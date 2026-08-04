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
# "Directed at the net" — the wider Corsi/Fenwick mouth. A shot attempt is a puck
# directed AT the net, which includes misses: Corsi counts shots that go wide or
# hit the post, not just those that would go in. These margins widen is_on_net's
# mouth so a shot missing within ~1.2 m of a post (or sailing under ~0.8 m over
# the bar) still classifies as an attempt. They're hand-set *reporting* thresholds
# (the same fuzzy line a human scorer draws for "was that even a shot?"), not
# evaluator terms — tune in playtest. The vertical margin is smaller so a puck
# flipped well over the glass reads as a clear/dump, not a shot.
const DIRECTED_LATERAL_MARGIN: float = 1.2
const DIRECTED_VERTICAL_MARGIN: float = 0.8


# `goal_line_z` carries the end in its sign (± GameRules.GOAL_LINE_Z); the
# goal mouth is centred on x = 0. False when the puck is moving parallel to or
# away from that line.
static func is_on_net(puck_pos: Vector3, puck_vel: Vector3, goal_line_z: float) -> bool:
	return _crosses_mouth(puck_pos, puck_vel, goal_line_z, MARGIN, MARGIN)


# The Corsi/Fenwick gate: is this release a SHOT (directed at the net) rather than
# a pass or a clear? Same ballistic projection as is_on_net, widened by the
# DIRECTED_* margins so misses still count. A pass to the wing, a cross-crease
# feed (moving parallel to the goal line), or a dump-in projects outside the wide
# mouth and reads false. A backdoor feed aimed straight at a teammate in the
# crease can still read true here (it IS aimed at the net) — the "received by a
# teammate" check upstream (ShotOnGoalTracker) reclassifies that as a pass.
static func is_directed_at_net(puck_pos: Vector3, puck_vel: Vector3, goal_line_z: float) -> bool:
	return _crosses_mouth(puck_pos, puck_vel, goal_line_z,
			DIRECTED_LATERAL_MARGIN, DIRECTED_VERTICAL_MARGIN)


# Whether a release came from the shooter's OWN half, which disqualifies it as a
# shot event outright — not an attempt, not a shot on goal, not a blocked shot.
#
# The ballistic tests above cannot refuse these on their own: ICE_FRICTION 0.05
# gives PUCK_ICE_DECEL_M_S2 0.49, so a 15 m/s release coasts ~230 m against a
# 59.7 m rink and a puck from the far end really does reach the mouth. What keeps
# it rare is angular — ±2.115 m at ~51 m is a ±2.3° window — but an errant stretch
# pass hits it about once a game, and it plotted a point-blank dot beside the
# passer's OWN crease on the shot map.
#
# The centre red line is z = 0 by construction (rink centred on the origin, goal
# lines at ±GameRules.GOAL_LINE_Z), so "own half" reduces to the release sitting
# on the opposite side of centre from the net being shot at — the same convention
# InfractionRules.check_icing uses for the icing release. A release exactly ON the
# line is legal (the product is 0, not negative).
#
# Safe to make absolute because there is no goalie-pull mechanic: goalies spawn
# for every match, so the empty-net shot from deep that a real scorer WOULD credit
# cannot occur. Revisit this if a pulled goalie ever ships.
static func is_release_in_own_half(release_z: float, goal_line_z: float) -> bool:
	return release_z * goal_line_z < 0.0


static func _crosses_mouth(puck_pos: Vector3, puck_vel: Vector3, goal_line_z: float,
		lateral_margin: float, vertical_margin: float) -> bool:
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
	if absf(x) > GameRules.NET_HALF_WIDTH + lateral_margin:
		return false
	var y: float = puck_pos.y + puck_vel.y * t \
			- 0.5 * GameRules.GRAVITY_M_S2 * t * t
	if y < 0.0:
		y = 0.0  # arc lands short — the puck slides the rest of the way
	return y <= GameRules.NET_HEIGHT + vertical_margin
