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
@onready var _blocker: StaticBody3D = $BlockArm/Blocker
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
@onready var stick_shaft_mesh: MeshInstance3D = $BlockArm/Stick/StickShaftMesh
@onready var stick_paddle_mesh: MeshInstance3D = $BlockArm/Stick/StickPaddleMesh
@onready var stick_blade_mesh: MeshInstance3D = $BlockArm/Stick/StickBladeMesh

# Arm-to-glove segments. 0.76 per side is ~104% wingspan-equivalent on the
# ~1.92 m frame (torso box + standing pose in goalie_body_config_builder) —
# same anthropometry target as the skaters. Cosmetic only: glove/blocker
# positions are pose-driven, the arm just draws to them.
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

# P8 dirty-skip cache for `_update_connectors`. The arm-IK + connector rebuild
# is value-type-cheap but runs every rendered frame for both goalies; the pose
# only changes when `apply_body_config` / `apply_network_pose` move a part, and
# a settled goalie holds its stance for seconds, so we recompute only when one
# of the body-local part transforms actually changed. Default-mismatched so the
# first frame always rebuilds.
var _last_body_xform: Transform3D
var _last_left_pad_pos: Vector3 = Vector3.INF
var _last_right_pad_pos: Vector3
var _last_glove_pos: Vector3
var _last_block_arm_pos: Vector3


func _ready() -> void:
	# The stick is a hooked shape that snagged skaters when it shared LAYER_WALLS
	# with the rest of the goalie. Move it to LAYER_GOALIE_STICK: the skater
	# mask omits that layer so players pass through instead of getting caught
	# (the puck's stick rebounds are analytic — GoalieContactDetector).
	_stick.collision_layer = Constants.LAYER_GOALIE_STICK
	# The body parts come off the scene-default LAYER_WALLS onto their own
	# LAYER_GOALIE_BODIES so a ghosted skater (whose mask drops back to bare
	# LAYER_WALLS — see Skater.set_ghost) passes through the goalie while still
	# standing on the ice. MASK_SKATER includes the new layer, so non-ghost
	# skaters bump exactly as before; the puck's save contacts are analytic
	# (GoalieContactDetector reads these same parts), so no mask is involved.
	_left_pad.collision_layer = Constants.LAYER_GOALIE_BODIES
	_right_pad.collision_layer = Constants.LAYER_GOALIE_BODIES
	_body.collision_layer = Constants.LAYER_GOALIE_BODIES
	_head.collision_layer = Constants.LAYER_GOALIE_BODIES
	_glove.collision_layer = Constants.LAYER_GOALIE_BODIES
	_blocker.collision_layer = Constants.LAYER_GOALIE_BODIES
	# Swap the scene's primitive part meshes for the shared low-poly faceted
	# set (colliders untouched). Before the uniform coordinator only by
	# convention — painting is material_override / ShaderMaterial, mesh-free.
	GoalieMeshBuilder.apply_goalie(self)
	_init_stick_knob()
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

# Clear-sweep follow-through moves the BlockArm (and its child Stick, whose
# collider is real — puck bounces off LAYER_GOALIE_STICK during saves) through
# the puck's exit path. Without this, that "cosmetic" swing can re-strike the
# puck moments after the clear velocity was imparted and deflect it anywhere,
# including back into the goalie's own net. Disabled for the swing's duration.
func set_stick_collision_enabled(enabled: bool) -> void:
	_stick.collision_layer = Constants.LAYER_GOALIE_STICK if enabled else 0


# Cached list of this goalie's CollisionShape3D parts (pads / body / head / glove /
# stick / blocker) for the analytic puck drive's contact queries. The subtree is
# static after _ready — only transforms move — so one gather serves every query;
# GoalieContactDetector re-gathering per sub-step allocated hundreds of arrays per
# tick in a crease scramble. Runtime enable/disable (the clear-sweep stick toggle
# above) is filtered at QUERY time from the live layer/disabled flags, so the cache
# never goes stale.
var _collision_parts_cache: Array[CollisionShape3D] = []


func get_collision_parts() -> Array[CollisionShape3D]:
	if _collision_parts_cache.is_empty():
		_gather_collision_parts(self, _collision_parts_cache)
	return _collision_parts_cache


static func _gather_collision_parts(node: Node, found: Array[CollisionShape3D]) -> void:
	for child in node.get_children():
		if child is CollisionShape3D:
			found.append(child)
		_gather_collision_parts(child, found)

func get_blocker_position() -> Vector3:
	return _block_arm.position

# Glove world position — the pin point for a caught puck (catch-and-hold).
func get_glove_world_position() -> Vector3:
	return _glove.global_position

# Blocker-assembly world position — the glove's opposite number. Read by the
# shot-read instrumentation, which has to ask "how far is the NEAREST arm from
# this shot" (on an elevated shot either arm can make the save, so keying on the
# glove alone measures glove-side-vs-blocker-side rather than reach).
func get_blocker_world_position() -> Vector3:
	return _block_arm.global_position

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
# set survives. Pad yaw (the rebound-steering toe-out) IS carried as of v13 —
# before that, remote clients rendered square pads whose rebounds appeared to
# kick toward the corners for no visible reason.
func apply_network_pose(state: GoalieNetworkState) -> void:
	# Body + head positions are state-dependent (the pose builder hardcodes
	# different y-heights per state — body 0.40 in butterfly, 1.22 standing
	# etc.). The wire format doesn't carry them, so derive from state_enum
	# via the pose builder's lookup. Without this the chest/head freeze at
	# the scene-default standing height while the legs animate, which reads
	# as a floating head over crouching pads.
	_body.position = GoalieBodyConfigBuilder.resting_body_position_for_state(state.state_enum)
	_body.rotation = Vector3(state.body_pitch, _body.rotation.y, state.body_roll)
	_head.position = GoalieBodyConfigBuilder.resting_head_position_for_state(state.state_enum)
	_head.rotation = Vector3(_head.rotation.x, state.head_yaw, _head.rotation.z)
	_left_pad.position = state.left_pad_offset
	_left_pad.rotation = Vector3(state.left_pad_pitch, state.left_pad_yaw, state.left_pad_roll)
	_right_pad.position = state.right_pad_offset
	_right_pad.rotation = Vector3(state.right_pad_pitch, state.right_pad_yaw, state.right_pad_roll)
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


func _setup_uniform_coordinator() -> void:
	_uniform_coordinator = GoalieUniformCoordinator.new()
	_uniform_coordinator.setup(self)


func _init_connectors() -> void:
	left_hip_connector = _make_connector_mesh()
	add_child(left_hip_connector)
	right_hip_connector = _make_connector_mesh()
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


# White tape knob capping the shaft butt — the fixed house look for the
# goalie stick. Goalies tape heavily and white is the norm; unlike the
# skater's knob it never tracks a kit color, so it's created once here
# (geometry side) while GoalieUniformCoordinator paints the shaft, paddle,
# and blade. Shaft top is at Stick-local y = 0.5 (mesh at 0.25, box 0.5
# tall); the knob sits proud of it by the same 1 cm as the skater's.
func _init_stick_knob() -> void:
	var knob := MeshInstance3D.new()
	knob.name = "StickKnob"
	knob.mesh = SkaterMeshBuilder.shared_knob()
	knob.position = Vector3(0.0, 0.5 - SkaterMeshBuilder.KNOB_HEIGHT_M * 0.5 + 0.01, 0.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.93, 0.93, 0.90)
	mat.roughness = 0.9
	BodyRim.apply(mat)
	knob.material_override = mat
	_stick.add_child(knob)


# Unit-height shared tube (radius baked at HIP_CONNECTOR_RADIUS); the
# per-frame stretch lives in _point_connector's basis, not the mesh.
func _make_connector_mesh() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = GoalieMeshBuilder.shared_connector_tube()
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
	var span: Vector3 = b_local - a_local
	var length: float = span.length()
	var center: Vector3 = (a_local + b_local) * 0.5
	if length < 0.0001:
		bone.position = center
		return
	# One local transform write, not position + scale + look_at. look_at costs
	# six transform operations, two of which resolve the global chain; the prism
	# is rotationally symmetric so the up vector only has to dodge colinearity.
	# X/Y carry the arm thickness and stay as the sizing seam left them.
	var bone_scale: Vector3 = bone.scale
	bone_scale.z = length
	bone.transform = Transform3D(
			Basis.looking_at(span / length, _up_for_look_at(span)).scaled_local(bone_scale),
			center)


static func _up_for_look_at(direction: Vector3) -> Vector3:
	if absf(direction.normalized().y) > 0.99:
		return Vector3.FORWARD
	return Vector3.UP


# ONE MeshInstance3D per bone, carrying the prism whose long axis is already
# local Z (shared_arm_bone_z bakes the rotation a child node used to apply).
# X/Y are the arm THICKNESS; Z is the length _update_arm_bone() rewrites per
# tick — each writer reads the other's components back rather than overwriting
# the whole vector. Same rig contract as Skater._resolve_or_create_bone_mesh,
# which is where this collapse was proven.
func _make_arm_bone() -> Node3D:
	var mi := MeshInstance3D.new()
	mi.mesh = SkaterMeshBuilder.shared_arm_bone_z()
	var radius: float = _ARM_RADIUS * 0.5
	mi.scale = Vector3(radius, radius, 1.0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


func _make_sphere_mesh(radius: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = SkaterMeshBuilder.shared_joint_ball()
	mi.scale = Vector3.ONE * radius
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


# Bridge each body-part pair with a cylinder that tracks their current positions
# every frame. All positions are in goalie-local space (direct children of the
# Goalie root), so no coordinate conversion needed.
#
# P8: value-type-cheap but runs every rendered frame for both goalies. Skip when
# the goalie is hidden, and when no part moved since the last frame — a settled
# goalie's `apply_body_config` lerp converges to a fixed pose, so holding a
# stance skips the arm-IK rebuild entirely. Root translation/yaw doesn't dirty
# the pose: the arms are children and ride along rigidly, so only the body-local
# part transforms matter. Nothing here feeds gameplay (colliders are read
# directly), so a skipped frame is purely cosmetic.
func _update_connectors() -> void:
	if not is_visible_in_tree():
		return
	if not _connectors_pose_changed():
		return
	# Anchor offsets are body-local against the 0.52 × 0.72 torso box in
	# Goalie.tscn (half-height 0.36): hips near the box bottom, shoulders a
	# hand's width below the box top — keep in sync if the box resizes.
	_point_connector(left_hip_connector,
		_body.position + _body.basis * Vector3(-0.10, -0.30, 0.0),
		_left_pad.position)
	_point_connector(right_hip_connector,
		_body.position + _body.basis * Vector3(0.10, -0.30, 0.0),
		_right_pad.position)
	# Shoulder spheres follow the body pivot each frame.
	var glove_shoulder: Vector3 = _body.position + _body.basis * Vector3(-0.23, 0.24, 0.0)
	var blocker_shoulder: Vector3 = _body.position + _body.basis * Vector3(0.23, 0.24, 0.0)
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


# Returns true (and refreshes the snapshot) when any input to `_update_connectors`
# moved since the last rebuild. Exact equality is sufficient: a converged lerp
# produces bit-identical transforms tick over tick, and any real movement trips
# the compare. Body transform covers both the shoulder pivots (position + basis)
# and the connector roots in one check.
func _connectors_pose_changed() -> bool:
	if _body.transform == _last_body_xform \
			and _left_pad.position == _last_left_pad_pos \
			and _right_pad.position == _last_right_pad_pos \
			and _glove.position == _last_glove_pos \
			and _block_arm.position == _last_block_arm_pos:
		return false
	_last_body_xform = _body.transform
	_last_left_pad_pos = _left_pad.position
	_last_right_pad_pos = _right_pad.position
	_last_glove_pos = _glove.position
	_last_block_arm_pos = _block_arm.position
	return true


func _point_connector(mesh: MeshInstance3D, from_pos: Vector3, to_pos: Vector3) -> void:
	var diff: Vector3 = to_pos - from_pos
	var length: float = diff.length()
	if length < 0.02:
		mesh.visible = false
		return
	mesh.visible = true
	mesh.position = (from_pos + to_pos) * 0.5
	# Orient the unit tube (Y-axis aligned) to point from from_pos to to_pos.
	# The stretch to the span's length rides the basis Y column — mesh
	# mutation would leak through the shared connector mesh to every goalie.
	var y_axis: Vector3 = diff / length
	var ref: Vector3 = Vector3.FORWARD if abs(y_axis.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var x_axis: Vector3 = ref.cross(y_axis).normalized()
	var z_axis: Vector3 = x_axis.cross(y_axis).normalized()
	mesh.basis = Basis(x_axis, y_axis * length, z_axis)
