extends GutTest

# Parity fuzz: NativeSkaterMovement (C++ GDExtension, native/src/) against the
# GDScript reference SkaterMovementRules. apply_movement is stateless, so this
# is a wide random sweep; integrate_forward additionally checks the native
# internal loop (N ticks behind one boundary crossing) against the GDScript
# loop, including the stagger-decay thrust path and the transient cfg.thrust
# restore. Goes pending when the extension isn't built.

const TOLERANCE: float = 0.001
const FUZZ_ITERATIONS: int = 2000
const SEED: int = 0x4D4F5645  # "MOVE"

var _rng := RandomNumberGenerator.new()


func before_each() -> void:
	_rng.seed = SEED


func _native_missing() -> bool:
	if ClassDB.class_exists(&"NativeSkaterMovement"):
		return false
	NativeParityGuard.report_missing(self, "NativeSkaterMovement")
	return true


func _random_cfg() -> SkaterMovementRules.MovementConfig:
	var cfg := SkaterMovementRules.MovementConfig.new()
	cfg.thrust = _rng.randf_range(5.0, 30.0)
	cfg.friction = _rng.randf_range(1.0, 8.0)
	cfg.max_speed = _rng.randf_range(5.0, 12.0)
	cfg.move_deadzone = _rng.randf_range(0.0, 0.2)
	cfg.brake_multiplier = _rng.randf_range(1.5, 5.0)
	cfg.puck_carry_speed_multiplier = _rng.randf_range(0.7, 1.0)
	cfg.backward_thrust_multiplier = _rng.randf_range(0.3, 0.8)
	cfg.crossover_thrust_multiplier = _rng.randf_range(0.5, 0.9)
	cfg.friction_drag = _rng.randf_range(0.0, 0.5)
	cfg.sprint_thrust_multiplier = _rng.randf_range(1.0, 1.4)
	cfg.sprint_max_speed_multiplier = _rng.randf_range(1.0, 1.4)
	cfg.sprint_carry_penalty_bypass = _rng.randf_range(0.0, 1.0)
	cfg.lateral_grip = 1.0 if _rng.randf() < 0.3 else _rng.randf_range(0.3, 1.2)
	return cfg


func _native_from(cfg: SkaterMovementRules.MovementConfig) -> RefCounted:
	var native: RefCounted = ClassDB.instantiate(&"NativeSkaterMovement")
	var missing: String = native.configure(cfg)
	assert_eq(missing, "", "MovementConfig properties missing: %s" % missing)
	return native


func test_apply_movement_matches_native() -> void:
	if _native_missing():
		return
	for i: int in FUZZ_ITERATIONS:
		var cfg: SkaterMovementRules.MovementConfig = _random_cfg()
		var native: RefCounted = _native_from(cfg)
		var vel := Vector3(_rng.randf_range(-14.0, 14.0), 0.0, _rng.randf_range(-14.0, 14.0))
		var input := Vector2.ZERO
		if _rng.randf() < 0.85:
			input = Vector2(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0))
		var facing: float = _rng.randf_range(-PI, PI)
		var has_puck: bool = _rng.randf() < 0.5
		var brake: bool = _rng.randf() < 0.25
		var sprint: bool = _rng.randf() < 0.3
		var delta: float = 1.0 / 120.0 if _rng.randf() < 0.8 else _rng.randf_range(0.004, 0.05)

		var gd: Vector3 = SkaterMovementRules.apply_movement(
				vel, input, facing, has_puck, brake, delta, cfg, sprint)
		var cpp: Vector3 = native.apply_movement(
				vel, input, facing, has_puck, brake, delta, sprint)
		var err: float = gd.distance_to(cpp)
		if err > TOLERANCE:
			fail_test("apply_movement diverged at iter %d: gd=%s cpp=%s err=%f" % [i, gd, cpp, err])
			return
	pass_test("%d apply_movement fuzz cases within %f" % [FUZZ_ITERATIONS, TOLERANCE])


func test_integrate_forward_matches_native() -> void:
	if _native_missing():
		return
	var result := SkaterMovementRules.ForwardResult.new()
	for i: int in 400:
		var cfg: SkaterMovementRules.MovementConfig = _random_cfg()
		var native: RefCounted = _native_from(cfg)
		var body_cfg := BodyCheckRules.Config.new()
		native.set_stagger_params(body_cfg.max_stagger_seconds, body_cfg.max_thrust_penalty)

		var pos := Vector3(_rng.randf_range(-10.0, 10.0), 0.0, _rng.randf_range(-20.0, 20.0))
		var vel := Vector3(_rng.randf_range(-8.0, 8.0), 0.0, _rng.randf_range(-8.0, 8.0))
		var input := Vector2(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0))
		var facing: float = _rng.randf_range(-PI, PI)
		var has_puck: bool = _rng.randf() < 0.5
		var brake: bool = _rng.randf() < 0.15
		var sprint: bool = _rng.randf() < 0.3
		var dt: float = 1.0 / 120.0
		var ticks: int = _rng.randi_range(0, 60)
		var decay: int = 0 if _rng.randf() < 0.4 else _rng.randi_range(5, 40)
		var stagger: float = 0.0 if _rng.randf() < 0.5 else _rng.randf_range(0.05, 1.0)
		var pre_thrust: float = cfg.thrust

		SkaterMovementRules.integrate_forward(pos, vel, input, facing, has_puck,
				brake, sprint, cfg, dt, ticks, decay, result, stagger,
				body_cfg if stagger > 0.0 else null)
		native.integrate_forward(pos, vel, input, facing, has_puck, brake, sprint,
				dt, ticks, decay, stagger, stagger > 0.0)

		assert_eq(cfg.thrust, pre_thrust, "cfg.thrust restored after integrate_forward")
		var pos_err: float = result.position.distance_to(native.get_forward_position())
		var vel_err: float = result.velocity.distance_to(native.get_forward_velocity())
		if pos_err > TOLERANCE or vel_err > TOLERANCE:
			fail_test("integrate_forward diverged at iter %d: pos_err=%f vel_err=%f ticks=%d" % [
					i, pos_err, vel_err, ticks])
			return
	pass_test("400 integrate_forward fuzz cases within %f" % TOLERANCE)
