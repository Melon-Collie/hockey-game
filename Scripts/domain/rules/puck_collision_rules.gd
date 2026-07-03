class_name PuckCollisionRules

# Pure math for puck interactions. The Puck node computes contact points and
# velocities from physics state, then calls these to produce the resulting
# velocity. No engine or signal dependencies here — fully unit-testable.

# Domain rule: an opponent can always attempt a poke check; teammates cannot.
static func can_poke_check(carrier_team_id: int, checker_team_id: int) -> bool:
	return carrier_team_id != checker_team_id

# Billiard-style reflection off the blade. contact_normal is the blade-to-puck
# unit vector at overlap time. Returns new horizontal velocity (no Y component).
# Drives BOTH the natural too-fast-to-catch deflect and the deliberate redirect
# (hold LMB without the puck) — one model, so they always feel identical.
#   deflect_blend ∈ [0, 1]: 0 = pure pass-through, 1 = pure reflection
# Two effects ease with puck speed via one shared 0→1 "hardness" factor
# (speed / speed_ref, clamped) — a soft puck is steerable, a hard puck glances:
#   speed_retain → speed_retain_min: energy retained. Hard pucks shed more so
#       deflections stop pinballing. speed_retain_min < 0 disables the falloff
#       (flat speed_retain).
#   max_deflect_deg → max_deflect_deg_min: cap on how far the puck may be turned
#       off its incoming line. Soft pucks get a sharp, steerable redirect; hard
#       pucks only a shallow tip (high momentum can't be sharply redirected by a
#       passive blade). The cap also tames the wild caroms a near-perpendicular /
#       jittery blade normal produces at higher blend. max_deflect_deg_min < 0
#       disables the speed falloff (flat max_deflect_deg); max_deflect_deg >= 180
#       disables the clamp entirely.
static func deflect_velocity(
		incoming_velocity: Vector3,
		contact_normal: Vector3,
		deflect_blend: float,
		speed_retain: float,
		speed_retain_min: float = -1.0,
		max_deflect_deg: float = 180.0,
		max_deflect_deg_min: float = -1.0,
		speed_ref: float = 0.0) -> Vector3:
	var horiz := Vector3(incoming_velocity.x, 0.0, incoming_velocity.z)
	var speed: float = incoming_velocity.length()
	if horiz.length() < 0.0001:
		return Vector3.ZERO
	# Shared 0→1 "how hard is this puck" factor for both speed-dependent falloffs.
	var hard: float = clampf(speed / speed_ref, 0.0, 1.0) if speed_ref > 0.0001 else 0.0
	var in_dir: Vector3 = horiz.normalized()
	var reflected: Vector3 = horiz - 2.0 * horiz.dot(contact_normal) * contact_normal
	var new_dir: Vector3 = in_dir.lerp(reflected.normalized(), deflect_blend).normalized()
	var cap: float = max_deflect_deg
	if max_deflect_deg_min >= 0.0:
		cap = lerpf(max_deflect_deg, max_deflect_deg_min, hard)
	if cap < 180.0:
		var turn: float = in_dir.angle_to(new_dir)
		if turn > deg_to_rad(cap):
			var axis: Vector3 = in_dir.cross(new_dir)
			if axis.length() > 0.0001:
				new_dir = in_dir.rotated(axis.normalized(), deg_to_rad(cap))
			else:
				new_dir = in_dir
	var retain: float = speed_retain
	if speed_retain_min >= 0.0:
		retain = lerpf(speed_retain, speed_retain_min, hard)
	return new_dir * speed * retain

# Adds upward Y component to a horizontal deflection direction. Used when the
# deflecting skater is elevated.
static func apply_deflection_elevation(horizontal_dir: Vector3, elevation_angle_deg: float) -> Vector3:
	var rad: float = deg_to_rad(elevation_angle_deg)
	return Vector3(
		horizontal_dir.x * cos(rad),
		sin(rad),
		horizontal_dir.z * cos(rad)
	).normalized()

# Loose puck bouncing off a skater's body (passive body-block). Reflect +
# dampen. If the reflection collapses to zero, fall back to the contact normal.
static func body_block_velocity(
		incoming_velocity: Vector3,
		contact_normal: Vector3,
		dampen: float) -> Vector3:
	var horiz := Vector3(incoming_velocity.x, 0.0, incoming_velocity.z)
	var reflected: Vector3 = horiz - 2.0 * horiz.dot(contact_normal) * contact_normal
	if reflected.length() < 0.001:
		reflected = contact_normal
	return reflected.normalized() * horiz.length() * dampen

# Body-check strip: transfers the checker's horizontal momentum into the puck,
# scaled by the strip speed. Trivial but extracted for consistency.
static func body_check_strip_velocity(hit_direction: Vector3, puck_speed: float) -> Vector3:
	return hit_direction * puck_speed

# Poke-check strip velocity — a stick-on-stick momentum contest. The checker's
# blade sweep plus a fraction of the carrier's (carrier_vel_blend) form the blended
# contest momentum: its heading AIMS the loose puck and its MAGNITUDE PACES it — a
# hard poke squirts the puck away fast, a soft one barely nudges it, clamped to
# [min_speed, max_speed]. When the checker's blade is near-still it's a positional
# strip with no sweep momentum, so the puck is pushed off the carrier
# (carrier_pos - checker_pos) at min_speed. If both collapse to zero the
# caller-supplied fallback_direction keeps the rule deterministic under test.
static func poke_strip_velocity(
		checker_blade_vel: Vector3,
		carrier_blade_vel: Vector3,
		carrier_pos: Vector3,
		checker_pos: Vector3,
		carrier_vel_blend: float,
		min_speed: float,
		max_speed: float,
		fallback_direction: Vector3) -> Vector3:
	var checker_horiz := Vector3(checker_blade_vel.x, 0.0, checker_blade_vel.z)
	var carrier_horiz := Vector3(carrier_blade_vel.x, 0.0, carrier_blade_vel.z)
	var strip_dir: Vector3
	var speed: float
	if checker_horiz.length() > 0.5:
		# Active poke: heading and pace both come from the blended contest momentum.
		var blended: Vector3 = checker_horiz + carrier_horiz * carrier_vel_blend
		strip_dir = blended
		speed = clampf(blended.length(), min_speed, max_speed)
	else:
		# Positional stick-on-puck: no sweep to pace it, so floor speed, pushed away.
		strip_dir = Vector3(carrier_pos.x - checker_pos.x, 0.0, carrier_pos.z - checker_pos.z)
		speed = min_speed
	strip_dir.y = 0.0
	if strip_dir.length() > 0.001:
		strip_dir = strip_dir.normalized()
	else:
		strip_dir = fallback_direction.normalized()
	return strip_dir * speed
