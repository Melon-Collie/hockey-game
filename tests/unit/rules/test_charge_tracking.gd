extends GutTest

# ChargeTracking — wrister aim charge accumulation, with direction-variance
# reset. Caller owns per-frame state; each tick produces new charge + direction.
#
# accumulate() decouples two signals: an INTENT pair (cursor motion, drives
# direction + variance) and a BLADE pair (world motion, drives magnitude via
# projection onto the intent direction). These tests exercise a single combined
# motion, so each call passes the same prev/current position into both the
# intent and blade pairs.

const VARIANCE_DEG: float = 45.0

func test_no_movement_preserves_charge_and_direction() -> void:
	var dir := Vector3(1, 0, 0)
	var result: Dictionary = ChargeTracking.accumulate(
		Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, dir, 0.5, VARIANCE_DEG)
	assert_almost_eq(result.charge, 0.5, 0.001, "no blade delta → charge unchanged")
	assert_eq(result.direction, dir, "direction preserved when no movement")

func test_tiny_movement_treated_as_none() -> void:
	# Under the 0.001 threshold
	var result: Dictionary = ChargeTracking.accumulate(
		Vector3.ZERO, Vector3(0.0005, 0, 0), Vector3.ZERO, Vector3(0.0005, 0, 0), Vector3.ZERO, 1.0, VARIANCE_DEG)
	assert_almost_eq(result.charge, 1.0, 0.001, "negligible movement doesn't add to charge")

func test_straight_movement_accumulates() -> void:
	# First tick: no prev direction, moves 0.5 in +X. New charge = 0 + 0.5 = 0.5
	var step1: Dictionary = ChargeTracking.accumulate(
		Vector3.ZERO, Vector3(0.5, 0, 0), Vector3.ZERO, Vector3(0.5, 0, 0), Vector3.ZERO, 0.0, VARIANCE_DEG)
	assert_almost_eq(step1.charge, 0.5, 0.001)
	assert_eq(step1.direction, Vector3(1, 0, 0))

	# Second tick: continues in +X by 0.3. 0.5 + 0.3 = 0.8
	var step2: Dictionary = ChargeTracking.accumulate(
		Vector3(0.5, 0, 0), Vector3(0.8, 0, 0), Vector3(0.5, 0, 0), Vector3(0.8, 0, 0), step1.direction, step1.charge, VARIANCE_DEG)
	assert_almost_eq(step2.charge, 0.8, 0.001)

func test_direction_reversal_resets_charge() -> void:
	# Prev direction is +X; current movement is -X (180°, way past 45° variance)
	var result: Dictionary = ChargeTracking.accumulate(
		Vector3(0.5, 0, 0),           # prev intent pos
		Vector3(0.3, 0, 0),           # current intent pos (moved -X by 0.2)
		Vector3(0.5, 0, 0),           # prev blade pos
		Vector3(0.3, 0, 0),           # current blade pos (moved -X by 0.2)
		Vector3(1, 0, 0),             # prev direction (+X)
		1.0,                          # current charge
		VARIANCE_DEG)
	# Charge reset to 0 then the 0.2 added → 0.2
	assert_almost_eq(result.charge, 0.2, 0.001, "big direction change resets charge")
	assert_eq(result.direction, Vector3(-1, 0, 0))

func test_small_direction_change_keeps_charge() -> void:
	# Small angle change (under variance threshold) accumulates normally
	var prev_dir := Vector3(1, 0, 0)
	# Move mostly +X, slightly +Z (angle ~18°, under 45°)
	var delta := Vector3(1.0, 0, 0.3).normalized() * 0.5
	var result: Dictionary = ChargeTracking.accumulate(
		Vector3.ZERO, delta, Vector3.ZERO, delta, prev_dir, 1.0, VARIANCE_DEG)
	assert_almost_eq(result.charge, 1.5, 0.01, "small wobble still accumulates")

func test_first_tick_no_prev_direction_no_reset() -> void:
	# prev_direction == Vector3.ZERO → no variance check, just accumulate
	var result: Dictionary = ChargeTracking.accumulate(
		Vector3.ZERO, Vector3(0.5, 0, 0), Vector3.ZERO, Vector3(0.5, 0, 0), Vector3.ZERO, 0.0, VARIANCE_DEG)
	assert_almost_eq(result.charge, 0.5, 0.001)

func test_y_component_ignored() -> void:
	# Blade movement in Y should not contribute to charge; only XZ plane
	var result: Dictionary = ChargeTracking.accumulate(
		Vector3.ZERO, Vector3(0, 0.5, 0), Vector3.ZERO, Vector3(0, 0.5, 0), Vector3.ZERO, 0.0, VARIANCE_DEG)
	assert_almost_eq(result.charge, 0.0, 0.001, "pure Y movement → no charge")

func test_player_movement_does_not_create_charge() -> void:
	# When tracking (mouse_world - player_pos): if the player skates east by 1 m
	# while holding the cursor still, mouse_world also moves east by 1 m, so
	# the relative position is unchanged and no charge should accumulate.
	var prev_relative := Vector3(3.0, 0.0, -2.0)  # mouse(3,0,-2) - player(0,0,0)
	var curr_relative := Vector3(3.0, 0.0, -2.0)  # mouse(4,0,-2) - player(1,0,0)
	var result: Dictionary = ChargeTracking.accumulate(
		prev_relative, curr_relative, prev_relative, curr_relative, Vector3.ZERO, 0.0, VARIANCE_DEG)
	assert_almost_eq(result.charge, 0.0, 0.001, "skating with held cursor adds no charge")

# ── Sweep time + counted-speed cap (the wrister power model's speed signal) ──

const DT: float = 1.0 / 120.0

func test_sweep_time_accumulates_on_counted_ticks() -> void:
	var result: Dictionary = ChargeTracking.accumulate(
		Vector3.ZERO, Vector3(0.5, 0, 0), Vector3.ZERO, Vector3(0.5, 0, 0),
		Vector3.ZERO, 0.0, VARIANCE_DEG, 0.0, DT, 0.0)
	assert_almost_eq(result.sweep_time, DT, 0.00001, "counted tick adds delta")
	assert_almost_eq(result.charge, 0.5, 0.001)

func test_idle_tick_holds_sweep_time() -> void:
	# Cursor stationary: neither charge nor time advances — "draw, then hold
	# for the lane" must preserve the loaded average sweep speed.
	var result: Dictionary = ChargeTracking.accumulate(
		Vector3(0.5, 0, 0), Vector3(0.5, 0, 0), Vector3(0.5, 0, 0), Vector3(0.5, 0, 0),
		Vector3(1, 0, 0), 0.7, VARIANCE_DEG, 0.25, DT, 0.0)
	assert_almost_eq(result.sweep_time, 0.25, 0.00001, "idle tick holds sweep time")
	assert_almost_eq(result.charge, 0.7, 0.001, "idle tick holds charge")

func test_counted_speed_cap_trims_single_tick_yank() -> void:
	# A one-tick 0.5 m yank against a 2 m/s cap over a 0.1 s tick counts only
	# 0.2 m — an instant gesture banks short runway (a snap), not full charge.
	var result: Dictionary = ChargeTracking.accumulate(
		Vector3.ZERO, Vector3(0.5, 0, 0), Vector3.ZERO, Vector3(0.5, 0, 0),
		Vector3.ZERO, 0.0, VARIANCE_DEG, 0.0, 0.1, 2.0)
	assert_almost_eq(result.charge, 0.2, 0.001, "counted travel capped at speed × delta")
	assert_almost_eq(result.sweep_time, 0.1, 0.00001, "capped tick still counts its time")

func test_cap_disabled_when_nonpositive() -> void:
	var result: Dictionary = ChargeTracking.accumulate(
		Vector3.ZERO, Vector3(0.5, 0, 0), Vector3.ZERO, Vector3(0.5, 0, 0),
		Vector3.ZERO, 0.0, VARIANCE_DEG, 0.0, 0.001, 0.0)
	assert_almost_eq(result.charge, 0.5, 0.001, "cap <= 0 counts full travel")

func test_variance_reset_zeroes_sweep_time_with_charge() -> void:
	# Direction reversal starts a new sweep: both accumulators reset, then the
	# reversal tick's own motion counts into the fresh sweep.
	var result: Dictionary = ChargeTracking.accumulate(
		Vector3(0.5, 0, 0), Vector3(0.3, 0, 0),
		Vector3(0.5, 0, 0), Vector3(0.3, 0, 0),
		Vector3(1, 0, 0), 1.0, VARIANCE_DEG, 0.5, DT, 0.0)
	assert_almost_eq(result.charge, 0.2, 0.001, "charge reset then reversal tick counted")
	assert_almost_eq(result.sweep_time, DT, 0.00001, "sweep time reset with charge")
	assert_true(result.reset, "variance break reports the new stroke")

func test_reset_flag_false_on_continuation_idle_and_first_tick() -> void:
	# Straight continuation — no reset.
	var cont: Dictionary = ChargeTracking.accumulate(
		Vector3.ZERO, Vector3(0.3, 0, 0), Vector3.ZERO, Vector3(0.3, 0, 0),
		Vector3(1, 0, 0), 0.5, VARIANCE_DEG, 0.1, DT, 0.0)
	assert_false(cont.reset, "same-direction motion is the same stroke")
	# Idle tick — no reset.
	var idle: Dictionary = ChargeTracking.accumulate(
		Vector3(0.5, 0, 0), Vector3(0.5, 0, 0), Vector3(0.5, 0, 0), Vector3(0.5, 0, 0),
		Vector3(1, 0, 0), 0.5, VARIANCE_DEG, 0.1, DT, 0.0)
	assert_false(idle.reset, "holding still is not a new stroke")
	# First meaningful motion (no prev direction) — a stroke STARTS but nothing
	# was broken; callers already capture the hand read at aim entry.
	var first: Dictionary = ChargeTracking.accumulate(
		Vector3.ZERO, Vector3(0.3, 0, 0), Vector3.ZERO, Vector3(0.3, 0, 0),
		Vector3.ZERO, 0.0, VARIANCE_DEG, 0.0, DT, 0.0)
	assert_false(first.reset, "first motion after entry is not a variance break")
