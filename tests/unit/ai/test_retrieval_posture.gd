extends GutTest

# TeamBrain's RETRIEVAL upgrade wiring (docs/breakout-plan.md Phase A):
# a loose puck in our DZ that we clearly win the race to flips the brain
# from DZONE into the retrieval posture — 5v5 only, dead pucks excluded,
# contested races stay DZONE. The pure race gate itself is pinned in
# test_possession_state; these cover the brain's gating and the resulting
# slot shape end to end.

const OUR_NET_Z: float = 26.65


# Team 0 (defends +Z) peers 1–5 (C/LW/RW/LD/RD), team 1 peers 11–15.
# `opp_z` places the whole opposing side at one depth — far (up-ice) for a
# clear race, close for a contested one.
func _snapshot(opp_z: float, puck_pos: Vector3) -> WorldSnapshot:
	var snap := WorldSnapshot.new()
	var ours: Array = [
		[1, Vector3(0.0, 0.0, 18.0)], [2, Vector3(-4.0, 0.0, 16.0)],
		[3, Vector3(4.0, 0.0, 16.0)], [4, Vector3(-3.0, 0.0, 23.0)],
		[5, Vector3(5.0, 0.0, 23.0)],
	]
	var theirs: Array = [
		[11, Vector3(0.0, 0.0, opp_z)], [12, Vector3(-4.0, 0.0, opp_z)],
		[13, Vector3(4.0, 0.0, opp_z)], [14, Vector3(-2.0, 0.0, opp_z)],
		[15, Vector3(2.0, 0.0, opp_z)],
	]
	var our_ids: Array = []
	var their_ids: Array = []
	for entry: Array in ours:
		var s := SkaterNetworkState.new()
		s.position = entry[1]
		snap.skater_states[entry[0]] = s
		our_ids.append(entry[0])
	for entry: Array in theirs:
		var s := SkaterNetworkState.new()
		s.position = entry[1]
		snap.skater_states[entry[0]] = s
		their_ids.append(entry[0])
	snap.teammate_ids_by_team = {0: our_ids, 1: their_ids}
	# A playable loose puck: the enrichment publishes a live chase election.
	snap.closest_to_puck_by_team = {0: 5, 1: 15}
	var puck := PuckNetworkState.new()
	puck.carrier_peer_id = -1
	puck.position = puck_pos
	snap.puck_state = puck
	return snap


func _team_map() -> Dictionary:
	var m: Dictionary = {}
	for pid: int in [1, 2, 3, 4, 5]:
		m[pid] = 0
	for pid: int in [11, 12, 13, 14, 15]:
		m[pid] = 1
	return m


func _brain(size: int) -> TeamBrain:
	return TeamBrain.new(0, _team_map(), {}, size,
			{1: 0, 2: 1, 3: 2, 4: 3, 5: 4})


func _tick(brain: TeamBrain, snap: WorldSnapshot) -> void:
	brain.force_retick()
	brain.tick(1.0, snap)


func test_clear_race_win_postures_the_team() -> void:
	# Opponents parked in the NZ — our corner retrieval is uncontested.
	var brain: TeamBrain = _brain(5)
	_tick(brain, _snapshot(0.0, Vector3(8.0, 0.0, 24.0)))
	assert_eq(brain.state, AIPossessionState.State.RETRIEVAL)
	# The posture is the breakout shape with a retriever, not zone coverage.
	var slots: Array = brain.slot_assignments.values()
	assert_has(slots, AIRoleSlots.Slot.CHASE)
	assert_has(slots, AIRoleSlots.Slot.BREAKOUT_D2)
	assert_has(slots, AIRoleSlots.Slot.BREAKOUT_STRONG)


func test_contested_race_stays_dzone() -> void:
	# A forechecker right on top of the puck — the race is not clearly ours,
	# and a slot scramble is defense.
	var brain: TeamBrain = _brain(5)
	_tick(brain, _snapshot(23.5, Vector3(8.0, 0.0, 24.0)))
	assert_eq(brain.state, AIPossessionState.State.DZONE)


func test_3v3_never_postures() -> void:
	# 5v5-exclusive by decision (plan §5): the same uncontested retrieval in
	# a 3v3 brain keeps the shipped DZONE behavior.
	var brain: TeamBrain = _brain(3)
	_tick(brain, _snapshot(0.0, Vector3(8.0, 0.0, 24.0)))
	assert_eq(brain.state, AIPossessionState.State.DZONE)


func test_dead_puck_never_postures() -> void:
	# A goalie smother / phase lock publishes a -1 chase election — nobody
	# can play the puck, so nobody postures around it.
	var brain: TeamBrain = _brain(5)
	var snap: WorldSnapshot = _snapshot(0.0, Vector3(8.0, 0.0, 24.0))
	snap.closest_to_puck_by_team = {0: -1, 1: -1}
	_tick(brain, snap)
	assert_eq(brain.state, AIPossessionState.State.DZONE)
