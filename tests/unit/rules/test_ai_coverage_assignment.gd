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


func test_f1_takes_carrier_in_alone_back_state() -> void:
	# Team 0 defending (own_net at +Z). All three teammates are FURTHER
	# from own net than the puck — alone-back rush, nobody home. F1
	# takes the carrier as a man-to-man mark (backcheck destination
	# between carrier and net), F2 takes the off-puck opp.
	var skaters: Array = [
			[100, 0, Vector3(0, 0, 20)],   # F1 — z=20, dist-to-net 6.65
			[110, 0, Vector3(2, 0, 22)],   # F2 — dist-to-net 4.65
			[120, 0, Vector3(-2, 0, 22)],  # F3 — dist-to-net 4.65
			[200, 1, Vector3(0, 0, 24)],   # carrier — dist-to-net 2.65
			[300, 1, Vector3(3, 0, 18)],   # off-puck opp — dist-to-net 8.65
	]
	var snap := _make_snapshot(skaters, 200)
	var roles: Dictionary = {
			100: AIRoleAssignment.ROLE_F1,
			110: AIRoleAssignment.ROLE_F2,
			120: AIRoleAssignment.ROLE_F3,
	}
	var coverage: Dictionary = AICoverageAssignment.compute(snap, 0, OUR_NET_Z, _resolver(skaters), roles)
	assert_eq(coverage.get(100), 200, "F1 takes the carrier when alone-back")
	assert_eq(coverage.get(110), 300, "F2 takes the only off-puck opp")
	assert_false(coverage.has(120), "F3 has no mark — only one off-puck opp")


func test_f2_takes_carrier_when_teammate_back_but_f1_caught() -> void:
	# F1 (100) at z=20 caught up-ice. F2 (110) at z=25 is BACK of the
	# puck (z=24) — defensive cover present, so this is NOT alone-back.
	# F1 keeps chasing in CHASE_PUCK; F2 picks up the carrier as the
	# back defender. F3 takes the off-puck opp.
	var skaters: Array = [
			[100, 0, Vector3(0, 0, 20)],   # F1 — z=20, dist-to-net 6.65
			[110, 0, Vector3(2, 0, 25)],   # F2 — z=25, dist-to-net 1.65 (back of puck)
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
	assert_false(coverage.has(100), "F1 has no mark when cover is present")
	assert_eq(coverage.get(110), 200, "F2 takes the carrier when F1 is out and cover is present")
	assert_eq(coverage.get(120), 300, "F3 takes the off-puck opp")


func test_f1_no_mark_when_puck_in_our_oz() -> void:
	# Even when nobody is back of the puck, F1 doesn't get a defensive
	# mark in our OZ — that's a forecheck, not a backcheck.
	var skaters: Array = [
			[100, 0, Vector3(0, 0, -22)],   # F1 deep in OZ
			[110, 0, Vector3(2, 0, -20)],
			[120, 0, Vector3(-2, 0, -18)],
			[200, 1, Vector3(0, 0, -24)],   # opp carrier deep in OZ
			[300, 1, Vector3(3, 0, -18)],
	]
	var snap := _make_snapshot(skaters, 200)
	var roles: Dictionary = {
			100: AIRoleAssignment.ROLE_F1,
			110: AIRoleAssignment.ROLE_F2,
			120: AIRoleAssignment.ROLE_F3,
	}
	var coverage: Dictionary = AICoverageAssignment.compute(snap, 0, OUR_NET_Z, _resolver(skaters), roles)
	assert_false(coverage.has(100), "F1 no-mark in our OZ — that's a forecheck")


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
