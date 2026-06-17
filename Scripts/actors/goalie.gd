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
@onready var _stick: StaticBody3D = $BlockArm/Stick
@onready var _stick_blade: CollisionShape3D = $BlockArm/Stick/StickBladeCollider

# Visual mesh refs — public so GoalieUniformCoordinator can read them directly
# without a growing parameter list, matching the SkaterUniformCoordinator pattern.
@onready var body_mesh: MeshInstance3D = $Body/MeshInstance3D
@onready var head_mesh: MeshInstance3D = $Head/MeshInstance3D
@onready var left_pad_mesh: MeshInstance3D = $LeftPad/MeshInstance3D
@onready var right_pad_mesh: MeshInstance3D = $RightPad/MeshInstance3D
@onready var glove_ring_mesh: MeshInstance3D = $Glove/Ring
@onready var glove_main_mesh: MeshInstance3D = $Glove/Main
@onready var glove_detail_mesh: MeshInstance3D = $Glove/MeshInstance3D2
@onready var blocker_mesh: MeshInstance3D = $BlockArm/Blocker/BlockerPadMesh
@onready var blocker_hand_mesh: MeshInstance3D = $BlockArm/BlockerHand

const _ARM_UPPER_LEN: float = 0.38
const _ARM_FOREARM_LEN: float = 0.38
const _ARM_RADIUS: float = 0.16
const _SHOULDER_SPHERE_RADIUS: float = 0.10
const _ELBOW_SPHERE_RADIUS: float = 0.08

var _uniform_coordinator: GoalieUniformCoordinator
# Dynamic visual nodes — public for GoalieUniformCoordinator access.
var left_hip_connector: MeshInstance3D = null
var right_hip_connector: MeshInstance3D = null
var glove_upper_arm: Node3D = null
var glove_forearm: Node3D = null
var blocker_upper_arm: Node3D = null
var blocker_forearm: Node3D = null
var glove_shoulder_sphere: MeshInstance3D = null
var blocker_shoulder_sphere: MeshInstance3D = null
var glove_elbow_sphere: MeshInstance3D = null
var blocker_elbow_sphere: MeshInstance3D = null


func _ready() -> void:
	# The stick is a hooked shape that snagged skaters when it shared LAYER_WALLS
	# with the rest of the goalie. Move it to LAYER_GOALIE_STICK: the puck mask
	# includes that layer so shots still rebound off the stick, but the skater
	# mask omits it so players pass through instead of getting caught.
	_stick.collision_layer = Constants.LAYER_GOALIE_STICK
	_init_head_mesh()
	_init_connectors()
	_init_arm_bones()
	_setup_uniform_coordinator()


func _process(_delta: float) -> void:
	_update_connectors()


func apply_jersey_info(p_name: String, number: int) -> void:
	_uniform_coordinator.apply_jersey_info(p_name, number)


func apply_uniform(colors: Dictionary) -> void:
	_uniform_coordinator.apply_uniform(colors)

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
	head_mesh.mesh = sphere


func _setup_uniform_coordinator() -> void:
	_uniform_coordinator = GoalieUniformCoordinator.new()
	_uniform_coordinator.setup(self)


func _init_connectors() -> void:
	left_hip_connector = _make_connector_mesh(0.08)
	add_child(left_hip_connector)
	right_hip_connector = _make_connector_mesh(0.08)
	add_child(right_hip_connector)


func _init_arm_bones() -> void:
	glove_upper_arm = _make_arm_bone()
	add_child(glove_upper_arm)
	glove_forearm = _make_arm_bone()
	add_child(glove_forearm)
	blocker_upper_arm = _make_arm_bone()
	add_child(blocker_upper_arm)
	blocker_forearm = _make_arm_bone()
	add_child(blocker_forearm)
	glove_shoulder_sphere = _make_sphere_mesh(_SHOULDER_SPHERE_RADIUS)
	add_child(glove_shoulder_sphere)
	blocker_shoulder_sphere = _make_sphere_mesh(_SHOULDER_SPHERE_RADIUS)
	add_child(blocker_shoulder_sphere)
	glove_elbow_sphere = _make_sphere_mesh(_ELBOW_SPHERE_RADIUS)
	add_child(glove_elbow_sphere)
	blocker_elbow_sphere = _make_sphere_mesh(_ELBOW_SPHERE_RADIUS)
	add_child(blocker_elbow_sphere)


func _make_connector_mesh(radius: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = 0.1
	mi.mesh = cyl
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


# Two-bone arm IK. shoulder_local / hand_local are in goalie-local space.
# pole_local is the elbow-hint direction in goalie-local space — the solver
# converts to world space before projecting onto the perpendicular plane.
func _update_arm_ik(upper: Node3D, forearm_bone: Node3D,
		shoulder_local: Vector3, hand_local: Vector3, pole_local: Vector3,
		elbow_sphere: MeshInstance3D = null) -> void:
	if upper == null or forearm_bone == null:
		return
	var shoulder_w: Vector3 = to_global(shoulder_local)
	var hand_w: Vector3 = to_global(hand_local)
	var pole_w: Vector3 = global_transform.basis * pole_local
	var elbow_w: Vector3 = TwoBoneIK.solve_elbow(
			shoulder_w, hand_w, _ARM_UPPER_LEN, _ARM_FOREARM_LEN, pole_w)
	var elbow_local: Vector3 = to_local(elbow_w)
	if elbow_sphere != null:
		elbow_sphere.position = elbow_local
	_update_arm_bone(upper, shoulder_local, elbow_local)
	_update_arm_bone(forearm_bone, elbow_local, hand_local)


func _update_arm_bone(bone: Node3D, a_local: Vector3, b_local: Vector3) -> void:
	if bone == null:
		return
	var length: float = (b_local - a_local).length()
	bone.position = (a_local + b_local) * 0.5
	bone.scale = Vector3(1.0, 1.0, maxf(length, 0.001))
	var a_world: Vector3 = to_global(a_local)
	var b_world: Vector3 = to_global(b_local)
	if (b_world - a_world).length() > 0.0001:
		bone.look_at(b_world, _up_for_look_at(b_world - a_world))


static func _up_for_look_at(direction: Vector3) -> Vector3:
	if absf(direction.normalized().y) > 0.99:
		return Vector3.FORWARD
	return Vector3.UP


# Node3D wrapper with a unit CylinderMesh child rotated 90° around X so the
# cylinder's local Y maps to the wrapper's look_at forward axis (Z). scale.z
# is set per tick to the bone's actual length by _update_arm_bone().
func _make_arm_bone() -> Node3D:
	var wrapper := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.name = "Cylinder"
	var cyl := CylinderMesh.new()
	cyl.top_radius = _ARM_RADIUS * 0.5
	cyl.bottom_radius = _ARM_RADIUS * 0.5
	cyl.height = 1.0
	cyl.radial_segments = 12
	mi.mesh = cyl
	mi.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	wrapper.add_child(mi)
	return wrapper


func _make_sphere_mesh(radius: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	sphere.radial_segments = 12
	sphere.rings = 6
	mi.mesh = sphere
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


# Bridge each body-part pair with a cylinder that tracks their current positions
# every frame. All positions are in goalie-local space (direct children of the
# Goalie root), so no coordinate conversion needed.
func _update_connectors() -> void:
	_point_connector(left_hip_connector,
		_body.position + _body.basis * Vector3(-0.10, -0.24, 0.0),
		_left_pad.position)
	_point_connector(right_hip_connector,
		_body.position + _body.basis * Vector3(0.10, -0.24, 0.0),
		_right_pad.position)
	# Shoulder spheres follow the body pivot each frame.
	var glove_shoulder: Vector3 = _body.position + _body.basis * Vector3(-0.23, 0.12, 0.0)
	var blocker_shoulder: Vector3 = _body.position + _body.basis * Vector3(0.23, 0.12, 0.0)
	glove_shoulder_sphere.position = glove_shoulder
	blocker_shoulder_sphere.position = blocker_shoulder
	# Glove arm: shoulder on body's left side (goalie's catch hand), elbow drops down.
	_update_arm_ik(glove_upper_arm, glove_forearm,
		glove_shoulder, _glove.position, Vector3(-0.3, -1.0, 0.0),
		glove_elbow_sphere)
	# Blocker arm: forearm connects directly to BlockArm (wrist position of the
	# blocker pad + hand mesh assembly).
	_update_arm_ik(blocker_upper_arm, blocker_forearm,
		blocker_shoulder, _block_arm.position, Vector3(0.3, -1.0, 0.0),
		blocker_elbow_sphere)


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
