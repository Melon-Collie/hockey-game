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
@onready var _stick_blade: CollisionShape3D = $BlockArm/Stick/StickBladeCollider

@onready var _left_pad_mesh: MeshInstance3D = $LeftPad/MeshInstance3D
@onready var _right_pad_mesh: MeshInstance3D = $RightPad/MeshInstance3D
@onready var _body_mesh: MeshInstance3D = $Body/MeshInstance3D
@onready var _head_mesh: MeshInstance3D = $Head/MeshInstance3D
@onready var _glove_mesh: MeshInstance3D = $Glove/MeshInstance3D
@onready var _blocker_mesh: MeshInstance3D = $BlockArm/Blocker/BlockerPadMesh

var _stripe_meshes: Array[MeshInstance3D] = []
var _number_label_front: Label3D = null
var _number_label_back: Label3D = null
var _name_label_back: Label3D = null
var _left_hip_connector: MeshInstance3D = null
var _right_hip_connector: MeshInstance3D = null
var _glove_arm_connector: MeshInstance3D = null
var _blocker_arm_connector: MeshInstance3D = null


func _ready() -> void:
	_init_head_mesh()
	_init_jersey_stripes()
	_init_labels()
	_init_connectors()


func _process(_delta: float) -> void:
	_update_connectors()


func set_goalie_identity(number: int, name: String) -> void:
	if _number_label_front:
		_number_label_front.text = str(number)
	if _number_label_back:
		_number_label_back.text = str(number)
	if _name_label_back:
		_name_label_back.text = name.to_upper()


func set_goalie_color(jersey_color: Color, helmet_color: Color, pads_color: Color, stripe_color: Color = Color.WHITE) -> void:
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
	_apply_stripe_color(stripe_color)
	_apply_connector_colors(jersey_color, pads_color)

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

# Stick blade world position. Used by the controller's goalie poke check —
# the puck is magneted to the carrier's blade with no physics during carry,
# so we can't rely on RigidBody contact firing. The check is host-side:
# when this position is within poke radius of a carried puck, the goalie
# strips the puck.
func get_blade_world_position() -> Vector3:
	return _stick_blade.global_position


# Apply an authoritative pose snapshot directly to the body parts. Used by
# both live client rendering (interpolated broadcast pose) and replay playback
# — neither runs the local AI, so this writes the host's socket transforms
# straight onto the scene nodes. Skips the body_config_builder entirely.
# Rotations come in radians (matching the wire format); axes we don't carry on
# the wire (body yaw, blocker/glove roll) are left intact so whatever was last
# set survives.
func apply_network_pose(state: GoalieNetworkState) -> void:
	# Body + head positions are state-dependent (the pose builder hardcodes
	# different y-heights per state — body 0.46 in butterfly, 1.16 standing
	# etc.). The wire format doesn't carry them, so derive from state_enum
	# via the pose builder's lookup. Without this the chest/head freeze at
	# the scene-default standing height while the legs animate, which reads
	# as a floating head over crouching pads.
	_body.position = GoalieBodyConfigBuilder.resting_body_position_for_state(state.state_enum)
	_body.rotation = Vector3(state.body_pitch, _body.rotation.y, state.body_roll)
	_head.position = GoalieBodyConfigBuilder.resting_head_position_for_state(state.state_enum)
	_head.rotation = Vector3(_head.rotation.x, state.head_yaw, _head.rotation.z)
	_left_pad.position = state.left_pad_offset
	_left_pad.rotation = Vector3(state.left_pad_pitch, _left_pad.rotation.y, state.left_pad_roll)
	_right_pad.position = state.right_pad_offset
	_right_pad.rotation = Vector3(state.right_pad_pitch, _right_pad.rotation.y, state.right_pad_roll)
	_glove.position = state.glove_offset
	_glove.rotation = Vector3(state.glove_pitch, state.glove_yaw, _glove.rotation.z)
	_block_arm.position = state.blocker_offset
	_block_arm.rotation = Vector3(state.blocker_pitch, state.blocker_yaw, _block_arm.rotation.z)

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


func _init_head_mesh() -> void:
	var sphere := SphereMesh.new()
	sphere.radius = 0.15
	sphere.height = 0.22
	_head_mesh.mesh = sphere


func _init_jersey_stripes() -> void:
	# Three horizontal stripe bands painted over the body front + back faces.
	var stripe_ys: PackedFloat32Array = PackedFloat32Array([-0.17, -0.04, 0.09])
	for y: float in stripe_ys:
		for front: bool in [true, false]:
			var mi := MeshInstance3D.new()
			var box := BoxMesh.new()
			box.size = Vector3(0.50, 0.045, 0.003)
			mi.mesh = box
			mi.position = Vector3(0.0, y, -0.143 if front else 0.143)
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_body.add_child(mi)
			_stripe_meshes.append(mi)


func _init_labels() -> void:
	_number_label_front = _make_number_label()
	_number_label_front.position = Vector3(0.0, -0.06, -0.145)
	_body.add_child(_number_label_front)

	_number_label_back = _make_number_label()
	_number_label_back.position = Vector3(0.0, -0.03, 0.145)
	_number_label_back.rotation_degrees.y = 180.0
	_body.add_child(_number_label_back)

	_name_label_back = Label3D.new()
	_name_label_back.font_size = 14
	_name_label_back.pixel_size = 0.004
	_name_label_back.outline_size = 3
	_name_label_back.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_label_back.position = Vector3(0.0, 0.16, 0.145)
	_name_label_back.rotation_degrees.y = 180.0
	_body.add_child(_name_label_back)


func _make_number_label() -> Label3D:
	var lbl := Label3D.new()
	lbl.font_size = 32
	lbl.pixel_size = 0.004
	lbl.outline_size = 4
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return lbl


func _init_connectors() -> void:
	_left_hip_connector = _make_connector_mesh(0.08)
	add_child(_left_hip_connector)
	_right_hip_connector = _make_connector_mesh(0.08)
	add_child(_right_hip_connector)
	_glove_arm_connector = _make_connector_mesh(0.055)
	add_child(_glove_arm_connector)
	_blocker_arm_connector = _make_connector_mesh(0.055)
	add_child(_blocker_arm_connector)


func _make_connector_mesh(radius: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = 0.1
	mi.mesh = cyl
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


func _apply_stripe_color(color: Color) -> void:
	if _stripe_meshes.is_empty():
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	for mi: MeshInstance3D in _stripe_meshes:
		mi.material_override = mat
	if _number_label_front:
		_number_label_front.modulate = color
	if _number_label_back:
		_number_label_back.modulate = color
	if _name_label_back:
		_name_label_back.modulate = color


func _apply_connector_colors(jersey_color: Color, pads_color: Color) -> void:
	if not _glove_arm_connector:
		return
	var jersey_mat := StandardMaterial3D.new()
	jersey_mat.albedo_color = jersey_color
	_glove_arm_connector.material_override = jersey_mat
	_blocker_arm_connector.material_override = jersey_mat.duplicate()
	var pads_mat := StandardMaterial3D.new()
	pads_mat.albedo_color = pads_color
	_left_hip_connector.material_override = pads_mat
	_right_hip_connector.material_override = pads_mat.duplicate()


# Bridge each body-part pair with a cylinder that tracks their current positions
# every frame. All positions are in goalie-local space (direct children of the
# Goalie root), so no coordinate conversion needed.
func _update_connectors() -> void:
	_point_connector(_left_hip_connector,
		_body.position + _body.basis * Vector3(-0.10, -0.24, 0.0),
		_left_pad.position)
	_point_connector(_right_hip_connector,
		_body.position + _body.basis * Vector3(0.10, -0.24, 0.0),
		_right_pad.position)
	_point_connector(_glove_arm_connector,
		_body.position + _body.basis * Vector3(0.23, 0.12, 0.0),
		_glove.position)
	_point_connector(_blocker_arm_connector,
		_body.position + _body.basis * Vector3(-0.23, 0.12, 0.0),
		_block_arm.position)


func _point_connector(mesh: MeshInstance3D, from_pos: Vector3, to_pos: Vector3) -> void:
	var diff: Vector3 = to_pos - from_pos
	var length: float = diff.length()
	if length < 0.02:
		mesh.visible = false
		return
	mesh.visible = true
	mesh.position = (from_pos + to_pos) * 0.5
	# Orient CylinderMesh (Y-axis aligned) to point from from_pos to to_pos.
	var y_axis: Vector3 = diff / length
	var ref: Vector3 = Vector3.FORWARD if abs(y_axis.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var x_axis: Vector3 = ref.cross(y_axis).normalized()
	var z_axis: Vector3 = x_axis.cross(y_axis).normalized()
	mesh.basis = Basis(x_axis, y_axis, z_axis)
	(mesh.mesh as CylinderMesh).height = length
