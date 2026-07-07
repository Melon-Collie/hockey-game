class_name PenaltyShotRules

# Pure outcome classification for a single penalty-shot attempt, modelled on the
# NHL Rule 24.2 procedure: the puck starts at centre ice and the shooter skates
# in alone on the goalie. Two rules decide when an attempt is over:
#   1. The puck must be kept IN MOTION toward the opponent's goal line. If it
#      comes to rest ("lost momentum") or moves back toward centre ("went
#      backward"), the attempt is dead.
#   2. Once the puck crosses the goal line the shot is complete — a goal if it's
#      inside the posts and under the crossbar, otherwise a miss. There are no
#      rebounds: because the caller resolves the attempt the instant it goes
#      dead, a save that kicks the puck out is correctly a no-goal, while a
#      deflection that goes straight in still trips the goal test first (which
#      matches the rule's off-the-goalie / off-the-post exception).
#
# Engine-free so the whole lifecycle can be unit-tested headless. PenaltyDrill-
# Manager owns the per-tick accumulators (furthest progress, stall timer) and
# threads them in; this file only classifies a single sampled frame.
#
# Geometry convention matches the rest of the domain: `attack_dir_z` is the sign
# of the shooting team's direction along Z (team 0 attacks toward -Z, so -1).
# "Forward progress" is the puck's displacement from its start projected onto
# that attack direction — it grows as the shooter advances on the net.

enum Outcome { LIVE, GOAL, MISS }


# Tunables for the dead-puck detection. Defaults are deliberately forgiving so
# ordinary stickhandling (which moves the puck laterally, not backward) doesn't
# trip the "lost momentum" / "went backward" rules — only an actual stop or
# retreat does.
class Config:
	# Forward speed (m/s of progress toward the net) at or below which the puck
	# counts as stopped.
	var rest_speed: float = 0.5
	# How long (s) the puck must stay stopped before the attempt dies. A brief
	# dip mid-dangle (or a stride reset while building speed) shouldn't end the
	# rush.
	var stall_grace: float = 0.5
	# How far (m) the puck may retreat from its furthest point before "went
	# backward" fires. A generous window so a deke that pulls the puck back to
	# the hip before releasing reads as dangling, not a dead retreat.
	var backward_tolerance: float = 0.75
	# Forward progress (m) the shooter must make before the dead-puck rules arm,
	# so the puck sitting at centre at the very start isn't read as stalled.
	var start_progress: float = 0.4
	# Running-start grace (s): once the shooter commits to the rush (`started`),
	# suppress the dead-puck rules for this long so they can accelerate from a
	# standstill and settle the puck before "keep it moving" is enforced. Without
	# this, a skater still building speed just past the start line trips the stall
	# timer the instant their forward progress dips — the attempt felt over before
	# it began. This is the "get a running start" window.
	var start_grace: float = 0.8
	# Crossbar height (m); a puck crossing the line above this sailed over the net.
	var crossbar_height: float = 1.22


# Puck displacement from its start, projected onto the attack direction.
# Positive as the shooter advances toward the net; negative if it slides back
# toward centre.
static func forward_progress(puck_z: float, start_z: float, attack_dir_z: float) -> float:
	return (puck_z - start_z) * attack_dir_z


# Whether the puck has reached the goal-line depth, irrespective of width/height.
static func crossed_goal_plane(puck_z: float, goal_line_z: float, attack_dir_z: float) -> bool:
	if attack_dir_z < 0.0:
		return puck_z <= goal_line_z
	return puck_z >= goal_line_z


# Whether the puck is a goal: across the line, inside the posts, under the bar.
# The "between the posts, under the bar" test is shared with live play and the
# tutorial via GoalDetectionRules.point_in_mouth, so `half_width` / `crossbar_
# height` are the post-centerline / crossbar-centerline geometry and the pipe
# radius + puck extent tighten them to the whole-disc clear opening — a puck
# grazing the inside of a post is not a goal here, exactly as in a live game.
static func is_goal(
		puck_x: float,
		puck_y: float,
		puck_z: float,
		goal_line_z: float,
		attack_dir_z: float,
		half_width: float,
		crossbar_height: float) -> bool:
	if not crossed_goal_plane(puck_z, goal_line_z, attack_dir_z):
		return false
	return GoalDetectionRules.point_in_mouth(
			puck_x, puck_y, half_width, crossbar_height,
			GameRules.NET_POST_RADIUS,
			GameRules.PUCK_COLLISION_RADIUS,
			GameRules.PUCK_COLLISION_HALF_HEIGHT)


# Classify one sampled frame of an attempt.
#
# `forward_speed` is the rate of forward progress (m/s) — the caller derives it
# from the change in `forward_progress`, NOT from the puck's rigidbody velocity,
# because a carried puck is frozen to the blade and reports ~0 velocity even as
# the shooter skates it up the ice.
# `max_progress` is the running maximum of `current_progress`; `started` latches
# true once the shooter has advanced `start_progress`; `stall_time` is how long
# `forward_speed` has stayed at or below `rest_speed` since starting;
# `time_since_start` is how long the rush has been live (seconds since `started`
# latched), used to hold the dead-puck rules off during the running-start grace.
static func classify(
		puck_x: float,
		puck_y: float,
		puck_z: float,
		forward_speed: float,
		current_progress: float,
		max_progress: float,
		started: bool,
		stall_time: float,
		time_since_start: float,
		attack_dir_z: float,
		goal_line_z: float,
		half_width: float,
		cfg: Config) -> Outcome:
	if is_goal(puck_x, puck_y, puck_z, goal_line_z, attack_dir_z, half_width, cfg.crossbar_height):
		return Outcome.GOAL
	# Crossed the line but not a goal → wide or over the net: shot complete, miss.
	if crossed_goal_plane(puck_z, goal_line_z, attack_dir_z):
		return Outcome.MISS
	# Dead-puck rules don't arm until the shooter has actually started the rush.
	if not started:
		return Outcome.LIVE
	# Running-start grace: give the shooter time to accelerate off the mark and
	# settle the puck before the keep-it-moving rules can end the attempt.
	if time_since_start < cfg.start_grace:
		return Outcome.LIVE
	# Went backward — retreated from the furthest point reached.
	if current_progress < max_progress - cfg.backward_tolerance:
		return Outcome.MISS
	# Lost momentum — puck stopped advancing for long enough.
	if forward_speed <= cfg.rest_speed and stall_time >= cfg.stall_grace:
		return Outcome.MISS
	return Outcome.LIVE
