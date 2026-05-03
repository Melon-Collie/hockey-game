extends GutTest

# AIRoleAssignment is a pure function. Tests cover: empty snapshot, single
# teammate, picking the closest to the puck, ignoring the opposing team,
# and the human-F1 yield rule.
# Consumes the existing WorldSnapshot (Dict-keyed by peer_id) and two
# Callable resolvers (team_id, is_human).

# Default human resolver for tests that don't care about role-yield —
# treats every peer as a bot, so the yield rule never fires.
var _no_humans := func(_pid: int) -> bool: return false


# Builds a snapshot from [[peer_id, team_id, position], ...]. Returns the
# snapshot plus a resolver Callable mapping peer_id -> team_id.
func _make(skaters: Array, puck_pos: Vector3) -> Array:
	var snap := WorldSnapshot.new()
	var team_map: Dictionary = {}
	for entry: Array in skaters:
		var pid: int = entry[0]
		var tid: int = entry[1]
		var pos: Vector3 = entry[2]
		var s := SkaterNetworkState.new()
		s.position = pos
		snap.skater_states[pid] = s
		team_map[pid] = tid
	var puck := PuckNetworkState.new()
	puck.position = puck_pos
	snap.puck_state = puck
	var resolver := func(pid: int) -> int:
		return int(team_map.get(pid, -1))
	return [snap, resolver]


func test_empty_snapshot_returns_empty() -> void:
	var snap := WorldSnapshot.new()
	snap.puck_state = PuckNetworkState.new()
	var resolver := func(_pid: int) -> int: return -1
	var roles: Dictionary = AIRoleAssignment.compute(snap, 0, resolver, _no_humans)
	assert_eq(roles.size(), 0)


func test_single_teammate_is_f1() -> void:
	var made: Array = _make([[100, 0, Vector3(5, 0, 5)]], Vector3(0, 0, 0))
	var roles: Dictionary = AIRoleAssignment.compute(made[0], 0, made[1], _no_humans)
	assert_eq(roles.size(), 1)
	assert_eq(roles[100], AIRoleAssignment.ROLE_F1)


func test_closest_teammate_is_f1() -> void:
	var made: Array = _make([
			[100, 0, Vector3(10, 0, 0)],
			[200, 0, Vector3(2, 0, 0)],
			[300, 0, Vector3(20, 0, 0)],
	], Vector3(0, 0, 0))
	var roles: Dictionary = AIRoleAssignment.compute(made[0], 0, made[1], _no_humans)
	assert_eq(roles[200], AIRoleAssignment.ROLE_F1, "closest to puck (peer 200) should be F1")
	# 5k: rank 2 → F2, rank 3 → F3 (peers 100 and 300 sorted by distance).
	assert_eq(roles[100], AIRoleAssignment.ROLE_F2)
	assert_eq(roles[300], AIRoleAssignment.ROLE_F3)


func test_negative_peer_ids_can_be_f1() -> void:
	# Bot peer_ids are synthetic negatives (-1..-6). The sentinel that detects
	# "no peer matched the team filter" must NOT use `< 0` because that would
	# false-positive whenever a bot wins F1.
	var made: Array = _make([
			[-1, 0, Vector3(0.5, 0, 0)],   # bot, on top of the puck
			[-2, 0, Vector3(8, 0, 0)],     # bot, far
	], Vector3(0, 0, 0))
	var roles: Dictionary = AIRoleAssignment.compute(made[0], 0, made[1], _no_humans)
	assert_eq(roles.size(), 2, "all-bot team should still get role assignments")
	assert_eq(roles[-1], AIRoleAssignment.ROLE_F1, "closest bot (peer -1) should be F1")
	# 5k: rank 2 → F2 (only two teammates means no F3).
	assert_eq(roles[-2], AIRoleAssignment.ROLE_F2)


func test_three_teammates_get_f1_f2_f3_in_rank_order() -> void:
	var made: Array = _make([
			[100, 0, Vector3(2, 0, 0)],   # closest
			[200, 0, Vector3(5, 0, 0)],   # second
			[300, 0, Vector3(10, 0, 0)],  # third
	], Vector3(0, 0, 0))
	var roles: Dictionary = AIRoleAssignment.compute(made[0], 0, made[1], _no_humans)
	assert_eq(roles[100], AIRoleAssignment.ROLE_F1)
	assert_eq(roles[200], AIRoleAssignment.ROLE_F2)
	assert_eq(roles[300], AIRoleAssignment.ROLE_F3)


func test_velocity_weighting_picks_intercepting_bot() -> void:
	# Bot A is slightly closer NOW but stationary. Bot B is a bit further
	# but skating directly toward the puck. The lookahead-weighted
	# distance should pick Bot B as F1.
	var snap := WorldSnapshot.new()
	var team_map: Dictionary = {}
	# Bot A: at (3, 0, 0), velocity 0 — closest to puck at origin right now.
	var sa := SkaterNetworkState.new()
	sa.position = Vector3(3.0, 0.0, 0.0)
	sa.velocity = Vector3.ZERO
	snap.skater_states[100] = sa
	team_map[100] = 0
	# Bot B: at (5, 0, 0) but skating toward puck at 8 m/s — predicted
	# position 0.5 s out is much closer to the puck.
	var sb := SkaterNetworkState.new()
	sb.position = Vector3(5.0, 0.0, 0.0)
	sb.velocity = Vector3(-8.0, 0.0, 0.0)
	snap.skater_states[200] = sb
	team_map[200] = 0
	var puck := PuckNetworkState.new()
	puck.position = Vector3(0.0, 0.0, 0.0)
	puck.velocity = Vector3.ZERO
	snap.puck_state = puck
	var resolver := func(pid: int) -> int: return int(team_map.get(pid, -1))
	var roles: Dictionary = AIRoleAssignment.compute(snap, 0, resolver, _no_humans)
	assert_eq(roles[200], AIRoleAssignment.ROLE_F1, "bot moving toward puck wins F1 over a slightly-closer stationary bot")


func test_ignores_opposing_team() -> void:
	var made: Array = _make([
			[100, 0, Vector3(10, 0, 0)],   # team 0, far from puck
			[200, 1, Vector3(0.1, 0, 0)],  # team 1, on the puck — but wrong team
	], Vector3(0, 0, 0))
	var roles_team0: Dictionary = AIRoleAssignment.compute(made[0], 0, made[1], _no_humans)
	assert_eq(roles_team0.size(), 1, "should only return team 0 entries")
	assert_eq(roles_team0[100], AIRoleAssignment.ROLE_F1, "team 0's lone skater is F1 even at distance")
	var roles_team1: Dictionary = AIRoleAssignment.compute(made[0], 1, made[1], _no_humans)
	assert_eq(roles_team1[200], AIRoleAssignment.ROLE_F1)


# ── Role-yield to humans ─────────────────────────────────────────────────────

func test_human_takes_f1_when_close_to_bot() -> void:
	# Bot at d=2 from puck, human at d=2.3. Within 20% tolerance of the
	# bot's distance — human gets F1, bot drops to F2.
	var made: Array = _make([
			[100, 0, Vector3(2.0, 0, 0)],   # bot — closer
			[200, 0, Vector3(2.3, 0, 0)],   # human — within tolerance
	], Vector3(0, 0, 0))
	var humans := func(pid: int) -> bool: return pid == 200
	var roles: Dictionary = AIRoleAssignment.compute(made[0], 0, made[1], humans)
	assert_eq(roles[200], AIRoleAssignment.ROLE_F1, "human within tolerance should take F1")
	assert_eq(roles[100], AIRoleAssignment.ROLE_F2, "bot drops to F2")


func test_human_does_not_steal_f1_when_far() -> void:
	# Bot at d=1, human at d=5. Way past the 20% tolerance. Bot keeps F1.
	var made: Array = _make([
			[100, 0, Vector3(1.0, 0, 0)],
			[200, 0, Vector3(5.0, 0, 0)],
	], Vector3(0, 0, 0))
	var humans := func(pid: int) -> bool: return pid == 200
	var roles: Dictionary = AIRoleAssignment.compute(made[0], 0, made[1], humans)
	assert_eq(roles[100], AIRoleAssignment.ROLE_F1, "bot stays F1 — human is too far")
	assert_eq(roles[200], AIRoleAssignment.ROLE_F2)


func test_human_already_closest_keeps_f1() -> void:
	# Human is already closest. Yield rule doesn't reorder; result is the
	# same — human is F1.
	var made: Array = _make([
			[100, 0, Vector3(5.0, 0, 0)],   # bot
			[200, 0, Vector3(1.0, 0, 0)],   # human, closest
	], Vector3(0, 0, 0))
	var humans := func(pid: int) -> bool: return pid == 200
	var roles: Dictionary = AIRoleAssignment.compute(made[0], 0, made[1], humans)
	assert_eq(roles[200], AIRoleAssignment.ROLE_F1)
	assert_eq(roles[100], AIRoleAssignment.ROLE_F2)
