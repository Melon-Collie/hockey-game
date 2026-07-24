extends GutTest

# GamepadAimRules — the right-stick deadzone + velocity-integrated cursor that
# lets a gamepad drive stickhandling and shooting through the mouse pipeline.
# Pure math, no engine input needed.

const DZ: float = 0.15
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


func test_absolute_cursor_is_proportional_offset() -> void:
	# Stickhandle mode: cursor = anchor + stick * radius. Centered → on the anchor;
	# full deflection → a radius out; half → half-way (proportional placement).
	assert_eq(GamepadAimRules.absolute_cursor(ANCHOR, Vector2.ZERO, RADIUS), ANCHOR,
			"centered stick sits on the anchor")
	var full: Vector2 = GamepadAimRules.absolute_cursor(ANCHOR, Vector2(1.0, 0.0), RADIUS)
	assert_almost_eq(full.x, ANCHOR.x + RADIUS, 0.01, "full-right places the blade a radius out")
	var half: Vector2 = GamepadAimRules.absolute_cursor(ANCHOR, Vector2(0.0, 0.5), RADIUS)
	assert_almost_eq(half.y, ANCHOR.y + RADIUS * 0.5, 0.01, "half-deflection places half-way out")


func test_normalized_stick_parks_at_the_rim_for_aim() -> void:
	# Shot aim: a normalized stick places the cursor a full radius out in the stick
	# direction, so player→cursor is a clean stick-direction shot line regardless of
	# how hard the stick is pushed (magnitude is power, handled separately).
	var gentle: Vector2 = GamepadAimRules.absolute_cursor(ANCHOR, Vector2(0.3, 0.0).normalized(), RADIUS)
	var hard: Vector2 = GamepadAimRules.absolute_cursor(ANCHOR, Vector2(1.0, 0.0).normalized(), RADIUS)
	assert_eq(gentle, hard, "aim direction is independent of push strength")
	assert_almost_eq((gentle - ANCHOR).length(), RADIUS, 0.01, "parked at the reach radius")
