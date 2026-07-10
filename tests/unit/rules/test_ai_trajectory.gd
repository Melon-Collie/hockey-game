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


func test_predict_at_speed_cap_limits_acceleration() -> void:
	# Accelerating body, capped at a top speed below where the accel would take it.
	# Uncapped it reaches vel·t + ½·a·t²; the cap holds the projected speed (and so
	# the distance) down. Default (0) is uncapped — every non-pass caller.
	var pos := Vector3.ZERO
	var vel := Vector3(0, 0, 6)
	var accel := Vector3(0, 0, 10)
	var uncapped: Vector3 = AITrajectory.predict_at(pos, vel, 0.6, 6, accel)
	var capped: Vector3 = AITrajectory.predict_at(pos, vel, 0.6, 6, accel, 6.0)
	assert_lt(capped.z, uncapped.z, "the speed cap shortens an accelerating lead")
	# Capped at 6 m/s from a 6 m/s start → ~constant 6 m/s → ~3.6 m over 0.6 s.
	assert_almost_eq(capped.z, 3.6, 0.2, "capped body holds ~its top speed")


func test_zero_velocity_yields_static_trajectory() -> void:
	var pos := Vector3(1, 0, 2)
	var traj: Array[Vector3] = AITrajectory.predict(pos, Vector3.ZERO, 3, 0.1)
	for p: Vector3 in traj:
		assert_eq(p, pos, "no velocity → no movement at any step")


# ── Puck-physics prediction ─────────────────────────────────────────────────

func test_predict_puck_decelerates_with_ice_friction() -> void:
	# A puck moving along +X should travel STRICTLY less far than the
	# constant-velocity equivalent, because Coulomb friction (μ × g)
	# decelerates it each step. With μ = ICE_FRICTION = 0.05 and g = 9.81 the
	# deceleration is about 0.49 m/s² — observable over a couple seconds.
	# Velocity / time chosen to stay well inside the rink (4 m/s × 2 s
	# = 8 m, INNER_HALF_WIDTH ≈ 12.85 m) so the rink clamp / bounce
	# doesn't confound the comparison.
	var pos := Vector3(0, 0, 0)
	var vel := Vector3(4, 0, 0)
	var no_friction: Vector3 = AITrajectory.predict_at(pos, vel, 2.0)
	var with_friction: Vector3 = AITrajectory.predict_puck_at(pos, vel, 2.0)
	assert_lt(with_friction.x, no_friction.x,
			"puck prediction with friction must trail constant-velocity prediction")
	# Derive the expected loss from the constant so this can't drift out of sync:
	# constant decel ⇒ distance loss = ½·a·t² (a = PUCK_ICE_DECEL_M_S2, t = 2 s).
	var expected_loss: float = 0.5 * GameRules.PUCK_ICE_DECEL_M_S2 * 2.0 * 2.0
	assert_almost_eq(with_friction.x, no_friction.x - expected_loss, 0.5,
			"friction deceleration matches the Coulomb model (½·a·t²)")


func test_predict_puck_bounces_off_boards() -> void:
	# Puck moving fast into +X board well past the rink edge. With
	# bounce, perpendicular velocity reverses (× restitution), so the
	# final position is INSIDE the board and X velocity should have
	# flipped sign — observable as a final position less than the
	# bounce wall.
	var pos := Vector3(GameRules.INNER_HALF_WIDTH - 1.0, 0, 0)
	var vel := Vector3(30, 0, 0)  # blows past the board in < 0.1s
	var lead: Vector3 = AITrajectory.predict_puck_at(pos, vel, 0.5)
	assert_lt(lead.x, GameRules.INNER_HALF_WIDTH - 0.01,
			"after bouncing off +X board, puck should sit inside the rink; got x=%f" % lead.x)


func test_predict_puck_friction_stops_a_slow_puck() -> void:
	# A barely-moving puck decelerated by friction should reach zero
	# velocity and STOP, not start moving backward. Tests the clamp-
	# at-zero edge of the Coulomb model.
	var pos := Vector3(0, 0, 0)
	# 0.05 m/s puck, friction decel ≈ 0.098 m/s², stops in ~0.5 s.
	var vel := Vector3(0.05, 0, 0)
	var lead: Vector3 = AITrajectory.predict_puck_at(pos, vel, 2.0)
	# After 2 s the puck should be stopped at a small forward position.
	# It must NOT have negative x (would mean velocity reversed).
	assert_gte(lead.x, -0.001, "slow puck must stop, not reverse; got x=%f" % lead.x)
	assert_lte(lead.x, 0.1, "slow puck stops within a small distance")


func test_predict_puck_bounces_off_rounded_corner() -> void:
	# Regression (P2-16): the bounce model used to reflect off an axis-aligned
	# RECTANGLE, letting a corner-bound puck travel into ~3.5 m of phantom corner
	# ice past the rounded boards. Fire a puck diagonally into a corner; after the
	# carom its final position must be a valid in-rink point — i.e. the rounded-
	# corner clamp leaves it unchanged. With the old rectangle model the puck ends
	# up in the phantom corner and the clamp would move it.
	var pos := Vector3(GameRules.INNER_HALF_WIDTH - 1.0, 0, GameRules.INNER_HALF_LENGTH - 1.0)
	var vel := Vector3(25, 0, 25)  # straight at the corner, blows past it in < 0.1 s
	var lead: Vector3 = AITrajectory.predict_puck_at(pos, vel, 0.5)
	var reclamped: Vector2 = GameRules.clamp_to_rink_inner(Vector2(lead.x, lead.z))
	assert_almost_eq(reclamped.x, lead.x, 0.02,
			"corner carom leaves the puck on/inside the rounded boards (x)")
	assert_almost_eq(reclamped.y, lead.z, 0.02,
			"corner carom leaves the puck on/inside the rounded boards (z); got (%f, %f)" % [lead.x, lead.z])
