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

# `glove_max_step`: optional cap on the glove's linear movement this frame,
# in metres. Caller passes `glove_react_max_speed * delta` to throw a hard
# arm-speed cap on the catch reach so the glove can't perfectly beat the
# puck to the spot. -1 disables the cap (glove uses the shared lerp). The
# rotation still uses the shared lerp regardless — wrist orientation
# tracks position closely enough not to need its own cap.
func apply_body_config(config: GoalieBodyConfig, t: float, glove_max_step: float = -1.0) -> void:
	_lerp_part(_left_pad,  config.left_pad_pos,  config.left_pad_rot,  t)
	_lerp_part(_right_pad, config.right_pad_pos, config.right_pad_rot, t)
	_lerp_part(_body,      config.body_pos,      config.body_rot,      t)
	_lerp_part(_head,      config.head_pos,      config.head_rot,      t)
	if glove_max_step < 0.0:
		_lerp_part(_glove, config.glove_pos, config.glove_rot, t)
	else:
		_glove.position = _glove.position.move_toward(config.glove_pos, glove_max_step)
		_glove.rotation_degrees = _glove.rotation_degrees.lerp(config.glove_rot, t)
	# Blocker assembly = blocker pad + stick (shaft, paddle, blade) as one
	# rigid unit. Single transform via `blocker_pos` / `blocker_rot` drives
	# the whole BlockArm; pad and stick are children that rotate together
	# (real-world they're physically attached at the wrist).
	_lerp_part(_block_arm, config.blocker_pos, config.blocker_rot, t)

func set_goalie_position(x: float, z: float) -> void:
	global_position = Vector3(x, 0.0, z)

func set_goalie_rotation_y(y: float) -> void:
	rotation.y = y

func get_goalie_rotation_y() -> float:
	return rotation.y

func _lerp_part(part: Node3D, target_pos: Vector3, target_rot_deg: Vector3, t: float) -> void:
	part.position = part.position.lerp(target_pos, t)
	part.rotation_degrees = part.rotation_degrees.lerp(target_rot_deg, t)
