extends GutTest

# The DZONE readiness gate (docs/transition-defense-plan.md §9). DZONE is a
# SHAPE, not a location: the raw possession table flips to it the instant the
# puck crosses our blue line, which used to re-slot three still-backchecking
# forwards onto zone posts. These pin the pure predicate and the brain wiring.
#
# Team 0 defends +Z (net at +26.65).

const OUR_NET_Z: float = 26.65


# ── The pure predicate ───────────────────────────────────────────────────────

func test_unset_coverage_keeps_the_rush_shape() -> void:
	assert_false(AIPossessionState.coverage_read(false, 1, false, 0.5),
			"men unaccounted for means we are not in coverage")


func test_set_coverage_enters_immediately() -> void:
	# Becoming set is the cheap direction — there is nothing to protect against
	# by delaying it, and the expensive reading (a rush arriving) is instant.
	assert_true(AIPossessionState.coverage_read(true, 0, false, 0.5),
			"accounted coverage enters on the tick it is true")


func test_a_single_bad_tick_does_not_break_a_set_structure() -> void:
	assert_true(AIPossessionState.coverage_read(false, 1, true, 1.0),
			"one failed accounting tick must not dump a set zone into scramble")


func test_sustained_failure_leaves_coverage() -> void:
	assert_false(AIPossessionState.coverage_read(
			false, AIPossessionState.COVERAGE_HOLD_TICKS, true, 1.0),
			"a sustained breakdown does return the team to the rush shape")


func test_latch_guard_forces_coverage_eventually() -> void:
	# The failure mode the guard exists for: if the accounting never clears, the
	# team would defend a settled cycle with rush roles forever.
	assert_true(AIPossessionState.coverage_read(
			false, 99, false, AIPossessionState.COVERAGE_FORCE_AFTER_S + 0.1),
			"a long possession in our zone forces the zone shape regardless")


# ── Brain wiring ─────────────────────────────────────────────────────────────

func _snapshot(ours: Array, opp: Array, carrier: int) -> WorldSnapshot:
	var snap := WorldSnapshot.new()
	for e: Array in ours + opp:
		var s := SkaterNetworkState.new()
		s.position = e[1]
		s.velocity = e[2] if e.size() > 2 else Vector3.ZERO
		s.stamina = 1.0
		snap.skater_states[e[0]] = s
	var puck := PuckNetworkState.new()
	puck.carrier_peer_id = carrier
	puck.position = snap.skater_states[carrier].position if carrier != -1 \
			else Vector3(4.0, 0.0, 20.0)
	snap.puck_state = puck
	return snap


func _brain() -> TeamBrain:
	var team_map: Dictionary = {100: 0, 110: 0, 120: 0, 130: 0, 140: 0, 200: 1, 210: 1}
	var positions: Dictionary = {100: 0, 110: 1, 120: 2, 130: 3, 140: 4}
	return TeamBrain.new(0, team_map, {}, 5, positions)


func test_backcheck_is_not_dissolved_at_the_blue_line() -> void:
	# The reported failure: the puck crosses into our zone with three of ours
	# still up-ice. The old code re-slotted all five into zone areas — a
	# structure that assumes five bodies are home, being run by two. The team
	# must stay in the rush shape until the coverage makes sense.
	var brain: TeamBrain = _brain()
	brain.tick(1.0, _snapshot([
		[100, Vector3(0.0, 0.0, -10.0), Vector3(0.0, 0.0, 7.0)],   # backchecking
		[110, Vector3(-5.0, 0.0, -12.0), Vector3(0.0, 0.0, 7.0)],  # backchecking
		[120, Vector3(5.0, 0.0, -12.0), Vector3(0.0, 0.0, 7.0)],   # backchecking
		[130, Vector3(-3.0, 0.0, 20.0)],
		[140, Vector3(3.0, 0.0, 20.0)],
	], [
		[200, Vector3(0.0, 0.0, 9.0), Vector3(0.0, 0.0, 7.0)],     # carrier, entering
		[210, Vector3(-7.0, 0.0, 9.0), Vector3(0.0, 0.0, 7.0)],    # unmarked
	], 200))
	assert_eq(brain.state, AIPossessionState.State.TRANS_OD,
			"an unaccounted-for entry stays in the rush shape, not zone coverage")
	# And the shape is the layered rush, not zone posts.
	assert_ne(_slot_of(brain, AIRoleSlots.Slot.RUSH_D1), -1,
			"the rush layers are live")
	for pid: int in [100, 110, 120, 130, 140]:
		assert_false(brain.get_slot(pid) in [
				AIRoleSlots.Slot.ZONE_D_STRONG, AIRoleSlots.Slot.ZONE_D_WEAK,
				AIRoleSlots.Slot.ZONE_C, AIRoleSlots.Slot.ZONE_W_STRONG,
				AIRoleSlots.Slot.ZONE_W_WEAK],
				"peer %d must not be holding a zone post mid-backcheck" % pid)


func test_a_set_structure_does_run_zone_coverage() -> void:
	# The other half: once everybody is home and accounted for, the team is in
	# coverage. The gate must not latch the rush shape on forever.
	var brain: TeamBrain = _brain()
	brain.tick(1.0, _snapshot([
		[100, Vector3(1.0, 0.0, 21.0)],     # on the carrier
		[110, Vector3(-4.0, 0.0, 22.0)],    # on the second man
		[120, Vector3(4.0, 0.0, 19.0)],
		[130, Vector3(-1.0, 0.0, 24.0)],
		[140, Vector3(2.0, 0.0, 24.0)],
	], [
		[200, Vector3(3.0, 0.0, 20.0)],     # carrier, contained
		[210, Vector3(-5.0, 0.0, 23.0)],    # fronted
	], 200))
	assert_eq(brain.state, AIPossessionState.State.DZONE,
			"a set structure runs zone coverage")


func test_a_loose_puck_in_our_zone_is_not_gated() -> void:
	# The gate is about defending a RUSH. A loose or dead puck in our zone is
	# DZONE's (or RETRIEVAL's) business — holding the rush shape over it would
	# stop the team setting up around a puck nobody has.
	var brain: TeamBrain = _brain()
	brain.tick(1.0, _snapshot([
		[100, Vector3(0.0, 0.0, -10.0), Vector3(0.0, 0.0, 7.0)],
		[110, Vector3(-5.0, 0.0, -12.0), Vector3(0.0, 0.0, 7.0)],
		[120, Vector3(5.0, 0.0, -12.0), Vector3(0.0, 0.0, 7.0)],
		[130, Vector3(-3.0, 0.0, 20.0)],
		[140, Vector3(3.0, 0.0, 20.0)],
	], [
		[200, Vector3(0.0, 0.0, 9.0)],
		[210, Vector3(-7.0, 0.0, 9.0)],
	], -1))
	assert_ne(brain.state, AIPossessionState.State.TRANS_OD,
			"a loose puck in our zone is not a rush being defended")


func _slot_of(brain: TeamBrain, slot: int) -> int:
	for pid: int in brain.slot_assignments:
		if brain.slot_assignments[pid] == slot:
			return pid
	return -1
