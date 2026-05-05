class_name AIShotAim

# Pure function for picking a shot aim point past the opposing goalie's
# projected shadow on the net plane. Returns a world XZ point at y=0;
# callers write this to InputState.mouse_world_pos so the blade IK and
# the quick-shot release direction both follow the chosen target.
#
# Geometry: trace the shooter→goalie sightline to the net plane (z=net_z).
# The point of intersection is the goalie's "shadow" — the spot the
# goalie blocks. Treat the goalie as a circle of half-width `shadow_half`
# along the net plane; the two open arcs are [left_post, shadow_left]
# and [shadow_right, right_post]. Aim along the larger arc, biased
# toward the open POST (corner) by `corner_bias` so the shot pulls
# away from the goalie's lateral coverage rather than landing at the
# arc midpoint. corner_bias = 0 → midpoint of arc; corner_bias = 1 →
# right at the post (high risk of going wide); typical ~0.7 puts the
# aim near the post while keeping margin from going off-net.
#
# Edge cases:
#  - Shooter and goalie at the same Z (no sightline crossing the net):
#    aim at the net center (no useful goalie projection).
#  - Goalie sits past the net relative to shooter (sign mismatch on Z):
#    same — fall back to center. Should never happen in normal play
#    but the math goes funny otherwise.
#  - Goalie shadow covers the entire net: both arcs degenerate to zero
#    or negative width; pick the less-degenerate side (still picks the
#    midpoint of an empty arc, but at least it's a corner near the
#    less-covered post).


# Default corner bias — caller can override per shot type if desired.
const DEFAULT_CORNER_BIAS: float = 0.7


static func compute_open_net_aim(
		shooter: Vector3,
		goalie: Vector3,
		net_z: float,
		net_half_width: float,
		shadow_half: float,
		corner_bias: float = DEFAULT_CORNER_BIAS) -> Vector3:
	var dz: float = goalie.z - shooter.z
	var to_net_z: float = net_z - shooter.z
	# If the shooter is at goalie z OR on the wrong side, the sightline
	# math breaks down. Aim center.
	if absf(dz) < 0.001 or signf(dz) != signf(to_net_z):
		return Vector3(0.0, 0.0, net_z)
	var t: float = to_net_z / dz
	var shadow_x: float = shooter.x + t * (goalie.x - shooter.x)
	# Clamp the shadow's two edges to the net so an off-net shadow doesn't
	# count as blocking.
	var shadow_left: float = clampf(shadow_x - shadow_half, -net_half_width, net_half_width)
	var shadow_right: float = clampf(shadow_x + shadow_half, -net_half_width, net_half_width)
	var left_arc_size: float = shadow_left - (-net_half_width)
	var right_arc_size: float = net_half_width - shadow_right
	var aim_x: float
	if left_arc_size >= right_arc_size:
		# Left arc: shadow_left is goalie-side, -net_half_width is post.
		# Bias toward the post.
		aim_x = lerpf(shadow_left, -net_half_width, corner_bias)
	else:
		# Right arc: shadow_right is goalie-side, +net_half_width is post.
		aim_x = lerpf(shadow_right, net_half_width, corner_bias)
	return Vector3(aim_x, 0.0, net_z)
