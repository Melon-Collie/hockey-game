class_name SkaterIKCoordinator
extends RefCounted

# Owns the per-tick blade and arm IK pipeline:
# - Mouse → top-hand IK + blade placement (asymmetric ROM, wall/goalie/net clamps).
# - Bottom-hand IK from the placed top hand + blade.
# - Geometry helpers shared with SkaterShotPoseCoordinator: blade_y_local,
#   blade_y_pitch_corrected, stick_horiz.
# - Net exclusion zone and goalie body / butterfly box clamps. Both clamps
#   strip the puck on contact via _controller._do_release.
#
# Stateless rule layers (TopHandIK, BottomHandIK) live in domain/rules/. This
# class is the controller-facing dispatcher that builds configs from the
# controller's @export tunables and writes blade/hand positions onto Skater.

# ── References ────────────────────────────────────────────────────────────────
var _skater: Skater = null
var _controller: SkaterController = null  # tunables, _do_release, _game_state, has_puck

func setup(skater: Skater, controller: SkaterController) -> void:
	_skater = skater
	_controller = controller

# ── Blade From Mouse (Top-Hand IK) ────────────────────────────────────────────
# Input is treated as a desired blade position. The top hand is solved as a
# consequence, clamped to an asymmetric ROM. See domain/rules/top_hand_ik.gd.
func apply_blade_from_mouse(input: InputState, _delta: float) -> void:
	var mouse_world: Vector3 = input.mouse_world_pos
	mouse_world.y = 0.0

	var shoulder_world: Vector3 = _skater.upper_body_to_global(_skater.shoulder.position)
	shoulder_world.y = 0.0
	var to_mouse: Vector3 = mouse_world - shoulder_world

	if to_mouse.length() < 0.01:
		return

	# Convert mouse world position into upper-body-local XZ for the solver.
	var mouse_local: Vector3 = _skater.upper_body_to_local(mouse_world)
	var desired_blade_xz := Vector2(mouse_local.x, mouse_local.z)

	var blade_side_sign: float = -1.0 if _skater.is_left_handed else 1.0

	# Solve IK — returns (hand, blade) in upper-body-local space.
	var ik: Dictionary = TopHandIK.solve(
			_skater.shoulder.position,
			desired_blade_xz,
			blade_side_sign,
			_ik_config())
	var hand_local: Vector3 = ik.hand
	var blade_local: Vector3 = ik.blade
	# Apply pitch correction to blade Y after IK so the IK geometry (hand-to-blade
	# vertical drop) stays consistent, but the blade's world Y stays at blade_height.
	blade_local.y = blade_y_pitch_corrected(blade_local.z)

	# Wall clamp on the solved blade. Wall-pin auto-release (when carrying).
	var intended_blade: Vector3 = blade_local
	var wall_clamped: Vector3 = _skater.clamp_blade_to_walls(blade_local)

	if _controller.has_puck:
		var squeeze: float = _skater.get_wall_squeeze(intended_blade, wall_clamped)
		if ShotMechanics.should_release_on_wall_pin(squeeze, _skater.wall_squeeze_threshold):
			var wall_normal: Vector3 = _skater.get_blade_wall_normal()
			if wall_normal.length() > 0.0:
				_controller._do_release(wall_normal.normalized(), 3.0)
			else:
				var nudge: Vector3 = _skater.global_transform.basis * (-wall_clamped.normalized())
				_controller._do_release(nudge.normalized(), 3.0)

	# When the blade got pulled back by the wall clamp, slide the hand by the
	# same horizontal offset so |hand − blade| stays at stick_horiz. Prevents
	# the stick mesh from compressing; reads as "pulling the stick back".
	var clamp_delta_xz := Vector3(
			wall_clamped.x - intended_blade.x, 0.0, wall_clamped.z - intended_blade.z)
	if clamp_delta_xz.length_squared() > 0.0:
		hand_local.x += clamp_delta_xz.x
		hand_local.z += clamp_delta_xz.z

	# Goalie body clamp (strips puck on contact) + net exclusion zone.
	# All work in world space; convert back once at the end.
	var heel_world: Vector3 = _skater.upper_body_to_global(wall_clamped)
	var clamped_heel: Vector3 = heel_world
	if _controller.has_puck:
		clamped_heel = clamp_blade_from_goalies(clamped_heel)
	# Compute the puck contact point (mid-blade) and clamp that against the net,
	# not the heel. This is geometrically correct regardless of blade angle.
	var hand_world: Vector3 = _skater.upper_body_to_global(hand_local)
	var shaft: Vector3 = clamped_heel - hand_world
	shaft.y = 0.0
	var contact_world: Vector3 = clamped_heel
	if shaft.length() > 0.001:
		contact_world = clamped_heel + shaft.normalized() * _skater.blade_length * 0.5
	var clamped_contact: Vector3 = clamp_blade_from_net(contact_world)
	if clamped_contact != contact_world:
		var delta: Vector3 = clamped_contact - contact_world
		clamped_heel += delta
		if _controller.has_puck:
			_controller._do_release(delta.normalized(), _controller.goalie_strip_power)
	if clamped_heel != heel_world:
		var clamped_local: Vector3 = _skater.upper_body_to_local(clamped_heel)
		hand_local.x += clamped_local.x - wall_clamped.x
		hand_local.z += clamped_local.z - wall_clamped.z
		wall_clamped = clamped_local

	_skater.set_top_hand_position(hand_local)
	_skater.set_blade_position(wall_clamped)

	# Store the blade's bearing from the shoulder for follow-through.
	var bearing: Vector3 = wall_clamped - _skater.shoulder.position
	if Vector2(bearing.x, bearing.z).length() > 0.001:
		_controller._blade_relative_angle = atan2(bearing.x, -bearing.z)

# ── Bottom Hand ───────────────────────────────────────────────────────────────
# Recompute the bottom hand pose from the current top_hand + blade positions.
# Purely reactive — does not affect blade or top-hand placement. Caller must
# have already written the top hand and blade for this tick before calling.
func update_bottom_hand() -> void:
	var blade_local: Vector3 = _skater.get_blade_position()
	var hand_local: Vector3 = _skater.get_top_hand_position()
	var grip_target_xz := Vector2(
			lerpf(hand_local.x, blade_local.x, _controller.bottom_hand_grip_fraction),
			lerpf(hand_local.z, blade_local.z, _controller.bottom_hand_grip_fraction))
	# Derive grip Y from the stick shaft so the hand stays on the stick regardless
	# of pitch lean or reach. bh_hand_y offsets for fine-tuning.
	var grip_y: float = lerpf(hand_local.y, blade_local.y, _controller.bottom_hand_grip_fraction) + _controller.bh_hand_y
	var cfg: BottomHandIK.Config = _bottom_hand_ik_config()
	cfg.hand_y = grip_y
	var bh: Vector3 = BottomHandIK.solve(
			_skater.bottom_shoulder.position,
			grip_target_xz,
			cfg)
	_skater.set_bottom_hand_position(bh)

# ── Net Exclusion Clamp ───────────────────────────────────────────────────────
# Clamps `point` (either the puck contact point or the blade heel during
# follow-through) out of the net exclusion zone. The zone is NET_HALF_WIDTH +
# NET_PUCK_BUFFER wide on each side and NET_DEPTH + NET_PUCK_BUFFER deep from
# the goal line. The buffer applies uniformly to both the side posts and the
# back board. The point always escapes through the nearest face — never the
# front mouth.
func clamp_blade_from_net(point: Vector3) -> Vector3:
	if point.y > GameRules.NET_HEIGHT:
		return point
	var result: Vector3 = point
	var gl: float           = GameRules.GOAL_LINE_Z
	var eff_depth: float    = GameRules.NET_DEPTH + GameRules.NET_PUCK_BUFFER
	var hw: float           = GameRules.NET_HALF_WIDTH + GameRules.NET_PUCK_BUFFER
	# +Z net
	if result.z >= gl and result.z < gl + eff_depth:
		var local_depth: float = result.z - gl
		if abs(result.x) < hw:
			var d_back: float  = eff_depth - local_depth
			var d_left: float  = result.x + hw
			var d_right: float = hw - result.x
			if d_back <= d_left and d_back <= d_right:
				result.z = gl + eff_depth
			elif d_left <= d_right:
				result.x = -hw
			else:
				result.x = hw
	# -Z net
	elif result.z <= -gl and result.z > -gl - eff_depth:
		var local_depth: float = -gl - result.z
		if abs(result.x) < hw:
			var d_back: float  = eff_depth - local_depth
			var d_left: float  = result.x + hw
			var d_right: float = hw - result.x
			if d_back <= d_left and d_back <= d_right:
				result.z = -gl - eff_depth
			elif d_left <= d_right:
				result.x = -hw
			else:
				result.x = hw
	return result

# ── Goalie Body / Butterfly Clamp ─────────────────────────────────────────────
# Pushes blade_world out of every goalie's collision zone and strips the puck
# on contact. Standing/RVH use an XZ cylinder; butterfly uses an oriented box
# around the leg pads. Returns the adjusted world position.
func clamp_blade_from_goalies(blade_world: Vector3) -> Vector3:
	if not _controller._game_state.has_method("get_goalie_data"):
		return blade_world
	var goalie_data: Array[Dictionary] = _controller._game_state.get_goalie_data()
	var result: Vector3 = blade_world
	for data: Dictionary in goalie_data:
		var gpos: Vector3 = data["position"]
		if data["is_butterfly"]:
			var prev: Vector3 = result
			result = _clamp_blade_butterfly_box(result, gpos, data["rotation_y"])
			if result != prev and _controller.has_puck:
				break
		else:
			var to_blade := Vector2(result.x - gpos.x, result.z - gpos.z)
			var dist: float = to_blade.length()
			if dist < _controller.goalie_block_radius:
				var push_dir: Vector2 = to_blade.normalized() if dist > 0.001 else Vector2(0.0, -sign(gpos.z) if gpos.z != 0.0 else 1.0)
				result.x = gpos.x + push_dir.x * _controller.goalie_block_radius
				result.z = gpos.z + push_dir.y * _controller.goalie_block_radius
				if _controller.has_puck:
					_controller._do_release(Vector3(push_dir.x, 0.0, push_dir.y), _controller.goalie_strip_power)
					break
	return result

# Pushes blade_world out of the goalie's butterfly leg-pad box in goalie local XZ.
# Strips the puck on contact. Returns the adjusted world position (unchanged if outside).
func _clamp_blade_butterfly_box(blade_world: Vector3, gpos: Vector3, rot_y: float) -> Vector3:
	var dx: float = blade_world.x - gpos.x
	var dz: float = blade_world.z - gpos.z
	var local_x: float = dx * cos(rot_y) + dz * sin(rot_y)
	var local_z: float = -dx * sin(rot_y) + dz * cos(rot_y)
	if abs(local_x) >= _controller.butterfly_pad_half_x or abs(local_z) >= _controller.butterfly_pad_half_z:
		return blade_world
	# Inside box — escape along shortest axis.
	var ox: float = _controller.butterfly_pad_half_x - abs(local_x)
	var oz: float = _controller.butterfly_pad_half_z - abs(local_z)
	var escaped_local_x: float
	var escaped_local_z: float
	if ox < oz:
		escaped_local_x = _controller.butterfly_pad_half_x * signf(local_x) if local_x != 0.0 else _controller.butterfly_pad_half_x
		escaped_local_z = local_z
	else:
		escaped_local_x = local_x
		escaped_local_z = _controller.butterfly_pad_half_z * signf(local_z) if local_z != 0.0 else _controller.butterfly_pad_half_z
	var world_dx: float = escaped_local_x * cos(rot_y) - escaped_local_z * sin(rot_y)
	var world_dz: float = escaped_local_x * sin(rot_y) + escaped_local_z * cos(rot_y)
	var result: Vector3 = blade_world
	result.x = gpos.x + world_dx
	result.z = gpos.z + world_dz
	if _controller.has_puck:
		var escape := Vector2(world_dx - dx, world_dz - dz)
		var push_dir: Vector2 = escape.normalized() if escape.length_squared() > 0.0001 else Vector2(world_dx, world_dz).normalized()
		_controller._do_release(Vector3(push_dir.x, 0.0, push_dir.y), _controller.goalie_strip_power)
	return result

# ── Geometry Helpers ──────────────────────────────────────────────────────────
# Converts the world-space blade_height to upper-body-local Y.
# Uses the upper body's world Y so the result is correct regardless of where
# the skater's CharacterBody3D origin sits above the ice.
func blade_y_local() -> float:
	return _controller.blade_height - _skater.upper_body.global_position.y

# Pitch-corrected blade Y for a given blade local Z. Used AFTER IK so the
# IK geometry stays internally consistent (correct hand-to-blade vertical drop),
# while the blade's final world Y is kept at blade_height despite upper-body pitch.
# When upper_body.rotation.x = pitch, a point at local Z offset z shifts world Y
# by -z * sin(pitch). Adding z * sin(pitch) to the local Y target cancels that out.
func blade_y_pitch_corrected(blade_local_z: float) -> float:
	var base: float = blade_y_local()
	var pitch: float = _skater.upper_body.rotation.x
	if abs(pitch) > 0.001:
		base += blade_local_z * sin(pitch)
	return base

# Horizontal projection of the stick onto the XZ plane, given the fixed
# vertical drop from hand to blade. Used by follow-through to keep stick
# length consistent with the IK solver.
func stick_horiz() -> float:
	var drop: float = _controller.hand_rest_y - blade_y_local()
	var sq: float = _controller.stick_length * _controller.stick_length - drop * drop
	return sqrt(maxf(sq, 0.0001))

# ── Config Builders ───────────────────────────────────────────────────────────
func _ik_config() -> TopHandIK.Config:
	var cfg := TopHandIK.Config.new()
	cfg.stick_length = _controller.stick_length
	cfg.blade_y = blade_y_local()
	cfg.hand_rest_y = _controller.hand_rest_y
	cfg.hand_y_max = _controller.hand_y_max
	cfg.rom_forehand_angle_max = deg_to_rad(_controller.rom_forehand_angle_max_deg)
	cfg.rom_backhand_angle_max = deg_to_rad(_controller.rom_backhand_angle_max_deg)
	cfg.rom_forehand_reach_max = _controller.rom_forehand_reach_max
	cfg.rom_backhand_reach_max = _controller.rom_backhand_reach_max
	return cfg

func _bottom_hand_ik_config() -> BottomHandIK.Config:
	var cfg := BottomHandIK.Config.new()
	cfg.hand_y = _controller.bh_hand_y
	cfg.backhand_angle = _bh_backhand_angle()
	cfg.release_angle_max = deg_to_rad(_controller.bh_release_angle_deg)
	cfg.release_angle_band = deg_to_rad(_controller.bh_release_angle_band_deg)
	return cfg

# Blade world angle toward the backhand side, in the skater's body frame.
# Returns a positive value when the blade is on the backhand side; 0 on forehand.
func _bh_backhand_angle() -> float:
	var blade_world: Vector3 = _skater.upper_body_to_global(_skater.get_blade_position())
	var to_blade: Vector3 = blade_world - _skater.global_position
	to_blade.y = 0.0
	if to_blade.length() < 0.01:
		return 0.0
	var skater_dir: Vector3 = _skater.global_transform.basis.inverse() * to_blade.normalized()
	var blade_angle: float = atan2(skater_dir.x, -skater_dir.z)
	# For a lefty the backhand side is +X (positive angle); negate blade_side_sign
	# so the result is always positive toward backhand regardless of handedness.
	var blade_side_sign: float = -1.0 if _skater.is_left_handed else 1.0
	return blade_angle * -blade_side_sign
