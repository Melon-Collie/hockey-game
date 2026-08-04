extends GutTest

# ClockSync — NTP-style RTT sampling and offset computation.
# Uses load() because ClockSync has no class_name (it's only instantiated
# inside NetworkManager).

var ClockSyncScript = load("res://Scripts/networking/clock_sync.gd")


func _make() -> RefCounted:
	return ClockSyncScript.new()


# ── Readiness ────────────────────────────────────────────────────────────────

func test_not_ready_before_initial_ping_count() -> void:
	var cs := _make()
	cs.record_pong(0.0, 0.05, 0.1)
	cs.record_pong(0.0, 0.05, 0.1)
	assert_false(cs.is_ready)


func test_ready_after_initial_ping_count() -> void:
	var cs := _make()
	cs.record_pong(0.0, 0.05, 0.1)
	cs.record_pong(0.0, 0.05, 0.1)
	cs.record_pong(0.0, 0.05, 0.1)
	assert_true(cs.is_ready)


func test_ready_stays_true_after_more_samples() -> void:
	var cs := _make()
	for i: int in 6:
		cs.record_pong(0.0, 0.05, 0.1)
	assert_true(cs.is_ready)


# ── RTT calculation ──────────────────────────────────────────────────────────

func test_rtt_is_recv_minus_send_time() -> void:
	var cs := _make()
	# send=1.0, recv=1.1 → 100 ms RTT
	cs.record_pong(1.0, 1.05, 1.1)
	assert_almost_eq(cs.rtt_ms, 100.0, 1.0)


func test_rtt_reflects_symmetric_delay() -> void:
	var cs := _make()
	# 50 ms one-way → 100 ms RTT
	cs.record_pong(0.0, 0.05, 0.1)
	assert_almost_eq(cs.rtt_ms, 100.0, 1.0)


# ── Outlier dropping ─────────────────────────────────────────────────────────

func test_outlier_samples_excluded_from_rtt_average() -> void:
	var cs := _make()
	# Fill the window: 6 normal samples at 50 ms, 2 outliers at 500 ms.
	# OUTLIER_DROP=2 removes the two highest, leaving only 50 ms samples.
	for i: int in 6:
		cs.record_pong(0.0, 0.025, 0.05)
	cs.record_pong(0.0, 0.25, 0.5)
	cs.record_pong(0.0, 0.25, 0.5)
	assert_almost_eq(cs.rtt_ms, 50.0, 5.0)


func test_single_sample_not_dropped() -> void:
	# With fewer samples than OUTLIER_DROP, at least one is always kept.
	var cs := _make()
	cs.record_pong(0.0, 0.1, 0.2)
	assert_almost_eq(cs.rtt_ms, 200.0, 1.0)


# ── Offset / sync ────────────────────────────────────────────────────────────

func test_zero_offset_when_clocks_are_in_sync() -> void:
	# If host_time == midpoint of the round trip, offset should be ~0.
	# send=0, recv=0.1, host_time=0.05 → rtt=0.1, offset=(0.05+0.05)-0.1=0
	var cs := _make()
	for i: int in 3:
		cs.record_pong(0.0, 0.05, 0.1)
	# estimated_host_time ≈ local_time + 0 ≈ local_time
	var now: float = Time.get_ticks_msec() / 1000.0
	assert_almost_eq(cs.estimated_host_time(), now, 0.05)


func test_positive_offset_when_host_is_ahead() -> void:
	# host is 10 s ahead of client; mid-trip host_time should be ~(local+10+rtt/2)
	# send=0, recv=0.1, host_time=10.05 → offset=(10.05+0.05)-0.1=10.0
	var cs := _make()
	for i: int in 3:
		cs.record_pong(0.0, 10.05, 0.1)
	var now: float = Time.get_ticks_msec() / 1000.0
	assert_almost_eq(cs.estimated_host_time(), now + 10.0, 0.05)


# ── Adaptive input-lead servo ────────────────────────────────────────────────

func _ready_clock() -> RefCounted:
	var cs := _make()
	cs.record_pong(0.0, 0.05, 0.1)
	cs.record_pong(0.0, 0.05, 0.1)
	cs.record_pong(0.0, 0.05, 0.1)
	return cs


func test_lead_extra_starts_at_one_tick() -> void:
	# Initial extra = one tick — the playtest-measured deficit of the static
	# lead on a clean link, so warm-up starts near the right answer.
	var cs := _ready_clock()
	assert_almost_eq(cs.current_input_lead_s(),
			cs.INPUT_LEAD_SEC + 1.0 / 120.0, 1e-6)


func test_sustained_overdue_raises_the_lead() -> void:
	# The host popping our inputs ~20 ms late (queue running dry) must climb
	# the extra — this is the servo's whole purpose.
	var cs := _ready_clock()
	var before: float = cs.current_input_lead_s()
	for _i in range(60):
		cs.record_ack_overdue(0.020)
	assert_gt(cs.current_input_lead_s(), before, "sustained overdue climbs the lead")


func test_lead_extra_is_hard_capped() -> void:
	var cs := _ready_clock()
	for _i in range(5000):
		cs.record_ack_overdue(0.2)
	assert_lte(cs.current_input_lead_s(), cs.INPUT_LEAD_SEC + cs.MAX_LEAD_EXTRA_S + 1e-9,
			"extra never exceeds MAX_LEAD_EXTRA_S")


func test_healthy_overdue_relaxes_toward_zero_extra() -> void:
	# Overdue steady under the one-tick grace -> the servo slowly gives the
	# extra back (over-lead only costs remote-visibility latency, but it does
	# cost it).
	var cs := _ready_clock()
	for _i in range(60):
		cs.record_ack_overdue(0.020)
	var raised: float = cs.current_input_lead_s()
	for _i in range(2000):
		cs.record_ack_overdue(0.0)
	assert_lt(cs.current_input_lead_s(), raised, "healthy acks relax the lead")


func test_phase_artifact_overdue_is_ignored() -> void:
	# A multi-second overdue is an input parked across a replay/intermission,
	# not link lateness — it must not spike the servo.
	var cs := _ready_clock()
	var before: float = cs.current_input_lead_s()
	for _i in range(50):
		cs.record_ack_overdue(3.0)
	assert_almost_eq(cs.current_input_lead_s(), before, 1e-9,
			"phase-resume artifacts are excluded from the servo")


func test_servo_never_touches_the_ntp_offset() -> void:
	# The invariant: lead adaptation is separate state; the offset stays pure
	# ping/pong NTP. Feeding the servo must not move estimated_host_time's base.
	var cs := _ready_clock()
	var offset_before: float = cs._offset
	for _i in range(100):
		cs.record_ack_overdue(0.05)
	assert_eq(cs._offset, offset_before,
			"100 overdue samples moved the NTP offset")
	# Second, weaker check: nothing folded the offset into the stamp path either.
	# Both terms read the wall clock, so the tolerance must clear the 1 ms
	# granularity of Time.get_ticks_msec() — a millisecond boundary landing
	# between the two reads shrinks the gap by exactly one tick.
	var lead_gap: float = cs.estimated_input_stamp_time() - cs.estimated_host_time()
	assert_almost_eq(lead_gap, cs.current_input_lead_s(), 2e-3,
			"stamp lead is base + extra, with no offset drift folded in")
