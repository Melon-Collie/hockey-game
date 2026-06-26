extends GutTest

# AIActionScoring is pure-function. Tests cover the obvious geometric
# cases and the boundary conditions on shot geometry / pressure / lane.

const NET_HW: float = 0.915
# Goal at +Z for these tests; shooter shoots toward +Z, goalie sits in front.
const GOAL := Vector3(0.0, 0.0, 26.65)


func test_shoot_score_high_in_slot_no_pressure() -> void:
	var shooter := Vector3(0.0, 0.0, 21.0)  # ~5.6 m from goal, in front
	var goalie := Vector3(0.7, 0.0, 26.0)   # well offset, leaves a big open side
	var s: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW,[])
	assert_gt(s, 0.4, "open net + close + no pressure should score high (~0.5)")


func test_shoot_score_zero_at_long_range() -> void:
	var shooter := Vector3(0.0, 0.0, -5.0)  # ~32 m from goal — way past falloff
	var goalie := Vector3(0.0, 0.0, 26.0)
	var s: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW,[])
	assert_eq(s, 0.0, "shots from beyond SHOT_RANGE_FALLOFF_M should score 0")


func test_shoot_score_falls_off_with_pressure() -> void:
	var shooter := Vector3(0.0, 0.0, 21.0)
	var goalie := Vector3(0.5, 0.0, 26.0)
	var clear: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW,[])
	# Defender 2 m sideways AND 2 m forward (toward goal): inside the
	# forward cone (≈45° offset, dot ≈ 0.71) and inside the pressure
	# radius. Far enough off the shot lane that lane_clear stays at 1.0,
	# so we're testing pressure in isolation.
	var nearby_opp: Array[Vector3] = [Vector3(2.0, 0.0, 23.0)]
	var pressured: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW,nearby_opp)
	assert_lt(pressured, clear, "opponent in the forward pressure cone should reduce shoot score")


func test_shoot_score_reduced_by_mid_lane_defender() -> void:
	# Defender mid-segment with reaction time blocks the shot. New
	# lane physics: defender's t along the segment matters — a
	# defender right next to the shooter (low t) doesn't have time
	# to position their stick into a 30 m/s puck path. Use a longer
	# shot so the mid-lane defender lands well past the reaction
	# threshold.
	var shooter := Vector3(0.0, 0.0, 15.0)
	var goalie := Vector3(0.5, 0.0, 26.0)
	var clear: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW,[])
	# Defender at z=20, 5 m from shooter along an ~11 m segment —
	# t ≈ 0.43, time_to_defender ≈ 0.16 s > LANE_REACTION_DELAY_S
	# (0.08), so they have time to position their stick.
	var blocker: Array[Vector3] = [Vector3(-0.1, 0.0, 20.0)]
	var blocked: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW,blocker)
	assert_gt(clear, 0.0)
	assert_lt(blocked, clear, "defender in shot lane with reaction time should reduce shoot score")


func test_shoot_blocked_by_close_on_line_defender() -> void:
	# Lane physics: a defender 2 m in front of the shooter, dead on the
	# shot line, is a shot-blocker — the puck's path runs straight through
	# the space their stick already occupies, so it blocks even on a fast
	# slapper. (The old reaction-window model wrongly let the puck "blow
	# past" an unreacting low-t defender; the reachability model doesn't —
	# they don't need to react, they're already there.)
	var shooter := Vector3(0.0, 0.0, 15.0)
	var aim := Vector3(0.0, 0.0, 26.65)
	var slapper := AIActionScoring.SLAPPER_SHOT_SPEED_M_S
	var clear: float = AIActionScoring.lane_clear(shooter, aim, [], slapper)
	var close_blocker: Array[Vector3] = [Vector3(-0.1, 0.0, 17.0)]
	var blocked: float = AIActionScoring.lane_clear(shooter, aim, close_blocker, slapper)
	assert_almost_eq(clear, 1.0, 0.0001, "sanity: the empty lane is clear")
	assert_lt(blocked, 0.1, "a defender dead on the close shot line blocks the shot")


func test_shoot_score_unaffected_by_defender_off_lane() -> void:
	var shooter := Vector3(0.0, 0.0, 21.0)
	var goalie := Vector3(0.5, 0.0, 26.0)
	var clear: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW,[])
	# Defender to the far side, outside both pressure radius and shot lane.
	var off_lane: Array[Vector3] = [Vector3(8.0, 0.0, 24.0)]
	var s: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW,off_lane)
	assert_almost_eq(s, clear, 0.001)


func test_pass_lateral_with_open_net_scores_high() -> void:
	# Phase 5e fix for "bots never pass side to side". Both shooter and
	# receiver are at the same depth (z=21), but the goalie covers the
	# shooter's angle. Receiver has wide-open net.
	var shooter := Vector3(3.0, 0.0, 21.0)   # angled shot — goalie can see them
	var receiver := Vector3(-3.0, 0.0, 21.0) # cross-slot — wide open
	var goalie := Vector3(2.5, 0.0, 26.0)    # shading the shooter's side
	var s: float = AIActionScoring.score_pass(shooter, receiver, GOAL, goalie, NET_HW,[])
	assert_gt(s, 0.3, "lateral pass to a teammate with an open net should score well")


func test_pass_score_zero_when_lane_blocked() -> void:
	var shooter := Vector3(0.0, 0.0, 10.0)
	var receiver := Vector3(0.0, 0.0, 22.0)  # close to goal, would normally score
	var goalie := Vector3(0.5, 0.0, 26.0)
	var blocker: Array[Vector3] = [Vector3(0.0, 0.0, 16.0)]  # right on the line
	var s: float = AIActionScoring.score_pass(shooter, receiver, GOAL, goalie, NET_HW,blocker)
	assert_eq(s, 0.0, "opponent on the pass line should zero the score")


func test_pass_lane_only_counts_opponents_between_endpoints() -> void:
	var shooter := Vector3(0.0, 0.0, 10.0)
	var receiver := Vector3(0.0, 0.0, 22.0)
	var goalie := Vector3(0.5, 0.0, 26.0)
	# Opponent BEHIND the shooter (z=5, before z=10) — shouldn't block
	var behind: Array[Vector3] = [Vector3(0.0, 0.0, 5.0)]
	var s: float = AIActionScoring.score_pass(shooter, receiver, GOAL, goalie, NET_HW,behind)
	assert_gt(s, 0.0, "opponent behind the shooter shouldn't block the lane")


func test_shoot_score_zero_from_behind_goal_line() -> void:
	# GOAL.z = +26.65; shooter past it (z=27) is behind the net.
	var shooter := Vector3(0.0, 0.0, 27.0)
	var goalie := Vector3(0.0, 0.0, 26.0)
	var s: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW,[])
	assert_eq(s, 0.0, "shot from behind goal line should score 0")


func test_shoot_score_low_at_extreme_angle() -> void:
	# Shooter way out on the boards, close to goal-line z. shot_angle_factor
	# is now quadratic (1 - x²) with x = angle/(π/2): at ~80° (x≈0.89) it's
	# about 0.21, combined with dist_response ≈ 0.82 lands around 0.17.
	# Wide-angle shots are still discouraged but no longer near-zero.
	# lateral 12, forward 2 → angle ≈ 80.5°.
	var shooter := Vector3(12.0, 0.0, 24.65)
	var goalie := Vector3(0.0, 0.0, 26.0)
	var s: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW, [])
	assert_lt(s, 0.25, "shot from ~80° off-axis should score < 0.25")


func test_shoot_score_partial_at_moderate_angle() -> void:
	# Shooter at ~58° off-axis. shot_angle_factor = 1 - 58°/90° ≈ 0.36.
	# Combined with the quadratic distance falloff (~9.4 m → 0.82) and
	# an exposed goalie at this angle (squareness = 0), score ≈ 0.30.
	var shooter := Vector3(8.0, 0.0, 21.65)
	var goalie := Vector3(0.0, 0.0, 26.0)
	var center := Vector3(0.0, 0.0, 21.0)
	var s_angle: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW, [])
	var s_center: float = AIActionScoring.score_shoot(center, GOAL, goalie, NET_HW, [])
	assert_gt(s_angle, 0.0, "shot from 58° should still score above zero")
	assert_lt(s_angle, s_center, "shot from 58° should score lower than a center shot")


func test_pass_score_zero_to_receiver_behind_goal_line() -> void:
	var shooter := Vector3(0.0, 0.0, 20.0)
	var receiver := Vector3(0.0, 0.0, 28.0)  # past attacking goal line
	var goalie := Vector3(0.0, 0.0, 26.0)
	var s: float = AIActionScoring.score_pass(shooter, receiver, GOAL, goalie, NET_HW,[])
	assert_eq(s, 0.0, "pass to receiver behind goal line should score 0")


func test_pass_score_falls_off_with_receiver_pressure() -> void:
	var shooter := Vector3(0.0, 0.0, 10.0)
	var receiver := Vector3(0.0, 0.0, 22.0)
	var goalie := Vector3(0.5, 0.0, 26.0)
	var clear: float = AIActionScoring.score_pass(shooter, receiver, GOAL, goalie, NET_HW,[])
	# Defender 2 m past the receiver (toward the attacking goal) and
	# 0.5 m off-axis — inside the receiver's forward pressure cone but
	# past the shooter→receiver segment so lane_clear isn't triggered.
	var checker: Array[Vector3] = [Vector3(0.5, 0.0, 24.0)]
	var pressured: float = AIActionScoring.score_pass(shooter, receiver, GOAL, goalie, NET_HW,checker)
	assert_lt(pressured, clear)




# Pressure cube-falloff sanity checks. The directional formula zeros
# opponents behind and beside the play, so shoot/pass scoring no
# longer counts defenders who can't realistically disrupt the action.

func test_shoot_pressure_ignores_defender_behind_shooter() -> void:
	var shooter := Vector3(0.0, 0.0, 21.0)
	var goalie := Vector3(0.5, 0.0, 26.0)
	var clean: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW,[])
	# Defender 2 m behind shooter (between shooter and own net).
	var behind: Array[Vector3] = [Vector3(0.5, 0.0, 19.0)]
	var pressured: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW,behind)
	assert_almost_eq(pressured, clean, 0.001,
			"defender behind the shooter should not pressure the shot")


func test_shoot_pressure_ignores_perpendicular_defender() -> void:
	var shooter := Vector3(0.0, 0.0, 21.0)
	var goalie := Vector3(0.5, 0.0, 26.0)
	var clean: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW,[])
	# Defender 2 m sideways at the same depth — directly perpendicular
	# to the shooter→goal axis. Cube weight = 0 (dot = 0).
	var perp: Array[Vector3] = [Vector3(2.0, 0.0, 21.0)]
	var pressured: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW,perp)
	assert_almost_eq(pressured, clean, 0.001,
			"perpendicular defender should not pressure the shot")


func test_pass_trailing_defender_pressures_reception_but_not_the_lane() -> void:
	# A defender just GOAL-side of the receiver: their closest approach to
	# the puck is only AFTER it reaches the receiver, so they're trailing
	# the play and the lane model skips them (no in-flight interception).
	# They DO pressure the reception, though — so the pass value drops via
	# the receiver's shot score, not via the lane. This pins the clean
	# separation the rework draws between in-flight interception (lane) and
	# pressure at reception (receiver value).
	var shooter := Vector3(0.0, 0.0, 10.0)
	var receiver := Vector3(0.0, 0.0, 18.0)
	var goalie := Vector3(0.0, 0.0, 26.0)
	var trailing: Array[Vector3] = [Vector3(1.0, 0.0, 19.5)]
	# Lane itself stays clear — the defender is past the receiver.
	var lane: float = AIActionScoring.lane_clear(
			shooter, receiver, trailing, AIActionScoring.PASS_SPEED_M_S)
	assert_almost_eq(lane, 1.0, 0.0001, "a defender past the receiver isn't a lane interceptor")
	var clean: float = AIActionScoring.score_pass(shooter, receiver, GOAL, goalie, NET_HW,[])
	var pressured: float = AIActionScoring.score_pass(shooter, receiver, GOAL, goalie, NET_HW,trailing)
	assert_lt(pressured, clean, "a defender on the receiver still pressures the reception")


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
			shooter, receiver, attacking_goal, goalie,
			NET_HW, [])
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


# ── Calibration: shot quality formula sanity checks ───────────────────────────
# Targets from SHOT_QUALITY_SPEC.md. These are the canonical scenarios
# the formula was designed around — if the implementation produces these
# (within rounding) the formula is correct. Any drift here means a tuning
# constant moved.

# Slot, centered, goalie squared. Monotone dist_response from goal:
# 5 m / 19.36 m = 0.258, dist_response = 1 - 0.258² = 0.93. Combined
# with shot_angle_factor 1.0 × (1 - BASE_COVERAGE 0.28) = 0.67.
func test_shot_quality_slot_5m_squared() -> void:
	var shooter := Vector3(0.0, 0.0, 21.65)  # 5 m from goal line
	var goalie := Vector3(0.0, 0.0, 26.0)    # squared (matches puck arc)
	var s: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW, [])
	assert_almost_eq(s, 0.67, 0.02, "slot 5m centered, goalie squared")


# Same shot but goalie has slid out of position (~30° arc offset).
# squareness = 0 at offset >= 30°, coverage = 0, full open net.
# dist_response 0.93 × angle 1.0 × open net 1.0 = 0.93.
func test_shot_quality_slot_5m_goalie_delayed() -> void:
	var shooter := Vector3(0.0, 0.0, 21.65)
	# Place goalie at ~30° off arc relative to shooter's puck angle (0°).
	# Goalie depth ~0.5 m in front of goal line; lateral ~0.45 m → arc ~42°
	# which is well past the SQUARENESS_OFFSET (30°), so squareness = 0.
	var goalie := Vector3(0.45, 0.0, 26.15)
	var s: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW, [])
	assert_almost_eq(s, 0.93, 0.02, "slot 5m centered, goalie misaligned → open net")


# 60° half-wall vs goalie at center (delayed/non-square).
# dist 9.25 m → dist_response 1 - (9.25/19.36)² ≈ 0.77. Quadratic
# angle 1 - (60/90)² = 0.556. Open net (squareness = 0) → ~0.43.
func test_shot_quality_60deg_goalie_delayed() -> void:
	# 60° angle: lateral / forward = tan(60°). Forward 4.625, lateral 8.0.
	var shooter := Vector3(8.0, 0.0, 22.025)  # 60° off-axis, dist ~9.25 m
	var goalie := Vector3(0.0, 0.0, 26.0)     # goalie at center (arc 0°, delayed)
	var s: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW, [])
	assert_almost_eq(s, 0.43, 0.05, "half-wall 60° vs delayed goalie ≈ 0.43")


# 60° half-wall vs squared goalie. Coverage knocks the open-net score
# down to ≈ 0.43 × (1 - 0.28) ≈ 0.31.
func test_shot_quality_60deg_goalie_squared() -> void:
	var shooter := Vector3(8.0, 0.0, 22.025)
	# Squared goalie: goalie_arc matches puck_arc (60°). Place goalie
	# laterally to produce that arc at the goalie's depth in front of
	# the goal. tan(60°) × forward(0.65) = 1.126 lateral.
	var goalie := Vector3(1.126, 0.0, 26.0)
	var s: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW, [])
	assert_almost_eq(s, 0.31, 0.05, "half-wall 60° vs squared goalie ≈ 0.31")


# Slightly off-center 5 m shot, squared goalie. The "great chance"
# scenario the user calls out — should score comfortably above the
# bar a typical CARRY candidate clears. Quadratic angle softens 11°
# off-center to ~0.98, × 0.93 dist × (1 - 0.28 squared) = ~0.66.
func test_shot_quality_slightly_off_center_5m_squared() -> void:
	var shooter := Vector3(1.0, 0.0, 21.65)  # ~11° off-axis, dist ~5.1 m
	# Goalie squared to the puck: goalie_arc matches puck_arc.
	# tan(11°) × goalie_forward(0.65) = 0.126 lateral.
	var goalie := Vector3(0.126, 0.0, 26.0)
	var s: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW, [])
	assert_gt(s, 0.6,
			"slightly off-center 5 m slot shot vs squared goalie should score > 0.6 (great chance)")


# Quadratic angle ordering. Three shots at the same close distance,
# varying angle: 30° > 60° > 89°. The new curve is monotone and
# "soft near zero, sharp near edges".
func test_shot_quality_angle_ordering_quadratic() -> void:
	var goalie := Vector3(0.0, 0.0, 26.0)  # delayed, open net so we isolate angle
	# 30° off-axis at dist ~6 m: forward 5.2, lateral 3.0.
	var shot_30 := Vector3(3.0, 0.0, 21.45)
	# 60° off-axis at dist ~6 m: forward 3.0, lateral 5.2.
	var shot_60 := Vector3(5.2, 0.0, 23.65)
	# 89° off-axis: lateral large, forward tiny.
	var shot_89 := Vector3(6.0, 0.0, 26.55)
	var s30: float = AIActionScoring.score_shoot(shot_30, GOAL, goalie, NET_HW, [])
	var s60: float = AIActionScoring.score_shoot(shot_60, GOAL, goalie, NET_HW, [])
	var s89: float = AIActionScoring.score_shoot(shot_89, GOAL, goalie, NET_HW, [])
	assert_gt(s30, s60, "30° shot should outscore 60° shot")
	assert_gt(s60, s89, "60° shot should outscore 89° shot")


# Blue-line bomb scores 0. SHOT_RANGE_FALLOFF_M is geometry-derived
# (GOAL_LINE_Z - BLUE_LINE_Z), so a shot from the attacking blue
# line is exactly at the falloff distance and dist_response zeros.
# This is the structural guarantee against bots launching pucks
# from neutral-zone or blue-line range — no defenders, no coverage
# math required, the dist curve alone says 0.
func test_shoot_score_zero_at_attacking_blue_line() -> void:
	# Attacking blue line for a shooter going +Z is at z = GOAL_LINE_Z
	# - (GOAL_LINE_Z - BLUE_LINE_Z) = BLUE_LINE_Z. Place shooter there
	# (centered) firing at GOAL.
	var shooter := Vector3(0.0, 0.0, GameRules.BLUE_LINE_Z)
	var goalie := Vector3(0.0, 0.0, 26.0)  # squared, irrelevant
	var s: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW, [])
	assert_eq(s, 0.0,
			"attacking blue-line shot must score 0 — falloff distance equals attacking-zone span")


# Monotone close-shot value. With dist_response monotone-falling
# from goal (no IDEAL peak), a 3 m point-blank shot retains nearly
# full dist value. The "drove past slot is bad" guardrail comes
# from the goalie pressure zone, which ramps linearly from
# GOALIE_ZONE_MAX_PENALTY at the goalie to 0 at the zone depth edge.
func test_shot_quality_3m_close_shot_retains_value() -> void:
	# Centered shot at 3 m, squared goalie at center. Without the
	# goalie zone penalty applied, dist_response ≈ 0.98 × angle 1.0
	# × (1 - 0.28 coverage) ≈ 0.71.
	var shooter := Vector3(0.0, 0.0, 23.65)  # 3 m from goal
	var goalie := Vector3(0.0, 0.0, 26.0)    # squared
	var s: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW, [])
	assert_gt(s, 0.6,
			"3 m point-blank shot (no zone applied) should retain dist value > 0.6")
	# Sanity: a shooter DEEP in the zone (1 m from goalie, on-axis)
	# triggers heavy penalty. depth_factor = 1 - 1/3.5 = 0.71;
	# penalty = 0.8 × 0.71 ≈ 0.57; multiplier ≈ 0.43.
	var deep_shooter := Vector3(0.0, 0.0, 25.0)  # 1 m from goalie
	var deep_no_zone: float = AIActionScoring.score_shoot(
			deep_shooter, GOAL, goalie, NET_HW, [])
	var deep_with_zone: float = AIActionScoring.score_shoot(
			deep_shooter, GOAL, goalie, NET_HW, [], goalie)
	assert_lt(deep_with_zone, deep_no_zone * 0.5,
			"shot deep inside goalie zone should drop > 50%")


# ── Goalie pressure zone ────────────────────────────────────────────────────
# Optional goalie_current_pos parameter on score_shoot / score_pass.
# When supplied, shots from inside a narrow rectangle in front of the
# goalie's CURRENT position are penalised. Default (Vector3.INF)
# bypasses — every test above relies on that default.

func test_goalie_zone_penalises_carrier_drive_in() -> void:
	# Carrier driving on-axis to z=24 (2m from goalie at z=26, well
	# inside zone depth 3.5m). Same scenario without the zone scores
	# higher; with the zone the shot is significantly penalised.
	var shooter := Vector3(0.0, 0.0, 24.0)
	var goalie := Vector3(0.0, 0.0, 26.0)
	var no_zone: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW, [])
	var with_zone: float = AIActionScoring.score_shoot(
			shooter, GOAL, goalie, NET_HW, [], goalie)
	assert_lt(with_zone, no_zone * 0.75,
			"on-axis 2m-from-goalie shot should be heavily penalised; got %f vs %f" % [with_zone, no_zone])


func test_goalie_zone_preserves_slot_shot() -> void:
	# Slot shot — 5m from goal = 4.35m from goalie at z=26. That
	# distance is past the zone depth (3.5m), so the slot shot is
	# NOT penalised by the goalie zone.
	var shooter := Vector3(0.0, 0.0, 21.65)
	var goalie := Vector3(0.0, 0.0, 26.0)
	var no_zone: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW, [])
	var with_zone: float = AIActionScoring.score_shoot(
			shooter, GOAL, goalie, NET_HW, [], goalie)
	assert_almost_eq(with_zone, no_zone, 0.001,
			"slot shot sits outside goalie zone depth; should be unaffected")


func test_goalie_zone_preserves_backdoor_receiver() -> void:
	# Back-door receiver close to net but laterally offset from the
	# goalie's current position. Goalie is squared to the CARRIER (at
	# +X), so back-door (-X side) is off-axis. score_pass(carrier,
	# back-door) with goalie_current passed should NOT penalise the
	# receiver — back-door remains a strong pass option.
	var carrier := Vector3(3.0, 0.0, 21.0)
	var receiver := Vector3(-3.0, 0.0, 25.0)  # 1.65m from net, 3m off-axis
	var goalie_current := Vector3(2.5, 0.0, 26.0)  # squared to carrier side
	# Predicted goalie at receiver's release (goalie tried to slide
	# but only made it partway).
	var goalie_predicted := Vector3(-0.5, 0.0, 26.0)
	var no_zone: float = AIActionScoring.score_pass(
			carrier, receiver, GOAL, goalie_predicted, NET_HW, [])
	var with_zone: float = AIActionScoring.score_pass(
			carrier, receiver, GOAL, goalie_predicted, NET_HW, [], goalie_current)
	# Receiver at lateral offset 3m relative to goalie_current.x = 2.5
	# means receiver-goalie lateral dx = 5.5m, well past the 1m zone
	# half-width. No penalty.
	assert_almost_eq(with_zone, no_zone, 0.001,
			"back-door receiver off-axis from current goalie should not be penalised")


func test_goalie_zone_default_is_no_op() -> void:
	# Shooter sits inside the zone (on-axis, 3m forward of goalie).
	# Without explicitly passing goalie_current_pos, the default
	# sentinel (Vector3.INF) bypasses the zone calc and produces the
	# same score as a call with the sentinel passed explicitly.
	var shooter := Vector3(0.0, 0.0, 23.0)
	var goalie := Vector3(0.0, 0.0, 26.0)
	var default_call: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW, [])
	var explicit_inf: float = AIActionScoring.score_shoot(
			shooter, GOAL, goalie, NET_HW, [], Vector3.INF)
	assert_eq(default_call, explicit_inf,
			"default param must be Vector3.INF and bypass the zone calc")
	# And confirm the zone actually penalises when the same shooter
	# IS supplied as goalie_current — sanity that the new path lights up.
	var with_zone: float = AIActionScoring.score_shoot(
			shooter, GOAL, goalie, NET_HW, [], goalie)
	assert_lt(with_zone, default_call,
			"shooter inside zone with goalie supplied should score lower")


# ── position_potential ───────────────────────────────────────────────────────
# position_potential models "value of being at this position" — used
# only when the evaluator is OUTSIDE shooting range (the regime rule
# in SM._score_at). Closeness peaks at the slot and ramps to 0 at the
# goal mouth (inside) and at the goal-to-goal rink length (outside).

func test_potential_zero_behind_goal_line() -> void:
	# Past the attacking goal line — no shooting potential.
	var pos := Vector3(0.0, 0.0, 27.5)
	assert_eq(AIActionScoring.position_potential(pos, GOAL, []), 0.0)


func test_potential_zero_at_90_degrees_off_axis() -> void:
	# Pure perpendicular — angle factor zeros.
	var pos := Vector3(8.0, 0.0, 26.65)  # same z as goal
	assert_almost_eq(AIActionScoring.position_potential(pos, GOAL, []), 0.0, 0.01)


func test_potential_peaks_at_slot() -> void:
	# Slot position should score above any nearby non-slot position.
	var slot := Vector3(0.0, 0.0, 20.65)  # 6 m from goal — slot radius
	var deeper := Vector3(0.0, 0.0, 24.65)  # 2 m from goal — past slot
	var farther := Vector3(0.0, 0.0, 14.65)  # 12 m from goal — past slot outward
	var slot_v: float = AIActionScoring.position_potential(slot, GOAL, [])
	var deeper_v: float = AIActionScoring.position_potential(deeper, GOAL, [])
	var farther_v: float = AIActionScoring.position_potential(farther, GOAL, [])
	assert_gt(slot_v, deeper_v, "slot scores higher than past-slot toward goal")
	assert_gt(slot_v, farther_v, "slot scores higher than past-slot away from goal")


func test_potential_drops_inside_slot_toward_goal() -> void:
	# Closeness ramps DOWN inside slot — getting closer to the goal
	# than the slot doesn't keep increasing the position value.
	var slot := Vector3(0.0, 0.0, 20.65)   # 6 m from goal
	var crease := Vector3(0.0, 0.0, 25.65)  # 1 m from goal — in the crease
	assert_gt(
			AIActionScoring.position_potential(slot, GOAL, []),
			AIActionScoring.position_potential(crease, GOAL, []),
			"slot has higher potential than the crease (no carry-into-net pull)")


func test_potential_drops_with_far_distance() -> void:
	# Linear ramp on the outside — further from goal = lower potential.
	# Near OZ blue line vs deep DZ — both have full angle, no defenders.
	var oz_high := Vector3(0.0, 0.0, 5.0)    # ~22 m from goal
	var deep_dz := Vector3(0.0, 0.0, -20.0)  # ~46 m from goal
	assert_gt(
			AIActionScoring.position_potential(oz_high, GOAL, []),
			AIActionScoring.position_potential(deep_dz, GOAL, []),
			"closer to goal scores higher")


func test_potential_drops_with_pressure() -> void:
	# Forward-cone pressure cuts openness, dropping potential.
	var pos := Vector3(0.0, 0.0, 5.0)  # ~22 m from goal — outside shoot range
	var clean: float = AIActionScoring.position_potential(pos, GOAL, [])
	# Defender 2 m forward toward goal, on-axis.
	var pressured_opps: Array[Vector3] = [Vector3(0.0, 0.0, 7.0)]
	var pressured: float = AIActionScoring.position_potential(pos, GOAL, pressured_opps)
	assert_lt(pressured, clean, "forward-cone defender drops position potential")


# ── time_to_arrive ───────────────────────────────────────────────────────────

func test_time_to_arrive_zero_at_destination() -> void:
	var p := Vector3(5.0, 0.0, 5.0)
	assert_almost_eq(
			AIActionScoring.time_to_arrive(p, p, Vector3.ZERO),
			0.0, 0.0001)


func test_time_to_arrive_uses_ref_speed_when_stationary() -> void:
	# Stationary skater 10 m from dest. effective_speed = SKATER_REF.
	var from := Vector3(0.0, 0.0, 0.0)
	var dest := Vector3(10.0, 0.0, 0.0)
	var t: float = AIActionScoring.time_to_arrive(from, dest, Vector3.ZERO)
	assert_almost_eq(t, 10.0 / AIActionScoring.SKATER_REF_SPEED_M_S, 0.001)


func test_time_to_arrive_faster_with_momentum_toward_dest() -> void:
	var from := Vector3(0.0, 0.0, 0.0)
	var dest := Vector3(10.0, 0.0, 0.0)
	var stationary: float = AIActionScoring.time_to_arrive(from, dest, Vector3.ZERO)
	var with_momentum: float = AIActionScoring.time_to_arrive(
			from, dest, Vector3(AIActionScoring.SKATER_REF_SPEED_M_S, 0.0, 0.0))
	assert_lt(with_momentum, stationary,
			"velocity component toward dest reduces arrival time")


func test_time_to_arrive_slower_with_momentum_away() -> void:
	var from := Vector3(0.0, 0.0, 0.0)
	var dest := Vector3(10.0, 0.0, 0.0)
	var stationary: float = AIActionScoring.time_to_arrive(from, dest, Vector3.ZERO)
	var with_momentum: float = AIActionScoring.time_to_arrive(
			from, dest, Vector3(-5.0, 0.0, 0.0))
	assert_gt(with_momentum, stationary,
			"velocity component away from dest increases arrival time")


func test_time_to_arrive_clamps_at_min_speed_for_extreme_reverse() -> void:
	# Skater moving so fast away from dest that effective_speed would
	# be non-positive without the floor. The clamp at MIN_TRAVEL_SPEED_M_S
	# ensures finite (large) ETA — 10 m / 1 m/s = 10 s.
	var from := Vector3(0.0, 0.0, 0.0)
	var dest := Vector3(10.0, 0.0, 0.0)
	var t: float = AIActionScoring.time_to_arrive(
			from, dest, Vector3(-50.0, 0.0, 0.0))
	assert_almost_eq(t, 10.0 / AIActionScoring.MIN_TRAVEL_SPEED_M_S, 0.001)


# ─── carry_poke_safety ─────────────────────────────────────────────────

func test_carry_poke_safety_full_when_no_opponents() -> void:
	var puck_pos := Vector3.ZERO
	var empty: Array[Vector3] = []
	assert_eq(AIActionScoring.carry_poke_safety(puck_pos, empty), 1.0)


func test_carry_poke_safety_full_when_opponent_beyond_safe_radius() -> void:
	var puck_pos := Vector3.ZERO
	var far: Array[Vector3] = [Vector3(AIActionScoring.CARRY_POKE_SAFE_RADIUS_M + 1.0, 0.0, 0.0)]
	assert_eq(AIActionScoring.carry_poke_safety(puck_pos, far), 1.0)


func test_carry_poke_safety_floor_when_opponent_inside_danger_radius() -> void:
	var puck_pos := Vector3.ZERO
	var close: Array[Vector3] = [Vector3(0.5, 0.0, 0.0)]
	assert_eq(AIActionScoring.carry_poke_safety(puck_pos, close),
			AIActionScoring.CARRY_POKE_SAFETY_FLOOR)


func test_carry_poke_safety_ramps_between_radii() -> void:
	# Opponent at the midpoint between danger and safe radii → safety
	# sits midway between floor and 1.0.
	var puck_pos := Vector3.ZERO
	var mid_r: float = 0.5 * (
			AIActionScoring.CARRY_POKE_DANGER_RADIUS_M
			+ AIActionScoring.CARRY_POKE_SAFE_RADIUS_M)
	var mid: Array[Vector3] = [Vector3(mid_r, 0.0, 0.0)]
	var expected: float = 0.5 * (AIActionScoring.CARRY_POKE_SAFETY_FLOOR + 1.0)
	assert_almost_eq(AIActionScoring.carry_poke_safety(puck_pos, mid), expected, 0.01)


func test_carry_poke_safety_uses_nearest_opponent() -> void:
	# Two opponents — one far, one inside danger. Nearest dominates,
	# so the result is the floor regardless of the second opponent.
	var puck_pos := Vector3.ZERO
	var opps: Array[Vector3] = [
			Vector3(10.0, 0.0, 0.0),
			Vector3(0.5, 0.0, 0.0),
	]
	assert_eq(AIActionScoring.carry_poke_safety(puck_pos, opps),
			AIActionScoring.CARRY_POKE_SAFETY_FLOOR)


func test_carry_poke_safety_asymmetric_for_in_front_vs_behind() -> void:
	# Geometric demonstration that opp-to-PUCK (not opp-to-body) is the
	# right thing to measure. Carrier body at origin, attacking dir +X,
	# so puck rides at (CARRY_OFFSET, 0, 0). An opponent at (CARRY_OFFSET,
	# 0, 0) is on top of the puck — full poke threat. An opponent at
	# (-CARRY_OFFSET, 0, 0) is 2*CARRY_OFFSET away from the puck and
	# almost certainly outside the safe radius — no threat. Both
	# opponents sit the SAME body-to-body distance; a body-to-body
	# implementation would treat them identically.
	const CARRY_OFFSET := 2.0  # matches SkaterAgentStateMachine.CARRY_BLADE_AIM_FORWARD_M
	var puck_pos := Vector3(CARRY_OFFSET, 0.0, 0.0)
	var in_front: Array[Vector3] = [Vector3(CARRY_OFFSET, 0.0, 0.0)]
	var behind: Array[Vector3] = [Vector3(-CARRY_OFFSET, 0.0, 0.0)]
	assert_eq(AIActionScoring.carry_poke_safety(puck_pos, in_front),
			AIActionScoring.CARRY_POKE_SAFETY_FLOOR,
			"opponent on the puck = full danger")
	assert_eq(AIActionScoring.carry_poke_safety(puck_pos, behind), 1.0,
			"opponent two carry-arms behind = safe")


# ─── carry_intercept_safety ─────────────────────────────────────────────

func test_carry_intercept_safety_returns_one_with_no_opponents() -> void:
	var self_pos := Vector3.ZERO
	var candidate := Vector3(5.0, 0.0, 0.0)
	var empty: Array[Vector3] = []
	assert_eq(AIActionScoring.carry_intercept_safety(
			self_pos, candidate, 1.0, empty, empty), 1.0)


func test_carry_intercept_safety_returns_one_at_zero_arrival_time() -> void:
	# local_time ≈ 0 means bot has no path. Helper should short-
	# circuit to 1.0 so stand-still candidates don't get a spurious
	# penalty from this check (carry_poke_safety covers them).
	var self_pos := Vector3.ZERO
	var opps_now: Array[Vector3] = [Vector3(2.0, 0.0, 0.0)]
	var opps_then: Array[Vector3] = [Vector3(2.0, 0.0, 0.0)]
	assert_eq(AIActionScoring.carry_intercept_safety(
			self_pos, self_pos, 0.0, opps_now, opps_then), 1.0)


func test_carry_intercept_safety_safe_for_parallel_same_speed_chase() -> void:
	# Defender starts 4 m to the side, parallel velocity, same speed.
	# Relative motion is zero → constant distance over the window →
	# fallback to distance at t=0. 4 m is outside CARRY_POKE_SAFE_RADIUS
	# (3.0 m), so safety = 1.0.
	var self_pos := Vector3.ZERO
	var candidate := Vector3(0.0, 0.0, 10.0)  # bot moves +Z 10 m
	var opps_now: Array[Vector3] = [Vector3(4.0, 0.0, 0.0)]
	# Defender ends 4 m to the side of CANDIDATE → same +Z motion at
	# the same speed.
	var opps_then: Array[Vector3] = [Vector3(4.0, 0.0, 10.0)]
	assert_eq(AIActionScoring.carry_intercept_safety(
			self_pos, candidate, 1.0, opps_now, opps_then), 1.0)


func test_carry_intercept_safety_floor_when_path_crosses_defender_in_window() -> void:
	# Bot drives +Z 10 m over 1 s. Defender starts ahead and to the
	# left, cuts across to the bot's path mid-window — defender ends
	# ON the bot's line at t = 0.5. Closest approach is ~0 → floor.
	var self_pos := Vector3.ZERO
	var candidate := Vector3(0.0, 0.0, 10.0)
	# At t=0: bot at (0,0,0), opp at (-3, 0, 5).
	# At t=1: bot at (0,0,10), opp at (3, 0, 5).
	# At t=0.5: bot at (0,0,5), opp at (0,0,5). Distance = 0.
	var opps_now: Array[Vector3] = [Vector3(-3.0, 0.0, 5.0)]
	var opps_then: Array[Vector3] = [Vector3(3.0, 0.0, 5.0)]
	assert_eq(AIActionScoring.carry_intercept_safety(
			self_pos, candidate, 1.0, opps_now, opps_then),
			AIActionScoring.CARRY_POKE_SAFETY_FLOOR)


func test_carry_intercept_safety_safe_when_defender_moves_away_from_path() -> void:
	# Bot drives +Z 10 m. Defender at same start position as the
	# crossing case but moving AWAY (-X to -X further). Closest
	# approach stays far from the path → safety = 1.0.
	# Demonstrates intercept-safety is direction-aware: it's about
	# convergence, not just "are there opponents around."
	var self_pos := Vector3.ZERO
	var candidate := Vector3(0.0, 0.0, 10.0)
	var opps_now: Array[Vector3] = [Vector3(-3.0, 0.0, 5.0)]
	var opps_then: Array[Vector3] = [Vector3(-8.0, 0.0, 5.0)]
	assert_eq(AIActionScoring.carry_intercept_safety(
			self_pos, candidate, 1.0, opps_now, opps_then), 1.0)


func test_carry_intercept_safety_ignores_closest_approach_outside_window() -> void:
	# Bot drives +Z 10 m over 1 s. Defender starts ahead of where
	# the bot will arrive (z=15) and creeps lateral toward the path,
	# so analytical closest approach t* ≈ 1.54 — OUTSIDE [0, 1].
	# Clamp to t=1 (end of window) → distance at endpoint governs.
	# Endpoint geometry: bot at (0,0,10), opp at (-4, 0, 15), d≈6.4
	# well outside SAFE_RADIUS → safety = 1.0.
	var self_pos := Vector3.ZERO
	var candidate := Vector3(0.0, 0.0, 10.0)
	var opps_now: Array[Vector3] = [Vector3(-5.0, 0.0, 15.0)]
	var opps_then: Array[Vector3] = [Vector3(-4.0, 0.0, 15.0)]
	assert_eq(AIActionScoring.carry_intercept_safety(
			self_pos, candidate, 1.0, opps_now, opps_then), 1.0)


func test_carry_intercept_safety_uses_worst_defender() -> void:
	# Two defenders: one converging onto the path (dangerous), one
	# moving away (safe). Result should track the dangerous one
	# (worst-case dominates).
	var self_pos := Vector3.ZERO
	var candidate := Vector3(0.0, 0.0, 10.0)
	var opps_now: Array[Vector3] = [
			Vector3(-3.0, 0.0, 5.0),  # converger (crosses path at t=0.5)
			Vector3(8.0, 0.0, 5.0),   # mover-away
	]
	var opps_then: Array[Vector3] = [
			Vector3(3.0, 0.0, 5.0),
			Vector3(15.0, 0.0, 5.0),
	]
	assert_eq(AIActionScoring.carry_intercept_safety(
			self_pos, candidate, 1.0, opps_now, opps_then),
			AIActionScoring.CARRY_POKE_SAFETY_FLOOR)


# ─── expected_pass_speed / pass_launch_speed (distance-adaptive) ─────────

func test_pass_launch_speed_short_feed_is_snap_soft() -> void:
	# At/under the short threshold a pass fires at the soft snap speed — no rocket
	# on a close feed.
	var maxw: float = GameRules.DEFAULT_WRISTER_POWER_MAX_M_S
	assert_almost_eq(
			AIActionScoring.pass_launch_speed(AIActionScoring.PASS_RAMP_SHORT_DISTANCE_M, maxw),
			AIActionScoring.PASS_SPEED_M_S, 0.001)
	assert_almost_eq(AIActionScoring.pass_launch_speed(2.0, maxw),
			AIActionScoring.PASS_SPEED_M_S, 0.001)


func test_pass_launch_speed_ramps_up_with_distance() -> void:
	# Between the short and long thresholds, launch speed increases monotonically.
	var maxw: float = GameRules.DEFAULT_WRISTER_POWER_MAX_M_S
	var near: float = AIActionScoring.pass_launch_speed(12.0, maxw)
	var mid: float = AIActionScoring.pass_launch_speed(18.0, maxw)
	var far: float = AIActionScoring.pass_launch_speed(24.0, maxw)
	assert_gt(mid, near, "an 18 m pass must launch harder than a 12 m one")
	assert_gt(far, mid, "a 24 m pass must launch harder than an 18 m one")
	assert_gt(near, AIActionScoring.PASS_SPEED_M_S, "a 12 m pass is past the snap floor")


func test_pass_launch_speed_long_pass_reaches_ramp_top() -> void:
	# At/beyond the long threshold a pass fires at the long-pass pace (clamped by
	# the passer's own max wrister).
	var maxw: float = GameRules.DEFAULT_WRISTER_POWER_MAX_M_S
	assert_almost_eq(
			AIActionScoring.pass_launch_speed(AIActionScoring.PASS_RAMP_LONG_DISTANCE_M, maxw),
			AIActionScoring.PASS_RAMP_LONG_SPEED_M_S, 0.001)
	assert_almost_eq(AIActionScoring.pass_launch_speed(60.0, maxw),
			AIActionScoring.PASS_RAMP_LONG_SPEED_M_S, 0.001)


func test_pass_launch_speed_clamps_to_passer_max() -> void:
	# A low-Shot passer (low max wrister) can't reach the long-pass pace — the
	# launch clamps to its own ceiling.
	var weak_max: float = 16.0
	assert_almost_eq(AIActionScoring.pass_launch_speed(40.0, weak_max), weak_max, 0.001)


func test_expected_pass_speed_uses_distance_ramp() -> void:
	# expected_pass_speed is just pass_launch_speed at the league cap.
	var shooter := Vector3.ZERO
	var far := Vector3(0.0, 0.0, 18.0)
	assert_almost_eq(
			AIActionScoring.expected_pass_speed(shooter, far),
			AIActionScoring.pass_launch_speed(18.0, GameRules.DEFAULT_WRISTER_POWER_MAX_M_S),
			0.001)


# ─── score_pass: speed-aware lane clearance ─────────────────────────────

func test_score_pass_higher_at_charged_speed_with_in_lane_defender() -> void:
	# Same defender on the same pass line. At quick-shot speed (14 m/s)
	# the defender has more time to react and step toward the line,
	# producing a lower lane-clear (and a lower pass score). At
	# charged speed (~19 m/s) the puck arrives sooner, defender
	# contributes less, score is higher.
	#
	# Defender geometry has to put time-to-defender INSIDE the
	# LANE_REACTION_DELAY_S..+RAMP_S band (0.08..0.18s) at both
	# speeds, otherwise reaction_factor clamps and the two scores
	# match. With a 15 m pass and defender at z=2.5 (parameter
	# t=0.167): slow flight=1.07s, t*flight=0.18s (top of ramp);
	# fast flight=0.79s, t*flight=0.13s (mid ramp). Both inside,
	# slow reaction stronger → slow score lower.
	var shooter := Vector3.ZERO
	var receiver := Vector3(0.0, 0.0, 15.0)
	var goalie := Vector3(0.0, 0.0, GOAL.z - 1.0)
	var in_lane: Array[Vector3] = [Vector3(0.5, 0.0, 2.5)]
	var slow: float = AIActionScoring.score_pass(
			shooter, receiver, GOAL, goalie, NET_HW, in_lane,
			Vector3.INF, AIActionScoring.PASS_SPEED_M_S)
	var fast: float = AIActionScoring.score_pass(
			shooter, receiver, GOAL, goalie, NET_HW, in_lane,
			Vector3.INF, AIActionScoring.PASS_CHARGE_SPEED_M_S)
	assert_gt(fast, slow,
			"charged pass scores higher than quick-shot when a defender sits in the lane (less reaction time)")


# ── lane_clear: closest-approach reachability model (now public) ─────────────
# The carrier's pass scoring uses this directly. Covered invariants: a
# defender who can get a stick onto the puck's path cuts the clearance; a
# defender already ON the path blocks even when sitting right at the
# release (the old reaction-window product zeroed these — the breakout
# turnover bug); a faster puck threads better (less time to close); and a
# defender bearing down on the lane (velocity-aware) blocks more than the
# same defender standing still.

func test_lane_clear_full_with_no_defenders() -> void:
	var from := Vector3(0.0, 0.0, 0.0)
	var to := Vector3(0.0, 0.0, 12.0)
	var s: float = AIActionScoring.lane_clear(from, to, [], AIActionScoring.PASS_SPEED_M_S)
	assert_almost_eq(s, 1.0, 0.0001, "empty lane is fully clear")


func test_lane_clear_reduced_by_mid_lane_defender() -> void:
	# Defender mid-segment, dead on the line: the puck's path runs straight
	# through their stick reach → full block → clearance drops below 1.
	var from := Vector3(0.0, 0.0, 0.0)
	var to := Vector3(0.0, 0.0, 14.0)
	var mid_lane: Array[Vector3] = [Vector3(0.2, 0.0, 7.0)]
	var s: float = AIActionScoring.lane_clear(from, to, mid_lane, AIActionScoring.PASS_SPEED_M_S)
	assert_lt(s, 1.0, "a defender on the mid-lane reduces clearance")


func test_lane_clear_blocks_close_on_line_defender() -> void:
	# THE breakout-turnover regression. A defender 1 m in front of the
	# passer, dead on the line — a man in the slot the pass would go
	# straight through. The old reaction-window model treated them as
	# unable to react (puck "blows past" before the delay) and read the
	# lane as clear, so the turnover cost collapsed to zero. The
	# reachability model sees the puck pass within a stick of where they
	# already are → full block.
	var from := Vector3(0.0, 0.0, 0.0)
	var to := Vector3(0.0, 0.0, 12.0)
	var close_on_line: Array[Vector3] = [Vector3(0.0, 0.0, 1.0)]
	var s: float = AIActionScoring.lane_clear(from, to, close_on_line, AIActionScoring.PASS_SPEED_M_S)
	assert_lt(s, 0.05, "a defender right on the line at the release fully blocks the lane")


func test_lane_clear_charged_pass_threads_better_than_quick() -> void:
	# A faster (charged) pass reaches the defender's closest-approach point
	# sooner, leaving less time to close the gap → smaller reach → the lane
	# reads as more open. This is why routing the carrier through the real
	# pass speed matters for pickoff risk. Defender held off the line so
	# both speeds give a partial (non-saturated) block that can differ.
	var from := Vector3(0.0, 0.0, 0.0)
	var to := Vector3(0.0, 0.0, 15.0)
	var lane_def: Array[Vector3] = [Vector3(1.0, 0.0, 2.5)]
	var quick: float = AIActionScoring.lane_clear(from, to, lane_def, AIActionScoring.PASS_SPEED_M_S)
	var charged: float = AIActionScoring.lane_clear(from, to, lane_def, AIActionScoring.PASS_CHARGE_SPEED_M_S)
	assert_gt(charged, quick, "faster pass → less time for the defender to close → cleaner lane")


func test_lane_clear_clean_stretch_pass_stays_open() -> void:
	# A long pass with the only defender 8 m off the lane: even with the
	# whole flight to close, they can't reach the path → lane stays open.
	# Guards against the model over-rejecting legitimate stretch passes.
	var from := Vector3(0.0, 0.0, 0.0)
	var to := Vector3(0.0, 0.0, 20.0)
	var far_off: Array[Vector3] = [Vector3(8.0, 0.0, 10.0)]
	var s: float = AIActionScoring.lane_clear(from, to, far_off, AIActionScoring.PASS_SPEED_M_S)
	assert_almost_eq(s, 1.0, 0.0001, "a defender far off a stretch-pass lane doesn't block it")


func test_lane_clear_closing_defender_blocks_more_than_stationary() -> void:
	# Same defender 2 m off the mid-lane. Standing still they only partly
	# block; bearing down on the lane (−X velocity) they're dead-reckoned
	# INTO it → strictly more block (lower clearance). The old position-
	# only model could not tell these apart.
	var from := Vector3(0.0, 0.0, 0.0)
	var to := Vector3(0.0, 0.0, 12.0)
	var pos: Array[Vector3] = [Vector3(2.0, 0.0, 6.0)]
	var stationary: float = AIActionScoring.lane_clear(
			from, to, pos, AIActionScoring.PASS_SPEED_M_S, [Vector3.ZERO])
	var closing: float = AIActionScoring.lane_clear(
			from, to, pos, AIActionScoring.PASS_SPEED_M_S, [Vector3(-4.0, 0.0, 0.0)])
	assert_lt(closing, stationary, "a defender closing on the lane blocks more")


func test_lane_clear_defender_drifting_away_blocks_less() -> void:
	# Mirror image: the same defender drifting AWAY from the lane (+X)
	# can't reach it → blocks less than standing still (higher clearance).
	var from := Vector3(0.0, 0.0, 0.0)
	var to := Vector3(0.0, 0.0, 12.0)
	var pos: Array[Vector3] = [Vector3(2.0, 0.0, 6.0)]
	var stationary: float = AIActionScoring.lane_clear(
			from, to, pos, AIActionScoring.PASS_SPEED_M_S, [Vector3.ZERO])
	var drifting: float = AIActionScoring.lane_clear(
			from, to, pos, AIActionScoring.PASS_SPEED_M_S, [Vector3(4.0, 0.0, 0.0)])
	assert_gt(drifting, stationary, "a defender drifting off the lane blocks less")


# ── lane_clear_saucer / prefers_saucer: lofting over mid-lane defenders ───────
# A saucer pass flies the puck over a defender's grounded blade mid-lane,
# so a mid-lane defender that blocks a flat pass does NOT block a saucer —
# but a defender draped over the receiver (puck has landed) still does.

func test_lane_clear_saucer_ignores_mid_lane_defender() -> void:
	# Same mid-lane defender that drops the grounded lane below 1.0: the
	# saucer flies over it, so the saucer lane stays fully clear.
	var from := Vector3(0.0, 0.0, 0.0)
	var to := Vector3(0.0, 0.0, 14.0)
	var mid_lane: Array[Vector3] = [Vector3(0.2, 0.0, 7.0)]  # t ≈ 0.5
	var grounded: float = AIActionScoring.lane_clear(from, to, mid_lane, AIActionScoring.PASS_CHARGE_SPEED_M_S)
	var saucer: float = AIActionScoring.lane_clear_saucer(from, to, mid_lane, AIActionScoring.PASS_CHARGE_SPEED_M_S)
	assert_lt(grounded, 1.0, "sanity: grounded lane is contested by the mid-lane defender")
	assert_almost_eq(saucer, 1.0, 0.0001, "saucer flies over the mid-lane defender → lane clear")


func test_lane_clear_saucer_still_blocked_near_receiver() -> void:
	# Defender close to the receiver end (high t, past the airborne
	# window): the saucer has landed by then, so it still blocks.
	var from := Vector3(0.0, 0.0, 0.0)
	var to := Vector3(0.0, 0.0, 14.0)
	# t ≈ 0.9 (> SAUCER_AIRBORNE_T_MAX) → puck grounded, defender blocks.
	var near_receiver: Array[Vector3] = [Vector3(0.2, 0.0, 12.6)]
	var saucer: float = AIActionScoring.lane_clear_saucer(from, to, near_receiver, AIActionScoring.PASS_CHARGE_SPEED_M_S)
	assert_lt(saucer, 1.0, "a defender at the receiver end still blocks a landed saucer")


func test_prefers_saucer_true_for_contested_mid_lane() -> void:
	# A long pass with a defender squarely mid-lane: grounded is contested,
	# the saucer clears it by more than the margin → prefer the saucer.
	var from := Vector3(0.0, 0.0, 0.0)
	var to := Vector3(0.0, 0.0, 14.0)
	var mid_lane: Array[Vector3] = [Vector3(0.0, 0.0, 7.0)]
	assert_true(
			AIActionScoring.prefers_saucer(from, to, mid_lane, AIActionScoring.PASS_CHARGE_SPEED_M_S),
			"a mid-lane defender on a long pass should prompt a saucer")


func test_prefers_saucer_false_when_lane_open() -> void:
	# No defender in the lane: nothing to loft over, stay grounded.
	var from := Vector3(0.0, 0.0, 0.0)
	var to := Vector3(0.0, 0.0, 14.0)
	assert_false(
			AIActionScoring.prefers_saucer(from, to, [], AIActionScoring.PASS_CHARGE_SPEED_M_S),
			"an open lane never wants a saucer")


func test_prefers_saucer_false_when_blocker_at_receiver() -> void:
	# The only defender is at the receiver end, where the saucer has
	# landed — lofting doesn't help, so don't saucer.
	var from := Vector3(0.0, 0.0, 0.0)
	var to := Vector3(0.0, 0.0, 14.0)
	var near_receiver: Array[Vector3] = [Vector3(0.0, 0.0, 12.6)]  # t ≈ 0.9
	assert_false(
			AIActionScoring.prefers_saucer(from, to, near_receiver, AIActionScoring.PASS_CHARGE_SPEED_M_S),
			"a saucer doesn't clear a defender at the receiver, so don't loft")


# ── lane_loss_point: interceptor location for the turnover-cost term ──────────
# The loss location must be the worst blocker's closest-point ON the
# segment (where the puck actually gets picked), and INF when the lane
# is clean (no turnover to cost).

func test_lane_loss_point_inf_when_no_blocker() -> void:
	var from := Vector3(0.0, 0.0, 0.0)
	var to := Vector3(0.0, 0.0, 14.0)
	var p: Vector3 = AIActionScoring.lane_loss_point(from, to, [], AIActionScoring.PASS_SPEED_M_S)
	assert_false(p.is_finite(), "clean lane has no interception point")


func test_lane_loss_point_inf_when_defender_off_lane() -> void:
	# Defender far off the segment with no time to close → no block.
	var from := Vector3(0.0, 0.0, 0.0)
	var to := Vector3(0.0, 0.0, 14.0)
	var off_lane: Array[Vector3] = [Vector3(6.0, 0.0, 7.0)]
	var p: Vector3 = AIActionScoring.lane_loss_point(from, to, off_lane, AIActionScoring.PASS_SPEED_M_S)
	assert_false(p.is_finite(), "defender off the lane yields no interception point")


func test_lane_loss_point_is_on_the_path() -> void:
	# Single mid-lane defender at (0.4, 7.0) on a straight +Z lane: the
	# loss point is where the puck is at the defender's closest approach —
	# x on the lane (0), z at the defender's 7.0.
	var from := Vector3(0.0, 0.0, 0.0)
	var to := Vector3(0.0, 0.0, 14.0)
	var mid: Array[Vector3] = [Vector3(0.4, 0.0, 7.0)]
	var p: Vector3 = AIActionScoring.lane_loss_point(from, to, mid, AIActionScoring.PASS_SPEED_M_S)
	assert_true(p.is_finite(), "a blocking defender yields an interception point")
	assert_almost_eq(p.x, 0.0, 0.001, "loss point sits on the lane (x=0)")
	assert_almost_eq(p.z, 7.0, 0.001, "loss point sits at the defender's position along the lane")


func test_lane_loss_point_finite_for_close_release_defender() -> void:
	# Companion to the lane_clear close-defender regression: a defender 1 m
	# in front of the passer on the line now produces a finite loss point
	# (the old model returned INF here, zeroing the turnover cost). The
	# pick spot is right where they stand, ~1 m down the line.
	var from := Vector3(0.0, 0.0, 0.0)
	var to := Vector3(0.0, 0.0, 12.0)
	var close_on_line: Array[Vector3] = [Vector3(0.0, 0.0, 1.0)]
	var p: Vector3 = AIActionScoring.lane_loss_point(from, to, close_on_line, AIActionScoring.PASS_SPEED_M_S)
	assert_true(p.is_finite(), "a close on-line defender yields a real interception point")
	assert_almost_eq(p.z, 1.0, 0.1, "the pick happens right where the defender stands")


func test_lane_loss_point_picks_worst_blocker() -> void:
	# Two blockers; the one with higher block strength defines the loss
	# point. The dead-on mid-lane defender at z=7 outweighs one far off the
	# line at z=11 (only a partial block) — loss point should be at z≈7.
	var from := Vector3(0.0, 0.0, 0.0)
	var to := Vector3(0.0, 0.0, 14.0)
	var blockers: Array[Vector3] = [
			Vector3(0.05, 0.0, 7.0),   # dead-on, mid-lane → strong block
			Vector3(4.0, 0.0, 11.0),   # well off the line → weak block
	]
	var p: Vector3 = AIActionScoring.lane_loss_point(from, to, blockers, AIActionScoring.PASS_SPEED_M_S)
	assert_almost_eq(p.z, 7.0, 0.001, "loss point follows the strongest blocker")


# ── turnover_cost: defensive half of the carrier EV ──────────────────────────
# cost = loss_prob × threat_surface_shoot(loss_point → our net). Zero
# when there's nothing to lose; scales with both probability and how
# dangerous the steal location is, which self-localizes by geometry.

const OUR_NET := Vector3(0.0, 0.0, 26.65)        # we defend +Z
const OUR_GOALIE := Vector3(0.0, 0.0, 26.0)


func test_turnover_cost_zero_when_no_loss_point() -> void:
	var c: float = AIActionScoring.turnover_cost(
			Vector3.INF, 0.5, OUR_NET, OUR_GOALIE, NET_HW, [])
	assert_eq(c, 0.0, "no interception point → no turnover cost")


func test_turnover_cost_zero_when_no_loss_prob() -> void:
	var loss := Vector3(0.0, 0.0, 21.0)  # dangerous spot, but...
	var c: float = AIActionScoring.turnover_cost(
			loss, 0.0, OUR_NET, OUR_GOALIE, NET_HW, [])
	assert_eq(c, 0.0, "zero loss probability → no turnover cost")


func test_turnover_cost_scales_with_loss_probability() -> void:
	var loss := Vector3(0.0, 0.0, 21.0)  # in our slot, in front of our net
	var low: float = AIActionScoring.turnover_cost(
			loss, 0.2, OUR_NET, OUR_GOALIE, NET_HW, [])
	var high: float = AIActionScoring.turnover_cost(
			loss, 0.8, OUR_NET, OUR_GOALIE, NET_HW, [])
	assert_gt(high, low, "higher interception probability → higher turnover cost")


func test_turnover_cost_self_localizes_by_geometry() -> void:
	# Same loss probability: a steal in our slot must cost far more than
	# one out by our blue line / center ice — this is the "no zone flag"
	# property. threat_surface_shoot toward our net does the localizing.
	var in_slot := Vector3(0.0, 0.0, 21.0)       # ~5.6 m from our net
	var far_out := Vector3(0.0, 0.0, 2.0)        # near center ice
	var slot_cost: float = AIActionScoring.turnover_cost(
			in_slot, 0.5, OUR_NET, OUR_GOALIE, NET_HW, [])
	var far_cost: float = AIActionScoring.turnover_cost(
			far_out, 0.5, OUR_NET, OUR_GOALIE, NET_HW, [])
	assert_gt(slot_cost, far_cost,
			"own-zone turnover costs more than a neutral-ice one at equal probability")
