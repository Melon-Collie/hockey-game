extends GutTest

# Phase 3 added force_retick() to TeamBrain. This test verifies the
# rate-limit-bypass contract:
#   - tick(delta < TICK_PERIOD) is a no-op (existing behavior).
#   - force_retick() followed by tick(any_delta) computes regardless.
#   - After a forced tick, the natural cadence resumes (next tick
#     fires TICK_PERIOD seconds later, not earlier).

const OUR_NET_Z: float = 26.65
const TEAM_ID: int = 0


func _make_snapshot(carrier_pid: int, puck_pos: Vector3) -> WorldSnapshot:
	var snap := WorldSnapshot.new()
	# Two teammates + opp carrier so possession + assignment have
	# something to compute.
	for entry: Array in [[100, 0, Vector3(0.0, 0.0, 22.0)],
			[110, 0, Vector3(-2.0, 0.0, 22.65)],
			[120, 0, Vector3(2.0, 0.0, 22.0)],
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
	var team_map: Dictionary = {100: 0, 110: 0, 120: 0, 200: 1}
	var resolver: Callable = func(pid: int) -> int: return int(team_map.get(pid, -1))
	var human_resolver: Callable = func(_pid: int) -> bool: return false
	return TeamBrain.new(TEAM_ID, resolver, human_resolver)


func test_tick_below_period_is_noop() -> void:
	var brain: TeamBrain = _make_brain()
	var snap: WorldSnapshot = _make_snapshot(200, Vector3(0.0, 0.0, 22.0))
	# 100 ms — well below the 167 ms TICK_PERIOD. Should NOT compute.
	brain.tick(0.1, snap)
	assert_true(brain.slot_assignments.is_empty(),
			"tick() under TICK_PERIOD should be a no-op (no assignments yet)")


func test_force_retick_bypasses_rate_limit() -> void:
	var brain: TeamBrain = _make_brain()
	var snap: WorldSnapshot = _make_snapshot(200, Vector3(0.0, 0.0, 22.0))
	brain.force_retick()
	# Even with a tiny delta the next tick should compute because
	# _force_tick_pending was set.
	brain.tick(0.001, snap)
	assert_false(brain.slot_assignments.is_empty(),
			"force_retick() + tick() should compute regardless of accumulator")
	assert_eq(brain.state, AIPossessionState.State.DZONE,
			"opp carrier deep in our DZ → DZONE")


func test_natural_cadence_resumes_after_forced_tick() -> void:
	var brain: TeamBrain = _make_brain()
	var snap: WorldSnapshot = _make_snapshot(200, Vector3(0.0, 0.0, 22.0))
	brain.force_retick()
	brain.tick(0.001, snap)  # forced tick — accumulator reset to 0
	var assignments_after_forced: Dictionary = brain.slot_assignments.duplicate()

	# Next call within TICK_PERIOD should be a no-op (no double-tick
	# burst). Mutate snapshot so a re-tick would be detectable.
	var snap2: WorldSnapshot = _make_snapshot(100, Vector3(0.0, 0.0, -22.0))  # we now carry
	brain.tick(0.05, snap2)
	assert_eq_deep(brain.slot_assignments, assignments_after_forced,
			"tick() within TICK_PERIOD of a forced tick should not re-compute")

	# After enough delta to clear TICK_PERIOD, the natural cadence
	# fires and assignments update to reflect the new snapshot.
	brain.tick(0.2, snap2)  # 200 ms, > TICK_PERIOD
	assert_eq(brain.state, AIPossessionState.State.OZONE,
			"after natural tick fires, possession state reflects new carrier")


# Helper — GUT doesn't have assert_eq for Dictionary by default; do
# a manual deep compare via string repr (sufficient for small dicts).
func assert_eq_deep(a: Dictionary, b: Dictionary, msg: String = "") -> void:
	assert_eq(str(a), str(b), msg)
