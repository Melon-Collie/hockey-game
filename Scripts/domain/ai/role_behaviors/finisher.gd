class_name AIRoleFinisher

# FINISHER role behavior (assigned to the BACKDOOR slot in the
# current possession-state shape — Phase 3 will rename the enum).
# The bot in front of the opp net reacts to incoming pucks heading
# at our offensive goal:
#
#   - HOLD if no incoming shot (slow puck, not heading at goal).
#   - STEP OUT if our teammate's shooting state is_elevated (the
#     puck will be in the air, our body could block it but the
#     blade can't reach).
#   - TIP otherwise (fast ground shot, on or off target — both are
#     deflection candidates).
#
# Stateless — every decision falls out of the current world state.
# Future phases will extend HOLD with an openness-search positioning
# pass that sweeps candidates around the anchor and picks the one
# with the highest position_potential, but the reactive logic stays
# event-driven.

# Speed gate: pucks slower than this are passes / rolling, not shots.
const INCOMING_SHOT_SPEED_M_S: float = 12.0

# Lateral step magnitude used to clear the puck path on STEP_OUT.
const STEP_OUT_M: float = 1.5


static func decide(ctx: RoleContext) -> RoleDecision:
	var d := RoleDecision.new()
	var puck_state: PuckNetworkState = ctx.snapshot.puck_state
	if puck_state == null:
		d.target_position = ctx.anchor
		return d

	var puck_pos: Vector3 = puck_state.position
	var puck_vel: Vector3 = puck_state.velocity
	var puck_speed: float = sqrt(puck_vel.x * puck_vel.x + puck_vel.z * puck_vel.z)

	# Speed gate: too slow → pass / rolling, hold anchor.
	if puck_speed < INCOMING_SHOT_SPEED_M_S:
		d.target_position = ctx.anchor
		return d

	# Direction gate: must be heading at our offensive goal.
	var opp_goal_z: float = -ctx.own_goal_dir * GameRules.GOAL_LINE_Z
	var to_goal_z: float = opp_goal_z - puck_pos.z
	if puck_vel.z * to_goal_z <= 0.0:
		d.target_position = ctx.anchor
		return d

	# Predict where puck path crosses our z plane (lateral anchor pos).
	# Bail when the puck is moving along the z plane (vel.z == 0) or
	# the crossing is in the past, or so far in the future that
	# tipping isn't viable.
	if absf(puck_vel.z) < 0.001:
		d.target_position = ctx.anchor
		return d
	var t_to_my_z: float = (ctx.self_pos.z - puck_pos.z) / puck_vel.z
	if t_to_my_z <= 0.0 or t_to_my_z > 2.0:
		d.target_position = ctx.anchor
		return d
	var path_x_at_my_z: float = puck_pos.x + puck_vel.x * t_to_my_z

	# Elevated check: read the most-recent shooter's `is_elevated` flag
	# directly from their network state. Cleaner than projecting puck
	# y velocity through gravity math. We use the closest teammate to
	# the puck as the proxy for "shooter" since once the puck is in
	# flight there's no carrier — but the bot that just released will
	# typically be the closest teammate.
	var shooter_is_elevated: bool = _last_shooter_is_elevated(ctx)

	if shooter_is_elevated:
		# STEP OUT — move laterally so our body isn't in the path of
		# the elevated shot. Blade can't reach an elevated puck so
		# tipping isn't an option here.
		var step_dir: float = signf(path_x_at_my_z - ctx.anchor.x)
		if step_dir == 0.0:
			step_dir = 1.0
		d.target_position = Vector3(
				ctx.anchor.x - step_dir * STEP_OUT_M,
				0.0,
				ctx.anchor.z)
		return d

	# Fast ground shot — TIP. Shift anchor onto the puck path at our
	# z plane, aim mouse at goal so the blade angles toward net for
	# a deflection / redirect. Works for both on-target shots
	# (steers the puck through a different angle past the goalie)
	# and off-target shots (redirects toward net).
	d.target_position = Vector3(path_x_at_my_z, 0.0, ctx.anchor.z)
	d.aim_world_pos = Vector3(0.0, 0.0, opp_goal_z)
	d.has_aim_override = true
	return d


# Returns the is_elevated flag of the most recent likely shooter on
# our team. Used to detect elevated shots without doing gravity math
# on the puck. We pick the closest teammate to the puck as the proxy
# — once the puck is in flight there's no carrier, but the bot that
# just released is typically still nearby.
static func _last_shooter_is_elevated(ctx: RoleContext) -> bool:
	if ctx.snapshot.puck_state == null:
		return false
	var puck_pos: Vector3 = ctx.snapshot.puck_state.position
	var best_pid: int = 0
	var best_d2: float = INF
	for pid: int in ctx.snapshot.skater_states:
		if int(ctx.team_id_resolver.call(pid)) != ctx.team_id:
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
	return ctx.snapshot.skater_states[best_pid].is_elevated
