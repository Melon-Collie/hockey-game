extends GutTest

# RemoteController.sample_state_at — the geometry the local player's reconcile
# replay re-resolves body checks against (LocalController._replay_resolve_body_
# checks → GameManager._sample_historical_others).
#
# It is queried at an INPUT STAMP (`now + input lead`), which is always past the
# newest buffered snapshot, so the extrapolating branch is the steady state for
# replay — not an edge case. It used to FREEZE there. Once the live render gained
# stage-3 forward prediction that left replay as the only party still in the past:
# the live step collides against a ~host-present body, the host's own hit-claim
# rewind reconstructs a forward-predicted body, and replay re-resolved the same
# contact against a snapshot `one_way + broadcast_interval/2` older — enough, at
# skating speed against a 0.7 m contact diameter, to flip overlap, the aggressor
# gate, and the contact normal.
#
# These pin that the sample now tracks the requested instant, and that the freeze
# survives only as the deep-loss fallback.

const TICK: float = 1.0 / 120.0


func _controller() -> RemoteController:
	var rc := RemoteController.new()
	autofree(rc)
	return rc


func _state(pos: Vector3, vel: Vector3) -> SkaterNetworkState:
	var s := SkaterNetworkState.new()
	s.position = pos
	s.velocity = vel
	s.facing = Vector2(0.0, 1.0)          # +Z
	s.move_intent = Vector2.ZERO          # coast — isolates the projection
	return s


func _buffer(rc: RemoteController, at: float, pos: Vector3, vel: Vector3) -> void:
	var entry := BufferedSkaterState.new()
	entry.timestamp = at
	entry.state = _state(pos, vel)
	rc._state_buffer.append(entry)


func test_sample_past_the_buffer_advances_toward_the_requested_instant() -> void:
	# A remote coasting at 6 m/s, sampled 50 ms past the newest snapshot — the
	# steady-state replay case. Frozen, this returned the snapshot position; it
	# must now have travelled toward the requested instant.
	var rc := _controller()
	_buffer(rc, 10.0, Vector3.ZERO, Vector3(0.0, 0.0, 6.0))
	var s: SkaterNetworkState = rc.sample_state_at(10.05)
	assert_not_null(s)
	assert_gt(s.position.z, 0.0, "the sample projected forward instead of freezing")
	# Coasting on ice, so it travels slightly under vel*dt (friction) but on the
	# same order — not the frozen 0, and not an unbounded overshoot.
	assert_between(s.position.z, 0.15, 0.30,
			"travel is on the order of velocity x dt for a 50 ms coast at 6 m/s")


func test_further_requests_project_further() -> void:
	# Monotonic in the requested instant — the sample tracks the query rather
	# than snapping to one value past the buffer edge.
	var rc := _controller()
	_buffer(rc, 10.0, Vector3.ZERO, Vector3(0.0, 0.0, 6.0))
	var near_z: float = rc.sample_state_at(10.02).position.z
	var far_z: float = rc.sample_state_at(10.06).position.z
	assert_gt(far_z, near_z, "a later requested instant samples further along the path")


func test_a_stalled_buffer_still_freezes() -> void:
	# Past the deep-loss cap the old conservative freeze is retained: projecting a
	# third of a second of skating would fabricate contacts, not reconstruct them.
	var rc := _controller()
	_buffer(rc, 10.0, Vector3.ZERO, Vector3(0.0, 0.0, 6.0))
	var s: SkaterNetworkState = rc.sample_state_at(10.0 + RemoteController._SAMPLE_PREDICT_MAX_S + 0.05)
	assert_not_null(s)
	assert_eq(s.position, Vector3.ZERO, "beyond the cap the sample holds at the newest snapshot")


func test_a_stationary_remote_does_not_drift() -> void:
	# No velocity, no intent — the projection must be the identity, so a standing
	# player can never be projected into a contact that did not happen.
	var rc := _controller()
	_buffer(rc, 10.0, Vector3(1.0, 0.0, 2.0), Vector3.ZERO)
	var s: SkaterNetworkState = rc.sample_state_at(10.05)
	assert_almost_eq(s.position.x, 1.0, 0.001)
	assert_almost_eq(s.position.z, 2.0, 0.001)


func test_interpolating_branch_is_unchanged() -> void:
	# A request INSIDE the buffer still brackets normally — the change is scoped
	# to the past-the-edge branch.
	var rc := _controller()
	_buffer(rc, 10.0, Vector3.ZERO, Vector3(0.0, 0.0, 6.0))
	_buffer(rc, 10.0 + TICK * 4.0, Vector3(0.0, 0.0, 0.2), Vector3(0.0, 0.0, 6.0))
	var s: SkaterNetworkState = rc.sample_state_at(10.0 + TICK * 2.0)
	assert_not_null(s)
	assert_between(s.position.z, 0.0, 0.2, "bracketed between the two buffered samples")


func test_ghost_flag_survives_the_projection() -> void:
	# The ghost gate must still reach the caller — a projected sample that lost it
	# would re-resolve contacts against ghosted skaters the host skipped.
	var rc := _controller()
	var entry := BufferedSkaterState.new()
	entry.timestamp = 10.0
	var st := _state(Vector3.ZERO, Vector3(0.0, 0.0, 6.0))
	st.is_ghost = true
	entry.state = st
	rc._state_buffer.append(entry)
	var s: SkaterNetworkState = rc.sample_state_at(10.05)
	assert_true(s.is_ghost, "ghost flag carried through the forward projection")
