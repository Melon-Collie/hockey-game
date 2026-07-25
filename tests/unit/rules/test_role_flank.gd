extends GutTest

# AIRoleFlank — NEUTRAL only. Target = puck position offset laterally (sign
# per L/R) and slightly back toward our net, bounded by the race home.

const TEAM_ID: int = 0
const OUR_NET_Z: float = 26.65


func _make_ctx(self_pos: Vector3, puck_pos: Vector3) -> RoleContext:
	var snap := WorldSnapshot.new()
	var s := SkaterNetworkState.new()
	s.position = self_pos
	snap.skater_states[1] = s
	var puck := PuckNetworkState.new()
	puck.carrier_peer_id = -1
	puck.position = puck_pos
	snap.puck_state = puck

	var ctx := RoleContext.new()
	ctx.snapshot = snap
	ctx.self_pos = self_pos
	ctx.team_id = TEAM_ID
	ctx.peer_id = 1
	ctx.attacking_goal_pos = Vector3(0.0, 0.0, -OUR_NET_Z)
	ctx.defending_goal_pos = Vector3(0.0, 0.0, OUR_NET_Z)
	ctx.own_goal_dir = 1.0
	ctx.team_id_by_peer = {1: TEAM_ID}
	return ctx


func test_left_flank_target_is_left_and_back_of_puck() -> void:
	var puck_pos := Vector3(2, 0, -3)
	var ctx: RoleContext = _make_ctx(Vector3(0, 0, 0), puck_pos)
	var d: RoleDecision = AIRoleFlank.decide(ctx, -1.0)
	# Left = puck.x - LATERAL.
	assert_almost_eq(d.target_position.x,
			puck_pos.x - AIRoleFlank.FLANK_LATERAL_M, 0.01,
			"FLANK_L sits LATERAL_M to the left of puck")
	# Back toward our net (Team 0 our_net at +Z, own_goal_dir = +1).
	assert_almost_eq(d.target_position.z,
			puck_pos.z + AIRoleFlank.FLANK_DEPTH_M, 0.01,
			"FLANK_L sits DEPTH_M back toward our net")


func test_right_flank_target_is_right_and_back_of_puck() -> void:
	var puck_pos := Vector3(2, 0, -3)
	var ctx: RoleContext = _make_ctx(Vector3(0, 0, 0), puck_pos)
	var d: RoleDecision = AIRoleFlank.decide(ctx, 1.0)
	assert_almost_eq(d.target_position.x,
			puck_pos.x + AIRoleFlank.FLANK_LATERAL_M, 0.01,
			"FLANK_R sits LATERAL_M to the right of puck")
	assert_almost_eq(d.target_position.z,
			puck_pos.z + AIRoleFlank.FLANK_DEPTH_M, 0.01,
			"FLANK_R sits DEPTH_M back toward our net")


func test_falls_back_to_self_pos_when_no_puck_state() -> void:
	var self_pos := Vector3(0, 0, 0)
	var ctx: RoleContext = _make_ctx(self_pos, Vector3.ZERO)
	ctx.snapshot.puck_state = null
	var d: RoleDecision = AIRoleFlank.decide(ctx, -1.0)
	assert_eq(d.target_position, self_pos,
			"null puck_state → fall back to self_pos")


# ── Race-home bound: the flank is a shape, not a puck magnet ─────────────────

func _with_opponent(ctx: RoleContext, pos: Vector3, vel: Vector3) -> void:
	var opp := SkaterNetworkState.new()
	opp.position = pos
	opp.velocity = vel
	ctx.snapshot.skater_states[2] = opp
	ctx.team_id_by_peer[2] = 1 - TEAM_ID


func test_flank_holds_its_puck_side_shape_when_the_counter_is_contained() -> void:
	# Loose puck at centre with the only opponent stationary deep in HIS end,
	# and us goal-side of the play: his counter has the length of the rink to
	# run and we are home the whole way, so the shape is exactly the
	# puck-relative stand — the bound must not perturb ordinary play.
	var puck_pos := Vector3(0, 0, -2)
	var ctx: RoleContext = _make_ctx(Vector3(0, 0, 8), puck_pos)
	_with_opponent(ctx, Vector3(1, 0, -22), Vector3.ZERO)
	var d: RoleDecision = AIRoleFlank.decide(ctx, 1.0)
	assert_almost_eq(d.target_position.x,
			puck_pos.x + AIRoleFlank.FLANK_LATERAL_M, 0.01)
	assert_almost_eq(d.target_position.z,
			puck_pos.z + AIRoleFlank.FLANK_DEPTH_M, 0.01,
			"a contained counter leaves the flank shape untouched")


func test_flank_refuses_to_step_up_into_a_guaranteed_breakaway() -> void:
	# The reported puckwatching failure. Puck is deep in the attacking end, so
	# the raw shape puts this flank up past centre — while an opponent sits
	# BEHIND him, a stretch pass away from a clean run at our net. The old
	# target was the puck offset and nothing else, so he stepped up regardless.
	var puck_pos := Vector3(0, 0, -22)
	var ctx: RoleContext = _make_ctx(Vector3(0, 0, -18), puck_pos)
	_with_opponent(ctx, Vector3(1, 0, 14), Vector3(0, 0, 6))
	var raw_z: float = puck_pos.z + AIRoleFlank.FLANK_DEPTH_M
	var d: RoleDecision = AIRoleFlank.decide(ctx, 1.0)
	assert_gt(d.target_position.z, raw_z,
			"the last man sags home instead of following the puck up-ice")
