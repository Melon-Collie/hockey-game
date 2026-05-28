extends GutTest

# TeamBrain.exclude_skater / include_skater. Used by the tutorial to puppet a
# bot in scripted mode — without the exclusion, role assignment would yank
# the bot toward a slot anchor each brain tick and the puppet API would be
# fighting the brain. These tests pin the contract:
#   - excluded peers never appear in slot_assignments after a tick
#   - already-assigned peers are erased on the exclude call (so callers don't
#     have to wait for the next tick to see the effect)
#   - include_skater restores normal assignment on the next tick


const TEAM_ID: int = 0


func _make_snapshot(carrier_pid: int, puck_pos: Vector3) -> WorldSnapshot:
	var snap := WorldSnapshot.new()
	# Two team-0 teammates + one team-1 opponent so possession + slot
	# assignment have something to compute against.
	for entry: Array in [[100, 0, Vector3(0.0, 0.0, 22.0)],
			[110, 0, Vector3(-2.0, 0.0, 22.65)],
			[200, 1, puck_pos]]:
		var s := SkaterNetworkState.new()
		s.position = entry[2]
		snap.skater_states[entry[0]] = s
	var puck := PuckNetworkState.new()
	puck.carrier_peer_id = carrier_pid
	puck.position = puck_pos
	snap.puck_state = puck
	return snap


func _make_brain() -> TeamBrain:
	var team_map: Dictionary = {100: 0, 110: 0, 200: 1}
	return TeamBrain.new(TEAM_ID, team_map)


func test_excluded_peer_gets_no_slot() -> void:
	var brain: TeamBrain = _make_brain()
	brain.exclude_skater(110)
	brain.force_retick()
	brain.tick(0.001, _make_snapshot(200, Vector3(0.0, 0.0, 22.0)))
	assert_false(brain.slot_assignments.has(110),
			"excluded peer should not appear in slot_assignments")
	assert_true(brain.slot_assignments.has(100),
			"non-excluded teammate should still be assigned")


func test_exclude_erases_existing_assignment_immediately() -> void:
	# Without the in-line erase, callers would have to wait for the next
	# tick (up to 167 ms) to see the puppet stop role-anchoring.
	var brain: TeamBrain = _make_brain()
	brain.force_retick()
	brain.tick(0.001, _make_snapshot(200, Vector3(0.0, 0.0, 22.0)))
	assert_true(brain.slot_assignments.has(110),
			"sanity: peer 110 is assigned before exclusion")
	brain.exclude_skater(110)
	assert_false(brain.slot_assignments.has(110),
			"exclude_skater must erase the existing assignment immediately")


func test_include_restores_assignment_on_next_tick() -> void:
	var brain: TeamBrain = _make_brain()
	brain.exclude_skater(110)
	brain.force_retick()
	brain.tick(0.001, _make_snapshot(200, Vector3(0.0, 0.0, 22.0)))
	assert_false(brain.slot_assignments.has(110), "sanity: excluded")

	brain.include_skater(110)
	brain.force_retick()
	brain.tick(0.001, _make_snapshot(200, Vector3(0.0, 0.0, 22.0)))
	assert_true(brain.slot_assignments.has(110),
			"include_skater should restore role assignment on the next tick")


func test_get_slot_returns_none_for_excluded() -> void:
	var brain: TeamBrain = _make_brain()
	brain.exclude_skater(110)
	brain.force_retick()
	brain.tick(0.001, _make_snapshot(200, Vector3(0.0, 0.0, 22.0)))
	assert_eq(brain.get_slot(110), AIRoleSlots.Slot.NONE,
			"get_slot for an excluded peer should be NONE")
