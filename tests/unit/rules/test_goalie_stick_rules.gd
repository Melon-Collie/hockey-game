extends GutTest

# Pins the stick's model — geometry in, coverage out.
#
# The stick used to have no owner: collider boxes in Goalie.tscn, tilts and the
# aim solve in the pose builder, and NOTHING in the planning model. These pin the
# two properties that made that gap expensive, so it cannot silently reopen:
#   * the standing reach is DERIVED from the blade geometry (change the collider
#     or the yaw cap and the planner follows), and lands in the band the live
#     goalie measures;
#   * the blade closes the standing five-hole, which is what the live keeper
#     does and what the planner used to deny.


func test_standing_reach_lands_in_the_measured_band() -> void:
	# tests/unit/ai/test_goalie_low_cover.gd brackets the live standing keeper's
	# low cover at 0.59-0.64 m by sweeping flat shots for the point where saves
	# stop. The derivation must land there — that agreement is the whole claim
	# that this is a model of the stick rather than a fitted number.
	var reach: float = GoalieStickRules.standing_lateral_reach()
	gut.p("derived standing lateral reach: %.3f m" % reach)
	assert_true(reach >= 0.59 and reach <= 0.66,
			"derived reach must match the measured band (got %.3f)" % reach)


func test_the_stick_is_the_wider_low_surface() -> void:
	# The premise of the fix: while upright the PADS are not the outer edge, the
	# stick is. If this ever inverts, the planner's LOW core silently reverts to
	# the pad column and the slot re-opens.
	var pads: float = GoalieBehaviorRules.STANDING_PAD_CENTER_X_M \
			+ GoalieBehaviorRules.PAD_BOX_WIDTH_M * 0.5
	assert_gt(GoalieStickRules.standing_lateral_reach(), pads,
			"the standing keeper's outer low surface is the paddle, not the pads")


func test_reach_tracks_the_blade_geometry() -> void:
	# Derived, not declared: the blade's own half-width is inside the answer.
	var reach: float = GoalieStickRules.standing_lateral_reach()
	var center: float = reach - GoalieStickRules.BLADE_WIDTH_M * 0.5
	assert_almost_eq(center,
			GoalieStickRules.blade_center_x(GoalieStickRules.READY_WRIST_X_M,
					GoalieStickRules.TILT_READY_DEG,
					-GoalieStickRules.ACTIVE_YAW_CAP_DEG),
			0.001,
			"reach is the furthest blade CENTRE the yaw cap allows, plus its half-width")


func test_the_blade_closes_the_standing_five_hole() -> void:
	# The standing slot is ~0.16-0.20 m (GoalieBehaviorRules.five_hole_gap_m);
	# the blade is 0.38 m and lies across it. Measured: a dead-centre flat
	# release at 2.5-4.0 m is stick-saved 24/24.
	var standing_slot: float = GoalieBehaviorRules.five_hole_gap_m(false, 0.02)
	assert_eq(GoalieStickRules.five_hole_gap_after_blade(standing_slot), 0.0,
			"the paddle across the slot closes the standing five-hole outright")


func test_a_down_slide_leak_survives_the_blade() -> void:
	# The five-hole that genuinely exists is the DOWN goalie's slide leak, and
	# the blade must not erase it — otherwise closing the standing hole would
	# have cost the real one.
	assert_gt(GoalieStickRules.five_hole_gap_after_blade(0.36 + 0.38), 0.0,
			"a wide mid-slide leak is still a hole with the blade in it")


func test_yaw_aims_the_blade_not_the_assembly() -> void:
	# Closed-loop: after yawing, the blade CENTRE should sit on the wrist→target
	# bearing — not merely point the assembly the right way. This is the property
	# the old atan2(puck_x, fixed_lookahead) heuristic lacked.
	var wrist_x: float = GoalieStickRules.READY_WRIST_X_M
	var wrist_z: float = -0.32
	var target_x: float = 0.10
	var target_z: float = -1.40
	var yaw: float = GoalieStickRules.yaw_to_target(
			wrist_x, wrist_z, target_x, target_z,
			GoalieStickRules.TILT_READY_DEG, 90.0)
	var b: Vector2 = GoalieStickRules.blade_offset_from_wrist(
			GoalieStickRules.TILT_READY_DEG)
	var t: float = deg_to_rad(yaw)
	var bx: float = b.x * cos(t) + b.y * sin(t)
	var bz: float = -b.x * sin(t) + b.y * cos(t)
	var want: float = atan2(-(target_x - wrist_x), -(target_z - wrist_z))
	assert_almost_eq(atan2(-bx, -bz), want, 0.001,
			"the solved yaw puts the BLADE on the wrist→target line")


func test_yaw_is_capped() -> void:
	# The blocker pad is rigidly attached, so an uncapped swing takes it off the
	# body. A target hard to one side must saturate, not over-rotate.
	var yaw: float = GoalieStickRules.yaw_to_target(
			0.44, -0.32, -4.0, -0.4, GoalieStickRules.TILT_READY_DEG,
			GoalieStickRules.ACTIVE_YAW_CAP_DEG)
	assert_almost_eq(absf(yaw), GoalieStickRules.ACTIVE_YAW_CAP_DEG, 0.001,
			"a far-side target saturates the yaw cap")


func test_degenerate_inputs_hold_neutral() -> void:
	assert_eq(GoalieStickRules.yaw_to_target(0.44, -0.32, 0.44, -0.32,
			GoalieStickRules.TILT_READY_DEG, 25.0), 0.0,
			"a target at the wrist has no defined direction")
	# Zero TILT is NOT degenerate — the blade still hangs ASSEMBLY_LATERAL_M to
	# the side, so there is still a lever to swing. (The builder comment this
	# model replaced claimed the opposite; the guard only covers a blade sitting
	# exactly on the wrist, which the real geometry never produces.)
	assert_ne(GoalieStickRules.yaw_to_target(0.44, -0.32, 0.0, -2.0, 0.0, 25.0), 0.0,
			"a flat stick still has a lateral lever for yaw to act on")
