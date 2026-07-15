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
# `half_width` / `net_height` are the post-centerline / crossbar-centerline
# geometry (POST_HALF_WIDTH, NET_HEIGHT); `post_radius` and the puck extents
# tighten them to the whole-disc clear opening inside `point_in_mouth`. The puck
# is angular-locked flat, so its horizontal reach (puck_radius) differs from its
# vertical reach (puck_half_height) — 0.065 vs 0.0175. `net_depth` is the
# goal-line-to-back-frame depth (BASE_DEPTH), bounding the cavity fallback below.
static func crossed_into_net(
		prev_center: Vector3,
		curr_center: Vector3,
		goal_z: float,
		facing: float,
		half_width: float,
		net_height: float,
		post_radius: float,
		puck_radius: float,
		puck_half_height: float,
		net_depth: float) -> bool:
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
	if point_in_mouth(cross_x, cross_y, half_width, net_height,
			post_radius, puck_radius, puck_half_height):
		return true
	# Bent-path fallback: a post-and-in / bar-down entry is deflected by the
	# pipe mid-flight, so the STRAIGHT prev -> curr segment can pierce the
	# goal-line plane in the pipe band (outside the tightened mouth) even
	# though the real, bent path went in through the opening. If the puck's
	# center finished this tick fully inside the net CAVITY, the only
	# continuous route there from in front of the line is through the mouth —
	# the posts, bar, side/top netting and back mesh are all solid — so award
	# the goal on the endpoint. Without this, a deflected entry was rejected
	# once and then permanently locked out by the prev_depth freshness guard:
	# the puck sat visibly in the net with no goal.
	#
	# But this endpoint-only test trusts that "the only route into the cavity is
	# through the mouth" — true for a free puck against solid panels, but the
	# STRAIGHT segment we sample can straddle those panels: a puck slid in from
	# BESIDE the net (a side-netting scramble), a sharp-angle feed threaded from
	# behind the goal line, or a bot's pin/carry curled past a post can pierce
	# the plane far outside the frame yet land its endpoint inside the cavity —
	# a phantom "in from the back/side" goal (usually on a bot, whose angles are
	# exact). A genuine post-and-in / bar-down, by contrast, is in CONTACT with
	# the pipe as it crosses, so its crossing point sits within the pipe band —
	# no farther out than the post/bar outer face plus the puck's own reach.
	# Gate the fallback on that: a crossing beyond the band never touched the
	# frame, so it came from outside a solid face and is not a goal.
	var pipe_x_limit: float = half_width + post_radius + puck_radius
	var pipe_y_top: float = net_height + post_radius + puck_half_height
	var pipe_y_bottom: float = -(post_radius + puck_half_height)
	if absf(cross_x) > pipe_x_limit or cross_y > pipe_y_top or cross_y < pipe_y_bottom:
		return false
	return _center_inside_cavity(curr_center, curr_depth, half_width,
			net_height, post_radius, puck_radius, puck_half_height, net_depth)


# Whether a puck CENTER (already known to be >= puck_radius past the line —
# `depth` is the caller's signed depth) sits unambiguously INSIDE the net
# cavity: clear of the side panels (which stand at the post centerline),
# below the crossbar/top netting, and in front of the back mesh. The bounds
# are deliberately conservative — a puck embedded in a panel or resting
# beside / on top of / behind the net fails them all by a clear margin.
static func _center_inside_cavity(
		center: Vector3,
		depth: float,
		half_width: float,
		net_height: float,
		post_radius: float,
		puck_radius: float,
		puck_half_height: float,
		net_depth: float) -> bool:
	if depth > net_depth - puck_radius:
		return false
	if absf(center.x) > half_width - puck_radius:
		return false
	if center.y > net_height - post_radius - puck_half_height:
		return false
	if center.y < 0.0:
		return false
	return true


# Whether a puck CENTER at (cross_x, cross_y) on the goal-line plane sits fully
# inside the mouth: the whole disc between the post INNER faces and under the
# crossbar pipe. This is THE shared definition of "between the posts, under the
# bar" — live play (crossed_into_net), penalty shots (PenaltyShotRules.is_goal),
# and the tutorial (TutorialShotRules.crossed_goal_line) all route through it, so
# a post graze is never a goal in any mode.
#
# `half_width` / `net_height` are the post-centerline / crossbar-centerline
# geometry; the pipe `post_radius` steps in to the clear opening, and the puck's
# own extent (`puck_radius` horizontal, `puck_half_height` vertical) tightens it
# further so no part of the disc is on a pipe.
static func point_in_mouth(
		cross_x: float,
		cross_y: float,
		half_width: float,
		net_height: float,
		post_radius: float,
		puck_radius: float,
		puck_half_height: float) -> bool:
	if absf(cross_x) > half_width - post_radius - puck_radius:
		return false
	if cross_y > net_height - post_radius - puck_half_height:
		return false
	if cross_y < 0.0:
		return false
	return true
