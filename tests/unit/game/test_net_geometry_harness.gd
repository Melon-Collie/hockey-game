extends GutTest

# Claim geometry: when the client sees its blade reach the puck, does the host's
# rewind agree?
#
# This is the quantity behind the playtest's 45% pickup-claim miss rate. The
# other two harnesses assert the lookup was in RANGE; this one asserts the
# ANSWER was right. Because the blade is exact on both sides here, every
# disagreement is puck prediction error — a false negative is a claim the player
# earned and the host refused.

const H := preload("res://tests/harness/net_geometry_harness.gd")

const RTTS_MS: Array[float] = [10.0, 30.0, 60.0, 120.0]


func _cfg(rtt: float) -> RefCounted:
	var c: RefCounted = H.Config.new()
	c.rtt_ms = rtt
	c.duration_s = 6.0
	return c


# ── The clean case ───────────────────────────────────────────────────────────

func test_an_unperturbed_puck_is_never_refused() -> void:
	# Nothing the client cannot know about: prediction is exact and the host must
	# confirm every claim. A failure here is a rewind or view-time defect, not a
	# prediction one — there is nothing to mispredict.
	for rtt: float in RTTS_MS:
		var r: RefCounted = H.new().run(_cfg(rtt))
		assert_gt(r.client_hits, 0, "rtt %d: no claims produced, test is vacuous" % int(rtt))
		assert_eq(r.false_negatives, 0,
				"rtt %d: host refused a claim with nothing to mispredict — %s"
				% [int(rtt), r.summary()])


# ── Teeth: prediction span is what costs claims ──────────────────────────────

func test_unmodelled_deflections_cost_claims() -> void:
	# The host perturbs the puck in ways the client is told about only a snapshot
	# later. This is the real mechanism behind a miss, and it must show up.
	var cfg: RefCounted = _cfg(60.0)
	cfg.deflect_every_ticks = 12
	var r: RefCounted = H.new().run(cfg)
	assert_gt(r.false_negatives, 0,
			"deflections must cost claims — else the harness cannot see the effect: "
			+ r.summary())


func test_a_longer_render_span_raises_the_miss_rate() -> void:
	# The regression flagged when the clock unification moved the puck from
	# host-present to host-present + input lead. A single playtest could not
	# separate it from everything else that changed; here it is isolated.
	var present: RefCounted = _cfg(60.0)
	present.deflect_every_ticks = 12
	present.render_mode = H.RenderMode.AT_HOST_PRESENT
	var stamped: RefCounted = _cfg(60.0)
	stamped.deflect_every_ticks = 12
	stamped.render_mode = H.RenderMode.AT_INPUT_STAMP

	var rp: RefCounted = H.new().run(present)
	var rs: RefCounted = H.new().run(stamped)
	assert_gt(rs.mean_puck_error_m, rp.mean_puck_error_m,
			"the longer span must predict less accurately: at_present=%s / at_stamp=%s"
			% [rp.summary(), rs.summary()])


func test_prediction_error_grows_with_latency() -> void:
	# Span is one_way + lead, so a worse link predicts further and misses more.
	# Pins the direction; the magnitude is what the playtest telemetry reads
	# against.
	var near: RefCounted = _cfg(10.0)
	near.deflect_every_ticks = 12
	var far: RefCounted = _cfg(120.0)
	far.deflect_every_ticks = 12
	var rn: RefCounted = H.new().run(near)
	var rf: RefCounted = H.new().run(far)
	assert_gt(rf.mean_puck_error_m, rn.mean_puck_error_m,
			"10ms=%s / 120ms=%s" % [rn.summary(), rf.summary()])


# ── Bounds ───────────────────────────────────────────────────────────────────

func test_miss_rate_stays_tolerable_under_realistic_disturbance() -> void:
	# A characterisation bound, not a law. Occasional deflections at a normal
	# ping should not cost a large share of claims. If this starts failing, read
	# it as "the geometry got worse", not "loosen the number" — and check it
	# against the host row's pickup_claim_misses before re-pinning.
	var cfg: RefCounted = _cfg(30.0)
	cfg.deflect_every_ticks = 40
	var r: RefCounted = H.new().run(cfg)
	assert_lt(r.miss_rate(), 0.25,
			"more than a quarter of earned claims refused — " + r.summary())


func test_error_does_not_accumulate_across_deflections() -> void:
	# Each snapshot re-seeds the prediction, so an unmodelled event costs a
	# bounded excursion rather than a drift. A max error far above the mean is
	# expected; a max that scales with run length is not.
	var cfg: RefCounted = _cfg(30.0)
	cfg.deflect_every_ticks = 12
	var short_run: RefCounted = H.new().run(cfg)
	cfg.duration_s = 18.0
	var long_run: RefCounted = H.new().run(cfg)
	assert_lt(long_run.max_puck_error_m, short_run.max_puck_error_m * 2.0,
			"error accumulates instead of re-seeding: short=%s / long=%s"
			% [short_run.summary(), long_run.summary()])
