extends GutTest

# ShotReleaseRules — host-side clamping/validation of client shot-release
# claims. Lag comp is a privilege (forged inputs degrade to zero benefit),
# the shot itself is not (only the one-timer range gate rejects outright).


# ── clamp_rtt_ms ──────────────────────────────────────────────────────────────

func test_rtt_legit_value_passes_through() -> void:
	assert_almost_eq(ShotReleaseRules.clamp_rtt_ms(80.0, 75.0), 80.0, 0.001,
			"claim within measured*1.5+slack is untouched")

func test_rtt_forged_value_clamped_to_measured_ceiling() -> void:
	var clamped: float = ShotReleaseRules.clamp_rtt_ms(3000.0, 60.0)
	assert_almost_eq(clamped, 60.0 * ShotReleaseRules.RTT_MEASURED_HEADROOM
			+ ShotReleaseRules.RTT_MEASURED_SLACK_MS, 0.001,
			"forged rtt collapses to host-measured ceiling")

func test_rtt_hard_ceiling_when_no_measurement() -> void:
	assert_almost_eq(ShotReleaseRules.clamp_rtt_ms(3000.0, 0.0),
			ShotReleaseRules.MAX_RTT_MS, 0.001,
			"no ping sample yet → hard ceiling only")

func test_rtt_high_measured_ping_still_capped_at_max() -> void:
	assert_almost_eq(ShotReleaseRules.clamp_rtt_ms(1000.0, 500.0),
			ShotReleaseRules.MAX_RTT_MS, 0.001)

func test_rtt_negative_and_nan_zeroed() -> void:
	assert_almost_eq(ShotReleaseRules.clamp_rtt_ms(-50.0, 80.0), 0.0, 0.001)
	assert_almost_eq(ShotReleaseRules.clamp_rtt_ms(NAN, 80.0), 0.0, 0.001)


# ── clamp_back_date ───────────────────────────────────────────────────────────

func test_back_date_fresh_stamp_returns_elapsed() -> void:
	assert_almost_eq(ShotReleaseRules.clamp_back_date(100.0, 99.95), 0.05, 0.0001,
			"legit one-way delay back-dates by elapsed time")

func test_back_date_stale_stamp_earns_nothing() -> void:
	assert_almost_eq(ShotReleaseRules.clamp_back_date(100.0, 0.0), 0.0, 0.0001,
			"pre-warmup zero stamp (or forged old stamp) → no back-date")

func test_back_date_future_stamp_earns_nothing() -> void:
	assert_almost_eq(ShotReleaseRules.clamp_back_date(100.0, 100.5), 0.0, 0.0001)

func test_back_date_at_max_age_boundary() -> void:
	assert_almost_eq(
			ShotReleaseRules.clamp_back_date(100.0, 100.0 - ShotReleaseRules.MAX_CLAIM_AGE_S),
			ShotReleaseRules.MAX_CLAIM_AGE_S, 0.0001)


# ── is_timestamp_fresh ────────────────────────────────────────────────────────

func test_fresh_timestamp_accepted() -> void:
	assert_true(ShotReleaseRules.is_timestamp_fresh(100.0, 99.9))

func test_stale_and_future_timestamps_rejected() -> void:
	assert_false(ShotReleaseRules.is_timestamp_fresh(100.0, 99.0), "stale")
	assert_false(ShotReleaseRules.is_timestamp_fresh(100.0, 101.0), "future")
	assert_false(ShotReleaseRules.is_timestamp_fresh(100.0, NAN), "nan")


# ── sanitize_direction ────────────────────────────────────────────────────────

func test_direction_flat_shot_unchanged() -> void:
	var dir := Vector3(1, 0, 0)
	assert_eq(ShotReleaseRules.sanitize_direction(dir), dir)

func test_direction_unnormalized_input_normalized() -> void:
	var out: Vector3 = ShotReleaseRules.sanitize_direction(Vector3(10, 0, 0))
	assert_almost_eq(out.length(), 1.0, 0.001)
	assert_almost_eq(out.x, 1.0, 0.001)

func test_direction_legit_elevation_preserved() -> void:
	# ~0.46 vertical ratio is the steepest legit elevated shot.
	var dir := Vector3(1, 0.5, 0).normalized()
	var out: Vector3 = ShotReleaseRules.sanitize_direction(dir)
	assert_almost_eq(out.y, dir.y, 0.001, "below the y cap → untouched")

func test_direction_near_vertical_clamped() -> void:
	var out: Vector3 = ShotReleaseRules.sanitize_direction(Vector3(0.1, 0.99, 0).normalized())
	assert_almost_eq(out.y, ShotReleaseRules.MAX_DIRECTION_Y, 0.001)
	assert_almost_eq(out.length(), 1.0, 0.001, "still unit length after clamp")
	assert_true(out.x > 0.0, "horizontal heading preserved")

func test_direction_degenerate_inputs_rejected() -> void:
	assert_eq(ShotReleaseRules.sanitize_direction(Vector3.ZERO), Vector3.ZERO)
	assert_eq(ShotReleaseRules.sanitize_direction(Vector3.UP), Vector3.ZERO,
			"straight up has no horizontal heading")
	assert_eq(ShotReleaseRules.sanitize_direction(Vector3(NAN, 0, 1)), Vector3.ZERO)


# ── clamp_power ───────────────────────────────────────────────────────────────

func test_power_within_max_passes() -> void:
	assert_almost_eq(ShotReleaseRules.clamp_power(25.0, 34.0), 25.0, 0.001)

func test_power_forged_value_clamped() -> void:
	assert_almost_eq(ShotReleaseRules.clamp_power(500.0, 34.0), 34.0, 0.001)

func test_power_negative_and_nan_zeroed() -> void:
	assert_almost_eq(ShotReleaseRules.clamp_power(-5.0, 34.0), 0.0, 0.001)
	assert_almost_eq(ShotReleaseRules.clamp_power(NAN, 34.0), 0.0, 0.001)


# ── one_timer_in_range ────────────────────────────────────────────────────────

func test_one_timer_puck_in_zone_accepted() -> void:
	assert_true(ShotReleaseRules.one_timer_in_range(
			Vector2(0, 0), Vector2(0.3, 0), 0.5, 0.0, 0.08))

func test_one_timer_within_slack_accepted() -> void:
	# Just past radius but inside the server-side slack.
	assert_true(ShotReleaseRules.one_timer_in_range(
			Vector2(0, 0), Vector2(1.2, 0), 0.5, 0.0, 0.08))

func test_one_timer_across_rink_rejected() -> void:
	assert_false(ShotReleaseRules.one_timer_in_range(
			Vector2(0, 0), Vector2(15, 0), 0.5, 0.0, 0.08),
			"forged claim with a distant puck is rejected")

func test_one_timer_fast_puck_gets_speed_leniency() -> void:
	# 14 m/s puck adds 14 * 0.08 = 1.12 m leniency: 0.5 + 1.12 + 1.0 slack = 2.62.
	assert_true(ShotReleaseRules.one_timer_in_range(
			Vector2(0, 0), Vector2(2.5, 0), 0.5, 14.0, 0.08))
	assert_false(ShotReleaseRules.one_timer_in_range(
			Vector2(0, 0), Vector2(2.8, 0), 0.5, 14.0, 0.08))


# ── one_timer_power ───────────────────────────────────────────────────────────

func test_one_timer_power_dead_center_gets_full_bonus() -> void:
	# Puck on the zone center: proximity 1 → base * (1 + bonus).
	assert_almost_eq(ShotReleaseRules.one_timer_power(
			40.0, 0.15, Vector2(0, 0), Vector2(0, 0), 0.5), 40.0 * 1.15, 0.001)

func test_one_timer_power_edge_gets_full_penalty() -> void:
	# Puck at the radius edge: proximity 0 → base * (1 - bonus).
	assert_almost_eq(ShotReleaseRules.one_timer_power(
			40.0, 0.15, Vector2(0, 0), Vector2(0.5, 0), 0.5), 40.0 * 0.85, 0.001)

func test_one_timer_power_half_radius_is_neutral() -> void:
	# proximity 0.5 → 2*0.5 - 1 = 0 → no bonus or penalty.
	assert_almost_eq(ShotReleaseRules.one_timer_power(
			40.0, 0.15, Vector2(0, 0), Vector2(0.25, 0), 0.5), 40.0, 0.001)

func test_one_timer_power_beyond_radius_clamps_to_full_penalty() -> void:
	# Past the radius proximity clamps to 0 (not negative) → base * (1 - bonus).
	assert_almost_eq(ShotReleaseRules.one_timer_power(
			40.0, 0.15, Vector2(0, 0), Vector2(2.0, 0), 0.5), 40.0 * 0.85, 0.001)

func test_one_timer_power_zero_radius_returns_base() -> void:
	assert_almost_eq(ShotReleaseRules.one_timer_power(
			40.0, 0.15, Vector2(0, 0), Vector2(0, 0), 0.0), 40.0, 0.001)


# ── clamp_origin ──────────────────────────────────────────────────────────────

func test_origin_within_reach_passes_through() -> void:
	# 1 m from the body (< 2.5 m reach): returned unchanged, y preserved.
	var got: Vector3 = ShotReleaseRules.clamp_origin(Vector3(1.0, 0.05, 0.0), Vector3(0.0, 1.0, 0.0))
	assert_almost_eq(got, Vector3(1.0, 0.05, 0.0), Vector3(0.001, 0.001, 0.001))

func test_origin_beyond_reach_clamped_to_boundary() -> void:
	# 10 m downfield collapses onto the 2.5 m reach circle, same direction.
	var got: Vector3 = ShotReleaseRules.clamp_origin(Vector3(10.0, 0.05, 0.0), Vector3(0.0, 1.0, 0.0))
	assert_almost_eq(got, Vector3(2.5, 0.05, 0.0), Vector3(0.001, 0.001, 0.001))

func test_origin_clamp_is_horizontal_only_and_keeps_y() -> void:
	# Diagonal forged origin clamps in XZ but the client y rides through untouched.
	var got: Vector3 = ShotReleaseRules.clamp_origin(Vector3(0.0, 0.9, 10.0), Vector3(0.0, 1.0, 0.0))
	assert_almost_eq(got, Vector3(0.0, 0.9, 2.5), Vector3(0.001, 0.001, 0.001))

func test_origin_non_finite_falls_back_to_body() -> void:
	var got: Vector3 = ShotReleaseRules.clamp_origin(Vector3(NAN, 0.0, 0.0), Vector3(1.0, 1.0, 1.0))
	assert_almost_eq(got, Vector3(1.0, 1.0, 1.0), Vector3(0.001, 0.001, 0.001))
