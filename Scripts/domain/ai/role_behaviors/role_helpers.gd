class_name AIRoleHelpers

# Shared helpers for off-puck role behaviors. Every role that picks
# a position via candidate-set argmax (SUPPORT, OUTLET, FINISHER, and
# the upcoming defensive roles PRESSURE / MARK / CONTAIN) uses the
# same candidate generation, legality / anti-crowding filters, and
# context resolution. The role-specific differentiator is the
# scoring function — everything else lives here.

# Search radius around the anchor for polar candidate generation.
# Same scale as AIRoleCarrier.CARRY_SEARCH_STEP_M (3.0 m); roughly
# one brain-tick of travel at top skating speed. Sampling parameter,
# not a behavioral knob.
const SEARCH_STEP_M: float = 3.0

# Candidates within this distance of any teammate (excluding self)
# are filtered out — physical-overlap distance, prevents two
# teammates stacking on the same spot. Matches the blade-reach
# physical scale rather than an arbitrary "personal space" radius.
const ANTI_CROWD_RADIUS_M: float = 1.8

# Margin from the rink boards / goal lines that candidates are
# clamped inside of. Sampling parameter.
const RINK_INSET_M: float = 0.5
const GOAL_LINE_BUFFER_M: float = 1.0

# Pre-baked rotations for the 8 polar cardinal candidates.
const POLAR_ANGLES: Array[float] = [
		0.0, PI * 0.25, PI * 0.5, PI * 0.75,
		PI, -PI * 0.75, -PI * 0.5, -PI * 0.25,
]


# ── Candidate generation ─────────────────────────────────────────────────────

# Returns the standard off-puck candidate set: anchor + self
# (stand-still) + 8 polar samples around the anchor at SEARCH_STEP_M.
# Polar pattern is fixed-cardinal (0°, 45°, ..., 315°) — roles that
# need slot-oriented search (like CARRIER) roll their own.
#
# Phase 4d / Step 2 of the no-anchors refactor: roles increasingly
# compute their own search center from in-game refs (carrier pos,
# nets, etc.) instead of leaning on ctx.anchor. New code should
# call `generate_candidates_around(self_pos, center)` directly.
static func generate_candidates(ctx: RoleContext) -> Array[Vector3]:
	return generate_candidates_around(ctx.self_pos, ctx.anchor)


# Returns the standard 10-candidate set centered on `center`:
# `center` itself + `self_pos` (stand-still) + 8 polar samples
# around `center` at SEARCH_STEP_M. Use this when a role wants to
# pick its own search center from in-game references rather than
# inheriting whatever ctx.anchor happens to be.
#
# `with_inner_ring` appends 8 more polar samples at half step so the
# argmax can express small corrections instead of jumping in 3 m
# quanta — used by PRESSURE, whose chosen cut-off point is consumed
# directly as a steering target every dispatch (a coarser role that
# re-centers each brain tick doesn't need the resolution).
static func generate_candidates_around(self_pos: Vector3,
		center: Vector3, with_inner_ring: bool = false) -> Array[Vector3]:
	var result: Array[Vector3] = []
	result.append(center)
	result.append(self_pos)
	for angle: float in POLAR_ANGLES:
		result.append(Vector3(
				center.x + SEARCH_STEP_M * cos(angle),
				0.0,
				center.z + SEARCH_STEP_M * sin(angle)))
	if with_inner_ring:
		var inner: float = SEARCH_STEP_M * 0.5
		for angle: float in POLAR_ANGLES:
			result.append(Vector3(
					center.x + inner * cos(angle),
					0.0,
					center.z + inner * sin(angle)))
	return result


# Rejects candidates outside the playable rink, in either crease,
# or past either goal line. Common to every off-puck role.
static func is_legal_position(c: Vector3) -> bool:
	if absf(c.x) > GameRules.RINK_HALF_WIDTH - RINK_INSET_M:
		return false
	if absf(c.z) > GameRules.GOAL_LINE_Z - GOAL_LINE_BUFFER_M:
		return false
	if CreaseRules.is_in_crease(Vector2(c.x, c.z)):
		return false
	return true


# True if `c` is within ANTI_CROWD_RADIUS_M of any teammate position
# (callers should exclude self before passing the list, see
# `collect_teammates_excluding_self`).
static func too_close_to_teammate(c: Vector3,
		teammate_positions: Array[Vector3]) -> bool:
	var r2: float = ANTI_CROWD_RADIUS_M * ANTI_CROWD_RADIUS_M
	for tp: Vector3 in teammate_positions:
		var dx: float = c.x - tp.x
		var dz: float = c.z - tp.z
		if dx * dx + dz * dz < r2:
			return true
	return false


# ── Defensive anticipation ───────────────────────────────────────────────────

# How far ahead (seconds) defensive roles lead an opponent's position when
# scoring threats, so they defend where the attack is GOING rather than the
# freeze-frame. Mirrors how PRESSURE already leads its search center off the
# carrier's velocity; this extends that anticipation to the receivers / men the
# other defensive roles cover.
const DEFENSIVE_ANTICIPATION_S: float = 0.3
# Clamp on the lead distance so a fast skater — or a momentary velocity spike on
# a curling route — can't drag a defender far off the man. Keeps anticipation a
# half-step nudge, not a commit to a phantom.
const DEFENSIVE_ANTICIPATION_MAX_M: float = 2.5


# Leads a threat position by its velocity over DEFENSIVE_ANTICIPATION_S, clamped
# to DEFENSIVE_ANTICIPATION_MAX_M. XZ only; y stays 0. `scale` is the difficulty
# pace knob (ctx.defensive_anticipation_scale): 1.0 = today, lower leads less so
# the defender sits a step behind the play (more space for the carrier).
static func lead_threat(pos: Vector3, vel: Vector3, scale: float = 1.0) -> Vector3:
	var anticipation_s: float = DEFENSIVE_ANTICIPATION_S * scale
	var lead_x: float = vel.x * anticipation_s
	var lead_z: float = vel.z * anticipation_s
	var l: float = sqrt(lead_x * lead_x + lead_z * lead_z)
	if l > DEFENSIVE_ANTICIPATION_MAX_M:
		var s: float = DEFENSIVE_ANTICIPATION_MAX_M / l
		lead_x *= s
		lead_z *= s
	return Vector3(pos.x + lead_x, 0.0, pos.z + lead_z)


# ── Man-on-threat coverage ───────────────────────────────────────────────────

# Slack on cover_man_target's goal-side filter: candidates may sit up to
# this far toward the play from the man (roughly even with him) but no
# further. Tight coverage must never trade the defensive side for lane
# denial — a defender ahead of his man is one burst from being beaten to
# the net. Goal-side is measured along the man→our-net LINE (the same
# projection the cover anchor and the threat partition use), not the Z
# axis: for a man wide of the net or near the goal-line-extended, "behind
# him in Z" and "between him and the net" point different ways, and the
# Z reading let the marker legally park BESIDE his man, off the sealing
# lane.
const COVER_GOAL_SIDE_TOLERANCE_M: float = 0.5

# Shared "cover this assigned man" target for the backline defenders
# (MARK) when TeamBrain's threat partition hands them a specific
# opponent. Picks the position that most deflates the carrier→man pass-threat
# surface (lane interception × the man's resulting shot), searching a candidate
# set centered on the threat partition's own cover anchor — a stick into the
# man→net lane (AIThreatAssignment.cover_anchor, COVER_DEPTH_M goal-side of
# him) — i.e. set up ON the man, in the feed lane, to kill the one-timer.
#
# The search center used to be the midpoint between the man and our net,
# which sagged the whole candidate set: a man 12 m out was "covered" from
# ~6 m away, and because a midpoint moves at HALF the man's speed, a
# cutting man walked away from his check every time ("bots lose their
# man"). Anchoring on cover_anchor keeps the defender attached (it tracks
# the man 1:1) and matches the anchor the partition already scored
# reachability against, so the pairing and the coverage agree. The ±3 m
# candidate ring still lets the argmax shade off the body and into the
# carrier→man lane when that deflates the threat more.
#
# This replaces the legacy "minimize the MAX threat over ALL opponents" scoring
# for the assigned-man case: because each backline defender gets a DISTINCT man,
# two defenders no longer collapse onto the single most dangerous opponent.
# Roles fall back to their all-opponents behavior when unassigned (man_pid -1).
static func cover_man_target(ctx: RoleContext, man_pos: Vector3,
		carrier_pos: Vector3) -> Vector3:
	var our_net: Vector3 = ctx.defending_goal_pos
	var our_goalie_pos: Vector3 = resolve_our_goalie_pos(ctx)
	var teammates: Array[Vector3] = ctx.scratch_teammates
	collect_teammates_excluding_self(ctx, teammates)

	var search_center: Vector3 = AIThreatAssignment.cover_anchor(man_pos, our_net)
	var candidates: Array[Vector3] = generate_candidates_around(ctx.self_pos, search_center)

	# Goal-side axis: the man→our-net direction. A candidate is goal-side
	# when its projection onto this line from the man is positive (with the
	# tolerance slack) — i.e. it sits between the man and the net he
	# threatens, wherever on the ice that lane points.
	var to_net_x: float = our_net.x - man_pos.x
	var to_net_z: float = our_net.z - man_pos.z
	var to_net_len: float = sqrt(to_net_x * to_net_x + to_net_z * to_net_z)
	var has_lane: bool = to_net_len > 0.001
	if has_lane:
		to_net_x /= to_net_len
		to_net_z /= to_net_len

	var best_pos: Vector3 = ctx.self_pos
	var best_score: float = -INF
	# Fallback across candidates that failed ONLY the goal-side filter —
	# used when a man parked against our goal line leaves no legal
	# goal-side spot (goal-line buffer + crease eat the ring), so the
	# defender still covers from the front instead of freezing.
	var fallback_pos: Vector3 = ctx.self_pos
	var fallback_score: float = -INF
	for c: Vector3 in candidates:
		if not is_legal_position(c):
			continue
		if too_close_to_teammate(c, teammates):
			continue
		# Carrier's view of defenders: our team + us hypothetically at c. Append
		# c to the shared teammates scratch in place and pop it after scoring —
		# a duplicate() per candidate (10×/decide) was pure hot-path churn. The
		# array is restored exactly, and too_close_to_teammate above already read
		# it candidate-free this iteration.
		teammates.push_back(c)
		# Minimize the carrier's threat of feeding THIS man (lane × his shot).
		var threat: float = AIActionScoring.threat_surface_pass(
				carrier_pos, man_pos, our_net, our_goalie_pos,
				GameRules.NET_HALF_WIDTH, teammates)
		teammates.pop_back()
		var score: float = -threat
		# Stay on the defensive side of the man: positive projection onto
		# the man→our-net line (see COVER_GOAL_SIDE_TOLERANCE_M). A man on
		# the net (no lane) disables the filter — any spot is "in front".
		var proj: float = (c.x - man_pos.x) * to_net_x + (c.z - man_pos.z) * to_net_z \
				if has_lane else 0.0
		if not has_lane or proj >= -COVER_GOAL_SIDE_TOLERANCE_M:
			if score > best_score:
				best_score = score
				best_pos = c
		elif score > fallback_score:
			fallback_score = score
			fallback_pos = c
	if best_score == -INF and fallback_score > -INF:
		return fallback_pos
	return best_pos


# ── Carrier-best-option (inverse scoring) ────────────────────────────────────

# Computes the opposing carrier's best option — shoot at our net, or pass to
# any of `opp_teammates` — with our hypothetical defender position `candidate`
# appended to the carrier's view of the defenders. The on-puck / rush
# defensive roles (PRESSURE's cut-off argmax, CONTAIN's odd-man lane fan)
# argmax the NEGATION of this over their candidate sets: the spot that most
# deflates the carrier's best option wins.
#
# Uses the threat-surface helpers so the gradient survives when score_shoot /
# score_pass collapse to 0 (carrier far from net or all receivers far from
# net). The position_potential floor pulls the defender tight to the carrier
# in TRANS_OD scenarios where there's no immediate scoring threat to defend —
# without it the score is flat across goal-side candidates and the argmax
# picks arbitrarily.
#
# Coverage is CONTINUOUS by construction: `our_team_excluding_self` rides
# into both surfaces, so a teammate already on a receiver suppresses that
# pass threat and an uncovered receiver's threat stands — "who is really
# open" needs no separate boolean read.
static func carrier_best_option(
		candidate: Vector3,
		carrier_pos: Vector3,
		our_net: Vector3,
		our_goalie_pos: Vector3,
		our_team_excluding_self: Array[Vector3],
		opp_teammates: Array[Vector3]) -> float:
	# Carrier's view of defenders = our team + me at the candidate. This helper
	# is called once per candidate in PRESSURE's argmax (up to ~19×/decide), so
	# duplicating the array every call was pure hot-path churn. Append the
	# candidate to the caller's array in place and pop it before returning — the
	# array is left exactly as passed, and after the first call the backing
	# store keeps its capacity so the push/pop allocates nothing.
	our_team_excluding_self.push_back(candidate)

	# Carrier's best shot at our net (with positional fallback floor).
	var shoot_value: float = AIActionScoring.threat_surface_shoot(
			carrier_pos, our_net, our_goalie_pos,
			GameRules.NET_HALF_WIDTH, our_team_excluding_self)

	# Carrier's best pass to any teammate (with positional fallback).
	# `our_net` is the attacking goal from the carrier's perspective, so the
	# receiver's threat is evaluated against our goalie.
	var pass_value: float = 0.0
	for opp_pos: Vector3 in opp_teammates:
		var pass_score: float = AIActionScoring.threat_surface_pass(
				carrier_pos, opp_pos, our_net, our_goalie_pos,
				GameRules.NET_HALF_WIDTH, our_team_excluding_self)
		if pass_score > pass_value:
			pass_value = pass_score

	our_team_excluding_self.pop_back()
	return maxf(shoot_value, pass_value)


# Rush variant of carrier_best_option, for CONTAIN's odd-man lane fan: RAW xG
# threats (no position_potential floor) with each pass modeled as a ONE-TIMER
# feed — the goalie must traverse to the receiver's line over the pass flight
# and reads the release late (predict_goalie_pos + goalie_unsettled), which is
# exactly what makes the cross-crease feed the threat the 2-on-1 doctrine
# plays ("the goalie takes the shooter, I take the pass"). The carrier's
# direct shot is scored against the goalie where he IS — squared to the known
# shooter, the doctrine's other half.
#
# Why not the surfaced variant above: its position_potential floor exists to
# give PRESSURE close-in gradients, but across CONTAIN's gap-distance fan the
# floor flattens (every candidate sits outside the pressure cone) and masks
# the reducible-threat comparison entirely; and a set-goalie pass read scores
# the one-timer feed near zero, hiding the very threat the fan exists to
# take away. Raw xG also ties at ~0 far from the net, so the fan's hold
# margin keeps the classic retreat line out there — the correct far-out read.
static func carrier_live_option(
		candidate: Vector3,
		carrier_pos: Vector3,
		our_net: Vector3,
		our_goalie_pos: Vector3,
		our_team_excluding_self: Array[Vector3],
		opp_teammates: Array[Vector3]) -> float:
	# Defenders = our team + me at the candidate. Append-and-restore the caller's
	# array in place instead of duplicating it — called once per candidate in
	# CONTAIN's lane fan (up to ~13×/decide), so a fresh Array per call was pure
	# churn. The array is left exactly as passed; capacity is retained across the
	# push/pop so steady-state calls allocate nothing.
	our_team_excluding_self.push_back(candidate)
	var best: float = AIActionScoring.score_shoot(
			carrier_pos, our_net, our_goalie_pos,
			GameRules.NET_HALF_WIDTH, our_team_excluding_self)
	for receiver: Vector3 in opp_teammates:
		var pass_speed: float = AIActionScoring.expected_pass_speed(carrier_pos, receiver)
		var flight_s: float = carrier_pos.distance_to(receiver) / maxf(pass_speed, 1.0)
		var pred_goalie: Vector3 = AIActionScoring.predict_goalie_pos(
				our_goalie_pos, our_net, flight_s, receiver)
		var unsettled: float = AIActionScoring.goalie_unsettled(
				our_goalie_pos, our_net, flight_s, receiver)
		var pass_value: float = AIActionScoring.score_pass(
				carrier_pos, receiver, our_net, pred_goalie,
				GameRules.NET_HALF_WIDTH, our_team_excluding_self, pass_speed, unsettled)
		if pass_value > best:
			best = pass_value
	our_team_excluding_self.pop_back()
	return best


# ── Body check ───────────────────────────────────────────────────────────────

# Evaluates whether the on-puck pressurer should commit to a body check on the
# live OPPONENT carrier this tick (AIBodyCheck), resolving the carrier from the
# snapshot. Returns a no-commit Result when the puck is loose, carried by a
# teammate, or absent — so only a real opponent carrier is ever a hit target.
# Used by PRESSURE (which also serves FORECHECK's F1), the pressurers that have
# support behind them; the last-man gap defender never calls this.
static func evaluate_body_check(ctx: RoleContext) -> AIBodyCheck.Result:
	if ctx.snapshot == null or ctx.snapshot.puck_state == null:
		return AIBodyCheck.Result.new()
	var carrier_pid: int = ctx.snapshot.puck_state.carrier_peer_id
	if carrier_pid == -1 or ctx.team_id_by_peer.get(carrier_pid, -1) == ctx.team_id:
		return AIBodyCheck.Result.new()
	if not ctx.snapshot.skater_states.has(carrier_pid):
		return AIBodyCheck.Result.new()
	# Difficulty pace knob: check_aggression gates hit-hunting. 0.0 = never
	# commit (pure containment — the easiest, least intimidating tier); below 1.0
	# raises the required separating-hit impulse inversely, so an easier bot only
	# commits to the hardest hits and mostly just contains. 1.0 = today's gate.
	if ctx.check_aggression <= 0.0:
		return AIBodyCheck.Result.new()
	var commit_threshold: float = AIBodyCheck.COMMIT_IMPULSE_M_S / ctx.check_aggression
	var carrier: SkaterNetworkState = ctx.snapshot.skater_states[carrier_pid]
	# The victim's real mass (Size) — don't leave your feet for a hit you'd bounce
	# off a heavy carrier with. League default when the build isn't wired.
	var victim_caps: AISkaterCaps = ctx.caps_by_peer.get(carrier_pid)
	var victim_weight: float = victim_caps.weight if victim_caps != null \
			else AIBodyCheck.LEAGUE_VICTIM_WEIGHT
	return AIBodyCheck.evaluate(
			ctx.self_pos, ctx.self_max_speed, ctx.self_weight,
			ctx.self_body_check_transfer, ctx.self_stagger_timer,
			carrier.position, carrier.velocity, commit_threshold, victim_weight)


# ── Context resolution ──────────────────────────────────────────────────────

# Returns the puck-carrying teammate's position, or Vector3.ZERO if
# no teammate carries the puck (loose puck or opp possession). Roles
# that argmax over score_pass(carrier, candidate) need this; they
# fall back to the anchor when ZERO is returned.
static func resolve_teammate_carrier_pos(ctx: RoleContext) -> Vector3:
	if ctx.snapshot == null or ctx.snapshot.puck_state == null:
		return Vector3.INF
	var carrier_pid: int = ctx.snapshot.puck_state.carrier_peer_id
	if carrier_pid == -1:
		return Vector3.INF
	if ctx.team_id_by_peer.get(carrier_pid, -1) != ctx.team_id:
		return Vector3.INF
	if not ctx.snapshot.skater_states.has(carrier_pid):
		return Vector3.INF
	return ctx.snapshot.skater_states[carrier_pid].position


# Our carrier's CLOSING speed (m/s) toward the attacking net — the forward
# (toward-attacking-goal) component of the carrier's velocity, floored at 0.
# The "is this a rush?" primitive: a carrier driving up-ice at speed reads
# high; one cycling laterally, stalled, or retreating reads ~0. Returns 0.0
# when there's no teammate carrier to read (loose puck / opp possession), so
# roles default to their non-rush shape. Lateral velocity is deliberately
# ignored — only driving AT the net counts as a rush.
static func carrier_closing_speed(ctx: RoleContext) -> float:
	if ctx.snapshot == null or ctx.snapshot.puck_state == null:
		return 0.0
	var carrier_pid: int = ctx.snapshot.puck_state.carrier_peer_id
	if carrier_pid == -1 or not ctx.snapshot.skater_states.has(carrier_pid):
		return 0.0
	if ctx.team_id_by_peer.get(carrier_pid, -1) != ctx.team_id:
		return 0.0
	var vel: Vector3 = ctx.snapshot.skater_states[carrier_pid].velocity
	# Forward = toward the attacking goal along Z (-own_goal_dir).
	return maxf(-ctx.own_goal_dir * vel.z, 0.0)


# Returns the opposing goalie's CURRENT world position. Falls back
# to the attacking goal mouth when goalie state isn't buffered yet
# (first-frame edge case). Used as the `predicted_goalie_pos` arg
# to AIActionScoring.score_pass — v1 uses live position rather than
# future-projected, since differences across candidates dominate
# any prediction error.
static func resolve_opp_goalie_pos(ctx: RoleContext) -> Vector3:
	var opp_team_id: int = 1 - ctx.team_id
	var goalie: GoalieNetworkState = ctx.snapshot.goalie_states.get(opp_team_id)
	if goalie == null:
		return ctx.attacking_goal_pos
	return Vector3(goalie.position_x, 0.0, goalie.position_z)


# Returns OUR goalie's current position. Defensive roles use this
# as the predicted_goalie_pos when scoring the carrier's shot
# threat against our net.
static func resolve_our_goalie_pos(ctx: RoleContext) -> Vector3:
	var goalie: GoalieNetworkState = ctx.snapshot.goalie_states.get(ctx.team_id)
	if goalie == null:
		return ctx.defending_goal_pos
	return Vector3(goalie.position_x, 0.0, goalie.position_z)


# Returns the position of whichever peer carries the puck (regardless
# of team), or Vector3.ZERO when the puck is loose / null. Defensive
# roles use this since they're scoring against the opp carrier; the
# offensive `resolve_teammate_carrier_pos` filters to our team and
# returns ZERO when an opp carries.
static func resolve_any_carrier_pos(ctx: RoleContext) -> Vector3:
	if ctx.snapshot == null or ctx.snapshot.puck_state == null:
		return Vector3.INF
	var carrier_pid: int = ctx.snapshot.puck_state.carrier_peer_id
	if carrier_pid == -1:
		return Vector3.INF
	if not ctx.snapshot.skater_states.has(carrier_pid):
		return Vector3.INF
	return ctx.snapshot.skater_states[carrier_pid].position


# ── Play reference (anti-freeze) ─────────────────────────────────────────────
# Off-puck roles orient their candidate search around the carrier. But
# there's no live carrier for most of every transition — a loose puck,
# a breakout pass in flight, the beat after a won battle. The old
# fallback was to freeze at self_pos, which is the "stuck on the heels"
# bug: standing still is almost never the right call mid-transition.
#
# These resolvers fall back to the PUCK itself when no carrier holds it,
# so the role keeps flowing toward the developing play (the elected
# chaser contests it; the others set up as the next option / recover
# into shape). Returns INF only when there's no puck state at all
# (degenerate first frame) — callers still self_pos that case.

# Offensive roles (SUPPORT, OUTLET, FINISHER): prefer a live teammate
# carrier; else, when the puck is genuinely LOOSE, orient off the puck.
# An opp carrier is deliberately NOT a fallback — there's no offensive
# context to a candidate-pass-from-the-opp, and the brain re-ticks to a
# defensive role the same frame on the carrier change, so the caller
# holds for that one transient frame.
static func resolve_offensive_play_ref(ctx: RoleContext) -> Vector3:
	var carrier: Vector3 = resolve_teammate_carrier_pos(ctx)
	if carrier.is_finite():
		return carrier
	if ctx.snapshot != null and ctx.snapshot.puck_state != null \
			and ctx.snapshot.puck_state.carrier_peer_id == -1:
		return ctx.snapshot.puck_state.position
	return Vector3.INF


# Defensive roles (PRESSURE, CONTAIN, MARK): prefer whoever carries the
# puck (an opp by definition in their states); else orient off the puck.
static func resolve_defensive_play_ref(ctx: RoleContext) -> Vector3:
	var carrier: Vector3 = resolve_any_carrier_pos(ctx)
	if carrier.is_finite():
		return carrier
	if ctx.snapshot != null and ctx.snapshot.puck_state != null:
		return ctx.snapshot.puck_state.position
	return Vector3.INF


# Velocity of the play reference — the carrier's velocity when one holds
# the puck, else the puck's own velocity (loose / in flight). Roles that
# lead their search center off the reference (PRESSURE) use this so the
# lead is well-defined even with no live carrier.
static func resolve_play_ref_velocity(ctx: RoleContext) -> Vector3:
	if ctx.snapshot == null or ctx.snapshot.puck_state == null:
		return Vector3.ZERO
	var carrier_pid: int = ctx.snapshot.puck_state.carrier_peer_id
	if carrier_pid != -1 and ctx.snapshot.skater_states.has(carrier_pid):
		return ctx.snapshot.skater_states[carrier_pid].velocity
	return ctx.snapshot.puck_state.velocity


# Fills `out` with positions of opp peers other than the puck carrier — i.e.,
# the carrier's potential pass receivers. Defensive roles use this to score
# "carrier's best pass" when evaluating how much a candidate defender position
# deflates the carrier's options. Caller-owned scratch (see collect_opponents).
static func collect_opp_team_excluding_carrier(ctx: RoleContext,
		out: Array[Vector3], anticipate: bool = false) -> void:
	out.clear()
	var carrier_pid: int = -1
	if ctx.snapshot != null and ctx.snapshot.puck_state != null:
		carrier_pid = ctx.snapshot.puck_state.carrier_peer_id
	for pid: int in ctx.snapshot.skater_states:
		if ctx.team_id_by_peer.get(pid, -1) == ctx.team_id:
			continue  # our team
		if pid == carrier_pid:
			continue
		var s: SkaterNetworkState = ctx.snapshot.skater_states[pid]
		# Defensive anticipation: lead the receiver to where they're cutting.
		out.append(lead_threat(s.position, s.velocity, ctx.defensive_anticipation_scale) \
				if anticipate else s.position)


# Fills `out` with the positions of teammates excluding self. Used as the
# anti-crowd filter input. Caller-owned scratch (see collect_opponents).
static func collect_teammates_excluding_self(ctx: RoleContext,
		out: Array[Vector3]) -> void:
	out.clear()
	for pid: int in ctx.snapshot.skater_states:
		if pid == ctx.peer_id:
			continue
		if ctx.team_id_by_peer.get(pid, -1) == ctx.team_id:
			out.append(ctx.snapshot.skater_states[pid].position)


# Returns parallel arrays of opponent positions and full state refs.
# Positions feed AIActionScoring.score_pass / path_clearance; full
# states feed AIActionScoring.time_to_arrive (needs velocity for
# momentum-aware ETA).
static func collect_opponents(ctx: RoleContext,
		out_positions: Array[Vector3],
		out_states: Array[SkaterNetworkState],
		anticipate: bool = false) -> void:
	out_positions.clear()
	out_states.clear()
	ctx.scratch_opp_caps.clear()
	for pid: int in ctx.snapshot.skater_states:
		if ctx.team_id_by_peer.get(pid, -1) != ctx.team_id:
			var s: SkaterNetworkState = ctx.snapshot.skater_states[pid]
			# Defensive anticipation: lead each opponent to where they're headed.
			# States keep their raw velocity for any momentum-aware ETA caller.
			out_positions.append(lead_threat(s.position, s.velocity, ctx.defensive_anticipation_scale) \
					if anticipate else s.position)
			out_states.append(s)
			ctx.scratch_opp_caps.append(ctx.caps_by_peer.get(pid))


# Min over opponents of momentum-aware ETA back to our net — the shared
# race-home read behind every "am I recoverable?" question (SUPPORT's exposure,
# the forecheck safety's pinch read, CONTAIN's advance clamp). Each opponent
# races at ITS real top speed (Speed cap); INF when there are no opponents (no
# recovery threat).
static func min_opp_time_home(opp_states: Array[SkaterNetworkState],
		opp_caps: Array, our_net: Vector3) -> float:
	var has_caps: bool = opp_caps.size() == opp_states.size()
	var best: float = INF
	for i: int in opp_states.size():
		var s: SkaterNetworkState = opp_states[i]
		var ref_speed: float = AIActionScoring.SKATER_REF_SPEED_M_S
		if has_caps:
			var caps: AISkaterCaps = opp_caps[i]
			if caps != null:
				ref_speed = caps.max_speed
		var t: float = AIActionScoring.time_to_arrive(s.position, our_net, s.velocity, ref_speed)
		if t < best:
			best = t
	return best


# The farthest a defender may stand from OUR net and still win the race home
# against the fastest opponent: (fastest opp ETA home − the set-up margin) ×
# my top speed. The margin is braking from top speed (AISteering's brake
# decel) — the last man must arrive SET, not flying past his own cage. INF
# when there is no opponent to race. The single "how far can I safely be from
# home?" primitive shared by the forecheck safety and CONTAIN.
static func race_home_radius(ctx: RoleContext,
		opp_states: Array[SkaterNetworkState], our_net: Vector3) -> float:
	var t_home: float = min_opp_time_home(opp_states, ctx.scratch_opp_caps, our_net)
	if t_home == INF:
		return INF
	var margin: float = GameRules.DEFAULT_SKATER_MAX_SPEED_M_S 			/ AISteering.ARRIVAL_BRAKE_DECEL_M_S2
	return maxf(t_home - margin, 0.0) * maxf(ctx.self_max_speed, 1.0)


# Is the race to a loose puck already LOST — an opponent reaches it a clear
# contest-band ahead of me? Momentum-aware ETAs at each skater's real Speed
# cap, with the same physical contest margin the dump-chase race uses
# (CHASE_CONTEST_MARGIN_M, a stride's head-start): arriving inside that band
# still creates a live 50/50 (worth racing, the drive-through commits it);
# arriving clearly behind it means the collector has gathered and I'm just
# skating myself out of the play. A chaser that reads LOST should transition
# to defending the pickup instead of pushing (the missed-pass "third man keeps
# chasing while the counter develops" failure). False when no opponent
# threatens the puck.
static func loose_puck_race_lost(
		snapshot: WorldSnapshot, self_pos: Vector3, self_vel: Vector3,
		self_max_speed: float, team_id: int, team_id_by_peer: Dictionary,
		caps_by_peer: Dictionary) -> bool:
	if snapshot == null or snapshot.puck_state == null:
		return false
	var puck_pos: Vector3 = snapshot.puck_state.position
	var my_eta: float = AIActionScoring.time_to_arrive(
			self_pos, puck_pos, self_vel, maxf(self_max_speed, 1.0))
	var best_opp_eta: float = INF
	for pid: int in snapshot.skater_states:
		if team_id_by_peer.get(pid, -1) == team_id:
			continue
		var s: SkaterNetworkState = snapshot.skater_states[pid]
		var caps: AISkaterCaps = caps_by_peer.get(pid)
		var speed: float = caps.max_speed if caps != null \
				else AIActionScoring.SKATER_REF_SPEED_M_S
		var t: float = AIActionScoring.time_to_arrive(s.position, puck_pos, s.velocity, speed)
		if t < best_opp_eta:
			best_opp_eta = t
	if best_opp_eta == INF:
		return false
	var contest_window: float = AIActionScoring.CHASE_CONTEST_MARGIN_M \
			/ maxf(self_max_speed, 1.0)
	return my_eta > best_opp_eta + contest_window
