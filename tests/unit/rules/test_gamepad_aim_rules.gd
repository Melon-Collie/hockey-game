extends GutTest

# GamepadAimRules — the right-stick "skill stick" → screen-cursor mapping that
# lets a gamepad drive stickhandling through the mouse pipeline. Pure math, no
# engine input needed.

const DZ: float = 0.15
const RADIUS: float = 480.0


func test_deadzone_zeros_small_input() -> void:
	assert_eq(GamepadAimRules.apply_radial_deadzone(Vector2(0.1, 0.0), DZ), Vector2.ZERO,
			"input inside the deadzone reads dead-zero")
	assert_eq(GamepadAimRules.apply_radial_deadzone(Vector2.ZERO, DZ), Vector2.ZERO,
			"a centered stick reads zero")


func test_deadzone_edge_rescales_to_full_span() -> void:
	# Just past the deadzone edge → ~0 magnitude (no discontinuous step).
	var near_edge: Vector2 = GamepadAimRules.apply_radial_deadzone(Vector2(DZ + 0.001, 0.0), DZ)
	assert_almost_eq(near_edge.length(), 0.0, 0.01, "magnitude ramps up from zero at the deadzone edge")
	# Full deflection → magnitude 1 (the span is rescaled, not clipped at 1 - dz).
	var full: Vector2 = GamepadAimRules.apply_radial_deadzone(Vector2(1.0, 0.0), DZ)
	assert_almost_eq(full.length(), 1.0, 0.0001, "full deflection reaches magnitude 1")
	# Halfway through the live span → ~0.5.
	var mid_mag: float = DZ + (1.0 - DZ) * 0.5
	var mid: Vector2 = GamepadAimRules.apply_radial_deadzone(Vector2(mid_mag, 0.0), DZ)
	assert_almost_eq(mid.length(), 0.5, 0.0001, "midpoint of the live span reads half")


func test_deadzone_preserves_direction() -> void:
	var raw := Vector2(0.6, 0.8)  # length 1.0, 3-4-5 direction
	var out: Vector2 = GamepadAimRules.apply_radial_deadzone(raw, DZ)
	assert_almost_eq(out.angle(), raw.angle(), 0.0001, "deadzone rescale keeps the heading")


func test_deadzone_clamps_overrange_magnitude() -> void:
	# Analog noise / a forged axis can exceed 1.0; magnitude must still cap at 1.
	var out: Vector2 = GamepadAimRules.apply_radial_deadzone(Vector2(2.0, 0.0), DZ)
	assert_almost_eq(out.length(), 1.0, 0.0001, "over-range deflection clamps to unit")


func test_cursor_anchors_at_zero_stick() -> void:
	var anchor := Vector2(960.0, 540.0)
	var cursor: Vector2 = GamepadAimRules.blade_cursor_screen(anchor, Vector2.ZERO, RADIUS, DZ)
	assert_eq(cursor, anchor, "a centered stick parks the cursor on the anchor")


func test_cursor_offsets_by_radius_at_full_deflection() -> void:
	var anchor := Vector2(960.0, 540.0)
	# Stick pushed fully right → cursor is RADIUS px to the right of the anchor.
	var cursor: Vector2 = GamepadAimRules.blade_cursor_screen(anchor, Vector2(1.0, 0.0), RADIUS, DZ)
	assert_almost_eq(cursor.x, anchor.x + RADIUS, 0.01, "full-right parks the cursor a radius right")
	assert_almost_eq(cursor.y, anchor.y, 0.01, "no vertical offset for a purely horizontal push")
	# Screen-down convention: +y stick pushes the cursor down.
	var down: Vector2 = GamepadAimRules.blade_cursor_screen(anchor, Vector2(0.0, 1.0), RADIUS, DZ)
	assert_almost_eq(down.y, anchor.y + RADIUS, 0.01, "full-down parks the cursor a radius below")
