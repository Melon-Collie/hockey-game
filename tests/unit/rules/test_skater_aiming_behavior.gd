extends GutTest

# SkaterAimingBehavior — owns wrister charge state and slapper charge timers.
# Tests operate directly on the RefCounted; no Skater node needed.
#
# tick_wrister_charge takes TWO positions:
#   - intent_pos: cursor position (screen-space in prod — packed (x, 0, y)),
#     drives DIRECTION and variance check. Camera-immune.
#   - blade_pos: actual blade position in skater-translation-subtracted
#     world XZ — drives MAGNITUDE via projection onto intent direction.
# The two frames don't have to match: direction only reads intent, magnitude
# only reads blade. Tests below pass arbitrary Vector3s for both and assert
# on the behaviors that follow from the dual-signal contract.

const VARIANCE_DEG: float = 35.0
const MAX_DISTANCE: float = 1.5

var ab: SkaterAimingBehavior

func before_each() -> void:
	ab = SkaterAimingBehavior.new()

func test_initial_state() -> void:
	assert_almost_eq(ab.charge_distance, 0.0, 0.001)
	assert_eq(ab.prev_intent_pos, Vector3.ZERO)
	assert_eq(ab.prev_blade_pos_rel_skater, Vector3.ZERO)
	assert_eq(ab.prev_blade_dir, Vector3.ZERO)
	assert_almost_eq(ab.slapper_charge_timer, 0.0, 0.001)
	assert_almost_eq(ab.one_timer_window_timer, 0.0, 0.001)

func test_tick_accumulates_charge() -> void:
	# Cursor and blade both move 0.5 m from the seeded zero baseline → 0.5 m of charge.
	ab.tick_wrister_charge(Vector3(0.5, 0.0, 0.0), Vector3(0.5, 0.0, 0.0), VARIANCE_DEG, MAX_DISTANCE)
	assert_almost_eq(ab.charge_distance, 0.5, 0.001)

func test_charge_capped_at_max() -> void:
	# 2 m of blade travel in one tick, cap is 1.5 m.
	ab.tick_wrister_charge(Vector3(2.0, 0.0, 0.0), Vector3(2.0, 0.0, 0.0), VARIANCE_DEG, MAX_DISTANCE)
	assert_almost_eq(ab.charge_distance, MAX_DISTANCE, 0.001, "charge capped at max_wrister_charge_distance")

func test_tick_updates_prev_positions() -> void:
	ab.tick_wrister_charge(Vector3(0.3, 0.0, 0.1), Vector3(0.25, 0.0, 0.05), VARIANCE_DEG, MAX_DISTANCE)
	assert_eq(ab.prev_intent_pos, Vector3(0.3, 0.0, 0.1))
	assert_eq(ab.prev_blade_pos_rel_skater, Vector3(0.25, 0.0, 0.05))

func test_rom_clamp_cursor_drags_blade_pinned_no_charge() -> void:
	# Regression test for the ROM-clamp bug: cursor keeps moving (player drags
	# past their reach) but the blade is pinned at the ROM boundary. Charge
	# must not accumulate — magnitude comes from blade, not cursor.
	# Seed prev state to the pinned configuration so the first tick doesn't
	# count a "jump from zero to pinned" as a delta.
	ab.reset_wrister(Vector3(0.5, 0.0, 0.0), Vector3(0.4, 0.0, 0.0))
	for i in range(5):
		var cursor: Vector3 = Vector3(0.5 * (i + 2), 0.0, 0.0)  # cursor moves each tick
		var blade: Vector3 = Vector3(0.4, 0.0, 0.0)              # blade pinned
		ab.tick_wrister_charge(cursor, blade, VARIANCE_DEG, MAX_DISTANCE)
	assert_almost_eq(ab.charge_distance, 0.0, 0.001,
			"cursor drag past ROM with blade pinned must produce zero charge")

func test_stationary_cursor_no_charge_even_if_blade_moves() -> void:
	# Symmetric to the ROM-clamp case: if the cursor isn't moving the player has
	# no drag intent, so blade motion (e.g., body rotation, locomotion residue)
	# alone must not pump charge. Seed prev state at the steady position so
	# tick 1 doesn't see a jump from zero.
	ab.reset_wrister(Vector3(0.3, 0.0, 0.0), Vector3(0.3, 0.0, 0.0))
	for i in range(5):
		var cursor: Vector3 = Vector3(0.3, 0.0, 0.0)            # cursor held
		var blade: Vector3 = Vector3(0.3 + 0.05 * i, 0.0, 0.0)  # blade drifting
		ab.tick_wrister_charge(cursor, blade, VARIANCE_DEG, MAX_DISTANCE)
	assert_almost_eq(ab.charge_distance, 0.0, 0.001,
			"stationary cursor must produce zero charge regardless of blade motion")

func test_direction_comes_from_cursor_not_blade() -> void:
	# Cursor moves +X (clear drag direction); blade drifts in a totally
	# different direction (+Z, simulating body-rotation tangent). The recorded
	# direction must follow the CURSOR, not the blade — that's the whole point
	# of the cursor-direction / blade-magnitude split.
	ab.tick_wrister_charge(Vector3(0.5, 0.0, 0.0), Vector3(0.0, 0.0, 0.5), VARIANCE_DEG, MAX_DISTANCE)
	assert_almost_eq(ab.prev_blade_dir.x, 1.0, 0.001, "direction.x should be +1 (cursor direction)")
	assert_almost_eq(ab.prev_blade_dir.z, 0.0, 0.001, "direction.z should be 0 (cursor direction, not blade)")

func test_blade_motion_orthogonal_to_intent_contributes_zero_charge() -> void:
	# Blade motion projected onto the intent direction: motion perpendicular
	# to the player's drag (e.g., body-rotation tangent, IK catch-up after a
	# press snap) projects to zero magnitude. This is what keeps a snapped
	# wind-up's blade catch-up from over-charging passes.
	ab.tick_wrister_charge(Vector3(0.5, 0.0, 0.0), Vector3(0.0, 0.0, 0.5), VARIANCE_DEG, MAX_DISTANCE)
	assert_almost_eq(ab.charge_distance, 0.0, 0.001,
			"orthogonal blade motion projects to zero, no charge accumulated")

func test_blade_motion_against_intent_contributes_zero_charge() -> void:
	# Blade moving opposite the drag direction (e.g., catching up from a
	# previous pose toward the wind-up start while the cursor has snapped
	# forward) projects to negative — clamped to zero, no charge added.
	ab.tick_wrister_charge(Vector3(0.5, 0.0, 0.0), Vector3(-0.5, 0.0, 0.0), VARIANCE_DEG, MAX_DISTANCE)
	assert_almost_eq(ab.charge_distance, 0.0, 0.001,
			"blade motion opposite intent projects negative, clamped to zero")

func test_direction_reversal_resets_charge() -> void:
	ab.tick_wrister_charge(Vector3(0.5, 0.0, 0.0), Vector3(0.5, 0.0, 0.0), VARIANCE_DEG, MAX_DISTANCE)
	var charge_after_first: float = ab.charge_distance
	assert_gt(charge_after_first, 0.0)
	# Reverse cursor direction by 0.1 m. ChargeTracking resets then adds the
	# new blade delta; final charge is below the original.
	ab.tick_wrister_charge(Vector3(0.4, 0.0, 0.0), Vector3(0.4, 0.0, 0.0), VARIANCE_DEG, MAX_DISTANCE)
	assert_lt(ab.charge_distance, charge_after_first, "direction reversal resets charge accumulator")

func test_reset_wrister_zeroes_charge_and_seeds_pos() -> void:
	ab.charge_distance = 1.2
	ab.prev_blade_dir = Vector3(1, 0, 0)
	ab.reset_wrister(Vector3(0.2, 0.0, 0.1), Vector3(0.25, 0.0, 0.05))
	assert_almost_eq(ab.charge_distance, 0.0, 0.001)
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
