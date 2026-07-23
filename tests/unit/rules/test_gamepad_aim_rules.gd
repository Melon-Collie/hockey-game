extends GutTest

# GamepadAimRules — the right-stick deadzone + velocity-integrated cursor that
# lets a gamepad drive stickhandling and shooting through the mouse pipeline.
# Pure math, no engine input needed.

const DZ: float = 0.15
const SPEED: float = 3200.0
const RADIUS: float = 480.0
const ANCHOR := Vector2(960.0, 540.0)


func test_deadzone_zeros_small_input() -> void:
	assert_eq(GamepadAimRules.apply_radial_deadzone(Vector2(0.1, 0.0), DZ), Vector2.ZERO,
			"input inside the deadzone reads dead-zero")
	assert_eq(GamepadAimRules.apply_radial_deadzone(Vector2.ZERO, DZ), Vector2.ZERO,
			"a centered stick reads zero")


func test_deadzone_edge_rescales_to_full_span() -> void:
	var near_edge: Vector2 = GamepadAimRules.apply_radial_deadzone(Vector2(DZ + 0.001, 0.0), DZ)
	assert_almost_eq(near_edge.length(), 0.0, 0.01, "magnitude ramps up from zero at the deadzone edge")
	var full: Vector2 = GamepadAimRules.apply_radial_deadzone(Vector2(1.0, 0.0), DZ)
	assert_almost_eq(full.length(), 1.0, 0.0001, "full deflection reaches magnitude 1")
	var mid_mag: float = DZ + (1.0 - DZ) * 0.5
	var mid: Vector2 = GamepadAimRules.apply_radial_deadzone(Vector2(mid_mag, 0.0), DZ)
	assert_almost_eq(mid.length(), 0.5, 0.0001, "midpoint of the live span reads half")


func test_deadzone_preserves_direction_and_clamps_overrange() -> void:
	var raw := Vector2(0.6, 0.8)  # length 1.0, 3-4-5 direction
	var out: Vector2 = GamepadAimRules.apply_radial_deadzone(raw, DZ)
	assert_almost_eq(out.angle(), raw.angle(), 0.0001, "deadzone rescale keeps the heading")
	var over: Vector2 = GamepadAimRules.apply_radial_deadzone(Vector2(2.0, 0.0), DZ)
	assert_almost_eq(over.length(), 1.0, 0.0001, "over-range deflection clamps to unit")


func test_centered_stick_holds_cursor() -> void:
	# The #1 fix: a centered stick must leave the cursor exactly where it was —
	# no snap back to the anchor, so the player can set the blade and skate freely.
	var held := Vector2(1200.0, 400.0)
	var out: Vector2 = GamepadAimRules.integrate_cursor(held, Vector2.ZERO, SPEED, 0.016, ANCHOR, RADIUS)
	assert_eq(out, held, "zero stick velocity holds the cursor in place")


func test_cursor_integrates_by_stick_velocity() -> void:
	# Cursor advances by stick * speed * delta (pure screen-space velocity — the
	# signal the wrister reads for power/direction, free of skater/camera drift).
	var out: Vector2 = GamepadAimRules.integrate_cursor(ANCHOR, Vector2(1.0, 0.0), SPEED, 0.01, ANCHOR, RADIUS)
	assert_almost_eq(out.x, ANCHOR.x + SPEED * 0.01, 0.01, "full-right advances one step of stick velocity")
	assert_almost_eq(out.y, ANCHOR.y, 0.01, "no vertical drift on a horizontal push")


func test_cursor_clamps_to_reach_disc() -> void:
	# A sustained push pins at the reach radius, never running off toward the edge.
	var out := ANCHOR
	for _i in range(200):  # far more than enough to reach the rim
		out = GamepadAimRules.integrate_cursor(out, Vector2(0.0, 1.0), SPEED, 0.016, ANCHOR, RADIUS)
	assert_almost_eq((out - ANCHOR).length(), RADIUS, 0.01, "held stick pins the cursor at the reach radius")
	assert_almost_eq(out.x, ANCHOR.x, 0.01, "and stays on the pushed axis")
