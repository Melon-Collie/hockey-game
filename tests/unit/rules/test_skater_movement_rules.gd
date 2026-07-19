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


# ── integrate_forward (stage-3 remote forward-prediction primitive) ────────────

func test_integrate_forward_zero_ticks_is_identity() -> void:
	var r := SkaterMovementRules.ForwardResult.new()
	var pos := Vector3(3, 0, 4)
	var vel := Vector3(5, 0, 0)
	SkaterMovementRules.integrate_forward(pos, vel, Vector2(1, 0), 0.0,
		false, false, false, _default_cfg(), 0.01, 0, 0, r)
	assert_eq(r.position, pos, "0 ticks leaves position unchanged")
	assert_eq(r.velocity, vel, "0 ticks leaves velocity unchanged")


func test_integrate_forward_negative_ticks_clamped() -> void:
	var r := SkaterMovementRules.ForwardResult.new()
	var pos := Vector3(3, 0, 4)
	var vel := Vector3(5, 0, 0)
	SkaterMovementRules.integrate_forward(pos, vel, Vector2(1, 0), 0.0,
		false, false, false, _default_cfg(), 0.01, -5, 0, r)
	assert_eq(r.position, pos, "negative ticks treated as zero — no integration")


func test_integrate_forward_matches_sequential_apply_movement() -> void:
	# The whole point: with NO decay the primitive must equal N hand-rolled
	# apply_movement steps with position accumulation — the client render and host
	# rewind both call it, so its equivalence to the live per-tick math is what keeps
	# them aligned. (intent_decay_ticks = 0 -> full intent every tick.)
	var cfg := _default_cfg()
	var pos := Vector3(0, 0, 0)
	var vel := Vector3(2, 0, 1)
	var mv := Vector2(1, 0)
	var expect_pos := pos
	var expect_vel := vel
	for _i in 9:
		expect_vel = SkaterMovementRules.apply_movement(expect_vel, mv, 0.0, false, false, 0.0083, cfg, false)
		expect_pos += expect_vel * 0.0083
	var r := SkaterMovementRules.ForwardResult.new()
	SkaterMovementRules.integrate_forward(pos, vel, mv, 0.0, false, false, false, cfg, 0.0083, 9, 0, r)
	assert_almost_eq(r.velocity.x, expect_vel.x, 1e-6)
	assert_almost_eq(r.velocity.z, expect_vel.z, 1e-6)
	assert_almost_eq(r.position.x, expect_pos.x, 1e-6)
	assert_almost_eq(r.position.z, expect_pos.z, 1e-6)


func test_integrate_forward_is_deterministic() -> void:
	# render == rewind rests on this: identical inputs (incl. the decay) must give
	# identical output, so the host's rewind reconstruction lands exactly where the
	# client rendered.
	var cfg := _default_cfg()
	var a := SkaterMovementRules.ForwardResult.new()
	var b := SkaterMovementRules.ForwardResult.new()
	SkaterMovementRules.integrate_forward(Vector3(1, 0, 2), Vector3(4, 0, -3),
		Vector2(0, 1), 1.2, true, false, true, cfg, 0.0083, 9, 5, a)
	SkaterMovementRules.integrate_forward(Vector3(1, 0, 2), Vector3(4, 0, -3),
		Vector2(0, 1), 1.2, true, false, true, cfg, 0.0083, 9, 5, b)
	assert_eq(a.position, b.position, "same inputs -> same predicted position")
	assert_eq(a.velocity, b.velocity, "same inputs -> same predicted velocity")


func test_integrate_forward_coasts_to_a_stop_with_no_input() -> void:
	var cfg := _default_cfg()
	var r := SkaterMovementRules.ForwardResult.new()
	SkaterMovementRules.integrate_forward(Vector3(6, 0, 0), Vector3(6, 0, 0),
		Vector2.ZERO, 0.0, false, false, false, cfg, 0.0083, 9, 0, r)
	assert_lt(Vector2(r.velocity.x, r.velocity.z).length(), 6.0,
		"no input -> friction bleeds speed over the prediction window")
	assert_gt(r.position.x, 6.0, "still drifts forward while decelerating")


func test_integrate_forward_intent_decay_reduces_thrust_travel() -> void:
	# RL-style decay: fading the assumed intent to 0 over the window applies less
	# thrust than holding it full, so a thrusting skater travels LESS far — the
	# mechanism that tames overshoot when the real player cuts. From rest so the
	# only forward motion is the (decayed vs full) thrust.
	var cfg := _default_cfg()
	var full := SkaterMovementRules.ForwardResult.new()
	var decayed := SkaterMovementRules.ForwardResult.new()
	SkaterMovementRules.integrate_forward(Vector3.ZERO, Vector3.ZERO, Vector2(1, 0),
		0.0, false, false, false, cfg, 0.0083, 9, 0, full)   # no decay
	SkaterMovementRules.integrate_forward(Vector3.ZERO, Vector3.ZERO, Vector2(1, 0),
		0.0, false, false, false, cfg, 0.0083, 9, 5, decayed)  # decay over 5 ticks
	assert_lt(decayed.position.x, full.position.x, "decayed intent applies less thrust -> less travel")
	assert_lt(decayed.velocity.x, full.velocity.x, "decayed intent -> lower end speed")
	assert_gt(decayed.position.x, 0.0, "but still moves forward (near ticks apply near-full intent)")
