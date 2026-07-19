class_name PuckInteractionRules

# Segment-segment swept detection — tests whether the closest approach between
# the puck's path (puck_prev→puck_curr) and the blade's path (blade_prev→blade_curr)
# falls within `radius`. Handles stationary puck + fast blade swing, which the
# old puck-segment-vs-blade-point test missed when the blade passed through the
# zone entirely within a single tick.

static func check_pickup(
		puck_prev: Vector3, puck_curr: Vector3,
		blade_prev: Vector3, blade_curr: Vector3,
		radius: float) -> bool:
	return _segment_segment_dist_sq(puck_prev, puck_curr, blade_prev, blade_curr) <= radius * radius


static func check_poke(
		puck_prev: Vector3, puck_curr: Vector3,
		blade_prev: Vector3, blade_curr: Vector3,
		radius: float) -> bool:
	return _segment_segment_dist_sq(puck_prev, puck_curr, blade_prev, blade_curr) <= radius * radius


# Body-block trigger: the puck's swept path (puck_prev→puck_curr) comes within `radius` of
# the blocker's body sphere centre. `radius` folds in the sphere radius + the puck radius.
# A swept segment-vs-point test (like check_pickup/poke) so a fast puck can't tunnel through
# the torso in a single tick — the analytic replacement for the body-block Area3D sensor.
# The sphere centre carries its own height (torso for a passive block, ice-sealing for a
# shot-block crouch), so a grounded puck naturally passes UNDER a raised passive sphere.
static func check_body_block(
		puck_prev: Vector3, puck_curr: Vector3,
		body_center: Vector3, radius: float) -> bool:
	var closest: Vector3 = _closest_point_on_segment(body_center, puck_prev, puck_curr)
	return closest.distance_squared_to(body_center) <= radius * radius


# Stick-lift trigger geometry. The attacker's blade is a single point; the
# victim's stick is the hand→blade shaft segment. A lift fires when the
# attacker's blade is within `radius` of the shaft AND sits below the shaft at
# the closest point (their blade is hooked under the victim's stick).
# `under_margin` is how much lower the blade must be than the shaft contact
# point (0.0 = strictly below).
static func check_blade_under_stick(
		att_blade: Vector3,
		vic_hand: Vector3, vic_blade: Vector3,
		radius: float,
		under_margin: float = 0.0) -> bool:
	var contact: Vector3 = _closest_point_on_segment(att_blade, vic_hand, vic_blade)
	if att_blade.distance_squared_to(contact) > radius * radius:
		return false
	return att_blade.y < contact.y - under_margin


# Closest point on segment a→b to point p. Degenerates to `a` for a zero-length
# segment.
static func _closest_point_on_segment(p: Vector3, a: Vector3, b: Vector3) -> Vector3:
	var ab: Vector3 = b - a
	var ab_len_sq: float = ab.length_squared()
	if ab_len_sq <= 1e-10:
		return a
	var t: float = clampf((p - a).dot(ab) / ab_len_sq, 0.0, 1.0)
	return a + ab * t


# Minimum squared distance between two line segments (Eberly analytical solution).
# Degenerates correctly when either or both segments have zero length.
static func _segment_segment_dist_sq(
		p0: Vector3, p1: Vector3,
		q0: Vector3, q1: Vector3) -> float:
	var d1: Vector3 = p1 - p0
	var d2: Vector3 = q1 - q0
	var r: Vector3 = p0 - q0
	var a: float = d1.dot(d1)
	var e: float = d2.dot(d2)
	var f: float = d2.dot(r)
	var s: float
	var t: float
	if a <= 1e-10 and e <= 1e-10:
		return r.length_squared()
	if a <= 1e-10:
		s = 0.0
		t = clampf(f / e, 0.0, 1.0)
	else:
		var c: float = d1.dot(r)
		if e <= 1e-10:
			t = 0.0
			s = clampf(-c / a, 0.0, 1.0)
		else:
			var b: float = d1.dot(d2)
			var denom: float = a * e - b * b
			if abs(denom) > 1e-10:
				s = clampf((b * f - c * e) / denom, 0.0, 1.0)
			else:
				s = 0.0
			t = (b * s + f) / e
			if t < 0.0:
				t = 0.0
				s = clampf(-c / a, 0.0, 1.0)
			elif t > 1.0:
				t = 1.0
				s = clampf((b - c) / a, 0.0, 1.0)
	var closest_p: Vector3 = p0 + d1 * s
	var closest_q: Vector3 = q0 + d2 * t
	return (closest_p - closest_q).length_squared()
