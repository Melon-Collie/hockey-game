extends GutTest

# SkaterAimingBehavior — owns wrister swing state (cursor-speed power signal +
# forehand/backhand swing rotation) and slapper charge timers. Tests operate
# directly on the RefCounted; no Skater node needed.
#
# tick_wrister_charge takes TWO positions:
#   - intent_pos: cursor position (screen-space in prod — packed (x, 0, y)),
#     drives the DIRECTION / variance check AND the cursor-speed power signal
#     (cursor_speed_ema). Camera-immune.
#   - blade_pos: blade position in skater-translation-subtracted world XZ —
#     drives the swing ROTATION (signed angular step around the player).
# Power is the pure cursor speed, not a drag distance.

const VARIANCE_DEG: float = 35.0
const SMOOTHING: float = 14.0
const DT: float = 1.0 / 120.0

var ab: SkaterAimingBehavior

func before_each() -> void:
	ab = SkaterAimingBehavior.new()

func test_initial_state() -> void:
	assert_almost_eq(ab.cursor_speed_ema, 0.0, 0.001)
	assert_almost_eq(ab.swing_rotation, 0.0, 0.001)
	assert_eq(ab.prev_intent_pos, Vector3.ZERO)
	assert_eq(ab.prev_blade_pos_rel_skater, Vector3.ZERO)
	assert_eq(ab.prev_blade_dir, Vector3.ZERO)
	assert_almost_eq(ab.slapper_charge_timer, 0.0, 0.001)
	assert_almost_eq(ab.one_timer_window_timer, 0.0, 0.001)

func test_cursor_motion_builds_speed_ema() -> void:
	# Seed the prev cursor so the first tick measures a real delta, then a steady
	# fast drag should push the EMA up from zero.
	ab.reset_wrister(Vector3(0.0, 0.0, 0.0), Vector3.ZERO)
	for i in range(20):
		ab.tick_wrister_charge(Vector3(10.0 * (i + 1), 0.0, 0.0), Vector3.ZERO, VARIANCE_DEG, DT, SMOOTHING)
	# 10 px per DT ≈ 1200 px/s; EMA converges toward that.
	assert_gt(ab.cursor_speed_ema, 500.0, "steady fast drag drives the cursor-speed EMA up")

func test_slower_drag_yields_lower_speed_ema() -> void:
	# Half the per-tick pixel step → roughly half the instantaneous speed, so the
	# EMA settles lower. This is the soft-touch-vs-rip power separation.
	ab.reset_wrister(Vector3.ZERO, Vector3.ZERO)
	for i in range(20):
		ab.tick_wrister_charge(Vector3(5.0 * (i + 1), 0.0, 0.0), Vector3.ZERO, VARIANCE_DEG, DT, SMOOTHING)
	var slow_ema: float = ab.cursor_speed_ema

	ab.reset_wrister(Vector3.ZERO, Vector3.ZERO)
	for i in range(20):
		ab.tick_wrister_charge(Vector3(10.0 * (i + 1), 0.0, 0.0), Vector3.ZERO, VARIANCE_DEG, DT, SMOOTHING)
	var fast_ema: float = ab.cursor_speed_ema

	assert_lt(slow_ema, fast_ema, "a slower sweep reads as less power")

func test_stationary_cursor_decays_speed_ema() -> void:
	# Build some speed, then hold the cursor still: instantaneous speed is zero,
	# so the EMA decays back toward zero.
	ab.reset_wrister(Vector3.ZERO, Vector3.ZERO)
	for i in range(10):
		ab.tick_wrister_charge(Vector3(10.0 * (i + 1), 0.0, 0.0), Vector3.ZERO, VARIANCE_DEG, DT, SMOOTHING)
	var moving_ema: float = ab.cursor_speed_ema
	assert_gt(moving_ema, 0.0)
	var held: Vector3 = ab.prev_intent_pos
	for _i in range(40):
		ab.tick_wrister_charge(held, Vector3.ZERO, VARIANCE_DEG, DT, SMOOTHING)
	assert_lt(ab.cursor_speed_ema, moving_ema * 0.5, "held cursor decays the power signal")

func test_tick_updates_prev_positions() -> void:
	ab.tick_wrister_charge(Vector3(0.3, 0.0, 0.1), Vector3(0.25, 0.0, 0.05), VARIANCE_DEG, DT, SMOOTHING)
	assert_eq(ab.prev_intent_pos, Vector3(0.3, 0.0, 0.1))
	assert_eq(ab.prev_blade_pos_rel_skater, Vector3(0.25, 0.0, 0.05))

func test_direction_comes_from_cursor_not_blade() -> void:
	# Cursor moves +X (clear drag direction); blade sits elsewhere. The recorded
	# direction must follow the CURSOR.
	ab.tick_wrister_charge(Vector3(0.5, 0.0, 0.0), Vector3(0.0, 0.0, 0.5), VARIANCE_DEG, DT, SMOOTHING)
	assert_almost_eq(ab.prev_blade_dir.x, 1.0, 0.001, "direction.x should be +1 (cursor direction)")
	assert_almost_eq(ab.prev_blade_dir.z, 0.0, 0.001, "direction.z should be 0 (cursor direction, not blade)")

func test_swing_rotation_accumulates_from_blade_bearing() -> void:
	# Cursor drags a constant +X (no variance break); the blade bearing rotates
	# a quarter turn, so swing_rotation picks up the signed step.
	ab.tick_wrister_charge(Vector3(0.5, 0.0, 0.0), Vector3(1.0, 0.0, 0.0), VARIANCE_DEG, DT, SMOOTHING)
	ab.tick_wrister_charge(Vector3(1.0, 0.0, 0.0), Vector3(0.0, 0.0, 1.0), VARIANCE_DEG, DT, SMOOTHING)
	assert_almost_eq(ab.swing_rotation, -PI / 2.0, 0.01, "blade quarter-turn accumulates as signed rotation")

func test_reset_wrister_zeroes_state_and_seeds_pos() -> void:
	ab.swing_rotation = 1.2
	ab.cursor_speed_ema = 900.0
	ab.prev_blade_dir = Vector3(1, 0, 0)
	ab.reset_wrister(Vector3(0.2, 0.0, 0.1), Vector3(0.25, 0.0, 0.05))
	assert_almost_eq(ab.swing_rotation, 0.0, 0.001)
	assert_almost_eq(ab.cursor_speed_ema, 0.0, 0.001)
	assert_eq(ab.prev_blade_dir, Vector3.ZERO)
	assert_eq(ab.prev_intent_pos, Vector3(0.2, 0.0, 0.1))
	assert_eq(ab.prev_blade_pos_rel_skater, Vector3(0.25, 0.0, 0.05))

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
