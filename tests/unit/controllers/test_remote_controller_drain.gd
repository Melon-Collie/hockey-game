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


func test_steady_state_quantization_overdue_never_drains() -> void:
	# The measured steady state on a healthy 3-peer host: a DEEP queue (the stamp
	# lead working) whose front pops ~12 ms overdue — render-frame quantization,
	# not lateness, since physics ticks bunch two to a frame at ~100 fps. Plus an
	# ordinary hitch on top. The old 4-tick (33 ms) trigger fired here several
	# times a second, and each fire cost the client a visible reconcile.
	var rc := _controller()
	var now: float = 10.0
	var stamps: Array = []
	for i: int in range(10):
		stamps.append(now - TICK * 1.5 + TICK * float(i))  # front ~12 ms overdue, 10 deep
	_seed(rc, stamps)
	rc._drain_backlog(now)
	assert_eq(rc._input_queue.size(), 10, "a deep queue at quantization-scale overdue is untouched")
	assert_eq(rc.last_processed_host_timestamp, 0.0, "ack untouched")


func test_hitch_scale_overdue_still_does_not_drain() -> void:
	# ~5 ticks (~42 ms) overdue: an ordinary host hitch on top of quantization.
	# Tolerating it costs input LATENCY; draining it costs a visible correction —
	# so the trigger deliberately sits above this band.
	var rc := _controller()
	var now: float = 10.0
	var stamps: Array = []
	for i: int in range(10):
		stamps.append(now - TICK * 5.0 + TICK * float(i))
	_seed(rc, stamps)
	rc._drain_backlog(now)
	assert_eq(rc._input_queue.size(), 10, "hitch-scale slip rides rather than dropping inputs")


func test_backlog_drains_to_target_and_advances_ack() -> void:
	# A genuine ratchet (front past the trigger): everything staler than the
	# ~2-tick target is acked-without-applying; the queue keeps the fresh tail.
	var rc := _controller()
	var now: float = 10.0
	var stamps: Array = []
	for i: int in range(12):
		stamps.append(now - TICK * float(12 - i))  # 12..1 ticks overdue
	_seed(rc, stamps)
	rc._drain_backlog(now)
	# Only entries at/after now - _DRAIN_TARGET_S (2 ticks) survive.
	assert_eq(rc._input_queue.size(), 2, "drained down to the ~2-tick-overdue tail")
	assert_almost_eq(rc.last_processed_host_timestamp, now - TICK * 3.0, 1e-6,
			"ack advanced through the dropped span")


func test_drain_target_clears_the_quantization_floor() -> void:
	# The old 1-tick target drained to ~8.3 ms — BELOW the ~12 ms quantization
	# floor — so the very next frame read as overdue again and re-armed the
	# trigger. The target must leave the surviving front inside the healthy band.
	var rc := _controller()
	var now: float = 10.0
	var stamps: Array = []
	for i: int in range(12):
		stamps.append(now - TICK * float(12 - i))
	_seed(rc, stamps)
	rc._drain_backlog(now)
	var front_overdue: float = now - rc._input_queue.front().host_timestamp
	assert_lt(front_overdue, RemoteController._DRAIN_TRIGGER_S,
			"post-drain front is clear of the trigger, so one drain settles it")


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
	stale.quick_pass_pressed = true
	stale.brake = true  # held — must NOT carry
	var fresh := _input_at(now - TICK * 0.5)
	rc._input_queue.append(stale)
	rc._input_queue.append(fresh)
	rc._drain_backlog(now)
	assert_eq(rc._input_queue.size(), 1)
	assert_true(fresh.shoot_pressed, "press carried forward")
	assert_true(fresh.quick_pass_pressed, "press carried forward")
	assert_false(fresh.brake, "held state not carried — next input owns the truth")


func test_fresh_single_entry_queue_never_drains() -> void:
	# A lone input at jitter-scale staleness belongs to the normal pop path.
	var rc := _controller()
	var now: float = 10.0
	_seed(rc, [now - 0.1])
	rc._drain_backlog(now)
	assert_eq(rc._input_queue.size(), 1)
	assert_eq(rc.last_processed_host_timestamp, 0.0)


func test_lone_stale_input_is_dropped_not_applied() -> void:
	# A LONE input parked across a goal replay / intermission (seconds stale)
	# must be acked-and-dropped, not applied: its held state is ancient, and
	# applying it produced multi-second input_lead spikes at every phase resume.
	var rc := _controller()
	var now: float = 10.0
	var stale := _input_at(now - 3.0)
	stale.shoot_pressed = true  # a 3-second-old press is a stale ACTION — dropped
	rc._input_queue.append(stale)
	rc._drain_backlog(now)
	assert_eq(rc._input_queue.size(), 0, "phase-resume artifact dropped")
	assert_almost_eq(rc.last_processed_host_timestamp, now - 3.0, 1e-6,
			"acked so the client stops replaying it")


func test_stale_presses_are_not_carried_across_a_phase_pause() -> void:
	# In a multi-entry drain, presses older than the stale-solo bound are phase
	# artifacts and drop with their frame (only jitter-scale presses carry).
	var rc := _controller()
	var now: float = 10.0
	var ancient := _input_at(now - 2.0)
	ancient.shoot_pressed = true
	var fresh := _input_at(now - TICK * 0.5)
	rc._input_queue.append(ancient)
	rc._input_queue.append(fresh)
	rc._drain_backlog(now)
	assert_eq(rc._input_queue.size(), 1)
	assert_false(fresh.shoot_pressed, "a 2-second-old press does not fire on resume")
