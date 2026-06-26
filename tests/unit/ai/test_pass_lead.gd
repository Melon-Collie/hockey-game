extends GutTest

# AIPassLead is the unified pass-leading helper shared by the carrier role's
# pass scoring and the state machine's firing aim. Tests cover the two
# refinements over a naive pos+vel·t lead: the intercept-time solve (a
# receiver skating away is led further than the current-distance estimate
# would) and the along-velocity acceleration projection (a turning
# receiver's centripetal accel is discarded so the aim doesn't fly wide).


func _receiver(pos: Vector3, vel: Vector3) -> SkaterNetworkState:
	var s := SkaterNetworkState.new()
	s.position = pos
	s.velocity = vel
	s.blade_contact_world = pos  # aim at the (here, body-coincident) blade
	return s


# ── Along-velocity acceleration projection ──────────────────────────────────

func test_along_velocity_keeps_parallel_component() -> void:
	# Accel purely along the velocity direction is preserved unchanged.
	var vel := Vector3(3, 0, 0)
	var accel := Vector3(2, 0, 0)
	var out := AIPassLead.along_velocity_component(accel, vel)
	assert_almost_eq(out.x, 2.0, 0.001)
	assert_almost_eq(out.z, 0.0, 0.001)


func test_along_velocity_discards_perpendicular_component() -> void:
	# A skater moving along +X with a purely sideways (+Z) acceleration is
	# turning, not translating sideways — the centripetal component is
	# dropped so the lead doesn't aim into empty ice.
	var vel := Vector3(4, 0, 0)
	var accel := Vector3(0, 0, 5)  # entirely perpendicular
	var out := AIPassLead.along_velocity_component(accel, vel)
	assert_almost_eq(out.length(), 0.0, 0.001,
			"purely centripetal accel should project to ~zero")


func test_along_velocity_projects_mixed_to_parallel_only() -> void:
	var vel := Vector3(1, 0, 0)
	var accel := Vector3(3, 0, 7)  # 3 along, 7 across
	var out := AIPassLead.along_velocity_component(accel, vel)
	assert_almost_eq(out.x, 3.0, 0.001)
	assert_almost_eq(out.z, 0.0, 0.001)


func test_along_velocity_keeps_accel_when_stationary() -> void:
	# Below the projection speed there's no travel direction; the raw
	# accel (the intended "starting to move" direction) is kept.
	var vel := Vector3(0.1, 0, 0)  # below MIN_SPEED_FOR_PROJECTION
	var accel := Vector3(0, 0, 6)
	var out := AIPassLead.along_velocity_component(accel, vel)
	assert_eq(out, accel, "near-stationary receiver keeps raw accel")


# ── Intercept-time solve ────────────────────────────────────────────────────

func test_intercept_leads_further_for_fleeing_target() -> void:
	# Shooter at origin, receiver 8 m up-ice skating further away. The
	# naive current-distance time underestimates flight; the intercept
	# solve should lead PAST the naive pos+vel·t point.
	var shooter := Vector3.ZERO
	var pos := Vector3(0, 0, 8)
	var vel := Vector3(0, 0, 6)  # skating away at 6 m/s
	var speed := 14.0
	var max_lead := 0.6

	var naive_t: float = 8.0 / speed
	var naive_point := pos + vel * naive_t

	var solved_t := AITrajectory.intercept_time(
			shooter, pos, vel, Vector3.ZERO, speed, max_lead)
	var solved_point := AITrajectory.predict_at(pos, vel, solved_t)

	assert_gt(solved_t, naive_t,
			"fleeing target should be led with a longer flight time")
	assert_gt(solved_point.z, naive_point.z,
			"solved intercept should sit further up-ice than the naive lead")


func test_intercept_converges_for_stationary_target() -> void:
	# A stationary target's intercept time is just distance / speed.
	var t := AITrajectory.intercept_time(
			Vector3.ZERO, Vector3(0, 0, 7), Vector3.ZERO, Vector3.ZERO,
			14.0, 0.6)
	assert_almost_eq(t, 7.0 / 14.0, 0.001)


func test_intercept_clamped_to_max_lead() -> void:
	# Target far enough that distance/speed exceeds the cap → clamps.
	var t := AITrajectory.intercept_time(
			Vector3.ZERO, Vector3(0, 0, 30), Vector3.ZERO, Vector3.ZERO,
			14.0, 0.6)
	assert_almost_eq(t, 0.6, 0.001)


func test_intercept_zero_speed_returns_zero() -> void:
	var t := AITrajectory.intercept_time(
			Vector3.ZERO, Vector3(0, 0, 5), Vector3.ZERO, Vector3.ZERO,
			0.0, 0.6)
	assert_eq(t, 0.0)


# ── End-to-end lead() ───────────────────────────────────────────────────────

func test_lead_returns_point_and_flight_time() -> void:
	var receiver := _receiver(Vector3(0, 0, 6), Vector3(0, 0, 4))
	var out := AIPassLead.lead(Vector3.ZERO, receiver, Vector3.ZERO, 14.0, 0.6)
	assert_eq(out.size(), 2)
	var point: Vector3 = out[0]
	var flight_t: float = out[1]
	assert_gt(flight_t, 0.0)
	# Receiver moving up-ice → lead point ahead of the start blade pos.
	assert_gt(point.z, 6.0, "lead point should be ahead of the receiver")


func test_lead_point_matches_lead_first_element() -> void:
	var receiver := _receiver(Vector3(2, 0, 5), Vector3(1, 0, 3))
	var accel := Vector3(0, 0, 2)
	var full := AIPassLead.lead(Vector3.ZERO, receiver, accel, 14.0, 0.6)
	var point := AIPassLead.lead_point(Vector3.ZERO, receiver, accel, 14.0, 0.6)
	assert_eq(point, full[0], "lead_point must equal lead()[0]")


func test_lead_falls_back_to_body_when_blade_unpopulated() -> void:
	var s := SkaterNetworkState.new()
	s.position = Vector3(0, 0, 5)
	s.velocity = Vector3.ZERO
	# blade_contact_world left at ZERO → fallback to body position.
	var point := AIPassLead.lead_point(Vector3.ZERO, s, Vector3.ZERO, 14.0, 0.6)
	assert_almost_eq(point.z, 5.0, 0.001,
			"unpopulated blade should aim at body position")


func test_lead_turning_receiver_does_not_overshoot_sideways() -> void:
	# Receiver skating along +Z with a strong sideways (+X) acceleration —
	# i.e. carving a turn. The aim should stay essentially on the +Z line,
	# not get thrown out along +X by a ½·a·t² term that won't materialize.
	var receiver := _receiver(Vector3(0, 0, 6), Vector3(0, 0, 8))
	var turn_accel := Vector3(12, 0, 0)  # near the clamp, purely sideways
	var point := AIPassLead.lead_point(Vector3.ZERO, receiver, turn_accel, 14.0, 0.6)
	assert_almost_eq(point.x, 0.0, 0.05,
			"centripetal accel must not push the lead point sideways")
