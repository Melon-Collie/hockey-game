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
# `exposure` is the foot-race-home consideration so SUPPORT doesn't
# get caught past the play. Compares my sprint ETA to our net against
# the fastest opp's momentum-aware ETA via time_to_arrive. Floored
# at 0; the (1 - exposure) factor goes negative when opps clearly
# beat me home, naturally rejecting unrecoverable candidates.
#
# Step 2 of the no-anchors refactor: search center is derived from
# in-game references (the carrier's position) rather than read from
# ctx.anchor. Polar samples around the carrier let the score
# function find the right "trail" position — exposure penalizes
# candidates ahead of the carrier (toward opp net), so argmax
# converges on positions behind/beside the carrier toward our net.
# The "trail" direction emerges from the math, not from a hand-coded
# weak-side bias.

# Polar sampling radius around the search center. Same scale as
# AIRoleCarrier.CARRY_SEARCH_STEP_M (3.0 m) — sampling parameter,
# not a behavioral knob. The carrier itself is excluded by the
# anti-crowding filter; samples at the rim of the circle remain.
const SEARCH_RADIUS_M: float = 5.0


static func decide(ctx: RoleContext) -> RoleDecision:
	var d := RoleDecision.new()

	# Bail-out: no teammate carrier means there's no offensive
	# context to score against. Brain re-tick will re-route this peer
	# on the next physics frame; in the meantime hold position.
	var carrier_pos: Vector3 = AIRoleHelpers.resolve_teammate_carrier_pos(ctx)
	if not carrier_pos.is_finite():
		d.target_position = ctx.self_pos
		return d

	var our_net: Vector3 = ctx.defending_goal_pos
	var goalie_pos: Vector3 = AIRoleHelpers.resolve_opp_goalie_pos(ctx)

	var opp_positions: Array[Vector3] = []
	var opp_states: Array[SkaterNetworkState] = []
	AIRoleHelpers.collect_opponents(ctx, opp_positions, opp_states)

	var teammate_positions: Array[Vector3] = AIRoleHelpers.collect_teammates_excluding_self(ctx)
	var min_opp_time_home: float = _min_opp_time_home(opp_states, our_net)

	# Search around the carrier. Polar samples cover the cycle space;
	# anti-crowd filter rejects the carrier-overlap candidate.
	var candidates: Array[Vector3] = _generate_candidates(ctx, carrier_pos)

	var best_pos: Vector3 = ctx.self_pos
	var best_score: float = -INF
	for c: Vector3 in candidates:
		if not AIRoleHelpers.is_legal_position(c):
			continue
		if AIRoleHelpers.too_close_to_teammate(c, teammate_positions):
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


# ── Candidate generation (in-game-ref) ──────────────────────────────────────

# 8 polar samples at SEARCH_RADIUS_M around the carrier, plus self
# (stand-still) and the carrier's own position (which the anti-crowd
# filter rejects but is included for symmetry with other roles).
# No "search center" or "trail depth" formulas — the carrier is the
# ref, and the score function picks the best direction.
static func _generate_candidates(ctx: RoleContext, carrier_pos: Vector3) -> Array[Vector3]:
	var result: Array[Vector3] = []
	result.append(carrier_pos)
	result.append(ctx.self_pos)
	for angle: float in AIRoleHelpers.POLAR_ANGLES:
		result.append(Vector3(
				carrier_pos.x + SEARCH_RADIUS_M * cos(angle),
				0.0,
				carrier_pos.z + SEARCH_RADIUS_M * sin(angle)))
	return result


# ── Role-specific scoring ────────────────────────────────────────────────────

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


# Foot-race-home exposure in [0, 1]. 0 when I beat every opp back
# to our net; ramps to 1 (full unrecoverable) as my ETA exceeds the
# fastest opp's. CLAMPED to 1 so (1 - exposure) stays non-negative —
# without the upper clamp, the factor goes negative for deeply-
# exposed candidates, and multiplying score_pass by a large negative
# INVERTS the argmax preference (small pass_value × large negative
# wins over big pass_value × less-negative, picking the most exposed
# candidate). Clamp pushes all-exposed-equally candidates to score 0
# so the loop falls back to self_pos.
static func _exposure(candidate: Vector3, our_net: Vector3,
		min_opp_time_home: float) -> float:
	var safe_time: float = maxf(min_opp_time_home, 0.001)
	var dist: float = candidate.distance_to(our_net)
	var my_time: float = dist / AIActionScoring.SKATER_REF_SPEED_M_S
	return clampf(my_time / safe_time - 1.0, 0.0, 1.0)
