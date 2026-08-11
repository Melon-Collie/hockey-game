extends GutTest

# ── THE SHOT PEOPLE ACTUALLY TAKE: straight in down a post lane ──────────────
# Every other real-goalie instrument in this directory fires from a PARKED
# shooter — settle on a spot, then release. That is not a shot anybody takes,
# and it hides a whole class of failure, because a parked shooter presents the
# goalie a FIXED angle. This one drives the carrier in the way a player does:
# straight down the ice, holding a lane, releasing off the drive.
#
# The lane is the point. Driving down x = ±NET_HALF_WIDTH — in line with a post —
# the carrier's own lateral velocity is EXACTLY ZERO for the whole approach,
# while the angle he presents sweeps from ~8° at the dot line to over 40° at the
# doorstep. The goalie's square position on the challenge arc therefore travels
# most of the way from the middle of the mouth to the post while the thing he
# measures the play by (`carrier.velocity.x`) never leaves zero.
#
# Two questions, one per test below:
#   TRACE  — how far behind his own square position does he actually run?
#   MAP    — and does that leave a repeatable place to shoot?
#
# The control lane (x = 0, straight in down the middle) is run alongside so the
# post-lane numbers can be read as "worse than a drive" rather than "worse than a
# parked shooter", which would confound the drive with the lane.
#
# ── WHAT IT MEASURED (2026-08) ───────────────────────────────────────────────
# Drive at 6.5 m/s from 9 m, wind-up held through it, honest release, best over
# 70/80 mph. Columns run post to post; on the -x lane the LEFT edge is the short
# side.
#
#   release 2.5 m   POST LANE   FLAT |Gpppppppssssssssssssssss|  2 goals
#                               LOW  |Gppppppssssssssssssssssss|  2
#                               HIGH |GGpppssssssssGGppssssssp |  8
#                               -> 12/144 (8.3%), 8 of them short side
#                   CENTRE      ->  3/144 (2.1%), 0 short side
#   release 4.0 m   POST LANE   -> 10/144 (6.9%), 6 short side
#                   CENTRE      ->  4/144 (2.8%), 0 short side
#
# FOUR TIMES the goals, and the whole short-side column is open at EVERY loft —
# the flat and low ones too, which is the part that reads as broken. The centre
# lane concedes nothing there at any loft; what it concedes is the middle, high,
# which is the goalie getting beaten the way he is supposed to be.
#
# ── WHY: the retreat, not the tracking ───────────────────────────────────────
# The trace test rules out lag outright — he is never more than 7 cm off his own
# square position anywhere in the drive. He is exactly where the model puts him,
# and the model puts him here (post lane, sampled down the drive):
#
#     out(m)   angle   goalie_x   radius
#      4.0     12.9°    -0.250    1.125
#      3.0     17.0°    -0.240    0.739
#      2.0     24.6°    -0.208    0.365
#      1.0     42.5°    -0.117    0.111
#
# He drifts BACK TOWARD THE MIDDLE as the shooter closes on the post. That is
# not a bug in the arc solve, it is the arc solve's definition: the challenge
# position is the puck→goal-CENTRE line, and that line converges on x = 0 at the
# goal line, so as the radius collapses his lateral position stops depending on
# the shooter's angle at all. At 1 m out he is standing 7 cm off centre with a
# shooter in line with the post and ~0.28 m of open pipe beside him.
#
# The radius collapses because of the RUSH BACKFLOW, which is the one constraint
# in GoalieDepthSolver that is not a race — it gives ground on the attacker's
# DISTANCE alone (GoalieBehaviorRules.rush_retreat_depth), for any carrier
# closing at 1.5 m/s inside 8 m. Switching it off (the counterfactual test
# below) at the 2.5 m post-lane release:
#
#     backflow ON    x -0.225  radius 0.565   ->  8/144 goals, 4 short side
#     backflow OFF   x -0.660  radius 1.749   ->  0/144 goals, all 144 STICK
#
# So the backflow owns the position the goals come from. Note the OFF column is
# a wall, which is the other failure mode — the counterfactual identifies the
# mechanism, it is not a proposal.
#
# ── WHAT THIS INSTRUMENT CANNOT DECIDE ───────────────────────────────────────
# Deep in his crease the goalie is physically too small to cover the mouth from
# 2.5 m (a 1.12 m pad column against a 1.83 m net), so SOME band is open however
# he stands, and standing on the centre line splits the leftover evenly. Closing
# the short side means choosing to concede the far side instead — real doctrine
# ("never get beat short side"), but a doctrine call, not something the geometry
# decides: measured from the post lane at 2.5 m the short-side gap is already
# the ANGULARLY smaller of the two (5.2° against 7.4°), so an even-handed model
# is already shading away from it and no amount of grounding will flip that on
# its own. Post integration cannot rescue it either — `rvh_early_angle` is 80°,
# which on this lane is not reached until 0.16 m off the goal line.
#
# The two ways out, both changes to how the retreat is priced rather than to the
# lateral solve:
#   * floor the backflow at the depth where the set stance still fills the
#     shooter's angle — tried and REJECTED here: full coverage is exactly the
#     wall the OFF column measured, and the floor's own geometry (r >= 0.39·D)
#     cancels the backflow out to ~4.5 m, which re-freezes the keeper's depth in
#     AIActionScoring.planned_goalie_depth and with it the bots' drive-the-net
#     gradient;
#   * make the retreat DIRECTIONAL: it buys lateral coverage, and a carrier on
#     the post lane has no short-side room left to punish it with, so the ground
#     given up on that side is bought with nothing.

const Harness := preload("res://tests/unit/ai/real_goalie_shot_harness.gd")
const GOAL_Z: float = -GameRules.GOAL_LINE_Z
const POST_LANE: float = -GameRules.NET_HALF_WIDTH
# Where the drive starts. Outside `rush_engage_distance` (8 m) so the backflow
# engages during the drive rather than being already spent at the first tick.
const START_DIST: float = 9.0
# A real forward's drive pace, not the sprint ceiling — 9.0 m/s is
# DEFAULT_SKATER_MAX_SPEED_M_S and nobody carries the puck at it.
const DRIVE_SPEED: float = 6.5
const MAX_AIM: float = GameRules.NET_HALF_WIDTH \
		- GameRules.NET_POST_RADIUS - GameRules.PUCK_COLLISION_RADIUS
const SHOT_MPH: Array[float] = [70.0, 80.0]
const MPH_TO_MS: float = 0.44704
const PART := ["STICK", "PAD", "BLOCK", "CHEST", "GLOVE"]

var _goalie: Node = null
var _puck: Node = null
var _shooter: Skater = null
var _ctrl: GoalieController = null
var _h: RefCounted = null


func before_each() -> void:
	_goalie = load("res://Scenes/Goalie.tscn").instantiate()
	_puck = load("res://Scenes/Puck.tscn").instantiate()
	_shooter = load("res://Scenes/Skater.tscn").instantiate() as Skater
	_ctrl = GoalieController.new()
	add_child_autofree(_goalie)
	add_child_autofree(_puck)
	add_child_autofree(_shooter)
	add_child_autofree(_ctrl)
	_h = Harness.new()
	_h.setup(_goalie, _puck, _ctrl, _shooter)


# The square position he is CHASING: the challenge-arc point for the true puck
# at the radius he is currently holding. Comparing his actual x against this
# separates "he is in the wrong place because he is late" from "the place he is
# aiming for is itself wrong" — only the first shows up as a lag.
func _square_x(lane_x: float, dist: float) -> float:
	var cfg := GoalieBehaviorRules.ArcConfig.new()
	cfg.net_half_width = _ctrl.net_half_width
	cfg.seal_inset = _ctrl.post_seal_inset
	cfg.seal_depth = _ctrl.rvh_depth
	cfg.post_integration_angle_deg = _ctrl.rvh_early_angle
	return GoalieBehaviorRules.target_arc_position(
			Vector3(lane_x, 0.0, GOAL_Z + dist), GOAL_Z, 0.0, 1,
			_ctrl._current_depth, cfg).x


func _trace(lane_x: float, label: String) -> void:
	_h.settle_ready(Vector3(lane_x, 0.0, GOAL_Z + START_DIST))
	gut.p("  %s" % label)
	gut.p("    out(m)  angle  goalie_x  square_x   lag  depth")
	var d: float = START_DIST
	while d > 1.0:
		var next_d: float = d - 0.5
		_h.drive_in(lane_x, d, next_d, DRIVE_SPEED)
		d = next_d
		var angle: float = rad_to_deg(atan2(absf(lane_x), maxf(d, 0.01)))
		var sq: float = _square_x(lane_x, d)
		gut.p("    %5.1f   %4.1f°   %+6.3f   %+6.3f  %+5.3f  %5.3f"
				% [d, angle, _ctrl._current_x, sq, _ctrl._current_x - sq,
				_ctrl._current_depth])


# What he does with the whole approach, sampled every half metre. Read the `lag`
# column: it is metres of net he is conceding to the short side at that instant.
func test_report_the_trace_down_the_post_lane() -> void:
	gut.p("Straight-in drive at %.1f m/s, sampled every 0.5 m." % DRIVE_SPEED)
	gut.p("`square_x` is the arc target for the true puck at his CURRENT radius,")
	gut.p("so `lag` is tracking error alone — not a disagreement about where to be.")
	_trace(POST_LANE, "POST LANE  x = %.3f" % POST_LANE)
	_trace(0.0, "CENTRE LANE (control)  x = 0")
	assert_true(true, "report")


func _map(lane_x: float, release_dist: float, windup: bool) -> Dictionary:
	var lofts: Array[int] = [
		ShotMechanics.ELEVATION_FLAT,
		ShotMechanics.ELEVATION_LOW,
		ShotMechanics.ELEVATION_HIGH,
	]
	var names: Array[String] = ["FLAT", "LOW ", "HIGH"]
	var start := Vector3(lane_x, 0.0, GOAL_Z + START_DIST)
	var goals: int = 0
	var shots: int = 0
	var parts: Dictionary = {}
	var near_goals: int = 0    # goals on the SHORT side — the lane's own side
	var pose_x: float = 0.0
	var pose_depth: float = 0.0
	for li: int in lofts.size():
		var row: String = ""
		var row_goals: int = 0
		var a: float = -MAX_AIM
		while a <= MAX_AIM + 0.001:
			var best: String = "."
			for mph: float in SHOT_MPH:
				var speed: float = mph * MPH_TO_MS
				var aim := Vector3(a, 0.0, GOAL_Z)
				_h.settle_ready(start)
				var rel: Vector3 = _h.drive_in(lane_x, START_DIST, release_dist,
						DRIVE_SPEED, aim if windup else Vector3.INF,
						lofts[li], speed)
				pose_x += _ctrl._current_x
				pose_depth += _ctrl._current_depth
				var o: int = _h.fire_release_at(rel, aim, lofts[li], speed, 0.0) \
						if windup else _h.fire_at(rel, aim, lofts[li], speed, 0.0)
				shots += 1
				if o == Harness.GOAL:
					goals += 1
					row_goals += 1
					best = "G"
					if lane_x != 0.0 and a * signf(lane_x) > 0.0:
						near_goals += 1
				elif o == Harness.SAVE:
					var k: String = PART[_h.last_part] if _h.last_part >= 0 else "?"
					parts[k] = int(parts.get(k, 0)) + 1
					if best == ".":
						best = k.substr(0, 1).to_lower()
				elif best == ".":
					best = "x"
			row += best
			a += 0.07
		gut.p("     %s |%s| %d" % [names[li], row, row_goals])
	var n: float = float(maxi(shots, 1))
	gut.p("     -> %d/%d (%.1f%%)  short-side %d  release pose x %+.3f radius %.3f  %s"
			% [goals, shots, 100.0 * float(goals) / n, near_goals,
			pose_x / n, pose_depth / n, str(parts)])
	return {"goals": goals, "shots": shots, "near": near_goals}


# ── COUNTERFACTUAL: how much of the short-side hole is the rush backflow ─────
# `rush_engage_distance = 0` switches the backflow off entirely (the constraint
# is skipped for any carrier at or beyond the engage distance), leaving depth to
# the races the solver header describes: a genuine 1v0 with nothing binding is
# challenged at the ceiling. Not a proposal — a measurement of which constraint
# owns the position the goals come from.
func test_report_how_much_of_the_hole_is_the_rush_backflow() -> void:
	gut.p("POST LANE, cold release 2.5 m out. Baseline, then backflow disabled.")
	var base: Dictionary = _map(POST_LANE, 2.5, false)
	_ctrl.rush_engage_distance = 0.0
	gut.p("  backflow OFF:")
	var off: Dictionary = _map(POST_LANE, 2.5, false)
	gut.p("  %d -> %d goals, short-side %d -> %d"
			% [base["goals"], off["goals"], base["near"], off["near"]])
	assert_true(true, "report")


# The map, off the drive. Columns run post to post left→right; on the -x post
# lane the LEFT of each row is the short side.
func test_report_the_goal_map_off_a_post_lane_drive() -> void:
	gut.p("Cold release off the drive (no wind-up published).")
	for dist: float in [4.0, 2.5]:
		gut.p("  release %.1f m out, POST LANE:" % dist)
		_map(POST_LANE, dist, false)
		gut.p("  release %.1f m out, CENTRE LANE (control):" % dist)
		_map(0.0, dist, false)
	assert_true(true, "report")


# The same drive with the trigger held through it — the human mechanism, and the
# one the cold sweeps in test_goalie_exhaustive_beatability measured as WIDENING
# the seam from a parked spot. Whether that still holds off a moving carrier is
# the question.
func test_report_the_goal_map_off_a_post_lane_drive_with_windup() -> void:
	gut.p("Wind-up held through the drive, honest release.")
	for dist: float in [4.0, 2.5]:
		gut.p("  release %.1f m out, POST LANE:" % dist)
		_map(POST_LANE, dist, true)
		gut.p("  release %.1f m out, CENTRE LANE (control):" % dist)
		_map(0.0, dist, true)
	assert_true(true, "report")
