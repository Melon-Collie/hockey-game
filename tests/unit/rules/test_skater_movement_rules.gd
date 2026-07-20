extends GutTest

# SkaterMovementRules — thrust, friction, max speed clamping with carry penalty.

func _default_cfg() -> SkaterMovementRules.MovementConfig:
	var cfg := SkaterMovementRules.MovementConfig.new()
	cfg.thrust = 20.0
	cfg.friction = 5.0
	cfg.max_speed = 10.0
	cfg.move_deadzone = 0.1
	cfg.brake_multiplier = 5.0
	cfg.puck_carry_speed_multiplier = 0.88
	cfg.backward_thrust_multiplier = 0.7
	cfg.crossover_thrust_multiplier = 0.85
	return cfg

func test_no_input_applies_friction() -> void:
	var result: Vector3 = SkaterMovementRules.apply_movement(
		Vector3(5, 0, 0), Vector2.ZERO, 0.0, false, false, 0.1, _default_cfg())
	var speed: float = Vector2(result.x, result.z).length()
	assert_lt(speed, 5.0, "friction should slow the skater")

func test_brake_slows_faster_than_friction() -> void:
	var no_brake: Vector3 = SkaterMovementRules.apply_movement(
		Vector3(5, 0, 0), Vector2.ZERO, 0.0, false, false, 0.1, _default_cfg())
	var with_brake: Vector3 = SkaterMovementRules.apply_movement(
		Vector3(5, 0, 0), Vector2.ZERO, 0.0, false, true, 0.1, _default_cfg())
	assert_lt(with_brake.length(), no_brake.length(), "braking removes more speed than idle friction")

func test_input_applies_thrust() -> void:
	var result: Vector3 = SkaterMovementRules.apply_movement(
		Vector3.ZERO, Vector2(1, 0), 0.0, false, false, 0.1, _default_cfg())
	assert_gt(result.x, 0.0, "thrust in +X direction should increase X velocity")

func test_deadzone_input_treated_as_no_input() -> void:
	var cfg := _default_cfg()
	# Input below the 0.1 deadzone should apply only friction, no thrust
	var result: Vector3 = SkaterMovementRules.apply_movement(
		Vector3(5, 0, 0), Vector2(0.01, 0), 0.0, false, false, 0.1, cfg)
	assert_lt(Vector2(result.x, result.z).length(), 5.0)

func test_puck_carry_reduces_max_speed() -> void:
	# Accelerate for a long time to hit the cap
	var cfg := _default_cfg()
	var v_free := Vector3.ZERO
	var v_carry := Vector3.ZERO
	for i in range(1000):
		v_free = SkaterMovementRules.apply_movement(v_free, Vector2(1, 0), 0.0, false, false, 0.01, cfg)
		v_carry = SkaterMovementRules.apply_movement(v_carry, Vector2(1, 0), 0.0, true, false, 0.01, cfg)
	var free_speed: float = Vector2(v_free.x, v_free.z).length()
	var carry_speed: float = Vector2(v_carry.x, v_carry.z).length()
	assert_lt(carry_speed, free_speed, "carrying the puck caps speed lower than free skating")
	assert_lt(carry_speed, cfg.max_speed, "carry speed should be below full max_speed")

func test_sprint_raises_top_speed() -> void:
	# Accelerate to the cap with and without sprint; sprint should settle higher.
	var cfg := _default_cfg()
	cfg.sprint_max_speed_multiplier = 1.3
	cfg.sprint_thrust_multiplier = 1.2
	var v_normal := Vector3.ZERO
	var v_sprint := Vector3.ZERO
	for i in range(1000):
		v_normal = SkaterMovementRules.apply_movement(v_normal, Vector2(1, 0), 0.0, false, false, 0.01, cfg, false)
		v_sprint = SkaterMovementRules.apply_movement(v_sprint, Vector2(1, 0), 0.0, false, false, 0.01, cfg, true)
	var normal_speed: float = Vector2(v_normal.x, v_normal.z).length()
	var sprint_speed: float = Vector2(v_sprint.x, v_sprint.z).length()
	assert_gt(sprint_speed, normal_speed, "sprint settles at a higher top speed")
	assert_almost_eq(sprint_speed, cfg.max_speed * cfg.sprint_max_speed_multiplier, 0.2,
		"sprint cap is max_speed × sprint_max_speed_multiplier")

func test_sprint_with_puck_waives_most_of_carry_penalty() -> void:
	# Sprinting with the puck is heads-down / straight-line, so most of the carry
	# speed penalty is waived (sprint_carry_penalty_bypass) — that's what lets a
	# fast carrier separate. A sprinting carrier tops out higher than a cruising
	# one, near max_speed × sprint × the bypassed carry mult.
	var cfg := _default_cfg()
	cfg.sprint_max_speed_multiplier = 1.3
	cfg.sprint_thrust_multiplier = 1.2
	cfg.puck_carry_speed_multiplier = 0.85   # 15% cruise carry penalty
	cfg.sprint_carry_penalty_bypass = 0.6    # waive 60% of it while sprinting
	var v_cruise := Vector3.ZERO
	var v_sprint := Vector3.ZERO
	for i in range(2000):
		v_cruise = SkaterMovementRules.apply_movement(v_cruise, Vector2(1, 0), 0.0, true, false, 0.01, cfg, false)
		v_sprint = SkaterMovementRules.apply_movement(v_sprint, Vector2(1, 0), 0.0, true, false, 0.01, cfg, true)
	var cruise_speed: float = Vector2(v_cruise.x, v_cruise.z).length()
	var sprint_speed: float = Vector2(v_sprint.x, v_sprint.z).length()
	assert_gt(sprint_speed, cruise_speed, "sprinting with the puck tops out faster than cruising with it")
	var eff_carry: float = lerpf(cfg.puck_carry_speed_multiplier, 1.0, cfg.sprint_carry_penalty_bypass)
	assert_almost_eq(sprint_speed, cfg.max_speed * cfg.sprint_max_speed_multiplier * eff_carry, 0.2,
		"sprint carry cap = max × sprint × the bypassed carry mult")

func test_sprint_carry_bypass_zero_keeps_full_penalty() -> void:
	# Default bypass (0.0) leaves the carry penalty fully in place even while
	# sprinting, so the pre-bypass behavior is preserved for callers that omit it.
	var cfg := _default_cfg()
	cfg.sprint_max_speed_multiplier = 1.3
	cfg.sprint_thrust_multiplier = 1.2
	cfg.puck_carry_speed_multiplier = 0.85
	# sprint_carry_penalty_bypass left at its 0.0 default.
	var v := Vector3.ZERO
	for i in range(2000):
		v = SkaterMovementRules.apply_movement(v, Vector2(1, 0), 0.0, true, false, 0.01, cfg, true)
	var speed: float = Vector2(v.x, v.z).length()
	assert_almost_eq(speed, cfg.max_speed * cfg.sprint_max_speed_multiplier * cfg.puck_carry_speed_multiplier, 0.2,
		"no bypass → sprint carry cap keeps the full carry penalty")

func test_sprint_inactive_matches_baseline() -> void:
	# Default multipliers + sprint_active=false must be a no-op vs the old 7-arg path.
	var cfg := _default_cfg()
	var with_default_arg: Vector3 = SkaterMovementRules.apply_movement(
		Vector3(3, 0, 0), Vector2(1, 0), 0.0, false, false, 0.01, cfg)
	var explicit_false: Vector3 = SkaterMovementRules.apply_movement(
		Vector3(3, 0, 0), Vector2(1, 0), 0.0, false, false, 0.01, cfg, false)
	assert_almost_eq(with_default_arg.x, explicit_false.x, 0.00001, "omitted sprint arg == sprint_active false")

func test_over_max_preserved_when_no_thrust() -> void:
	# Skater blasted by a body check to speed 20 — without new thrust input, the
	# clamp shouldn't yank them back to max_speed. Only friction erodes it.
	var cfg := _default_cfg()
	var boosted := Vector3(20, 0, 0)
	var result: Vector3 = SkaterMovementRules.apply_movement(
		boosted, Vector2.ZERO, 0.0, false, false, 0.01, cfg)
	# A single small step of friction should barely reduce 20
	assert_gt(Vector2(result.x, result.z).length(), cfg.max_speed,
		"over-max speed from external source should survive a single friction tick")

func test_backward_thrust_scaled_down() -> void:
	# Facing +Z means facing_dir is (-sin(0), -cos(0)) = (0, -1), so moving
	# in (0, 1) is aligned with facing — move_dot = -1 is backward.
	# Moving in (0, -1) is backward from facing. (0, 1) is forward. Let's test
	# that moving "behind" the skater applies reduced thrust.
	var cfg := _default_cfg()
	# With rotation_y = 0, forward is -Z direction; so move (0, 1) is backward
	var forward: Vector3 = SkaterMovementRules.apply_movement(
		Vector3.ZERO, Vector2(0, -1), 0.0, false, false, 0.1, cfg)
	var backward: Vector3 = SkaterMovementRules.apply_movement(
		Vector3.ZERO, Vector2(0, 1), 0.0, false, false, 0.1, cfg)
	# Forward thrust full; backward thrust scaled by backward_thrust_multiplier (0.7)
	assert_gt(forward.length(), backward.length(), "backward thrust should be weaker than forward")
