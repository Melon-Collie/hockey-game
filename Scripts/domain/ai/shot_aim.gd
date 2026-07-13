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
#
# 0.3 keeps the aim point away from the post (a third of the way from
# arc midpoint toward the post). Combined with the per-release aim error,
# wind-up offset compensation residual, and aim drift during the wrister
# charge, anything closer to the post (≥ 0.5) produced shots that sailed
# wide of the net entirely. Bias under 0.3 sacrifices corner placement
# without enough accuracy gain to justify.
const DEFAULT_CORNER_BIAS: float = 0.3

# How far ahead to project the goalie's shadow when goalie_velocity_x
# is supplied. Goalie t_push_speed ≈ 6 m/s; at 0.2 s the shadow can
# drift 1.2 m, larger than the net half-width — the aim then biases
# fully into the recovery arc and any underestimate of the goalie's
# motion (e.g., goalie brakes mid-slide) sends the shot wide of the
# post. 0.12 s × 6 m/s = 0.72 m of drift, enough to bias toward the
# recovery side without inverting the aim entirely.
const SHADOW_VELOCITY_LOOKAHEAD_S: float = 0.12


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
	# Post clearance: never aim outside the line the puck's CENTER can cross
	# without clipping the pipe (post radius + puck radius inside the post
	# centerline — GameRules.NET_ENTRY_HALF_WIDTH's derivation). A degenerate
	# arc lerps the aim onto the post itself, and with zero aim error the bot
	# rides that exact line into the iron every time.
	var entry_max: float = net_half_width \
			- GameRules.NET_POST_RADIUS - GameRules.PUCK_COLLISION_RADIUS
	return Vector3(clampf(aim_x, -entry_max, entry_max), 0.0, net_z)
