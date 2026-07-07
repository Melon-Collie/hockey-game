class_name ShotOnNetRules

# Pure ballistic "is this shot on net?" test — the NHL scorer question behind
# a shot on goal: would the puck have gone in if the goalie hadn't stopped it?
# Projects the puck's flight (position + velocity at release, or at the latest
# redirect) onto a goal-line plane and checks the crossing point against the
# goal mouth. GameManager uses it to gate goalie-touch SOG confirmations and
# blocked-shot credits: a goalie stopping a wide cross-crease pass, or a
# defender intercepting one, is not a shot event.
#
# The projection is idealized — no ice/air friction, and a puck whose arc
# lands short of the line is assumed to slide the rest of the way at ice
# level. MARGIN widens the mouth so borderline reads round toward counting the
# shot; slightly over-crediting beats swallowing real saves.

const MARGIN: float = 0.15


# `goal_line_z` carries the end in its sign (± GameRules.GOAL_LINE_Z); the
# goal mouth is centred on x = 0. False when the puck is moving parallel to or
# away from that line.
static func is_on_net(puck_pos: Vector3, puck_vel: Vector3, goal_line_z: float) -> bool:
	if absf(puck_vel.z) < 0.001:
		return false
	# Must approach the mouth from the FRONT: shots on the +Z goal travel +Z.
	# Without this, a puck behind the goal line (wraparound / centering feed
	# from behind the net) crossing the plane inside the mouth's x-range would
	# read as on net — it can only enter through the back of the net.
	if signf(puck_vel.z) != signf(goal_line_z):
		return false
	var t: float = (goal_line_z - puck_pos.z) / puck_vel.z
	if t <= 0.0:
		return false  # already past the line
	var x: float = puck_pos.x + puck_vel.x * t
	if absf(x) > GameRules.NET_HALF_WIDTH + MARGIN:
		return false
	var y: float = puck_pos.y + puck_vel.y * t \
			- 0.5 * GameRules.GRAVITY_M_S2 * t * t
	if y < 0.0:
		y = 0.0  # arc lands short — the puck slides the rest of the way
	return y <= GameRules.NET_HEIGHT + MARGIN
