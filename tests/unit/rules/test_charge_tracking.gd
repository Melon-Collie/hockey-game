extends GutTest

# ChargeTracking — wrister SWING tracking: the forehand/backhand chirality
# (accumulated blade rotation), the stroke's blade travel (the power-ceiling
# gate signal), and the direction-variance reset that starts a fresh stroke.
# Power is NOT tracked here — it's the pure cursor speed
# (SkaterAimingBehavior.cursor_speed_ema) — so accumulate() reports
# { direction, reset, rotation, travel }.
#
# accumulate() reads an INTENT pair (cursor motion, drives direction + variance)
# and a BLADE pair (world motion, drives the rotation via signed angular step).
# These tests exercise a single combined motion unless noted, so each call
# passes the same prev/current position into both the intent and blade pairs.

const VARIANCE_DEG: float = 45.0
const DT: float = 1.0 / 120.0

func test_no_movement_preserves_direction() -> void:
	var dir := Vector3(1, 0, 0)
	var result: Dictionary = ChargeTracking.accumulate(
		Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, dir, VARIANCE_DEG)
	assert_eq(result.direction, dir, "direction preserved when no movement")
	assert_false(result.reset, "no motion is not a variance break")

func test_tiny_movement_treated_as_none() -> void:
	# Under the 0.001 threshold — no new direction recorded, rotation held.
	var result: Dictionary = ChargeTracking.accumulate(
		Vector3.ZERO, Vector3(0.0005, 0, 0), Vector3.ZERO, Vector3(0.0005, 0, 0),
		Vector3.ZERO, VARIANCE_DEG, 1.5)
	assert_eq(result.direction, Vector3.ZERO, "negligible motion records no direction")
	assert_almost_eq(result.rotation, 1.5, 0.001, "negligible motion holds rotation")

func test_straight_movement_records_direction() -> void:
	var step1: Dictionary = ChargeTracking.accumulate(
		Vector3.ZERO, Vector3(0.5, 0, 0), Vector3.ZERO, Vector3(0.5, 0, 0),
		Vector3.ZERO, VARIANCE_DEG)
	assert_eq(step1.direction, Vector3(1, 0, 0))
	assert_false(step1.reset)

	# Second tick: continues in +X — same stroke, no reset.
	var step2: Dictionary = ChargeTracking.accumulate(
		Vector3(0.5, 0, 0), Vector3(0.8, 0, 0), Vector3(0.5, 0, 0), Vector3(0.8, 0, 0),
		step1.direction, VARIANCE_DEG)
	assert_eq(step2.direction, Vector3(1, 0, 0))
	assert_false(step2.reset, "same-direction motion is the same stroke")

func test_direction_reversal_resets_stroke() -> void:
	# Prev direction is +X; current movement is -X (180°, way past 45° variance).
	var result: Dictionary = ChargeTracking.accumulate(
		Vector3(0.5, 0, 0),           # prev intent pos
		Vector3(0.3, 0, 0),           # current intent pos (moved -X by 0.2)
		Vector3(0.5, 0, 0),           # prev blade pos
		Vector3(0.3, 0, 0),           # current blade pos (moved -X by 0.2)
		Vector3(1, 0, 0),             # prev direction (+X)
		VARIANCE_DEG,
		5.0)                          # current rotation (discarded by the break)
	assert_true(result.reset, "big direction change starts a new stroke")
	assert_eq(result.direction, Vector3(-1, 0, 0))

func test_small_direction_change_keeps_stroke() -> void:
	# Small angle change (under variance threshold) is the same stroke.
	var prev_dir := Vector3(1, 0, 0)
	# Move mostly +X, slightly +Z (angle ~18°, under 45°).
	var delta := Vector3(1.0, 0, 0.3).normalized() * 0.5
	var result: Dictionary = ChargeTracking.accumulate(
		Vector3.ZERO, delta, Vector3.ZERO, delta, prev_dir, VARIANCE_DEG)
	assert_false(result.reset, "small wobble is not a variance break")

func test_first_tick_no_prev_direction_no_reset() -> void:
	# prev_direction == Vector3.ZERO → no variance check.
	var result: Dictionary = ChargeTracking.accumulate(
		Vector3.ZERO, Vector3(0.5, 0, 0), Vector3.ZERO, Vector3(0.5, 0, 0),
		Vector3.ZERO, VARIANCE_DEG)
	assert_false(result.reset, "first motion after entry is not a variance break")
	assert_eq(result.direction, Vector3(1, 0, 0))

# ── Swing rotation (the forehand/backhand chirality signal) ──────────────────

func test_swing_step_signed_angle() -> void:
	# Quarter turn of the blade bearing +X → +Z is one rotational sense; the
	# reverse is the opposite sign; identical bearings are zero.
	assert_almost_eq(ChargeTracking.swing_step(Vector3(1, 0, 0), Vector3(0, 0, 1)),
		-PI / 2.0, 0.001, "+X → +Z is a signed quarter turn")
	assert_almost_eq(ChargeTracking.swing_step(Vector3(0, 0, 1), Vector3(1, 0, 0)),
		PI / 2.0, 0.001, "the reverse sweep is the opposite sign")
	assert_almost_eq(ChargeTracking.swing_step(Vector3(1, 0, 0), Vector3(1, 0, 0)),
		0.0, 0.001, "no bearing change → no rotation")

func test_swing_step_ignores_height_and_degenerate() -> void:
	assert_almost_eq(ChargeTracking.swing_step(Vector3(1, 0, 0), Vector3(0, 5, 1)),
		-PI / 2.0, 0.001, "vertical component ignored")
	assert_almost_eq(ChargeTracking.swing_step(Vector3.ZERO, Vector3(1, 0, 0)),
		0.0, 0.001, "degenerate bearing → zero")

func test_rotation_accumulates_one_step() -> void:
	# First tick (no prev direction, cursor moving): rotation = the blade's
	# angular step around the player.
	var result: Dictionary = ChargeTracking.accumulate(
		Vector3.ZERO, Vector3(0.5, 0, 0), Vector3(1, 0, 0), Vector3(0, 0, 1),
		Vector3.ZERO, VARIANCE_DEG, 0.0)
	assert_almost_eq(result.rotation, -PI / 2.0, 0.001, "one quarter-turn step accumulated")

func test_rotation_idle_tick_holds() -> void:
	var result: Dictionary = ChargeTracking.accumulate(
		Vector3(0.5, 0, 0), Vector3(0.5, 0, 0), Vector3(1, 0, 0), Vector3(0, 0, 1),
		Vector3(1, 0, 0), VARIANCE_DEG, 2.5)
	assert_almost_eq(result.rotation, 2.5, 0.001, "idle cursor holds rotation")

func test_rotation_resets_on_variance_break() -> void:
	# A variance break starts a fresh stroke: prior rotation is discarded and
	# only this tick's step counts — so a deke-then-shoot classifies off the
	# shot's own rotation, not the deke's.
	var result: Dictionary = ChargeTracking.accumulate(
		Vector3(0.5, 0, 0), Vector3(0.3, 0, 0),          # cursor reverses → break
		Vector3(1, 0, 0), Vector3(0, 0, 1),
		Vector3(1, 0, 0), VARIANCE_DEG, 5.0)
	assert_true(result.reset)
	assert_almost_eq(result.rotation, -PI / 2.0, 0.001, "rotation reset then this step counted")

# ── Stroke travel (the power-ceiling gate signal) ─────────────────────────────

func test_travel_step_xz_length() -> void:
	assert_almost_eq(ChargeTracking.travel_step(Vector3.ZERO, Vector3(0.3, 0, 0.4)),
		0.5, 0.001, "travel step is the XZ path length")
	assert_almost_eq(ChargeTracking.travel_step(Vector3.ZERO, Vector3(0.3, 5.0, 0.4)),
		0.5, 0.001, "vertical component ignored")
	assert_almost_eq(ChargeTracking.travel_step(Vector3.ZERO, Vector3(3, 0, 4), 0.5),
		0.5, 0.001, "step capped at max_step (anti-teleport bound)")

func test_travel_accumulates_over_stroke() -> void:
	# Two ticks of a steady drag: blade sweeps 0.2 then 0.3 → 0.5 m of stroke.
	var s1: Dictionary = ChargeTracking.accumulate(
		Vector3.ZERO, Vector3(0.5, 0, 0),
		Vector3(1.0, 0, 0), Vector3(1.2, 0, 0),
		Vector3.ZERO, VARIANCE_DEG, 0.0, 0.0)
	assert_almost_eq(s1.travel, 0.2, 0.001, "first tick banks its blade step")
	var s2: Dictionary = ChargeTracking.accumulate(
		Vector3(0.5, 0, 0), Vector3(1.0, 0, 0),
		Vector3(1.2, 0, 0), Vector3(1.5, 0, 0),
		s1.direction, VARIANCE_DEG, s1.rotation, s1.travel)
	assert_almost_eq(s2.travel, 0.5, 0.001, "same-stroke steps sum")

func test_travel_holds_without_cursor_intent() -> void:
	# Cursor idle, blade moved anyway (locomotion/IK noise) — no intent, no
	# travel banked: the gate can't be farmed by skating with the blade out.
	var result: Dictionary = ChargeTracking.accumulate(
		Vector3(0.5, 0, 0), Vector3(0.5, 0, 0),
		Vector3(1.0, 0, 0), Vector3(1.4, 0, 0),
		Vector3(1, 0, 0), VARIANCE_DEG, 0.0, 0.3)
	assert_almost_eq(result.travel, 0.3, 0.001, "idle cursor holds travel")

func test_travel_resets_on_variance_break() -> void:
	# A wiggle's direction reversal starts a fresh stroke: banked travel is
	# discarded and only this tick's step counts — a zig-zag can never
	# accumulate the full-stroke travel that unlocks the power ceiling.
	var result: Dictionary = ChargeTracking.accumulate(
		Vector3(0.5, 0, 0), Vector3(0.3, 0, 0),          # cursor reverses → break
		Vector3(1.0, 0, 0), Vector3(1.1, 0, 0),
		Vector3(1, 0, 0), VARIANCE_DEG, 0.0, 2.0)
	assert_true(result.reset)
	assert_almost_eq(result.travel, 0.1, 0.001, "travel reset, then this tick's step counted")

func test_travel_step_capped_in_accumulate() -> void:
	# A one-tick blade-target jump across the arc banks only max_travel_step —
	# forged cursor teleports can't buy the stroke.
	var result: Dictionary = ChargeTracking.accumulate(
		Vector3.ZERO, Vector3(0.5, 0, 0),
		Vector3(1.0, 0, 0), Vector3(-1.0, 0, 0),         # 2.0 m target jump
		Vector3.ZERO, VARIANCE_DEG, 0.0, 0.0, 0.25)
	assert_almost_eq(result.travel, 0.25, 0.001, "per-tick travel bounded by max_travel_step")

func test_swing_direction_classifies_forehand_vs_backhand() -> void:
	# End-to-end: a two-tick arc one way vs the other yields opposite net
	# rotation, which ShotMechanics.is_backhand_from_swing reads as FH vs BH.
	# Cursor drags a constant +X the whole time (no variance break); only the
	# blade bearing rotates.
	var s1: Dictionary = ChargeTracking.accumulate(
		Vector3.ZERO, Vector3(0.5, 0, 0),
		Vector3(1, 0, 0), Vector3(0.707, 0, 0.707),
		Vector3.ZERO, VARIANCE_DEG, 0.0)
	var s2: Dictionary = ChargeTracking.accumulate(
		Vector3(0.5, 0, 0), Vector3(1.0, 0, 0),
		Vector3(0.707, 0, 0.707), Vector3(0, 0, 1),
		s1.direction, VARIANCE_DEG, s1.rotation)
	assert_almost_eq(s2.rotation, -PI / 2.0, 0.01, "consistent arc sums its steps")
	assert_true(ShotMechanics.is_backhand_from_swing(s2.rotation, false),
		"negative net rotation is a RH backhand")
	assert_false(ShotMechanics.is_backhand_from_swing(-s2.rotation, false),
		"the mirror arc is a RH forehand")
