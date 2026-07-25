extends GutTest

# Pins the TIE between the live goalie's depth and every model that predicts it.
#
# There are three consumers of "where will the keeper be standing?":
#   1. GoalieController          — the live goalie (integrates toward the target)
#   2. AIActionScoring           — the bot planner's keeper (shot/pass/carry EV)
#   3. shot_sim_harness          — the lateral-reach BAND instrument score_shoot
#                                  is calibrated against
#
# All three now go through GoalieDepthSolver. They did not always: the planner and
# the band instrument each carried their own copy of the retired Buckley distance
# chart, so when depth became a solve they were predicting a keeper who no longer
# existed — the planner would have under-valued in-tight shots (it thought he was
# 0.35 m further out than he is at 2 m). Nothing failed, because a duplicated
# constant does not fail, it just quietly lies.
#
# These tests are the thing that WILL fail next time.

const Harness := preload("res://tests/unit/ai/real_goalie_shot_harness.gd")
const ShotSim := preload("res://tests/unit/ai/shot_sim_harness.gd")
const GOAL_Z: float = -GameRules.GOAL_LINE_Z
const SETTLE_TICKS: int = 240

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


# The live goalie's settled depth against a stationary, unpressured threat — the
# case all three models agree they are describing.
func _live_settled(threat_dist: float) -> float:
	_ctrl.reset_to_crease()
	_h.settle(Vector3(0.0, 0.0, GOAL_Z + threat_dist), SETTLE_TICKS)
	return _ctrl._current_depth


func test_the_band_instrument_matches_the_live_goalie() -> void:
	# shot_sim_harness.goalie_set_pos drives score_shoot's calibration. If it and
	# the live keeper disagree, the bots are tuned against a fiction.
	var goal := Vector3(0.0, 0.0, GOAL_Z)
	for d: float in [1.5, 2.0, 3.0, 5.0, 8.0]:
		var shooter := Vector3(0.0, 0.0, GOAL_Z + d)
		var band: Vector3 = ShotSim.goalie_set_pos(shooter, goal)
		var band_depth: float = absf(band.z - GOAL_Z)
		var live: float = _live_settled(d)
		gut.p("threat %.1f m: live %.2f  band %.2f" % [d, live, band_depth])
		assert_almost_eq(band_depth, live, 0.03,
				"the band instrument must model the depth the live goalie actually holds (%.1f m)" % d)


func test_the_planner_matches_the_live_goalie_on_a_static_read() -> void:
	# planned_goalie_depth is RETREAT-ONLY by design: it never challenges the
	# keeper out, because his live depth is replicated truth the planner cannot
	# fully see. So feed it a keeper already AT the live depth and it must leave
	# him there — if it disagrees, the planner is mispricing every settled look.
	var goal := Vector3(0.0, 0.0, GOAL_Z)
	for d: float in [1.5, 2.0, 3.0, 5.0, 8.0]:
		var live: float = _live_settled(d)
		var keeper := Vector3(0.0, 0.0, GOAL_Z + live)
		var release := Vector3(0.0, 0.0, GOAL_Z + d)
		var planned: float = AIActionScoring.planned_goalie_depth(
				keeper, goal, release, 0.25, 0.0)
		gut.p("threat %.1f m: live %.2f  planned %.2f" % [d, live, planned])
		assert_almost_eq(planned, live, 0.03,
				"a static read must leave the keeper at the depth he actually holds (%.1f m)" % d)


func test_the_planner_still_retreats_him_on_an_approach() -> void:
	# The retreat-only correction must survive the tie — this is the behaviour the
	# depth model was added to the planner FOR (bots refused to drive the net
	# against a keeper frozen at challenge depth).
	var goal := Vector3(0.0, 0.0, GOAL_Z)
	var keeper := Vector3(0.0, 0.0, GOAL_Z + 1.75)
	var close_release := Vector3(0.0, 0.0, GOAL_Z + 2.5)
	var closing: float = AIActionScoring.planned_goalie_depth(
			keeper, goal, close_release, 0.4, 6.0)
	assert_lt(closing, 1.75,
			"a closing rush must still back the planned keeper in")


func test_the_standoff_reaches_the_planner() -> void:
	# The in-tight case specifically, since that is where the old chart and the
	# solve disagree most (1.75 vs 1.40 at 2 m). A keeper sitting out at the
	# ceiling with the puck 2 m away is not a state the live goalie can be in.
	var goal := Vector3(0.0, 0.0, GOAL_Z)
	var keeper := Vector3(0.0, 0.0, GOAL_Z + 1.75)
	var release := Vector3(0.0, 0.0, GOAL_Z + 2.0)
	var planned: float = AIActionScoring.planned_goalie_depth(
			keeper, goal, release, 0.3, 0.0)
	assert_true(planned <= 2.0 - AIActionScoring.GOALIE_CHALLENGE_STANDOFF_M + 0.01,
			"the planner must respect the standoff the live keeper keeps (got %.2f)" % planned)


# ── The DYNAMIC tie ──────────────────────────────────────────────────────────
# Matching on a settled read is the easy half. What the planner is actually FOR
# is predicting where the keeper will be `time_s` from now, and there the two can
# only ever agree approximately — the planner is a closed-form solve, the live
# goalie is an integrator with tracking lag. These pin how far apart they may get,
# and in which DIRECTION.

const PLAN_S: float = 0.30
const PLAN_TICKS: int = 36        # PLAN_S at 120 Hz


# Step the live goalie for `ticks` with a carrier at `at` skating at `vel`.
func _step(at: Vector3, vel: Vector3, ticks: int) -> void:
	var p: Vector3 = at
	_shooter.velocity = vel
	for _i: int in ticks:
		_shooter.global_position = p
		_puck.global_position = p
		_puck.linear_velocity = Vector3.ZERO
		_ctrl._physics_process(1.0 / 120.0)
		p += vel * (1.0 / 120.0)


func test_the_planner_tracks_a_live_rush() -> void:
	# The case the depth model was added to the planner FOR. A carrier closing at
	# 6 m/s drives the speed-matched backflow; the planner has to land on the same
	# retreat the live keeper actually skates, or bots misprice the drive.
	var goal := Vector3(0.0, 0.0, GOAL_Z)
	for start: float in [3.0, 5.0, 8.0, 11.0]:
		_ctrl.reset_to_crease()
		_h.settle(Vector3(0.0, 0.0, GOAL_Z + start), SETTLE_TICKS)
		var keeper := Vector3(0.0, 0.0, GOAL_Z + _ctrl._current_depth)
		# puck_pos_at_release is where the puck will be AT release, not now.
		var release := Vector3(0.0, 0.0, GOAL_Z + start - 6.0 * PLAN_S)
		var planned: float = AIActionScoring.planned_goalie_depth(
				keeper, goal, release, PLAN_S, 6.0)
		_step(Vector3(0.0, 0.0, GOAL_Z + start), Vector3(0.0, 0.0, -6.0), PLAN_TICKS)
		var live: float = _ctrl._current_depth
		gut.p("rush from %.0f m: live %.2f  planned %.2f  (%+.2f)"
				% [start, live, planned, planned - live])
		assert_almost_eq(planned, live, 0.20,
				"the planned retreat must track the one the keeper skates (from %.0f m)" % start)


func test_the_planner_never_over_states_the_keeper() -> void:
	# THE one-sided safety property, and the reason planned_goalie_depth is
	# retreat-only rather than a full re-solve.
	#
	# Coverage is a tangent cone off the keeper's body, so a keeper modelled too far
	# OUT subtends a wider cone than the real one — the net reads more covered than
	# it is, every shot and drive prices worse than it should, and the compete falls
	# through to the back pass. That is exactly the refuse-to-drive bug the planning
	# depth model was added to fix, and re-introducing it by mis-prediction is the
	# failure mode worth a test.
	#
	# The opposite error (modelling him too deep) costs a shot that gets saved —
	# real, but self-correcting and far less visible than bots that will not attack.
	# So the planner is allowed to run deep and is NOT allowed to run out.
	#
	# The clamp's cost shows up here as the relocation cases: when the puck moves
	# AWAY from a keeper who is currently deep he challenges back out, and the
	# planner holds him where he was. Bounded by his skating rate, and on the safe
	# side of the asymmetry above.
	var goal := Vector3(0.0, 0.0, GOAL_Z)
	var worst: float = -INF
	for from_d: float in [1.5, 2.0, 3.0, 5.0, 8.0]:
		for to_d: float in [1.5, 2.0, 3.0, 5.0, 8.0]:
			_ctrl.reset_to_crease()
			_h.settle(Vector3(0.0, 0.0, GOAL_Z + from_d), SETTLE_TICKS)
			var keeper := Vector3(0.0, 0.0, GOAL_Z + _ctrl._current_depth)
			var release := Vector3(0.0, 0.0, GOAL_Z + to_d)
			var planned: float = AIActionScoring.planned_goalie_depth(
					keeper, goal, release, PLAN_S, 0.0)
			_step(Vector3(0.0, 0.0, GOAL_Z + to_d), Vector3.ZERO, PLAN_TICKS)
			worst = maxf(worst, planned - _ctrl._current_depth)
	gut.p("worst over-statement across the relocation grid: %+.3f m" % worst)
	assert_true(worst <= 0.10,
			("the planner must never model the keeper materially further OUT than he "
			+ "will be — that is the bug that stops bots attacking (worst %+.2f m)") % worst)
