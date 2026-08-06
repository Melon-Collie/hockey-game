extends GutTest

# ShotReleaseRules — host-side clamping/validation on the shot-release path.
# Lag comp is a privilege (a bad timestamp degrades to zero benefit), the shot
# itself is not (only the one-timer contact test refuses one outright).


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
	# The steepest legit lofted shot is a 45° soft flip (MAX_LOFT_RATIO), a
	# normalized y of ~0.707 — it must pass through the clamp untouched.
	var dir := Vector3(1, 1, 0).normalized()
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


# ── one_timer_claim_blocked ───────────────────────────────────────────────────

func test_one_timer_claim_allowed_when_nothing_objects() -> void:
	assert_false(ShotReleaseRules.one_timer_claim_blocked(false, false, false, false, false),
			"a loose puck, live phase, healthy shooter off cooldown — the claim stands")


func test_one_timer_claim_blocked_by_each_reason_alone() -> void:
	assert_true(ShotReleaseRules.one_timer_claim_blocked(true, false, false, false, false),
			"someone already carries the puck")
	assert_true(ShotReleaseRules.one_timer_claim_blocked(false, true, false, false, false),
			"pickup is locked (dead-puck phase)")
	assert_true(ShotReleaseRules.one_timer_claim_blocked(false, false, true, false, false),
			"movement is locked")
	assert_true(ShotReleaseRules.one_timer_claim_blocked(false, false, false, true, false),
			"the shooter is a ghost")


# The regression this clause exists for. When the host's own sim of the shooter
# already fired this swing as a carried slapshot, the puck it released is LOOSE
# again — so the carrier check passes and, without the cooldown, the very same
# swing's claim fires the puck a second time. The releasing skater's reattach
# cooldown is the only surviving evidence that the shot already happened.
func test_one_timer_claim_blocked_after_the_shooter_just_released() -> void:
	assert_true(
			ShotReleaseRules.one_timer_claim_blocked(false, false, false, false, true),
			"a shooter inside their own reattach cooldown cannot re-fire the puck they just released")


# ── one_timer_claim_is_stale ──────────────────────────────────────────────────

func test_one_timer_claim_fresh_when_the_puck_was_last_played_before_the_swing() -> void:
	# The feed that set this one-timer up IS a release, and it necessarily
	# predates the swing that answers it. The common case must not be rejected.
	assert_false(ShotReleaseRules.one_timer_claim_is_stale(10.0, 9.4),
			"the pass being one-timed was played before the claim was stamped")


func test_one_timer_claim_fresh_when_the_puck_has_never_been_played() -> void:
	assert_false(ShotReleaseRules.one_timer_claim_is_stale(10.0, -1.0),
			"an untouched puck (faceoff drop) blocks nothing")


# The second double-fire shape: two shooters commit on the same feed, the first
# claim to land fires the puck and leaves it LOOSE, so the carrier check cannot
# see that the contest is already resolved. The loser must whiff rather than drag
# the puck back out of its flight and re-fire it.
func test_one_timer_claim_stale_once_the_puck_is_already_in_flight() -> void:
	assert_true(ShotReleaseRules.one_timer_claim_is_stale(10.0, 10.05),
			"someone played the puck after this swing committed — the swing missed")


# ── one_timer_window_grace ────────────────────────────────────────────────────
#
# The host arms a remote carrier's one-timer window on its own pickup tick; that
# carrier arms it one way later and releases an input lead before the host sees
# it. The grace is what keeps the client's honest window inside the host's.

const LEAD_S: float = 0.033
const BROADCAST_S: float = 1.0 / 60.0


func test_window_grace_covers_the_round_trip_offset() -> void:
	# 100 ms link: 50 ms one way + 33 ms lead + one broadcast interval.
	assert_almost_eq(
			ShotReleaseRules.one_timer_window_grace(100.0, LEAD_S, BROADCAST_S),
			0.05 + LEAD_S + BROADCAST_S, 0.0001,
			"the host holds its deadline open by exactly the arming offset")

func test_window_grace_is_zero_without_a_ping_sample() -> void:
	# No sample (host player, bot, or a peer measured at 0) — nothing to cover,
	# and the honest window is already the right one.
	assert_almost_eq(ShotReleaseRules.one_timer_window_grace(0.0, LEAD_S, BROADCAST_S), 0.0, 0.0001)
	assert_almost_eq(ShotReleaseRules.one_timer_window_grace(-5.0, LEAD_S, BROADCAST_S), 0.0, 0.0001)
	assert_almost_eq(ShotReleaseRules.one_timer_window_grace(NAN, LEAD_S, BROADCAST_S), 0.0, 0.0001)

func test_window_grace_is_capped() -> void:
	# A garbage ping reading must not hold a wind-up open indefinitely.
	assert_almost_eq(
			ShotReleaseRules.one_timer_window_grace(9000.0, LEAD_S, BROADCAST_S),
			ShotReleaseRules.ONE_TIMER_WINDOW_GRACE_MAX_S, 0.0001)

func test_window_grace_grows_with_the_link() -> void:
	assert_gt(ShotReleaseRules.one_timer_window_grace(200.0, LEAD_S, BROADCAST_S),
			ShotReleaseRules.one_timer_window_grace(40.0, LEAD_S, BROADCAST_S),
			"a worse link needs more of the host's deadline held open")


# ── one_timer_connects ────────────────────────────────────────────────────────
#
# The shipped window: back = one_timer_retention_time + one_timer_leniency_time
# (0.19 s), forward = one_timer_leniency_time (0.08 s), zone radius 0.5 m.

const BACK_S: float = 0.19
const FWD_S: float = 0.08
const ZONE_R: float = 0.5


func _connects(zone: Vector2, puck: Vector2, vel: Vector2, airborne: bool = false) -> bool:
	return ShotReleaseRules.one_timer_connects(
			zone, ZONE_R, puck, vel, airborne, BACK_S, FWD_S)


func test_one_timer_still_puck_inside_the_zone_connects() -> void:
	assert_true(_connects(Vector2.ZERO, Vector2(0.3, 0.0), Vector2.ZERO))

func test_one_timer_still_puck_outside_the_zone_whiffs() -> void:
	# Nothing to forgive: a stationary puck out of reach was never reachable.
	assert_false(_connects(Vector2.ZERO, Vector2(0.7, 0.0), Vector2.ZERO))

func test_one_timer_forgives_a_puck_already_past_the_zone() -> void:
	# 20 m/s feed judged at the end of the hold: the puck sits 0.15 s (3 m) past
	# the zone, inside the 0.19 s look-back, so the swing met it on the way
	# through.
	assert_true(_connects(Vector2.ZERO, Vector2(3.0, 0.0), Vector2(20.0, 0.0)))

func test_one_timer_whiffs_a_puck_too_far_past_the_zone() -> void:
	# 0.25 s (5 m) past on the same feed — the player committed late enough that
	# the blade came down behind the puck.
	assert_false(_connects(Vector2.ZERO, Vector2(5.0, 0.0), Vector2(20.0, 0.0)))

func test_one_timer_forgives_a_puck_not_yet_arrived() -> void:
	# 1 m short on a 20 m/s feed is 0.05 s early, inside the 0.08 s forward
	# window; 2.5 m short is past even the window plus the zone's own radius.
	assert_true(_connects(Vector2.ZERO, Vector2(-1.0, 0.0), Vector2(20.0, 0.0)))
	assert_false(_connects(Vector2.ZERO, Vector2(-2.5, 0.0), Vector2(20.0, 0.0)))

func test_one_timer_leniency_is_timing_only_never_width() -> void:
	# THE regression this test file exists for: the ring the contact test
	# replaced inflated isotropically by speed × time, so on a 20 m/s feed a
	# puck ~4 m WIDE of the shooter connected. Along the line, 3 m is forgiven;
	# across it, 1 m is not.
	assert_true(_connects(Vector2.ZERO, Vector2(3.0, 0.0), Vector2(20.0, 0.0)))
	assert_false(_connects(Vector2.ZERO, Vector2(0.0, 1.0), Vector2(20.0, 0.0)),
			"a puck a metre off the line is unreachable at any speed")
	assert_false(_connects(Vector2.ZERO, Vector2(3.0, 4.0), Vector2(20.0, 0.0)))

func test_one_timer_across_rink_whiffs() -> void:
	assert_false(_connects(Vector2.ZERO, Vector2(15.0, 0.0), Vector2(20.0, 0.0)))

func test_one_timer_cannot_strike_an_airborne_puck() -> void:
	# Same geometry that connects on the ice: a slapper comes down to the ice,
	# so a puck still in the air is swung under.
	assert_true(_connects(Vector2.ZERO, Vector2(0.3, 0.0), Vector2.ZERO, false))
	assert_false(_connects(Vector2.ZERO, Vector2(0.3, 0.0), Vector2.ZERO, true))


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
