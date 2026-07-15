extends GutTest

# AIAccelerationTracker is the global per-host perception cache: smoothed linear
# acceleration AND heading turn rate, shared by reference to every bot. These
# tests cover the heading-turn-rate (receiver-commitment) signal — the running
# estimate the pass EV reads to avoid chucking feeds at turning players. It
# GAINS confidence over time: a receiver settling onto a line decays toward 0.

const DT: float = 1.0 / 120.0  # PHYSICS_TICK


func _state(vel: Vector3) -> SkaterNetworkState:
	var s := SkaterNetworkState.new()
	s.velocity = vel
	return s


# Rotate an XZ vector by `angle` (from +X toward +Z).
func _rot(base: Vector3, angle: float) -> Vector3:
	return Vector3(
			base.x * cos(angle) - base.z * sin(angle), 0.0,
			base.x * sin(angle) + base.z * cos(angle))


# Feed `frames` velocity samples (vel_fn(i)) for one peer, return its smoothed
# heading turn rate.
func _run(tracker: AIAccelerationTracker, peer: int,
		vel_fn: Callable, frames: int) -> float:
	for i in frames:
		var states: Dictionary = {peer: _state(vel_fn.call(i))}
		tracker.update(states, DT)
	return tracker.heading_omega_by_peer.get(peer, 0.0)


func test_straight_line_receiver_reads_settled() -> void:
	var tracker := AIAccelerationTracker.new()
	var omega: float = _run(tracker, 1,
			func(_i: int) -> Vector3: return Vector3(6.0, 0.0, 0.0), 120)
	assert_almost_eq(omega, 0.0, 0.05,
			"a constant-velocity receiver has ~zero heading turn rate")


func test_turning_receiver_reads_its_turn_rate() -> void:
	# Velocity rotates a steady 2 rad/s; the smoothed estimate converges there.
	var tracker := AIAccelerationTracker.new()
	var omega: float = _run(tracker, 1,
			func(i: int) -> Vector3:
				return _rot(Vector3(6.0, 0.0, 0.0), 2.0 * DT * i), 120)
	assert_almost_eq(absf(omega), 2.0, 0.25,
			"a 2 rad/s cut is read as ~2 rad/s of heading rotation")


func test_near_stationary_receiver_has_no_heading() -> void:
	# Below OMEGA_MIN_SPEED the velocity direction is noise — treated as settled
	# (a near-stopped receiver is easy to feed, no lead needed).
	var tracker := AIAccelerationTracker.new()
	var omega: float = _run(tracker, 1,
			func(i: int) -> Vector3:
				# Direction flips wildly but stays below the speed floor.
				return _rot(Vector3(0.2, 0.0, 0.0), float(i)), 120)
	assert_almost_eq(omega, 0.0, 0.01,
			"a sub-floor-speed receiver contributes no turn rate")


func test_confidence_builds_as_a_receiver_settles() -> void:
	# Turn hard, then straighten: the estimate decays toward 0, so the passer
	# grows confident over time (the whole point of a running estimate).
	var tracker := AIAccelerationTracker.new()
	var turning: float = _run(tracker, 1,
			func(i: int) -> Vector3:
				return _rot(Vector3(6.0, 0.0, 0.0), 3.0 * DT * i), 60)
	# Now hold the heading it ended on — a straight line.
	var final_dir := _rot(Vector3(6.0, 0.0, 0.0), 3.0 * DT * 60)
	var settled: float = _run(tracker, 1,
			func(_i: int) -> Vector3: return final_dir, 60)
	assert_gt(absf(turning), 1.0, "mid-cut reads a real turn rate")
	assert_lt(absf(settled), absf(turning) * 0.5,
			"straightening out decays the estimate — confidence gained over time")


func test_stale_peer_is_pruned() -> void:
	var tracker := AIAccelerationTracker.new()
	_run(tracker, 7,
			func(_i: int) -> Vector3: return Vector3(6.0, 0.0, 0.0), 10)
	assert_true(tracker.heading_omega_by_peer.has(7), "peer tracked while present")
	# A frame without peer 7 prunes it.
	tracker.update({1: _state(Vector3(6.0, 0.0, 0.0))}, DT)
	assert_false(tracker.heading_omega_by_peer.has(7),
			"a peer that left the snapshot is pruned from the omega cache")
