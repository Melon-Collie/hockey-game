extends GutTest

# AIRoleAssignment is a pure function. Tests cover: empty snapshot, single
# teammate, picking the closest to the puck, and ignoring the opposing team.


func _make_snapshot(skaters: Array) -> WorldSnapshot:
	# skaters: Array of [peer_id, team_id, position]
	var snap := WorldSnapshot.new()
	snap.num_skaters = skaters.size()
	for i: int in skaters.size():
		var entry: Array = skaters[i]
		snap.skater_peer_id[i] = entry[0]
		snap.skater_team[i] = entry[1]
		snap.skater_pos[i] = entry[2]
	return snap


func test_empty_snapshot_returns_empty() -> void:
	var snap := WorldSnapshot.new()  # num_skaters = 0
	var roles: Dictionary = AIRoleAssignment.compute(snap, 0)
	assert_eq(roles.size(), 0)


func test_single_teammate_is_f1() -> void:
	var snap := _make_snapshot([[100, 0, Vector3(5, 0, 5)]])
	snap.puck_pos = Vector3(0, 0, 0)
	var roles: Dictionary = AIRoleAssignment.compute(snap, 0)
	assert_eq(roles.size(), 1)
	assert_eq(roles[100], AIRoleAssignment.ROLE_F1)


func test_closest_teammate_is_f1() -> void:
	var snap := _make_snapshot([
			[100, 0, Vector3(10, 0, 0)],
			[200, 0, Vector3(2, 0, 0)],
			[300, 0, Vector3(20, 0, 0)],
	])
	snap.puck_pos = Vector3(0, 0, 0)
	var roles: Dictionary = AIRoleAssignment.compute(snap, 0)
	assert_eq(roles[200], AIRoleAssignment.ROLE_F1, "closest to puck (peer 200) should be F1")
	assert_eq(roles[100], AIRoleAssignment.ROLE_OFF)
	assert_eq(roles[300], AIRoleAssignment.ROLE_OFF)


func test_ignores_opposing_team() -> void:
	var snap := _make_snapshot([
			[100, 0, Vector3(10, 0, 0)],   # team 0, far from puck
			[200, 1, Vector3(0.1, 0, 0)],  # team 1, on the puck — but wrong team
	])
	snap.puck_pos = Vector3(0, 0, 0)
	var roles_team0: Dictionary = AIRoleAssignment.compute(snap, 0)
	assert_eq(roles_team0.size(), 1, "should only return team 0 entries")
	assert_eq(roles_team0[100], AIRoleAssignment.ROLE_F1, "team 0's lone skater is F1 even at distance")
	var roles_team1: Dictionary = AIRoleAssignment.compute(snap, 1)
	assert_eq(roles_team1[200], AIRoleAssignment.ROLE_F1)
