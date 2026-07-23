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
## The cursor is VELOCITY-INTEGRATED, not an absolute stick-to-position map. The
## stick sets the cursor's screen-space velocity; a centered stick leaves it
## exactly where it was. This matches the mouse in the two ways that matter:
##   * it HOLDS position when you let go (you place the blade and it stays), and
##   * its motion is pure stick intent in stable screen space — independent of the
##     skater/camera drift that made an absolute skater-anchored cursor read random
##     wrister power and direction.
## The integrated cursor is clamped into a reach disc around an anchor so it stays
## on reachable ice; the blade IK ROM-clamps beyond that.

# Radial deadzone with edge rescale. Below `deadzone` the stick reads dead-zero
# (so a resting stick can't slowly drift the held cursor); from the deadzone edge
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

# Advance the screen-space cursor by the (already deadzoned) stick velocity and
# clamp it into a `max_radius_px` disc around `anchor`. `stick_dz` is a 0..1
# vector in the JOY_AXIS_RIGHT_* convention (x right, y down) — which already
# matches screen axes. `speed_px_s` is the cursor speed at full deflection.
static func integrate_cursor(cursor: Vector2, stick_dz: Vector2, speed_px_s: float,
		delta: float, anchor: Vector2, max_radius_px: float) -> Vector2:
	var moved: Vector2 = cursor + stick_dz * speed_px_s * delta
	# limit_length is a no-op when already inside the disc, so a held cursor that
	# is not at the rim is left untouched (it holds in stable screen space).
	return anchor + (moved - anchor).limit_length(max_radius_px)
