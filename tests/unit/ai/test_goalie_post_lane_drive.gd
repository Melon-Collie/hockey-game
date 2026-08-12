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
# Four questions, one per test below:
#   TRACE    — how far behind his own square position does he run, and which
#              depth constraint is actually bringing him in?
#   MAP      — does that leave a repeatable place to shoot?
#   ANCHOR   — what does moving where the retreat lands buy, and cost?
#   WALKOUT  — the puck dragged across him, which prices depth the other way
#   DEKE     — and a BODY going around him, which is what retreating is FOR
#
# The control lane (x = 0, straight in down the middle) is run alongside so the
# post-lane numbers can be read as "worse than a drive" rather than "worse than a
# parked shooter", which would confound the drive with the lane.
#
# ── WHAT IT MEASURED (2026-08) ───────────────────────────────────────────────
# Drive at 6.5 m/s from 9 m, best over 70/80 mph. L/R are goals in the left and
# right halves of the mouth; on the -x lane LEFT is the short side. `radius` is
# the challenge radius he is actually holding at the release.
#
#              WIND-UP HELD THROUGH THE DRIVE        COLD RELEASE
#   release    POST LANE      CENTRE       radius    POST         CENTRE
#    2.5 m      2  L2/R0      3  L2/R1     0.749      6  L4/R2     5  L2/R3
#    4.0 m      8  L6/R2      4  L2/R2     1.170      8  L6/R2     4  L2/R2
#    6.5 m      7  L2/R5      6  L0/R6     1.560      -            -
#
# The control is NOT clean, and reading it as clean was a bug in this instrument
# for one run: it concedes 2 left-half goals at 2.5 and 4.0 m. What the post lane
# has ever added is the EXCESS and its side, not the existence of a hole.
#
# THE 2.5 m ROW USED TO BE 12 (L8/R4), four times the control, with the short-side
# column open at EVERY loft including flat and low. That is what `rush_arrive_depth`
# addressed and it is what the sweep below prices; the row now sits at the control's
# level and the flat and low rows are clean.
#
# THE 4.0 m ROW IS THE RESIDUAL. Its left half did not move (L6 against the
# control's L2), because the backflow's curve near its `rush_mid_distance` end is
# barely touched by where it lands — 1.127 to 1.170 of radius. If the post lane
# still feels wrong to play at that range, the shape of the curve between mid and
# arrive is the next thing to look at, not the anchor.
#
# BY 6.5 m THERE IS NO LANE EFFECT LEFT. Both lanes are dominated by the same
# RIGHT-half hole, which is the low glove-side seam a held wind-up opens against a
# parked shooter too (test_goalie_exhaustive_beatability's held-windup sweep). The
# radius column is why — the backflow has barely bitten there (1.56 against a 1.75
# ceiling), so the geometry below never goes degenerate.
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
#     backflow ON    x -0.284  radius 0.749   ->  6/144 goals, 4 short side
#     backflow OFF   x -0.660  radius 1.749   ->  0/144 goals, all 144 STICK
#
# So the backflow owns the position the goals come from. Note the OFF column is
# a wall, which is the other failure mode — the counterfactual identifies the
# mechanism, it is not a proposal.
#
# ── WHAT THE LATERAL SOLVE CANNOT FIX ────────────────────────────────────────
# Deep in his crease the goalie is physically too small to cover the mouth from
# 2.5 m (a 1.12 m pad column against a 1.83 m net), so SOME band is open however
# he stands, and standing on the centre line splits the leftover evenly. Shading
# to the short side means choosing to concede the far side, and the geometry does
# not decide that: from the post lane at 2.5 m the short-side gap is already the
# ANGULARLY smaller of the two (5.2° against 7.4°), so an even-handed model is
# shading away from it correctly. Post integration cannot rescue it either —
# `rvh_early_angle` is 80°, not reached on this lane until 0.16 m off the line.
#
# So the depth is the lever, and the retreat is where the defect lives.
#
# ── WHAT THE RETREAT'S ANCHOR IS WORTH (the sweep test below) ────────────────
# Sweeping `rush_arrive_depth` — where the backflow lands when the attacker
# reaches `rush_arrive_distance` — wind-up drive, released 2.5 m out. 0.10 is
# `depth_defensive`, which it used to be; 0.40 is what it is now:
#
#     anchor      POST radius / goals        CENTRE radius / goals
#     0.10 (was)    0.565   12  L8/R4          0.500   3  L2/R1
#     0.25          0.657    6  L4/R2          0.600   3  L2/R1
#     0.40 (ship)   0.749    2  L2/R0          0.700   3  L2/R1
#     0.55          0.841    0                 0.800   1  L0/R1
#     0.70          0.933    0                 0.900   0
#
# READ THE CONTROL COLUMN. It is FLAT at 3 goals from 0.10 through 0.40 and only
# starts falling past that, so in that range the anchor moves the post lane's
# excess and nothing else: at 0.40 the two lanes concede alike and the asymmetry
# is gone with no beatability lost on the control. Past 0.55 the keeper walls up
# on both lanes, which is the other failure mode and the one that matters more —
# that is the whole reason the anchor did not simply go to C (0.70).
#
# ── THE OTHER HALF OF THE TRADE: does a shallower retreat get him WALKED ─────
# Retreating is not for the shot. It is what stops a goalie being skated around
# for free — deeper is a shorter arc to travel to stay in front of a puck dragged
# across him — so an anchor that buys angle has to be paid for here or only half
# the trade has been measured. Body driving straight in to 3.5 m, puck then
# dragged to the backhand side, fired from where the PUCK ended up:
#
#   drag pace     anchor 0.10 (was)              anchor 0.40 (ship)
#   3.6 m/s        4/144   x -0.076  r 0.240      1/144   x -0.187  r 0.505
#   6.0 m/s       25/144   x -0.070  r 0.500     10/144   x -0.151  r 0.700
#
# IT GOES THE OTHER WAY, at both paces, and the goalie-x column is the reason.
# With the puck dragged out to -0.90 the deeper keeper sits at -0.07 — he barely
# follows it across at all. This is the degenerate arc again: the challenge line
# converges on x = 0 at the goal line, so the deeper he is, the LESS his lateral
# target responds to the puck moving. Retreating does shorten the arc he has to
# travel, but in this model it shrinks the arc he is ASKED to travel faster still,
# so in tight the retreat is not buying lateral protection — it is removing his
# lateral response. That is the same defect the post-lane hole comes from, seen
# from the other side, and it means the depth/lateral trade the backflow is meant
# to make is not actually being made at these ranges.
#
# SCOPE, because this measures less than it sounds like: the body drives straight
# and only the puck moves, so it is the drag, not a deke-and-tuck where the body
# goes around. The tuck is the beaten-wide seal's job and lives in
# test_goalie_lateral_beat_slide.gd. One cut distance, one direction, rebounds
# terminal.
#
# ── DOES HE GET SKATED AROUND? (the deke test) ───────────────────────────────
# The two measurements above both move only the PUCK, so `carrier.velocity.x`
# stays zero and the lateral tracking cap, the carrier lead and the beaten-wide
# read never engage. That leaves the question retreating actually exists to
# answer untouched: does a body crossing the crease face get past him. Drive the
# +post lane to 3.5 m, cut the body across to -0.55 with the puck leading to the
# far post, fire from where the PUCK ended up:
#
#   cut pace            anchor 0.10 (was)          anchor 0.40 (ship)
#   3.7 m/s lateral      5/144  x -0.207 r 0.439    0/144  x -0.308 r 0.654
#   5.9 m/s lateral      4/144  x -0.141 r 0.616    1/144  x -0.196 r 0.787
#
# HE IS NOT BEING SKATED AROUND — 0-3.5% of a perfect-aim sweep, he stays on his
# feet through it (down 0%, the beaten-wide seal never fires because he wins the
# race to the tuck), and the shallower retreat is BETTER at it, not worse. Taken
# with the walkout above, the retreat has now been priced against every lateral
# shape this harness can produce and it has not once paid for the depth it costs.
#
# THE SHAPE THAT DOES BEAT HIM IS A DIFFERENT MECHANISM. Cutting from the centre
# lane out to x -1.00 instead puts the puck at -1.35 — outside the post — and that
# scores 25/144 (17.4%) at anchor 0.10 and 24/144 at 0.40, i.e. the retreat does
# not touch it. He is beaten WIDE there (correctly), seals (down 100%, at 0.19 s),
# and the seal parks him at a fixed x -0.154 so the rotated pad edge lands on the
# post — which it does. The goals are shots that pass OUTSIDE that pad edge at his
# own plane and cut back inside the post at the goal line. That is a walkout past
# him answered by a seal, not a failure of the arc, and it is the one worth
# looking at next.
#
# ── WHAT THE SOURCES SAY (2026-08) ───────────────────────────────────────────
# Two findings, and they point at the trigger and the anchor separately.
#
# THE ANCHOR IS A SITUATIONAL ZONE, NOT A DEPTH. In the Buckley system this
# curve is taken from, D — where the retreat lands — is defined as "on the post,
# or tracking the puck behind the net", and C as the middle of the blue paint,
# held "when a lateral play can be made". A shooter coming straight in from
# 1.5 m is neither, and the taught breakaway retreat ends at the top of the
# crease and converts into lateral movement rather than continuing to the goal
# line — "if you back in too soon they will have net open up to shoot at", which
# is this defect stated as a coaching error.
#
# THE TRIGGER IS DISTANCE, AND DOCTRINE SAYS IT SHOULD BE THE LATERAL OPTION.
# "Challenge the shot, respect the pass": depth is surrendered when another
# option appears — a trailer, a backdoor man, a deke — not because the shooter
# got closer. Our solve already prices both of those honestly (`lateral_cap` for
# the deke, `backdoor_cap` for the pass), and the trace test shows BOTH sitting
# at "not binding" for the entire post-lane drive while the goalie surrenders
# 1.75 m of radius anyway. He pays for respecting a pass nobody can throw.
#
# That also explains why switching the backflow off makes him a wall HERE and
# should not be read as "the backflow is wrong": against a 1v0 with no lateral
# option, near-unbeatable is what the doctrine actually prescribes. What is
# missing is the model that separates that case from the deke the backflow
# exists for — a carrier's remaining lateral ROOM, which on the post lane is
# almost nil to the short side and the width of the ice to the far.

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


const CAP_INF: float = 99.0


func _cap(v: float) -> String:
	return "  -  " if v >= CAP_INF else "%5.2f" % v


# WHICH CONSTRAINT IS ACTUALLY BRINGING HIM IN. Read live off the controller's
# own `_depth_constraints` (rebuilt in place every tick) rather than re-derived
# here, so this cannot describe a solve the goalie isn't running. Every entry is
# a MAXIMUM RADIUS; the tightest one is the answer, and a dash means that
# constraint is not binding at all.
func _trace(lane_x: float, label: String) -> void:
	_h.settle_ready(Vector3(lane_x, 0.0, GOAL_Z + START_DIST))
	gut.p("  %s" % label)
	gut.p("    out(m)  angle  goalie_x  square_x    lag  radius | ceil  standoff"
			+ "  lateral  backdoor   rush  <- binding")
	var d: float = START_DIST
	while d > 1.0:
		var next_d: float = d - 0.5
		_h.drive_in(lane_x, d, next_d, DRIVE_SPEED)
		d = next_d
		var angle: float = rad_to_deg(atan2(absf(lane_x), maxf(d, 0.01)))
		var sq: float = _square_x(lane_x, d)
		var c: GoalieDepthSolver.Constraints = _ctrl._depth_constraints
		var binding: String = "ceiling"
		var tightest: float = c.ceiling_radius
		for pair: Array in [[c.standoff_cap, "standoff"], [c.lateral_cap, "lateral"],
				[c.backdoor_cap, "backdoor"], [c.rush_radius, "rush"]]:
			if float(pair[0]) < tightest:
				tightest = float(pair[0])
				binding = String(pair[1])
		gut.p("    %5.1f   %4.1f°   %+6.3f   %+6.3f  %+5.3f   %5.3f | %s  %s  %s  %s  %s   %s"
				% [d, angle, _ctrl._current_x, sq, _ctrl._current_x - sq,
				_ctrl._current_depth, _cap(c.ceiling_radius), _cap(c.standoff_cap),
				_cap(c.lateral_cap), _cap(c.backdoor_cap), _cap(c.rush_radius),
				binding])


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
	# Split by half of the mouth ALWAYS, never by "the lane's own side": a
	# short-side count that is only defined for an off-centre lane silently
	# reports zero for the control, which reads as "the control concedes nothing
	# there" when it means "not measured". On the -x lane, `left` is short side.
	var left_goals: int = 0
	var right_goals: int = 0
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
					if a < 0.0:
						left_goals += 1
					elif a > 0.0:
						right_goals += 1
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
	gut.p("     -> %d/%d (%.1f%%)  L%d/R%d  release pose x %+.3f radius %.3f  %s"
			% [goals, shots, 100.0 * float(goals) / n, left_goals, right_goals,
			pose_x / n, pose_depth / n, str(parts)])
	return {"goals": goals, "shots": shots, "left": left_goals, "right": right_goals}


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
	gut.p("  %d -> %d goals, short side %d -> %d"
			% [base["goals"], off["goals"], base["left"], off["left"]])
	assert_true(true, "report")


# ── COUNTERFACTUAL: the retreat's TERMINAL ANCHOR ────────────────────────────
# The backflow lands on `depth_defensive` — BPS "D" — when the attacker reaches
# `rush_arrive_distance`. But D is defined situationally, not by distance: in the
# system this curve is taken from, D is "on the post, or tracking the puck behind
# the net". A shooter coming straight at the goalie from 1.5 m is not that
# situation, and the taught retreat against him ends at the top of the crease and
# converts into lateral movement rather than continuing to the goal line ("if you
# back in too soon they will have net open up to shoot at"). The zone that IS
# defined for it is C — the middle of the blue paint, held when a lateral play is
# live, which is exactly what the retreat is buying.
#
# So this sweeps the landing anchor from D to C and measures. BOTH lanes, and the
# control column is the half that matters: an anchor that only helps the post
# lane by walling him up everywhere is not the fix, and the control is what tells
# the two apart. The full 5-point sweep is in the header; three points are kept
# live here because these maps are the most expensive thing in the suite.
#
# `AIActionScoring._build_planning_rush_cfg` copies all three anchors by hand, so
# it must move with `rush_arrive_depth` or the bots score against a keeper who
# retreats further than the one they meet. The tie is pinned by
# test_goalie_depth_model_tie.gd — keep the two in step.
func test_report_the_retreat_landing_anchor_sweep() -> void:
	gut.p("Wind-up drive, release 2.5 m. Retreat anchor D (%.2f) .. C (%.2f)."
			% [_ctrl.depth_defensive, _ctrl.depth_conservative])
	for anchor: float in [0.10, 0.40, 0.70]:
		_ctrl._rush_cfg.depth_arrive = anchor
		gut.p("  anchor %.2f, POST LANE:" % anchor)
		var post: Dictionary = _map(POST_LANE, 2.5, true)
		gut.p("  anchor %.2f, CENTRE LANE:" % anchor)
		var mid: Dictionary = _map(0.0, 2.5, true)
		gut.p("  == anchor %.2f: POST %d (L%d/R%d)  CENTRE %d (L%d/R%d)"
				% [anchor, post["goals"], post["left"], post["right"],
				mid["goals"], mid["left"], mid["right"]])
	assert_true(true, "report")


# ── THE OTHER HALF OF THE TRADE: does the shallower retreat get him WALKED ───
# Every measurement above prices depth against the shot. Retreating is not for
# the shot — it is what keeps a goalie from being skated around for free, because
# a goalie standing further out has a longer arc to travel to stay in front of a
# puck dragged across him. So an anchor that buys angle has to be paid for here
# or it has only been checked against the half of the trade it helps.
#
# The move: drive the body straight in down the middle to `CUT_DIST`, then drag
# the puck across to the backhand side in 0.25 s (~3.6 m/s of real lateral puck
# travel, the pace a human plays it) with the body still coming straight on, and
# release from where the PUCK ended up — not where the body is.
const CUT_DIST: float = 3.5
const CUT_TO_X: float = -0.9
const CUT_S: float = 0.25
const CUT_S_FAST: float = 0.15


func _walkout_map(anchor: float, seconds: float) -> Dictionary:
	_ctrl._rush_cfg.depth_arrive = anchor
	var lofts: Array[int] = [
		ShotMechanics.ELEVATION_FLAT,
		ShotMechanics.ELEVATION_LOW,
		ShotMechanics.ELEVATION_HIGH,
	]
	var names: Array[String] = ["FLAT", "LOW ", "HIGH"]
	var start := Vector3(0.0, 0.0, GOAL_Z + START_DIST)
	var goals: int = 0
	var shots: int = 0
	var pose_x: float = 0.0
	var pose_depth: float = 0.0
	for li: int in lofts.size():
		var row: String = ""
		var a: float = -MAX_AIM
		while a <= MAX_AIM + 0.001:
			var best: String = "."
			for mph: float in SHOT_MPH:
				var speed: float = mph * MPH_TO_MS
				_h.settle_ready(start)
				_h.drive_in(0.0, START_DIST, CUT_DIST, DRIVE_SPEED)
				var rel: Vector3 = _h.sweep_across(CUT_TO_X, seconds, DRIVE_SPEED)
				pose_x += _ctrl._current_x
				pose_depth += _ctrl._current_depth
				var o: int = _h.fire_at(rel, Vector3(a, 0.0, GOAL_Z), lofts[li],
						speed, 0.0)
				shots += 1
				if o == Harness.GOAL:
					goals += 1
					best = "G"
				elif o == Harness.SAVE:
					best = "s" if best == "." else best
				elif best == ".":
					best = "x"
			row += best
			a += 0.07
		gut.p("     %s |%s|" % [names[li], row])
	var n: float = float(maxi(shots, 1))
	gut.p("     -> %d/%d (%.1f%%)  goalie x %+.3f radius %.3f at the release"
			% [goals, shots, 100.0 * float(goals) / n, pose_x / n, pose_depth / n])
	return {"goals": goals, "shots": shots}


func test_report_whether_the_shallower_retreat_gets_him_walked() -> void:
	gut.p("Straight drive to %.1f m, puck dragged to %+.2f in %.2f s, then fired."
			% [CUT_DIST, CUT_TO_X, CUT_S])
	for seconds: float in [CUT_S, CUT_S_FAST]:
		gut.p("  drag in %.2f s (%.1f m/s of lateral puck travel):"
				% [seconds, absf(CUT_TO_X) / seconds])
		for anchor: float in [0.10, 0.40]:
			gut.p("   retreat anchor %.2f:" % anchor)
			_walkout_map(anchor, seconds)
	assert_true(true, "report")


# The map, off the drive. Columns run post to post left→right; on the -x post
# lane the LEFT of each row is the short side.
func test_report_the_goal_map_off_a_post_lane_drive() -> void:
	gut.p("Cold release off the drive (no wind-up published).")
	# 6.5 m is swept on the wind-up arm only — that is the human mechanism, and
	# these maps are the most expensive thing in the suite.
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
	for dist: float in [6.5, 4.0, 2.5]:
		gut.p("  release %.1f m out, POST LANE:" % dist)
		_map(POST_LANE, dist, true)
		gut.p("  release %.1f m out, CENTRE LANE (control):" % dist)
		_map(0.0, dist, true)
	assert_true(true, "report")


# ── THE DEKE: the case the retreat exists for ────────────────────────────────
# The walkout above moves only the puck. That is the right shape for a
# forehand-backhand beat, and it is BLIND to the failure retreating is supposed
# to prevent — a carrier who skates across the crease face and past the goalie.
# With the body moving, `carrier.velocity.x` is finally non-zero, so the lateral
# tracking cap engages, the carrier lead swings the tracked threat, and the
# beaten-wide seal has a real drive to read. None of that fires in `_walkout_map`.
#
# Two paces, because a deke is bought out of the legs: the lateral component
# comes at the cost of the drive, so a wide fast cut is a slow approach. Forward
# pace drops to DEKE_FORWARD accordingly.
#
# `commit` is when he first dropped into a committed slide, and it is half the
# measurement — sealing late and never sealing are different failures and the
# goal count cannot tell them apart.
# THE SHAPE MATTERS, and the first one tried was the wrong one. Cutting from the
# centre lane out to x -1.00 puts the PUCK at -1.35 with its lead — outside the
# post — which is a walkout PAST him, not around him: the shot then has to cut
# back in past his pad edge, and it measured 17% of the aim space at both anchors
# (unmoved by the retreat, because the seal spot is a fixed geometric point).
# Real and worth knowing, but it is not the question.
#
# Skating AROUND him is a cross-crease cut: come down one post lane, take the body
# across the crease face, tuck on the other side. Driving from +NET_HALF_WIDTH to
# DEKE_TO_X is 1.47 m of body travel with the puck arriving at the far post — the
# move the retreat is supposed to keep him in front of.
const DEKE_FROM: float = 3.5
const DEKE_LANE: float = GameRules.NET_HALF_WIDTH
const DEKE_TO_X: float = -0.55
const DEKE_FORWARD: float = 3.0


func _deke_map(anchor: float, seconds: float) -> Dictionary:
	_ctrl._rush_cfg.depth_arrive = anchor
	var lofts: Array[int] = [
		ShotMechanics.ELEVATION_FLAT,
		ShotMechanics.ELEVATION_LOW,
		ShotMechanics.ELEVATION_HIGH,
	]
	var names: Array[String] = ["FLAT", "LOW ", "HIGH"]
	var start := Vector3(DEKE_LANE, 0.0, GOAL_Z + START_DIST)
	var goals: int = 0
	var shots: int = 0
	var pose_x: float = 0.0
	var pose_depth: float = 0.0
	var commits: int = 0
	var commit_s: float = 0.0
	var seal_x: float = 0.0
	var down: int = 0
	for li: int in lofts.size():
		var row: String = ""
		var a: float = -MAX_AIM
		while a <= MAX_AIM + 0.001:
			var best: String = "."
			for mph: float in SHOT_MPH:
				var speed: float = mph * MPH_TO_MS
				_h.settle_ready(start)
				_h.drive_in(DEKE_LANE, START_DIST, DEKE_FROM, DRIVE_SPEED)
				var rel: Vector3 = _h.deke_across(DEKE_TO_X, seconds, DEKE_FORWARD)
				pose_x += _ctrl._current_x
				pose_depth += _ctrl._current_depth
				if not is_inf(_h.last_deke_commit_s):
					commits += 1
					commit_s += _h.last_deke_commit_s
					seal_x += _ctrl._slide.end_x
				if _h.last_deke_went_down:
					down += 1
				var o: int = _h.fire_at(rel, Vector3(a, 0.0, GOAL_Z), lofts[li],
						speed, 0.0)
				shots += 1
				if o == Harness.GOAL:
					goals += 1
					best = "G"
				elif o == Harness.SAVE:
					best = "s" if best == "." else best
				elif best == ".":
					best = "x"
			row += best
			a += 0.07
		gut.p("     %s |%s|" % [names[li], row])
	var n: float = float(maxi(shots, 1))
	var mean_commit: String = "never" if commits == 0 \
			else "%.2f s on %d%%, aimed x %+.3f" % [commit_s / float(commits),
			int(round(100.0 * float(commits) / n)), seal_x / float(commits)]
	gut.p("     -> %d/%d (%.1f%%)  goalie x %+.3f radius %.3f  down %d%%  seal %s"
			% [goals, shots, 100.0 * float(goals) / n, pose_x / n, pose_depth / n,
			int(round(100.0 * float(down) / n)), mean_commit])
	return {"goals": goals, "shots": shots, "commits": commits}


func test_report_whether_the_deke_skates_around_him() -> void:
	gut.p("Drive the %+.2f lane to %.1f m, then CUT the body across to %+.2f."
			% [DEKE_LANE, DEKE_FROM, DEKE_TO_X])
	for seconds: float in [0.40, 0.25]:
		gut.p("  cut in %.2f s (%.1f m/s of body lateral):"
				% [seconds, absf(DEKE_TO_X - DEKE_LANE) / seconds])
		for anchor: float in [0.10, 0.40]:
			gut.p("   retreat anchor %.2f:" % anchor)
			_deke_map(anchor, seconds)
	assert_true(true, "report")
