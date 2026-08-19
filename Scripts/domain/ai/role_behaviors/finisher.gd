class_name AIRoleFinisher

# FINISHER role behavior (OZONE — `AIRoleSlots.Slot.FINISHER`). Stateless, and
# two-mode: REACTIVE deflects an incoming shot and overrides everything while it
# is active; POSITIONING stages for the next one.
#
# There is deliberately no exposure factor — FINISHER is committed to crashing
# the net by role definition. Defensive recovery is SUPPORT's job.

# Speed gate: pucks slower than this are passes / rolling, not shots.
const INCOMING_SHOT_SPEED_M_S: float = 12.0

# Weak-side staging bias for the SET-UP CYCLE — the shape when the carrier has
# controlled possession low or on the wall and the defense is set, where the
# cross-seam feed is the highest-value look. Sized so the candidate ring
# (±SEARCH_STEP_M) spans the far-post / back-door region rather than straddling
# centre ice. Feel tunable; 0 = centered.
const WEAK_SIDE_BIAS_M: float = 4.0

# Rush-mode weak-side bias — the staging offset at FULL rush. Still opposite
# the carrier (a backdoor/give-and-go option), but tight enough that the
# FINISHER drives a lane it can actually finish from rather than parking past
# the far post. Blended toward WEAK_SIDE_BIAS_M as the rush cools.
const RUSH_WEAK_SIDE_BIAS_M: float = 2.0

# Rush-mode staging depth in front of the opp goal (metres). At full rush the
# search center pulls in from SLOT_DIST_M to here so the FINISHER crashes the
# net — a rebound / backdoor tap-in threat — instead of hanging at the slot.
# The is_legal_position crease/goal-line filters keep candidates off the goal
# line, so this can sit tight to the net safely.
const RUSH_NET_DRIVE_DIST_M: float = 2.5

# Carrier closing-speed band (m/s, toward the opp net) that maps to the
# rush blend. At/below LO the play reads as a set cycle (full cross-seam
# staging); at/above HI it reads as a full rush (net-crash). Between, the
# staging lerps. Keyed on the carrier's forward speed specifically — lateral
# cycling in the zone is not a rush, only driving at the net is.
const RUSH_SPEED_LO_M_S: float = 2.5
const RUSH_SPEED_HI_M_S: float = 6.5

# Cap on the feed flight time used for the goalie-motion prediction. Bounds the
# goalie's predicted slide so a far cross-ice candidate doesn't model an
# unrealistically settled goalie. Mirrors the carrier's pass-lead horizon.
const FEED_FLIGHT_MAX_S: float = 0.6

# TIP/SCREEN STATION depth: how far off the goal mouth the shot-line post
# sits, along the carrier→net line. Just outside the crease arc
# (GameRules.CREASE_ARC_RADIUS ≈ 1.83 m) plus a body — the real net-front
# office where the body screens the goalie AND the blade reaches the point
# blast (screen and tip are the same real estate; see tip_ev).
const TIP_STATION_DIST_M: float = 2.5


static func decide(ctx: RoleContext) -> RoleDecision:
	var reactive: RoleDecision = _try_reactive_decision(ctx)
	if reactive != null:
		return reactive
	return _positioning_decision(ctx)


# ── Reactive (incoming shot) ─────────────────────────────────────────────────

# A TIP decision when an incoming shot is detected; null when there is no shot
# threat. Every gate produces null on a miss so positioning takes over instead
# of the bot holding where it stands.
static func _try_reactive_decision(ctx: RoleContext) -> RoleDecision:
	var puck_state: PuckNetworkState = ctx.snapshot.puck_state
	if puck_state == null:
		return null

	# Held pucks are not shots: a carrier skating the puck at speed must not flip
	# the FINISHER into tip mode. This also covers the carrier-reaction debounce
	# window right after a release, when a live feed still nominally reads as
	# held — the tip reaction then starts a beat late, which is exactly what the
	# reaction-delay difficulty knob means.
	if puck_state.carrier_peer_id != -1:
		return null

	var puck_pos: Vector3 = puck_state.position
	var puck_vel: Vector3 = puck_state.velocity
	var puck_speed: float = sqrt(puck_vel.x * puck_vel.x + puck_vel.z * puck_vel.z)

	# Speed gate: too slow → pass / rolling, not a shot.
	if puck_speed < INCOMING_SHOT_SPEED_M_S:
		return null

	# Direction gate: must be heading at our offensive goal.
	var opp_goal_z: float = -ctx.own_goal_dir * GameRules.GOAL_LINE_Z
	var to_goal_z: float = opp_goal_z - puck_pos.z
	if puck_vel.z * to_goal_z <= 0.0:
		return null

	# Predict where puck path crosses our z plane (lateral anchor pos).
	if absf(puck_vel.z) < 0.001:
		return null
	var t_to_my_z: float = (ctx.self_pos.z - puck_pos.z) / puck_vel.z
	if t_to_my_z <= 0.0 or t_to_my_z > 2.0:
		return null
	var path_x_at_my_z: float = puck_pos.x + puck_vel.x * t_to_my_z

	# TIP: step onto the puck path at our current z plane and aim at the goal so
	# the blade angles for the redirect — which works on-target (steering the
	# puck through a different angle past the goalie) and off-target alike. The
	# station is our CURRENT z, so the tip is taken from where the bot actually
	# is when the puck arrives rather than from a fixed anchor.
	var d := RoleDecision.new()
	d.target_position = Vector3(path_x_at_my_z, 0.0, ctx.self_pos.z)
	d.aim_world_pos = Vector3(0.0, 0.0, opp_goal_z)
	d.has_aim_override = true
	# A grounded blade flies under an elevated puck, so an airborne incoming shot
	# has to be met with the blade raised.
	if _last_shooter_is_elevated(ctx):
		d.lift_blade = true
	return d


# True when the most recent likely shooter on our team released with any loft
# (level > 0) — read off his replicated state rather than projecting the puck's
# y velocity through gravity. The closest teammate to the puck is the proxy for
# "shooter": a puck in flight has no carrier, but the bot that just released is
# typically still nearest it.
static func _last_shooter_is_elevated(ctx: RoleContext) -> bool:
	if ctx.snapshot.puck_state == null:
		return false
	var puck_pos: Vector3 = ctx.snapshot.puck_state.position
	var best_pid: int = 0
	var best_d2: float = INF
	for pid: int in ctx.snapshot.skater_states:
		if ctx.team_id_by_peer.get(pid, -1) != ctx.team_id:
			continue
		var pos: Vector3 = ctx.snapshot.skater_states[pid].position
		var dx: float = pos.x - puck_pos.x
		var dz: float = pos.z - puck_pos.z
		var d2: float = dx * dx + dz * dz
		if d2 < best_d2:
			best_d2 = d2
			best_pid = pid
	if best_pid == 0:
		return false
	return ctx.snapshot.skater_states[best_pid].elevation_level > 0


# ── Positioning (no incoming shot) ──────────────────────────────────────────

# Argmax over the named staging stations, each scored as the better of its two
# payoffs — the one-timer feed or the tip of the carrier's direct rip. Falls
# back to self_pos when no teammate carries (the brain re-routes this peer
# within a frame).
static func _positioning_decision(ctx: RoleContext) -> RoleDecision:
	var d := RoleDecision.new()

	var carrier_pos: Vector3 = AIRoleHelpers.resolve_teammate_carrier_pos(ctx)
	if not carrier_pos.is_finite():
		d.target_position = ctx.self_pos
		return d

	var goalie_pos: Vector3 = AIRoleHelpers.resolve_opp_goalie_pos(ctx)

	var opp_positions: Array[Vector3] = ctx.scratch_opp_positions
	var opp_states: Array[SkaterNetworkState] = ctx.scratch_opp_states
	AIRoleHelpers.collect_opponents(ctx, opp_positions, opp_states)

	var teammate_positions: Array[Vector3] = ctx.scratch_teammates
	AIRoleHelpers.collect_teammates_excluding_self(ctx, teammate_positions)

	# 0 = set cycle (full cross-seam staging), 1 = full rush (net-crash). The
	# cross-seam park strands the FINISHER off an odd-man chance developing NOW,
	# so the staging blends toward a genuine second attacker as the rush builds.
	var rush: float = _rush_factor(ctx)
	var weak_bias: float = lerpf(WEAK_SIDE_BIAS_M, RUSH_WEAK_SIDE_BIAS_M, rush)
	var stage_dist: float = lerpf(GameRules.SLOT_DIST_M, RUSH_NET_DRIVE_DIST_M, rush)

	# The slot, stage_dist in front of the opp goal, shifted to the WEAK side so
	# the FINISHER stages the cross-seam one-timer rather than crowding the
	# puck-side play. strong_x is the puck's hysteretic side; weak is its
	# negation, and the candidate spread still reaches strong-side spots when the
	# scoring favours them.
	var search_center := Vector3(
			-ctx.strong_x * weak_bias,
			0.0,
			ctx.attacking_goal_pos.z + ctx.own_goal_dir * stage_dist)
	# Far from the station, skate at the CALCULATED center directly: the feed×shot
	# argmax refines a seam read that will be re-taken from closer before arrival
	# (see STATION_ARGMAX_LOD_M), and readiness needs half-step proximity anyway.
	if not AIRoleHelpers.station_needs_refinement(ctx.self_pos, search_center):
		d.target_position = search_center
		return d
	# NAMED-STATION candidate set — the one-timer geography, not a blind polar
	# ring. The spots a finisher stages at are structural rink geography; the
	# scoring picks among them per the live coverage. A ring around a single
	# centre cannot span the backdoor and the high slot in the same read.
	var weak: float = -ctx.strong_x
	var goal_z: float = ctx.attacking_goal_pos.z
	var own_dir: float = ctx.own_goal_dir
	var candidates: Array[Vector3] = [
		# The rush-blended generic station (net-crash on the rush, weak-side
		# slot on the set cycle) and the current spot (stability).
		search_center,
		ctx.self_pos,
		# BACKDOOR — the far-post tap-in / one-timer: a body-width outside
		# the far post, just clear of the crease arc (1.83 m) and the
		# goal-line buffer.
		Vector3(weak * (GameRules.NET_HALF_WIDTH + 1.4), 0.0,
				goal_z + own_dir * 1.5),
		# BUMPER — the mid-slot one-timer at the top of the crease traffic.
		Vector3(weak * 0.8, 0.0, goal_z + own_dir * GameRules.SLOT_DIST_M),
		# WEAK DOT — the flank one-timer office at the end-zone faceoff dot.
		Vector3(weak * GameRules.END_ZONE_FACEOFF_DOT_X, 0.0,
				goal_z + own_dir
						* (GameRules.GOAL_LINE_Z - GameRules.ICING_FACEOFF_DOT_Z)),
		# HIGH SLOT — the trailing seam at the top of the house.
		Vector3(weak * 1.5, 0.0, goal_z + own_dir * 9.5),
	]
	# TIP/SCREEN STATION — the shot-line post: ON the carrier→net line at
	# crease-edge depth, where the body screens the goalie and the blade tips the
	# point blast (they are the same spot). It tracks the carrier, so a point man
	# walking the line drags the station with him. Its whole value comes from the
	# tip term below: score_pass correctly rates a body parked in the goalie's
	# chest as a terrible pass target.
	var to_carrier: Vector3 = carrier_pos - ctx.attacking_goal_pos
	to_carrier.y = 0.0
	var to_carrier_len: float = to_carrier.length()
	if to_carrier_len > TIP_STATION_DIST_M + 0.5:
		candidates.append(ctx.attacking_goal_pos
				+ to_carrier * (TIP_STATION_DIST_M / to_carrier_len))
	# Switch-hysteresis: hold the staging spot unless a fresh one scores clearly
	# better, so the pre-aim cursor doesn't hop between near-tied slots.
	AIRoleHelpers.append_incumbent(ctx, candidates)

	# The carrier's rip, for the tip term: his real wrister pace, released a
	# handle-length toward the net. Self caps drive the tip blade's reach.
	var carrier_caps: AISkaterCaps = null
	var carrier_pid: int = ctx.snapshot.puck_state.carrier_peer_id \
			if ctx.snapshot != null and ctx.snapshot.puck_state != null else -1
	if carrier_pid != -1:
		carrier_caps = ctx.caps_by_peer.get(carrier_pid)
	var carrier_shot_speed: float = carrier_caps.wrister_shot_speed \
			if carrier_caps != null else AIActionScoring.WRISTER_SHOT_SPEED_M_S
	var carrier_release: Vector3 = AIActionScoring.release_point_toward(
			carrier_pos, ctx.attacking_goal_pos)
	var self_caps: AISkaterCaps = ctx.caps_by_peer.get(ctx.peer_id)

	var best_pos: Vector3 = ctx.self_pos
	var best_score: float = -INF
	# RUSH DEPTH GATE — a feel tunable, deliberately not a perception.
	#
	# Fired at the live goalie from this fixture's four stations, the net crash
	# (2.7 m), the backdoor (2.8 m), the bumper (5.1 m) and the high slot (9.6 m)
	# ALL convert 24/24 while he is still square to the carrier and ALL convert
	# 0/24 once he has re-squared. Location does not enter it; the only variable
	# is whether he has recovered. So no shot-value model can order these spots —
	# on the shot alone they are the same spot, and an argmax over near-identical
	# values picks whichever noise is highest.
	#
	# What makes the net the right station on a rush is the second chance and the
	# body: rebounds, tips, and a keeper who has to respect a man at the post.
	# Nothing in the scoring represents that (the tip term only fires for a body
	# on the shot line), so rather than invent a value that makes the model appear
	# to discriminate, this states the coaching decision directly: on a rush the
	# second attacker drives the net, and perimeter stations are not his.
	#
	# The cap IS stage_dist, with no margin, because stage_dist is already the
	# code's own statement of how deep the finisher belongs at this rush factor —
	# a candidate deeper than it contradicts the staging decision just made. At a
	# standstill that is SLOT_DIST_M, and it tightens to the crease as the rush
	# develops.
	var depth_cap: float = stage_dist
	for c: Vector3 in candidates:
		if not AIRoleHelpers.is_legal_position(c):
			continue
		if AIRoleHelpers.too_close_to_teammate(c, teammate_positions):
			continue
		if absf(c.z - goal_z) > depth_cap:
			continue
		# The speed our carrier would actually fire at — long passes get the
		# charged-wrister speed, short ones the quick-shot speed. At a flat
		# 14 m/s a 12 m feed scores as if defenders had 36% more reaction time
		# than they really do.
		var pass_speed: float = AIActionScoring.expected_pass_speed(carrier_pos, c)
		# Predict the goalie at the one-timer feed's release (flight only — the
		# FINISHER fires on contact) and credit the motion: a weak-side candidate
		# forces a goalie slide it can't finish inside the pass flight, so the
		# cross-seam look scores above a static strong-side one. This is the
		# off-puck mirror of the carrier's own feed scoring.
		var flight_t: float = clampf(
				carrier_pos.distance_to(c) / pass_speed, 0.0, FEED_FLIGHT_MAX_S)
		# Pre-armed feed keeper (backdoor_depth_cap on v3's predicted pose):
		# a live goalie who can see this one-timer spot is already
		# depth-capped against it, arriving on the line with hands sunk by
		# the race's tightness — the cross-seam look prices merely-strong,
		# not phantom-certain (and a post-sealable deep-wide spot honestly
		# dies against the wall the real keeper adopts).
		AIActionScoring.resolve_feed_keeper(
				goalie_pos, ctx.attacking_goal_pos, flight_t, c, carrier_pos,
				AIRoleHelpers.opp_goalie_hands(ctx), pass_speed, opp_positions)
		# A staging spot is worth the better of its two payoffs: the one-timer
		# feed (score_pass — being open for a pass-and-shoot) or the TIP of
		# the carrier's direct rip through this spot (tip_ev — standing where
		# the blast can be deflected). max(), not sum: one puck, one outcome.
		var feed: float = AIActionScoring.score_pass(
				carrier_pos, c, ctx.attacking_goal_pos,
				AIActionScoring.feed_keeper_pos, GameRules.NET_HALF_WIDTH,
				opp_positions, pass_speed, AIActionScoring.feed_keeper_unsettled,
				-1.0, AIActionScoring.feed_keeper_hands, Vector4.INF,
				ctx.scratch_opp_caps)
		var tip: float = AIActionScoring.tip_ev(
				carrier_release, c, ctx.attacking_goal_pos, goalie_pos,
				GameRules.NET_HALF_WIDTH, opp_positions,
				carrier_shot_speed, ctx.scratch_opp_caps, self_caps)
		var score: float = maxf(feed, tip) + AIRoleHelpers.incumbent_bonus(ctx, c)
		if score > best_score:
			best_score = score
			best_pos = c

	d.target_position = best_pos
	# Arrival needs no separate quality gate: the argmax already encoded "this is
	# a high-value pass-and-shoot spot", and a weak one scores low for the carrier
	# too, so the ready flag never gets consumed. Tolerance is half a search step
	# — inside it the bot is nearer the chosen station than any neighbouring one.
	if ctx.self_pos.distance_to(best_pos) < AIRoleHelpers.SEARCH_STEP_M * 0.5:
		d.is_one_timer_ready = true
	return d


# Rush blend in [0, 1] from the carrier's CLOSING speed toward the opp net.
# Only the forward (toward-attacking-goal) component counts — a carrier cycling
# laterally at speed is not rushing the net and must not collapse the cross-seam
# staging. Returns 0 when the carrier isn't resolvable, so staging defaults to
# the set-cycle shape.
static func _rush_factor(ctx: RoleContext) -> float:
	if ctx.snapshot == null or ctx.snapshot.puck_state == null:
		return 0.0
	var carrier_pid: int = ctx.snapshot.puck_state.carrier_peer_id
	if carrier_pid == -1 or not ctx.snapshot.skater_states.has(carrier_pid):
		return 0.0
	if ctx.team_id_by_peer.get(carrier_pid, -1) != ctx.team_id:
		return 0.0
	var carrier_vel: Vector3 = ctx.snapshot.skater_states[carrier_pid].velocity
	# Forward = toward the attacking goal along Z (-own_goal_dir). Negative
	# (skating away from the net) floors at 0 — never a rush.
	var closing_speed: float = maxf(-ctx.own_goal_dir * carrier_vel.z, 0.0)
	return clampf(
			(closing_speed - RUSH_SPEED_LO_M_S)
					/ (RUSH_SPEED_HI_M_S - RUSH_SPEED_LO_M_S),
			0.0, 1.0)
