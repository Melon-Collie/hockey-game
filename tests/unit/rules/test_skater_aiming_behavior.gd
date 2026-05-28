extends GutTest

# SkaterAimingBehavior — owns wrister charge state and slapper charge timers.
# Tests operate directly on the RefCounted; no Skater node needed.
#
# tick_wrister_charge takes the blade's position in a skater-translation-
# subtracted frame (world XZ orientation, skater pos removed). Charge
# accumulates from the delta of this position frame-over-frame, so the
# inputs in these tests are blade-pos-rel-skater Vector3s — not raw mouse.

const VARIANCE_DEG: float = 35.0
const MAX_DISTANCE: float = 1.5

var ab: SkaterAimingBehavior

func before_each() -> void:
	ab = SkaterAimingBehavior.new()

func test_initial_state() -> void:
	assert_almost_eq(ab.charge_distance, 0.0, 0.001)
	assert_eq(ab.prev_blade_pos_rel_skater, Vector3.ZERO)
	assert_eq(ab.prev_blade_dir, Vector3.ZERO)
	assert_almost_eq(ab.slapper_charge_timer, 0.0, 0.001)
	assert_almost_eq(ab.one_timer_window_timer, 0.0, 0.001)

func test_tick_accumulates_charge() -> void:
	# 0.5 m of blade travel from the seeded zero baseline → 0.5 m of charge.
	ab.tick_wrister_charge(Vector3(0.5, 0.0, 0.0), VARIANCE_DEG, MAX_DISTANCE)
	assert_almost_eq(ab.charge_distance, 0.5, 0.001)

func test_charge_capped_at_max() -> void:
	# 2 m of blade travel in one tick, cap is 1.5 m.
	ab.tick_wrister_charge(Vector3(2.0, 0.0, 0.0), VARIANCE_DEG, MAX_DISTANCE)
	assert_almost_eq(ab.charge_distance, MAX_DISTANCE, 0.001, "charge capped at max_wrister_charge_distance")

func test_tick_updates_prev_blade_pos() -> void:
	ab.tick_wrister_charge(Vector3(0.3, 0.0, 0.1), VARIANCE_DEG, MAX_DISTANCE)
	assert_eq(ab.prev_blade_pos_rel_skater, Vector3(0.3, 0.0, 0.1))

func test_stationary_blade_does_not_accumulate() -> void:
	# This is the regression test for the ROM-clamp bug: when IK pins the blade
	# at the ROM boundary, blade_pos_rel_skater stops changing even though the
	# cursor keeps moving. Charge must hold steady, not keep growing.
	ab.tick_wrister_charge(Vector3(0.4, 0.0, 0.0), VARIANCE_DEG, MAX_DISTANCE)
	var charge_after_move: float = ab.charge_distance
	assert_gt(charge_after_move, 0.0)
	for i in range(5):
		ab.tick_wrister_charge(Vector3(0.4, 0.0, 0.0), VARIANCE_DEG, MAX_DISTANCE)
	assert_almost_eq(ab.charge_distance, charge_after_move, 0.001,
			"charge must not grow while blade pos is unchanged (ROM clamp scenario)")

func test_direction_reversal_resets_charge() -> void:
	ab.tick_wrister_charge(Vector3(0.5, 0.0, 0.0), VARIANCE_DEG, MAX_DISTANCE)
	var charge_after_first: float = ab.charge_distance
	assert_gt(charge_after_first, 0.0)
	# Reverse direction by 0.1 m. ChargeTracking resets then adds the new
	# delta; final charge is below the original since 0.1 < charge_after_first.
	ab.tick_wrister_charge(Vector3(0.4, 0.0, 0.0), VARIANCE_DEG, MAX_DISTANCE)
	assert_lt(ab.charge_distance, charge_after_first, "direction reversal resets charge accumulator")

func test_reset_wrister_zeroes_charge_and_seeds_pos() -> void:
	ab.charge_distance = 1.2
	ab.prev_blade_dir = Vector3(1, 0, 0)
	ab.reset_wrister(Vector3(0.2, 0.0, 0.1))
	assert_almost_eq(ab.charge_distance, 0.0, 0.001)
	assert_eq(ab.prev_blade_dir, Vector3.ZERO)
	assert_eq(ab.prev_blade_pos_rel_skater, Vector3(0.2, 0.0, 0.1))

func test_tick_slapper_increments_timer() -> void:
	ab.tick_slapper(0.016)
	assert_almost_eq(ab.slapper_charge_timer, 0.016, 0.001)
	ab.tick_slapper(0.016)
	assert_almost_eq(ab.slapper_charge_timer, 0.032, 0.001)

func test_reset_slapper_zeroes_both_timers() -> void:
	ab.slapper_charge_timer = 0.5
	ab.one_timer_window_timer = 0.1
	ab.reset_slapper()
	assert_almost_eq(ab.slapper_charge_timer, 0.0, 0.001)
	assert_almost_eq(ab.one_timer_window_timer, 0.0, 0.001)

func test_tick_one_timer_window_decrements_when_positive() -> void:
	ab.one_timer_window_timer = 0.1
	ab.tick_one_timer_window(0.016)
	assert_almost_eq(ab.one_timer_window_timer, 0.084, 0.001)

func test_tick_one_timer_window_goes_negative_on_expiry() -> void:
	# Timer goes negative when delta overshoots — callers check <= 0 to detect expiry.
	ab.one_timer_window_timer = 0.01
	ab.tick_one_timer_window(0.016)
	assert_lt(ab.one_timer_window_timer, 0.0, "timer goes negative; caller detects expiry via <= 0")

func test_tick_one_timer_window_noop_when_zero() -> void:
	ab.one_timer_window_timer = 0.0
	ab.tick_one_timer_window(0.016)
	assert_almost_eq(ab.one_timer_window_timer, 0.0, 0.001, "noop when timer already zero")
