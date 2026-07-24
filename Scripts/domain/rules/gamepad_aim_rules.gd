class_name GamepadAimRules
## Pure math for driving the blade cursor from an analog right stick, so a gamepad
## can stickhandle and shoot through the SAME pipeline the mouse uses.
##
## The whole sim reads the blade target from InputState.mouse_world_pos /
## mouse_screen_pos (a screen cursor ray-projected onto the ice), and the wrister
## reads that cursor's screen-space SPEED for power and its drag DIRECTION for aim.
## Feeding a synthesized cursor back through those fields means blade IK, the
## charge tracker and its travel gate run unchanged — no controller branch below
## the input gatherer. See CLAUDE.md → "How It Plays".
##
## The gatherer maps the stick to a cursor with `absolute_cursor` (anchor + offset):
##   * STICKHANDLE: proportional, precise blade placement; the gatherer eases the
##     cursor to a forward rest when the stick is released.
##   * SHOOT (RT held): the cursor is parked at the reach radius in the stick
##     DIRECTION, so the shot line (player→cursor) points where the stick points —
##     a held aim, decoupled from motion. Power is committed separately from the
##     stick magnitude, so shooting needs no flick, drag timing, or travel gate.

# Radial deadzone with edge rescale. Below `deadzone` the stick reads dead-zero
# (so a resting stick holds the cursor and can't drift it); from the deadzone edge
# outward the magnitude is rescaled to span the full 0..1 with no step at the
# boundary. Direction is preserved; magnitude is clamped to 1.
static func apply_radial_deadzone(stick: Vector2, deadzone: float) -> Vector2:
	var mag: float = stick.length()
	if mag <= deadzone:
		return Vector2.ZERO
	var span: float = 1.0 - deadzone
	if span <= 0.0:
		return stick / mag  # degenerate deadzone (>=1): treat any live input as full
	var scaled: float = clampf((mag - deadzone) / span, 0.0, 1.0)
	return (stick / mag) * scaled

# Absolute screen cursor = anchor + deadzoned_stick * radius_px. `stick_dz` is a
# 0..1 vector in the JOY_AXIS_RIGHT_* convention (x right, y down), which already
# matches screen axes. Proportional: half-deflection places the blade half-way out
# to the reach radius (stickhandle). Passing a normalized stick parks the cursor at
# the rim in the stick direction (shot aim).
static func absolute_cursor(anchor: Vector2, stick_dz: Vector2, radius_px: float) -> Vector2:
	return anchor + stick_dz * radius_px
