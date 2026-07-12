extends GutTest

# PingRules — the smart-ping decision table (cursor target × possession →
# context message) and the obeyer election. Peers: 1 = pinger (team 0),
# 2 = bot teammate, 3/4 = opponents (team 1).

const PINGER: int = 1
const MATE: int = 2
const OPP_A: int = 3
const OPP_B: int = 4
const TEAM: int = 0

const TEAM_BY_PEER: Dictionary = {1: 0, 2: 0, 3: 1, 4: 1}

var _positions: Dictionary = {}


func before_each() -> void:
	_positions = {
		PINGER: Vector3(0.0, 0.0, 10.0),
		MATE: Vector3(5.0, 0.0, 0.0),
		OPP_A: Vector3(-5.0, 0.0, 0.0),
		OPP_B: Vector3(-5.0, 0.0, -8.0),
	}


func _resolve(cursor: Vector3, carrier: int,
		puck_pos: Vector3 = Vector3(0.0, 0.0, -15.0)) -> PingRules.Resolution:
	return PingRules.resolve(cursor, PINGER, TEAM, _positions, TEAM_BY_PEER,
			carrier, puck_pos)


# ── Decision table ───────────────────────────────────────────────────────────

func test_self_ping_while_teammate_carries_is_pass_to_me() -> void:
	var r: PingRules.Resolution = _resolve(_positions[PINGER], MATE)
	assert_eq(r.type, PingRules.Type.PASS_TO_ME)
	assert_eq(r.target_peer, PINGER)


func test_self_ping_with_loose_puck_is_im_open() -> void:
	var r: PingRules.Resolution = _resolve(_positions[PINGER], -1)
	assert_eq(r.type, PingRules.Type.IM_OPEN)


func test_self_ping_while_opponent_carries_is_im_open() -> void:
	var r: PingRules.Resolution = _resolve(_positions[PINGER], OPP_A)
	assert_eq(r.type, PingRules.Type.IM_OPEN)


func test_self_ping_while_self_carries_is_a_no_op() -> void:
	assert_null(_resolve(_positions[PINGER], PINGER))


func test_ping_carrying_teammate_is_shoot() -> void:
	var r: PingRules.Resolution = _resolve(_positions[MATE], MATE)
	assert_eq(r.type, PingRules.Type.SHOOT)
	assert_eq(r.target_peer, MATE)


func test_ping_teammate_while_pinger_carries_is_get_open() -> void:
	var r: PingRules.Resolution = _resolve(_positions[MATE], PINGER)
	assert_eq(r.type, PingRules.Type.GET_OPEN)
	assert_eq(r.target_peer, MATE)


func test_ping_teammate_with_loose_puck_is_directed_get_puck() -> void:
	var puck := Vector3(0.0, 0.0, -15.0)
	var r: PingRules.Resolution = _resolve(_positions[MATE], -1, puck)
	assert_eq(r.type, PingRules.Type.GET_PUCK)
	assert_eq(r.target_peer, MATE)
	assert_eq(r.world_pos, puck, "retrieval order carries the puck position")


func test_ping_teammate_while_opponents_carry_is_defend() -> void:
	var r: PingRules.Resolution = _resolve(_positions[MATE], OPP_A)
	assert_eq(r.type, PingRules.Type.DEFEND)
	assert_eq(r.target_peer, MATE)


func test_ping_opposing_carrier_is_pressure() -> void:
	var r: PingRules.Resolution = _resolve(_positions[OPP_A], OPP_A)
	assert_eq(r.type, PingRules.Type.PRESSURE_CARRIER)
	assert_eq(r.target_peer, OPP_A)


func test_ping_off_puck_opponent_is_cover_him() -> void:
	var r: PingRules.Resolution = _resolve(_positions[OPP_B], OPP_A)
	assert_eq(r.type, PingRules.Type.COVER_HIM)
	assert_eq(r.target_peer, OPP_B)


func test_ping_loose_puck_is_undirected_get_puck() -> void:
	var puck := Vector3(0.0, 0.0, -15.0)
	var r: PingRules.Resolution = _resolve(puck, -1, puck)
	assert_eq(r.type, PingRules.Type.GET_PUCK)
	assert_eq(r.target_peer, -1)


func test_carried_puck_resolves_through_its_carrier_not_the_puck() -> void:
	# Cursor on the carrier's body where the puck also is: the skater wins.
	var r: PingRules.Resolution = _resolve(_positions[MATE], MATE, _positions[MATE])
	assert_eq(r.type, PingRules.Type.SHOOT)


func test_bare_ice_is_go_there() -> void:
	var spot := Vector3(3.0, 0.0, -12.0)   # > PICK_RADIUS_M from everyone
	var r: PingRules.Resolution = _resolve(spot, MATE)
	assert_eq(r.type, PingRules.Type.GO_THERE)
	assert_almost_eq(r.world_pos.x, spot.x, 0.001)
	assert_almost_eq(r.world_pos.z, spot.z, 0.001)


func test_go_there_clamps_outside_the_boards_into_the_rink() -> void:
	var wild := Vector3(500.0, 0.0, -500.0)
	var r: PingRules.Resolution = _resolve(wild, MATE)
	assert_eq(r.type, PingRules.Type.GO_THERE)
	var inner: Vector2 = GameRules.clamp_to_rink_inner(Vector2(wild.x, wild.z))
	assert_almost_eq(r.world_pos.x, inner.x, 0.001)
	assert_almost_eq(r.world_pos.z, inner.y, 0.001)


func test_nearest_skater_wins_the_pick() -> void:
	_positions[OPP_A] = Vector3(5.0, 0.0, 1.5)   # near MATE at (5,0,0)
	var cursor := Vector3(5.0, 0.0, 1.0)          # 1.0 m to OPP_A, 1.0+ to MATE
	var r: PingRules.Resolution = _resolve(cursor, -1, Vector3(0, 0, -15))
	assert_eq(r.type, PingRules.Type.COVER_HIM)
	assert_eq(r.target_peer, OPP_A)


# ── Obeyer election ──────────────────────────────────────────────────────────

func _choose(type: int, target: int, pos: Vector3, carrier: int,
		bots: Array, puck_pos: Vector3 = Vector3(0.0, 0.0, -15.0)) -> int:
	return PingRules.choose_obeyer(type, target, pos, PINGER, carrier,
			puck_pos, bots, _positions)


func test_pass_pings_need_no_obeyer() -> void:
	assert_eq(_choose(PingRules.Type.PASS_TO_ME, PINGER, Vector3.ZERO, MATE, [MATE]), -1)
	assert_eq(_choose(PingRules.Type.IM_OPEN, PINGER, Vector3.ZERO, -1, [MATE]), -1)


func test_directed_pings_obey_only_when_the_target_is_a_bot() -> void:
	assert_eq(_choose(PingRules.Type.SHOOT, MATE, Vector3.ZERO, MATE, [MATE]), MATE)
	assert_eq(_choose(PingRules.Type.SHOOT, MATE, Vector3.ZERO, MATE, []), -1,
			"a human target gets the bubble, not a directive")
	assert_eq(_choose(PingRules.Type.GET_OPEN, MATE, Vector3.ZERO, PINGER, [MATE]), MATE)
	assert_eq(_choose(PingRules.Type.DEFEND, MATE, Vector3.ZERO, OPP_A, [MATE]), MATE)


func test_undirected_get_puck_elects_nearest_bot_to_the_puck() -> void:
	_positions[5] = Vector3(0.0, 0.0, -14.0)   # second bot, closest to the puck
	assert_eq(_choose(PingRules.Type.GET_PUCK, -1, Vector3.ZERO, -1, [MATE, 5]), 5)


func test_cover_him_elects_nearest_bot_to_the_pinged_opponent() -> void:
	_positions[5] = Vector3(-5.0, 0.0, -7.0)   # right next to OPP_B
	assert_eq(_choose(PingRules.Type.COVER_HIM, OPP_B, _positions[OPP_B], -1,
			[MATE, 5]), 5)


func test_go_there_never_conscripts_the_carrier() -> void:
	# MATE carries and is nearest to the spot; the other bot gets the order.
	_positions[5] = Vector3(20.0, 0.0, 10.0)
	var spot := Vector3(6.0, 0.0, 0.0)
	assert_eq(_choose(PingRules.Type.GO_THERE, -1, spot, MATE, [MATE, 5]), 5)


# ── Lookup tables ────────────────────────────────────────────────────────────

func test_every_type_has_a_message_and_duration() -> void:
	for t: int in PingRules.Type.values():
		assert_true(PingRules.message_for(t).length() > 0)
		assert_gt(PingRules.directive_duration_s(t), 0.0)


func test_type_validation_bounds() -> void:
	assert_true(PingRules.is_valid_type(PingRules.Type.PASS_TO_ME))
	assert_true(PingRules.is_valid_type(PingRules.Type.GO_THERE))
	assert_false(PingRules.is_valid_type(-1))
	assert_false(PingRules.is_valid_type(PingRules.Type.size()))
