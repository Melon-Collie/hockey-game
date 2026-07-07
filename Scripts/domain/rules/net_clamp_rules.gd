class_name NetClampRules

# Pure geometry for the blade's net-exclusion clamp. The blade is IK-driven, not
# physics-collided against the net, so this math is what keeps a stick out of the
# goal. Extracted from SkaterIKCoordinator so it's unit-testable headless and
# shared as the single definition of the exclusion box.
#
# The exclusion box is `half_width + buffer` wide on each side and `depth +
# buffer` deep from each goal line, up to `net_height`. A point inside escapes
# through the NEAREST side/back face — never the front mouth (you can't be pushed
# out toward center ice through the opening).
#
# Tuck-in exception: when `allow_tuck` (a carrier bringing the puck in from the
# front/side of the mouth), a point in the shallow FRONT slice — within the real
# mouth width and at most `tuck_depth` past the line — is left unclamped, so the
# blade can carry the puck across the line and the puck rides in. Only the front
# slice is opened; the deeper interior and the sides/back beyond it stay blocked,
# so a stick can't reach the puck through the back mesh. `allow_tuck` should
# already fold in the carrier-not-too-far-behind gate (see SkaterIKCoordinator).
static func clamp_out_of_net(
		point: Vector3,
		gl: float,
		half_width: float,
		buffer: float,
		depth: float,
		net_height: float,
		allow_tuck: bool,
		tuck_depth: float) -> Vector3:
	if point.y > net_height:
		return point
	var result: Vector3 = point
	var eff_depth: float = depth + buffer
	var hw: float = half_width + buffer
	# +Z net
	if result.z >= gl and result.z < gl + eff_depth:
		var local_depth: float = result.z - gl
		if absf(result.x) < hw:
			if allow_tuck and local_depth <= tuck_depth and absf(result.x) <= half_width:
				return result  # legal front-of-mouth tuck — let the puck ride in
			var d_back: float = eff_depth - local_depth
			var d_left: float = result.x + hw
			var d_right: float = hw - result.x
			if d_back <= d_left and d_back <= d_right:
				result.z = gl + eff_depth
			elif d_left <= d_right:
				result.x = -hw
			else:
				result.x = hw
	# -Z net
	elif result.z <= -gl and result.z > -gl - eff_depth:
		var local_depth: float = -gl - result.z
		if absf(result.x) < hw:
			if allow_tuck and local_depth <= tuck_depth and absf(result.x) <= half_width:
				return result
			var d_back: float = eff_depth - local_depth
			var d_left: float = result.x + hw
			var d_right: float = hw - result.x
			if d_back <= d_left and d_back <= d_right:
				result.z = -gl - eff_depth
			elif d_left <= d_right:
				result.x = -hw
			else:
				result.x = hw
	return result
