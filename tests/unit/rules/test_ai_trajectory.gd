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


func test_step_puck_board_friction_bleeds_tangential_speed() -> void:
	# A puck glancing off the +X board (small into-board X, large along-board Z) loses some of
	# its ALONG-board speed to board friction — the term that kills a hard rim-around. Ice
	# friction over one tick is ~0.004 m/s (negligible at this speed), so the drop is the board.
	var pos := Vector3(GameRules.INNER_HALF_WIDTH - 0.02, 0, 0)
	var vel := Vector3(6, 0, 30)  # mostly tangential (+Z), gentle into the +X board
	var stepped: Transform3D = AITrajectory.step_puck(pos, vel, 1.0 / 120.0)
	assert_lt(stepped.basis.x.x, 0.0, "into-board component reflected")
	assert_lt(stepped.basis.x.z, 29.5, "along-board (tangential) speed bled by board friction")
	assert_gt(stepped.basis.x.z, 27.0, "but most of the tangential pace is kept on a glance")


func test_a_square_carom_cannot_erase_the_along_board_channel() -> void:
	# The Coulomb drop is proportional to the NORMAL impulse, so on a steep hit it
	# outgrows the tangential speed it is subtracted from. Unbounded, every contact
	# past ~71° of incidence came straight back off the wall — one outcome for a
	# fifth of the incidence range, and the angle of reflection stopped tracking the
	# angle of incidence. The rim's sticking bound caps the loss at a third.
	var pos := Vector3(GameRules.INNER_HALF_WIDTH - 0.02, 0, 0)
	for inc_deg: float in [72.0, 80.0, 89.0]:
		var a: float = deg_to_rad(inc_deg)
		var vel := Vector3(sin(a), 0.0, cos(a)) * 20.0
		var stepped: Transform3D = AITrajectory.step_puck(pos, vel, 1.0 / 120.0)
		var kept: float = stepped.basis.x.z / vel.z
		assert_gt(kept, 1.0 - GameRules.PUCK_BOARD_TANGENTIAL_MAX_LOSS - 0.02,
				"%.0f-degree carom keeps at least two thirds of its along-board pace" % inc_deg)


func test_steeper_caroms_come_off_the_boards_at_distinct_angles() -> void:
	# The property a player reads directly: a steeper hit comes off nearer to square,
	# and no two incidences share an exit. Collapsing them all onto the wall normal is
	# what "the bounce looked wrong" was.
	var pos := Vector3(GameRules.INNER_HALF_WIDTH - 0.02, 0, 0)
	var last: float = -INF
	for inc_deg: float in [45.0, 55.0, 65.0, 75.0, 85.0]:
		var a: float = deg_to_rad(inc_deg)
		var vel := Vector3(sin(a), 0.0, cos(a)) * 20.0
		var out: Vector3 = AITrajectory.step_puck(pos, vel, 1.0 / 120.0).basis.x
		# Angle off the board surface, taken on the outgoing (−X, +Z) velocity.
		var off_board: float = rad_to_deg(atan2(-out.x, out.z))
		assert_gt(off_board, last + 1.0,
				"%.0f-degree carom leaves more square than the shallower one" % inc_deg)
		assert_lt(off_board, inc_deg,
				"%.0f-degree carom still leaves shallower than it arrived (restitution)"
						% inc_deg)
		last = off_board


func test_step_puck_chained_matches_predict_puck_at() -> void:
	# The load-bearing guarantee: the puck drive free-runs by CHAINING step_puck, and
	# that must equal the AITrajectory predictor the AI reasons with, or the bots aim
	# at a puck future the host never produces. Chain N steps, compare to
	# predict_puck_at(N steps).
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


# ── Board-aware reception gate ──────────────────────────────────────────────
# solve_reception_gate: where a loose puck comes into a receiver's reach, on
# the puck's REAL path rather than the straight ray off its current velocity.
# The two agree in open ice; on a rim they do not, and the difference is what
# decides whether a bot is set for the carom or a corner late.

const _GATE_REACH: float = 1.4
const _GATE_HORIZON_S: float = 2.0
const _GATE_STEPS: int = 20


func test_gate_matches_the_straight_ray_in_open_ice() -> void:
	# Puck through centre ice at pass pace, receiver a metre off its line. No
	# boards involved, so the board-aware solve must land on the same entry
	# point the straight-line geometry gives: reach from the body, on the line.
	var from_pos := Vector3(0, 0, 1)
	var found: bool = AITrajectory.solve_reception_gate(
			Vector3(-8, 0, 0), Vector3(18, 0, 0), from_pos,
			_GATE_REACH, _GATE_HORIZON_S, _GATE_STEPS)
	assert_true(found, "a feed crossing our level is gateable")
	assert_almost_eq(AITrajectory.gate_point.z, 0.0, 0.05,
			"the gate sits on the puck's travel line")
	assert_almost_eq(from_pos.distance_to(AITrajectory.gate_point), _GATE_REACH,
			0.05, "…at the blade's comfortable extension")
	assert_gt(AITrajectory.gate_time_s, 0.0)


func test_a_corner_rim_is_timed_around_the_carom_not_across_it() -> void:
	# Rim fired down the wall into the corner, receiver waiting up the far side
	# of it. The straight ray leaves the rink mid-corner, so a ray-based read
	# has to invent a clamped point and times the arrival along a chord. The
	# path solve walks the carom: the gate must land on the puck's real route
	# and be timed later than the straight-line crossing, because going around
	# is farther than going through.
	var puck_pos := Vector3(GameRules.INNER_HALF_WIDTH - 0.3, 0,
			GameRules.CORNER_CENTER_Z - 4.0)
	var puck_vel := Vector3(0, 0, 16)
	# Receiver waiting up the end wall past the corner, where the rim comes out.
	var from_pos := Vector3(2.0, 0, GameRules.INNER_HALF_LENGTH - 1.24)
	var found: bool = AITrajectory.solve_reception_gate(
			puck_pos, puck_vel, from_pos, _GATE_REACH, _GATE_HORIZON_S, _GATE_STEPS)
	assert_true(found, "the rim comes around into reach")
	var gate: Vector2 = Vector2(AITrajectory.gate_point.x, AITrajectory.gate_point.z)
	assert_true(GameRules.clamp_to_rink_inner(gate).is_equal_approx(gate),
			"the gate is on the playing surface, not a phantom point past the glass")
	var straight_t: float = (from_pos.z - puck_pos.z) / puck_vel.z
	assert_gt(AITrajectory.gate_time_s, straight_t,
			"around the corner takes longer than the straight-line chord")
	# And it arrives running ALONG the end boards, ~90° off the line it left on
	# — the whole reason the stance has to be built from the path.
	assert_lt(AITrajectory.gate_velocity.x, -5.0,
			"the rim arrives travelling down the end wall, not up the side one")


func test_the_gate_direction_is_the_post_carom_travel() -> void:
	# The blade squares to the direction the puck is travelling WHEN it arrives.
	# Off a wall that is the reflected direction, not the one it left on — a
	# receiver squared to the pre-carom line has his face open to nothing.
	var puck_pos := Vector3(GameRules.INNER_HALF_WIDTH - 2.0, 0, 0)
	AITrajectory.solve_reception_gate(
			puck_pos, Vector3(14, 0, 6), Vector3(GameRules.INNER_HALF_WIDTH - 3.0, 0, 4),
			_GATE_REACH, _GATE_HORIZON_S, _GATE_STEPS)
	assert_lt(AITrajectory.gate_velocity.x, 0.0,
			"after the wall the puck is coming back off it")


func test_a_puck_that_never_closes_reports_no_gate() -> void:
	# Running for the far end with the whole rink to cross: nothing inside the
	# horizon brings it closer than it already is, so there is nothing to set up
	# for and gate_closes says so.
	AITrajectory.solve_reception_gate(
			Vector3(0, 0, 5), Vector3(0, 0, 20), Vector3.ZERO,
			_GATE_REACH, _GATE_HORIZON_S, _GATE_STEPS)
	assert_false(AITrajectory.gate_in_reach)
	assert_false(AITrajectory.gate_closes, "a departing puck is not a reception")


func test_a_puck_ringing_off_the_near_wall_does_close() -> void:
	# Same "moving away from me" dot product, opposite answer: the wall is right
	# there and it comes straight back. This is the case the straight-ray test
	# got wrong, and why the closing read has to be path-based.
	AITrajectory.solve_reception_gate(
			Vector3(GameRules.INNER_HALF_WIDTH - 1.0, 0, 0), Vector3(20, 0, 0),
			Vector3(GameRules.INNER_HALF_WIDTH - 2.5, 0, 1),
			_GATE_REACH, _GATE_HORIZON_S, _GATE_STEPS)
	assert_true(AITrajectory.gate_closes,
			"a carom back toward us is a puck that closes")


# ── The gate is a RENDEZVOUS ────────────────────────────────────────────────
# The reach circle rides the receiver's own velocity, so the answer is where the
# puck's path meets the BODY's, not where it meets the spot the body occupied at
# the instant of asking. Both tests below walk the real clock and compare the
# two frames on the same feed; `from_vel = ZERO` is the frozen solve, and it is
# kept reachable precisely so these can still reproduce the defect.


# Walks a feed tick by tick and reports [ticks whose blade target was out of
# the arm's reach, the tick the first real entry appeared on, ticks walked].
# `ride` selects the frame: the receiver's true velocity, or ZERO for the frozen
# solve.
#
# The tracked quantity is `gate_offset` — the meet in the BODY's frame, which is
# what the blade aim consumes (SkaterAgentStateMachine._blade_gate_on_puck_line)
# and therefore what the stick is asked to do. `gate_point`, the same event in
# world coordinates, feeds the stance instead and legitimately moves.
func _walk_gate(puck_pos: Vector3, puck_vel: Vector3, body_pos: Vector3,
		body_vel: Vector3, ride: bool) -> Array:
	var dt: float = 1.0 / 30.0
	var p: Vector3 = puck_pos
	var v: Vector3 = puck_vel
	var b: Vector3 = body_pos
	var unreachable: int = 0
	var first_entry: int = -1
	var i: int = 0
	while i < 60 and b.distance_to(p) > _GATE_REACH:
		var hit: bool = AITrajectory.solve_reception_gate(
				p, v, b, _GATE_REACH, _GATE_HORIZON_S, _GATE_STEPS,
				body_vel if ride else Vector3.ZERO, AIRoleCarrier.PASS_LEAD_MAX_S)
		if hit and first_entry < 0:
			first_entry = i
		if AITrajectory.gate_offset.length() > _GATE_REACH + 0.001:
			unreachable += 1
		var stepped: Transform3D = AITrajectory.step_puck(p, v, dt)
		p = stepped.origin
		v = stepped.basis.x
		b += body_vel * dt
		i += 1
	return [unreachable, first_entry, i]


func test_the_catching_pose_is_available_before_the_puck_arrives() -> void:
	# A feed crossing in front of a receiver skating INTO the lane — the routine
	# give-and-go, and the shape behind the reported "stick rotates around just
	# as the puck reaches it".
	#
	# What the ride changes is WHEN the blade learns the pose it has to catch in.
	# Frozen, the puck's path never enters a circle drawn where the body is
	# STANDING, so for most of the approach there is no entry and the solve falls
	# back to the closest-approach foot — metres away, a target the arm cannot
	# reach — resolving to the real catching offset only in the last few ticks.
	# That last transition is ~0.46 m in a tick and the cursor slews ~0.33
	# (blade speed ~10 m/s at 30 Hz), so the stick is still swinging when the
	# puck gets there. Ridden, the same offset is available from the first tick
	# and the blade carries it in.
	var puck_pos := Vector3(-12, 0, -14)
	var puck_vel := Vector3(16, 0, 0)
	var body_pos := Vector3(0, 0, -18)
	var body_vel := Vector3(0, 0, 5)
	var frozen: Array = _walk_gate(puck_pos, puck_vel, body_pos, body_vel, false)
	var ridden: Array = _walk_gate(puck_pos, puck_vel, body_pos, body_vel, true)
	gut.p("  frozen: first entry tick %d of %d, %d ticks aimed out of reach"
			% [frozen[1], frozen[2], frozen[0]])
	gut.p("  ridden: first entry tick %d of %d, %d ticks aimed out of reach"
			% [ridden[1], ridden[2], ridden[0]])
	# The defect, reproduced.
	assert_gt(frozen[1], frozen[2] / 2,
			"frozen: no entry exists until the body has nearly arrived")
	assert_gt(frozen[0], frozen[2] / 2,
			"frozen: the blade spends most of the approach aimed out of its reach")
	# Ridden: the meet is known early, and it is somewhere the arm can be.
	assert_lt(ridden[1], frozen[1] / 2,
			"ridden: the rendezvous is available long before the puck arrives")
	# One opening tick before the walk resolves the meet; after that the target
	# is always somewhere the arm can be.
	assert_lt(ridden[0], 2,
			"ridden: the blade is not asked for ice the arm cannot cover")


func test_the_ride_leaves_a_standing_receiver_untouched() -> void:
	# The control that keeps the ride honest: with no velocity to ride, the
	# rendezvous IS the frozen solve — same meet, same offset, bit for bit — so
	# nothing about a stationary reception changed.
	var puck_pos := Vector3(-8, 0, 0)
	var puck_vel := Vector3(18, 0, 0)
	var from_pos := Vector3(0, 0, 1)
	AITrajectory.solve_reception_gate(puck_pos, puck_vel, from_pos,
			_GATE_REACH, _GATE_HORIZON_S, _GATE_STEPS)
	var frozen_point: Vector3 = AITrajectory.gate_point
	var frozen_offset: Vector3 = AITrajectory.gate_offset
	AITrajectory.solve_reception_gate(puck_pos, puck_vel, from_pos,
			_GATE_REACH, _GATE_HORIZON_S, _GATE_STEPS,
			Vector3.ZERO, AIRoleCarrier.PASS_LEAD_MAX_S)
	assert_eq(AITrajectory.gate_point, frozen_point)
	assert_eq(AITrajectory.gate_offset, frozen_offset)
	# And the two halves describe one event: the offset applied to the body IS
	# the world meet, which is the invariant the blade aim rests on.
	assert_almost_eq((from_pos + frozen_offset).distance_to(frozen_point), 0.0,
			0.001, "offset applied to the body is the world meet")


func test_a_puck_already_on_the_blade_gates_at_itself() -> void:
	var puck_pos := Vector3(0, 0, 0)
	var found: bool = AITrajectory.solve_reception_gate(
			puck_pos, Vector3(10, 0, 0), Vector3(0.5, 0, 0),
			_GATE_REACH, _GATE_HORIZON_S, _GATE_STEPS)
	assert_true(found)
	assert_eq(AITrajectory.gate_point, puck_pos)

# ── The puck caroms on its edge, not its centre ───────────────────────────────
# The disc's centre used to be clamped straight onto the kickplate face, so half
# the puck (a 6.5 cm radius) sat inside the wall. Harmless-looking until players
# could work the boards freely, at which point a puck visibly buried in the
# kickplate is what you see. AITrajectory._step now takes the body's own
# half-extent; every puck entry point passes the disc radius, skater
# approximations still pass 0.

const _PR: float = GameRules.PUCK_COLLISION_RADIUS


func test_a_puck_driven_into_the_side_boards_rests_a_radius_short() -> void:
	var p := Vector3(GameRules.INNER_HALF_WIDTH - 0.5, 0.0175, 0.0)
	var v := Vector3(6.0, 0.0, 0.0)
	for i: int in 200:
		var stepped: Transform3D = AITrajectory.step_puck(p, v, 1.0 / 120.0)
		p = stepped.origin
		v = stepped.basis.x
	assert_lte(p.x, GameRules.INNER_HALF_WIDTH - _PR + 1e-3,
			"the puck's EDGE stops at the kickplate — its centre never reaches the face")


func test_the_puck_never_overlaps_the_boards_anywhere_on_the_boundary() -> void:
	# Straight walls and the rounded corners alike.
	for deg: int in range(0, 360, 20):
		var rad: float = deg_to_rad(float(deg))
		var dir := Vector3(cos(rad), 0.0, sin(rad))
		var p: Vector3 = dir * 2.0
		p.y = 0.0175
		var v: Vector3 = dir * 14.0
		for i: int in 300:
			var stepped: Transform3D = AITrajectory.step_puck(p, v, 1.0 / 120.0)
			p = stepped.origin
			v = stepped.basis.x
		var xz := Vector2(p.x, p.z)
		var inset: Vector2 = GameRules.clamp_to_rink_inner(xz, _PR)
		assert_almost_eq(inset.distance_to(xz), 0.0, 1e-3,
				"puck edge stays out of the boards on the %d° heading" % deg)


func test_airborne_pucks_use_the_same_inset() -> void:
	var p := Vector3(GameRules.INNER_HALF_WIDTH - 0.4, 0.35, 0.0)
	var v := Vector3(7.0, 1.0, 0.0)
	for i: int in 240:
		var stepped: Transform3D = AITrajectory.step_puck_3d(p, v, 1.0 / 120.0)
		p = stepped.origin
		v = stepped.basis.x
	assert_lte(p.x, GameRules.INNER_HALF_WIDTH - _PR + 1e-3,
			"a lofted puck caroms on its edge too")


func test_the_bots_predict_the_same_boundary_the_puck_uses() -> void:
	# predict_puck must not model a puck that slides a radius deeper than the real
	# one — the rim reads it plans against would be wrong by that much per contact.
	var traj: Array[Vector3] = AITrajectory.predict_puck(
			Vector3(GameRules.INNER_HALF_WIDTH - 0.5, 0.0175, 0.0),
			Vector3(9.0, 0.0, 2.0), 90, 1.0 / 60.0)
	for point: Vector3 in traj:
		var xz := Vector2(point.x, point.z)
		assert_almost_eq(GameRules.clamp_to_rink_inner(xz, _PR).distance_to(xz), 0.0, 1e-3,
				"predicted puck respects the same inset boundary")


func test_the_closed_form_caroms_on_the_same_edge_as_the_walk() -> void:
	# The stepped walk above and AITrajectory.puck_release_landing's closed form
	# are two solvers for one puck, and the dump eval compares their answers
	# (it ranks releases with the closed form, everything else walks the sim).
	# The closed form kept the un-inset boundary when _step gained its margin,
	# so it modelled a puck resting a radius deeper into the boards, compounding
	# per contact on a multi-bounce rim (#650).
	for deg: int in range(0, 360, 20):
		var rad: float = deg_to_rad(float(deg))
		var vel := Vector3(cos(rad), 0.0, sin(rad)) * 14.0
		var landing: Vector3 = AITrajectory.puck_release_landing(
				Vector3(3.0, 0.0, 6.0), vel, 0.0).origin
		var xz := Vector2(landing.x, landing.z)
		assert_almost_eq(GameRules.clamp_to_rink_inner(xz, _PR).distance_to(xz), 0.0, 1e-2,
				"closed-form landing keeps the puck's edge out of the boards (%d°)" % deg)


func test_a_lofted_release_lands_on_the_ice_it_flew_over() -> void:
	# A release whose AIRBORNE leg ends past the boards resumes its slide from
	# the clamp — and the clamp has to leave it strictly INSIDE the boundary the
	# leg loop then searches. clamp_to_rink_inner returns a Vector2, whose
	# float32 components round the exact boundary to either side; landing a
	# rounding-width outside made every board solve report no contact, and the
	# puck ran its whole ~200 m runout clean through the wall (#650). Only
	# LOFTED releases reach that clamp, which is why the flat sweep above missed it.
	var hang: float = AIActionScoring.dump_loft_hang_s(ShotMechanics.ELEVATION_HIGH)
	for deg: int in range(0, 360, 15):
		var rad: float = deg_to_rad(float(deg))
		var vel := Vector3(cos(rad), 0.0, sin(rad)) * 14.0
		var landing: Vector3 = AITrajectory.puck_release_landing(
				Vector3(10.5, 0.0, 24.0), vel, hang).origin
		var xz := Vector2(landing.x, landing.z)
		assert_almost_eq(GameRules.clamp_to_rink_inner(xz, _PR).distance_to(xz), 0.0, 1e-2,
				"a lofted release settles on the playing surface (%d°)" % deg)


func test_skater_approximations_are_unchanged() -> void:
	# _step's default margin is 0, so the no-bounce skater path still clamps the
	# body centre exactly as before.
	var end: Vector3 = AITrajectory.predict_final(
			Vector3(GameRules.INNER_HALF_WIDTH - 0.2, 0.0, 0.0),
			Vector3(8.0, 0.0, 0.0), 60, 1.0 / 60.0)
	assert_almost_eq(end.x, GameRules.INNER_HALF_WIDTH, 1e-3,
			"a skater prediction still stops with its centre on the boundary")
