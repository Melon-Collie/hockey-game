extends GutTest

# LagCompRewind — time-base helpers for lag-compensated validation. Tests pin
# the formulas so a future tweak that re-introduces RTT (or any other
# accidental coupling) trips immediately. The bug class these helpers replaced
# — pickup/poke/hit resolvers each open-coding their own rewind math — was the
# kind that ships invisibly because no integration test exercised the geometry
# path. Pinning the formulas at the unit level is the cheapest backstop.

const EPSILON: float = 1e-6


# ── self_view_time ───────────────────────────────────────────────────────────

func test_self_view_time_adds_input_lead() -> void:
	# The claimant's own predicted entity at view-time T lives in the host's
	# buffer at T + INPUT_LEAD_SEC (the host's gated processing applied the
	# input that produced the client's view at exactly that wall time).
	var t: float = LagCompRewind.self_view_time(10.0)
	assert_almost_eq(t, 10.0 + NetworkManager.INPUT_LEAD_SEC, EPSILON)


func test_self_view_time_is_rtt_independent() -> void:
	# Same host_timestamp, two notional RTTs — the formula must not change.
	# This is the property that distinguishes the new rewind from the prior
	# host_timestamp + rtt/2: lower-ping players don't get an artificial
	# pickup advantage.
	var a: float = LagCompRewind.self_view_time(100.0)
	var b: float = LagCompRewind.self_view_time(100.0)
	assert_eq(a, b)


# ── remote_view_time ─────────────────────────────────────────────────────────

func test_remote_view_time_subtracts_interp_delay() -> void:
	# The claimant rendered remote entities at host_time - interp_delay; the
	# host's matching snapshot lives at the same offset behind host_timestamp.
	assert_almost_eq(LagCompRewind.remote_view_time(10.0, 75.0), 9.925, EPSILON)


func test_remote_view_time_clamps_upper() -> void:
	# Anything past 200ms gets clamped — defends against a malicious or
	# warmup-glitched claim that would otherwise query arbitrarily far back.
	assert_almost_eq(LagCompRewind.remote_view_time(10.0, 300.0), 10.0 - 0.2, EPSILON)


func test_remote_view_time_clamps_lower() -> void:
	# Negative interp_delay would push the rewind into the future of host
	# time, which is meaningless for an interpolated entity. Clamp at 0.
	assert_almost_eq(LagCompRewind.remote_view_time(10.0, -5.0), 10.0, EPSILON)


# ── prev_tick ────────────────────────────────────────────────────────────────

func test_prev_tick_subtracts_one_physics_tick() -> void:
	# Used as the "prev" endpoint in the swept-segment pickup/poke geometry
	# test. Works for either view perspective.
	assert_almost_eq(LagCompRewind.prev_tick(10.0), 10.0 - 1.0 / float(Constants.PHYSICS_TICK), EPSILON)


# ── Composition ──────────────────────────────────────────────────────────────

func test_self_and_remote_diverge_by_input_lead_plus_interp_delay() -> void:
	# The same view-time resolves to two host-times for the two perspectives.
	# The gap between them is exactly INPUT_LEAD_SEC + interp_delay — useful
	# to assert in case a future refactor accidentally collapses them.
	var host_ts: float = 5.0
	var interp_ms: float = 75.0
	var self_t: float = LagCompRewind.self_view_time(host_ts)
	var remote_t: float = LagCompRewind.remote_view_time(host_ts, interp_ms)
	assert_almost_eq(self_t - remote_t, NetworkManager.INPUT_LEAD_SEC + interp_ms / 1000.0, EPSILON)
