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


# ── one_timer_contact ─────────────────────────────────────────────────────────
# Offsets are puck-minus-zone-centre in the shooter's own frame: the near end
# sampled when the swing committed, the far end when the blade arrived.

const ZONE_R: float = 0.5

func test_one_timer_contact_when_the_puck_sits_in_the_zone_all_beat() -> void:
	assert_true(ShotReleaseRules.one_timer_contact(
			Vector2(0.3, 0), Vector2(0.3, 0), ZONE_R),
			"a stationary puck inside the ring connects")

func test_one_timer_contact_when_the_feed_crosses_during_the_hold() -> void:
	# Commit while the feed is still 2 m out; it runs clean through the zone and
	# is 1.5 m past by the time the blade lands. The beat is what forgives this.
	assert_true(ShotReleaseRules.one_timer_contact(
			Vector2(-2.0, 0), Vector2(1.5, 0), ZONE_R),
			"the puck crossed the ring while the stick was coming down")

func test_one_timer_early_commit_whiffs() -> void:
	# Committed so early the feed is still a metre short when the blade arrives —
	# the old symmetric ring rewarded this exactly as much as good timing.
	assert_false(ShotReleaseRules.one_timer_contact(
			Vector2(-4.0, 0), Vector2(-1.0, 0), ZONE_R),
			"the segment never reaches the zone")

func test_one_timer_late_commit_whiffs() -> void:
	assert_false(ShotReleaseRules.one_timer_contact(
			Vector2(1.0, 0), Vector2(4.0, 0), ZONE_R),
			"the puck was already through before the swing committed")

func test_one_timer_contact_misses_a_fast_puck_that_passes_wide() -> void:
	# Travels the full length of the beat but a metre off the blade's line.
	assert_false(ShotReleaseRules.one_timer_contact(
			Vector2(-3.0, 1.0), Vector2(3.0, 1.0), ZONE_R),
			"a wide feed is a wide feed however fast it goes")

func test_one_timer_contact_distance_is_the_closest_approach() -> void:
	assert_almost_eq(ShotReleaseRules.one_timer_contact_distance(
			Vector2(-3.0, 0.2), Vector2(3.0, 0.2)), 0.2, 0.001,
			"perpendicular distance to the segment, not to either endpoint")

func test_one_timer_contact_distance_clamps_to_the_endpoints() -> void:
	# The zone centre is behind the near end: the closest point is that endpoint,
	# not the infinite line's foot.
	assert_almost_eq(ShotReleaseRules.one_timer_contact_distance(
			Vector2(1.0, 0), Vector2(4.0, 0)), 1.0, 0.001)

func test_one_timer_contact_distance_of_a_degenerate_segment() -> void:
	assert_almost_eq(ShotReleaseRules.one_timer_contact_distance(
			Vector2(0.4, 0.3), Vector2(0.4, 0.3)), 0.5, 0.001,
			"zero-length beat falls back to the offset itself")

func test_one_timer_contact_distance_rejects_non_finite_offsets() -> void:
	assert_eq(ShotReleaseRules.one_timer_contact_distance(
			Vector2(NAN, 0), Vector2(0, 0)), INF)


# ── one_timer_beat_plausible ──────────────────────────────────────────────────

func test_one_timer_beat_plausible_for_a_hard_feed() -> void:
	# 30 m/s closing over a 0.11 s beat = 3.3 m through the shooter's frame.
	assert_true(ShotReleaseRules.one_timer_beat_plausible(
			Vector2(-2.0, 0), Vector2(1.3, 0), 0.11))

func test_one_timer_beat_implausible_for_a_forged_sweep() -> void:
	# A segment long enough to sweep the zone centre from anywhere on the rink.
	assert_false(ShotReleaseRules.one_timer_beat_plausible(
			Vector2(-40.0, 0), Vector2(40.0, 0), 0.11),
			"no puck moves 80 m in a tenth of a second")

func test_one_timer_beat_implausible_when_non_finite() -> void:
	assert_false(ShotReleaseRules.one_timer_beat_plausible(
			Vector2(INF, 0), Vector2.ZERO, 0.11))


# ── one_timer_within_reach ────────────────────────────────────────────────────

func test_one_timer_within_reach_of_the_live_puck() -> void:
	assert_true(ShotReleaseRules.one_timer_within_reach(
			Vector2(1.5, 0), Vector2(0, 0), 2.5))

func test_one_timer_out_of_reach_rejected() -> void:
	# Lag comp said the shooter connected, but the puck has since travelled well
	# past any stick — the swing whiffs rather than dragging the puck back.
	assert_false(ShotReleaseRules.one_timer_within_reach(
			Vector2(4.0, 0), Vector2(0, 0), 2.5))

func test_one_timer_reach_bound_no_ops_without_a_caps_entry() -> void:
	assert_true(ShotReleaseRules.one_timer_within_reach(
			Vector2(40.0, 0), Vector2(0, 0), 0.0),
			"no measured reach for the peer — lean on the other gates")


# ── one_timer_power ───────────────────────────────────────────────────────────
# Graded by the beat's closest approach (one_timer_contact_distance).

func test_one_timer_power_dead_center_gets_full_bonus() -> void:
	# Struck through the zone centre: proximity 1 → base * (1 + bonus).
	assert_almost_eq(ShotReleaseRules.one_timer_power(
			40.0, 0.15, 0.0, 0.5), 40.0 * 1.15, 0.001)

func test_one_timer_power_edge_gets_full_penalty() -> void:
	# Grazed the ring edge: proximity 0 → base * (1 - bonus).
	assert_almost_eq(ShotReleaseRules.one_timer_power(
			40.0, 0.15, 0.5, 0.5), 40.0 * 0.85, 0.001)

func test_one_timer_power_half_radius_is_neutral() -> void:
	# proximity 0.5 → 2*0.5 - 1 = 0 → no bonus or penalty.
	assert_almost_eq(ShotReleaseRules.one_timer_power(
			40.0, 0.15, 0.25, 0.5), 40.0, 0.001)

func test_one_timer_power_beyond_radius_clamps_to_full_penalty() -> void:
	# Past the radius proximity clamps to 0 (not negative) → base * (1 - bonus).
	assert_almost_eq(ShotReleaseRules.one_timer_power(
			40.0, 0.15, 2.0, 0.5), 40.0 * 0.85, 0.001)

func test_one_timer_power_zero_radius_returns_base() -> void:
	assert_almost_eq(ShotReleaseRules.one_timer_power(
			40.0, 0.15, 0.0, 0.0), 40.0, 0.001)


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
