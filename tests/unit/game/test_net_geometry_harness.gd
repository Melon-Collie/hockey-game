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


# ── Scoring the two one-clock options ────────────────────────────────────────
#
# Both keep the puck and remote skaters on a single timeline, which is the
# constraint. They differ in WHICH timeline and in how the host answers:
#
#   A  puck rendered at H+L, host REPRODUCES the client's prediction
#   B  puck rendered at H,   host looks up truth (the local body still sits at
#                            H+L, because it cannot leave the input stamp)
#
# The tempting summary — "neither refuses an honest claim, so score them on what
# they grant" — is wrong about B, and the measurement is what says so. B still
# compares a PREDICTED puck against truth; it only shortens the span from
# one_way + lead to one_way. Halving an error is not removing it, and at 120 ms
# B still refuses ~12% of earned claims. Only reproduction removes the class.

func _option_a(rtt: float, deflect: int) -> RefCounted:
	var c: RefCounted = _cfg(rtt)
	c.deflect_every_ticks = deflect
	c.render_mode = H.RenderMode.AT_INPUT_STAMP
	c.adjudication = H.AdjudicationMode.REPRODUCE_CLIENT_VIEW
	return c


func _option_b(rtt: float, deflect: int) -> RefCounted:
	var c: RefCounted = _cfg(rtt)
	c.deflect_every_ticks = deflect
	c.render_mode = H.RenderMode.AT_HOST_PRESENT
	c.adjudication = H.AdjudicationMode.LOOKUP_TRUTH
	return c


func test_only_reproduction_eliminates_refusals() -> void:
	# A refuses nothing at any latency, because it never compares the client's
	# prediction to anything the client could not see. That is a property of the
	# rule, not of the link — which is why it holds across the whole matrix.
	for rtt: float in RTTS_MS:
		var a: RefCounted = H.new().run(_option_a(rtt, 12))
		assert_gt(a.host_confirms, 0, "rtt %d: vacuous" % int(rtt))
		assert_eq(a.false_negatives, 0, "rtt %d option A — %s" % [int(rtt), a.summary()])


func test_option_b_shortens_the_span_but_still_refuses() -> void:
	# The correction to the obvious reading of B. Drawing the puck at H removes
	# the LEAD from the prediction span, not the trip, so a bad link still
	# refuses earned claims — just at the rate a link half as long would have.
	var b_far: RefCounted = H.new().run(_option_b(120.0, 12))
	var shipping: RefCounted = _cfg(60.0)
	shipping.deflect_every_ticks = 12
	var s: RefCounted = H.new().run(shipping)
	assert_gt(b_far.false_negatives, 0,
			"B is not refusal-free — it predicts too, just over a shorter span: "
			+ b_far.summary())
	assert_almost_eq(b_far.mean_puck_error_m, s.mean_puck_error_m, 0.02,
			"B at 120ms should predict about as well as shipping at 60ms — the lead "
			+ "is worth roughly one RTT here: b120=%s / ship60=%s"
			% [b_far.summary(), s.summary()])


func test_reproduction_grants_exactly_what_the_client_predicted() -> void:
	# Faithfulness check on the mode itself: if the host is really re-running the
	# client's dead reckon, then the error in what it grants IS the client's
	# prediction error, to the last decimal. A divergence here means the mode is
	# measuring some other computation and every number above it is suspect.
	for rtt: float in RTTS_MS:
		var a: RefCounted = H.new().run(_option_a(rtt, 12))
		assert_almost_eq(a.mean_grant_staleness_m, a.mean_puck_error_m, 0.001,
				"rtt %d: reproduction is not reproducing — %s" % [int(rtt), a.summary()])


func test_option_b_pays_on_every_grant_even_on_a_perfect_link() -> void:
	# The discriminator. With nothing to mispredict, A grants against the real
	# puck and costs exactly nothing; B still adjudicates a puck a full input
	# lead stale, because the blade it is compared against lives at H+L while the
	# puck was rendered at H. That cost is structural — it does not depend on
	# latency, jitter, or anything going wrong.
	var a: RefCounted = H.new().run(_option_a(30.0, 0))
	var b: RefCounted = H.new().run(_option_b(30.0, 0))
	assert_gt(a.host_confirms, 0, "option A produced no grants to score: " + a.summary())
	assert_gt(b.host_confirms, 0, "option B produced no grants to score: " + b.summary())
	assert_almost_eq(a.mean_grant_staleness_m, 0.0, 0.01,
			"nothing to mispredict, so A must grant against truth: " + a.summary())
	assert_gt(b.mean_grant_staleness_m, 0.2,
			"B grants a puck roughly puck_speed x lead stale: " + b.summary())


func test_option_b_skews_the_picture_and_option_a_does_not() -> void:
	# What the player looks at rather than what the host decides. Under B the
	# puck being aimed at and the body doing the aiming are on different
	# timelines, so the gap is there on every frame whether or not anyone reaches
	# for it. It is also the thing puck-at-H+L was adopted to remove.
	var a: RefCounted = H.new().run(_option_a(30.0, 0))
	var b: RefCounted = H.new().run(_option_b(30.0, 0))
	assert_almost_eq(a.render_skew_m, 0.0, 0.001,
			"one timeline means no skew: " + a.summary())
	assert_gt(b.render_skew_m, 0.2, "B's puck trails the player's own body: " + b.summary())


func test_option_a_only_costs_when_the_puck_does_something() -> void:
	# A's grants are wrong exactly as often as the client's prediction was, so
	# its cost scales with unmodelled events and with span — unlike B's, which is
	# a fixed tax. This is the shape that decides the trade.
	var quiet: RefCounted = H.new().run(_option_a(30.0, 0))
	var busy: RefCounted = H.new().run(_option_a(30.0, 12))
	assert_gt(busy.mean_grant_staleness_m, quiet.mean_grant_staleness_m,
			"quiet=%s / busy=%s" % [quiet.summary(), busy.summary()])
	assert_gt(busy.phantom_grants, 0,
			"a deflected puck must sometimes be granted after it left: " + busy.summary())


func test_option_a_cost_grows_with_latency() -> void:
	# Reproduction is only as good as the prediction it reproduces, so A inherits
	# the span dependence the shipping arrangement pays as refusals. The choice
	# is which side of the same error the player experiences.
	var near: RefCounted = H.new().run(_option_a(10.0, 12))
	var far: RefCounted = H.new().run(_option_a(120.0, 12))
	assert_gt(far.mean_grant_staleness_m, near.mean_grant_staleness_m,
			"10ms=%s / 120ms=%s" % [near.summary(), far.summary()])


func test_reproduction_needs_the_claims_own_base_snapshot() -> void:
	# Teeth for option A. Reproducing the client's view means predicting from the
	# snapshot the CLIENT had; if the host guesses that from its RTT estimate it
	# can pick a newer one, know about a deflection the client did not, and start
	# refusing honest claims again — which is the defect A exists to remove. So a
	# claim has to carry the stamp it predicted from.
	var cfg: RefCounted = _option_a(30.0, 12)
	cfg.base_stamp_error_ticks = 4
	var r: RefCounted = H.new().run(cfg)
	assert_gt(r.false_negatives, 0,
			"a wrong base must break reproduction — else the test proves nothing "
			+ "about needing the real one: " + r.summary())


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
