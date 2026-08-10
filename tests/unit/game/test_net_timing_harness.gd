extends GutTest

# The input-timing pipeline under a framerate x latency matrix.
#
# These are the assertions that would have caught the wall-clock stamping bug
# before it reached a playtest — and the reason to trust them is
# test_legacy_wall_stamping_loses_inputs below, which asserts the harness still
# REPRODUCES that bug when switched back to the old scheme. A harness that only
# ever passes is evidence of nothing.

const H := preload("res://tests/harness/net_timing_harness.gd")

# Deliberately includes rates that do NOT divide the 120 Hz physics tick (75,
# 100, 144): those produce an irregular 1-2-1-2 step pattern per frame, which is
# harder on the clock than a clean 2-per-frame.
const CLIENT_FPS: Array[float] = [30.0, 60.0, 75.0, 100.0, 144.0, 240.0]
const RTTS: Array[float] = [10.0, 30.0, 80.0, 160.0]


func _cfg(client_fps: float, rtt: float) -> RefCounted:
	var c: RefCounted = H.Config.new()
	c.client_fps = client_fps
	c.host_fps = 60.0  # the case that broke: host slower than its physics rate
	c.rtt_ms = rtt
	c.duration_s = 4.0
	return c


# ── The regression the harness exists for ────────────────────────────────────

func test_legacy_wall_stamping_loses_inputs_at_60fps() -> void:
	# Proof the harness has teeth. Under the old scheme two physics steps in one
	# rendered frame read the same 1 ms wall clock, produce the same stamp, and
	# the host's strictly-greater dedupe throws one away. If this test ever goes
	# green, the harness has stopped modelling the burst and every assertion
	# below it is worthless.
	var cfg: RefCounted = _cfg(60.0, 30.0)
	cfg.stamp_mode = H.StampMode.WALL_CLOCK
	var r: RefCounted = H.new().run(cfg)
	assert_gt(r.colliding_stamps, 0,
			"wall stamping must collide at 60 fps — else the burst is not modelled")
	assert_gt(r.deduped, 0, "collided stamps must be dropped by the dedupe: " + r.summary())


func test_tick_domain_stamping_never_collides_at_any_framerate() -> void:
	for fps: float in CLIENT_FPS:
		var r: RefCounted = H.new().run(_cfg(fps, 30.0))
		assert_eq(r.colliding_stamps, 0,
				"client %d fps: stamps must stay a tick apart — %s" % [int(fps), r.summary()])


# ── Delivery integrity ───────────────────────────────────────────────────────

func test_no_input_is_dropped_by_the_dedupe() -> void:
	# Every input that survives the link must be queued. A dedupe drop on a clean
	# link is a stamping bug, not a network event.
	for fps: float in CLIENT_FPS:
		for rtt: float in RTTS:
			var r: RefCounted = H.new().run(_cfg(fps, rtt))
			assert_eq(r.deduped, 0,
					"client %d fps @ %d ms: %s" % [int(fps), int(rtt), r.summary()])


# ── Queue health ─────────────────────────────────────────────────────────────

func test_backlog_drain_does_not_fire_on_a_healthy_link() -> void:
	# The drain is a lossy correction that costs the client a visible reconcile.
	# On a clean link it must never engage; if it does, either the trigger is
	# mistuned or inputs genuinely arrive late — and the whole point of tracking
	# it here is that those are different problems with different fixes.
	for fps: float in CLIENT_FPS:
		var r: RefCounted = H.new().run(_cfg(fps, 30.0))
		assert_eq(r.drains, 0,
				"client %d fps: drain fired on a clean link — %s" % [int(fps), r.summary()])


func test_queue_depth_stays_bounded() -> void:
	for fps: float in CLIENT_FPS:
		for rtt: float in RTTS:
			var r: RefCounted = H.new().run(_cfg(fps, rtt))
			assert_lt(r.queue_depth_max, 40,
					"client %d fps @ %d ms: %s" % [int(fps), int(rtt), r.summary()])


# ── The lead servo ───────────────────────────────────────────────────────────

func test_lead_servo_settles_below_its_ceiling() -> void:
	# The failure this reproduces: input_lead_extra pinned at MAX_LEAD_EXTRA_S for
	# a whole session on a 30 ms link. The servo can only be judged against a
	# clean measurement, which is what the tick clock provides.
	for fps: float in CLIENT_FPS:
		var r: RefCounted = H.new().run(_cfg(fps, 30.0))
		assert_lt(r.lead_extra_ms, 49.0,
				"client %d fps: servo saturated — %s" % [int(fps), r.summary()])


func test_overdue_is_not_inflated_by_render_cadence() -> void:
	# Pop-overdue must measure link lateness, not the host's frame cadence. Two
	# clients on the SAME link at very different framerates should measure
	# comparably; when they don't, the servo is being fed render rate.
	var slow: RefCounted = H.new().run(_cfg(60.0, 30.0))
	var fast: RefCounted = H.new().run(_cfg(240.0, 30.0))
	assert_lt(absf(slow.overdue_mean_ms - fast.overdue_mean_ms), 8.0,
			"overdue tracks framerate: 60fps=%s / 240fps=%s"
			% [slow.summary(), fast.summary()])


# ── Adverse conditions ───────────────────────────────────────────────────────

func test_jitter_and_loss_do_not_desynchronise_the_pipeline() -> void:
	var cfg: RefCounted = _cfg(60.0, 80.0)
	cfg.jitter_ms = 20.0
	cfg.loss_pct = 3.0
	var r: RefCounted = H.new().run(cfg)
	assert_eq(r.deduped, 0, "loss and jitter must not cause dedupe drops: " + r.summary())
	assert_lt(r.queue_depth_max, 60, r.summary())
