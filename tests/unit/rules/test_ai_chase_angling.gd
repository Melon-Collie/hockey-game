extends GutTest

# Pure-function test for SkaterAgentStateMachine._angle_intercept_inside,
# the chase-angle bias that funnels an opposing carrier toward the
# boards instead of letting them cut to center ice.

const BIAS: float = SkaterAgentStateMachine.CHASE_ANGLE_BIAS_M


func test_carrier_on_positive_x_biases_intercept_toward_center() -> void:
	# Carrier on the +X side of the rink — bias must be -X so the bot
	# meets them between the carrier and center ice.
	var target := Vector3(5.0, 0.0, 0.0)
	var carrier := Vector3(5.0, 0.0, 0.0)
	var biased: Vector3 = SkaterAgentStateMachine._angle_intercept_inside(target, carrier)
	assert_almost_eq(biased.x, target.x - BIAS, 0.001)
	assert_eq(biased.z, target.z, "Z is unchanged by lateral angling")


func test_carrier_on_negative_x_biases_toward_center() -> void:
	var target := Vector3(-5.0, 0.0, 10.0)
	var carrier := Vector3(-5.0, 0.0, 10.0)
	var biased: Vector3 = SkaterAgentStateMachine._angle_intercept_inside(target, carrier)
	assert_almost_eq(biased.x, target.x + BIAS, 0.001)


func test_carrier_near_center_skips_bias() -> void:
	# When the carrier is within CHASE_ANGLE_BIAS_M of center, there's
	# no inside to take away — applying the bias would overshoot to the
	# wrong side and OPEN the middle, the opposite of what we want.
	var target := Vector3(0.5, 0.0, 0.0)
	var carrier := Vector3(0.5, 0.0, 0.0)  # |x| < BIAS = 1.5
	var biased: Vector3 = SkaterAgentStateMachine._angle_intercept_inside(target, carrier)
	assert_eq(biased, target, "centered carrier produces no bias")


func test_carrier_at_bias_boundary_skips_bias() -> void:
	# Exactly at the boundary: <= guard means no bias.
	var target := Vector3(BIAS, 0.0, 0.0)
	var carrier := Vector3(BIAS, 0.0, 0.0)
	var biased: Vector3 = SkaterAgentStateMachine._angle_intercept_inside(target, carrier)
	assert_eq(biased, target)


func test_bias_does_not_modify_y_or_z() -> void:
	var target := Vector3(8.0, 0.0, -5.0)
	var carrier := Vector3(8.0, 0.0, -5.0)
	var biased: Vector3 = SkaterAgentStateMachine._angle_intercept_inside(target, carrier)
	assert_eq(biased.y, 0.0)
	assert_eq(biased.z, -5.0)
