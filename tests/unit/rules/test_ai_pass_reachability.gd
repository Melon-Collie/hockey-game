extends GutTest

# Pure-function test for SkaterAgentStateMachine._is_pass_target_reachable.
# Filters pass targets that the quick-shot blade IK can't actually
# reach — receivers outside the ROM cone from current facing would
# fire the puck at the ROM edge, not at the receiver, and the result
# looks like a dump.

const FACING_TOWARD_PLUS_Z: Vector2 = Vector2(0.0, 1.0)
const FACING_TOWARD_MINUS_Z: Vector2 = Vector2(0.0, -1.0)
const SELF: Vector3 = Vector3(0.0, 0.0, 0.0)


func test_target_directly_ahead_is_reachable() -> void:
	# Bot facing +Z, receiver at z=10 — dot = 1.0, well above threshold.
	var aim := Vector3(0.0, 0.0, 10.0)
	assert_true(SkaterAgentStateMachine._is_pass_target_reachable(SELF, FACING_TOWARD_PLUS_Z, aim))


func test_target_directly_behind_is_unreachable() -> void:
	# Bot facing +Z, receiver at z=-10 (behind) — dot = -1.0, below threshold.
	var aim := Vector3(0.0, 0.0, -10.0)
	assert_false(SkaterAgentStateMachine._is_pass_target_reachable(SELF, FACING_TOWARD_PLUS_Z, aim))


func test_target_perpendicular_is_unreachable() -> void:
	# Bot facing +Z, receiver at x=10, z=0 (90° to the side) — dot = 0,
	# below the 0.1 threshold (so receivers right at the ROM edge are
	# excluded; the IK still clamps slightly inside).
	var aim := Vector3(10.0, 0.0, 0.0)
	assert_false(SkaterAgentStateMachine._is_pass_target_reachable(SELF, FACING_TOWARD_PLUS_Z, aim))


func test_target_45_degrees_forward_is_reachable() -> void:
	# Bot facing +Z, receiver 45° off-axis forward — dot ≈ 0.707, above threshold.
	var aim := Vector3(7.07, 0.0, 7.07)
	assert_true(SkaterAgentStateMachine._is_pass_target_reachable(SELF, FACING_TOWARD_PLUS_Z, aim))


func test_target_135_degrees_back_is_unreachable() -> void:
	# 45° forward of the bot's BACK side — dot ≈ -0.707.
	var aim := Vector3(7.07, 0.0, -7.07)
	assert_false(SkaterAgentStateMachine._is_pass_target_reachable(SELF, FACING_TOWARD_PLUS_Z, aim))


func test_facing_minus_z_flips_reachability() -> void:
	# When the bot faces the other way, what was reachable (forward of +Z)
	# becomes unreachable (now behind facing).
	var aim := Vector3(0.0, 0.0, 10.0)
	assert_false(SkaterAgentStateMachine._is_pass_target_reachable(SELF, FACING_TOWARD_MINUS_Z, aim))


func test_degenerate_self_aim_is_reachable() -> void:
	# Aim coincident with self has no direction to constrain — return true
	# rather than rejecting. Real callers will skip the aim for other
	# reasons (zero distance flight time, etc.).
	assert_true(SkaterAgentStateMachine._is_pass_target_reachable(SELF, FACING_TOWARD_PLUS_Z, SELF))
