class_name Goalie
extends Node3D

# `_block_arm` is the root of the blocker-hand assembly: blocker pad + stick
# (shaft, paddle, blade) all rigidly attached. Driven by a single transform
# (`blocker_pos` + `blocker_rot` from the body config). The stick geometry
# is baked into the mesh layout — different states get the blade in the right
# place via different blocker rotations, not by tracking the blade
# independently. The Blocker pad and Stick are SEPARATE child StaticBody3Ds
# under BlockArm so they can carry different physics materials (pad absorbs,
# stick rebounds), but they share the BlockArm transform.
@onready var _left_pad: StaticBody3D = $LeftPad
@onready var _right_pad: StaticBody3D = $RightPad
@onready var _body: StaticBody3D = $Body
@onready var _head: StaticBody3D = $Head
@onready var _glove: StaticBody3D = $Glove
@onready var _block_arm: Node3D = $BlockArm

@onready var _left_pad_mesh: MeshInstance3D = $LeftPad/MeshInstance3D
@onready var _right_pad_mesh: MeshInstance3D = $RightPad/MeshInstance3D
@onready var _body_mesh: MeshInstance3D = $Body/MeshInstance3D
@onready var _head_mesh: MeshInstance3D = $Head/MeshInstance3D
@onready var _glove_mesh: MeshInstance3D = $Glove/MeshInstance3D
@onready var _blocker_mesh: MeshInstance3D = $BlockArm/Blocker/BlockerPadMesh

func set_goalie_color(jersey_color: Color, helmet_color: Color, pads_color: Color) -> void:
	var jersey_mat := StandardMaterial3D.new()
	jersey_mat.albedo_color = jersey_color
	_body_mesh.material_override = jersey_mat
	var helmet_mat := StandardMaterial3D.new()
	helmet_mat.albedo_color = helmet_color
	_head_mesh.material_override = helmet_mat
	var pads_mat := StandardMaterial3D.new()
	pads_mat.albedo_color = pads_color
	_left_pad_mesh.material_override = pads_mat
	_right_pad_mesh.material_override = pads_mat.duplicate()
	_glove_mesh.material_override = pads_mat.duplicate()
	_blocker_mesh.material_override = pads_mat.duplicate()

# `glove_max_step` / `blocker_max_step`: optional caps on linear movement
# this frame (metres). Callers pass `*_react_max_speed * delta` to enforce a
# realistic arm-speed limit so the catch / block reach can't perfectly beat
# the puck to the spot. -1 disables the cap (target uses the shared lerp).
# Rotations still lerp at the shared `t` regardless — wrist orientation
# tracks position closely enough not to need its own cap. The blocker step
# applies to the entire BlockArm (pad + stick rigid assembly).
func apply_body_config(config: GoalieBodyConfig, t: float, glove_max_step: float = -1.0, blocker_max_step: float = -1.0) -> void:
	_lerp_part(_left_pad,  config.left_pad_pos,  config.left_pad_rot,  t)
	_lerp_part(_right_pad, config.right_pad_pos, config.right_pad_rot, t)
	_lerp_part(_body,      config.body_pos,      config.body_rot,      t)
	_lerp_part(_head,      config.head_pos,      config.head_rot,      t)
	if glove_max_step < 0.0:
		_lerp_part(_glove, config.glove_pos, config.glove_rot, t)
	else:
		_glove.position = _glove.position.move_toward(config.glove_pos, glove_max_step)
		_glove.rotation_degrees = _lerp_euler_deg(_glove.rotation_degrees, config.glove_rot, t)
	# Blocker assembly = blocker pad + stick (shaft, paddle, blade) as one
	# rigid unit. Single transform via `blocker_pos` / `blocker_rot` drives
	# the whole BlockArm; pad and stick are children that rotate together
	# (real-world they're physically attached at the wrist). When reaching
	# for a blocker save the position is rate-limited via `blocker_max_step`
	# the same way the glove is, so the assembly can't teleport to the
	# impact point.
	if blocker_max_step < 0.0:
		_lerp_part(_block_arm, config.blocker_pos, config.blocker_rot, t)
	else:
		_block_arm.position = _block_arm.position.move_toward(config.blocker_pos, blocker_max_step)
		_block_arm.rotation_degrees = _lerp_euler_deg(_block_arm.rotation_degrees, config.blocker_rot, t)

func set_goalie_position(x: float, z: float) -> void:
	global_position = Vector3(x, 0.0, z)

func set_goalie_rotation_y(y: float) -> void:
	rotation.y = y

func get_goalie_rotation_y() -> float:
	return rotation.y

# Current body-local position of the glove and blocker assembly. Read by the
# controller to pace the elevated-shot reach so the arm arrives WITH the puck
# rather than sprinting to the destination at max speed and sitting idle until
# impact. Returned in goalie-local space (the same space the config targets
# live in) so the caller can `distance_to(config.glove_pos)` directly.
func get_glove_position() -> Vector3:
	return _glove.position

func get_blocker_position() -> Vector3:
	return _block_arm.position

# Pose accessors used by goalie_controller.get_state() to fill the
# authoritative socket transforms broadcast in the world snapshot. All values
# returned in goalie-local space; rotations in radians.
func get_left_pad_position() -> Vector3:
	return _left_pad.position

func get_left_pad_rotation() -> Vector3:
	return _left_pad.rotation

func get_right_pad_position() -> Vector3:
	return _right_pad.position

func get_right_pad_rotation() -> Vector3:
	return _right_pad.rotation

func get_body_rotation() -> Vector3:
	return _body.rotation

func get_glove_rotation() -> Vector3:
	return _glove.rotation

func get_blocker_rotation() -> Vector3:
	return _block_arm.rotation

func get_head_yaw() -> float:
	return _head.rotation.y

func _lerp_part(part: Node3D, target_pos: Vector3, target_rot_deg: Vector3, t: float) -> void:
	part.position = part.position.lerp(target_pos, t)
	part.rotation_degrees = _lerp_euler_deg(part.rotation_degrees, target_rot_deg, t)


# Wrap-safe Euler lerp: rotation_degrees.lerp on a Vector3 interpolates each
# axis linearly, which crosses through 0° instead of through 180° at sign
# flips (-179° → +179° becomes a 358° spin through 0°, not a 2° step). All
# current goalie body parts stay within ±90°, but the moment any rotation
# range crosses ±180° the latent bug surfaces. Reduce the per-axis delta
# into [-180°, +180°] via fmod so the lerp always takes the short way.
static func _lerp_euler_deg(from: Vector3, to: Vector3, t: float) -> Vector3:
	return Vector3(
		from.x + _shortest_deg_delta(from.x, to.x) * t,
		from.y + _shortest_deg_delta(from.y, to.y) * t,
		from.z + _shortest_deg_delta(from.z, to.z) * t,
	)


static func _shortest_deg_delta(from: float, to: float) -> float:
	var delta: float = fmod(to - from + 540.0, 360.0) - 180.0
	return delta
