class_name ChargeTracking

# Tracks the wrister SWING — its rotational chirality (forehand/backhand) and
# the "setting up" reset — from the cursor (intent) delta and the blade bearing.
# Power is NOT tracked here: it's the raw cursor speed (SkaterAimingBehavior.
# cursor_speed_ema), the pure mouse-speed model. This rule only answers "which
# way is the blade curling" and "did the player break their stroke".
#
#   - DIRECTION & variance check: derived from the cursor (intent) delta.
#     The intent_pos is conventionally screen space (pixel position
#     packed as Vector3(x, 0, y)), which is the camera-immune frame —
#     pixel motion captures the player's mouse drag intent independent
#     of camera lag, body rotation, or skater locomotion. World-space
#     intent leaks transient bias from camera-follow lag during brakes
#     and direction changes; screen-space doesn't.
#
# Resets the stroke when the cursor's direction of motion changes by more
# than max_direction_variance_deg — models the player "setting up" the shot:
# a straight drag holds one swing; a zig-zag starts a fresh one.
#
# SWING ROTATION: the signed angular sweep of the blade AROUND THE PLAYER,
# accumulated in radians over the stroke (blade positions are passed relative
# to the skater, so the player is the rotation center). Each tick adds the
# signed angle from the previous blade bearing to the current one
# (atan2(cross.y, dot) — the standard clockwise-vs-counter-clockwise test).
# The SIGN of the accumulated total is the forehand/backhand chirality: a
# forehand and a backhand sweep the blade in opposite rotational senses, and
# unlike a travel-direction read this correctly classifies a cross-body
# backhand (off-side start, stick-side finish) by the net rotation. Resets to
# zero on a variance break, so the live stroke's rotation classifies. A purely
# radial push (straight out from the body) contributes ~0 — the ambiguous
# straight-ahead shot, which the caller's deadband defaults to forehand.
#
# Caller owns the per-frame state (prev_intent_pos, prev_blade_pos,
# prev_direction, rotation). Each tick it calls accumulate() with the current
# positions and stores back the returned values.
#
# Returns { "direction": Vector3, "reset": bool, "rotation": float }.
#   - direction: the most recent meaningful cursor-motion unit vector.
#     Caller passes this as prev_direction next tick. Vector3.ZERO means
#     "no direction yet recorded" (first frame or negligible cursor
#     motion).
#   - reset: true when the direction-variance break fired this tick — a NEW
#     swing started.
#   - rotation: accumulated signed angular sweep (radians); classify FH/BH by
#     its sign at release (ShotMechanics.is_backhand_from_swing).
static func accumulate(
		prev_intent_pos: Vector3,
		current_intent_pos: Vector3,
		prev_blade_pos: Vector3,
		current_blade_pos: Vector3,
		prev_direction: Vector3,
		max_direction_variance_deg: float,
		current_rotation: float = 0.0) -> Dictionary:
	var intent_delta := current_intent_pos - prev_intent_pos
	intent_delta.y = 0.0
	var intent_dist: float = intent_delta.length()
	if intent_dist <= 0.001:
		# Cursor not moving — no drag intent this tick. Hold direction and
		# rotation unchanged regardless of what the blade did (e.g.,
		# locomotion-induced blade motion doesn't swing the stroke without
		# intent).
		return {"direction": prev_direction, "reset": false,
				"rotation": current_rotation}

	var current_dir: Vector3 = intent_delta.normalized()
	var new_rotation: float = current_rotation
	var was_reset: bool = false
	if prev_direction != Vector3.ZERO:
		var angle_deg: float = rad_to_deg(prev_direction.angle_to(current_dir))
		if angle_deg > max_direction_variance_deg:
			new_rotation = 0.0
			was_reset = true

	# Signed angular step of the blade around the player (radians). Both
	# positions are player-relative (translation removed), so a near-zero
	# bearing (blade over the player — never happens in practice) is guarded.
	new_rotation += swing_step(prev_blade_pos, current_blade_pos)

	return {"direction": current_dir, "reset": was_reset,
			"rotation": new_rotation}


# Signed angle (radians, +/-) swept from bearing `prev_rel` to `curr_rel`
# about the vertical axis — the per-tick clockwise/counter-clockwise step.
# Pure XZ (y ignored). Zero when either bearing is degenerate.
static func swing_step(prev_rel: Vector3, curr_rel: Vector3) -> float:
	var a := Vector3(prev_rel.x, 0.0, prev_rel.z)
	var b := Vector3(curr_rel.x, 0.0, curr_rel.z)
	if a.length_squared() < 0.0001 or b.length_squared() < 0.0001:
		return 0.0
	var cross_y: float = a.z * b.x - a.x * b.z
	return atan2(cross_y, a.dot(b))
