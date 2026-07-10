extends GutTest

# AISkaterCaps + the wiring that pushes a bot's attribute-scaled
# capabilities into its state machine. Covers: baseline defaults (so an unwired
# bot behaves as before), the time_to_arrive ref-speed parameter, score_shoot's
# shot-speed sensitivity, and that apply_capabilities derives the state
# machine's reach gates / self-speeds from the caps.


# ── Defaults reproduce the league baseline ──────────────────────────────────

func test_caps_defaults_equal_league_baseline() -> void:
	var caps := AISkaterCaps.new()
	assert_almost_eq(caps.max_speed, GameRules.DEFAULT_SKATER_MAX_SPEED_M_S, 0.001)
	assert_almost_eq(caps.blade_span,
			GameRules.DEFAULT_STICK_LENGTH_M + GameRules.DEFAULT_BLADE_LENGTH_M, 0.001)
	assert_almost_eq(caps.stick_reach, GameRules.DEFAULT_STICK_LENGTH_M, 0.001)
	assert_almost_eq(caps.wrister_shot_speed, GameRules.DEFAULT_WRISTER_POWER_MAX_M_S, 0.001)
	# Cross-player fields (used once a peer's real build is read) default to the
	# league baseline too, so a missing caps_by_peer entry reproduces old behaviour.
	assert_almost_eq(caps.weight, 1.0, 0.001)
	assert_almost_eq(caps.body_check_transfer, 0.45, 0.001)
	assert_almost_eq(caps.body_check_brace, 0.4, 0.001)
	assert_almost_eq(caps.handle_reach, AIActionScoring.EVADE_CARRY_HANDLE_M, 0.001,
			"handle reach defaults to the league carry-handle reach")


func test_role_context_self_speeds_default_to_baseline() -> void:
	# An unwired context (unit tests, no SM populating it) must carry the
	# baseline so the carrier scores exactly as it did before this change.
	var ctx := RoleContext.new()
	assert_almost_eq(ctx.self_max_speed, GameRules.DEFAULT_SKATER_MAX_SPEED_M_S, 0.001)
	assert_almost_eq(ctx.self_wrister_shot_speed, GameRules.DEFAULT_WRISTER_POWER_MAX_M_S, 0.001)


# ── time_to_arrive ref-speed parameter ──────────────────────────────────────

func test_time_to_arrive_default_matches_explicit_baseline() -> void:
	var from := Vector3(0, 0, 0)
	var dest := Vector3(0, 0, 10)
	var implicit := AIActionScoring.time_to_arrive(from, dest, Vector3.ZERO)
	var explicit := AIActionScoring.time_to_arrive(
			from, dest, Vector3.ZERO, AIActionScoring.SKATER_REF_SPEED_M_S)
	assert_almost_eq(implicit, explicit, 0.0001,
			"omitting ref_speed must equal passing the baseline (back-compat)")


func test_time_to_arrive_faster_skater_arrives_sooner() -> void:
	var from := Vector3(0, 0, 0)
	var dest := Vector3(0, 0, 10)
	var slow := AIActionScoring.time_to_arrive(from, dest, Vector3.ZERO, 8.0)
	var fast := AIActionScoring.time_to_arrive(from, dest, Vector3.ZERO, 11.0)
	assert_lt(fast, slow, "a higher ref speed must yield a shorter arrival time")


# ── score_shoot shot-speed sensitivity ──────────────────────────────────────

func test_score_shoot_non_decreasing_in_shot_speed() -> void:
	# A faster shot gives a lane defender less reaction time, so shot quality
	# is non-decreasing in shot speed for the same geometry. Defender placed
	# in the lane so the term actually bites.
	var shooter := Vector3(0, 0, 5)
	var goal := Vector3(0, 0, -GameRules.GOAL_LINE_Z)
	var goalie := Vector3(0, 0, goal.z + 1.0)
	var defenders: Array[Vector3] = [Vector3(0.3, 0, 2.0)]
	var slow := AIActionScoring.score_shoot(
			shooter, goal, goalie, GameRules.NET_HALF_WIDTH, defenders, 16.0)
	var fast := AIActionScoring.score_shoot(
			shooter, goal, goalie, GameRules.NET_HALF_WIDTH, defenders, 28.0)
	assert_gte(fast, slow,
			"faster shot should score >= slower shot through the same lane")


# ── apply_capabilities wires the state machine ──────────────────────────────

func _caps(span: float, max_speed: float, accel: float,
		shot: float) -> AISkaterCaps:
	var c := AISkaterCaps.new()
	c.blade_span = span
	c.max_speed = max_speed
	c.max_accel = accel
	c.wrister_shot_speed = shot
	return c


func test_apply_capabilities_derives_reach_gates_and_speeds() -> void:
	var sm := SkaterAgentStateMachine.new()
	var caps := _caps(2.0, 10.5, 13.0, 27.0)
	sm.apply_capabilities(caps)
	# Reach gates derive from blade_span + the SM's own buffers.
	assert_almost_eq(sm._blade_reach,
			2.0 + SkaterAgentStateMachine.BLADE_REACH_BUFFER_M, 0.001)
	assert_almost_eq(sm._poke_jab_reach, 2.0 + GameRules.POKE_RADIUS_M, 0.001)
	assert_almost_eq(sm._receive_body_offset,
			2.0 - SkaterAgentStateMachine.RECEIVE_BODY_INSET_M, 0.001)
	# Scalars pass straight through.
	assert_almost_eq(sm._self_max_speed, 10.5, 0.001)
	assert_almost_eq(sm._chase_max_accel, 13.0, 0.001)
	assert_almost_eq(sm._self_wrister_shot_speed, 27.0, 0.001)


func test_apply_capabilities_null_is_noop() -> void:
	var sm := SkaterAgentStateMachine.new()
	var baseline_reach: float = sm._blade_reach
	var baseline_speed: float = sm._self_max_speed
	sm.apply_capabilities(null)
	assert_almost_eq(sm._blade_reach, baseline_reach, 0.001,
			"null caps must leave the league-default reach untouched")
	assert_almost_eq(sm._self_max_speed, baseline_speed, 0.001)


func test_unwired_state_machine_uses_baseline_reach() -> void:
	# A freshly constructed SM (no capabilities applied) reaches exactly as
	# the old const did, so non-attribute paths are unchanged.
	var sm := SkaterAgentStateMachine.new()
	assert_almost_eq(sm._blade_reach, SkaterAgentStateMachine.BLADE_REACH_M, 0.001)
