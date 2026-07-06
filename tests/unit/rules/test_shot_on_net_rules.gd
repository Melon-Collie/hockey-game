extends GutTest

# ShotOnNetRules — ballistic on-net projection gating SOG / blocked-shot
# credits. Goal mouths are centred on x = 0 at z = ±GameRules.GOAL_LINE_Z.

const GOAL_Z: float = GameRules.GOAL_LINE_Z
const ICE_Y: float = 0.0175  # puck rest height


func test_flat_shot_at_center_is_on_net() -> void:
	assert_true(ShotOnNetRules.is_on_net(
			Vector3(0.0, ICE_Y, 20.0), Vector3(0.0, 0.0, 15.0), GOAL_Z))


func test_wide_shot_is_off_net() -> void:
	# Crosses the goal line half a metre outside the post + margin.
	var t: float = (GOAL_Z - 20.0) / 15.0
	var vx: float = (GameRules.NET_HALF_WIDTH + ShotOnNetRules.MARGIN + 0.5) / t
	assert_false(ShotOnNetRules.is_on_net(
			Vector3(0.0, ICE_Y, 20.0), Vector3(vx, 0.0, 15.0), GOAL_Z))


func test_shot_over_crossbar_is_off_net() -> void:
	# Close-range riser: crosses the line ~1.97 m up, well over the 1.22 m bar.
	assert_false(ShotOnNetRules.is_on_net(
			Vector3(0.0, ICE_Y, GOAL_Z - 2.0), Vector3(0.0, 20.0, 20.0), GOAL_Z))


func test_lofted_shot_dropping_under_bar_is_on_net() -> void:
	# HIGH-loft wrister from distance: airborne mid-flight, gravity brings it
	# down through the mouth (~1.11 m at the line).
	assert_true(ShotOnNetRules.is_on_net(
			Vector3(0.0, ICE_Y, GOAL_Z - 15.0), Vector3(0.0, 5.4, 18.0), GOAL_Z))


func test_saucer_landing_short_slides_in() -> void:
	# LOW-loft saucer from centre ice: the arc lands well before the line and
	# the puck slides the rest of the way at ice level.
	assert_true(ShotOnNetRules.is_on_net(
			Vector3(0.0, ICE_Y, 0.0), Vector3(0.0, 2.2, 14.0), GOAL_Z))


func test_moving_away_is_off_net() -> void:
	assert_false(ShotOnNetRules.is_on_net(
			Vector3(0.0, ICE_Y, 20.0), Vector3(0.0, 0.0, -15.0), GOAL_Z))


func test_zero_z_velocity_is_off_net() -> void:
	assert_false(ShotOnNetRules.is_on_net(
			Vector3(5.0, ICE_Y, 20.0), Vector3(-3.0, 0.0, 0.0), GOAL_Z))


func test_negative_end_goal_respects_direction() -> void:
	assert_true(ShotOnNetRules.is_on_net(
			Vector3(0.0, ICE_Y, -20.0), Vector3(0.0, 0.0, -15.0), -GOAL_Z))
	assert_false(ShotOnNetRules.is_on_net(
			Vector3(0.0, ICE_Y, -20.0), Vector3(0.0, 0.0, 15.0), -GOAL_Z))
