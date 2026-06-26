class_name PuckReceptionRules

# Pure decision: when a loose puck overlaps a blade, does the skater receive it
# (set as carrier) or deflect it (bounce off via PuckCollisionRules)? Speed
# alone is too coarse — a well-angled blade or a stick "giving" with the puck
# (cushion) should let a player handle a harder pass than a stationary,
# poorly-oriented blade.
#
#   pickup_max_speed:    absolute puck speed below which pickup always succeeds
#   deflect_min_speed:   baseline relative-speed threshold (puck vs blade)
#   alignment_bonus:     extra m/s of relative speed tolerated when the blade
#                        face is pointed directly into the incoming puck
#
# Cushion (blade moving with the puck) is captured implicitly by using the
# puck-relative-to-blade velocity for both the threshold check and the
# alignment dot product.
static func should_receive(
		puck_velocity: Vector3,
		blade_velocity: Vector3,
		blade_face_normal: Vector3,
		pickup_max_speed: float,
		deflect_min_speed: float,
		alignment_bonus: float) -> bool:
	if puck_velocity.length() <= pickup_max_speed:
		return true
	var rel_vel: Vector3 = puck_velocity - blade_velocity
	var rel_speed: float = rel_vel.length()
	var alignment: float = 0.0
	if rel_speed > 0.001:
		# -rel_vel points from puck toward blade; dot with face normal = how
		# head-on the approach is. Negative means the puck is moving away from
		# the blade face — no bonus.
		alignment = maxf(0.0, -rel_vel.normalized().dot(blade_face_normal))
	var threshold: float = deflect_min_speed + alignment_bonus * alignment
	return rel_speed < threshold


# Pure: horizontal unit vector perpendicular to the stick shaft (top_hand →
# blade_contact), picking the face that opposes reference_velocity (i.e. faces
# an incoming puck). `fallback_stick_dir` is used as the shaft direction when the
# hand and blade are coincident (degenerate). Shared by Skater.get_blade_face_normal
# (live geometry) and the lag-comp pickup resolver (rewound snapshot geometry) so
# the catch-vs-deflect decision judges against ONE definition of "blade face".
static func blade_face_normal(
		blade_contact: Vector3,
		top_hand: Vector3,
		reference_velocity: Vector3,
		fallback_stick_dir: Vector3) -> Vector3:
	var stick_horiz: Vector3 = blade_contact - top_hand
	stick_horiz.y = 0.0
	if stick_horiz.length() < 0.001:
		stick_horiz = fallback_stick_dir
	stick_horiz = stick_horiz.normalized()
	var face_normal := Vector3(-stick_horiz.z, 0.0, stick_horiz.x)
	if face_normal.dot(reference_velocity) > 0.0:
		face_normal = -face_normal
	return face_normal


# Pure on-ice/off-ice gate: a blade only interacts with pucks on its own
# vertical plane. A lifted blade (off the ice) handles airborne pucks; a
# grounded blade handles grounded pucks. This is what lets a saucer pass fly
# over a stationary, grounded blade instead of being corralled out of the air,
# and is what limits a lifted blade to tipping airborne pucks.
static func blade_can_interact(blade_up: bool, puck_airborne: bool) -> bool:
	return blade_up == puck_airborne
