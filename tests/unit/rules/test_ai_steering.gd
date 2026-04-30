extends GutTest

# AISteering is a pure function — these tests cover the obvious cases:
# anchor pull, teammate repel, board repel, and the unit-magnitude clamp.

const RINK_X: float = 13.0
const RINK_Z: float = 30.0


func test_no_movement_when_at_anchor() -> void:
	var pos := Vector3(0, 0, 0)
	var v := AISteering.compute_move_vector(pos, pos, [], RINK_X, RINK_Z)
	assert_almost_eq(v.length(), 0.0, 0.01, "no force when self is on the anchor")


func test_attracts_toward_anchor_along_z() -> void:
	var pos := Vector3(0, 0, 0)
	var anchor := Vector3(0, 0, 5)
	var v := AISteering.compute_move_vector(pos, anchor, [], RINK_X, RINK_Z)
	assert_almost_eq(v.x, 0.0, 0.05)
	assert_gt(v.y, 0.5, "Vector2.y maps to world Z; should be positive toward anchor")


func test_teammate_repel_pushes_away() -> void:
	var pos := Vector3(0, 0, 0)
	var anchor := Vector3(0, 0, 5)  # pulls toward +Z
	var teammate_at_anchor: Array[Vector3] = [Vector3(0, 0, 1)]  # blocking the path
	var v_solo := AISteering.compute_move_vector(pos, anchor, [], RINK_X, RINK_Z)
	var v_blocked := AISteering.compute_move_vector(pos, anchor, teammate_at_anchor, RINK_X, RINK_Z)
	assert_lt(v_blocked.y, v_solo.y, "teammate ahead should reduce the +Z pull")


func test_board_repel_pushes_inward_at_x_wall() -> void:
	var pos := Vector3(RINK_X - 0.5, 0, 0)  # very close to +X board
	var anchor := Vector3(RINK_X - 0.5, 0, 0)  # anchor at same point
	var v := AISteering.compute_move_vector(pos, anchor, [], RINK_X, RINK_Z)
	assert_lt(v.x, 0.0, "should be pushed toward -X (inward)")


func test_output_magnitude_clamped_to_unit() -> void:
	var pos := Vector3(RINK_X - 0.1, 0, RINK_Z - 0.1)  # corner; many forces stack
	var anchor := Vector3(0, 0, 0)
	var v := AISteering.compute_move_vector(pos, anchor, [], RINK_X, RINK_Z)
	assert_lte(v.length(), 1.0001, "move_vector must not exceed unit length")


func test_ignores_teammates_outside_repel_radius() -> void:
	var pos := Vector3(0, 0, 0)
	var anchor := Vector3(0, 0, 5)
	var far_teammate: Array[Vector3] = [Vector3(0, 0, 1.0 + AISteering.TEAMMATE_REPEL_RADIUS + 0.1)]
	var v_with := AISteering.compute_move_vector(pos, anchor, far_teammate, RINK_X, RINK_Z)
	var v_solo := AISteering.compute_move_vector(pos, anchor, [], RINK_X, RINK_Z)
	assert_almost_eq(v_with.x, v_solo.x, 0.001)
	assert_almost_eq(v_with.y, v_solo.y, 0.001)
