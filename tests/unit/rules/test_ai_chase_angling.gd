extends GutTest

# Pure-function test for SkaterAgentStateMachine._shade_intercept_goal_side,
# the chase-angle shading that brings a carrier-chase approach in on the
# inside (net-side) lane so the carrier is funneled toward the boards.

const REACH: float = SkaterAgentStateMachine.BLADE_REACH_M


func test_shade_moves_intercept_toward_our_net() -> void:
	# Intercept on the +X wall, our net straight down +Z: the shaded point
	# must sit exactly one blade-reach along the intercept→net line.
	var target := Vector3(8.0, 0.0, 0.0)
	var our_net := Vector3(0.0, 0.0, GameRules.GOAL_LINE_Z)
	var shaded: Vector3 = SkaterAgentStateMachine._shade_intercept_goal_side(target, our_net)
	var expected: Vector3 = target + (our_net - target).normalized() * REACH
	assert_almost_eq(shaded.x, expected.x, 0.001)
	assert_almost_eq(shaded.z, expected.z, 0.001)


func test_shade_distance_is_blade_reach_at_any_range() -> void:
	# Grounded scaling: the shade magnitude is one blade reach whether the
	# intercept is at the blue line or in tight — no distance falloff.
	var our_net := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)
	for target: Vector3 in [Vector3(6.0, 0.0, 12.0), Vector3(-3.0, 0.0, -14.0)]:
		var shaded: Vector3 = SkaterAgentStateMachine._shade_intercept_goal_side(target, our_net)
		assert_almost_eq(
				Vector2(shaded.x - target.x, shaded.z - target.z).length(),
				REACH, 0.001)


func test_shade_points_at_the_defended_net_not_center_ice() -> void:
	# The old flat bias shifted toward center-ice X regardless of which net
	# was defended. The shade must follow the actual net: same intercept,
	# opposite nets → opposite Z components.
	var target := Vector3(5.0, 0.0, 0.0)
	var toward_pos: Vector3 = SkaterAgentStateMachine._shade_intercept_goal_side(
			target, Vector3(0.0, 0.0, GameRules.GOAL_LINE_Z))
	var toward_neg: Vector3 = SkaterAgentStateMachine._shade_intercept_goal_side(
			target, Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z))
	assert_gt(toward_pos.z, target.z, "defending +Z shades the target toward +Z")
	assert_lt(toward_neg.z, target.z, "defending -Z shades the target toward -Z")


func test_shade_clamps_at_the_net() -> void:
	# Intercept closer to the net than one blade reach: the shade is clamped
	# to the remaining ice so the chaser is never projected past his own
	# goal line.
	var our_net := Vector3(0.0, 0.0, GameRules.GOAL_LINE_Z)
	var target: Vector3 = our_net + Vector3(0.0, 0.0, -0.5)  # 0.5 m in front
	var shaded: Vector3 = SkaterAgentStateMachine._shade_intercept_goal_side(target, our_net)
	assert_almost_eq(shaded.z, our_net.z, 0.001, "shade stops at the net")


func test_shade_degenerate_target_on_net_is_unchanged() -> void:
	var our_net := Vector3(0.0, 0.0, GameRules.GOAL_LINE_Z)
	assert_eq(
			SkaterAgentStateMachine._shade_intercept_goal_side(our_net, our_net),
			our_net)


func test_shade_does_not_modify_y() -> void:
	var target := Vector3(8.0, 0.0, -5.0)
	var shaded: Vector3 = SkaterAgentStateMachine._shade_intercept_goal_side(
			target, Vector3(0.0, 0.0, GameRules.GOAL_LINE_Z))
	assert_eq(shaded.y, 0.0)
