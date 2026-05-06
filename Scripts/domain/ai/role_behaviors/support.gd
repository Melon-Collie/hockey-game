class_name AIRoleSupport

# SUPPORT role behavior — OZONE + TRANS_DO. The off-puck teammate
# whose job is "be a pass option AND be in a recoverable position."
#
# Algorithm: argmax over a candidate set of
#
#     score_pass(carrier, candidate) × (1 - exposure(candidate))
#
# `score_pass` (existing AIActionScoring primitive) handles
# "available for a pass + good shot if I receive": it factors lane
# clearance from carrier through projected opponents and recursively
# evaluates the candidate's own future-action value via score_at.
#
# `exposure` is new — a foot-race-home consideration so SUPPORT
# doesn't get caught past the play. It compares my time back to our
# net (sprint speed from the candidate) against the fastest opp's
# momentum-aware ETA back to our net. If any opp can beat me home,
# the candidate is exposed; if I beat them all home, exposure is 0.
#
# No magic blends, no tuning bumps — both factors are real geometric
# / temporal quantities. Both fall out of existing AIActionScoring
# primitives (score_pass, time_to_arrive).
#
# State-agnostic: OZONE and TRANS_DO use the same scoring; only the
# anchor differs (set by AIRoleSlots.slot_anchor based on possession
# state).

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
const _POLAR_ANGLES: Array[float] = [
		0.0, PI * 0.25, PI * 0.5, PI * 0.75,
		PI, -PI * 0.75, -PI * 0.5, -PI * 0.25,
]


static func decide(ctx: RoleContext) -> RoleDecision:
	var d := RoleDecision.new()

	# Bail-out: no teammate carrier means there's no offensive
	# context to score against. Brain re-tick will re-route this peer
	# on the next physics frame; in the meantime fall back to anchor.
	var carrier_pos: Vector3 = _resolve_teammate_carrier_pos(ctx)
	if carrier_pos == Vector3.ZERO:
		d.target_position = ctx.anchor
		return d

	var our_net: Vector3 = ctx.defending_goal_pos
	var goalie_pos: Vector3 = _resolve_opp_goalie_pos(ctx)

	# Collect opponents once. Positions feed score_pass; full states
	# feed time_to_arrive (needs velocity for momentum-aware ETA).
	var opp_positions: Array[Vector3] = []
	var opp_states: Array[SkaterNetworkState] = []
	for pid: int in ctx.snapshot.skater_states:
		if int(ctx.team_id_resolver.call(pid)) != ctx.team_id:
			var s: SkaterNetworkState = ctx.snapshot.skater_states[pid]
			opp_positions.append(s.position)
			opp_states.append(s)

	var teammate_positions: Array[Vector3] = _collect_teammates_excluding_self(ctx)
	var min_opp_time_home: float = _min_opp_time_home(opp_states, our_net)

	var candidates: Array[Vector3] = _generate_candidates(ctx)

	var best_pos: Vector3 = ctx.anchor
	var best_score: float = -INF
	for c: Vector3 in candidates:
		if not _is_legal_position(c, ctx):
			continue
		if _too_close_to_teammate(c, teammate_positions):
			continue
		var pass_value: float = AIActionScoring.score_pass(
				carrier_pos, c, ctx.attacking_goal_pos,
				goalie_pos, GameRules.NET_HALF_WIDTH,
				opp_positions)
		var exposure: float = _exposure(c, our_net, min_opp_time_home)
		var score: float = pass_value * (1.0 - exposure)
		if score > best_score:
			best_score = score
			best_pos = c

	d.target_position = best_pos
	return d


# ── Helpers ──────────────────────────────────────────────────────────────────

# Returns the carrier's world position if a teammate carries the
# puck; Vector3.ZERO otherwise (signalling caller to fall back).
static func _resolve_teammate_carrier_pos(ctx: RoleContext) -> Vector3:
	if ctx.snapshot == null or ctx.snapshot.puck_state == null:
		return Vector3.ZERO
	var carrier_pid: int = ctx.snapshot.puck_state.carrier_peer_id
	if carrier_pid == -1:
		return Vector3.ZERO
	if int(ctx.team_id_resolver.call(carrier_pid)) != ctx.team_id:
		return Vector3.ZERO
	if not ctx.snapshot.skater_states.has(carrier_pid):
		return Vector3.ZERO
	return ctx.snapshot.skater_states[carrier_pid].position


# Opposing goalie's CURRENT position (not future-projected). v1
# uses the live position rather than the predict-at-receive-time
# math — score_pass differences across candidates are dominated
# by lane clearance + receiver geometry, so the goalie prediction
# error is roughly symmetric across candidates and doesn't change
# the argmax. Falls back to attacking goal mouth when goalie state
# isn't buffered yet.
static func _resolve_opp_goalie_pos(ctx: RoleContext) -> Vector3:
	var opp_team_id: int = 1 - ctx.team_id
	var goalie: GoalieNetworkState = ctx.snapshot.goalie_states.get(opp_team_id)
	if goalie == null:
		return ctx.attacking_goal_pos
	return Vector3(goalie.position_x, 0.0, goalie.position_z)


static func _collect_teammates_excluding_self(ctx: RoleContext) -> Array[Vector3]:
	var result: Array[Vector3] = []
	for pid: int in ctx.snapshot.skater_states:
		if pid == ctx.peer_id:
			continue
		if int(ctx.team_id_resolver.call(pid)) == ctx.team_id:
			result.append(ctx.snapshot.skater_states[pid].position)
	return result


# Min over opponents of momentum-aware ETA back to our net. INF
# when there are no opponents (no recovery threat).
static func _min_opp_time_home(opp_states: Array[SkaterNetworkState],
		our_net: Vector3) -> float:
	var best: float = INF
	for s: SkaterNetworkState in opp_states:
		var t: float = AIActionScoring.time_to_arrive(s.position, our_net, s.velocity)
		if t < best:
			best = t
	return best


# Candidate set: anchor + self + 8 polar samples around the anchor.
# Polar pattern is fixed-cardinal (0°, 45°, ..., 315°) rather than
# slot-oriented because SUPPORT has no obvious "forward" direction
# (unlike CARRIER which orients toward the slot).
static func _generate_candidates(ctx: RoleContext) -> Array[Vector3]:
	var result: Array[Vector3] = []
	result.append(ctx.anchor)
	result.append(ctx.self_pos)
	for angle: float in _POLAR_ANGLES:
		result.append(Vector3(
				ctx.anchor.x + SEARCH_STEP_M * cos(angle),
				0.0,
				ctx.anchor.z + SEARCH_STEP_M * sin(angle)))
	return result


# Rejects candidates outside the playable rink, in either crease,
# or past either goal line.
static func _is_legal_position(c: Vector3, ctx: RoleContext) -> bool:
	if absf(c.x) > GameRules.RINK_HALF_WIDTH - RINK_INSET_M:
		return false
	# Both goal lines: |c.z| > GOAL_LINE_Z - buffer rejects positions
	# past EITHER goal line (own or attacking).
	if absf(c.z) > GameRules.GOAL_LINE_Z - GOAL_LINE_BUFFER_M:
		return false
	if CreaseRules.is_in_crease(Vector2(c.x, c.z)):
		return false
	return true


static func _too_close_to_teammate(c: Vector3,
		teammate_positions: Array[Vector3]) -> bool:
	var r2: float = ANTI_CROWD_RADIUS_M * ANTI_CROWD_RADIUS_M
	for tp: Vector3 in teammate_positions:
		var dx: float = c.x - tp.x
		var dz: float = c.z - tp.z
		if dx * dx + dz * dz < r2:
			return true
	return false


# Foot-race-home exposure. 0 when I beat every opp back to our net;
# scales upward as my ETA exceeds the fastest opp's. Floored at 0,
# unbounded above — letting the (1 - exposure) factor go negative
# naturally rejects candidates I can't recover from.
#
# `min_opp_time_home` is precomputed once per decide() since it's
# candidate-independent.
static func _exposure(candidate: Vector3, our_net: Vector3,
		min_opp_time_home: float) -> float:
	# Tiny epsilon prevents division-by-zero in the (rare) case
	# where an opp is sitting on top of our goal — at that point
	# any positive my_time produces enormous exposure, candidate
	# rejected. Behaves correctly without a magic upper cap.
	var safe_time: float = maxf(min_opp_time_home, 0.001)
	var dist: float = candidate.distance_to(our_net)
	var my_time: float = dist / AIActionScoring.SKATER_REF_SPEED_M_S
	return maxf(my_time / safe_time - 1.0, 0.0)
