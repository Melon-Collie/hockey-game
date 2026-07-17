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

# Mirror SkaterController.apply_attributes' engine/handling composition: thrust
# scales with Speed (the forward engine); the off-axis multipliers scale with
# Agility divided by Speed's thrust scaling, so cut acceleration reads ONLY
# Agility. Base values arbitrary — the guarantee is scale-invariant.
func _attr_cfg(attrs: PlayerAttributes) -> SkaterMovementRules.MovementConfig:
	var cfg := _default_cfg()
	cfg.thrust = 20.0 * attrs.speed_accel_mult()
	var m_cut: float = attrs.agility_cut_mult() / attrs.speed_accel_mult()
	cfg.crossover_thrust_multiplier = 0.85 * m_cut
	cfg.backward_thrust_multiplier = 0.7 * m_cut
	return cfg

func test_cut_acceleration_reads_agility_never_speed() -> void:
	# The engine/handling guarantee: a jet (Speed 5 / Agility 1) launches harder
	# on the straight, but the agile skater (Speed 1 / Agility 5) out-accelerates
	# it on the perpendicular cut — and cut acceleration is IDENTICAL across all
	# Speed levels at fixed Agility (Speed's scaling divides back out), so a
	# faster skater is never the more elusive one.
	var jet := PlayerAttributes.new(5, 1, 3, 3, 3, 3)
	var agile := PlayerAttributes.new(1, 5, 3, 3, 3, 3)
	# Forward launch (input along facing, -Z at rotation 0): the jet wins.
	var fwd_jet: Vector3 = SkaterMovementRules.apply_movement(
		Vector3.ZERO, Vector2(0, -1), 0.0, false, false, 0.1, _attr_cfg(jet))
	var fwd_agile: Vector3 = SkaterMovementRules.apply_movement(
		Vector3.ZERO, Vector2(0, -1), 0.0, false, false, 0.1, _attr_cfg(agile))
	assert_gt(fwd_jet.length(), fwd_agile.length(), "Speed owns the straight-line launch")
	# Perpendicular cut (input at 90° to facing): the agile skater wins.
	var cut_jet: Vector3 = SkaterMovementRules.apply_movement(
		Vector3.ZERO, Vector2(1, 0), 0.0, false, false, 0.1, _attr_cfg(jet))
	var cut_agile: Vector3 = SkaterMovementRules.apply_movement(
		Vector3.ZERO, Vector2(1, 0), 0.0, false, false, 0.1, _attr_cfg(agile))
	assert_gt(cut_agile.length(), cut_jet.length(), "Agility owns the cut")
	# And Speed contributes NOTHING to the cut: any Speed level at the same
	# Agility yields an identical perpendicular launch.
	var reference: Vector3 = SkaterMovementRules.apply_movement(
		Vector3.ZERO, Vector2(1, 0), 0.0, false, false, 0.1,
		_attr_cfg(PlayerAttributes.new(3, 4, 3, 3, 3, 3)))
	for speed_level: int in range(PlayerAttributes.LEVEL_MIN, PlayerAttributes.LEVEL_MAX + 1):
		var a := PlayerAttributes.new(speed_level, 4, 3, 3, 3, 3)
		var cut: Vector3 = SkaterMovementRules.apply_movement(
			Vector3.ZERO, Vector2(1, 0), 0.0, false, false, 0.1, _attr_cfg(a))
		assert_almost_eq(cut.length(), reference.length(), 0.0001,
			"cut acceleration must be independent of Speed (level %d)" % speed_level)
