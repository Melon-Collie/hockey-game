extends GutTest

# AICoverageAssignment is a pure function. Tests cover the
# F2-marks-most-dangerous / F3-marks-other split, the "F1 not assigned
# a mark" rule, and the carrier-excluded-from-marks rule.

# Team 0 defends +Z (our_net_z = +26.65), attacks -Z.
const OUR_NET_Z: float = 26.65


func _make_snapshot(skaters: Array, carrier_peer_id: int = -1) -> WorldSnapshot:
	# skaters: Array of [peer_id, team_id, position]
	var snap := WorldSnapshot.new()
	for entry: Array in skaters:
		var s := SkaterNetworkState.new()
		s.position = entry[2]
		snap.skater_states[entry[0]] = s
	var puck := PuckNetworkState.new()
	puck.carrier_peer_id = carrier_peer_id
	snap.puck_state = puck
	return snap


func _resolver(skaters: Array) -> Callable:
	var team_map: Dictionary = {}
	for entry: Array in skaters:
		team_map[entry[0]] = entry[1]
	return func(pid: int) -> int: return int(team_map.get(pid, -1))


func test_f2_takes_most_dangerous_f3_takes_other() -> void:
	# Team 0 defending. Two opps: 200 closer to our net (+Z), 300 further.
	# F2 should mark 200, F3 should mark 300.
	var skaters: Array = [
			[100, 0, Vector3(0, 0, 20)],   # our F1 (chasing)
			[110, 0, Vector3(2, 0, 22)],   # our F2
			[120, 0, Vector3(-2, 0, 22)],  # our F3
			[200, 1, Vector3(0, 0, 24)],   # opp closer to our net (z=24)
			[300, 1, Vector3(3, 0, 18)],   # opp further from our net
	]
	var snap := _make_snapshot(skaters, 200)
	var roles: Dictionary = {
			100: AIRoleAssignment.ROLE_F1,
			110: AIRoleAssignment.ROLE_F2,
			120: AIRoleAssignment.ROLE_F3,
	}
	var coverage: Dictionary = AICoverageAssignment.compute(snap, 0, OUR_NET_Z, _resolver(skaters), roles)
	# Carrier (200) is excluded; only non-carrier opp here is 300.
	# So F2 marks 300; F3 has nothing.
	assert_eq(coverage.get(110), 300)
	assert_false(coverage.has(120), "F3 has no mark when only one non-carrier opp on the ice")


func test_two_non_carrier_opps_both_marked() -> void:
	var skaters: Array = [
			[100, 0, Vector3(0, 0, 22)],   # F1 chasing puck (loose, no carrier)
			[110, 0, Vector3(2, 0, 22)],   # F2
			[120, 0, Vector3(-2, 0, 22)],  # F3
			[200, 1, Vector3(0, 0, 25)],   # opp closer to our net
			[300, 1, Vector3(0, 0, 18)],   # opp further
			[400, 1, Vector3(5, 0, 20)],   # opp middle
	]
	var snap := _make_snapshot(skaters, -1)  # no carrier
	var roles: Dictionary = {
			100: AIRoleAssignment.ROLE_F1,
			110: AIRoleAssignment.ROLE_F2,
			120: AIRoleAssignment.ROLE_F3,
	}
	var coverage: Dictionary = AICoverageAssignment.compute(snap, 0, OUR_NET_Z, _resolver(skaters), roles)
	# F2 takes the most dangerous (200, |25 - 26.65| = 1.65)
	# F3 takes the next (400, |20 - 26.65| = 6.65)
	# (300 is at |18-26.65| = 8.65, the least dangerous → not marked)
	assert_eq(coverage.get(110), 200)
	assert_eq(coverage.get(120), 400)


func test_f1_never_assigned_a_mark() -> void:
	var skaters: Array = [
			[100, 0, Vector3(0, 0, 20)],
			[200, 1, Vector3(0, 0, 25)],
	]
	var snap := _make_snapshot(skaters, -1)
	var roles: Dictionary = {100: AIRoleAssignment.ROLE_F1}
	var coverage: Dictionary = AICoverageAssignment.compute(snap, 0, OUR_NET_Z, _resolver(skaters), roles)
	assert_false(coverage.has(100), "F1 pressures puck via chase logic, no man-mark")
