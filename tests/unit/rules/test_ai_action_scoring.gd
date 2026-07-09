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


func test_shoot_score_negligible_at_long_range() -> void:
	# No hard distance cutoff anymore — from ~32 m the net subtends almost no
	# angle and the goalie covers it, so danger is negligible (a sliver of
	# over-the-shoulder residual), never a shot the carrier would pick.
	var shooter := Vector3(0.0, 0.0, -5.0)  # ~32 m from goal
	var goalie := Vector3(0.0, 0.0, 26.0)
	var s: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW,[])
	assert_lt(s, 0.02, "a shot from ~32 m is negligible")


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
	# Shooter at ~58° off-axis vs a goalie SQUARED to each shooter (on the
	# challenge arc toward them, 0.6 m out) — how a real goalie plays it. From the
	# angle the net foreshortens and the squared goalie covers the near side, so
	# the off-angle look scores below the straight-on one. (With the goalie pinned
	# at center the near post would open up — but a goalie doesn't stand still.)
	var shooter := Vector3(8.0, 0.0, 21.65)
	var goalie_angle := Vector3(0.96, 0.0, 26.05)   # squared to the 58° shooter
	var center := Vector3(0.0, 0.0, 21.0)
	var goalie_center := Vector3(0.0, 0.0, 26.05)   # squared to the center shooter
	var s_angle: float = AIActionScoring.score_shoot(shooter, GOAL, goalie_angle, NET_HW, [])
	var s_center: float = AIActionScoring.score_shoot(center, GOAL, goalie_center, NET_HW, [])
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


# ── Shot danger: seven-hole open-net calibration ─────────────────────────────
# score_shoot rates a shot by the best of the seven goalie holes (open_net_danger)
# — top/bottom corners, five-hole, armpits — each scored as the net it clears past
# the goalie's height-appropriate, reaction-gated cover. These lock the ORDERING
# the whole AI ranks against: a genuinely open look far outscores firing into a
# set goalie, distance/angle emerge from the geometry, and a set goalie is
# beatable but low-percentage. best_shot_loft returns the winning hole's elevation
# so the loft matches the aim. (GOAL at +Z; a lower goalie z = further OUT.)

func test_shot_danger_backdoor_tap_in_is_near_certain() -> void:
	var shooter := Vector3(-0.8, 0.0, 25.5)   # far post
	var goalie := Vector3(0.85, 0.0, 25.45)   # stranded on the near post
	var s: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW, [])
	assert_gt(s, 0.9, "a gaping backdoor net is near-certain")


func test_shot_danger_backdoor_tap_in_is_shot_flat() -> void:
	# A gaping open net low: no reason to elevate — bury it along the ice.
	var loft: int = AIActionScoring.best_shot_loft(
			Vector3(-0.8, 0.0, 25.5), GOAL, Vector3(0.85, 0.0, 25.45),
			NET_HW, AIActionScoring.WRISTER_SHOT_SPEED_M_S)
	assert_eq(loft, ShotMechanics.ELEVATION_FLAT, "an open net gets buried flat")


func test_shot_danger_cross_seam_beats_a_frozen_goalie() -> void:
	# Off the strong side, goalie frozen at center — he can't slide (freeze), so
	# the near side is open.
	var shooter := Vector3(3.0, 0.0, 22.0)
	var goalie := Vector3(0.0, 0.0, 25.15)
	var s: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW, [])
	assert_gt(s, 0.4, "cross-seam past a frozen goalie is a strong chance")


func test_shot_danger_set_goalie_slot_is_small_but_nonzero() -> void:
	# Clean slot, goalie SET and squared: laterally covered low, only the
	# over-the-shoulder (top corner) window is open → small but NOT zero.
	var shooter := Vector3(0.0, 0.0, 21.65)
	var goalie := Vector3(0.0, 0.0, 25.05)
	var s: float = AIActionScoring.score_shoot(shooter, GOAL, goalie, NET_HW, [])
	assert_gt(s, 0.0, "a set goalie is beatable over the shoulder — not zero")
	assert_lt(s, 0.25, "...but a set-goalie slot shot is a low-percentage play")


func test_shot_danger_set_goalie_slot_is_roofed() -> void:
	# The slot shot's only opening is over the shoulder — so if the bot shoots it,
	# it must ELEVATE. This is the loft coupling: the score and the loft come from
	# the same hole.
	var loft: int = AIActionScoring.best_shot_loft(
			Vector3(0.0, 0.0, 21.65), GOAL, Vector3(0.0, 0.0, 25.05),
			NET_HW, AIActionScoring.WRISTER_SHOT_SPEED_M_S)
	assert_eq(loft, ShotMechanics.ELEVATION_HIGH, "beat a set goalie over the shoulder")


func test_shot_danger_point_blank_into_a_set_goalie_is_smothered() -> void:
	# Shooting from right on top of a squared, set goalie: his body eclipses the
	# whole net from that eye — no opening anywhere. You must move off-angle or
	# deke, not fire into him. (Supersedes the old "over-the-shoulder up close"
	# read: at 0.5 m the goalie subtends the entire net.)
	var pb := Vector3(0.0, 0.0, 24.65)                       # 0.5 m off the goalie
	var slot := Vector3(0.0, 0.0, 21.65)                     # ~5 m
	var s_pb: float = AIActionScoring.score_shoot(pb, GOAL, Vector3(0.0, 0.0, 25.15), NET_HW, [])
	var s_slot: float = AIActionScoring.score_shoot(slot, GOAL, Vector3(0.0, 0.0, 25.05), NET_HW, [])
	assert_lt(s_pb, 0.05, "point-blank into a set goalie is smothered")
	assert_lt(s_pb, s_slot, "...worse than backing out to the slot for a roof")


func test_shot_danger_open_look_dwarfs_firing_into_a_set_goalie() -> void:
	var open_s: float = AIActionScoring.score_shoot(
			Vector3(3.0, 0.0, 22.0), GOAL, Vector3(0.0, 0.0, 25.15), NET_HW, [])
	var set_s: float = AIActionScoring.score_shoot(
			Vector3(0.0, 0.0, 21.65), GOAL, Vector3(0.0, 0.0, 25.05), NET_HW, [])
	assert_gt(open_s, set_s * 2.5, "an open net is worth far more than roofing a set goalie")


func test_shot_danger_challenged_goalie_kills_the_range_shot() -> void:
	# 9 m straight-on, goalie challenging OUT (further from his net) → he eclipses
	# the angle. This is the "launch a long one at the goalie" play — it collapses.
	var s_far: float = AIActionScoring.score_shoot(
			Vector3(0.0, 0.0, 17.65), GOAL, Vector3(0.0, 0.0, 24.45), NET_HW, [])
	var s_slot: float = AIActionScoring.score_shoot(
			Vector3(0.0, 0.0, 21.65), GOAL, Vector3(0.0, 0.0, 25.05), NET_HW, [])
	assert_lt(s_far, s_slot, "a challenged goalie makes the range shot worse than the slot")


func test_shot_danger_range_closes_the_top_corner() -> void:
	# The over-the-shoulder window is a CLOSE-RANGE read: further out, the goalie's
	# glove has flight time to reach the corner, so the same set-goalie top-corner
	# shrinks. (This is why range doesn't help vs a set goalie — the corners shut.)
	# Distances are calibrated to the shot speed: full glove extension needs
	# flight >= arm delay + deploy (0.18 + 0.20 s) ≈ 12.5 m at the 33 m/s
	# wrister, so the mid-slot corner that used to shut at 6 m (24 m/s) now
	# stays open — a real consequence of the hotter shot, not a model change.
	var near: float = AIActionScoring.score_shoot(
			Vector3(0.0, 0.0, 23.65), GOAL, Vector3(0.0, 0.0, 25.15), NET_HW, [])   # 3 m
	var far: float = AIActionScoring.score_shoot(
			Vector3(0.0, 0.0, 11.65), GOAL, Vector3(0.0, 0.0, 25.15), NET_HW, [])   # 14 m
	assert_gt(near, far, "in tight the glove can't reach the top corner; at range it does")


func test_shot_danger_sharp_angle_is_low() -> void:
	# Wall shot: barely any net subtended → low.
	var s: float = AIActionScoring.score_shoot(
			Vector3(7.0, 0.0, 24.0), GOAL, Vector3(0.9, 0.0, 25.05), NET_HW, [])
	assert_lt(s, 0.3, "a sharp-angle shot has little net to hit")


func test_shot_danger_unsettled_goalie_scores_higher() -> void:
	# Same geometry; an unsettled (mid-slide) goalie can't deploy his glove in
	# time, so the shot beats him more.
	var shooter := Vector3(0.0, 0.0, 19.65)   # ~7 m
	var goalie := Vector3(0.0, 0.0, 25.15)
	var set_s: float = AIActionScoring.score_shoot(
			shooter, GOAL, goalie, NET_HW, [],
			AIActionScoring.WRISTER_SHOT_SPEED_M_S, 0.0)
	var unsettled: float = AIActionScoring.score_shoot(
			shooter, GOAL, goalie, NET_HW, [],
			AIActionScoring.WRISTER_SHOT_SPEED_M_S, 1.0)
	assert_gt(unsettled, set_s, "a mid-slide goalie reads the shot late → higher danger")


func test_shot_danger_caught_moving_goalie_opens_the_five_hole() -> void:
	# A head-on shot IN TIGHT at a goalie caught mid-slide: his legs are splayed,
	# so the five-hole is the opening — a FLAT shot between the pads, not a roof.
	# The five-hole is a physical gap, so it's only a real target up close; from
	# range it foreshortens away (and the goalie re-settles mid-flight).
	var shooter := Vector3(0.0, 0.0, 24.65)   # ~2 m — point blank
	var goalie := Vector3(0.0, 0.0, 25.65)    # 1 m out, squared
	var loft: int = AIActionScoring.best_shot_loft(
			shooter, GOAL, goalie, NET_HW, AIActionScoring.WRISTER_SHOT_SPEED_M_S, 1.0)
	assert_eq(loft, ShotMechanics.ELEVATION_FLAT, "shoot the five-hole flat on a sliding goalie in tight")


func test_shot_danger_cross_ice_shot_at_moving_goalie_collapses() -> void:
	# The bug the flight-fade + five-hole foreshortening fix: a bot must NOT rate a
	# long cross-ice shot at a caught-moving goalie as a chance. By the time a 12 m
	# shot arrives the goalie has re-settled, and a 12 m five-hole is a sliver.
	var shooter := Vector3(0.0, 0.0, 14.65)   # ~12 m out
	var goalie := Vector3(0.0, 0.0, 25.65)
	var s: float = AIActionScoring.score_shoot(
			shooter, GOAL, goalie, NET_HW, [], AIActionScoring.WRISTER_SHOT_SPEED_M_S, 1.0)
	assert_lt(s, 0.1, "a long shot at a mid-slide goalie is not a real chance — he recovers")


func test_shot_aim_targets_the_open_side() -> void:
	# Off the strong side (+x) vs a centred goalie: the open net is the near side,
	# so the aim resolves to a point on that side of the net.
	var aim: Vector3 = AIActionScoring.best_shot_aim(
			Vector3(3.0, 0.0, 22.0), GOAL, Vector3(0.0, 0.0, 25.15),
			NET_HW, AIActionScoring.WRISTER_SHOT_SPEED_M_S)
	assert_gt(aim.x, 0.0, "aim resolves to the open near side")
	assert_lt(absf(aim.x), NET_HW + 0.001, "aim stays inside the posts")
	assert_almost_eq(aim.z, GOAL.z, 0.001, "aim sits on the net plane")


func test_shot_aim_roofs_toward_a_post() -> void:
	# Set-goalie slot: loft is HIGH and the aim is a top CORNER (near a post), not
	# dead centre — aim and loft describe the same hole.
	var shooter := Vector3(0.0, 0.0, 21.65)
	var goalie := Vector3(0.0, 0.0, 25.05)
	var loft: int = AIActionScoring.best_shot_loft(
			shooter, GOAL, goalie, NET_HW, AIActionScoring.WRISTER_SHOT_SPEED_M_S)
	var aim: Vector3 = AIActionScoring.best_shot_aim(
			shooter, GOAL, goalie, NET_HW, AIActionScoring.WRISTER_SHOT_SPEED_M_S)
	assert_eq(loft, ShotMechanics.ELEVATION_HIGH, "the slot's only opening is up high")
	assert_gt(absf(aim.x), 0.4, "...so the aim is a top corner, not the goalie's chest")


# ── in_offensive_zone ─────────────────────────────────────────────────────────
# The value-map regime boundary: the attacking blue line. Attacking GOAL at +Z, so
# the O-zone is z > BLUE_LINE_Z.

func test_in_offensive_zone_past_blue_line() -> void:
	var deep := Vector3(0.0, 0.0, 20.0)          # well inside the zone
	var just_in := Vector3(0.0, 0.0, GameRules.BLUE_LINE_Z + 0.5)
	assert_true(AIActionScoring.in_offensive_zone(deep, GOAL))
	assert_true(AIActionScoring.in_offensive_zone(just_in, GOAL))


func test_not_in_offensive_zone_at_or_before_blue_line() -> void:
	var just_out := Vector3(0.0, 0.0, GameRules.BLUE_LINE_Z - 0.5)
	var nz := Vector3(0.0, 0.0, 0.0)
	var own_end := Vector3(0.0, 0.0, -20.0)
	assert_false(AIActionScoring.in_offensive_zone(just_out, GOAL))
	assert_false(AIActionScoring.in_offensive_zone(nz, GOAL))
	assert_false(AIActionScoring.in_offensive_zone(own_end, GOAL))


func test_in_offensive_zone_folds_for_negative_z_attack() -> void:
	# Attacking toward -Z: the O-zone is z < -BLUE_LINE_Z.
	var neg_goal := Vector3(0.0, 0.0, -26.65)
	assert_true(AIActionScoring.in_offensive_zone(Vector3(0, 0, -20.0), neg_goal))
	assert_false(AIActionScoring.in_offensive_zone(Vector3(0, 0, -5.0), neg_goal))
	assert_false(AIActionScoring.in_offensive_zone(Vector3(0, 0, 20.0), neg_goal))


# ── release_ahead_of_goalie / no phantom open net ─────────────────────────────
# GOAL is at +Z, so "in front of the goalie" = farther out = smaller z.

func test_release_clamped_when_behind_goalie() -> void:
	var goalie := Vector3(0.0, 0.0, 24.65)          # 2 m out from GOAL (z 26.65)
	var behind := Vector3(0.5, 0.0, 25.5)           # in the crease, past the goalie
	var clamped: Vector3 = AIActionScoring.release_ahead_of_goalie(behind, GOAL, goalie)
	assert_almost_eq(clamped.z, 24.65 - AIActionScoring.GOALIE_JAM_DISTANCE_M, 1e-4,
			"pushed out to the jam distance in front of the goalie")
	assert_almost_eq(clamped.x, 0.5, 1e-6, "lateral offset is untouched")


func test_release_untouched_when_in_front_of_goalie() -> void:
	var goalie := Vector3(0.0, 0.0, 24.65)
	var in_front := Vector3(1.0, 0.0, 20.0)         # out in the slot, well in front
	var out: Vector3 = AIActionScoring.release_ahead_of_goalie(in_front, GOAL, goalie)
	assert_eq(out, in_front, "a normal in-front shot is not clamped")


func test_shot_from_behind_goalie_is_not_a_phantom_open_net() -> void:
	# A shooter jammed dead-center just past the goalie used to read as an open net
	# (keeper modelled behind the shooter → danger 1.0). Clamped in front of him,
	# it's a point-blank jam into a set keeper — near zero, and far below a real
	# slot shot from the same centered line.
	var goalie := Vector3(0.0, 0.0, 24.65)
	var behind := Vector3(0.0, 0.0, 25.8)           # crease, dead center, past goalie
	var behind_danger: float = AIActionScoring.score_shoot(behind, GOAL, goalie, NET_HW, [])
	var slot := Vector3(0.0, 0.0, 20.65)            # real slot look, same line
	var slot_danger: float = AIActionScoring.score_shoot(slot, GOAL, goalie, NET_HW, [])
	assert_lt(behind_danger, slot_danger,
			"a jam from behind the goalie is not more dangerous than a slot shot")
	assert_lt(behind_danger, 0.2,
			"…it's a near-nothing point-blank jam, not a phantom open net")


# ── position_potential ───────────────────────────────────────────────────────
# position_potential models "value of being at this position" — used
# only when the evaluator is OUTSIDE shooting range (the regime rule
# in SM._score_at). Closeness peaks at the slot and ramps to 0 at the
# goal mouth (inside) and at the goal-to-goal rink length (outside).

func test_potential_zero_behind_goal_line() -> void:
	# Past the attacking goal line — no shooting potential. position_potential is
	# the raw geometric progression (no possession floor — that floor lives in the
	# offensive _score_at path, so the shared defensive threat_surface stays clean).
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


func test_potential_angle_is_goalmouth_projection() -> void:
	# The angle term is the goal mouth's projected width (cos of the bearing off
	# the goal normal), not a linear taper. Two positions the SAME distance (5 m)
	# from the goal — one head-on, one ~53° off (forward 3, lateral 4 → cos = 0.6)
	# — so closeness and openness match; only the projection differs. The off-axis
	# value must be the head-on value scaled by cos ≈ 0.6.
	var head_on := Vector3(0.0, 0.0, GOAL.z - 5.0)          # dist 5, cos 1
	var off_axis := Vector3(4.0, 0.0, GOAL.z - 3.0)         # dist 5, cos 0.6
	var head_v: float = AIActionScoring.position_potential(head_on, GOAL, [])
	var off_v: float = AIActionScoring.position_potential(off_axis, GOAL, [])
	assert_almost_eq(off_v, head_v * 0.6, 0.02,
			"off-axis value is the head-on value foreshortened by cos(θ)")


func test_potential_drops_with_pressure() -> void:
	# Forward-cone pressure cuts openness, dropping potential.
	var pos := Vector3(0.0, 0.0, 5.0)  # ~22 m from goal — outside shoot range
	var clean: float = AIActionScoring.position_potential(pos, GOAL, [])
	# Defender 2 m forward toward goal, on-axis.
	var pressured_opps: Array[Vector3] = [Vector3(0.0, 0.0, 7.0)]
	var pressured: float = AIActionScoring.position_potential(pos, GOAL, pressured_opps)
	assert_lt(pressured, clean, "forward-cone defender drops position potential")


# ── potential_realization_discount ───────────────────────────────────────────
# Potential is future value — it still has to be skated to the slot — so
# the carrier's compete discounts it over that remaining travel time.

func test_realization_discount_full_at_slot() -> void:
	# Inside the slot platform the promise is already real — no discount.
	var slot := Vector3(0.0, 0.0, 21.65)  # 5 m from goal, inside SLOT_RADIUS_M
	assert_eq(AIActionScoring.potential_realization_discount(slot, GOAL), 1.0)


func test_realization_discount_decays_with_distance() -> void:
	# Further from the slot = longer to realize = deeper discount.
	var near := Vector3(0.0, 0.0, 12.0)   # ~14.7 m from goal
	var far := Vector3(0.0, 0.0, -5.0)    # ~31.7 m from goal
	var near_d: float = AIActionScoring.potential_realization_discount(near, GOAL)
	var far_d: float = AIActionScoring.potential_realization_discount(far, GOAL)
	assert_lt(near_d, 1.0, "outside the slot the discount is real")
	assert_lt(far_d, near_d, "deeper positions pay a deeper discount")


func test_realization_discount_matches_delay_discount_currency() -> void:
	# The discount IS the standard per-second delay discount over the
	# remaining travel time at reference speed — same currency as every
	# other future action in the carrier's EV model.
	var pos := Vector3(0.0, 0.0, 8.65)  # 18 m from goal → 12 m past slot edge
	var expected: float = pow(
			AIActionScoring.CARRY_DELAY_DISCOUNT_PER_SEC,
			12.0 / AIActionScoring.SKATER_REF_SPEED_M_S)
	assert_almost_eq(
			AIActionScoring.potential_realization_discount(pos, GOAL),
			expected, 0.0001)


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


func test_pass_speed_scale_defaults_to_unchanged() -> void:
	# The difficulty pace arg defaults to 1.0, so an unscaled call is identical to
	# the two-arg form — the cross-player threat model is untouched by the knob.
	var maxw: float = GameRules.DEFAULT_WRISTER_POWER_MAX_M_S
	assert_eq(
			AIActionScoring.pass_launch_speed(18.0, maxw, 1.0),
			AIActionScoring.pass_launch_speed(18.0, maxw))


func test_pass_speed_scale_slows_the_puck_below_the_snap_floor() -> void:
	# The pace knob applies AFTER the clamp, so an easier bot's short feed drops
	# below the snap floor (PASS_SPEED_M_S) — a slow, readable puck by design.
	var maxw: float = GameRules.DEFAULT_WRISTER_POWER_MAX_M_S
	var full: float = AIActionScoring.pass_launch_speed(4.0, maxw, 1.0)
	var slowed: float = AIActionScoring.pass_launch_speed(4.0, maxw, 0.7)
	assert_almost_eq(slowed, full * 0.7, 0.001)
	assert_lt(slowed, AIActionScoring.PASS_SPEED_M_S,
			"a scaled short feed is slower than the snap floor")


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
			AIActionScoring.PASS_SPEED_M_S)
	var fast: float = AIActionScoring.score_pass(
			shooter, receiver, GOAL, goalie, NET_HW, in_lane,
			AIActionScoring.PASS_CHARGE_SPEED_M_S)
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


# ── lane_clear_saucer / prefers_saucer: a low flip over a near stick ─────────
# A saucer is airborne only for a fixed distance off the blade
# (SAUCER_AIRBORNE_DISTANCE_M, ~4 m): within it the puck flies over a
# grounded STICK but not a BODY; past it the puck has landed and every
# defender blocks with a stick. We can't know the live loft, so the model
# is deliberately conservative — saucers only beat a stick that's close.

func test_lane_clear_saucer_clears_near_stick_range_defender() -> void:
	# Defender within the airborne span (~3 m out) and off the line by more
	# than a body radius (within stick + closing reach, so the grounded lane
	# is contested). The saucer flies over their stick, body out of the
	# way → clear.
	var from := Vector3(0.0, 0.0, 0.0)
	var to := Vector3(0.0, 0.0, 14.0)
	var near_stick: Array[Vector3] = [Vector3(0.7, 0.0, 3.0)]
	var grounded: float = AIActionScoring.lane_clear(from, to, near_stick, AIActionScoring.PASS_CHARGE_SPEED_M_S)
	var saucer: float = AIActionScoring.lane_clear_saucer(from, to, near_stick, AIActionScoring.PASS_CHARGE_SPEED_M_S)
	assert_lt(grounded, 1.0, "sanity: grounded lane is contested by the stick-range defender")
	assert_almost_eq(saucer, 1.0, 0.0001, "saucer flies over a near stick → lane clear")


func test_lane_clear_saucer_blocked_by_body_in_lane() -> void:
	# Defender standing dead in the lane within the airborne span (within a
	# body radius of the line): the saucer can't fly over a torso, blocks.
	var from := Vector3(0.0, 0.0, 0.0)
	var to := Vector3(0.0, 0.0, 14.0)
	var body_in_lane: Array[Vector3] = [Vector3(0.0, 0.0, 3.0)]
	var saucer: float = AIActionScoring.lane_clear_saucer(from, to, body_in_lane, AIActionScoring.PASS_CHARGE_SPEED_M_S)
	assert_lt(saucer, 0.1, "a body dead in the lane blocks a saucer")


func test_lane_clear_saucer_blocked_past_airborne_span() -> void:
	# Stick-range defender BEYOND the airborne distance (~8 m out): the puck
	# has landed by then, so it blocks the saucer with a full stick just
	# like a flat pass. This is the key conservatism — a saucer doesn't
	# clear a defender far down the lane.
	var from := Vector3(0.0, 0.0, 0.0)
	var to := Vector3(0.0, 0.0, 14.0)
	var far_stick: Array[Vector3] = [Vector3(0.5, 0.0, 8.0)]
	var saucer: float = AIActionScoring.lane_clear_saucer(from, to, far_stick, AIActionScoring.PASS_CHARGE_SPEED_M_S)
	assert_lt(saucer, 1.0, "a defender past the airborne span still blocks a landed saucer")


func test_prefers_saucer_true_for_near_stick_range() -> void:
	# A stick-range defender within the airborne span: grounded is
	# contested, the saucer clears their stick by more than the margin →
	# prefer the saucer.
	var from := Vector3(0.0, 0.0, 0.0)
	var to := Vector3(0.0, 0.0, 14.0)
	var near_stick: Array[Vector3] = [Vector3(0.7, 0.0, 3.0)]
	assert_true(
			AIActionScoring.prefers_saucer(from, to, near_stick, AIActionScoring.PASS_CHARGE_SPEED_M_S),
			"a near stick-range defender should prompt a saucer")


func test_prefers_saucer_false_when_body_blocks_lane() -> void:
	# Defender standing dead in the lane: the saucer can't clear their body,
	# so lofting buys nothing → don't prefer it.
	var from := Vector3(0.0, 0.0, 0.0)
	var to := Vector3(0.0, 0.0, 14.0)
	var body_in_lane: Array[Vector3] = [Vector3(0.0, 0.0, 3.0)]
	assert_false(
			AIActionScoring.prefers_saucer(from, to, body_in_lane, AIActionScoring.PASS_CHARGE_SPEED_M_S),
			"a body dead in the lane can't be saucered over")


func test_prefers_saucer_false_when_lane_open() -> void:
	# No defender in the lane: nothing to loft over, stay grounded.
	var from := Vector3(0.0, 0.0, 0.0)
	var to := Vector3(0.0, 0.0, 14.0)
	assert_false(
			AIActionScoring.prefers_saucer(from, to, [], AIActionScoring.PASS_CHARGE_SPEED_M_S),
			"an open lane never wants a saucer")


func test_prefers_saucer_false_when_blocker_past_span() -> void:
	# The only defender is past the airborne span — the saucer has landed
	# and can't clear them, so lofting doesn't help. Don't saucer.
	var from := Vector3(0.0, 0.0, 0.0)
	var to := Vector3(0.0, 0.0, 14.0)
	var far_blocker: Array[Vector3] = [Vector3(0.0, 0.0, 8.0)]
	assert_false(
			AIActionScoring.prefers_saucer(from, to, far_blocker, AIActionScoring.PASS_CHARGE_SPEED_M_S),
			"a saucer doesn't clear a defender past the airborne span, so don't loft")


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


# ── pass_miss_loss_point: execution-miss loss location ────────────────────────
# A lane-clear pass can still miss on execution (PASS_MISS_PROB); the
# puck dies PASS_MISS_OVERSHOOT_M past the receiver on the pass line.

func test_pass_miss_loss_point_overshoots_past_receiver() -> void:
	var from := Vector3(0.0, 0.0, 20.0)
	var receiver := Vector3(0.0, 0.0, 24.0)  # straight backpass toward our net
	var loss: Vector3 = AIActionScoring.pass_miss_loss_point(from, receiver)
	assert_almost_eq(loss.z, 24.0 + AIActionScoring.PASS_MISS_OVERSHOOT_M, 0.001,
			"miss point sits the overshoot distance past the receiver on the pass line")
	assert_almost_eq(loss.x, 0.0, 0.001)


func test_pass_miss_loss_point_degenerate_falls_back_to_receiver() -> void:
	var p := Vector3(3.0, 0.0, 10.0)
	assert_eq(AIActionScoring.pass_miss_loss_point(p, p), p,
			"overlapping endpoints → miss point is the receiver itself")


func test_pass_miss_cost_self_localizes_by_rink_end() -> void:
	# The property the miss mode exists for: the identical pass shape,
	# missed in our own end, costs far more than missed in the opponent's
	# end — because the overshoot loss point lands in front of OUR net in
	# one case and a full rink away in the other. This is what lets the
	# risk term punish own-zone touch-passes without taxing OZ passing.
	var own_end_loss: Vector3 = AIActionScoring.pass_miss_loss_point(
			Vector3(2.0, 0.0, 20.0), Vector3(-2.0, 0.0, 23.0))
	var opp_end_loss: Vector3 = AIActionScoring.pass_miss_loss_point(
			Vector3(2.0, 0.0, -20.0), Vector3(-2.0, 0.0, -23.0))
	var own_end_cost: float = AIActionScoring.turnover_cost(
			own_end_loss, AIActionScoring.PASS_MISS_PROB, OUR_NET, OUR_GOALIE, NET_HW, [])
	var opp_end_cost: float = AIActionScoring.turnover_cost(
			opp_end_loss, AIActionScoring.PASS_MISS_PROB, OUR_NET, OUR_GOALIE, NET_HW, [])
	assert_gt(own_end_cost, opp_end_cost * 4.0,
			"a missed pass in our own end costs multiples of the same miss in theirs")
