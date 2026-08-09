extends GutTest

# Claim-rewind answerability across a latency x lead matrix.
#
# The bug these exist for is silent by construction: StateBufferManager answers a
# future query with its newest sample and no error, so a resolver asking for an
# instant the host has not simulated gets a plausible-looking wrong answer. The
# only way to catch it is to assert the lookup was in range BEFORE trusting it.
#
# test_resolving_on_arrival_overruns_the_buffer is the teeth: it asserts the
# legacy resolve-on-arrival path still overruns. If that goes green the harness
# has stopped modelling the gap and everything below it is worthless.

const H := preload("res://tests/harness/net_rewind_harness.gd")

# The lead is what the servo settles on; it has been observed anywhere from the
# 25 ms base to the 50 ms-extra ceiling, so the matrix covers the range.
const LEADS_MS: Array[float] = [25.0, 40.0, 60.0, 75.0]
const RTTS_MS: Array[float] = [10.0, 30.0, 60.0, 120.0, 200.0]


func _cfg(rtt: float, lead: float) -> RefCounted:
	var c: RefCounted = H.Config.new()
	c.rtt_ms = rtt
	c.input_lead_ms = lead
	# What _compute_target_interpolation_delay produces: rtt/2 + one broadcast
	# interval + jitter margin.
	c.interp_delay_ms = rtt / 2.0 + 16.7 + 10.0
	c.duration_s = 3.0
	return c


# ── Teeth ────────────────────────────────────────────────────────────────────

func test_resolving_on_arrival_overruns_the_buffer() -> void:
	# A claim lands one_way after it was stamped, but names an instant a full
	# input lead ahead of its stamp. Whenever lead > one_way — every link under
	# roughly twice the lead — the host has not simulated that instant yet.
	var cfg: RefCounted = _cfg(30.0, 75.0)
	cfg.resolve_mode = H.ResolveMode.ON_ARRIVAL
	var r: RefCounted = H.new().run(cfg)
	assert_gt(r.self_view_past_newest, 0,
			"resolve-on-arrival must overrun the buffer — else the gap is not modelled")
	assert_gt(r.max_lookup_overrun_ms, 40.0,
			"overrun should be about (lead - one_way): " + r.summary())


func test_a_fast_link_overruns_worse_than_a_slow_one() -> void:
	# The counter-intuitive shape that made this hard to find by playing: the
	# CLEANER the connection, the further past the buffer the lookup lands.
	var fast: RefCounted = _cfg(10.0, 75.0)
	fast.resolve_mode = H.ResolveMode.ON_ARRIVAL
	var slow: RefCounted = _cfg(120.0, 75.0)
	slow.resolve_mode = H.ResolveMode.ON_ARRIVAL
	var rf: RefCounted = H.new().run(fast)
	var rs: RefCounted = H.new().run(slow)
	assert_gt(rf.max_lookup_overrun_ms, rs.max_lookup_overrun_ms,
			"10ms link=%s / 120ms link=%s" % [rf.summary(), rs.summary()])


# ── Answerability ────────────────────────────────────────────────────────────

func test_deferred_claims_never_query_past_the_buffer() -> void:
	for rtt: float in RTTS_MS:
		for lead: float in LEADS_MS:
			var r: RefCounted = H.new().run(_cfg(rtt, lead))
			assert_eq(r.self_view_past_newest, 0,
					"rtt %d / lead %d: self-view overran — %s"
					% [int(rtt), int(lead), r.summary()])
			assert_eq(r.puck_view_past_newest, 0,
					"rtt %d / lead %d: puck-view overran — %s"
					% [int(rtt), int(lead), r.summary()])


func test_remote_view_is_always_in_range() -> void:
	# remote_view_time reaches BACKWARD, so it can only fail by falling off the
	# old end of the ring — the opposite failure from the self view.
	for rtt: float in RTTS_MS:
		for lead: float in LEADS_MS:
			var r: RefCounted = H.new().run(_cfg(rtt, lead))
			assert_eq(r.remote_view_past_newest, 0, r.summary())
			assert_eq(r.view_before_oldest, 0,
					"rtt %d: remote view fell off the ring — %s" % [int(rtt), r.summary()])


func test_every_claim_eventually_resolves() -> void:
	# Deferral must not strand a claim. If the release condition can't be met the
	# claim silently never adjudicates, which reads in-game as a dead poke.
	for rtt: float in RTTS_MS:
		var r: RefCounted = H.new().run(_cfg(rtt, 75.0))
		assert_gt(r.resolved, r.claims - 5,
				"rtt %d: claims stranded — %s" % [int(rtt), r.summary()])


# ── Buffer fidelity ──────────────────────────────────────────────────────────

func test_interpolated_lookup_matches_the_known_trajectory() -> void:
	# Straight-line motion has a closed form, so a bracket-search or lerp
	# regression surfaces as a position error rather than a plausible number.
	for rtt: float in RTTS_MS:
		var r: RefCounted = H.new().run(_cfg(rtt, 25.0))
		assert_lt(r.max_interp_error_m, 0.02,
				"rtt %d: buffer interpolation drifted — %s" % [int(rtt), r.summary()])


# ── render == rewind ─────────────────────────────────────────────────────────

func test_client_and_host_agree_on_forward_predict_depth() -> void:
	# The invariant that three call sites have to maintain by hand. A caller that
	# re-derives the lead or the fraction locally instead of taking the
	# claim-carried value shows up here as a depth mismatch.
	for rtt: float in RTTS_MS:
		for lead: float in LEADS_MS:
			var r: RefCounted = H.new().run(_cfg(rtt, lead))
			assert_eq(r.depth_mismatches, 0,
					"rtt %d / lead %d: %s" % [int(rtt), int(lead), r.summary()])
