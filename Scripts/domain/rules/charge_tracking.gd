class_name ChargeTracking

# Accumulates wrister charge from two decoupled signals:
#   - DIRECTION & variance check: derived from the cursor (intent) delta.
#     Captures what the player is dragging toward — independent of body
#     pose, blade IK convergence, or ROM clamping.
#   - MAGNITUDE: blade delta PROJECTED onto the intent direction. Only
#     blade motion aligned with the player's drag intent counts toward
#     charge — blade motion at an angle (e.g., body-rotation tangent,
#     IK catch-up after a press snap, locomotion residue) is filtered
#     out. ROM clamping still gates magnitude because a pinned blade
#     produces zero blade_delta regardless of intent.
#
# Both positions are passed in the same frame (typically world XZ minus
# skater translation, so locomotion / camera drift cancels out). The
# tracker itself doesn't care which frame as long as it's consistent.
#
# Resets the accumulator when the cursor's direction of motion changes
# by more than max_direction_variance_deg — models the player "setting
# up" the shot: a straight drag loads charge; zig-zags reset it.
#
# Caller owns the per-frame state (prev_intent_pos, prev_blade_pos,
# prev_direction, charge). Each tick it calls accumulate() with the
# current positions and stores back the returned values.
#
# Returns { "charge": float, "direction": Vector3 }.
#   - direction: the most recent meaningful cursor-motion unit vector.
#     Caller passes this as prev_direction next tick. Vector3.ZERO means
#     "no direction yet recorded" (first frame or negligible cursor
#     motion).
static func accumulate(
		prev_intent_pos: Vector3,
		current_intent_pos: Vector3,
		prev_blade_pos: Vector3,
		current_blade_pos: Vector3,
		prev_direction: Vector3,
		current_charge: float,
		max_direction_variance_deg: float) -> Dictionary:
	var intent_delta := current_intent_pos - prev_intent_pos
	intent_delta.y = 0.0
	var intent_dist: float = intent_delta.length()
	if intent_dist <= 0.001:
		# Cursor not moving — no drag intent this tick. Hold direction
		# and charge unchanged regardless of what the blade did
		# (e.g., locomotion-induced blade motion doesn't pump charge
		# without intent).
		return {"charge": current_charge, "direction": prev_direction}

	var current_dir: Vector3 = intent_delta.normalized()
	var new_charge: float = current_charge
	if prev_direction != Vector3.ZERO:
		var angle_deg: float = rad_to_deg(prev_direction.angle_to(current_dir))
		if angle_deg > max_direction_variance_deg:
			new_charge = 0.0

	# Magnitude from blade travel PROJECTED onto the intent direction.
	# Only motion the player intended counts — tangential blade motion
	# (body-rotation drift, IK catch-up after a press snap) projects to
	# zero or negative and contributes nothing. ROM clamping still gates
	# because a pinned blade has zero blade_delta.
	var blade_delta := current_blade_pos - prev_blade_pos
	blade_delta.y = 0.0
	var aligned_magnitude: float = blade_delta.dot(current_dir)
	if aligned_magnitude > 0.0:
		new_charge += aligned_magnitude

	return {"charge": new_charge, "direction": current_dir}
