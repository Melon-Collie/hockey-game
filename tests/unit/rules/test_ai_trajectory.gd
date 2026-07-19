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


func test_predict_final_matches_predict_endpoint() -> void:
	# predict_final() must return exactly predict()'s last sample — they share
	# the _step integrator, so this locks the scratch-free path to the array
	# path across every branch of the model (accel, cap, friction, bounce).
	var cases: Array = [
		# pos, vel, steps, dt, decel, bounce, accel, max_speed
		[Vector3(0, 0, 0), Vector3(3, 0, -2), 6, 0.1, 0.0, 0.0, Vector3.ZERO, 0.0],
		[Vector3(1, 0, 1), Vector3(5, 0, 4), 6, 0.1, 0.0, 0.0, Vector3(2, 0, -1), 6.0],
		[Vector3(GameRules.INNER_HALF_WIDTH - 0.5, 0, 0), Vector3(20, 0, 3), 6, 1.0 / 12.0,
			GameRules.PUCK_ICE_DECEL_M_S2, GameRules.PUCK_BOARD_BOUNCE, Vector3.ZERO, 0.0],
	]
	for c: Array in cases:
		var traj: Array[Vector3] = AITrajectory.predict(c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7])
		var final_pos: Vector3 = AITrajectory.predict_final(c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7])
		var endpoint: Vector3 = traj[traj.size() - 1]
		assert_almost_eq(final_pos.x, endpoint.x, 0.0001, "predict_final x matches endpoint")
		assert_almost_eq(final_pos.y, endpoint.y, 0.0001, "predict_final y matches endpoint")
		assert_almost_eq(final_pos.z, endpoint.z, 0.0001, "predict_final z matches endpoint")


# ── step_puck (deterministic single-step atom for the puck-sim migration) ──────

func test_step_puck_returns_position_and_velocity() -> void:
	# The whole reason step_puck exists: it returns velocity too (origin = pos,
	# basis.x = vel), so a free-run can carry it forward. A straight slide advances
	# ~vel·dt and keeps ~its direction (friction only trims magnitude).
	var stepped: Transform3D = AITrajectory.step_puck(Vector3(0, 0, 0), Vector3(4, 0, 0), 0.1)
	assert_almost_eq(stepped.origin.x, 0.4, 0.01, "position advanced by ~vel·dt")
	assert_gt(stepped.basis.x.x, 0.0, "velocity still points +X")
	assert_lt(stepped.basis.x.x, 4.0, "friction trimmed the speed slightly")


func test_step_puck_reflects_velocity_at_board() -> void:
	# Stepped hard into the +X board, the returned VELOCITY must flip sign (× the
	# restitution) — the thing predict_final can't report, and what a free-run needs
	# to continue the carom.
	var pos := Vector3(GameRules.INNER_HALF_WIDTH - 0.05, 0, 0)
	var stepped: Transform3D = AITrajectory.step_puck(pos, Vector3(30, 0, 0), 1.0 / 12.0)
	assert_lt(stepped.basis.x.x, 0.0, "post-board velocity reversed in X")
	assert_lte(stepped.origin.x, GameRules.INNER_HALF_WIDTH + 0.001, "stays inside the boards")


func test_step_puck_chained_matches_predict_puck_at() -> void:
	# The load-bearing guarantee: the shadow harness free-runs by CHAINING step_puck,
	# and that must equal the AITrajectory predictor the AI already trusts to match
	# Jolt. Chain N steps and compare the endpoint to predict_puck_at(N steps).
	var pos := Vector3(GameRules.INNER_HALF_WIDTH - 1.0, 0, 2.0)
	var vel := Vector3(18, 0, 6)  # fast enough to carom off +X within the window
	var dt: float = 1.0 / 12.0
	var steps: int = 6
	var p := pos
	var v := vel
	for _i in steps:
		var s: Transform3D = AITrajectory.step_puck(p, v, dt)
		p = s.origin
		v = s.basis.x
	var reference: Vector3 = AITrajectory.predict_puck_at(pos, vel, dt * float(steps), steps)
	assert_almost_eq(p.x, reference.x, 1e-5, "chained step_puck endpoint == predict_puck_at (x)")
	assert_almost_eq(p.z, reference.z, 1e-5, "chained step_puck endpoint == predict_puck_at (z)")


# ── step_puck_3d (the airborne/gravity extension of the puck atom) ─────────────

const _REST: float = AITrajectory.PUCK_REST_HEIGHT_M


func test_step_puck_3d_grounded_matches_step_puck() -> void:
	# A resting/sliding puck (at rest height, no vertical speed) must be BYTE-identical to
	# the grounded step_puck — the 3D atom only adds a vertical channel, it doesn't change
	# the on-ice slide.
	var pos := Vector3(1.0, _REST, 2.0)
	var vel := Vector3(8.0, 0.0, -3.0)
	var dt: float = 1.0 / 120.0
	var a: Transform3D = AITrajectory.step_puck_3d(pos, vel, dt)
	var b: Transform3D = AITrajectory.step_puck(pos, vel, dt)
	assert_almost_eq(a.origin.x, b.origin.x, 1e-6, "grounded 3D == step_puck (x)")
	assert_almost_eq(a.origin.z, b.origin.z, 1e-6, "grounded 3D == step_puck (z)")
	assert_almost_eq(a.origin.y, b.origin.y, 1e-6, "grounded height passes through")


func test_step_puck_3d_gravity_pulls_a_rising_puck_down() -> void:
	# An airborne puck loses vy by g·dt each tick (ballistic), and gains height while vy>0.
	var dt: float = 1.0 / 120.0
	var stepped: Transform3D = AITrajectory.step_puck_3d(
			Vector3(0, 0.5, 0), Vector3(10, 3.0, 0), dt)
	assert_almost_eq(stepped.basis.x.y, 3.0 - GameRules.GRAVITY_M_S2 * dt, 1e-4, "vy dropped by g·dt")
	assert_gt(stepped.origin.y, 0.5, "still rising this tick (vy was positive)")
	assert_almost_eq(stepped.basis.x.x, 10.0, 1e-6, "no ice friction in the air — horizontal pace held")


func test_step_puck_3d_lands_and_slides() -> void:
	# A puck just above the ice with a small downward vy lands THIS tick: clamped to rest
	# height, vy killed (no vertical bounce), and horizontal speed preserved for the slide.
	var dt: float = 1.0 / 120.0
	var stepped: Transform3D = AITrajectory.step_puck_3d(
			Vector3(0, _REST + 0.005, 0), Vector3(6, -2.0, 0), dt)
	assert_almost_eq(stepped.origin.y, _REST, 1e-6, "clamped to rest height on landing")
	assert_eq(stepped.basis.x.y, 0.0, "vertical speed killed — land-and-slide, no bounce")
	assert_gt(stepped.basis.x.x, 0.0, "horizontal slide continues")


func test_step_puck_3d_ballistic_flight_time_matches_closed_form() -> void:
	# Chained airborne steps: a puck launched with vy = v0 lands after ~2·v0/g (no vertical
	# restitution), and with no ice friction its horizontal range is vx·flight_time. Verify
	# against the closed form to a tick's tolerance.
	var dt: float = 1.0 / 240.0
	var v0: float = 4.0     # up
	var vx: float = 5.0
	var p := Vector3(0, _REST, 0)
	var v := Vector3(vx, v0, 0)
	var t: float = 0.0
	var apex: float = _REST
	for _i in 1000:
		var s: Transform3D = AITrajectory.step_puck_3d(p, v, dt)
		p = s.origin
		v = s.basis.x
		t += dt
		apex = maxf(apex, p.y)
		if v.y == 0.0 and p.y <= _REST + 1e-6 and t > dt:
			break  # landed
	var expected_flight: float = 2.0 * v0 / GameRules.GRAVITY_M_S2
	assert_almost_eq(t, expected_flight, 3.0 * dt, "flight time ≈ 2·v0/g")
	assert_almost_eq(apex - _REST, v0 * v0 / (2.0 * GameRules.GRAVITY_M_S2), 0.02, "apex ≈ v0²/2g")
	assert_almost_eq(p.x, vx * expected_flight, 0.05, "horizontal range ≈ vx·flight_time (no air friction)")


func test_step_puck_3d_reflects_off_boards_while_airborne() -> void:
	# A puck flying into the +X board mid-air caroms in XZ (like the grounded puck) while
	# gravity keeps acting on Y — boards are full-height, so height doesn't spare the wall.
	var dt: float = 1.0 / 120.0
	var pos := Vector3(GameRules.INNER_HALF_WIDTH - 0.05, 0.6, 0)
	var stepped: Transform3D = AITrajectory.step_puck_3d(pos, Vector3(30, 1.0, 0), dt)
	assert_lt(stepped.basis.x.x, 0.0, "airborne puck reflected off the +X board")
	assert_lte(stepped.origin.x, GameRules.INNER_HALF_WIDTH + 0.001, "stays inside the boards")
	assert_lt(stepped.basis.x.y, 1.0, "gravity still acting on the vertical channel")
