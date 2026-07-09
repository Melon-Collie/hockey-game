class_name ChargeTracking

# Accumulates wrister charge from two decoupled signals:
#   - DIRECTION & variance check: derived from the cursor (intent) delta.
#     The intent_pos is conventionally screen space (pixel position
#     packed as Vector3(x, 0, y)), which is the camera-immune frame —
#     pixel motion captures the player's mouse drag intent independent
#     of camera lag, body rotation, or skater locomotion. World-space
#     intent leaks transient bias from camera-follow lag during brakes
#     and direction changes; screen-space doesn't.
#   - MAGNITUDE: blade delta PROJECTED onto the intent direction. Only
#     blade motion aligned with the player's drag intent counts toward
#     charge — blade motion at an angle (body-rotation tangent, IK
#     catch-up after a press snap, locomotion residue) is filtered out.
#     ROM clamping still gates magnitude because a pinned blade produces
#     zero blade_delta regardless of intent.
#
# Frames don't need to match between the two signals — intent_pos can be
# in screen pixels while blade_pos is in world meters, because direction
# only uses intent_pos and magnitude only uses blade_pos. The dot product
# is direction × blade_delta and only the SIGN of the dot matters when
# you've already factored out unit conversion (intent_pos normalized).
#
# Resets the accumulator when the cursor's direction of motion changes
# by more than max_direction_variance_deg — models the player "setting
# up" the shot: a straight drag loads charge; zig-zags reset it.
#
# SWEEP TIME: alongside distance, accumulate() tracks how long the sweep
# actively spent moving (delta added only on ticks that counted charge).
# charge / sweep_time is the AVERAGE sweep speed — the primary power
# signal of the wrister (ShotMechanics.wrister_power_t): a slow deliberate
# sweep is a soft pass, a ripped sweep is a full shot. Ticks where the
# cursor holds still add neither charge nor time, so "draw, then hold for
# the shooting lane" preserves the loaded shot instead of diluting it.
# A direction-variance reset zeroes time together with charge — a new
# sweep starts a fresh average.
#
# COUNTED-SPEED CAP: per-tick counted blade travel is clamped to
# max_counted_speed × delta. The blade TARGET the caller measures is the
# ROM-clamped cursor projection, so a single-tick cursor yank can
# otherwise traverse the whole reachable arc at once and load full charge
# with zero runway. The cap is the "the blade can only move so fast"
# budget for charge counting: a yank still reads as a fast sweep (high
# average speed) but only banks the capped distance, so instant gestures
# release as snaps, not full wristers. Pass <= 0.0 to disable (legacy
# behavior).
#
# Caller owns the per-frame state (prev_intent_pos, prev_blade_pos,
# prev_direction, charge, sweep_time). Each tick it calls accumulate()
# with the current positions and stores back the returned values.
#
# Returns { "charge": float, "direction": Vector3, "sweep_time": float,
#           "reset": bool }.
#   - direction: the most recent meaningful cursor-motion unit vector.
#     Caller passes this as prev_direction next tick. Vector3.ZERO means
#     "no direction yet recorded" (first frame or negligible cursor
#     motion).
#   - reset: true when the direction-variance break fired this tick — a NEW
#     power stroke started. Callers that classify the shot by where the
#     stroke began (the forehand/backhand read) re-capture on this flag so
#     the classification belongs to the live sweep, not to a stale snapshot
#     from aim entry.
static func accumulate(
		prev_intent_pos: Vector3,
		current_intent_pos: Vector3,
		prev_blade_pos: Vector3,
		current_blade_pos: Vector3,
		prev_direction: Vector3,
		current_charge: float,
		max_direction_variance_deg: float,
		current_sweep_time: float = 0.0,
		delta: float = 0.0,
		max_counted_speed: float = 0.0) -> Dictionary:
	var intent_delta := current_intent_pos - prev_intent_pos
	intent_delta.y = 0.0
	var intent_dist: float = intent_delta.length()
	if intent_dist <= 0.001:
		# Cursor not moving — no drag intent this tick. Hold direction,
		# charge, and sweep time unchanged regardless of what the blade
		# did (e.g., locomotion-induced blade motion doesn't pump charge
		# without intent). Holding time too is what lets a player draw
		# the shot and wait for a lane without the average speed decaying.
		return {"charge": current_charge, "direction": prev_direction,
				"sweep_time": current_sweep_time, "reset": false}

	var current_dir: Vector3 = intent_delta.normalized()
	var new_charge: float = current_charge
	var new_sweep_time: float = current_sweep_time
	var was_reset: bool = false
	if prev_direction != Vector3.ZERO:
		var angle_deg: float = rad_to_deg(prev_direction.angle_to(current_dir))
		if angle_deg > max_direction_variance_deg:
			new_charge = 0.0
			new_sweep_time = 0.0
			was_reset = true

	# Magnitude from blade travel PROJECTED onto the intent direction.
	# Only motion the player intended counts — tangential blade motion
	# (body-rotation drift, IK catch-up after a press snap) projects to
	# zero or negative and contributes nothing. ROM clamping still gates
	# because a pinned blade has zero blade_delta.
	var blade_delta := current_blade_pos - prev_blade_pos
	blade_delta.y = 0.0
	var aligned_magnitude: float = blade_delta.dot(current_dir)
	if aligned_magnitude > 0.0:
		if max_counted_speed > 0.0 and delta > 0.0:
			aligned_magnitude = minf(aligned_magnitude, max_counted_speed * delta)
		new_charge += aligned_magnitude
		new_sweep_time += delta

	return {"charge": new_charge, "direction": current_dir,
			"sweep_time": new_sweep_time, "reset": was_reset}
