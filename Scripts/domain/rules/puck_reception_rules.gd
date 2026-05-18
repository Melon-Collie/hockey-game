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
