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
# State-agnostic: OZONE and TRANS_DO use the same scoring; only the
# anchor differs (set by AIRoleSlots.slot_anchor based on possession
# state). Candidate generation, legality filters, anti-crowding,
# and context-resolution helpers live in AIRoleHelpers.

static func decide(ctx: RoleContext) -> RoleDecision:
	var d := RoleDecision.new()

	# Bail-out: no teammate carrier means there's no offensive
	# context to score against. Brain re-tick will re-route this peer
	# on the next physics frame; in the meantime fall back to anchor.
	var carrier_pos: Vector3 = AIRoleHelpers.resolve_teammate_carrier_pos(ctx)
	if carrier_pos == Vector3.ZERO:
		d.target_position = ctx.anchor
		return d

	var our_net: Vector3 = ctx.defending_goal_pos
	var goalie_pos: Vector3 = AIRoleHelpers.resolve_opp_goalie_pos(ctx)

	var opp_positions: Array[Vector3] = []
	var opp_states: Array[SkaterNetworkState] = []
	AIRoleHelpers.collect_opponents(ctx, opp_positions, opp_states)

	var teammate_positions: Array[Vector3] = AIRoleHelpers.collect_teammates_excluding_self(ctx)
	var min_opp_time_home: float = _min_opp_time_home(opp_states, our_net)

	var candidates: Array[Vector3] = AIRoleHelpers.generate_candidates(ctx)

	var best_pos: Vector3 = ctx.anchor
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
