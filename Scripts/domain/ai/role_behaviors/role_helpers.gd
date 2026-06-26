class_name AIRoleHelpers

# Shared helpers for off-puck role behaviors. Every role that picks
# a position via candidate-set argmax (SUPPORT, OUTLET, FINISHER, and
# the upcoming defensive roles PRESSURE / ANCHOR / COVER) uses the
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
static func generate_candidates_around(self_pos: Vector3,
		center: Vector3) -> Array[Vector3]:
	var result: Array[Vector3] = []
	result.append(center)
	result.append(self_pos)
	for angle: float in POLAR_ANGLES:
		result.append(Vector3(
				center.x + SEARCH_STEP_M * cos(angle),
				0.0,
				center.z + SEARCH_STEP_M * sin(angle)))
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


# ── Man-on-threat coverage ───────────────────────────────────────────────────

# Shared "cover this assigned man" target for the backline defenders
# (ANCHOR / COVER) when TeamBrain's threat partition hands them a specific
# opponent. Picks the position that most deflates the carrier→man pass-threat
# surface (lane interception × the man's resulting shot), searching a candidate
# set centered on the midpoint between the man and our net — i.e. set up
# goal-side of him, in the feed lane, to kill the one-timer.
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

	var search_center: Vector3 = (man_pos + our_net) * 0.5
	var candidates: Array[Vector3] = generate_candidates_around(ctx.self_pos, search_center)

	var best_pos: Vector3 = ctx.self_pos
	var best_score: float = -INF
	for c: Vector3 in candidates:
		if not is_legal_position(c):
			continue
		if too_close_to_teammate(c, teammates):
			continue
		# Carrier's view of defenders: our team + us hypothetically at c.
		var defenders: Array[Vector3] = teammates.duplicate()
		defenders.append(c)
		# Minimize the carrier's threat of feeding THIS man (lane × his shot).
		var threat: float = AIActionScoring.threat_surface_pass(
				carrier_pos, man_pos, our_net, our_goalie_pos,
				GameRules.NET_HALF_WIDTH, defenders)
		var score: float = -threat
		if score > best_score:
			best_score = score
			best_pos = c
	return best_pos


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
	var carrier: SkaterNetworkState = ctx.snapshot.skater_states[carrier_pid]
	return AIBodyCheck.evaluate(
			ctx.self_pos, ctx.self_max_speed, ctx.self_weight,
			ctx.self_body_check_transfer, ctx.self_stagger_timer,
			carrier.position, carrier.velocity)


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


# Defensive roles (PRESSURE, CONTAIN, COVER): prefer whoever carries the
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
		out: Array[Vector3]) -> void:
	out.clear()
	var carrier_pid: int = -1
	if ctx.snapshot != null and ctx.snapshot.puck_state != null:
		carrier_pid = ctx.snapshot.puck_state.carrier_peer_id
	for pid: int in ctx.snapshot.skater_states:
		if ctx.team_id_by_peer.get(pid, -1) == ctx.team_id:
			continue  # our team
		if pid == carrier_pid:
			continue
		out.append(ctx.snapshot.skater_states[pid].position)


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
		out_states: Array[SkaterNetworkState]) -> void:
	out_positions.clear()
	out_states.clear()
	for pid: int in ctx.snapshot.skater_states:
		if ctx.team_id_by_peer.get(pid, -1) != ctx.team_id:
			var s: SkaterNetworkState = ctx.snapshot.skater_states[pid]
			out_positions.append(s.position)
			out_states.append(s)
