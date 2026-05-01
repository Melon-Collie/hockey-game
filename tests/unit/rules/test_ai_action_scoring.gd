extends GutTest

# AIActionScoring is pure-function. Tests cover the obvious geometric
# cases and the boundary conditions on advancement / pressure.

const NET_HW: float = 0.915
const SHADOW_HW: float = 0.3
# Goal at +Z for these tests; shooter shoots toward +Z, goalie sits in front.
const GOAL := Vector3(0.0, 0.0, 26.65)


func test_shoot_score_high_in_slot_no_pressure() -> void:
	var shooter := Vector3(0.0, 0.0, 21.0)  # ~5.6 m from goal, in front
	var goalie := Vector3(0.5, 0.0, 26.0)   # offset to one side → big open arc
	var s: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW, SHADOW_HW, [])
	assert_gt(s, 0.5, "open net + close + no pressure should score high")


func test_shoot_score_zero_at_long_range() -> void:
	var shooter := Vector3(0.0, 0.0, -5.0)  # ~32 m from goal — way past falloff
	var goalie := Vector3(0.0, 0.0, 26.0)
	var s: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW, SHADOW_HW, [])
	assert_eq(s, 0.0, "shots from beyond SHOT_RANGE_FALLOFF_M should score 0")


func test_shoot_score_falls_off_with_pressure() -> void:
	var shooter := Vector3(0.0, 0.0, 21.0)
	var goalie := Vector3(0.5, 0.0, 26.0)
	var clear: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW, SHADOW_HW, [])
	var nearby_opp: Array[Vector3] = [Vector3(1.0, 0.0, 21.0)]  # 1m away
	var pressured: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW, SHADOW_HW, nearby_opp)
	assert_lt(pressured, clear, "opponent within pressure radius should reduce shoot score")


func test_pass_score_zero_for_marginal_advancement() -> void:
	# Receiver only 2m closer to goal — under PASS_MIN_ADVANTAGE_M
	var shooter := Vector3(0.0, 0.0, 10.0)
	var receiver := Vector3(0.0, 0.0, 12.0)
	var s: float = AIActionScoring.score_pass(shooter, receiver, GOAL, [])
	assert_eq(s, 0.0)


func test_pass_score_positive_for_clear_advancement() -> void:
	var shooter := Vector3(0.0, 0.0, 10.0)
	var receiver := Vector3(0.0, 0.0, 18.0)  # 8 m closer to goal
	var s: float = AIActionScoring.score_pass(shooter, receiver, GOAL, [])
	assert_gt(s, 0.0, "8 m advancement should score above zero")


func test_pass_score_falls_off_with_receiver_pressure() -> void:
	var shooter := Vector3(0.0, 0.0, 10.0)
	var receiver := Vector3(0.0, 0.0, 18.0)
	var clear: float = AIActionScoring.score_pass(shooter, receiver, GOAL, [])
	var checked: Array[Vector3] = [Vector3(0.5, 0.0, 18.0)]  # opponent on the receiver
	var pressured: float = AIActionScoring.score_pass(shooter, receiver, GOAL, checked)
	assert_lt(pressured, clear)
