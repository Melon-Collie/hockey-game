extends GutTest

# TutorialShotRules — pure detection for the Shooting tutorial. These pin the
# success criteria the drills depend on: a goal only counts inside the posts and
# past the line, a target only clears when the puck crosses within its radius,
# and a quick tap doesn't satisfy the "charged wrist shot" drill.

const GOAL_LINE_Z: float = -26.65   # team 0 attacks toward -Z
const ATTACK_DIR: float = -1.0
const HALF_WIDTH: float = 0.915


func test_crossed_goal_line_true_past_line_inside_posts() -> void:
	assert_true(TutorialShotRules.crossed_goal_line(
			0.0, -27.0, GOAL_LINE_Z, ATTACK_DIR, HALF_WIDTH))


func test_crossed_goal_line_false_before_line() -> void:
	assert_false(TutorialShotRules.crossed_goal_line(
			0.0, -26.0, GOAL_LINE_Z, ATTACK_DIR, HALF_WIDTH))


func test_crossed_goal_line_false_wide_of_post() -> void:
	assert_false(TutorialShotRules.crossed_goal_line(
			1.5, -27.0, GOAL_LINE_Z, ATTACK_DIR, HALF_WIDTH),
			"a puck wide of the posts is not a goal even if past the line")


func test_crossed_goal_line_handles_positive_attack_dir() -> void:
	# Sanity: the helper is direction-agnostic for the +Z net too.
	assert_true(TutorialShotRules.crossed_goal_line(
			0.0, 27.0, 26.65, 1.0, HALF_WIDTH))
	assert_false(TutorialShotRules.crossed_goal_line(
			0.0, 26.0, 26.65, 1.0, HALF_WIDTH))


func test_nearest_target_returns_index_within_radius() -> void:
	var targets: Array[Vector2] = [Vector2(-0.62, 0.30), Vector2(0.0, 0.30), Vector2(0.62, 0.30)]
	assert_eq(TutorialShotRules.nearest_target(0.60, 0.32, targets, 0.33), 2)


func test_nearest_target_picks_closest_of_several() -> void:
	var targets: Array[Vector2] = [Vector2(-0.62, 0.95), Vector2(0.62, 0.95)]
	assert_eq(TutorialShotRules.nearest_target(-0.55, 0.90, targets, 0.40), 0)


func test_nearest_target_miss_returns_minus_one() -> void:
	var targets: Array[Vector2] = [Vector2(-0.62, 0.30), Vector2(0.62, 0.30)]
	assert_eq(TutorialShotRules.nearest_target(0.0, 0.30, targets, 0.33), -1,
			"a crossing between two targets, outside both radii, clears nothing")


func test_is_dragged_wrister_true_past_threshold() -> void:
	assert_true(TutorialShotRules.is_dragged_wrister(0.20, 0.15))


func test_is_dragged_wrister_false_for_tap() -> void:
	assert_false(TutorialShotRules.is_dragged_wrister(0.05, 0.15),
			"a sub-threshold drag is a quick tap, not a wrist shot")
