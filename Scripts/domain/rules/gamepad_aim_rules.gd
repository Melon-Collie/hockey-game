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
## The cursor runs in two modes (the gatherer picks per frame on the shoot trigger):
##   * STICKHANDLE — `absolute_cursor`: the stick maps to an absolute offset from
##     the anchor (proportional, precise blade placement). The gatherer freezes the
##     cursor when the stick is centered, so letting go HOLDS the blade in place.
##   * SHOOT (RT held) — `integrate_cursor`: the stick sets the cursor's screen
##     VELOCITY, so a flick is clean directional motion and — crucially — releasing
##     the stick to center produces NO motion, so it can't snap back toward the
##     anchor and corrupt the wrister's release read (which is what made absolute
##     shooting fire random directions).

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

# STICKHANDLE mode: absolute screen cursor = anchor + deadzoned_stick * radius_px.
# `stick_dz` is a 0..1 vector in the JOY_AXIS_RIGHT_* convention (x right, y down),
# which already matches screen axes. Proportional: half-deflection places the blade
# half-way out to the reach radius.
static func absolute_cursor(anchor: Vector2, stick_dz: Vector2, radius_px: float) -> Vector2:
	return anchor + stick_dz * radius_px

# SHOOT mode: advance the cursor by the (deadzoned) stick velocity and clamp it into
# a `max_radius_px` disc around `anchor`. `speed_px_s` is the cursor speed at full
# deflection. limit_length is a no-op inside the disc, so a held cursor not at the
# rim is left untouched (it holds in stable screen space — no snap-back on release).
static func integrate_cursor(cursor: Vector2, stick_dz: Vector2, speed_px_s: float,
		delta: float, anchor: Vector2, max_radius_px: float) -> Vector2:
	var moved: Vector2 = cursor + stick_dz * speed_px_s * delta
	return anchor + (moved - anchor).limit_length(max_radius_px)
