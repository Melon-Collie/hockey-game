extends GutTest

# AITrajectory is a pure function. Tests cover constant-velocity
# stepping, the rink clamp on steps that would land outside the
# inner boundary, the lead-time convenience wrapper, and the
# zero-velocity / zero-lead degenerate cases.


func test_constant_velocity_steps_forward() -> void:
	var pos := Vector3(0, 0, 0)
	var vel := Vector3(2, 0, 0)  # 2 m/s along +X
	var traj: Array[Vector3] = AITrajectory.predict(pos, vel, 4, 0.5)
	assert_eq(traj.size(), 4)
	# Step 0 = t=0.5s → x=1, step 3 = t=2.0s → x=4
	assert_almost_eq(traj[0].x, 1.0, 0.001)
	assert_almost_eq(traj[3].x, 4.0, 0.001)


func test_clamps_into_rink_at_boards() -> void:
	# Start near +X board, velocity hard into the wall. Without the
	# clamp the final step would be well outside the rink.
	var pos := Vector3(GameRules.INNER_HALF_WIDTH - 0.5, 0, 0)
	var vel := Vector3(20.0, 0, 0)  # 20 m/s — way past the board in 0.5s
	var traj: Array[Vector3] = AITrajectory.predict(pos, vel, 6, 1.0 / 12.0)
	for p: Vector3 in traj:
		assert_lte(p.x, GameRules.INNER_HALF_WIDTH + 0.001,
				"trajectory step must not exit the rink in +X")


func test_predict_at_returns_lead_position() -> void:
	var pos := Vector3(0, 0, 0)
	var vel := Vector3(0, 0, 4)  # 4 m/s along +Z
	var lead: Vector3 = AITrajectory.predict_at(pos, vel, 0.5)
	# 4 m/s × 0.5 s = 2 m along +Z, well clear of any board.
	assert_almost_eq(lead.z, 2.0, 0.01)
	assert_almost_eq(lead.x, 0.0, 0.01)


func test_predict_at_zero_lead_returns_input() -> void:
	var pos := Vector3(3, 0, -5)
	var vel := Vector3(10, 0, 10)
	var lead: Vector3 = AITrajectory.predict_at(pos, vel, 0.0)
	assert_eq(lead, pos, "zero lead time should return current position unchanged")


func test_zero_velocity_yields_static_trajectory() -> void:
	var pos := Vector3(1, 0, 2)
	var traj: Array[Vector3] = AITrajectory.predict(pos, Vector3.ZERO, 3, 0.1)
	for p: Vector3 in traj:
		assert_eq(p, pos, "no velocity → no movement at any step")
