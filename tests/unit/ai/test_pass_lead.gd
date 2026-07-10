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


func _caps(max_speed: float, max_accel: float) -> AISkaterCaps:
	var c := AISkaterCaps.new()
	c.max_speed = max_speed
	c.max_accel = max_accel
	return c


func test_lead_caps_projected_speed_to_receiver_top_speed() -> void:
	# A receiver cruising at 8 m/s up-ice with a strong along-travel accel. A slow
	# receiver (max_speed 8) can't get past 8, so it's led LESS far than a fast one
	# (max_speed 12) that keeps accelerating into open ice. Same observed motion —
	# only the attribute cap differs.
	var receiver := _receiver(Vector3(0, 0, 6), Vector3(0, 0, 8))
	var accel := Vector3(0, 0, 6)  # still accelerating up-ice
	var slow := AIPassLead.lead_point(Vector3.ZERO, receiver, accel, 20.0, 0.6, _caps(8.0, 12.0))
	var fast := AIPassLead.lead_point(Vector3.ZERO, receiver, accel, 20.0, 0.6, _caps(12.0, 12.0))
	assert_gt(fast.z, slow.z, "a faster receiver is led further into the open ice")


func test_lead_caps_accel_to_receiver_thrust() -> void:
	# Same observed accel, but a low-Agility receiver can't sustain it — its
	# along-travel accel is clamped to its real thrust, so it's led less far than a
	# high-Agility receiver. Speed cap held equal so only the accel cap differs.
	var receiver := _receiver(Vector3(0, 0, 6), Vector3(0, 0, 3))
	var accel := Vector3(0, 0, 30)  # a spike well above any real thrust
	var sluggish := AIPassLead.lead_point(Vector3.ZERO, receiver, accel, 20.0, 0.6, _caps(20.0, 6.0))
	var quick := AIPassLead.lead_point(Vector3.ZERO, receiver, accel, 20.0, 0.6, _caps(20.0, 14.0))
	assert_gt(quick.z, sluggish.z, "a more agile receiver accelerates further into the lead")


func test_lead_does_not_under_lead_a_sprinting_receiver() -> void:
	# A receiver already moving above its base max_speed (mid-sprint — sprint
	# raises the real cap) must NOT be under-led: the speed cap is the LARGER of the
	# base max_speed and the current speed, so it never brakes observed motion.
	var receiver := _receiver(Vector3(0, 0, 6), Vector3(0, 0, 11))  # 11 > base 9
	var over_cap := AIPassLead.lead_point(Vector3.ZERO, receiver, Vector3.ZERO, 22.0, 0.6, _caps(9.0, 12.0))
	var uncapped := AIPassLead.lead_point(Vector3.ZERO, receiver, Vector3.ZERO, 22.0, 0.6)
	# With no accel and an already-fast receiver, the base-9 cap must not pull the
	# lead in short of where the receiver actually skates.
	assert_gte(over_cap.z, uncapped.z - 0.01,
			"a sprinting receiver is led to its real speed, not braked to base")


func test_lead_null_caps_matches_league_default() -> void:
	# Back-compat: omitting caps must equal passing a league-baseline caps, so
	# unwired callers (and every existing test) are byte-for-byte unchanged.
	var receiver := _receiver(Vector3(1, 0, 5), Vector3(1, 0, 4))
	var accel := Vector3(0, 0, 2)
	var no_caps := AIPassLead.lead_point(Vector3.ZERO, receiver, accel, 16.0, 0.6)
	var league := AIPassLead.lead_point(Vector3.ZERO, receiver, accel, 16.0, 0.6,
			_caps(GameRules.DEFAULT_SKATER_MAX_SPEED_M_S, GameRules.DEFAULT_SKATER_THRUST_M_S2))
	assert_almost_eq(no_caps.z, league.z, 0.001)
	assert_almost_eq(no_caps.x, league.x, 0.001)


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


# ── effective_flight_speed: friction-aware lead ─────────────────────────────

func test_effective_flight_speed_below_launch_and_drops_with_distance() -> void:
	# The puck sheds speed in flight, so its average speed is below launch, and
	# more so over a longer pass.
	var launch := 20.0
	var near: float = AIPassLead.effective_flight_speed(launch, 5.0)
	var far: float = AIPassLead.effective_flight_speed(launch, 25.0)
	assert_lt(near, launch, "average flight speed is below the launch speed")
	assert_lt(far, near, "a longer pass averages even slower")
	# Closed form at 25 m: arrival = √(20² − 2·a·25), avg = (20 + arrival)/2.
	var arrival: float = sqrt(400.0 - 2.0 * GameRules.PUCK_ICE_DECEL_M_S2 * 25.0)
	assert_almost_eq(far, (20.0 + arrival) * 0.5, 0.001)


func test_effective_flight_speed_negligible_at_zero_distance() -> void:
	# A point-blank pass hasn't decelerated yet → average ≈ launch.
	assert_almost_eq(AIPassLead.effective_flight_speed(18.0, 0.0), 18.0, 0.001)


func test_friction_leads_a_long_pass_further_than_constant_speed() -> void:
	# A receiver cutting up-ice, led over a long pass. Because the puck slows in
	# flight, the friction-aware lead must sit further ahead than a naive
	# constant-launch-speed lead (longer flight time → receiver travels further).
	var receiver := _receiver(Vector3(0, 0, 20), Vector3(0, 0, 6))
	var launch := 20.0
	var friction_aware: float = AIPassLead.lead_point(
			Vector3.ZERO, receiver, Vector3.ZERO, launch, 1.5).z
	# Constant-speed reference: feed intercept_time the raw launch speed.
	var eff_t: float = AITrajectory.intercept_time(
			Vector3.ZERO, Vector3(0, 0, 20), Vector3(0, 0, 6), Vector3.ZERO, launch, 1.5)
	var constant_speed: float = AITrajectory.predict_at(
			Vector3(0, 0, 20), Vector3(0, 0, 6), eff_t).z
	assert_gt(friction_aware, constant_speed,
			"friction-aware lead sits further ahead than the constant-speed lead")
