class_name AIRoleOutlet

# OUTLET role behavior — TRANS_DO only. Stretch-pass option waiting
# at the opp blue line (NZ-side) for the breakout pass. Same
# candidate-set / score_pass argmax pattern as AIRoleSupport,
# minus the exposure half — OUTLET is intentionally up-ice and
# accepts being past the play. Defensive responsibility falls to
# SUPPORT (trail) on this team's strong-side rotation.
#
# Algorithm: argmax over the candidate set of
#
#     score_pass(carrier, candidate)
#
# Adds an offside filter: TRANS_DO is defined as "puck NZ-side of
# opp blue line" — any candidate past that line would ghost the
# bot until tag-up. Filter at the candidate level, before scoring.
#
# Step 2 of the no-anchors refactor: search center is derived from
# in-game references — opp blue line on the Z axis, mirrored puck X
# on the X axis (weak-side stretch position). The polar samples
# cover the full breakout-pass region; the offside filter rejects
# any sample that drifts past the blue line into OZ.

# Margin from the opp blue line that the search center sits on the
# NZ side. Sampling parameter — keeps most polar samples in legal
# territory; the offside filter is the actual game-rule guard.
const BLUE_LINE_BUFFER_M: float = 2.5

# Inset from the rink boards when mirroring puck X to weak side.
# Geometric — keeps OUTLET off the boards so polar samples don't
# all clamp against the wall.
const WEAK_SIDE_INSET_M: float = 2.0


static func decide(ctx: RoleContext) -> RoleDecision:
	var d := RoleDecision.new()

	var carrier_pos: Vector3 = AIRoleHelpers.resolve_teammate_carrier_pos(ctx)
	if not carrier_pos.is_finite():
		d.target_position = ctx.self_pos
		return d

	var goalie_pos: Vector3 = AIRoleHelpers.resolve_opp_goalie_pos(ctx)

	var opp_positions: Array[Vector3] = []
	var opp_states: Array[SkaterNetworkState] = []
	AIRoleHelpers.collect_opponents(ctx, opp_positions, opp_states)

	var teammate_positions: Array[Vector3] = AIRoleHelpers.collect_teammates_excluding_self(ctx)

	var search_center: Vector3 = _compute_search_center(ctx, carrier_pos)
	var candidates: Array[Vector3] = AIRoleHelpers.generate_candidates_around(
			ctx.self_pos, search_center)

	var best_pos: Vector3 = ctx.self_pos
	var best_score: float = -INF
	for c: Vector3 in candidates:
		if not AIRoleHelpers.is_legal_position(c):
			continue
		if _is_offside(c, ctx):
			continue
		if AIRoleHelpers.too_close_to_teammate(c, teammate_positions):
			continue
		# Match the speed our carrier would actually fire at — outlet
		# candidates are the long-pass receivers by definition (stretch
		# passes across zones), so this is exactly where the charged-
		# pass scoring matters most.
		var pass_speed: float = AIActionScoring.expected_pass_speed(carrier_pos, c)
		var score: float = AIActionScoring.score_pass(
				carrier_pos, c, ctx.attacking_goal_pos,
				goalie_pos, GameRules.NET_HALF_WIDTH,
				opp_positions, Vector3.INF, pass_speed)
		if score > best_score:
			best_score = score
			best_pos = c

	d.target_position = best_pos
	return d


# Search center for OUTLET: weak-side of carrier on the X axis,
# NZ-side of opp blue line on the Z axis. Pure in-game refs:
#   X = mirror of carrier X (weak-side stretch wing), clamped off
#       the boards by WEAK_SIDE_INSET_M.
#   Z = opp blue line offset toward our net by BLUE_LINE_BUFFER_M
#       (NZ-side, offside-safe by sampling).
# The polar samples around this point + the offside filter handle
# the actual positioning; this is just a sensible search center.
static func _compute_search_center(ctx: RoleContext,
		carrier_pos: Vector3) -> Vector3:
	var weak_x: float = clampf(-carrier_pos.x,
			-GameRules.RINK_HALF_WIDTH + WEAK_SIDE_INSET_M,
			GameRules.RINK_HALF_WIDTH - WEAK_SIDE_INSET_M)
	var z: float = -ctx.own_goal_dir * (GameRules.BLUE_LINE_Z - BLUE_LINE_BUFFER_M)
	return Vector3(weak_x, 0.0, z)


# Offside filter: in TRANS_DO the puck is NZ-side of opp blue line
# by definition. A candidate past that line would put OUTLET in OZ
# and trigger ghosting. Reject so the bot doesn't drift offside
# while waiting for the breakout to develop.
#
# Velocity-corrected: a candidate is "effectively offside" if the
# bot's projected position in SKATER_BRAKE_TIME_S given current
# velocity would already be past the line. This is what the user
# wants — target the line "RIGHT after the puck does." Bot moving
# fast toward opp net needs more buffer; bot at rest can sit right
# at the line. Pure kinematic — no behavioral knob.
static func _is_offside(c: Vector3, ctx: RoleContext) -> bool:
	var opp_blue_z: float = -ctx.own_goal_dir * GameRules.BLUE_LINE_Z
	var future_z: float = c.z + ctx.self_velocity.z * AIActionScoring.SKATER_BRAKE_TIME_S
	return -ctx.own_goal_dir * future_z > -ctx.own_goal_dir * opp_blue_z
