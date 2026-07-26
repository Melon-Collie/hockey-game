extends GutTest

# PuckController._inside_net — the client's render-side "never draw the puck in
# the net on our own initiative" predicate. Two call sites depend on it: the
# loose-puck prediction's goal park, and the interpolation fallback's
# extrapolation guard. Both must refuse to relocate / lead a puck that is merely
# BEHIND the net; only the cavity itself counts.
#
# State-free math (GameRules geometry via GoalDetectionRules), so a bare
# controller instance is enough — no puck, no NetworkManager, no tree.

var controller: PuckController

const ICE_Y: float = 0.0175
const GOAL_Z: float = GameRules.GOAL_LINE_Z


func before_each() -> void:
	controller = PuckController.new()


func after_each() -> void:
	controller.free()


func test_inside_the_mouth_counts() -> void:
	assert_true(controller._inside_net(Vector3(0.0, ICE_Y, GOAL_Z + 0.3)))
	assert_true(controller._inside_net(Vector3(0.0, ICE_Y, -GOAL_Z - 0.3)))


func test_behind_the_net_does_not_count() -> void:
	# The regression: the ice from the back frame out to the end boards is past the
	# goal line at every x, and a puck there must never be parked at / led toward
	# the mouth.
	assert_false(controller._inside_net(
			Vector3(0.3, ICE_Y, GOAL_Z + GameRules.NET_DEPTH + 0.2)))
	assert_false(controller._inside_net(Vector3(0.0, ICE_Y, GOAL_Z + 2.5)))
	assert_false(controller._inside_net(
			Vector3(-0.3, ICE_Y, -GOAL_Z - GameRules.NET_DEPTH - 0.2)))


func test_beside_the_net_does_not_count() -> void:
	assert_false(controller._inside_net(Vector3(1.05, ICE_Y, GOAL_Z + 0.3)))


func test_over_the_bar_does_not_count() -> void:
	assert_false(controller._inside_net(Vector3(0.0, 1.30, GOAL_Z + 0.3)))


func test_in_front_of_the_line_does_not_count() -> void:
	assert_false(controller._inside_net(Vector3(0.0, ICE_Y, GOAL_Z - 0.10)))
	assert_false(controller._inside_net(Vector3(0.0, ICE_Y, 0.0)))
