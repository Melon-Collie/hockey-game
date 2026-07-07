class_name TutorialShotRules

# Pure detection helpers for the Shooting tutorial's drills. Kept engine-free so
# the Shooting module's success criteria — "did the puck cross into the net?",
# "which lit target did it hit?", "was that a charged wrist shot or a tap?" —
# can be unit-tested headless. TutorialManager owns the per-drill state; this
# file only answers questions about a single sampled frame.


# Whether the puck has crossed the goal line into the net mouth — a real goal.
#
# `attack_dir_z` is the sign of the attacking team's shooting direction along Z
# (the Shooting tutorial is always team 0, attacking toward -Z, so this is -1).
# A goal counts only when the puck is past the line in the attack direction AND
# the whole disc is inside the mouth — between the posts, under the bar. The
# posts/bar test is shared with live play and penalty shots via GoalDetection-
# Rules.point_in_mouth (`half_width` / `net_height` are the post-centerline /
# crossbar-centerline geometry, tightened by the pipe radius + puck extent), so a
# post graze is not a goal here either. (Target drills use `nearest_target`
# instead — those deliberately reward rough aim and don't call this.)
static func crossed_goal_line(
		puck_x: float,
		puck_y: float,
		puck_z: float,
		goal_line_z: float,
		attack_dir_z: float,
		half_width: float,
		net_height: float) -> bool:
	if attack_dir_z < 0.0:
		if puck_z > goal_line_z:
			return false
	elif puck_z < goal_line_z:
		return false
	return GoalDetectionRules.point_in_mouth(
			puck_x, puck_y, half_width, net_height,
			GameRules.NET_POST_RADIUS,
			GameRules.PUCK_COLLISION_RADIUS,
			GameRules.PUCK_COLLISION_HALF_HEIGHT)


# Whether the puck has reached the goal-line DEPTH, ignoring width and height.
# `crossed_goal_line` answers "is this a goal?" (past the line AND inside the
# posts); this answers the looser "has the shot reached the net's depth?" — true
# for a goal, but also for a puck sailing wide of a post or over the crossbar.
# The drill loop uses it to retire a shot that has clearly missed the instant it
# passes the net, instead of waiting for it to trickle to a stop in the corner.
static func crossed_goal_plane(
		puck_z: float,
		goal_line_z: float,
		attack_dir_z: float) -> bool:
	if attack_dir_z < 0.0:
		return puck_z <= goal_line_z
	return puck_z >= goal_line_z


# Whether a shot in flight has clearly missed and the attempt should be retired.
# A shot is a miss once it has either (a) passed the goal-line depth without
# being a goal — wide of a post or over the bar — or (b) gone dead: lost its
# forward drive toward the net (a save/rebound that stopped it, or a shot that
# simply petered out). `forward_speed` is the rate of progress toward the net
# (m/s), derived by the caller from the change in forward progress rather than
# the rigidbody speed, so a puck rebounding straight back reads as negative and
# trips the rest test immediately.
#
# `is_goal_now` lets the caller feed in its own goal/target test result so this
# stays the single "should I reset?" answer without duplicating the posts math:
# when the shot IS a goal this returns false (the goal path handles it).
static func shot_missed(
		is_goal_now: bool,
		puck_z: float,
		goal_line_z: float,
		attack_dir_z: float,
		forward_speed: float,
		rest_speed: float,
		stall_time: float,
		stall_grace: float) -> bool:
	if is_goal_now:
		return false
	if crossed_goal_plane(puck_z, goal_line_z, attack_dir_z):
		return true
	return forward_speed <= rest_speed and stall_time >= stall_grace


# Index of the target nearest the (x, y) crossing point that lies within
# `radius`, or -1 if the puck crossed outside every target. Targets are
# net-plane positions (x = lateral, y = height). The caller tracks which
# indices are already cleared and ignores a repeat hit.
static func nearest_target(
		px: float,
		py: float,
		targets: Array[Vector2],
		radius: float) -> int:
	var best_i: int = -1
	var best_d2: float = radius * radius
	for i: int in targets.size():
		var dx: float = px - targets[i].x
		var dy: float = py - targets[i].y
		var d2: float = dx * dx + dy * dy
		if d2 <= best_d2:
			best_d2 = d2
			best_i = i
	return best_i


# Whether a released wrister was a charged/dragged shot rather than a flick.
# `charge_distance` is the blade-drag distance built up before release. The engine
# splits quick-vs-charged by hold time, not distance, but the Wrist Shot drill's
# lesson is dragging to aim/charge, so it gates on a meaningful drag past
# `drag_qualify` (a tutorial bar, not the engine's quick-shot rule).
static func is_dragged_wrister(charge_distance: float, drag_qualify: float) -> bool:
	return charge_distance >= drag_qualify
