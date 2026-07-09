class_name NetClampRules

# Pure geometry for the blade's net-exclusion clamp. The blade is IK-driven, not
# physics-collided against the net, so this math is what makes the net behave
# like a SOLID OBJECT for the stick: five solid faces (back, both sides, top,
# and the ice) with only the FRONT face — the mouth — open.
#
# A blade contact inside the goal box escapes through the nearest SOLID face
# (never the front). The one exception is a legal front entry: if the swept
# segment `prev -> point` came in through the mouth opening, the contact is left
# unclamped so the puck can be carried across the line (wraparounds / jams). This
# is a property of the blade's PATH, not the skater's position — a stick behind
# the net can't reach the puck in because the back mesh is solid, exactly as it
# would be physically, no matter how close the body is. Front entry is gated by
# `allow_front` (the carrier case); follow-through / non-carry calls pass false
# and get the pure exclusion, unchanged.
#
# The box is `half_width + buffer` wide and `depth + buffer` deep from each goal
# line, up to `net_height`.
static func clamp_out_of_net(
		point: Vector3,
		prev: Vector3,
		gl: float,
		half_width: float,
		buffer: float,
		depth: float,
		net_height: float,
		allow_front: bool) -> Vector3:
	if point.y > net_height:
		return point
	var eff_depth: float = depth + buffer
	var hw: float = half_width + buffer
	# +Z net: front plane at z = gl, interior extends toward +z.
	if point.z >= gl and point.z < gl + eff_depth and absf(point.x) < hw:
		return _resolve(point, prev, gl, hw, eff_depth, net_height, allow_front, 1.0)
	# -Z net: front plane at z = -gl, interior extends toward -z.
	if point.z <= -gl and point.z > -gl - eff_depth and absf(point.x) < hw:
		return _resolve(point, prev, gl, hw, eff_depth, net_height, allow_front, -1.0)
	return point


# `point` is known inside the box. Leave it if the blade entered through the
# front mouth; otherwise push it out through the nearest solid face.
static func _resolve(
		point: Vector3,
		prev: Vector3,
		gl: float,
		hw: float,
		eff_depth: float,
		net_height: float,
		allow_front: bool,
		facing: float) -> Vector3:
	var front_z: float = gl * facing
	if allow_front and _entered_via_front(prev, point, front_z, hw, eff_depth, net_height, facing):
		return point
	var local_depth: float = (point.z - front_z) * facing  # (0, eff_depth) inside
	var d_back: float = eff_depth - local_depth
	var d_left: float = point.x + hw
	var d_right: float = hw - point.x
	var result: Vector3 = point
	if d_back <= d_left and d_back <= d_right:
		result.z = front_z + facing * eff_depth
	elif d_left <= d_right:
		result.x = -hw
	else:
		result.x = hw
	return result


# Whether the swept segment `prev -> point` (point inside the box) entered
# through the front mouth: either prev was already inside (it entered on an
# earlier tick — the clamp runs every tick, so prev is always a legal position),
# or the segment crosses the front plane from the front side at a point within
# the opening. Coming from a side or the back returns false.
static func _entered_via_front(
		prev: Vector3,
		point: Vector3,
		front_z: float,
		hw: float,
		eff_depth: float,
		net_height: float,
		facing: float) -> bool:
	var prev_depth: float = (prev.z - front_z) * facing
	if prev_depth > 0.0 and prev_depth < eff_depth \
			and absf(prev.x) < hw and prev.y <= net_height:
		return true  # was inside last tick — inductively a legal (front) occupant
	if prev_depth <= 0.0:
		# Front side: does the segment cross the mouth plane within the opening?
		var dz: float = point.z - prev.z
		if absf(dz) < 0.0000001:
			return false
		var t: float = (front_z - prev.z) / dz
		if t < 0.0 or t > 1.0:
			return false
		var xc: float = prev.x + (point.x - prev.x) * t
		var yc: float = prev.y + (point.y - prev.y) * t
		return absf(xc) < hw and yc >= 0.0 and yc <= net_height
	return false
