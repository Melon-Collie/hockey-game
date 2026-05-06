class_name AIRoleOutlet

# OUTLET role behavior — TRANS_DO only. Stretch-pass option waiting
# at the opp blue line (NZ-side) for the breakout pass. Same
# candidate-set / score_pass argmax pattern as AIRoleSupport,
# minus the exposure half — OUTLET is intentionally up-ice and
# accepts being past the play. Defensive responsibility falls to
# SUPPORT (trail) on this team's strong-side rotation.
#
# Algorithm: argmax over a candidate set of
#
#     score_pass(carrier, candidate)
#
# The single existing AIActionScoring primitive captures everything
# OUTLET cares about: lane clearance from carrier (defenders in the
# stretch lane zero this out), recursive future-action value at the
# candidate (better shot / closer to goal → higher score), and
# time-decay over flight time.
#
# Adds an offside filter: TRANS_DO is defined as "puck NZ-side of
# opp blue line" — any candidate past that line would ghost the
# bot until tag-up. Filter at the candidate level, before scoring.

# Search radius around the anchor for polar candidate generation.
# Same scale as AIRoleCarrier.CARRY_SEARCH_STEP_M.
const SEARCH_STEP_M: float = 3.0

# Physical-overlap distance for the anti-crowding filter.
const ANTI_CROWD_RADIUS_M: float = 1.8

# Margin from the rink boards / goal lines.
const RINK_INSET_M: float = 0.5
const GOAL_LINE_BUFFER_M: float = 1.0

# Pre-baked rotations for the 8 polar cardinal candidates.
const _POLAR_ANGLES: Array[float] = [
		0.0, PI * 0.25, PI * 0.5, PI * 0.75,
		PI, -PI * 0.75, -PI * 0.5, -PI * 0.25,
]


static func decide(ctx: RoleContext) -> RoleDecision:
	var d := RoleDecision.new()

	# Bail-out: no teammate carrier means no offensive context. Brain
	# re-tick will reassign roles on the next physics frame; in the
	# meantime fall back to anchor.
	var carrier_pos: Vector3 = _resolve_teammate_carrier_pos(ctx)
	if carrier_pos == Vector3.ZERO:
		d.target_position = ctx.anchor
		return d

	var goalie_pos: Vector3 = _resolve_opp_goalie_pos(ctx)

	var opp_positions: Array[Vector3] = []
	for pid: int in ctx.snapshot.skater_states:
		if int(ctx.team_id_resolver.call(pid)) != ctx.team_id:
			opp_positions.append(ctx.snapshot.skater_states[pid].position)

	var teammate_positions: Array[Vector3] = _collect_teammates_excluding_self(ctx)

	var candidates: Array[Vector3] = _generate_candidates(ctx)

	var best_pos: Vector3 = ctx.anchor
	var best_score: float = -INF
	for c: Vector3 in candidates:
		if not _is_legal_position(c, ctx):
			continue
		if _is_offside(c, ctx):
			continue
		if _too_close_to_teammate(c, teammate_positions):
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


# ── Helpers ──────────────────────────────────────────────────────────────────
# Mirror AIRoleSupport's helpers verbatim — once a third role module
# (PRESSURE) lands with the same shape, extract into a shared base.

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


static func _is_legal_position(c: Vector3, ctx: RoleContext) -> bool:
	if absf(c.x) > GameRules.RINK_HALF_WIDTH - RINK_INSET_M:
		return false
	if absf(c.z) > GameRules.GOAL_LINE_Z - GOAL_LINE_BUFFER_M:
		return false
	if CreaseRules.is_in_crease(Vector2(c.x, c.z)):
		return false
	return true


# Offside filter: in TRANS_DO the puck is NZ-side of opp blue line
# by definition. A candidate past that line would put OUTLET in OZ
# and trigger ghosting (can't interact with the puck until tag-up).
# Reject so the bot doesn't drift offside while waiting for the
# breakout to develop.
#
# `own_goal_dir` is +1 for Team 0 (defends +Z, attacks -Z) and -1
# for Team 1. Opp blue line = -own_goal_dir * BLUE_LINE_Z.
# "Past" = on the OZ side, which is sign(-own_goal_dir) — equivalent
# to checking `-own_goal_dir * c.z > -own_goal_dir * opp_blue_z`.
static func _is_offside(c: Vector3, ctx: RoleContext) -> bool:
	var opp_blue_z: float = -ctx.own_goal_dir * GameRules.BLUE_LINE_Z
	return -ctx.own_goal_dir * c.z > -ctx.own_goal_dir * opp_blue_z


static func _too_close_to_teammate(c: Vector3,
		teammate_positions: Array[Vector3]) -> bool:
	var r2: float = ANTI_CROWD_RADIUS_M * ANTI_CROWD_RADIUS_M
	for tp: Vector3 in teammate_positions:
		var dx: float = c.x - tp.x
		var dz: float = c.z - tp.z
		if dx * dx + dz * dz < r2:
			return true
	return false
