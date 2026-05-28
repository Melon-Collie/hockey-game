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
var _aiming: SkaterAimingBehavior = null
var _controller: SkaterController = null  # tunables live as @export on the controller

func setup(skater: Skater, sm: SkaterStateMachine, aiming: SkaterAimingBehavior,
		controller: SkaterController) -> void:
	_skater = skater
	_sm = sm
	_aiming = aiming
	_controller = controller
	_prev_facing_angle = atan2(facing.x, facing.y)
	_prev_upper_body_angle = upper_body_angle

# ── Per-Tick Application ──────────────────────────────────────────────────────
func apply_velocity_lean(delta: float) -> void:
	var target: Vector2 = compute_velocity_lean_target(
			_skater.velocity, _skater.global_transform.basis,
			_controller.max_speed, _controller.velocity_lean_max_deg)
	velocity_lean_x = lerpf(velocity_lean_x, target.x, _controller.velocity_lean_speed * delta)
	velocity_lean_z = lerpf(velocity_lean_z, target.y, _controller.velocity_lean_speed * delta)


# Pure helpers — derive lean targets from state. Used both by the live pose
# pipeline (apply_velocity_lean / apply_upper_body lerp toward these targets)
# and by snap_lean_to_state below (remote / replay path snaps directly). Means
# lean isn't transmitted over the wire — receivers re-derive it from the
# velocity and hand position they already have.
static func compute_velocity_lean_target(
		world_velocity: Vector3, body_basis: Basis,
		max_speed: float, lean_max_deg: float) -> Vector2:
	if max_speed <= 0.0:
		return Vector2.ZERO
	var local_vel: Vector3 = body_basis.inverse() * world_velocity
	var lean_max: float = deg_to_rad(lean_max_deg)
	var target_x: float = -clampf(local_vel.z / max_speed, -1.0, 1.0) * lean_max
	var target_z: float =  clampf(local_vel.x / max_speed, -1.0, 1.0) * lean_max
	return Vector2(target_x, target_z)


static func compute_upper_body_lean_target(
		hand_local_xz: Vector2, shoulder_local_xz: Vector2,
		rom_max_reach: float, lean_max_deg: float) -> float:
	var hand_vec: Vector2 = hand_local_xz - shoulder_local_xz
	var hand_reach: float = hand_vec.length()
	if hand_reach <= 0.01 or rom_max_reach <= 0.0:
		return 0.0
	var reach_factor: float = clampf(hand_reach / rom_max_reach, 0.0, 1.0)
	return -reach_factor * deg_to_rad(lean_max_deg)


# Snap lean to the targets implied by current velocity + hand position. Used
# by remote / replay state application — lean isn't in the network state, so
# receivers re-derive it the same way the host computed it. Must be called
# AFTER set_top_hand_position and BEFORE set_blade_position so the blade
# marker lands at the correct world Y under the leaning upper body.
func snap_lean_to_state() -> void:
	var v_target: Vector2 = compute_velocity_lean_target(
			_skater.velocity, _skater.global_transform.basis,
			_controller.max_speed, _controller.velocity_lean_max_deg)
	velocity_lean_x = v_target.x
	velocity_lean_z = v_target.y
	upper_body_lean = compute_upper_body_lean_target(
			Vector2(_skater.top_hand.position.x, _skater.top_hand.position.z),
			Vector2(_skater.shoulder.position.x, _skater.shoulder.position.z),
			_controller.rom_backhand_reach_max, _controller.upper_body_lean_max_deg)
	_skater.set_upper_body_lean(upper_body_lean + velocity_lean_x, velocity_lean_z)
	_skater.set_lower_body_lean(velocity_lean_x, velocity_lean_z)

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
			# Gate: while the mouse is in the unreachable wedge behind the skater
			# (beyond rom_backhand_angle_max_deg + upper_body_max_twist_deg from
			# forward), freeze facing so the body doesn't chase a target it can't
			# reach. Resume tracking as soon as the mouse returns to the reachable
			# cone, regardless of side. Snap-prevention on wraps lives in the
			# blade speed cap (SkaterIKCoordinator), not in this lock — earlier
			# versions tied unlock to "same side it left from", which could
			# permanently strand facing when the mouse wrapped around.
			var mouse_body_angle: float = facing.angle_to(to_mouse.normalized())
			var ik_gate: float = deg_to_rad(_controller.rom_backhand_angle_max_deg + _controller.upper_body_max_twist_deg)
			if abs(mouse_body_angle) >= ik_gate:
				ik_locked_side = int(sign(mouse_body_angle))
			else:
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
		# Hold upper body facing the locked shot direction throughout the wind-up,
		# then layer the coil rotation on top: back shoulder pulls away from the
		# target as the wind-up timer fills, ending in a loaded stance with the
		# non-stick shoulder pointing at the puck. Re-computed from world space
		# each frame so the torso stays on target even if the feet pivot.
		if _sm.locked_slapper_dir.length_squared() > 0.0001:
			var locked_world := Vector3(_sm.locked_slapper_dir.x, 0.0, _sm.locked_slapper_dir.y)
			var local_dir := _skater.global_transform.basis.inverse() * locked_world
			var locked_angle := atan2(local_dir.x, -local_dir.z)
			var max_twist := deg_to_rad(_controller.upper_body_max_twist_deg)
			var aim_target: float = clampf(-locked_angle * _controller.upper_body_twist_ratio, -max_twist, max_twist)
			var wind_up_t: float = clampf(_aiming.slapper_charge_timer / _controller.slapper_wind_up_time, 0.0, 1.0)
			var wind_up_eased: float = sqrt(wind_up_t)
			var blade_side_sign: float = -1.0 if _skater.is_left_handed else 1.0
			var coil: float = -blade_side_sign * deg_to_rad(_controller.slapper_wind_up_twist_deg) * wind_up_eased
			upper_body_angle = lerp_angle(upper_body_angle, aim_target + coil, _controller.slapper_wind_up_lerp_speed * delta)
			_skater.set_upper_body_rotation(upper_body_angle)
		return

	var target_angle: float = 0.0
	var target_lean: float = 0.0
	var hand_vec := Vector2(
		_skater.top_hand.position.x - _skater.shoulder.position.x,
		_skater.top_hand.position.z - _skater.shoulder.position.z)
	var hand_reach: float = hand_vec.length()

	if hand_reach > 0.01:
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
		target_lean = compute_upper_body_lean_target(
				Vector2(_skater.top_hand.position.x, _skater.top_hand.position.z),
				Vector2(_skater.shoulder.position.x, _skater.shoulder.position.z),
				_controller.rom_backhand_reach_max,
				_controller.upper_body_lean_max_deg)

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
