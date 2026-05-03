extends GutTest

# AIActionScoring is pure-function. Tests cover the obvious geometric
# cases and the boundary conditions on shot geometry / pressure / lane.

const NET_HW: float = 0.915
const SHADOW_HW: float = 0.3
# Goal at +Z for these tests; shooter shoots toward +Z, goalie sits in front.
const GOAL := Vector3(0.0, 0.0, 26.65)


func test_shoot_score_high_in_slot_no_pressure() -> void:
	var shooter := Vector3(0.0, 0.0, 21.0)  # ~5.6 m from goal, in front
	var goalie := Vector3(0.7, 0.0, 26.0)   # well offset, leaves a big open side
	var s: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW, SHADOW_HW, [])
	assert_gt(s, 0.4, "open net + close + no pressure should score high (~0.5)")


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


func test_shoot_score_zero_when_defender_in_lane() -> void:
	# Phase 5g: a defender between the bot and the aim point should
	# block the shot, even if pressure (4 m radius) doesn't catch them.
	var shooter := Vector3(0.0, 0.0, 21.0)
	var goalie := Vector3(0.5, 0.0, 26.0)
	var clear: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW, SHADOW_HW, [])
	# Defender at z=24, between shooter (z=21) and net plane (z=26.65),
	# right on the bot→aim line and 5 m from the shooter — well past
	# pressure radius so they wouldn't otherwise count.
	var blocker: Array[Vector3] = [Vector3(-0.4, 0.0, 24.0)]
	var blocked: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW, SHADOW_HW, blocker)
	assert_gt(clear, 0.0)
	assert_lt(blocked, clear, "defender in shot lane should reduce shoot score")


func test_shoot_score_unaffected_by_defender_off_lane() -> void:
	var shooter := Vector3(0.0, 0.0, 21.0)
	var goalie := Vector3(0.5, 0.0, 26.0)
	var clear: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW, SHADOW_HW, [])
	# Defender to the far side, outside both pressure radius and shot lane.
	var off_lane: Array[Vector3] = [Vector3(8.0, 0.0, 24.0)]
	var s: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW, SHADOW_HW, off_lane)
	assert_almost_eq(s, clear, 0.001)


func test_pass_lateral_with_open_net_scores_high() -> void:
	# Phase 5e fix for "bots never pass side to side". Both shooter and
	# receiver are at the same depth (z=21), but the goalie covers the
	# shooter's angle. Receiver has wide-open net.
	var shooter := Vector3(3.0, 0.0, 21.0)   # angled shot — goalie can see them
	var receiver := Vector3(-3.0, 0.0, 21.0) # cross-slot — wide open
	var goalie := Vector3(2.5, 0.0, 26.0)    # shading the shooter's side
	var s: float = AIActionScoring.score_pass(shooter, receiver, Vector2.ZERO, GOAL, goalie, NET_HW, SHADOW_HW, [])
	assert_gt(s, 0.3, "lateral pass to a teammate with an open net should score well")


func test_pass_score_zero_when_lane_blocked() -> void:
	var shooter := Vector3(0.0, 0.0, 10.0)
	var receiver := Vector3(0.0, 0.0, 22.0)  # close to goal, would normally score
	var goalie := Vector3(0.5, 0.0, 26.0)
	var blocker: Array[Vector3] = [Vector3(0.0, 0.0, 16.0)]  # right on the line
	var s: float = AIActionScoring.score_pass(shooter, receiver, Vector2.ZERO, GOAL, goalie, NET_HW, SHADOW_HW, blocker)
	assert_eq(s, 0.0, "opponent on the pass line should zero the score")


func test_pass_lane_only_counts_opponents_between_endpoints() -> void:
	var shooter := Vector3(0.0, 0.0, 10.0)
	var receiver := Vector3(0.0, 0.0, 22.0)
	var goalie := Vector3(0.5, 0.0, 26.0)
	# Opponent BEHIND the shooter (z=5, before z=10) — shouldn't block
	var behind: Array[Vector3] = [Vector3(0.0, 0.0, 5.0)]
	var s: float = AIActionScoring.score_pass(shooter, receiver, Vector2.ZERO, GOAL, goalie, NET_HW, SHADOW_HW, behind)
	assert_gt(s, 0.0, "opponent behind the shooter shouldn't block the lane")


func test_pass_outlet_to_advanced_teammate_fires() -> void:
	# Phase 5h: bot deep in DZ, teammate at center ice. Receiver can't
	# shoot from there (too far for SHOT_RANGE_FALLOFF) but the pass
	# still scores via the advancement bonus.
	var shooter := Vector3(0.0, 0.0, -25.0)  # own zone, ~52 m from attacking goal at +Z
	var receiver := Vector3(0.0, 0.0, 0.0)   # center ice, ~27 m from goal
	var goalie := Vector3(0.0, 0.0, 26.0)
	var s: float = AIActionScoring.score_pass(shooter, receiver, Vector2.ZERO, GOAL, goalie, NET_HW, SHADOW_HW, [])
	assert_gt(s, AIActionScoring.ACTION_THRESHOLD, "outlet pass to a meaningfully advanced receiver should score above threshold")


func test_pass_open_man_fires_to_isolated_teammate() -> void:
	# Receiver is back near our own zone — no shot, no advancement
	# (carrier is FURTHER up-ice). Should still score via the open-man
	# term: receiver is wide open.
	var shooter := Vector3(0.0, 0.0, 5.0)    # carrier in NZ
	var receiver := Vector3(-4.0, 0.0, 0.0)  # back into NZ, ~5 m away laterally
	var receiver_facing := Vector2(0, 1)     # facing toward attacking goal (+Z)
	var goalie := Vector3(0.0, 0.0, 26.0)
	var s: float = AIActionScoring.score_pass(shooter, receiver, receiver_facing, GOAL, goalie, NET_HW, SHADOW_HW, [])
	assert_gt(s, AIActionScoring.ACTION_THRESHOLD,
			"open teammate should score above threshold on the open-man term alone")


func test_pass_open_man_fires_with_defender_only_behind_receiver() -> void:
	# Receiver facing +Z. Defender 2 m BEHIND them (at z=-2). The
	# open-man directional weighting zeroes the behind defender, so the
	# pass still clears threshold even though omni receiver-pressure
	# trims it slightly. Bot should still pass.
	var shooter := Vector3(0.0, 0.0, 5.0)
	var receiver := Vector3(0.0, 0.0, 0.0)
	var receiver_facing := Vector2(0, 1)
	var goalie := Vector3(0.0, 0.0, 26.0)
	var defender_behind: Array[Vector3] = [Vector3(0.0, 0.0, -2.0)]
	var s: float = AIActionScoring.score_pass(shooter, receiver, receiver_facing, GOAL, goalie, NET_HW, SHADOW_HW, defender_behind)
	assert_gt(s, AIActionScoring.ACTION_THRESHOLD,
			"defender only behind the receiver shouldn't kill the open-man pass")


func test_pass_open_man_drops_with_defender_in_front() -> void:
	# Defender 2 m in FRONT of the receiver, off-axis so the lane stays
	# partially open. Open-man collapses (defender is in the receiver's
	# forward cone), so the pass score should drop well below threshold
	# even though the lane is mostly clear.
	var shooter := Vector3(0.0, 0.0, 5.0)
	var receiver := Vector3(0.0, 0.0, 0.0)
	var receiver_facing := Vector2(0, 1)
	var goalie := Vector3(0.0, 0.0, 26.0)
	var defender_front: Array[Vector3] = [Vector3(0.5, 0.0, 2.0)]
	var s_pressured: float = AIActionScoring.score_pass(shooter, receiver, receiver_facing, GOAL, goalie, NET_HW, SHADOW_HW, defender_front)
	assert_lt(s_pressured, AIActionScoring.ACTION_THRESHOLD,
			"defender in front of receiver should drop open-man score below threshold")


func test_shoot_score_zero_from_behind_goal_line() -> void:
	# GOAL.z = +26.65; shooter past it (z=27) is behind the net.
	var shooter := Vector3(0.0, 0.0, 27.0)
	var goalie := Vector3(0.0, 0.0, 26.0)
	var s: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW, SHADOW_HW, [])
	assert_eq(s, 0.0, "shot from behind goal line should score 0")


func test_shoot_score_zero_at_extreme_angle() -> void:
	# Shooter way out on the boards, very close to goal-line z. From this
	# angle the visible net is a sliver — angle factor zeros it.
	# Forward = (22 - 26.65) * -signf(+26.65) = +4.65; lateral = 12.0;
	# angle = atan2(12, 4.65) ≈ 68.8° → in the soft ramp.
	# Push further out to clear SHOT_ANGLE_ZERO_DEG (80°):
	# lateral 12, forward 2 → angle ≈ 80.5°.
	var shooter := Vector3(12.0, 0.0, 24.65)  # 2 m in front of goal line, 12 m wide
	var goalie := Vector3(0.0, 0.0, 26.0)
	var s: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW, SHADOW_HW, [])
	assert_eq(s, 0.0, "shot from past 80° off-axis should score 0")


func test_shoot_score_partial_at_moderate_angle() -> void:
	# Shooter at 65° off-axis — inside the soft-ramp window between 50°
	# (full) and 80° (zero). Score should be > 0 but < a center shot.
	# lateral 8, forward ~5 → angle = atan2(8, 5) ≈ 58° → ramp factor
	# (80 - 58) / (80 - 50) ≈ 0.73.
	var shooter := Vector3(8.0, 0.0, 21.65)
	var goalie := Vector3(0.0, 0.0, 26.0)
	var center := Vector3(0.0, 0.0, 21.0)
	var s_angle: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW, SHADOW_HW, [])
	var s_center: float = AIActionScoring.score_shoot(center, GOAL, goalie, NET_HW, SHADOW_HW, [])
	assert_gt(s_angle, 0.0, "shot from 58° should still score above zero")
	assert_lt(s_angle, s_center, "shot from 58° should score lower than a center shot")


func test_pass_score_zero_to_receiver_behind_goal_line() -> void:
	var shooter := Vector3(0.0, 0.0, 20.0)
	var receiver := Vector3(0.0, 0.0, 28.0)  # past attacking goal line
	var goalie := Vector3(0.0, 0.0, 26.0)
	var s: float = AIActionScoring.score_pass(shooter, receiver, Vector2.ZERO, GOAL, goalie, NET_HW, SHADOW_HW, [])
	assert_eq(s, 0.0, "pass to receiver behind goal line should score 0")


func test_dump_score_zero_in_offensive_zone() -> void:
	# Team 1 (own_goal_dir = -1) in OZ: own_goal_dir * z < -BLUE_LINE_Z
	# means z > BLUE_LINE_Z. Bot at z=10 with attacking goal at +Z.
	var bot := Vector3(0.0, 0.0, 10.0)
	var attacking_goal := Vector3(0.0, 0.0, 26.65)
	var pressuring: Array[Vector3] = [Vector3(0.5, 0.0, 10.0), Vector3(-0.5, 0.0, 10.0)]
	var s: float = AIActionScoring.score_dump(bot, attacking_goal, -1.0, 7.29, pressuring)
	assert_eq(s, 0.0, "no dumping from the offensive zone")


func test_dump_score_high_in_own_zone_under_forward_pressure() -> void:
	# Team 1 in own zone (attacks +Z): opponents in FRONT of the bot
	# (between bot and attacking goal) read as real pressure.
	var bot := Vector3(0.0, 0.0, -15.0)
	var attacking_goal := Vector3(0.0, 0.0, 26.65)
	var pressure: Array[Vector3] = [
			Vector3(0.5, 0.0, -13.0),   # ahead and slightly +X
			Vector3(-0.5, 0.0, -13.0),  # ahead and slightly -X
			Vector3(0.0, 0.0, -12.0),   # directly ahead
	]
	var s: float = AIActionScoring.score_dump(bot, attacking_goal, -1.0, 7.29, pressure)
	# DZ dump caps at DUMP_OWN_ZONE_FACTOR (0.4) — heavy forward pressure
	# clears ACTION_THRESHOLD (0.25) so the bot will commit to a dump.
	assert_gt(s, AIActionScoring.ACTION_THRESHOLD,
			"blocked forward path in own zone should clear the action threshold")


func test_dump_score_low_when_pressure_is_only_behind() -> void:
	# Team 1 in own zone, opponents trailing behind (further from
	# attacking goal). Bot has open ice ahead — should NOT dump.
	var bot := Vector3(0.0, 0.0, -15.0)
	var attacking_goal := Vector3(0.0, 0.0, 26.65)
	var trailing: Array[Vector3] = [
			Vector3(0.5, 0.0, -17.0),
			Vector3(-0.5, 0.0, -17.0),
			Vector3(0.0, 0.0, -18.0),
	]
	var s: float = AIActionScoring.score_dump(bot, attacking_goal, -1.0, 7.29, trailing)
	assert_lt(s, 0.1, "trailing chasers shouldn't trigger a dump — open ice ahead")


func test_dump_score_zero_with_no_pressure() -> void:
	var bot := Vector3(0.0, 0.0, -15.0)
	var attacking_goal := Vector3(0.0, 0.0, 26.65)
	var s: float = AIActionScoring.score_dump(bot, attacking_goal, -1.0, 7.29, [])
	assert_eq(s, 0.0, "no pressure → no need to dump even from own zone")


func test_pass_score_falls_off_with_receiver_pressure() -> void:
	var shooter := Vector3(0.0, 0.0, 10.0)
	var receiver := Vector3(0.0, 0.0, 22.0)
	var goalie := Vector3(0.5, 0.0, 26.0)
	var clear: float = AIActionScoring.score_pass(shooter, receiver, Vector2.ZERO, GOAL, goalie, NET_HW, SHADOW_HW, [])
	# Opponent right on the receiver — pressure (not lane block, since
	# they're at the receiver's position not between).
	var checker: Array[Vector3] = [Vector3(0.5, 0.0, 22.0)]
	var pressured: float = AIActionScoring.score_pass(shooter, receiver, Vector2.ZERO, GOAL, goalie, NET_HW, SHADOW_HW, checker)
	assert_lt(pressured, clear)
