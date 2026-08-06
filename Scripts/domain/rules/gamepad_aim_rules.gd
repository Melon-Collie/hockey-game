class_name GamepadAimRules
## Pure math for driving the blade cursor from an analog right stick, so a gamepad
## can stickhandle and shoot through the SAME pipeline the mouse uses.
##
## The whole sim reads the blade target from InputState.mouse_world_pos /
## mouse_screen_pos (a screen cursor ray-projected onto the ice), and the wrister
## aims POSITIONALLY along origin→cursor. Feeding a synthesized cursor back through
## those fields means blade IK and the charge tracker run unchanged — no controller
## branch below the input gatherer. See docs/gameplay-design.md.
##
## The gatherer maps the stick to a cursor with `absolute_cursor` (anchor + offset).
## WHICH anchor is the whole trick, and it differs by mode:
##   * STICKHANDLE: anchored on the BODY, proportional — precise blade placement;
##     the gatherer eases the cursor to a forward rest when the stick is released.
##   * SHOOT (RT held): anchored on the PUCK (the blade contact point, pinned at
##     the trigger edge), parked at the reach radius in the stick DIRECTION. The
##     shot line is origin→cursor from that same puck, so anchoring there is what
##     makes the shot go exactly where the stick points — a held aim, decoupled
##     from motion and from camera zoom — and what makes the stick's bearing the
##     shot line's bearing, so the swing-chirality forehand/backhand read needs no
##     gamepad branch. Power rides the TRIGGER's analog travel (below), not the
##     stick, so shooting needs no flick, drag timing, or travel gate.
##
## ONE THUMB, ONE JOB. Aim and power were both on the right stick (bearing and
## push magnitude); a thumb cannot hold a bearing to a corner while metering a
## magnitude, so every precise shot cost the other axis. Splitting power onto the
## trigger — a separate digit with its own travel — makes the two independent.

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

# Schmitt trigger for an analog pull (raw 0..1 axis) used as a button: engages at
# `press`, disengages only back below `release`. A single threshold chatters when
# the pull rests on it — trigger noise is ~0.01-0.02, but a finger holding a
# trigger *at* the shot point is not steady, and each spurious edge would fire a
# shot. `press` sits low (see the caller) because everything above it is the
# power band, and travel spent reaching the press point is travel you can't shoot
# with.
static func trigger_held(depth: float, was_held: bool, press: float, release: float) -> bool:
	if was_held:
		return depth > release
	return depth >= press

# Analog pull → shot power fraction (0..1) over the USABLE travel. The band runs
# from `press` (the shot is already committed by the time it registers, so that
# pull is 0 power, not the minimum-power floor plus a step) to `full`.
#
# `full` sits SHORT of 1.0 on purpose: pads differ in how close to the mechanical
# stop they actually report, and several never reach 1.0 at all. Topping the band
# out at the stop would put the last few percent of power in travel that some
# hardware cannot physically produce — so a full rip would be unavailable on that
# pad, silently. Everything at or past `full` is a full rip.
static func trigger_power_t(depth: float, press: float, full: float) -> float:
	if full <= press:
		return 1.0
	return clampf((depth - press) / (full - press), 0.0, 1.0)

# Is the trigger SPRINGING BACK (finger leaving) rather than being dialled down?
#
# The shot fires on trigger release, so power has to be read from the pull the
# player was HOLDING — but a trigger sweeps its whole travel on the way out, and
# the last sample before it drops under the release point is a low one. Latching
# that turns every shot into a dribbler.
#
# The two motions separate cleanly by RATE, not by magnitude: a return spring
# unloads the trigger in ~40 ms (~15-25 units/s), while a deliberate ease-off is
# a muscle movement an order of magnitude slower (~1-3 units/s). So the latch
# follows the pull except while it is falling faster than any thumb dials, which
# preserves an exact held power on release AND leaves a slow ease-off free to
# genuinely soften the shot. `delta`-based so it reads the same at any tick rate.
static func trigger_is_springing_back(
		depth: float, prev_depth: float, delta: float, release_rate: float) -> bool:
	if delta <= 0.0:
		return false
	return (depth - prev_depth) / delta <= -release_rate
