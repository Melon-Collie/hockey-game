class_name SkaterLegRig
extends RefCounted

# The lower-body skeleton and the gait written onto it.
#
# Both legs are one skinned mesh on one Skeleton3D, sixteen bones in the chain
# LowerBody → Leg → Shin (see SkaterMeshBuilder.LegBone). Twelve of the bones
# carry geometry; the four pivots exist to be rotated by the gait
# (SkaterSkatingCoordinator).
#
# Pose = basis · scale, at position, each part stored separately: `_basis` is the
# authored rest rotation (constant for the twelve geometry bones; the four pivots
# are rewritten by set_swing), `_scale` and `_pos` are the sizing seam's.
#
# Also the source of the ice VFX's two reads — where a skate is being DRAWN and
# how hard its edge is loaded — because both are properties of this skeleton and
# of nothing else.

var _skater: Skater
var _skeleton: Skeleton3D = null
var _mesh: MeshInstance3D = null
var _basis: Array[Basis] = []
var _scale: PackedVector3Array = PackedVector3Array()
var _pos: PackedVector3Array = PackedVector3Array()
# The scene's authored shin euler, kept so the knee write can preserve its Y/Z
# the way a node's `rotation.x = v` did. Index 0 = left, 1 = right.
var _shin_base_euler: PackedVector3Array = PackedVector3Array()
# True while the skate bones carry an eversion, so set_foot_eversion knows it
# still owes one write to put them back (see there).
var _feet_everted: bool = false
# Untouched baselines the sizing seam multiplies against, captured off the scene
# subtree before it is freed.
var _base_scale: PackedVector3Array = PackedVector3Array()
var _base_pos: PackedVector3Array = PackedVector3Array()

# Last gait-authored leg pose (hip pivot euler (pitch, yaw, roll) + knee fold
# per leg), cached so the knockdown sprawl can compose ON TOP of whatever the
# gait wrote this frame instead of guessing it: the gait's own crumple blend
# keeps easing underneath the overlay through the get-up, so the handoff back
# to the live stride stays continuous at both ends.
var _gait_leg_l: Vector3 = Vector3.ZERO
var _gait_leg_r: Vector3 = Vector3.ZERO
var _gait_knee_l: float = 0.0
var _gait_knee_r: float = 0.0

# Per-blade edge load [0, 1], published by the gait each pose pass (push
# extension, carve under-push, hockey-stop scrape): the ice VFX scale mark
# intensity by it, so a loaded edge bites visibly harder than a glide.
var _edge_load_l: float = 0.0
var _edge_load_r: float = 0.0


func setup(skater: Skater) -> void:
	_skater = skater


# Reads the leg segment offsets out of the scene's LowerBody subtree, builds the
# skeleton from them, then frees the subtree.
#
# Reading the scene rather than hard-coding the offsets keeps Scenes/Skater.tscn
# the place leg proportions are authored — the nodes are still what you edit to
# move a knee, they just stop existing at runtime. Hard-coding them here would
# fork the numbers into two files that no test compares.
func build() -> void:
	var count: int = SkaterMeshBuilder.LEG_BONE_COUNT
	var lower_body: Node3D = _skater.lower_body
	_basis.resize(count)
	_scale.resize(count)
	_pos.resize(count)
	_base_scale.resize(count)
	_base_pos.resize(count)
	_shin_base_euler.resize(2)

	_skeleton = Skeleton3D.new()
	_skeleton.name = "LegRig"
	for bone: int in count:
		var node: Node3D = lower_body.get_node(
				SkaterMeshBuilder.LEG_BONE_NODE[bone]) as Node3D
		var xform: Transform3D = node.transform
		var part_scale: Vector3 = xform.basis.get_scale()
		_basis[bone] = xform.basis.orthonormalized()
		_scale[bone] = part_scale
		_pos[bone] = xform.origin
		_base_scale[bone] = part_scale
		_base_pos[bone] = xform.origin
		_skeleton.add_bone(str(bone))
		_skeleton.set_bone_parent(bone, SkaterMeshBuilder.LEG_BONE_PARENT[bone])
		_skeleton.set_bone_rest(bone, Transform3D.IDENTITY)
	_shin_base_euler[0] = _basis[SkaterMeshBuilder.LegBone.SHIN_L].get_euler()
	_shin_base_euler[1] = _basis[SkaterMeshBuilder.LegBone.SHIN_R].get_euler()

	for bone: int in count:
		_repose_bone(bone)
	# Freed only after every offset is read — the whole point of the subtree.
	# free() rather than queue_free(): a deferred free renders the scene's
	# placeholder primitives through the real legs for the frame it waits. Safe
	# here — these are plain children whose _ready has run, and nothing is
	# iterating the subtree.
	lower_body.get_node("LegL").free()
	lower_body.get_node("LegR").free()

	lower_body.add_child(_skeleton)
	_mesh = MeshInstance3D.new()
	_mesh.name = "LegMesh"
	_mesh.mesh = SkaterMeshBuilder.shared_leg_skin_mesh()
	_mesh.skin = SkaterMeshBuilder.shared_leg_skin()
	_mesh.skeleton = NodePath("..")
	_skeleton.add_child(_mesh)


func _repose_bone(bone: int) -> void:
	_skeleton.set_bone_pose(bone, Transform3D(
			_basis[bone].scaled_local(_scale[bone]), _pos[bone]))


# ── Gait ─────────────────────────────────────────────────────────────────────

# Hip pitch/roll and knee bend, straight onto the four pivot bones. All radians:
# pitch = fore/aft swing (local X) and roll = side-to-side splay (local Z) of the
# whole leg about the hip; knee = flex of the lower leg (local X) about the knee.
#
# The pivots carry no scale and their authored rotation is overwritten outright,
# so the pose is the gait's basis over the sizing seam's position. The knee write
# owns X only — `_shin_base_euler` carries the scene's authored Y/Z into the
# composed basis.
func set_swing(left_pitch: float, left_roll: float, left_knee: float,
		right_pitch: float, right_roll: float, right_knee: float,
		left_yaw: float = 0.0, right_yaw: float = 0.0) -> void:
	var base_l: Vector3 = _shin_base_euler[0]
	var base_r: Vector3 = _shin_base_euler[1]
	_gait_leg_l = Vector3(left_pitch, left_yaw, left_roll)
	_gait_leg_r = Vector3(right_pitch, right_yaw, right_roll)
	_gait_knee_l = left_knee
	_gait_knee_r = right_knee
	# Yaw rides the hip pivot's free Y slot: YXZ euler order puts it outermost,
	# so the leg externally rotates about vertical and the shin + boot carry it
	# — the mohawk open hip. Defaults keep the pre-yaw callers unchanged.
	_pose_pivot(SkaterMeshBuilder.LegBone.LEG_L,
			Vector3(left_pitch, left_yaw, left_roll))
	_pose_pivot(SkaterMeshBuilder.LegBone.SHIN_L,
			Vector3(left_knee, base_l.y, base_l.z))
	_pose_pivot(SkaterMeshBuilder.LegBone.LEG_R,
			Vector3(right_pitch, right_yaw, right_roll))
	_pose_pivot(SkaterMeshBuilder.LegBone.SHIN_R,
			Vector3(right_knee, base_r.y, base_r.z))


# Knockdown leg sprawl: re-poses the leg pivots as the cached gait pose plus
# `weight` of the sprawl overlay (SkaterController._apply_knockdown_fall calls
# this right after the gait, only while a skater is down). Weight rides the
# same get-up envelope as the fall tilt.
func apply_knockdown_overlay(pose: KnockdownFallRules.SprawlPose,
		weight: float) -> void:
	if weight <= 0.001:
		return
	var base_l: Vector3 = _shin_base_euler[0]
	var base_r: Vector3 = _shin_base_euler[1]
	_pose_pivot(SkaterMeshBuilder.LegBone.LEG_L,
			_gait_leg_l + Vector3(pose.l_pitch, 0.0, pose.l_roll) * weight)
	_pose_pivot(SkaterMeshBuilder.LegBone.SHIN_L,
			Vector3(_gait_knee_l + pose.l_knee * weight, base_l.y, base_l.z))
	_pose_pivot(SkaterMeshBuilder.LegBone.LEG_R,
			_gait_leg_r + Vector3(pose.r_pitch, 0.0, pose.r_roll) * weight)
	_pose_pivot(SkaterMeshBuilder.LegBone.SHIN_R,
			Vector3(_gait_knee_r + pose.r_knee * weight, base_r.y, base_r.z))


func _pose_pivot(bone: int, euler: Vector3) -> void:
	_skeleton.set_bone_pose(bone, Transform3D(Basis.from_euler(euler), _pos[bone]))


# Ankle eversion (radians, about the shin's Z): rolls the SKATE against its
# leg's splay so the blade stays flat on the ice. The boot hangs below the ankle
# joint, so a leg rolled far out of vertical — the shot block's extended leg —
# swings its blade up onto an edge and clear of the ice unless the ankle gives
# back the roll, which is what a real ankle does. Unlike the pivots this bone
# carries an authored rotation and the sizing seam's scale, so the eversion is
# composed onto the rest basis rather than replacing it.
#
# Skipped unless something is actually everted (and once more to settle back),
# so the common case adds no writes to the render-rate rig pass.
func set_foot_eversion(left_roll: float, right_roll: float) -> void:
	if is_zero_approx(left_roll) and is_zero_approx(right_roll) and not _feet_everted:
		return
	_feet_everted = not (is_zero_approx(left_roll) and is_zero_approx(right_roll))
	_pose_foot(SkaterMeshBuilder.LegBone.FOOT_L, left_roll)
	_pose_foot(SkaterMeshBuilder.LegBone.FOOT_R, right_roll)


func _pose_foot(bone: int, roll: float) -> void:
	var basis: Basis = Basis.from_euler(Vector3(0.0, 0.0, roll)) * _basis[bone]
	_skeleton.set_bone_pose(bone,
			Transform3D(basis.scaled_local(_scale[bone]), _pos[bone]))


# ── Ice VFX seams ────────────────────────────────────────────────────────────

func set_edge_loads(left: float, right: float) -> void:
	_edge_load_l = left
	_edge_load_r = right


func edge_load(left: bool) -> float:
	return _edge_load_l if left else _edge_load_r


# World position of a FOOT bone, composed through everything the gait wrote —
# lower-body yaw (alignment / pivot / stop), stride pitch, the mohawk yaw — so
# ice marks made from here follow the SKATES, not the torso. Falls back to the
# old body-center offset until the rig is built.
#
# The transform half is read INTERPOLATED, the bone pose half as-is: the body
# renders between tick poses, while the bone pose is whatever the render-rate
# gait wrote this frame. Composing the two gives the drawn body carrying the
# drawn foot; a plain global_transform read lays every stroke up to a tick of
# travel ahead of the skate that cut it.
func mark_position(left: bool) -> Vector3:
	if _skeleton == null:
		var t: Transform3D = _skater.get_global_transform_interpolated()
		return t.origin + t.basis.x * (-0.12 if left else 0.12)
	var bone: int = SkaterMeshBuilder.LegBone.FOOT_L if left \
			else SkaterMeshBuilder.LegBone.FOOT_R
	return (_skeleton.get_global_transform_interpolated()
			* _skeleton.get_bone_global_pose(bone)).origin


# ── Sizing seam ──────────────────────────────────────────────────────────────
# Scale and position are applied in separate passes by
# SkaterAppearanceCoordinator (a part can take one, the other, or both), so each
# setter writes its own component and recomposes. Attribute-apply rate, not per
# frame.
func set_bone_scale(bone: int, part_scale: Vector3) -> void:
	_scale[bone] = part_scale
	_repose_bone(bone)


func set_bone_position(bone: int, pos: Vector3) -> void:
	_pos[bone] = pos
	_repose_bone(bone)


# Read seams for the gait tests: the rotation the gait wrote and the position the
# sizing seam wrote. The euler round-trips exactly for the four pivots, whose
# basis is built from one (set_swing).
func bone_euler(bone: int) -> Vector3:
	return _skeleton.get_bone_pose(bone).basis.get_euler()


func bone_position(bone: int) -> Vector3:
	return _skeleton.get_bone_pose(bone).origin


func bone_base_scale(bone: int) -> Vector3:
	return _base_scale[bone]


func bone_base_position(bone: int) -> Vector3:
	return _base_pos[bone]


func surface_material(surface: int) -> StandardMaterial3D:
	return SkaterMeshBuilder.surface_override(_mesh, surface)


func set_surface_material(surface: int, mat: Material) -> void:
	_mesh.set_surface_override_material(surface, mat)
