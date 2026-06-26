class_name PuckReceptionRules

# Pure decision: when a loose puck overlaps a blade, does the skater receive it
# (set as carrier) or deflect it (bounce off via PuckCollisionRules)?
#
#   pickup_max_speed:    absolute puck speed below which pickup always succeeds
#   deflect_min_speed:   speed threshold for a poorly-angled blade. Set above
#                        charged-pass speed (~19 m/s) so any pass is receivable
#                        at ANY blade angle.
#   alignment_bonus:     extra m/s tolerated when the blade face is square to the
#                        incoming puck — the only thing that lets a blade corral a
#                        hard shot, and it's purely a function of where the blade
#                        points at contact.
#
# Reception is REACTIVE, not preemptive: it reads the puck's absolute speed and
# the blade angle at contact, nothing else. There is deliberately no cushion /
# "give with the puck" term — a moving blade is treated no differently from a
# static one — because timing a backswing into an incoming pass was fiddly and
# unintuitive (you had to pre-load it before the puck arrived). Catching a hard
# shot is now about squaring the blade, not winding up a cushion.
static func should_receive(
		puck_velocity: Vector3,
		blade_face_normal: Vector3,
		pickup_max_speed: float,
		deflect_min_speed: float,
		alignment_bonus: float) -> bool:
	var puck_speed: float = puck_velocity.length()
	if puck_speed <= pickup_max_speed:
		return true
	# How head-on the approach is: -puck_dir points from puck toward the blade;
	# dot with the face normal = squareness. Negative (puck moving away from the
	# face) clamps to 0, no bonus. puck_speed > pickup_max_speed here, so the
	# normalize is safe.
	var alignment: float = maxf(0.0, -puck_velocity.normalized().dot(blade_face_normal))
	var threshold: float = deflect_min_speed + alignment_bonus * alignment
	return puck_speed < threshold


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
