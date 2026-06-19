class_name TutorialShotRules

# Pure detection helpers for the Shooting tutorial's drills. Kept engine-free so
# the Shooting module's success criteria — "did the puck cross into the net?",
# "which lit target did it hit?", "was that a charged wrist shot or a tap?" —
# can be unit-tested headless. TutorialManager owns the per-drill state; this
# file only answers questions about a single sampled frame.


# Whether the puck has crossed the goal line into the net mouth.
#
# `attack_dir_z` is the sign of the attacking team's shooting direction along Z
# (the Shooting tutorial is always team 0, attacking toward -Z, so this is -1).
# A goal counts only when the puck is past the line in the attack direction AND
# laterally inside the posts (|x| within `half_width`). Height isn't gated here —
# crossing-height classification is the target test's job.
static func crossed_goal_line(
		puck_x: float,
		puck_z: float,
		goal_line_z: float,
		attack_dir_z: float,
		half_width: float) -> bool:
	if absf(puck_x) > half_width:
		return false
	if attack_dir_z < 0.0:
		return puck_z <= goal_line_z
	return puck_z >= goal_line_z


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


# Whether a released wrister was a charged/dragged shot rather than a quick tap.
# `charge_distance` is the blade-drag distance built up before release; below
# `quick_threshold` the engine fires it as a fixed-power quick shot (which is
# also the pass), so the Wrist Shot drill requires a drag past that line.
static func is_dragged_wrister(charge_distance: float, quick_threshold: float) -> bool:
	return charge_distance >= quick_threshold
