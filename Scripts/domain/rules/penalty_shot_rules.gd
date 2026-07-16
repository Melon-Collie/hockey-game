class_name PenaltyShotRules

# Pure outcome classification for a single penalty-shot attempt, modelled on the
# NHL Rule 24.2 procedure: the shooter starts at centre ice and skates in alone
# on the goalie. Two rules decide when an attempt is over:
#   1. The SHOOTER must keep driving toward the opponent's goal line. If they stop
#      advancing ("lost momentum") or skate back toward centre ("went backward"),
#      the attempt is dead. This is keyed on the shooter's own forward progress,
#      NOT the puck's: dangling or deking moves the puck laterally / pulls it back
#      to the hip, and a shot fires it away independently — none of which should
#      end the rush. (Rule 24.2 speaks of the puck, but here the puck is a real
#      body frozen to the blade while carried and free once shot, so tying the
#      keep-moving test to the skater's drive is the faithful gameplay reading —
#      only the player backing off ends it.)
#   2. Once the PUCK crosses the goal line the shot is complete — a goal if it's
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
# "Forward progress" is the shooter's displacement from their start projected onto
# that attack direction — it grows as they advance on the net.

enum Outcome { LIVE, GOAL, MISS }


# Tunables for the keep-driving detection. Defaults are deliberately forgiving so
# a shooter briefly gliding or weaving through their stride doesn't trip the "lost
# momentum" / "went backward" rules — only actually stopping or backing off does.
# (Because the rules track the shooter, not the puck, dangling or shooting the
# puck never trips them regardless of these tunables.)
class Config:
	# Forward speed (m/s of the shooter's progress toward the net) at or below
	# which the shooter counts as stopped.
	var rest_speed: float = 0.5
	# How long (s) the shooter must stay stopped before the attempt dies. A brief
	# dip mid-stride (or a stride reset while building speed) shouldn't end the
	# rush.
	var stall_grace: float = 0.5
	# How far (m) the shooter may drift back from their furthest point before "went
	# backward" fires. A generous window so squaring up or an edge-work wobble
	# reads as part of the rush, not a dead retreat.
	var backward_tolerance: float = 0.75
	# Forward progress (m) the shooter must make before the keep-driving rules arm,
	# so the shooter standing at centre at the very start isn't read as stalled.
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


# Displacement from the start point, projected onto the attack direction. The
# caller feeds the shooter's Z (the keep-driving rules track the player, not the
# puck). Positive as they advance toward the net; negative if they slide back
# toward centre.
static func forward_progress(pos_z: float, start_z: float, attack_dir_z: float) -> float:
	return (pos_z - start_z) * attack_dir_z


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
# `forward_speed` is the shooter's rate of forward progress (m/s) — the caller
# derives it from the change in the shooter's `forward_progress`. It tracks the
# player, not the puck, so a dangled or shot puck moving independently doesn't end
# the attempt; only the shooter stalling does.
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
