class_name SkaterPoseCoordinator
extends RefCounted

# Owns the per-tick pose layer: facing, upper-body twist/lean, velocity lean,
# lower-body lag, and head tracking. Stateless transforms live on the rules
# layer; this class carries the smoothed runtime state plus angular-velocity
# bookkeeping for network export.
#
# Pose state is read by LocalController.reconcile (facing snap, IK lock reset,
# lower-body-lag reset, post-replay re-apply) and by SkaterController to seed
# the upper-body angular-velocity tracker — kept public so those callsites
# stay terse.

const State = SkaterStateMachine.State

# ── Runtime State ─────────────────────────────────────────────────────────────
var facing: Vector2 = Vector2.DOWN
var upper_body_angle: float = 0.0
var upper_body_lean: float = 0.0
var velocity_lean_x: float = 0.0
var velocity_lean_z: float = 0.0
var lower_body_lag: float = 0.0
var head_angle: float = 0.0
var ik_locked_side: int = 0  # +1 = exited right, -1 = exited left, 0 = unlocked

# ── Angular-Velocity Tracking ─────────────────────────────────────────────────
var facing_angular_velocity: float = 0.0
var upper_body_angular_velocity: float = 0.0
var _prev_facing_angle: float = 0.0
var _prev_upper_body_angle: float = 0.0

# ── References ────────────────────────────────────────────────────────────────
var _skater: Skater = null
var _sm: SkaterStateMachine = null
var _controller: SkaterController = null  # tunables live as @export on the controller

func setup(skater: Skater, sm: SkaterStateMachine, controller: SkaterController) -> void:
	_skater = skater
	_sm = sm
	_controller = controller
	_prev_facing_angle = atan2(facing.x, facing.y)
	_prev_upper_body_angle = upper_body_angle

# ── Per-Tick Application ──────────────────────────────────────────────────────
func apply_velocity_lean(delta: float) -> void:
	var cfg_max_speed: float = _controller.max_speed
	var local_vel: Vector3 = _skater.global_transform.basis.inverse() * _skater.velocity
	var lean_max: float = deg_to_rad(_controller.velocity_lean_max_deg)
	var target_x: float = -clampf(local_vel.z / cfg_max_speed, -1.0, 1.0) * lean_max
	var target_z: float =  clampf(local_vel.x / cfg_max_speed, -1.0, 1.0) * lean_max
	velocity_lean_x = lerpf(velocity_lean_x, target_x, _controller.velocity_lean_speed * delta)
	velocity_lean_z = lerpf(velocity_lean_z, target_z, _controller.velocity_lean_speed * delta)

func apply_facing(input: InputState, delta: float) -> void:
	if not _sm.get_state() in [State.WRISTER_AIM, State.SLAPPER_CHARGE_WITH_PUCK,
			State.SLAPPER_CHARGE_WITHOUT_PUCK, State.SHOT_BLOCKING]:
		var prev_angle: float = _skater.rotation.y
		var mouse_world: Vector3 = input.mouse_world_pos
		var to_mouse: Vector2 = Vector2(
			mouse_world.x - _skater.global_position.x,
			mouse_world.z - _skater.global_position.z
		)
		if to_mouse.length() > _controller.move_deadzone:
			# Gate: prevent the body from rotating until the mouse crosses 180° and
			# snaps the arm to the other side. When the mouse exits the reachable IK
			# zone (rom_backhand_angle_max_deg + upper_body_max_twist_deg from forward),
			# record which side it left from and freeze. Re-entry only from the same
			# side unlocks — entering from the opposite side stays frozen.
			var mouse_body_angle: float = facing.angle_to(to_mouse.normalized())
			var ik_gate: float = deg_to_rad(_controller.rom_backhand_angle_max_deg + _controller.upper_body_max_twist_deg)
			if abs(mouse_body_angle) >= ik_gate:
				ik_locked_side = int(sign(mouse_body_angle))
			elif ik_locked_side == 0 or ik_locked_side * mouse_body_angle >= 0.0:
				ik_locked_side = 0
				var drag: float = _controller.facing_drag_speed_braking if input.brake else _controller.facing_drag_speed
				facing = facing.lerp(to_mouse.normalized(), drag * delta).normalized()
		_skater.set_facing(facing)
		var turn_delta: float = angle_difference(prev_angle, _skater.rotation.y)
		lower_body_lag = clampf(
			lower_body_lag - turn_delta,
			-deg_to_rad(_controller.lower_body_lag_max_deg),
			deg_to_rad(_controller.lower_body_lag_max_deg))

	# Always decay and apply — even during locked states.
	lower_body_lag = lerpf(lower_body_lag, 0.0, _controller.lower_body_lag_speed * delta)
	_skater.set_lower_body_lag(lower_body_lag)

func apply_upper_body(delta: float) -> void:
	if _sm.get_state() == State.SHOT_BLOCKING:
		return

	if _sm.get_state() in [State.SLAPPER_CHARGE_WITH_PUCK, State.SLAPPER_CHARGE_WITHOUT_PUCK]:
		# Hold upper body facing the locked shot direction throughout the wind-up.
		# Re-computed from world space each frame so the torso stays on target
		# even if the feet pivot while skating.
		if _sm.locked_slapper_dir.length_squared() > 0.0001:
			var locked_world := Vector3(_sm.locked_slapper_dir.x, 0.0, _sm.locked_slapper_dir.y)
			var local_dir := _skater.global_transform.basis.inverse() * locked_world
			var locked_angle := atan2(local_dir.x, -local_dir.z)
			var max_twist := deg_to_rad(_controller.upper_body_max_twist_deg)
			var target: float = clampf(-locked_angle * _controller.upper_body_twist_ratio, -max_twist, max_twist)
			upper_body_angle = lerp_angle(upper_body_angle, target, _controller.upper_body_return_speed * delta)
			_skater.set_upper_body_rotation(upper_body_angle)
		return

	var target_angle: float = 0.0
	var target_lean: float = 0.0
	var hand_vec := Vector2(
		_skater.top_hand.position.x - _skater.shoulder.position.x,
		_skater.top_hand.position.z - _skater.shoulder.position.z)
	var hand_reach: float = hand_vec.length()

	if hand_reach > 0.01:
		var reach_factor: float = clampf(hand_reach / _controller.rom_backhand_reach_max, 0.0, 1.0)
		# Drive twist from the blade's world direction in the skater body frame.
		# Using skater-local (not upper-body-local) gives a stable target that
		# doesn't shrink as the body rotates — the old hand-angle approach had a
		# dampening feedback loop that capped steady-state rotation at ~43% of the
		# world angle. Now the body tracks 1:1 up to upper_body_max_twist_deg.
		var blade_world: Vector3 = _skater.upper_body_to_global(_skater.get_blade_position())
		var to_blade: Vector3 = blade_world - _skater.global_position
		to_blade.y = 0.0
		if to_blade.length() > 0.01:
			var local_dir: Vector3 = _skater.global_transform.basis.inverse() * to_blade.normalized()
			var blade_angle: float = atan2(local_dir.x, -local_dir.z)
			var max_twist: float = deg_to_rad(_controller.upper_body_max_twist_deg)
			target_angle = clampf(-blade_angle * _controller.upper_body_twist_ratio, -max_twist, max_twist)
			target_lean = -reach_factor * deg_to_rad(_controller.upper_body_lean_max_deg)

	upper_body_angle = lerp_angle(upper_body_angle, target_angle, _controller.upper_body_return_speed * delta)
	upper_body_lean = lerpf(upper_body_lean, target_lean, _controller.upper_body_lean_return_speed * delta)
	_skater.set_upper_body_rotation(upper_body_angle)
	_skater.set_upper_body_lean(upper_body_lean + velocity_lean_x, velocity_lean_z)
	_skater.set_lower_body_lean(velocity_lean_x, velocity_lean_z)

func apply_head_tracking(input: InputState, delta: float) -> void:
	var mouse_local: Vector3 = _skater.upper_body_to_local(input.mouse_world_pos)
	mouse_local.y = 0.0
	var target_angle: float = 0.0
	if mouse_local.length() > 0.01:
		target_angle = clampf(
			atan2(mouse_local.x, -mouse_local.z),
			-deg_to_rad(_controller.head_track_max_deg),
			deg_to_rad(_controller.head_track_max_deg))
	head_angle = lerpf(head_angle, target_angle, _controller.head_track_speed * delta)
	_skater.set_head_angle(head_angle)

# ── Angular Velocity Bookkeeping ──────────────────────────────────────────────
# Called at the end of _process_input on real (non-replay) frames so the
# network state carries C1-continuous facing / upper-body rotation.
func update_angular_velocities(delta: float) -> void:
	if delta <= 0.0:
		return
	var cur_fa: float = atan2(facing.x, facing.y)
	facing_angular_velocity = angle_difference(_prev_facing_angle, cur_fa) / delta
	upper_body_angular_velocity = angle_difference(_prev_upper_body_angle, upper_body_angle) / delta
	_prev_facing_angle = cur_fa
	_prev_upper_body_angle = upper_body_angle

# ── Pose Resets ───────────────────────────────────────────────────────────────
# Used by SkaterController._transition_to_skating and _enter_slapper_charge.
# Clears smoothed pose state so the next tick starts from a neutral torso/lean.
func reset_lean_and_lag() -> void:
	upper_body_angle = 0.0
	upper_body_lean = 0.0
	velocity_lean_x = 0.0
	velocity_lean_z = 0.0
	lower_body_lag = 0.0
