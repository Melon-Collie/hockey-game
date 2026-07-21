class_name SkaterMovementRules

# Pure movement math extracted from SkaterController._apply_movement.
# Takes current state + input + tuning config, returns the new velocity.
# The caller (SkaterController) still owns the state machine guard (slapper
# charge windup, etc.); this function just does the physics.

class MovementConfig:
	var thrust: float = 0.0                      # forward thrust magnitude
	var friction: float = 0.0                    # base friction applied each tick
	var max_speed: float = 0.0                   # maximum horizontal speed
	var move_deadzone: float = 0.0               # stick deadzone
	var brake_multiplier: float = 0.0            # friction multiplier when braking
	var puck_carry_speed_multiplier: float = 0.0 # max speed reduction while carrying
	var backward_thrust_multiplier: float = 0.0  # thrust scale when moving against facing
	var crossover_thrust_multiplier: float = 0.0 # thrust scale when moving perpendicular to facing
	var friction_drag: float = 0.0               # velocity-proportional drag coefficient (m/s² per m/s)
	var sprint_thrust_multiplier: float = 1.0     # thrust boost while sprinting (modest, to reach the cap)
	var sprint_max_speed_multiplier: float = 1.0  # top-speed boost while sprinting (the headline effect)
	var sprint_carry_penalty_bypass: float = 0.0  # fraction of the carry speed penalty waived WHILE sprinting (heads-down straight-line flat-out); 0 = no bypass
	# Lateral grip — the edges' authority to REDIRECT momentum. Scales only the
	# component of thrust perpendicular to the current motion, so straight-line
	# drive (and slowing down) is untouched and 1.0 is an exact no-op. The
	# emergent turn radius is v²/(grip·a_perp) — the F = mv²/r seam that agility
	# (and later the skate-profile gear) actually owns: sub-1.0 turns wide AT
	# SPEED while a standing start keeps full authority (no momentum to fight).
	var lateral_grip: float = 1.0

# Below this horizontal speed (m/s) the grip decomposition is skipped: there is
# no meaningful momentum to redirect, and the velocity direction is numerically
# unstable. A standing start always gets full thrust authority.
const GRIP_MIN_SPEED: float = 0.5


static func apply_movement(
		current_velocity: Vector3,
		move_input: Vector2,
		facing_rotation_y: float,
		has_puck: bool,
		brake: bool,
		delta: float,
		cfg: MovementConfig,
		sprint_active: bool = false) -> Vector3:
	var velocity: Vector3 = current_velocity
	# Sprint multiplies the base thrust and (mainly) the speed cap. Default 1.0
	# multipliers + sprint_active=false make this a no-op for non-sprint callers.
	var sprint_thrust: float = cfg.sprint_thrust_multiplier if sprint_active else 1.0
	var sprint_max: float = cfg.sprint_max_speed_multiplier if sprint_active else 1.0

	if not brake and move_input.length() > cfg.move_deadzone:
		# NORMAL: apply thrust in the input direction, scaled by facing alignment.
		var thrust_dir := Vector3(move_input.x, 0.0, move_input.y)
		var facing_dir := Vector2(-sin(facing_rotation_y), -cos(facing_rotation_y))
		var move_dot: float = facing_dir.dot(move_input.normalized())

		var thrust_scale: float
		if move_dot >= 0.0:
			thrust_scale = lerpf(cfg.crossover_thrust_multiplier, 1.0, move_dot)
		else:
			thrust_scale = lerpf(cfg.backward_thrust_multiplier, cfg.crossover_thrust_multiplier, move_dot + 1.0)

		var applied_thrust: float = cfg.thrust * sprint_thrust
		var thrust_vec: Vector3 = thrust_dir * applied_thrust * thrust_scale
		# Lateral grip: decompose the thrust against the current motion and scale
		# only the perpendicular component (see MovementConfig.lateral_grip). The
		# parallel component — driving on, or slowing down — always passes whole,
		# and grip 1.0 recomposes exactly (guarded out as a no-op).
		if cfg.lateral_grip != 1.0:
			var vel_dir := Vector2(current_velocity.x, current_velocity.z)
			if vel_dir.length() > GRIP_MIN_SPEED:
				vel_dir = vel_dir.normalized()
				var t2 := Vector2(thrust_vec.x, thrust_vec.z)
				var par: Vector2 = vel_dir * t2.dot(vel_dir)
				var gripped: Vector2 = par + (t2 - par) * cfg.lateral_grip
				thrust_vec = Vector3(gripped.x, 0.0, gripped.y)
		var thrust_delta: Vector3 = thrust_vec * delta
		velocity += thrust_delta

		# Speed cap — but preserve over-max speed from external sources (body
		# check boost, etc.) so we don't instantly clamp a legitimate momentum gain.
		var base_max: float = cfg.max_speed * sprint_max
		# Sprinting with the puck is heads-down and straight-line (the turn radius
		# blows up anyway), so most of the carry speed penalty is waived while
		# sprinting — that's what lets a fast carrier actually run. The 1.6x sprint
		# stamina drain (StaminaRules) is the real cost of carrying at speed.
		var carry_mult: float = cfg.puck_carry_speed_multiplier
		if sprint_active:
			carry_mult = lerpf(carry_mult, 1.0, cfg.sprint_carry_penalty_bypass)
		var effective_max: float = base_max * carry_mult if has_puck else base_max
		var horiz := Vector2(velocity.x, velocity.z)
		var speed: float = horiz.length()
		if speed > effective_max:
			var pre_thrust_speed: float = Vector2(
				velocity.x - thrust_delta.x,
				velocity.z - thrust_delta.z
			).length()
			var target_speed: float = maxf(pre_thrust_speed, effective_max)
			if speed > target_speed:
				var limited: Vector2 = horiz.normalized() * target_speed
				velocity.x = limited.x
				velocity.z = limited.y

	# Friction: heavy when braking (regardless of direction input), normal otherwise.
	var horiz_vel := Vector2(velocity.x, velocity.z)
	var base_decel: float = cfg.friction + cfg.friction_drag * horiz_vel.length()
	var effective_friction: float = base_decel * cfg.brake_multiplier if brake else base_decel
	horiz_vel = horiz_vel.move_toward(Vector2.ZERO, effective_friction * delta)
	velocity.x = horiz_vel.x
	velocity.z = horiz_vel.y
	return velocity
