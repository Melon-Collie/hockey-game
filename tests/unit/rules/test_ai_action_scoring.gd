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
	# Defender 2 m sideways AND 2 m forward (toward goal): inside the
	# forward cone (≈45° offset, dot ≈ 0.71) and inside the pressure
	# radius. Far enough off the shot lane that lane_clear stays at 1.0,
	# so we're testing pressure in isolation.
	var nearby_opp: Array[Vector3] = [Vector3(2.0, 0.0, 23.0)]
	var pressured: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW, SHADOW_HW, nearby_opp)
	assert_lt(pressured, clear, "opponent in the forward pressure cone should reduce shoot score")


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
	# Receiver facing +Z. Defender 2 m BEHIND them (at z=-2). Both the
	# open-man directional weighting AND the receiver-pressure cube
	# falloff zero a behind-receiver defender — the pass clears
	# threshold cleanly.
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
	# Defender 2 m past the receiver (toward the attacking goal) and
	# 0.5 m off-axis — inside the receiver's forward pressure cone but
	# past the shooter→receiver segment so lane_clear isn't triggered.
	var checker: Array[Vector3] = [Vector3(0.5, 0.0, 24.0)]
	var pressured: float = AIActionScoring.score_pass(shooter, receiver, Vector2.ZERO, GOAL, goalie, NET_HW, SHADOW_HW, checker)
	assert_lt(pressured, clear)


# Behavior pass A #5 — NZ-specific clear-path suppression.

func test_dump_score_suppressed_in_nz_with_clear_forward_path() -> void:
	# Team 1 (own_goal_dir=-1, attacks +Z) carrying through the NZ at z=0
	# with side-and-behind pressure but nothing in front. Controlled
	# entry beats dump in 3v3 — score must drop below ACTION_THRESHOLD.
	var bot := Vector3(0.0, 0.0, 0.0)
	var attacking_goal := Vector3(0.0, 0.0, 26.65)
	var side_and_behind: Array[Vector3] = [
			Vector3(2.0, 0.0, 0.0),    # right beside (perpendicular)
			Vector3(-2.0, 0.0, 0.0),   # left beside
			Vector3(0.0, 0.0, -2.0),   # directly behind (toward own goal)
	]
	var s: float = AIActionScoring.score_dump(bot, attacking_goal, -1.0, 7.29, side_and_behind)
	assert_lt(s, AIActionScoring.ACTION_THRESHOLD,
			"NZ dump with open ice ahead should not clear ACTION_THRESHOLD")


func test_dump_score_fires_in_nz_when_forward_path_blocked() -> void:
	# Same NZ position as above, but now with a wall of defenders ahead
	# inside the clear-path radius. Suppression should NOT trigger.
	var bot := Vector3(0.0, 0.0, 0.0)
	var attacking_goal := Vector3(0.0, 0.0, 26.65)
	var wall_ahead: Array[Vector3] = [
			Vector3(0.0, 0.0, 2.0),    # directly ahead (toward attacking goal)
			Vector3(1.5, 0.0, 1.5),    # forward-right
			Vector3(-1.5, 0.0, 1.5),   # forward-left
	]
	var s: float = AIActionScoring.score_dump(bot, attacking_goal, -1.0, 7.29, wall_ahead)
	assert_gt(s, AIActionScoring.ACTION_THRESHOLD,
			"NZ dump with a wall of defenders ahead should still clear threshold")


# Pressure cube-falloff sanity checks. The directional formula zeros
# opponents behind and beside the play, so shoot/pass scoring no
# longer counts defenders who can't realistically disrupt the action.

func test_shoot_pressure_ignores_defender_behind_shooter() -> void:
	var shooter := Vector3(0.0, 0.0, 21.0)
	var goalie := Vector3(0.5, 0.0, 26.0)
	var clean: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW, SHADOW_HW, [])
	# Defender 2 m behind shooter (between shooter and own net).
	var behind: Array[Vector3] = [Vector3(0.5, 0.0, 19.0)]
	var pressured: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW, SHADOW_HW, behind)
	assert_almost_eq(pressured, clean, 0.001,
			"defender behind the shooter should not pressure the shot")


func test_shoot_pressure_ignores_perpendicular_defender() -> void:
	var shooter := Vector3(0.0, 0.0, 21.0)
	var goalie := Vector3(0.5, 0.0, 26.0)
	var clean: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW, SHADOW_HW, [])
	# Defender 2 m sideways at the same depth — directly perpendicular
	# to the shooter→goal axis. Cube weight = 0 (dot = 0).
	var perp: Array[Vector3] = [Vector3(2.0, 0.0, 21.0)]
	var pressured: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW, SHADOW_HW, perp)
	assert_almost_eq(pressured, clean, 0.001,
			"perpendicular defender should not pressure the shot")


func test_pass_receiver_pressure_ignores_defender_behind_receiver() -> void:
	var shooter := Vector3(0.0, 0.0, 10.0)
	var receiver := Vector3(0.0, 0.0, 18.0)
	var goalie := Vector3(0.0, 0.0, 26.0)
	var clean: float = AIActionScoring.score_pass(shooter, receiver, Vector2.ZERO, GOAL, goalie, NET_HW, SHADOW_HW, [])
	# Defender 2 m lateral and 1.5 m behind the receiver (toward the
	# shooter side). Within PRESSURE_RADIUS_M (2.5 m), but the cube
	# falloff sees a negative dot relative to receiver→goal forward
	# axis and weights it 0. Lane perp distance is also outside
	# LANE_CLEAR_RADIUS_M, so neither pressure nor lane block fires.
	var lateral_behind: Array[Vector3] = [Vector3(2.0, 0.0, 16.5)]
	var pressured: float = AIActionScoring.score_pass(shooter, receiver, Vector2.ZERO, GOAL, goalie, NET_HW, SHADOW_HW, lateral_behind)
	assert_almost_eq(pressured, clean, 0.001,
			"defender behind the receiver should not pressure the pass (cube falloff zeros it)")


# pass_lane_blocked_by_net coverage. Nets are at z = ±GameRules.GOAL_LINE_Z
# extending out by GameRules.NET_DEPTH; opening half-width NET_HW.

func test_net_blocker_oz_corner_to_corner_through_back_of_net() -> void:
	# Bot in attacking-zone right corner just inside the net depth,
	# teammate mirrored on the left. Pass goes through the net rect.
	var from := Vector3(5.0, 0.0, 27.0)   # inside net z-range
	var to := Vector3(-5.0, 0.0, 27.0)
	assert_true(AIActionScoring.pass_lane_blocked_by_net(from, to),
			"corner-to-corner pass through the back of the net should be blocked")


func test_net_blocker_dz_pass_across_goal_mouth() -> void:
	# Pass crossing in front of the goal at the goal-line z. Just clipping
	# the front face of the net rect.
	var from := Vector3(3.0, 0.0, 28.0)   # behind own net
	var to := Vector3(-3.0, 0.0, 25.0)    # front of own net
	assert_true(AIActionScoring.pass_lane_blocked_by_net(from, to),
			"pass crossing the goal mouth at goal-line z should be blocked by the net")


func test_net_blocker_clean_slot_pass_not_blocked() -> void:
	# Pass through the slot (well in front of the goal line). Both
	# endpoints in front of GOAL_LINE_Z, segment never enters either rect.
	var from := Vector3(5.0, 0.0, 18.0)
	var to := Vector3(-5.0, 0.0, 18.0)
	assert_false(AIActionScoring.pass_lane_blocked_by_net(from, to),
			"slot-line pass nowhere near the net should not be blocked")


func test_net_blocker_low_to_high_pass_not_blocked() -> void:
	# OZ low-to-high: from near the goal line up to the blue line.
	# Segment never enters the rect because x stays inside one corner
	# but z exits the rect cleanly toward NZ.
	var from := Vector3(5.0, 0.0, 25.5)   # in front of goal line, off to side
	var to := Vector3(0.0, 0.0, 12.0)
	assert_false(AIActionScoring.pass_lane_blocked_by_net(from, to),
			"low-to-high OZ pass should not be blocked by the attacking net")


func test_score_pass_zero_when_segment_crosses_net() -> void:
	var shooter := Vector3(5.0, 0.0, 27.0)
	var receiver := Vector3(-5.0, 0.0, 27.0)
	var goalie := Vector3(0.0, 0.0, -25.0)
	# Far-side goal so receiver isn't past attacking goal line.
	var attacking_goal := Vector3(0.0, 0.0, -26.65)
	var s: float = AIActionScoring.score_pass(
			shooter, receiver, Vector2.ZERO, attacking_goal, goalie,
			NET_HW, SHADOW_HW, [])
	assert_almost_eq(s, 0.0, 0.001,
			"score_pass returns zero when the segment crosses a net rect")


# pass_crosses_own_slot — own-DZ slot danger filter.

func test_own_slot_pass_blocked_team0() -> void:
	# Cross-crease slot pass for team 0 (own goal at +z=26.65). Segment
	# at z=22 (slot depth) crossing x=0 → blocked.
	var from := Vector3(3.0, 0.0, 22.0)
	var to := Vector3(-3.0, 0.0, 22.0)
	assert_true(AIActionScoring.pass_crosses_own_slot(from, to, GOAL.z))


func test_own_slot_pass_blocked_team1() -> void:
	# Mirror — team 1 (own goal at -z).
	var from := Vector3(3.0, 0.0, -22.0)
	var to := Vector3(-3.0, 0.0, -22.0)
	assert_true(AIActionScoring.pass_crosses_own_slot(from, to, -GOAL.z))


func test_pass_outside_own_slot_not_blocked() -> void:
	# Pass in NZ — well in front of slot rect. Not blocked.
	var from := Vector3(3.0, 0.0, 5.0)
	var to := Vector3(-3.0, 0.0, 5.0)
	assert_false(AIActionScoring.pass_crosses_own_slot(from, to, GOAL.z))


func test_breakout_pass_not_blocked() -> void:
	# Pass from corner up-ice (DZ → NZ). Segment doesn't cross the
	# slot rect because z exits the slot range before x enters.
	var from := Vector3(8.0, 0.0, 24.0)   # corner near boards
	var to := Vector3(0.0, 0.0, 5.0)      # mid-NZ
	assert_false(AIActionScoring.pass_crosses_own_slot(from, to, GOAL.z))
