extends GutTest

# AIRoleFlank — NEUTRAL only. Target = puck position offset laterally (sign
# per L/R) and slightly back toward our net, bounded by the numbers read.

const TEAM_ID: int = 0
const OUR_NET_Z: float = 26.65


# `home_mate` parks a teammate on our own goal line. It is ON by default because
# the flank only holds its puck-side shape while somebody is HOME BEHIND IT
# (AIRoleHelpers.home_layer_behind_me) — a flank that is the last man back is the
# layer and takes the layer's stand instead, which is the whole point of that
# read. So a fixture about the SHAPE has to say somebody else is home; without
# one the only bot on the ice is trivially the last man and every case below
# would be reading the layer bound rather than the geometry under it.
func _make_ctx(self_pos: Vector3, puck_pos: Vector3,
		home_mate: bool = true) -> RoleContext:
	var snap := WorldSnapshot.new()
	var s := SkaterNetworkState.new()
	s.position = self_pos
	snap.skater_states[1] = s
	var team_map: Dictionary = {1: TEAM_ID}
	if home_mate:
		var mate := SkaterNetworkState.new()
		mate.position = Vector3(0.0, 0.0, OUR_NET_Z)
		snap.skater_states[3] = mate
		team_map[3] = TEAM_ID
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
	ctx.team_id_by_peer = team_map
	return ctx


# The same fixture with the LIVE transition read the brain hands production
# dispatch. The last-man bound (AIRoleHelpers.neutral_station_target) needs real
# perception — who is an attacker and who is behind the stand — and an unwired
# read deliberately reports "nobody told me anything" and holds the geometry,
# so a fixture that wants to exercise the bound has to supply it.
func _with_read(ctx: RoleContext) -> RoleContext:
	var read := AIRushRead.new()
	read.fill(ctx.snapshot, TEAM_ID, OUR_NET_Z, ctx.team_id_by_peer, {}, {})
	ctx.rush_read = read
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


# ── Last-man bound: the flank is a shape, not a puck magnet ──────────────────

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
	var d: RoleDecision = AIRoleFlank.decide(_with_read(ctx), 1.0)
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
	# The lurker is kept ONSIDE (our side of the blue line, but not past it):
	# a body parked deeper than that couldn't legally take the feed, and the
	# shared read drops him for exactly that reason.
	var puck_pos := Vector3(0, 0, -22)
	# No home mate: this case is about the LAST MAN, and a body on our goal line
	# would make him not one (has_support_behind).
	var ctx: RoleContext = _make_ctx(Vector3(0, 0, -18), puck_pos, false)
	_with_opponent(ctx, Vector3(1, 0, 5), Vector3(0, 0, 6))
	var raw_z: float = puck_pos.z + AIRoleFlank.FLANK_DEPTH_M
	var d: RoleDecision = AIRoleFlank.decide(_with_read(ctx), 1.0)
	assert_gt(d.target_position.z, raw_z,
			"the last man sags home instead of following the puck up-ice")


# ── The numbers half: "if they win this puck, is anybody home?" ──────────────

func test_the_last_man_back_holds_the_layer_instead_of_the_puck_side_shape() -> void:
	# The reported neutral-zone failure, and the one the reactive half above
	# cannot see: nobody is behind anybody yet — both teams are converging on a
	# loose puck — so "has a man got behind me" reads clear for every station and
	# the whole shape steps up together. Here this flank is the only body home, so
	# stepping up to the puck-side stand leaves the house to nobody.
	var puck_pos := Vector3(0, 0, -6)
	var ctx: RoleContext = _make_ctx(Vector3(0, 0, 10), puck_pos, false)
	_with_opponent(ctx, Vector3(2, 0, -8), Vector3(0, 0, 2))
	var d: RoleDecision = AIRoleFlank.decide(_with_read(ctx), 1.0)
	assert_gt(d.target_position.z, puck_pos.z + AIRoleFlank.FLANK_DEPTH_M,
			"the last man back followed the puck up-ice anyway")
	assert_false(d.held_forward_stand,
			"the layer must not report holding its forward stand")


func test_a_teammate_home_behind_me_frees_the_flank_to_hold_its_shape() -> void:
	# The antisymmetric half: the read is strictly "is somebody DEEPER than me",
	# which the deepest body cannot answer yes to — so the two flanks can never
	# each appoint the other and both step up. Same geometry as above with a mate
	# on the goal line, and this flank is free to play the puck-side shape.
	var puck_pos := Vector3(0, 0, -6)
	var ctx: RoleContext = _make_ctx(Vector3(0, 0, 10), puck_pos)
	_with_opponent(ctx, Vector3(2, 0, -8), Vector3(0, 0, 2))
	var d: RoleDecision = AIRoleFlank.decide(_with_read(ctx), 1.0)
	assert_almost_eq(d.target_position.z,
			puck_pos.z + AIRoleFlank.FLANK_DEPTH_M, 0.01,
			"a flank with a layer behind it plays the shape")
