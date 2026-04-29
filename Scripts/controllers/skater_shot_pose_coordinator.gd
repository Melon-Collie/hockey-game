class_name SkaterShotPoseCoordinator
extends RefCounted

# Owns the blade and top-hand pose during shot states: the slapper wind-up
# (charge with or without puck) and the post-release follow-through for both
# wrister and slapper. The aim/IK flow in SkaterIKCoordinator is bypassed for
# these states because the blade pose is choreographed, not player-aimed.
#
# All clamp helpers (net exclusion, goalie body / butterfly) and the small
# geometry utilities (blade_y_local, stick_horiz) live on SkaterIKCoordinator
# because they are also used by the per-tick IK pipeline.

const State = SkaterStateMachine.State

# ── References ────────────────────────────────────────────────────────────────
var _skater: Skater = null
var _sm: SkaterStateMachine = null
var _aiming: SkaterAimingBehavior = null
var _ik: SkaterIKCoordinator = null
var _controller: SkaterController = null

func setup(skater: Skater, sm: SkaterStateMachine, aiming: SkaterAimingBehavior,
		ik: SkaterIKCoordinator, controller: SkaterController) -> void:
	_skater = skater
	_sm = sm
	_aiming = aiming
	_ik = ik
	_controller = controller

# ── Slapper Charge Pose ───────────────────────────────────────────────────────
# Slapper has a fixed blade pose offset from the shoulder — separate from
# the IK flow (this is a charged pre-shot pose, not player-aimed). Hand
# sits at the shoulder XZ at `hand_rest_y`; blade XZ is offset from the
# shoulder by slapper_blade_x/z; Y lerps from _ik.blade_y_local() (ice) up to
# slapper_wind_up_height during the wind-up charge.
func apply_slapper_blade_position() -> void:
	var blade_side_sign: float = -1.0 if _skater.is_left_handed else 1.0
	var wind_up_t: float = clampf(_aiming.slapper_charge_timer / _controller.slapper_wind_up_time, 0.0, 1.0)
	var current_blade_y: float = lerpf(_ik.blade_y_local(), _controller.slapper_wind_up_height, wind_up_t)
	var pos := Vector3(
			_skater.shoulder.position.x + blade_side_sign * _controller.slapper_blade_x,
			current_blade_y,
			_skater.shoulder.position.z + _controller.slapper_blade_z)
	pos = _skater.clamp_blade_to_walls(pos)
	var blade_world: Vector3 = _skater.upper_body_to_global(pos)
	var clamped_heel: Vector3 = blade_world
	if _controller.has_puck:
		clamped_heel = _ik.clamp_blade_from_goalies(clamped_heel)
	var hand_pos := Vector3(_skater.shoulder.position.x, _controller.hand_rest_y, _skater.shoulder.position.z)
	var hand_world: Vector3 = _skater.upper_body_to_global(hand_pos)
	var shaft: Vector3 = clamped_heel - hand_world
	shaft.y = 0.0
	var contact_world: Vector3 = clamped_heel
	if shaft.length() > 0.001:
		contact_world = clamped_heel + shaft.normalized() * _skater.blade_length * 0.5
	var clamped_contact: Vector3 = _ik.clamp_blade_from_net(contact_world)
	if clamped_contact != contact_world:
		var delta: Vector3 = clamped_contact - contact_world
		clamped_heel += delta
		if _controller.has_puck:
			_controller._do_release(delta.normalized(), _controller.goalie_strip_power)
	if clamped_heel != blade_world:
		pos = _skater.upper_body_to_local(clamped_heel)
	_skater.set_top_hand_position(hand_pos)
	_skater.set_blade_position(pos)

# ── Wrister Follow-Through ────────────────────────────────────────────────────
func apply_wrister_follow_through() -> void:
	var t: float = 1.0 - (_sm.follow_through_timer / _controller.follow_through_duration)
	var arc: float = sin(t * PI)
	var stick_horiz: float = _ik.stick_horiz()
	var local_dir := Vector3(sin(_controller._blade_relative_angle), 0.0, -cos(_controller._blade_relative_angle))
	var hand_pos := _skater.shoulder.position
	hand_pos.y = _controller.hand_rest_y + arc * _controller.wrister_follow_through_hand_y
	var intended_target: Vector3 = hand_pos + local_dir * stick_horiz
	intended_target.y = _ik.blade_y_local() + arc * _controller.wrister_follow_through_blade_lift
	var local_target: Vector3 = _skater.clamp_blade_to_walls(intended_target)
	var clamp_delta_xz := Vector3(
		local_target.x - intended_target.x, 0.0, local_target.z - intended_target.z)
	if clamp_delta_xz.length_squared() > 0.0:
		hand_pos.x += clamp_delta_xz.x
		hand_pos.z += clamp_delta_xz.z
	var net_world: Vector3 = _ik.clamp_blade_from_net(_skater.upper_body_to_global(local_target))
	var net_local: Vector3 = _skater.upper_body_to_local(net_world)
	hand_pos.x += net_local.x - local_target.x
	hand_pos.z += net_local.z - local_target.z
	local_target = net_local
	_skater.set_top_hand_position(hand_pos)
	_skater.set_blade_position(local_target)

# ── Slapper Follow-Through ────────────────────────────────────────────────────
func apply_slapper_follow_through() -> void:
	var t: float = 1.0 - (_sm.follow_through_timer / _controller.follow_through_duration)
	var blade_side_sign: float = -1.0 if _skater.is_left_handed else 1.0
	var shot_xz := Vector2(_sm.shot_dir.x, _sm.shot_dir.z)
	if shot_xz.length() > 0.001:
		shot_xz = shot_xz.normalized()
	var blade_pos := Vector3(
		_skater.shoulder.position.x + blade_side_sign * _controller.slapper_blade_x + shot_xz.x * t * _controller.slapper_follow_through_arc_dist,
		lerpf(_controller.slapper_wind_up_height, _ik.blade_y_local(), smoothstep(0.0, 1.0, t)),
		_skater.shoulder.position.z + _controller.slapper_blade_z + shot_xz.y * t * _controller.slapper_follow_through_arc_dist)
	blade_pos = _skater.clamp_blade_to_walls(blade_pos)
	blade_pos = _skater.upper_body_to_local(_ik.clamp_blade_from_net(_skater.upper_body_to_global(blade_pos)))
	var hand_pos := Vector3(
		_skater.shoulder.position.x,
		_controller.hand_rest_y + t * _controller.wrister_follow_through_hand_y,
		_skater.shoulder.position.z)
	_skater.set_top_hand_position(hand_pos)
	_skater.set_blade_position(blade_pos)
