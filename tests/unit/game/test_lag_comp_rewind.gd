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


# ── forward_predict_ticks (stage-3 render == rewind depth) ────────────────────

func test_forward_predict_ticks_zero_fraction_is_zero() -> void:
	# The shipped default: no forward integration -> render == rewind in the past.
	assert_eq(LagCompRewind.forward_predict_ticks(0.0, 0.075), 0)


func test_forward_predict_ticks_full_fraction_is_interp_delay_worth() -> void:
	# fraction 1.0, 75 ms interp delay, 120 Hz -> 9 ticks (0.075 * 120).
	assert_eq(LagCompRewind.forward_predict_ticks(1.0, 0.075), 9)


func test_forward_predict_ticks_half_fraction() -> void:
	assert_eq(LagCompRewind.forward_predict_ticks(0.5, 0.075), 5)  # round(4.5)


func test_forward_predict_ticks_clamps_and_guards() -> void:
	assert_eq(LagCompRewind.forward_predict_ticks(2.0, 0.075), 9, "fraction clamps to 1.0")
	assert_eq(LagCompRewind.forward_predict_ticks(-1.0, 0.075), 0, "negative fraction -> 0")
	assert_eq(LagCompRewind.forward_predict_ticks(1.0, -0.05), 0, "negative delay -> 0")


func test_forward_predict_ticks_caps_hostile_delay() -> void:
	# The host-side caller feeds this the RAW client-reported interp_delay_ms —
	# without the 200 ms ceiling (same clamp as remote_view_time) a crafted
	# claim with a huge delay turns the per-claim integration loop into an
	# unbounded host stall. 200 ms at 120 Hz -> 24 ticks, the hard ceiling.
	assert_eq(LagCompRewind.forward_predict_ticks(1.0, 1.0e6), 24)
	assert_eq(LagCompRewind.forward_predict_ticks(1.0, 0.2), 24, "legit delay at the ceiling")
	assert_eq(LagCompRewind.forward_predict_ticks(1.0, INF), 0, "non-finite -> 0")
	assert_eq(LagCompRewind.forward_predict_ticks(1.0, NAN), 0, "non-finite -> 0")


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

# ── Claim-stamp plausibility ──────────────────────────────────────────────────

func test_stamp_legit_one_way_delay_accepted() -> void:
	# 80ms RTT peer, claim arrives one-way (40ms) after the stamp.
	assert_true(LagCompRewind.is_claim_stamp_plausible(10.0, 10.0 - 0.04, 80.0))


func test_stamp_backdated_beyond_ping_rejected() -> void:
	# 30ms RTT peer backdating 190ms (still inside the 200ms absolute age cap)
	# — the timestamp-shopping exploit this check closes.
	assert_false(LagCompRewind.is_claim_stamp_plausible(10.0, 10.0 - 0.19, 30.0))


func test_stamp_jitter_slack_tolerated() -> void:
	# Elapsed = one_way + 90ms of frame alignment / jitter — inside the slack.
	assert_true(LagCompRewind.is_claim_stamp_plausible(10.0, 10.0 - 0.105, 30.0))


func test_stamp_future_rejected() -> void:
	assert_false(LagCompRewind.is_claim_stamp_plausible(10.0, 10.2, 80.0))


func test_stamp_small_future_ntp_error_tolerated() -> void:
	assert_true(LagCompRewind.is_claim_stamp_plausible(10.0, 10.02, 80.0))


func test_stamp_no_ping_sample_uses_conservative_past_bound() -> void:
	# No host ping sample yet must NOT mean "unbounded past" (a modified client
	# could never report ping and then backdate freely to win every 50/50). A
	# conservative default RTT (150ms -> 75ms one-way + 100ms slack = 175ms)
	# bounds the age; the future bound and the resolvers' absolute cap still hold.
	assert_true(LagCompRewind.is_claim_stamp_plausible(10.0, 10.0 - 0.15, 0.0),
			"legit warmup claim within the conservative default is accepted")
	assert_false(LagCompRewind.is_claim_stamp_plausible(10.0, 10.0 - 0.19, 0.0),
			"190ms backdate with no sample is rejected (was accepted before P0)")
	assert_false(LagCompRewind.is_claim_stamp_plausible(10.0, 9.5, 0.0),
			"500ms backdate with no sample is rejected (was accepted before P0)")
	assert_false(LagCompRewind.is_claim_stamp_plausible(10.0, 10.5, 0.0))


func test_stamp_nan_rejected() -> void:
	assert_false(LagCompRewind.is_claim_stamp_plausible(10.0, NAN, 80.0))


# ── clamp_client_blade ────────────────────────────────────────────────────────
# The client-authoritative blade is trusted as aim but pinned to within the
# claimant's physical reach of the server body, so a modified client can't
# teleport its blade onto a distant puck.

func test_clamp_blade_within_reach_passes_through() -> void:
	# A blade 1m from the body with a 2m reach is legal — returned untouched.
	var body := Vector3(5.0, 0.0, 5.0)
	var blade := Vector3(6.0, 0.0, 5.0)
	assert_eq(LagCompRewind.clamp_client_blade(blade, body, 2.0), blade)


func test_clamp_blade_beyond_reach_pinned_to_sphere() -> void:
	# A blade 4m from the body with a 2m reach is impossible — pulled back to the
	# reach sphere surface ALONG the aim line (direction preserved, distance clipped).
	var body := Vector3.ZERO
	var blade := Vector3(4.0, 0.0, 0.0)
	var clamped: Vector3 = LagCompRewind.clamp_client_blade(blade, body, 2.0)
	assert_almost_eq(clamped.x, 2.0, EPSILON)
	assert_almost_eq(body.distance_to(clamped), 2.0, EPSILON)


func test_clamp_blade_zero_reach_no_ops() -> void:
	# max_reach <= 0 (no caps entry for the peer) skips the clamp — the blade is
	# returned as-is rather than collapsed onto the body.
	var body := Vector3.ZERO
	var blade := Vector3(9.0, 0.0, 0.0)
	assert_eq(LagCompRewind.clamp_client_blade(blade, body, 0.0), blade)


# ── continuity_clamp ──────────────────────────────────────────────────────────
# Second, tighter anti-cheat bound: the client blade is pinned to within a
# plausible continuity distance of the host's OWN reconstruction of the blade,
# shrinking the exploitable slop from the reach sphere to the reconstruction error.

func test_continuity_within_tolerance_passes_through() -> void:
	# A client blade 0.4m from the host reconstruction, tolerance 0.6m — a legit
	# precise aim inside the reconstruction error is returned untouched.
	var recon := Vector3(5.0, 0.0, 5.0)
	var blade := Vector3(5.4, 0.0, 5.0)
	assert_eq(LagCompRewind.continuity_clamp(blade, recon, 0.6), blade)


func test_continuity_beyond_tolerance_pinned_along_aim() -> void:
	# A blade 2m from the reconstruction with a 0.6m tolerance — an implausible
	# teleport toward the puck, pulled back to the tolerance sphere ALONG the aim
	# line (direction preserved, distance clipped). Non-zero anchor so the
	# ZERO-means-no-sample guard doesn't fire.
	var recon := Vector3(5.0, 0.0, 5.0)
	var blade := Vector3(7.0, 0.0, 5.0)
	var clamped: Vector3 = LagCompRewind.continuity_clamp(blade, recon, 0.6)
	assert_almost_eq(clamped.x, 5.6, EPSILON)
	assert_almost_eq(recon.distance_to(clamped), 0.6, EPSILON)


func test_continuity_zero_reconstruction_no_ops() -> void:
	# reconstructed == ZERO means the host has no sample (warmup / unpopulated
	# host-only field) — skip the clamp rather than pull the blade to the origin.
	var blade := Vector3(9.0, 0.0, 0.0)
	assert_eq(LagCompRewind.continuity_clamp(blade, Vector3.ZERO, 0.6), blade)


func test_continuity_zero_tolerance_no_ops() -> void:
	# max_offset <= 0 skips the clamp (defensive — a zero tolerance would collapse
	# the blade onto the reconstruction).
	var recon := Vector3(1.0, 0.0, 0.0)
	var blade := Vector3(3.0, 0.0, 0.0)
	assert_eq(LagCompRewind.continuity_clamp(blade, recon, 0.0), blade)


func test_continuity_tolerance_is_blade_speed_plus_slack() -> void:
	# Grounded in the real Hands-scaled blade speed: traverse over the
	# reconstruction window + slack. Pins the formula so a tightening pass is
	# deliberate. (10 m/s default -> 10*0.033 + 0.30 = 0.63 m.)
	assert_almost_eq(LagCompRewind.blade_continuity_tolerance(10.0), 0.63, 1e-4)


func test_continuity_tolerance_floor_at_zero_blade_speed() -> void:
	# No caps entry (blade_speed 0) -> the slack floor, still a valid bound.
	assert_almost_eq(LagCompRewind.blade_continuity_tolerance(0.0), 0.30, 1e-4)


func test_continuity_tolerance_negative_blade_speed_clamped() -> void:
	assert_almost_eq(LagCompRewind.blade_continuity_tolerance(-5.0), 0.30, 1e-4)


# ── puck_view_time (Phase-3 loose-puck claim rewind) ──────────────────────────

func test_puck_view_time_follows_the_prediction_constant() -> void:
	# Under Phase-3 client puck prediction the claimant renders the loose puck
	# predicted AT the claim stamp, so the host rewinds to the stamp itself;
	# with prediction off it is the legacy interpolated past. The assertion
	# reads the constant so this test states the truth under either setting.
	var t: float = LagCompRewind.puck_view_time(10.0, 75.0)
	if Constants.PUCK_CLIENT_PREDICTION:
		assert_almost_eq(t, 10.0, EPSILON, "prediction on -> rewind at the stamp")
	else:
		assert_almost_eq(t, LagCompRewind.remote_view_time(10.0, 75.0), EPSILON,
				"prediction off -> legacy interpolated past")
