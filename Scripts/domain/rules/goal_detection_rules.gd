class_name GoalDetectionRules

# Pure, CENTER-based goal-line crossing test for live gameplay. Replaces the old
# Area3D `body_entered` sensor on HockeyGoal, which awarded false goals when a
# puck grazed a post or slid into the side netting.
#
# Why the sensor leaked
# ---------------------
# An Area3D fires on collision-SHAPE overlap (any part of the puck touching) and
# is a solid VOLUME enterable from ANY face. The puck's collision radius (0.065 m)
# is large relative to the goal mouth, so:
#   * A puck hugging the inside face of a post sits at |x| ~ 0.82 m — exactly the
#     old sensor's x-overlap boundary — so any forward drift read as a goal
#     ("weird stuff around the post").
#   * A puck entering the sensor box from a SIDE or BACK face (a scramble beside
#     the net, a puck squirting in from the side netting) tripped the same
#     `vel.z * facing > 0` gate and scored ("sliding it into the side of the net").
# The old sensor never accounted for the puck's own radius at all.
#
# The NHL rule (78.1): the ENTIRE puck must COMPLETELY cross the goal line,
# between the posts and below the crossbar. We model the puck by its center and
# require that center to cross the goal-line plane travelling INTO the net, with
# the crossing point inside a mouth tightened by the puck's own extent (so the
# whole disc is within the posts / under the bar). Because we work from the swept
# segment prev_center -> curr_center, a fast shot that clears the full goal depth
# in a single 120 Hz tick is caught reliably — the exact case an Area3D can
# tunnel straight through.
#
# `facing` is +1 for the +Z net, -1 for the -Z net (matches HockeyGoal.facing).
# `half_width` / `net_height` are the INNER mouth bounds (post inner face, under
# the crossbar) — pass POST_HALF_WIDTH - POST_RADIUS and NET_HEIGHT - POST_RADIUS.
# `puck_radius` is the disc's horizontal extent; `puck_half_height` its vertical
# extent (the puck is angular-locked flat, so these differ — 0.065 vs 0.0175).
static func crossed_into_net(
		prev_center: Vector3,
		curr_center: Vector3,
		goal_z: float,
		facing: float,
		half_width: float,
		net_height: float,
		puck_radius: float,
		puck_half_height: float) -> bool:
	# Signed depth past the goal line, positive = deeper into the net.
	var prev_depth: float = (prev_center.z - goal_z) * facing
	var curr_depth: float = (curr_center.z - goal_z) * facing
	# Require the WHOLE puck to finish crossing THIS tick: last tick it was not
	# yet fully across (center within a radius of the line, or in front), and now
	# it is (center at least a radius past the line). This single edge condition
	# also encodes DIRECTION — a puck pulled back out, or fed across from behind
	# the net, crosses the other way and never satisfies it.
	if prev_depth >= puck_radius:
		return false  # already fully in the net last tick — not a fresh crossing
	if curr_depth < puck_radius:
		return false  # not fully across the line yet
	# Interpolate where the center pierces the goal-line plane (depth == 0), so a
	# puck curling in is judged at the spot it actually crossed. If it was already
	# a hair past the line last tick, t clamps to prev_center — close enough at
	# 120 Hz for these slow-dribble cases.
	var span: float = curr_depth - prev_depth
	var t: float = 0.0
	if span > 0.0:
		t = clampf((0.0 - prev_depth) / span, 0.0, 1.0)
	var cross_x: float = prev_center.x + (curr_center.x - prev_center.x) * t
	var cross_y: float = prev_center.y + (curr_center.y - prev_center.y) * t
	# Mouth tightened by the puck's own extent: the whole disc must be inside the
	# posts and under the bar. A puck ringing a post crosses (if it crosses at
	# all) outside this tightened mouth and is correctly rejected.
	if absf(cross_x) > half_width - puck_radius:
		return false
	if cross_y > net_height - puck_half_height:
		return false
	if cross_y < 0.0:
		return false
	return true
