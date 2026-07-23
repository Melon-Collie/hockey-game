class_name GamepadAimRules
## Pure mapping from an analog right-stick deflection to a screen-space blade
## cursor, so a gamepad can drive stickhandling through the SAME pipeline the
## mouse uses.
##
## The whole sim reads the blade target from InputState.mouse_world_pos /
## mouse_screen_pos (a screen cursor ray-projected onto the ice). Feeding a
## SYNTHESIZED cursor back through those two fields lets blade IK, the wrister
## charge tracker and its travel gate run unchanged — there is no controller
## branch anywhere below the input gatherer. See CLAUDE.md → "How It Plays".
##
## The mapping is an ABSOLUTE "skill stick": deflection magnitude maps radially
## to a distance from `anchor` (the skater's on-screen position), so pushing the
## stick to a heading parks the blade at that heading. Holding the stick still
## holds the cursor still (zero screen-space speed → zero wrister charge, exactly
## like a held mouse); flicking it produces real screen-space cursor speed, which
## is the whole signal the pure-mouse-speed wrister power model reads.

# Radial deadzone with edge rescale. Below `deadzone` the stick reads dead-zero;
# from the deadzone edge outward the magnitude is rescaled to span the full 0..1
# so there is no discontinuous step at the boundary. Direction is preserved.
# Returns a vector of magnitude 0..1.
static func apply_radial_deadzone(stick: Vector2, deadzone: float) -> Vector2:
	var mag: float = stick.length()
	if mag <= deadzone:
		return Vector2.ZERO
	var span: float = 1.0 - deadzone
	if span <= 0.0:
		return stick / mag  # degenerate deadzone (>=1): treat any live input as full
	var scaled: float = clampf((mag - deadzone) / span, 0.0, 1.0)
	return (stick / mag) * scaled

# Screen-space blade cursor = anchor + deadzoned_direction * radius_px. `stick`
# is the raw right-stick vector in the JOY_AXIS_RIGHT_* convention (x right,
# y down) — which already matches screen axes, so it needs no reframing. radius_px
# is how far a full deflection reaches from the anchor, in pixels.
static func blade_cursor_screen(anchor: Vector2, stick: Vector2, radius_px: float, deadzone: float) -> Vector2:
	return anchor + apply_radial_deadzone(stick, deadzone) * radius_px
