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
# from the arc MIDPOINT toward the open POST by `corner_bias`.
#
# Goalie momentum: when `goalie_velocity_x` is provided, project the
# shadow forward by velocity × SHADOW_VELOCITY_LOOKAHEAD_S before
# picking the arc. Models the hockey "shoot back across the grain"
# pattern — a goalie sliding right will drift further right by the
# time the shot arrives, leaving the LEFT arc disproportionately
# open. The arc-size comparison naturally picks the recovery side.
# Default 0.0 keeps legacy behavior for callers without goalie
# velocity in scope (e.g. the lane-clear segment check in
# action_scoring.gd, where the small aim divergence doesn't matter).
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
# 0 = legacy arc-midpoint behavior, 1 = aim at the post.
const DEFAULT_CORNER_BIAS: float = 0.5

# How far ahead to project the goalie's shadow when goalie_velocity_x
# is supplied. ~0.2 s covers typical puck flight time from slot to
# net (≈ 5 m / 30 m/s = 0.17 s) plus a small reversal-cost buffer.
# Raise toward 0.3 if bots aren't aiming aggressively into the
# recovery side; lower toward 0.1 if shots go too wide of the
# moving goalie.
const SHADOW_VELOCITY_LOOKAHEAD_S: float = 0.2


static func compute_open_net_aim(
		shooter: Vector3,
		goalie: Vector3,
		net_z: float,
		net_half_width: float,
		shadow_half: float,
		corner_bias: float = DEFAULT_CORNER_BIAS,
		goalie_velocity_x: float = 0.0) -> Vector3:
	var dz: float = goalie.z - shooter.z
	var to_net_z: float = net_z - shooter.z
	# If the shooter is at goalie z OR on the wrong side, the sightline
	# math breaks down. Aim center.
	if absf(dz) < 0.001 or signf(dz) != signf(to_net_z):
		return Vector3(0.0, 0.0, net_z)
	var t: float = to_net_z / dz
	var shadow_x: float = shooter.x + t * (goalie.x - shooter.x)
	# Goalie momentum bias: a moving goalie drifts further along its
	# velocity by the time the puck reaches the net plane. Shift the
	# shadow by velocity × lookahead so the open-arc comparison picks
	# the side the goalie has to REVERSE to cover.
	shadow_x += goalie_velocity_x * SHADOW_VELOCITY_LOOKAHEAD_S
	# Clamp the shadow's two edges to the net so an off-net shadow doesn't
	# count as blocking.
	var shadow_left: float = clampf(shadow_x - shadow_half, -net_half_width, net_half_width)
	var shadow_right: float = clampf(shadow_x + shadow_half, -net_half_width, net_half_width)
	var left_arc_size: float = shadow_left - (-net_half_width)
	var right_arc_size: float = net_half_width - shadow_right
	var aim_x: float
	if left_arc_size >= right_arc_size:
		# Left arc: midpoint is between shadow_left (goalie side) and
		# -net_half_width (post). Lerp from midpoint toward the post.
		var midpoint: float = (-net_half_width + shadow_left) * 0.5
		aim_x = lerpf(midpoint, -net_half_width, corner_bias)
	else:
		# Right arc: midpoint is between shadow_right and +net_half_width.
		var midpoint: float = (shadow_right + net_half_width) * 0.5
		aim_x = lerpf(midpoint, net_half_width, corner_bias)
	return Vector3(aim_x, 0.0, net_z)
