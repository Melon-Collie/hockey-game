extends GutTest

# Repro probe for the reported "crash sprinting backwards online".
# 1. Confirms how Godot's Vector2.normalized() behaves on a (near-)zero vector.
# 2. Drives the real SkaterMovementRules.apply_movement loop with sprint + backward
#    input, round-tripping velocity through the wire quantization (the online
#    reconcile snap) every tick, and asserts velocity/position never go NaN/Inf.

func _is_finite_v3(v: Vector3) -> bool:
	return is_finite(v.x) and is_finite(v.y) and is_finite(v.z)

# Mirror of WorldStateCodec velocity quantization (encode *50 round, decode /50).
func _quantize_vel(v: Vector3) -> Vector3:
	return Vector3(
		clampi(roundi(v.x * 50.0), -32768, 32767) / 50.0,
		clampi(roundi(v.y * 50.0), -32768, 32767) / 50.0,
		clampi(roundi(v.z * 50.0), -32768, 32767) / 50.0)

func test_zero_vector_normalized_behavior() -> void:
	var n: Vector2 = Vector2.ZERO.normalized()
	gut.p("Vector2.ZERO.normalized() = %s  is_finite=%s" % [n, is_finite(n.x) and is_finite(n.y)])
	# Godot 4 returns Vector2.ZERO for a zero-length normalize (no NaN).
	assert_true(is_finite(n.x) and is_finite(n.y),
		"zero normalize should NOT be NaN in Godot 4")

func _cfg() -> SkaterMovementRules.MovementConfig:
	var cfg := SkaterMovementRules.MovementConfig.new()
	cfg.thrust = 10.5
	cfg.friction = 5.0
	cfg.friction_drag = 0.5
	cfg.max_speed = 8.0
	cfg.move_deadzone = 0.1
	cfg.brake_multiplier = 5.0
	cfg.puck_carry_speed_multiplier = 0.86
	cfg.backward_thrust_multiplier = 0.55
	cfg.crossover_thrust_multiplier = 0.75
	cfg.sprint_thrust_multiplier = 1.20
	cfg.sprint_max_speed_multiplier = 1.18
	return cfg

func test_sprint_backward_with_quantization_never_nan() -> void:
	var cfg := _cfg()
	var delta: float = 1.0 / 120.0
	# Facing forward (rotation_y = 0 → facing -Z). Backward input is +Z = (0, 1).
	var backward := Vector2(0, 1)
	for has_puck in [false, true]:
		var velocity := Vector3.ZERO
		var position := Vector3.ZERO
		var all_finite: bool = true
		for i in range(2000):
			velocity = SkaterMovementRules.apply_movement(
				velocity, backward, 0.0, has_puck, false, delta, cfg, true)
			# Every other tick, emulate the online reconcile: snap to the
			# wire-quantized server value (what LocalController.reconcile does).
			if i % 2 == 0:
				velocity = _quantize_vel(velocity)
			position += velocity * delta
			all_finite = all_finite and _is_finite_v3(velocity) and _is_finite_v3(position)
		assert_true(all_finite, "velocity/position stayed finite (has_puck=%s)" % has_puck)
		var spd: float = Vector2(velocity.x, velocity.z).length()
		assert_lte(spd, cfg.max_speed * cfg.sprint_max_speed_multiplier + 0.5,
			"backward sprint speed stays bounded by the sprint cap (has_puck=%s)" % has_puck)

func test_sprint_release_over_cap_then_backward_never_nan() -> void:
	# Build forward sprint speed over the cap, release sprint, then reverse —
	# exercises the "preserve over-max" branch in both directions.
	var cfg := _cfg()
	var delta: float = 1.0 / 120.0
	var velocity := Vector3.ZERO
	# Forward sprint (input (0,-1)) to the sprint cap.
	for i in range(600):
		velocity = SkaterMovementRules.apply_movement(
			velocity, Vector2(0, -1), 0.0, false, false, delta, cfg, true)
		velocity = _quantize_vel(velocity)
	# Now reverse with sprint released, quantizing each tick.
	var all_finite: bool = true
	for i in range(600):
		velocity = SkaterMovementRules.apply_movement(
			velocity, Vector2(0, 1), 0.0, false, false, delta, cfg, false)
		velocity = _quantize_vel(velocity)
		all_finite = all_finite and _is_finite_v3(velocity)
	assert_true(all_finite, "velocity stayed finite through over-cap reverse")
