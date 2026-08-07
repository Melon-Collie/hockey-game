class_name AIRoleFinisher

# FINISHER role behavior (OZONE — `AIRoleSlots.Slot.FINISHER`).
# Two-mode decision:
#
#   1. REACTIVE: an incoming shot is detected (puck heading at our
#      offensive goal at speed) — the off-puck deflection routine.
#      Always TIP: move onto the puck path and point the blade at net
#      for the redirect (works for on- and off-target shots). When the
#      incoming shot is ELEVATED, also raise the blade (lift_blade) so
#      it can reach the airborne puck — a grounded stick flies under it.
#      Reactive overrides positioning when active.
#
#   2. POSITIONING: no incoming shot. FINISHER cares about exactly
#      two things — being open for a shot, being open for a pass.
#      score_pass(carrier, candidate) bundles both:
#
#         path_clearance(carrier, candidate)   ← open for a pass
#       × score_shoot(candidate, ...)          ← open for a shot
#       × time_decay(flight_time)              ← ~1 for in-OZ passes
#
#      For near-net FINISHER candidates the shot-quality term
#      (score_shoot) dominates the gradient — small differences in
#      angle to net, goalie position, and forward-cone pressure
#      drive the argmax toward whichever spot has the cleanest open
#      look. Pass-lane openness gates which of those spots are
#      actually reachable from the current carrier position.
#
#      No exposure factor — FINISHER is committed to crashing the
#      net by role definition. Defensive recovery is SUPPORT's job.
#
# Stateless. Reactive logic is unchanged from the original
# `_backdoor_decision`; positioning is new in Phase 4c.

# Speed gate: pucks slower than this are passes / rolling, not shots.
const INCOMING_SHOT_SPEED_M_S: float = 12.0

# Weak-side staging bias: shift the positioning search center off-center to the
# WEAK side (opposite the puck's strong side) so the FINISHER stages the
# cross-seam one-timer option instead of stacking on the puck-side play.
# Sized so the candidate ring (±SEARCH_STEP_M) spans the far-post/back-door
# region rather than straddling center ice. Tunable; 0 = centered.
#
# This far-post staging is the SET-UP-CYCLE shape — the right spot when the
# carrier has controlled possession low/on the wall and the defense is set,
# where the cross-seam feed is the highest-value look. On a RUSH (carrier
# driving the net at speed) that same spot leaves the FINISHER stranded far
# from the play — not a threat when the odd-man chance is developing NOW. The
# _rush_factor() blend below pulls the staging toward a genuine net-crash as
# the carrier's closing speed rises, so the FINISHER is a real second attacker
# on the rush and reverts to the cross-seam park once the play settles.
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

# How far in front of the opp goal the positioning search center
# sits. Sourced from GameRules.SLOT_DIST_M — the faceoff-hash slot,
# the prime scoring area. Keeps every polar sample (radius
# SEARCH_STEP_M = 3) on the legal side of the goal line
# (GOAL_LINE_BUFFER_M = 1).


static func decide(ctx: RoleContext) -> RoleDecision:
	# Reactive mode wins when a shot is incoming. _try_reactive
	# returns null when no shot threat is detected; we then run
	# positioning.
	var reactive: RoleDecision = _try_reactive_decision(ctx)
	if reactive != null:
		return reactive
	return _positioning_decision(ctx)


# ── Reactive (incoming shot) ─────────────────────────────────────────────────

# Returns a TIP or STEP_OUT decision when an incoming shot is
# detected; null when no shot threat (caller falls through to
# positioning). All gates produce null on miss so positioning
# takes over instead of holding at the anchor.
static func _try_reactive_decision(ctx: RoleContext) -> RoleDecision:
	var puck_state: PuckNetworkState = ctx.snapshot.puck_state
	if puck_state == null:
		return null

	# Held pucks are not shots: a carrier skating the puck at speed must not
	# flip the FINISHER into tip mode. This also covers the carrier-reaction
	# debounce window right after a release, when a live feed still nominally
	# reads as held — the tip reaction then starts a beat late, which is
	# exactly what the reaction-delay difficulty knob means. (Before this
	# gate, that window's fast-"held" puck produced a reactive not-ready
	# decision that tore down one-timer readiness on every feed.)
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

	# TIP. Shift target onto the puck path at our current z plane, aim
	# mouse at goal so the blade angles toward net for a deflection /
	# redirect. Works for both on-target shots (steers the puck through a
	# different angle past the goalie) and off-target shots (redirects
	# toward net).
	#
	# Reactive references the FINISHER's CURRENT position (self_pos)
	# rather than a static anchor — under the no-anchors refactor
	# FINISHER roams, so reactive responses are anchored to where
	# the bot actually is when the puck arrives.
	var d := RoleDecision.new()
	d.target_position = Vector3(path_x_at_my_z, 0.0, ctx.self_pos.z)
	d.aim_world_pos = Vector3(0.0, 0.0, opp_goal_z)
	d.has_aim_override = true
	# Elevated check: read the most-recent shooter's loft level
	# directly from their network state (cleaner than projecting puck y
	# velocity through gravity math). Closest teammate to the puck is the
	# proxy for "shooter" since once the puck is in flight there's no
	# carrier — but the bot that just released is typically still nearest.
	# When the incoming on-net puck is airborne, raise the blade so we can
	# actually tip it — a grounded blade flies under an elevated puck.
	if _last_shooter_is_elevated(ctx):
		d.lift_blade = true
	return d


# True when the most recent likely shooter on our team released with any
# loft (level > 0). Used to detect airborne shots without doing gravity
# math on the puck. We pick the closest teammate to the puck as the proxy
# — once the puck is in flight there's no carrier, but the bot that
# just released is typically still nearby.
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

# Argmax over the candidate set scored with score_pass(carrier,
# candidate). Search center sits SLOT_DIST_M in front of
# the opp goal at center ice — the slot. Polar samples around this
# center cover the high-slot, low-slot, and weak/strong-side post
# regions. Falls back to self_pos when no teammate carrier (brain
# re-tick will re-route this peer within a frame).
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

	# Rush blend: how hard the carrier is driving the net right now. 0 = set
	# cycle (full cross-seam staging), 1 = full rush (net-crash). Pulls the
	# staging in from the far-post slot to a genuine second-attacker threat
	# so the FINISHER isn't stranded off the play when the odd-man chance is
	# developing NOW (see the constant doc-blocks above).
	var rush: float = _rush_factor(ctx)
	var weak_bias: float = lerpf(WEAK_SIDE_BIAS_M, RUSH_WEAK_SIDE_BIAS_M, rush)
	var stage_dist: float = lerpf(GameRules.SLOT_DIST_M, RUSH_NET_DRIVE_DIST_M, rush)

	# Search center: the slot, stage_dist in front of opp goal, shifted to the
	# WEAK side so the FINISHER stages the cross-seam one-timer rather than
	# crowding the puck-side play. strong_x is the puck's hysteretic side; the
	# weak side is its negation. The candidate spread still reaches strong-side
	# spots when the scoring favours them. On a rush stage_dist/weak_bias pull
	# the whole search toward a net-crash.
	var search_center := Vector3(
			-ctx.strong_x * weak_bias,
			0.0,
			ctx.attacking_goal_pos.z + ctx.own_goal_dir * stage_dist)
	# Far from the station, skate at the CALCULATED center directly — the
	# feed×shot argmax refines a seam read that will be re-taken from closer
	# before arrival (see STATION_ARGMAX_LOD_M), and readiness needs half-step
	# proximity anyway. The ten per-candidate goalie-predicted score_pass
	# evals only run when their answer is consumable.
	if not AIRoleHelpers.station_needs_refinement(ctx.self_pos, search_center):
		d.target_position = search_center
		return d
	# NAMED-STATION candidate set — the one-timer geography, not a blind
	# polar ring. The spots a finisher actually stages at are structural
	# rink geography; the scoring (feed lane × shot value × forced goalie
	# displacement) picks among them per the live coverage, and the
	# incumbent keeps the hysteresis. Fewer evals than the old 8-ring AND
	# wider coverage: a 3 m ring around one center could never span the
	# backdoor and the high slot in the same read.
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
	# crease-edge depth, where the body screens the goalie and the blade tips
	# the point blast (they're the same spot). Tracks the carrier, so a point
	# man walking the line drags the station with him. Its value comes from
	# the tip term below — score_pass correctly rates a body parked in the
	# goalie's chest as a terrible pass target, which is exactly why the old
	# argmax never stood there.
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
	# RUSH DEPTH GATE — doctrine, and deliberately not a perception.
	#
	# Fired at the live goalie from this fixture's four stations, the net crash
	# (2.7 m), the backdoor (2.8 m), the bumper (5.1 m) and the high slot
	# (9.6 m) ALL convert 24/24 while he is still square to the carrier, and
	# ALL convert 0/24 once he has re-squared. Location does not enter it; the
	# only variable is whether he has recovered. So no shot-value model can
	# order these spots, because on the shot alone they are the same spot —
	# and an argmax over near-identical values just picks whichever noise is
	# highest, which is how the finisher ended up staged 9.5 m out on a rush.
	#
	# What actually makes the net the right station on a rush is the second
	# chance and the body: rebounds, tips, and a keeper who has to respect a
	# man at the post. The rebound term is gone (see #577) and the tip term
	# only fires for a body on the shot line, so nothing in the scoring
	# represents it. Rather than invent a value that makes the model appear to
	# discriminate, this states the coaching decision directly: on a rush the
	# second attacker drives the net, and perimeter stations are not his.
	# CLAUDE.md names staging offsets as a legitimate feel tunable — the line
	# is evaluation vs. feel, and this is feel.
	#
	# The cap IS stage_dist, with no margin, because there is no number to add:
	# stage_dist is already the code's own statement of how deep the finisher
	# belongs at this rush factor. A candidate deeper than it contradicts the
	# staging decision that was just made. At a standstill that is SLOT_DIST_M
	# — the slot, which a net-front role should not be behind either — and it
	# tightens to the crease exactly as the rush develops.
	var depth_cap: float = stage_dist
	for c: Vector3 in candidates:
		if not AIRoleHelpers.is_legal_position(c):
			continue
		if AIRoleHelpers.too_close_to_teammate(c, teammate_positions):
			continue
		if absf(c.z - goal_z) > depth_cap:
			continue
		# Match the speed our carrier would actually fire at — long
		# passes get the charged-wrister speed, short ones the quick-
		# shot speed. Without this the lane-clear math assumes 14 m/s
		# universally and a 12 m feed scores as if defenders had 36%
		# more reaction time than they actually do.
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
	# One-timer ready: positioning argmax already encoded "this is a
	# high-value pass-and-shoot spot via score_pass." Once we've
	# arrived at it, signal ready. No separate quality gate — if the
	# spot is weak, score_pass(carrier, here) is low and the carrier
	# won't pass, so the ready flag never gets consumed.
	#
	# Arrival tolerance = half a polar search step. The candidates
	# are spaced SEARCH_STEP_M apart, so within half a step the bot
	# is closer to the chosen anchor than to any neighbor candidate;
	# they've effectively reached the spot.
	if ctx.self_pos.distance_to(best_pos) < AIRoleHelpers.SEARCH_STEP_M * 0.5:
		d.is_one_timer_ready = true
	return d


# Rush blend in [0, 1] from the carrier's CLOSING speed toward the opp net.
# 0 below RUSH_SPEED_LO_M_S (set cycle), 1 at/above RUSH_SPEED_HI_M_S (full
# rush), lerped between. Only the forward (toward-attacking-goal) component
# counts — a carrier cycling laterally at speed is not rushing the net, so it
# shouldn't collapse the cross-seam staging. Returns 0 when the carrier's
# state isn't resolvable (no carrier / not buffered) so staging defaults to
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
