class_name PuckCollisionRules

# Pure math for puck interactions. The Puck node computes contact points and
# velocities from physics state, then calls these to produce the resulting
# velocity. No engine or signal dependencies here — fully unit-testable.

# Domain rule: an opponent can always attempt a poke check; teammates cannot.
static func can_poke_check(carrier_team_id: int, checker_team_id: int) -> bool:
	return carrier_team_id != checker_team_id

# Passive-blade deflection via a NORMAL/TANGENTIAL decomposition of the incoming
# velocity against the blade face. contact_normal is the blade face normal
# (unit, points against the incoming puck). Returns new horizontal velocity (no
# Y). Drives BOTH the natural too-fast-to-catch deflect and the deliberate
# redirect (hold LMB without the puck) — one model, so they always feel identical.
#
# The incoming velocity is split into the component INTO the face (normal) and the
# component ALONG the face (tangential). The normal part rebounds with restitution
# `e`; the tangential part is kept by `tangential_retain`. Two real outcomes fall
# out of this ONE model, no hand-drawn curve:
#   - a SQUARE hit (nearly all normal) off a hard puck → low e → the puck dies in
#     front (the "bobble": knocked down, not held);
#   - a GLANCING hit (mostly tangential) → the glance survives → the puck keeps its
#     pace and only its LINE changes (a true tip / redirect).
# This is why it needs no angle cap: the only way to reverse the puck is a square
# hit, and a square hard hit is killed by the low restitution — there is no fast
# carom to clamp.
#
# `e` eases from normal_restitution (soft/slow puck) toward normal_restitution_min
# (hard puck) as speed climbs to speed_ref — a hard puck deadens more head-on, so
# a squared blade smothers a slapper into a bobble instead of caroming it.
# normal_restitution_min < 0 disables the falloff (flat e). tangential_retain is
# flat: a glance keeps its pace regardless of speed (that IS the redirect).
static func deflect_velocity(
		incoming_velocity: Vector3,
		contact_normal: Vector3,
		normal_restitution: float,
		normal_restitution_min: float = -1.0,
		tangential_retain: float = 1.0,
		speed_ref: float = 0.0) -> Vector3:
	var horiz := Vector3(incoming_velocity.x, 0.0, incoming_velocity.z)
	var speed: float = horiz.length()
	if speed < 0.0001:
		return Vector3.ZERO
	var n := Vector3(contact_normal.x, 0.0, contact_normal.z)
	if n.length() < 0.0001:
		return horiz  # degenerate normal: nothing to reflect against, pass through
	n = n.normalized()
	# Into-face component. horiz·n is negative for an approaching puck (n points
	# against travel), so v_normal points into the face; flipping it by -e below
	# sends the rebounded part back out along +n.
	var v_normal: Vector3 = horiz.dot(n) * n
	var v_tangent: Vector3 = horiz - v_normal
	var hard: float = clampf(speed / speed_ref, 0.0, 1.0) if speed_ref > 0.0001 else 0.0
	var e: float = normal_restitution
	if normal_restitution_min >= 0.0:
		e = lerpf(normal_restitution, normal_restitution_min, hard)
	return v_tangent * tangential_retain - v_normal * e

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

# Body-check strip: the puck comes loose along the hit line, but a HARD hit jars it
# nearly dead at the point of contact rather than launching it downice with the
# victim. `trickle_speed` is the soft-strip pace; as `intensity` (0..1 hit hardness)
# rises the forward carry falls toward `loose_speed`, so a squared-up check drops
# the puck at the hitter's feet — they drive through the check (reduced attacker
# restitution) and skate onto it, instead of the puck flying off with the body.
static func body_check_strip_velocity(
		hit_direction: Vector3,
		trickle_speed: float,
		loose_speed: float,
		intensity: float) -> Vector3:
	var speed: float = lerpf(trickle_speed, loose_speed, clampf(intensity, 0.0, 1.0))
	return hit_direction * speed

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


# Contested pickup: two blades reach the same loose puck at once. Neither player
# ever gets possession off this path — the puck squirts free — but its HEADING is
# biased toward the stronger blade: the exit is the vector sum of the two blade
# momenta, so a harder/faster sweep dominates the sum and the puck goes that
# player's way (blade speed already reflects Hands, so no attribute term is needed
# here). Speed is that combined momentum, clamped to [min_speed, max_speed]. When
# the two blades roughly cancel (net below deadlock_threshold — a true 50/50), the
# puck instead pops out PERPENDICULAR to the line between the blade contact points
# (the "pinched seed" behavior) at deadlock_speed; the caller supplies the ± side
# and a degenerate fallback direction so the rule stays deterministic under test.
static func contested_pickup_velocity(
		blade_a_vel: Vector3, blade_b_vel: Vector3,
		blade_a_pos: Vector3, blade_b_pos: Vector3,
		min_speed: float, max_speed: float,
		deadlock_speed: float, deadlock_threshold: float,
		perp_sign: float, fallback_dir: Vector3) -> Vector3:
	var net := Vector3(blade_a_vel.x + blade_b_vel.x, 0.0, blade_a_vel.z + blade_b_vel.z)
	if net.length() > deadlock_threshold:
		return net.normalized() * clampf(net.length(), min_speed, max_speed)
	# Deadlock — blades cancel. Pop perpendicular to the blade-to-blade line.
	var along := Vector3(blade_a_pos.x - blade_b_pos.x, 0.0, blade_a_pos.z - blade_b_pos.z)
	if along.length() < 0.001:
		along = Vector3(fallback_dir.x, 0.0, fallback_dir.z)
		if along.length() < 0.001:
			along = Vector3(1.0, 0.0, 0.0)
	var perp := Vector3(-along.z, 0.0, along.x).normalized()
	return perp * perp_sign * deadlock_speed
