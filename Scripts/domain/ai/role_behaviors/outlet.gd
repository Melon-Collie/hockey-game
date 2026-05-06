class_name AIRoleOutlet

# OUTLET role behavior — TRANS_DO only. Stretch-pass option waiting
# at the opp blue line (NZ-side) for the breakout pass. Same
# candidate-set / score_pass argmax pattern as AIRoleSupport,
# minus the exposure half — OUTLET is intentionally up-ice and
# accepts being past the play. Defensive responsibility falls to
# SUPPORT (trail) on this team's strong-side rotation.
#
# Algorithm: argmax over the standard off-puck candidate set of
#
#     score_pass(carrier, candidate)
#
# Adds an offside filter: TRANS_DO is defined as "puck NZ-side of
# opp blue line" — any candidate past that line would ghost the
# bot until tag-up. Filter at the candidate level, before scoring.
#
# Candidate generation, legality, anti-crowding, and context
# resolution live in AIRoleHelpers.

static func decide(ctx: RoleContext) -> RoleDecision:
	var d := RoleDecision.new()

	var carrier_pos: Vector3 = AIRoleHelpers.resolve_teammate_carrier_pos(ctx)
	if carrier_pos == Vector3.ZERO:
		d.target_position = ctx.anchor
		return d

	var goalie_pos: Vector3 = AIRoleHelpers.resolve_opp_goalie_pos(ctx)

	var opp_positions: Array[Vector3] = []
	var opp_states: Array[SkaterNetworkState] = []
	AIRoleHelpers.collect_opponents(ctx, opp_positions, opp_states)

	var teammate_positions: Array[Vector3] = AIRoleHelpers.collect_teammates_excluding_self(ctx)
	var candidates: Array[Vector3] = AIRoleHelpers.generate_candidates(ctx)

	var best_pos: Vector3 = ctx.anchor
	var best_score: float = -INF
	for c: Vector3 in candidates:
		if not AIRoleHelpers.is_legal_position(c):
			continue
		if _is_offside(c, ctx):
			continue
		if AIRoleHelpers.too_close_to_teammate(c, teammate_positions):
			continue
		var score: float = AIActionScoring.score_pass(
				carrier_pos, c, ctx.attacking_goal_pos,
				goalie_pos, GameRules.NET_HALF_WIDTH,
				opp_positions)
		if score > best_score:
			best_score = score
			best_pos = c

	d.target_position = best_pos
	return d


# Offside filter: in TRANS_DO the puck is NZ-side of opp blue line
# by definition. A candidate past that line would put OUTLET in OZ
# and trigger ghosting (can't interact with the puck until tag-up).
# Reject so the bot doesn't drift offside while waiting for the
# breakout to develop.
#
# `own_goal_dir` is +1 for Team 0 (defends +Z, attacks -Z) and -1
# for Team 1. Opp blue line = -own_goal_dir * BLUE_LINE_Z.
# "Past" = on the OZ side, equivalent to checking
# `-own_goal_dir * c.z > -own_goal_dir * opp_blue_z`.
static func _is_offside(c: Vector3, ctx: RoleContext) -> bool:
	var opp_blue_z: float = -ctx.own_goal_dir * GameRules.BLUE_LINE_Z
	return -ctx.own_goal_dir * c.z > -ctx.own_goal_dir * opp_blue_z
