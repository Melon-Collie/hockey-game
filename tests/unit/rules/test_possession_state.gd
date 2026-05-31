extends GutTest

# AIPossessionState is pure-function. Tests verify the 4-state table
# and sticky-possession (loose puck retains last team).

# Team 0 defends +Z (own_net_z = +26.65), attacks -Z.
const OUR_NET_Z: float = 26.65
const TEAM_ID: int = 0


func _make_snapshot(carrier_pid: int, puck_z: float,
		skaters: Array = [[100, 0], [200, 1]],
		puck_velocity: Vector3 = Vector3.ZERO) -> WorldSnapshot:
	# skaters: Array of [peer_id, team_id]. Position is unused by
	# possession_state — it only reads puck_state.position.z.
	var snap := WorldSnapshot.new()
	for entry: Array in skaters:
		var s := SkaterNetworkState.new()
		s.position = Vector3.ZERO
		snap.skater_states[entry[0]] = s
	var puck := PuckNetworkState.new()
	puck.carrier_peer_id = carrier_pid
	puck.position = Vector3(0.0, 0.0, puck_z)
	puck.velocity = puck_velocity
	snap.puck_state = puck
	return snap


func _resolver(skaters: Array) -> Dictionary:
	var team_map: Dictionary = {}
	for entry: Array in skaters:
		team_map[entry[0]] = entry[1]
	return team_map


func test_dzone_when_opp_carries_in_our_dz() -> void:
	# Opp (peer 200, team 1) holds the puck deep in our DZ (z > BLUE_LINE_Z).
	var snap := _make_snapshot(200, 22.0)
	var result: AIPossessionState.Result = AIPossessionState.compute(
			snap, TEAM_ID, OUR_NET_Z,
			_resolver([[100, 0], [200, 1]]), -1)
	assert_eq(result.state, AIPossessionState.State.DZONE)
	assert_eq(result.carrier_team, 1, "carrier_team is 1")


func test_ozone_when_we_carry_in_their_dz() -> void:
	var snap := _make_snapshot(100, -22.0)
	var result: AIPossessionState.Result = AIPossessionState.compute(
			snap, TEAM_ID, OUR_NET_Z,
			_resolver([[100, 0], [200, 1]]), -1)
	assert_eq(result.state, AIPossessionState.State.OZONE)


func test_trans_do_when_we_carry_in_neutral_zone() -> void:
	# Our possession in NZ (puck between the blue lines) → rush.
	var snap := _make_snapshot(100, 0.0)
	var result: AIPossessionState.Result = AIPossessionState.compute(
			snap, TEAM_ID, OUR_NET_Z,
			_resolver([[100, 0], [200, 1]]), -1)
	assert_eq(result.state, AIPossessionState.State.TRANS_DO)


func test_breakout_when_we_carry_in_our_own_dz() -> void:
	# Our possession deep in our OWN DZ (puck_z > BLUE_LINE_Z) → BREAKOUT,
	# not TRANS_DO. This is the case the new state carves out.
	var snap := _make_snapshot(100, 22.0)
	var result: AIPossessionState.Result = AIPossessionState.compute(
			snap, TEAM_ID, OUR_NET_Z,
			_resolver([[100, 0], [200, 1]]), -1)
	assert_eq(result.state, AIPossessionState.State.BREAKOUT,
			"our possession in our own DZ is a breakout, not a NZ rush")
	assert_eq(result.carrier_team, 0)


func test_trans_od_when_opp_carries_outside_our_dz() -> void:
	var snap := _make_snapshot(200, 0.0)
	var result: AIPossessionState.Result = AIPossessionState.compute(
			snap, TEAM_ID, OUR_NET_Z,
			_resolver([[100, 0], [200, 1]]), -1)
	assert_eq(result.state, AIPossessionState.State.TRANS_OD)


func test_loose_puck_keeps_last_carrier_team() -> void:
	# Puck was held by team 1, now loose at speed (just stripped or in
	# flight). State driven by sticky possession. Velocity above
	# NEUTRAL_PUCK_SPEED_M_S so the slow-puck NEUTRAL override doesn't
	# fire — fresh strips and in-flight passes have meaningful speed.
	var snap := _make_snapshot(-1, 5.0, [[100, 0], [200, 1]],
			Vector3(0.0, 0.0, -8.0))  # 8 m/s, well above 1 m/s threshold
	var result: AIPossessionState.Result = AIPossessionState.compute(
			snap, TEAM_ID, OUR_NET_Z,
			_resolver([[100, 0], [200, 1]]), 1)  # prev was team 1
	assert_eq(result.state, AIPossessionState.State.TRANS_OD,
			"loose puck inherits last carrier's team — opp possession in NZ")
	assert_eq(result.carrier_team, 1, "carrier_team stays at 1 (sticky)")


func test_loose_puck_in_our_dz_with_sticky_opp_is_dzone() -> void:
	var snap := _make_snapshot(-1, 22.0)  # loose, in our DZ
	var result: AIPossessionState.Result = AIPossessionState.compute(
			snap, TEAM_ID, OUR_NET_Z,
			_resolver([[100, 0], [200, 1]]), 1)
	assert_eq(result.state, AIPossessionState.State.DZONE)


func test_carrier_change_updates_team() -> void:
	# Opp carrier → carrier_team flips.
	var snap := _make_snapshot(200, 0.0)
	var result: AIPossessionState.Result = AIPossessionState.compute(
			snap, TEAM_ID, OUR_NET_Z,
			_resolver([[100, 0], [200, 1]]), 0)  # prev was us
	assert_eq(result.carrier_team, 1, "new carrier flips carrier_team")


func test_is_transition_helper() -> void:
	assert_true(AIPossessionState.is_transition(AIPossessionState.State.TRANS_DO))
	assert_true(AIPossessionState.is_transition(AIPossessionState.State.TRANS_OD))
	assert_false(AIPossessionState.is_transition(AIPossessionState.State.DZONE))
	assert_false(AIPossessionState.is_transition(AIPossessionState.State.OZONE))
	assert_false(AIPossessionState.is_transition(AIPossessionState.State.NEUTRAL))
	assert_false(AIPossessionState.is_transition(AIPossessionState.State.BREAKOUT))


func test_neutral_when_loose_puck_stationary() -> void:
	# Faceoff drop scenario — puck loose at center, near-zero velocity.
	var snap := _make_snapshot(-1, 0.0)
	snap.puck_state.velocity = Vector3.ZERO
	var result: AIPossessionState.Result = AIPossessionState.compute(
			snap, TEAM_ID, OUR_NET_Z,
			_resolver([[100, 0], [200, 1]]), 1)
	assert_eq(result.state, AIPossessionState.State.NEUTRAL,
			"loose stationary puck should be NEUTRAL regardless of prev possession")


func test_not_neutral_when_loose_puck_moving_fast() -> void:
	# Pass in flight — puck loose but moving fast. Should keep TRANS state.
	var snap := _make_snapshot(-1, 0.0)
	snap.puck_state.velocity = Vector3(20.0, 0.0, 0.0)  # 20 m/s pass
	var result: AIPossessionState.Result = AIPossessionState.compute(
			snap, TEAM_ID, OUR_NET_Z,
			_resolver([[100, 0], [200, 1]]), 0)  # we passed it
	assert_eq(result.state, AIPossessionState.State.TRANS_DO,
			"in-flight pass keeps TRANS state via sticky possession")
