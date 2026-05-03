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


func test_f2_takes_carrier_when_f1_caught_up_ice() -> void:
	# Team 0 defending (own_net at +Z). F1 (peer 100) at z=20 is FURTHER
	# from own net than the carrier (200) at z=24 — F1 caught up-ice on
	# a rush. Carrier becomes a valid mark; F2 takes the most-dangerous
	# (the carrier), F3 takes the off-puck opp.
	var skaters: Array = [
			[100, 0, Vector3(0, 0, 20)],   # F1 — z=20, dist-to-net 6.65
			[110, 0, Vector3(2, 0, 22)],   # F2
			[120, 0, Vector3(-2, 0, 22)],  # F3
			[200, 1, Vector3(0, 0, 24)],   # carrier — dist-to-net 2.65 (closer than F1)
			[300, 1, Vector3(3, 0, 18)],   # off-puck opp — dist-to-net 8.65
	]
	var snap := _make_snapshot(skaters, 200)
	var roles: Dictionary = {
			100: AIRoleAssignment.ROLE_F1,
			110: AIRoleAssignment.ROLE_F2,
			120: AIRoleAssignment.ROLE_F3,
	}
	var coverage: Dictionary = AICoverageAssignment.compute(snap, 0, OUR_NET_Z, _resolver(skaters), roles)
	assert_eq(coverage.get(110), 200, "F2 takes the carrier when F1 is out of position")
	assert_eq(coverage.get(120), 300, "F3 takes the off-puck opp")


func test_f2_skips_carrier_when_f1_in_position() -> void:
	# F1 (peer 100) at z=25 — between carrier (z=24) and own net (z=26.65).
	# F1 is in position to pressure the carrier through chase, so the
	# carrier is excluded from the mark pool. F2 takes the off-puck opp.
	var skaters: Array = [
			[100, 0, Vector3(0, 0, 25)],   # F1 — closer to net than carrier
			[110, 0, Vector3(2, 0, 22)],   # F2
			[120, 0, Vector3(-2, 0, 22)],  # F3
			[200, 1, Vector3(0, 0, 24)],   # carrier
			[300, 1, Vector3(3, 0, 18)],   # off-puck opp
	]
	var snap := _make_snapshot(skaters, 200)
	var roles: Dictionary = {
			100: AIRoleAssignment.ROLE_F1,
			110: AIRoleAssignment.ROLE_F2,
			120: AIRoleAssignment.ROLE_F3,
	}
	var coverage: Dictionary = AICoverageAssignment.compute(snap, 0, OUR_NET_Z, _resolver(skaters), roles)
	assert_eq(coverage.get(110), 300, "F2 marks the off-puck opp; carrier is F1's responsibility")
	assert_false(coverage.has(120), "F3 has no mark — only one non-carrier opp")


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
