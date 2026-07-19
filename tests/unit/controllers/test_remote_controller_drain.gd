extends GutTest

# RemoteController._drain_backlog — the input-backlog ratchet fix. Consumption
# is one input per tick and production is one per tick, so a jitter-burst
# backlog could never drain on its own: every subsequent input was applied
# ~backlog ticks stale for the rest of the session. The drain acks-without-
# applying stale inputs past the overdue trigger, folding edge flags (presses)
# into the next applied input. These tests drive the method directly with a
# synthetic queue — it touches only the queue, the ack, and telemetry.

const TICK: float = 1.0 / 120.0


func _controller() -> RemoteController:
	var rc := RemoteController.new()
	autofree(rc)
	return rc


func _input_at(ts: float) -> InputState:
	var s := InputState.new()
	s.host_timestamp = ts
	return s


func _seed(rc: RemoteController, timestamps: Array) -> void:
	for ts: float in timestamps:
		rc._input_queue.append(_input_at(ts))


func test_healthy_queue_is_untouched() -> void:
	# Front ~1 tick overdue (normal batch cadence) — under the trigger, no drain.
	var rc := _controller()
	var now: float = 10.0
	_seed(rc, [now - TICK, now, now + TICK])
	rc._drain_backlog(now)
	assert_eq(rc._input_queue.size(), 3, "healthy overdue never drains")
	assert_eq(rc.last_processed_host_timestamp, 0.0, "ack untouched")


func test_backlog_drains_to_target_and_advances_ack() -> void:
	# A ~10-tick backlog (post-jitter-burst shape): everything staler than the
	# ~1-tick target is acked-without-applying; the queue keeps the fresh tail.
	var rc := _controller()
	var now: float = 10.0
	var stamps: Array = []
	for i: int in range(10):
		stamps.append(now - TICK * float(10 - i))  # 10..1 ticks overdue
	_seed(rc, stamps)
	rc._drain_backlog(now)
	# Only entries at/after now - _DRAIN_TARGET_S survive: the 1-tick-overdue tail.
	assert_eq(rc._input_queue.size(), 1, "drained down to the ~1-tick-overdue tail")
	assert_almost_eq(rc.last_processed_host_timestamp, now - TICK * 2.0, 1e-6,
			"ack advanced through the dropped span")


func test_drain_always_leaves_one_input_to_apply() -> void:
	# Even a fully-stale queue keeps its newest entry so this tick still applies
	# a real input (the drain is a catch-up, not a starvation).
	var rc := _controller()
	var now: float = 10.0
	_seed(rc, [now - 0.2, now - 0.15, now - 0.1])
	rc._drain_backlog(now)
	assert_eq(rc._input_queue.size(), 1, "newest input survives")
	assert_almost_eq(rc._input_queue.front().host_timestamp, now - 0.1, 1e-6)


func test_dropped_presses_fold_into_the_next_applied_input() -> void:
	# A press inside the dropped span must still fire once: edge flags OR into
	# the next surviving input. Held state is deliberately NOT carried.
	var rc := _controller()
	var now: float = 10.0
	var stale := _input_at(now - 0.1)
	stale.shoot_pressed = true
	stale.quick_shot_pressed = true
	stale.brake = true  # held — must NOT carry
	var fresh := _input_at(now - TICK * 0.5)
	rc._input_queue.append(stale)
	rc._input_queue.append(fresh)
	rc._drain_backlog(now)
	assert_eq(rc._input_queue.size(), 1)
	assert_true(fresh.shoot_pressed, "press carried forward")
	assert_true(fresh.quick_shot_pressed, "press carried forward")
	assert_false(fresh.brake, "held state not carried — next input owns the truth")


func test_single_entry_queue_never_drains() -> void:
	# With one queued input the normal pop path owns it regardless of staleness.
	var rc := _controller()
	var now: float = 10.0
	_seed(rc, [now - 0.3])
	rc._drain_backlog(now)
	assert_eq(rc._input_queue.size(), 1)
	assert_eq(rc.last_processed_host_timestamp, 0.0)
