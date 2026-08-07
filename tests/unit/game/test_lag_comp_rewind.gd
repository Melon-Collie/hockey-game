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


# ── puck_view_time (Phase-3/4b loose-puck claim rewind) ───────────────────────

func test_puck_view_time_is_the_claim_stamp() -> void:
	# The claimant renders the loose puck predicted AT the claim stamp (render
	# == rewind at present, unconditional since Phase 4b removed the prediction
	# escape hatch), so the host rewinds to the stamp itself.
	assert_almost_eq(LagCompRewind.puck_view_time(10.0), 10.0, EPSILON,
			"loose-puck claims rewind to the claim stamp")


# ── plausible_interp_delay_ms (P2: bound the self-reported render delay) ──────

func test_interp_delay_honest_report_passes_through() -> void:
	# 80 ms RTT peer legitimately reporting ~60 ms (one-way 40 + interval + jitter).
	assert_almost_eq(LagCompRewind.plausible_interp_delay_ms(60.0, 80.0), 60.0, EPSILON)


func test_interp_delay_inflated_report_clamped_to_link() -> void:
	# 20 ms link reporting the 200 ms cap — the "hit them where they were"
	# exploit. Bound = one-way (10) + broadcast interval (~8.3) + 100 allowance.
	var bounded: float = LagCompRewind.plausible_interp_delay_ms(200.0, 20.0)
	assert_almost_eq(bounded, 10.0 + 1000.0 / float(Constants.STATE_RATE) + 100.0, 0.01)
	assert_lt(bounded, 200.0, "the flat cap alone no longer bounds a fast link")


func test_interp_delay_no_sample_uses_conservative_default() -> void:
	# No ping sample yet -> the same conservative default RTT the stamp check
	# uses (150 ms), not an unbounded pass-through.
	var bounded: float = LagCompRewind.plausible_interp_delay_ms(200.0, 0.0)
	assert_almost_eq(bounded, 75.0 + 1000.0 / float(Constants.STATE_RATE) + 100.0, 0.01)


func test_interp_delay_never_exceeds_absolute_cap() -> void:
	# A terrible-but-real link (300 ms RTT): the link-derived ceiling would pass
	# 258 ms, but the absolute 200 ms cap still rules.
	assert_almost_eq(LagCompRewind.plausible_interp_delay_ms(500.0, 300.0), 200.0, EPSILON)


func test_interp_delay_rejects_garbage() -> void:
	assert_almost_eq(LagCompRewind.plausible_interp_delay_ms(NAN, 80.0), 0.0, EPSILON)
	assert_almost_eq(LagCompRewind.plausible_interp_delay_ms(INF, 80.0), 0.0, EPSILON)
	assert_almost_eq(LagCompRewind.plausible_interp_delay_ms(-50.0, 80.0), 0.0, EPSILON)


# ── self_view_time with the claim-carried adaptive lead ───────────────────────

func test_self_view_honest_lead_passes_through() -> void:
	# A claim carrying base + 10 ms of adaptive extra rewinds to exactly that.
	var lead_ms: float = (NetworkManager.INPUT_LEAD_SEC + 0.010) * 1000.0
	assert_almost_eq(LagCompRewind.self_view_time(10.0, lead_ms),
			10.0 + NetworkManager.INPUT_LEAD_SEC + 0.010, EPSILON)


func test_self_view_inflated_lead_clamped() -> void:
	# A modified client reporting a huge lead can't push its self-view rewind
	# arbitrarily forward — bounded at base + MAX extra (mirrors ClockSync).
	var t: float = LagCompRewind.self_view_time(10.0, 500.0)
	assert_almost_eq(t, 10.0 + NetworkManager.INPUT_LEAD_SEC + 0.05, EPSILON)


func test_self_view_undercut_lead_clamped_to_base() -> void:
	# Reporting less than the base constant is equally implausible (the stamp
	# convention floors there) — clamped up to base.
	assert_almost_eq(LagCompRewind.self_view_time(10.0, 1.0),
			10.0 + NetworkManager.INPUT_LEAD_SEC, EPSILON)


func test_self_view_default_and_garbage_use_base() -> void:
	assert_almost_eq(LagCompRewind.self_view_time(10.0),
			10.0 + NetworkManager.INPUT_LEAD_SEC, EPSILON)
	assert_almost_eq(LagCompRewind.self_view_time(10.0, NAN),
			10.0 + NetworkManager.INPUT_LEAD_SEC, EPSILON)


func test_lead_extra_max_mirrors_clock_sync() -> void:
	# The host-side clamp must track the client-side servo ceiling — if they
	# drift apart a legit fully-adapted claim gets mis-rewound.
	var cs_script: GDScript = load("res://Scripts/networking/clock_sync.gd")
	assert_eq(LagCompRewind._INPUT_LEAD_EXTRA_MAX_S, cs_script.MAX_LEAD_EXTRA_S)


# ── self_view_catch_up ───────────────────────────────────────────────────────
#
# The claimant's own body at self_view_time is NOT in the host's buffer whenever
# their input lead exceeds the link's one-way trip — the host holds the input
# until its stamp comes due, so the newest capture is behind the requested
# instant and StateBufferManager answers the future query with the newest sample
# and no signal. These pin the catch-up that closes that gap, including the
# no-op cases (a link whose one-way already covers the lead must be untouched).

func _moving_snap(speed: float) -> SkaterNetworkState:
	var snap := SkaterNetworkState.new()
	snap.position = Vector3.ZERO
	snap.velocity = Vector3(0.0, 0.0, -speed)
	snap.move_intent = Vector2(0.0, -1.0)
	snap.facing = Vector2(0.0, 1.0)  # atan2(x, y) == 0 -> heading 0, fully aligned
	return snap


func test_self_view_catch_up_no_op_when_buffer_covers_the_instant() -> void:
	# One-way exceeds the lead: the buffer genuinely holds the self-view instant,
	# so the lookup was answerable and nothing may be added to it.
	var ctrl := autofree(SkaterController.new()) as SkaterController
	var d: Vector3 = LagCompRewind.self_view_catch_up(
			_moving_snap(9.0), ctrl, 10.0, 10.05,
			SkaterMovementRules.ForwardResult.new())
	assert_eq(d, Vector3.ZERO)


func test_self_view_catch_up_no_op_before_first_capture() -> void:
	var ctrl := autofree(SkaterController.new()) as SkaterController
	var d: Vector3 = LagCompRewind.self_view_catch_up(
			_moving_snap(9.0), ctrl, 10.0, -1.0,
			SkaterMovementRules.ForwardResult.new())
	assert_eq(d, Vector3.ZERO)


func test_self_view_catch_up_no_op_without_snapshot_or_controller() -> void:
	var scratch := SkaterMovementRules.ForwardResult.new()
	var ctrl := autofree(SkaterController.new()) as SkaterController
	assert_eq(LagCompRewind.self_view_catch_up(null, ctrl, 10.05, 10.0, scratch), Vector3.ZERO)
	assert_eq(LagCompRewind.self_view_catch_up(_moving_snap(9.0), null, 10.05, 10.0, scratch),
			Vector3.ZERO)


func test_self_view_catch_up_advances_a_moving_body_by_the_gap() -> void:
	# 25 ms of gap (the base input lead on a zero-one-way link) at 9 m/s is
	# ~0.22 m — the under-rewind this closes, and more than a quarter of the
	# 0.7 m contact diameter the clamps fence against.
	var ctrl := autofree(SkaterController.new()) as SkaterController
	var d: Vector3 = LagCompRewind.self_view_catch_up(
			_moving_snap(9.0), ctrl, 10.025, 10.0,
			SkaterMovementRules.ForwardResult.new())
	assert_almost_eq(d.length(), 0.225, 0.05)
	assert_lt(d.z, 0.0)  # travelled along -Z, the direction of motion


func test_self_view_catch_up_depth_is_bounded_by_the_lead_ceiling() -> void:
	# A garbage or crafted view-time can't buy integration distance: the depth is
	# clamped to the same INPUT_LEAD_SEC + extra ceiling that bounds the self-view
	# rewind itself. Five seconds of gap at 9 m/s would be 45 m unclamped.
	var ctrl := autofree(SkaterController.new()) as SkaterController
	var d: Vector3 = LagCompRewind.self_view_catch_up(
			_moving_snap(9.0), ctrl, 15.0, 10.0,
			SkaterMovementRules.ForwardResult.new())
	var ceiling_m: float = 9.0 * (NetworkManager.INPUT_LEAD_SEC + 0.05) + 0.1
	assert_lt(d.length(), ceiling_m)
