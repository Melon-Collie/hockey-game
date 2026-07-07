extends GutTest

# PenaltyShotRules — pure outcome classification for a penalty-shot attempt.
# These pin the NHL Rule 24.2 behaviour the drill depends on: a goal only counts
# inside the posts and under the bar, the attempt dies when the puck stops or
# goes backward, and a puck across the line wide/high is a miss (no rebounds).

const GOAL_LINE_Z: float = -26.65   # team 0 attacks toward -Z
const ATTACK_DIR: float = -1.0
const HALF_WIDTH: float = 0.915


func _cfg() -> PenaltyShotRules.Config:
	return PenaltyShotRules.Config.new()


# ── forward_progress ──────────────────────────────────────────────────────────

func test_forward_progress_grows_toward_net() -> void:
	# Starting at centre (z=0), advancing toward -Z increases progress.
	assert_almost_eq(PenaltyShotRules.forward_progress(-5.0, 0.0, ATTACK_DIR), 5.0, 0.001)


func test_forward_progress_negative_when_retreating() -> void:
	# Past the start, back toward +Z = negative progress.
	assert_almost_eq(PenaltyShotRules.forward_progress(2.0, 0.0, ATTACK_DIR), -2.0, 0.001)


func test_forward_progress_positive_attack_dir() -> void:
	assert_almost_eq(PenaltyShotRules.forward_progress(5.0, 0.0, 1.0), 5.0, 0.001)


# ── is_goal ───────────────────────────────────────────────────────────────────

func test_is_goal_true_inside_posts_under_bar() -> void:
	assert_true(PenaltyShotRules.is_goal(0.0, 0.4, -27.0, GOAL_LINE_Z, ATTACK_DIR, HALF_WIDTH, 1.22))


func test_is_goal_false_before_line() -> void:
	assert_false(PenaltyShotRules.is_goal(0.0, 0.4, -26.0, GOAL_LINE_Z, ATTACK_DIR, HALF_WIDTH, 1.22))


func test_is_goal_false_wide_of_post() -> void:
	assert_false(PenaltyShotRules.is_goal(1.5, 0.4, -27.0, GOAL_LINE_Z, ATTACK_DIR, HALF_WIDTH, 1.22))


func test_is_goal_false_over_crossbar() -> void:
	assert_false(PenaltyShotRules.is_goal(0.0, 1.5, -27.0, GOAL_LINE_Z, ATTACK_DIR, HALF_WIDTH, 1.22))


func test_is_goal_false_on_a_post_graze() -> void:
	# x = 0.90 is inside the post centerline (0.915) but the disc is on the pipe —
	# not a goal, same shared mouth as live play (GoalDetectionRules.point_in_mouth).
	assert_false(PenaltyShotRules.is_goal(0.90, 0.4, -27.0, GOAL_LINE_Z, ATTACK_DIR, HALF_WIDTH, 1.22))


# ── classify ──────────────────────────────────────────────────────────────────

func test_classify_live_while_skating_in() -> void:
	# Mid-rush, well shy of the net, moving forward: still live.
	var o: PenaltyShotRules.Outcome = PenaltyShotRules.classify(
			0.0, 0.05, -10.0, 6.0, 10.0, 10.0, true, 0.0, 5.0,
			ATTACK_DIR, GOAL_LINE_Z, HALF_WIDTH, _cfg())
	assert_eq(o, PenaltyShotRules.Outcome.LIVE)


func test_classify_goal_beats_every_other_rule() -> void:
	# Even if it would otherwise read as stalled, a puck in the net is a goal.
	var o: PenaltyShotRules.Outcome = PenaltyShotRules.classify(
			0.0, 0.3, -27.0, 0.0, 27.0, 27.0, true, 5.0, 5.0,
			ATTACK_DIR, GOAL_LINE_Z, HALF_WIDTH, _cfg())
	assert_eq(o, PenaltyShotRules.Outcome.GOAL)


func test_classify_miss_when_crossing_line_wide() -> void:
	var o: PenaltyShotRules.Outcome = PenaltyShotRules.classify(
			1.6, 0.3, -27.0, 8.0, 27.0, 27.0, true, 0.0, 5.0,
			ATTACK_DIR, GOAL_LINE_Z, HALF_WIDTH, _cfg())
	assert_eq(o, PenaltyShotRules.Outcome.MISS, "across the line but wide is a miss")


func test_classify_miss_when_stalled_long_enough() -> void:
	# Lost momentum: stopped past the stall grace, and past the running-start
	# grace → dead.
	var o: PenaltyShotRules.Outcome = PenaltyShotRules.classify(
			0.0, 0.05, -12.0, 0.1, 12.0, 12.0, true, 0.6, 5.0,
			ATTACK_DIR, GOAL_LINE_Z, HALF_WIDTH, _cfg())
	assert_eq(o, PenaltyShotRules.Outcome.MISS)


func test_classify_live_when_briefly_stopped_within_grace() -> void:
	# Stopped, but not yet past the stall grace: still live.
	var o: PenaltyShotRules.Outcome = PenaltyShotRules.classify(
			0.0, 0.05, -12.0, 0.1, 12.0, 12.0, true, 0.1, 5.0,
			ATTACK_DIR, GOAL_LINE_Z, HALF_WIDTH, _cfg())
	assert_eq(o, PenaltyShotRules.Outcome.LIVE)


func test_classify_live_when_stalled_but_within_running_start_grace() -> void:
	# Fully stopped past the stall grace, but still inside the running-start
	# window: the shooter is building speed off the mark, so the attempt lives.
	var o: PenaltyShotRules.Outcome = PenaltyShotRules.classify(
			0.0, 0.05, -1.0, 0.0, 1.0, 1.0, true, 1.0, 0.3,
			ATTACK_DIR, GOAL_LINE_Z, HALF_WIDTH, _cfg())
	assert_eq(o, PenaltyShotRules.Outcome.LIVE)


func test_classify_miss_when_going_backward() -> void:
	# Retreated more than backward_tolerance from the furthest point reached.
	var o: PenaltyShotRules.Outcome = PenaltyShotRules.classify(
			0.0, 0.05, -11.0, 4.0, 11.0, 12.0, true, 0.0, 5.0,
			ATTACK_DIR, GOAL_LINE_Z, HALF_WIDTH, _cfg())
	assert_eq(o, PenaltyShotRules.Outcome.MISS, "1.0 m retreat past a 0.75 m tolerance is dead")


func test_classify_live_for_small_dip_within_backward_tolerance() -> void:
	# A 0.5 m dip (lateral dangle wobble) under the 0.75 m tolerance stays live.
	var o: PenaltyShotRules.Outcome = PenaltyShotRules.classify(
			0.0, 0.05, -11.5, 4.0, 11.5, 12.0, true, 0.0, 5.0,
			ATTACK_DIR, GOAL_LINE_Z, HALF_WIDTH, _cfg())
	assert_eq(o, PenaltyShotRules.Outcome.LIVE)


func test_classify_live_before_rush_starts_even_at_rest() -> void:
	# Puck sitting at centre on the stick before the rush: dead-puck rules don't
	# arm until `started`, so a standstill here is not a miss.
	var o: PenaltyShotRules.Outcome = PenaltyShotRules.classify(
			0.0, 0.05, 0.0, 0.0, 0.0, 0.0, false, 1.0, 0.0,
			ATTACK_DIR, GOAL_LINE_Z, HALF_WIDTH, _cfg())
	assert_eq(o, PenaltyShotRules.Outcome.LIVE)
