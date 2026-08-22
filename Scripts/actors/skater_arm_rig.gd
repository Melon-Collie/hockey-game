class_name SkaterArmRig
extends RefCounted

# The upper-body skeleton: torso, helmet, the two deltoid caps, and both arms
# posed by IK from the hand markers.
#
# Fourteen bones, no parents, all identity rest (see SkaterMeshBuilder.UpperBone
# for why that makes a pose write a plain local transform). The mesh is a child
# of the skeleton, so the two share a transform space with nothing to keep in
# sync.
#
# Pose = basis · scale, at position, each part stored separately: `_basis` is the
# authored rest rotation, `_scale` and `_pos` are the sizing seam's, and
# `_thickness` is the arm parts' own radius contract. Every write here is
# cosmetic — the hand and shoulder MARKERS are gameplay geometry Skater owns, and
# this file only reads them.

# Fraction of the way the cap's pole leans from its rest hang toward the live
# upper-arm direction. Partial follow: the deltoid engages with the arm but
# stays seated on the torso at extreme reaches (a full follow points the whole
# pad down a cross-body arm and opens a gap at the trap line).
const _SHOULDER_CAP_FOLLOW: float = 0.6
# Rest pole in upper-body space for the RIGHT cap (x mirrors for the left):
# down, a touch outboard and forward — the deltoid's hang on a relaxed arm.
const _SHOULDER_CAP_REST_POLE := Vector3(0.32, -0.93, -0.17)

var _skater: Skater
var _skeleton: Skeleton3D = null
var _mesh: MeshInstance3D = null
# Per-part pose scale, except a bone's Z, which is its live length.
var _thickness: PackedVector3Array = PackedVector3Array()
var _basis: Array[Basis] = []
var _scale: PackedVector3Array = PackedVector3Array()
var _pos: PackedVector3Array = PackedVector3Array()
var _base_scale: PackedVector3Array = PackedVector3Array()
var _base_pos: PackedVector3Array = PackedVector3Array()
var _helmet_base_euler: Vector3 = Vector3.ZERO
var _face_gear_attach: BoneAttachment3D = null
var _face_gear_mesh: MeshInstance3D = null

# Cosmetic per-stride trunk texture (the gait's dig lean / weight-shift sway /
# stagger wobble), applied to the torso/helmet/shoulder-cap BONES rather than
# the UpperBody node: the blade and shoulder markers hang under UpperBody, so
# a node rotation would move the blade's WORLD position — physics-rate
# gameplay geometry — while the gait runs at render rate. Bones are pure mesh,
# so this keeps the invariant documented in SkaterPoseCoordinator._apply_lean.
# The arms stay anchored to the (deterministic) hands and stick on purpose.
# Head stabilization: the helmet rides only a fraction of the trunk texture.
# Real players hold the head steady while the shoulders work under it (the
# vestibulocollic "eyes level" reflex) — with full coupling every per-stride
# trunk roll was also a head wobble, the most visible motion on the rig. Roll
# (the oscillating weight-shift channel) is damped hard; pitch follows nearly
# fully because its big components are sustained postures (the effort dig, the
# sprint lean) the head genuinely leans with — a low follow there detaches the
# helmet from the torso top at deep folds. 1.0 / 1.0 restores rigid coupling.
var helmet_pitch_follow: float = 0.85
var helmet_roll_follow: float = 0.4

var _trunk_texture := Basis.IDENTITY
var _trunk_texture_head := Basis.IDENTITY
var _trunk_texture_pitch: float = 0.0
var _trunk_texture_roll: float = 0.0


func setup(skater: Skater) -> void:
	_skater = skater


# Reads the scene-authored placement of the four shell parts out of the
# UpperBody subtree, builds the skeleton from it, then frees those nodes —
# keeping Scenes/Skater.tscn the place the proportions are authored.
func build() -> void:
	var count: int = SkaterMeshBuilder.UPPER_BONE_COUNT
	var upper_body: Node3D = _skater.upper_body
	_basis.resize(count)
	_scale.resize(count)
	_pos.resize(count)
	_base_scale.resize(count)
	_base_pos.resize(count)
	_skeleton = Skeleton3D.new()
	_skeleton.name = "UpperRig"
	for part: int in count:
		_skeleton.add_bone(str(part))
		_skeleton.set_bone_rest(part, Transform3D.IDENTITY)
	upper_body.add_child(_skeleton)

	_mesh = MeshInstance3D.new()
	_mesh.name = "UpperMesh"
	_mesh.mesh = SkaterMeshBuilder.shared_upper_skin_mesh()
	_mesh.skin = SkaterMeshBuilder.shared_upper_skin()
	_mesh.skeleton = NodePath("..")
	_skeleton.add_child(_mesh)

	# Torso, helmet and the two deltoid caps: their placement is authored in the
	# scene, so it is read out and seeded onto their bones, same as the legs.
	for bone: int in [SkaterMeshBuilder.UpperBone.TORSO,
			SkaterMeshBuilder.UpperBone.HELMET,
			SkaterMeshBuilder.UpperBone.SHOULDER_L,
			SkaterMeshBuilder.UpperBone.SHOULDER_R]:
		var node: Node3D = upper_body.get_node(
				SkaterMeshBuilder.UPPER_BONE_NODE[bone]) as Node3D
		var xform: Transform3D = node.transform
		_basis[bone] = xform.basis.orthonormalized()
		_scale[bone] = xform.basis.get_scale()
		_pos[bone] = xform.origin
		_base_scale[bone] = _scale[bone]
		_base_pos[bone] = _pos[bone]
		repose_bone(bone)
		node.free()
	_helmet_base_euler = _basis[SkaterMeshBuilder.UpperBone.HELMET].get_euler()

	# The pelvis has no scene node to read: its profile is authored in
	# UpperBody's own space (SkaterMeshBuilder._PELVIS_PROFILE), so it rests at
	# the identity the sizing seam then scales about.
	var pelvis: int = SkaterMeshBuilder.UpperBone.PELVIS
	_basis[pelvis] = Basis.IDENTITY
	_scale[pelvis] = Vector3.ONE
	_pos[pelvis] = Vector3.ZERO
	_base_scale[pelvis] = Vector3.ONE
	_base_pos[pelvis] = Vector3.ZERO
	repose_bone(pelvis)

	_thickness.resize(count)
	var bone_radius: float = _skater.arm_mesh_thickness * 0.5
	set_bone_radius(SkaterMeshBuilder.UpperBone.TOP_UPPER_ARM, bone_radius)
	set_bone_radius(SkaterMeshBuilder.UpperBone.TOP_FOREARM, bone_radius)
	set_bone_radius(SkaterMeshBuilder.UpperBone.BOTTOM_UPPER_ARM, bone_radius)
	set_bone_radius(SkaterMeshBuilder.UpperBone.BOTTOM_FOREARM, bone_radius)
	set_ball_radius(SkaterMeshBuilder.UpperBone.TOP_ELBOW, _skater.elbow_sphere_radius)
	set_ball_radius(SkaterMeshBuilder.UpperBone.BOTTOM_ELBOW, _skater.elbow_sphere_radius)
	set_ball_radius(SkaterMeshBuilder.UpperBone.TOP_HAND, _skater.hand_sphere_radius)
	set_ball_radius(SkaterMeshBuilder.UpperBone.BOTTOM_HAND, _skater.hand_sphere_radius)
	var cuff_radius: float = _skater.arm_mesh_thickness * 0.6
	set_cuff_radius(SkaterMeshBuilder.UpperBone.TOP_CUFF, cuff_radius)
	set_cuff_radius(SkaterMeshBuilder.UpperBone.BOTTOM_CUFF, cuff_radius)

	# The gear style may have landed before the rig (spawn order is
	# registry-driven); now that the helmet bone exists, dress it.
	apply_face_gear()


# ── Arm pose ─────────────────────────────────────────────────────────────────

func update_top_arm() -> void:
	_update_arm(_skater.shoulder.position, _skater.top_hand.position,
			1.0 if _skater.is_left_handed else -1.0,
			SkaterMeshBuilder.UpperBone.TOP_UPPER_ARM,
			SkaterMeshBuilder.UpperBone.TOP_FOREARM,
			SkaterMeshBuilder.UpperBone.TOP_CUFF,
			SkaterMeshBuilder.UpperBone.TOP_ELBOW,
			SkaterMeshBuilder.UpperBone.TOP_HAND)


func update_bottom_arm() -> void:
	_update_arm(_skater.bottom_shoulder.position, _skater.bottom_hand.position,
			-1.0 if _skater.is_left_handed else 1.0,
			SkaterMeshBuilder.UpperBone.BOTTOM_UPPER_ARM,
			SkaterMeshBuilder.UpperBone.BOTTOM_FOREARM,
			SkaterMeshBuilder.UpperBone.BOTTOM_CUFF,
			SkaterMeshBuilder.UpperBone.BOTTOM_ELBOW,
			SkaterMeshBuilder.UpperBone.BOTTOM_HAND)


func _update_arm(marker_local: Vector3, hand_local: Vector3, pole_sign: float,
		upper: int, forearm: int, cuff: int, elbow_bone: int, glove: int) -> void:
	var upper_body: Node3D = _skater.upper_body
	var shoulder_l: Vector3 = _textured_shoulder(marker_local)
	var shoulder_w: Vector3 = upper_body.to_global(shoulder_l)
	var hand_w: Vector3 = upper_body.to_global(hand_local)
	var pole_local: Vector3 = _skater.arm_pole_local
	pole_local.x *= pole_sign
	pole_local = CheckStanceRules.tucked_pole(pole_local, CheckStanceRules.side_load(
			_skater.get_check_lead(), signf(marker_local.x)))
	var pole_w: Vector3 = upper_body.global_transform.basis * pole_local
	var elbow_w: Vector3 = TwoBoneIK.solve_elbow(shoulder_w, hand_w,
			_skater.upper_arm_length, _skater.forearm_length, pole_w)
	_pose_bone(upper, shoulder_w, elbow_w)
	_pose_bone(forearm, elbow_w, hand_w)
	_pose_cuff(cuff, elbow_w, hand_w)
	_pose_ball(elbow_bone, elbow_w)
	_pose_glove(glove, elbow_w, hand_w)
	_orient_shoulder_cap(marker_local, shoulder_l, elbow_w)


# Where a shoulder MARKER actually sits once the trunk texture has rolled the
# upper-body shell and the check load-up has driven the leading shoulder forward
# (see repose_bone, which puts both onto the cap bones but deliberately not onto
# the arms).
#
# The arm has to be rooted here, not at the marker: the marker is gameplay
# geometry and never moves with the texture, so an arm grown from it stayed put
# while the shoulder pad it emerges from rolled away — a visible gap at every
# large texture value. The HAND is untouched, so the blade keeps the position
# the IK solved and only the elbow re-solves; nothing gameplay reads changes.
func _textured_shoulder(marker_local: Vector3) -> Vector3:
	return _trunk_texture * (marker_local + _check_load_offset(signf(marker_local.x)))


# Load-up displacement of the shoulder on `side_sign`, zero on the trailing side
# and while nobody is committing. The cap bone and the arm root both take it.
func _check_load_offset(side_sign: float) -> Vector3:
	var lead: float = _skater.get_check_lead()
	if lead == 0.0:
		return Vector3.ZERO
	return CheckStanceRules.load_offset(
			CheckStanceRules.side_load(lead, side_sign),
			side_sign, _skater.shoulder_offset)


# One pose write per part, each a whole Transform3D built in upper-body space —
# the space the skeleton lives in. Deliberately NOT position/scale/look_at: that
# trio costs six transform operations, two of which resolve the global chain
# (look_at reads get_global_transform, writes back through set_global_transform,
# then restores scale through a get_scale/set_scale pair). Building the basis and
# assigning once has no global round-trip, and at ten parts per skater this is
# the densest such site in the rig.
#
# Orientation is built from the LOCAL span, not the world one: the two agree
# whenever upper_body's basis is a rotation, and under a scaled parent the local
# form is the correct one — it points the bone at the same endpoints the position
# term uses. The up vector only has to avoid colinearity, since the bone prism is
# rotationally symmetric about its long axis (see up_for_look_at).
#
# scaled_local is basis·S throughout. The plain scaled() is S·basis and puts the
# size on the wrong axes once a part tilts.
func _pose_bone(part: int, a_world: Vector3, b_world: Vector3) -> void:
	var upper_body: Node3D = _skater.upper_body
	var a_local: Vector3 = upper_body.to_local(a_world)
	var b_local: Vector3 = upper_body.to_local(b_world)
	var span: Vector3 = b_local - a_local
	var length: float = span.length()
	var center: Vector3 = (a_local + b_local) * 0.5
	var bone_scale: Vector3 = _thickness[part]
	if length < 0.0001:
		# Degenerate span: move it, hold the orientation it already had. A pose
		# write replaces the whole transform, so "leave the basis alone" has to be
		# spelled out.
		var held: Transform3D = _skeleton.get_bone_pose(part)
		held.origin = center
		_skeleton.set_bone_pose(part, held)
		return
	var dir: Vector3 = span / length
	# X/Y are the thickness the sizing seam owns; Z is the live bone length.
	bone_scale.z = length
	_skeleton.set_bone_pose(part, Transform3D(
			Basis.looking_at(dir, up_for_look_at(dir)).scaled_local(bone_scale),
			center))


func _pose_ball(part: int, world_pos: Vector3) -> void:
	_skeleton.set_bone_pose(part, Transform3D(
			Basis.IDENTITY.scaled(_thickness[part]),
			_skater.upper_body.to_local(world_pos)))


# Positions the gloved fist at the hand and aligns its long (local Y) axis with
# the forearm so the beveled cube's faces track the arm — same rotation
# composition as the cuff.
func _pose_glove(part: int, elbow_w: Vector3, hand_w: Vector3) -> void:
	var upper_body: Node3D = _skater.upper_body
	var pos: Vector3 = upper_body.to_local(hand_w)
	var scale_v: Vector3 = _thickness[part]
	var dir: Vector3 = hand_w - elbow_w
	if dir.length_squared() < 0.0001:
		var held: Transform3D = _skeleton.get_bone_pose(part)
		held.origin = pos
		_skeleton.set_bone_pose(part, held)
		return
	var dir_l: Vector3 = (upper_body.global_transform.basis.inverse() * dir).normalized()
	var basis := Basis.looking_at(dir_l, up_for_look_at(dir_l)) \
			* Basis(Vector3.RIGHT, PI * 0.5)
	_skeleton.set_bone_pose(part, Transform3D(basis.scaled_local(scale_v), pos))


# Glove cuff ring: its forward end sits at the hand and it extends back toward
# the elbow by its mesh height (no overlap past the hand). The ring's long axis
# is local Y: looking_at puts -Z on the bone, and the post-multiplied X(+90°)
# twist maps local Y onto it. The scale is composed AFTER that rotation
# (scaled_local, R·S) because the cuff's radius is non-uniform on a unit mesh —
# composing it the other way lands the radius on the wrong mesh axes and renders
# metre-wide flickering fins at the wrist.
func _pose_cuff(part: int, elbow_w: Vector3, hand_w: Vector3) -> void:
	var upper_body: Node3D = _skater.upper_body
	var scale_v: Vector3 = _thickness[part]
	var bone_dir: Vector3 = hand_w - elbow_w
	var bone_len: float = bone_dir.length()
	if bone_len < 0.0001:
		var held: Transform3D = _skeleton.get_bone_pose(part)
		held.origin = upper_body.to_local(hand_w)
		_skeleton.set_bone_pose(part, held)
		return
	var bone_dir_n: Vector3 = bone_dir / bone_len
	var cuff_height: float = SkaterMeshBuilder.CUFF_HEIGHT_M
	var cuff_center_w: Vector3 = hand_w \
			- bone_dir_n * (cuff_height * 0.5 + _skater.cuff_wrist_offset)
	var dir_l: Vector3 = (upper_body.global_transform.basis.inverse()
			* bone_dir_n).normalized()
	var basis := Basis.looking_at(dir_l, up_for_look_at(dir_l)) \
			* Basis(Vector3.RIGHT, PI * 0.5)
	_skeleton.set_bone_pose(part, Transform3D(
			basis.scaled_local(scale_v), upper_body.to_local(cuff_center_w)))


# Leans the deltoid cap on the anchor's side toward that arm's shoulder→elbow
# direction. Two texture constraints shape the basis (the shoulder-number
# decal was authored against the caps' identity orientation):
#   - The +Y pole points AWAY from the arm: the cap's blunt torso-side base
#     leans into the trap while the tapered −Y tail runs down the arm, and
#     the equirect texture stays upright — an along-the-arm (downward) pole
#     renders the number flipped and mirrored.
#   - Local +X stays near world +X for BOTH caps; each side's decal picks its
#     outboard face via uv1_offset (±0.25), exactly as at identity. Flipping
#     +X outboard per side turns the left cap's number to the inside.
# Writes rotation only — the caps' scale is SkaterAppearanceCoordinator's
# (quaternion assignment preserves it) and their position is the scene's.
func _orient_shoulder_cap(marker_local: Vector3, anchor_local: Vector3,
		elbow_w: Vector3) -> void:
	var side: float = signf(marker_local.x)
	var bone: int = SkaterMeshBuilder.UpperBone.SHOULDER_L if side < 0.0 \
			else SkaterMeshBuilder.UpperBone.SHOULDER_R
	# repose_bone premultiplies this basis by the trunk texture, so the arm
	# direction has to come back to the UNTEXTURED frame the basis is built in —
	# transposed is the inverse of that pure rotation.
	var arm_dir: Vector3 = _trunk_texture.transposed() \
			* (_skater.upper_body.to_local(elbow_w) - anchor_local)
	if arm_dir.length_squared() < 0.0001:
		return
	var rest: Vector3 = _SHOULDER_CAP_REST_POLE.normalized()
	rest.x *= side
	var pole: Vector3 = -rest.slerp(arm_dir.normalized(), _SHOULDER_CAP_FOLLOW)
	var x_axis: Vector3 = Vector3.RIGHT - pole * pole.x
	if x_axis.length_squared() < 0.01:
		return  # pole nearly along +X — keep the last stable roll
	x_axis = x_axis.normalized()
	_basis[bone] = Basis(x_axis, pole, x_axis.cross(pole)).orthonormalized()
	repose_bone(bone)


# An up vector safely non-colinear with `direction`. Falls back to
# Vector3.FORWARD when `direction` is near-vertical so look_at() doesn't warn
# about colinear basis vectors. Cylindrical meshes (arm bones, cuffs, the stick
# knob) are rotationally symmetric around their long axis, so the choice of up
# only matters for the warning — not for the rendered geometry. Public because
# SkaterStickRig's knob is composed exactly like the cuffs here.
static func up_for_look_at(direction: Vector3) -> Vector3:
	if absf(direction.normalized().y) > 0.99:
		return Vector3.FORWARD
	return Vector3.UP


# ── Trunk texture and head ───────────────────────────────────────────────────

func set_trunk_texture(pitch_add: float, roll_add: float) -> void:
	if is_equal_approx(pitch_add, _trunk_texture_pitch) \
			and is_equal_approx(roll_add, _trunk_texture_roll):
		return
	_trunk_texture_pitch = pitch_add
	_trunk_texture_roll = roll_add
	_trunk_texture = Basis.from_euler(Vector3(pitch_add, 0.0, roll_add))
	_trunk_texture_head = Basis.from_euler(Vector3(
			pitch_add * helmet_pitch_follow, 0.0, roll_add * helmet_roll_follow))
	repose_bone(SkaterMeshBuilder.UpperBone.TORSO)
	repose_bone(SkaterMeshBuilder.UpperBone.HELMET)
	repose_bone(SkaterMeshBuilder.UpperBone.SHOULDER_L)
	repose_bone(SkaterMeshBuilder.UpperBone.SHOULDER_R)


func set_head_angle(angle: float) -> void:
	_basis[SkaterMeshBuilder.UpperBone.HELMET] = Basis.from_euler(
			Vector3(_helmet_base_euler.x, angle, _helmet_base_euler.z))
	repose_bone(SkaterMeshBuilder.UpperBone.HELMET)


func repose_bone(bone: int) -> void:
	var origin: Vector3 = _pos[bone]
	# The check load-up displaces one cap before the texture rotates it: the
	# displacement is authored in the trunk's own frame, so it rides the roll.
	if bone == SkaterMeshBuilder.UpperBone.SHOULDER_L \
			or bone == SkaterMeshBuilder.UpperBone.SHOULDER_R:
		origin += _check_load_offset(signf(origin.x))
	var pose := Transform3D(_basis[bone].scaled_local(_scale[bone]), origin)
	# The trunk texture rotates the upper-body SHELL about the trunk pivot (the
	# skeleton lives in upper-body space, so a zero-origin premultiply is that
	# pivot). Arm bones are excluded — they follow the hands; the helmet takes
	# the stabilized head share instead of the full texture.
	if bone == SkaterMeshBuilder.UpperBone.TORSO \
			or bone == SkaterMeshBuilder.UpperBone.SHOULDER_L \
			or bone == SkaterMeshBuilder.UpperBone.SHOULDER_R:
		pose = Transform3D(_trunk_texture, Vector3.ZERO) * pose
	elif bone == SkaterMeshBuilder.UpperBone.HELMET:
		pose = Transform3D(_trunk_texture_head, Vector3.ZERO) * pose
	_skeleton.set_bone_pose(bone, pose)


# ── Face gear ────────────────────────────────────────────────────────────────

func apply_face_gear() -> void:
	if _skeleton == null:
		return
	var mesh: ArrayMesh = SkaterMeshBuilder.shared_face_gear(
			_skater.gear_style.helmet_face)
	if mesh == null:
		if _face_gear_attach != null:
			_skeleton.remove_child(_face_gear_attach)
			_face_gear_attach.queue_free()
			_face_gear_attach = null
			_face_gear_mesh = null
		return
	if _face_gear_attach == null:
		_face_gear_attach = BoneAttachment3D.new()
		_face_gear_attach.name = "FaceGear"
		_skeleton.add_child(_face_gear_attach)
		# bone_idx after add_child — the setter binds against the parent skeleton.
		_face_gear_attach.bone_idx = SkaterMeshBuilder.UpperBone.HELMET
		_face_gear_mesh = MeshInstance3D.new()
		_face_gear_attach.add_child(_face_gear_mesh)
	_face_gear_mesh.mesh = mesh


# The face piece's render node, for the uniform coordinator's paint and ghost
# fade. Null while the pick is bare.
func face_gear_mesh() -> MeshInstance3D:
	return _face_gear_mesh


# ── Sizing seams ─────────────────────────────────────────────────────────────
# The four scene-authored shell parts. Their arm siblings are placed by IK and
# sized through the radius seams below instead. Scale and position are applied
# in separate passes by SkaterAppearanceCoordinator (a part can take one, the
# other, or both), so each setter writes its own component and recomposes.
func set_bone_scale(bone: int, part_scale: Vector3) -> void:
	_scale[bone] = part_scale
	repose_bone(bone)


func set_bone_position(bone: int, pos: Vector3) -> void:
	_pos[bone] = pos
	repose_bone(bone)


func bone_base_scale(bone: int) -> Vector3:
	return _base_scale[bone]


func bone_base_position(bone: int) -> Vector3:
	return _base_pos[bone]


# Three radius setters because the three geometries have three scaling
# contracts. The stored vector is the part's whole pose scale except for a
# bone's Z, which is its live length.
func set_bone_radius(part: int, radius: float) -> void:
	_thickness[part] = Vector3(radius, radius, 1.0)


func set_ball_radius(part: int, radius: float) -> void:
	_thickness[part] = Vector3.ONE * radius


# The cuff ring's height is baked at its real size (the wrist placement offsets
# by it), so only its radius scales.
func set_cuff_radius(part: int, radius: float) -> void:
	_thickness[part] = Vector3(radius, 1.0, radius)


func ball_radius(part: int) -> float:
	return _thickness[part].x


# The per-skater material for one upper-body surface, created from the shared
# mesh's surface default on first use. Painters and the ghost fade both go
# through this — material_override would repaint every surface at once.
func surface_material(surface: int) -> StandardMaterial3D:
	return SkaterMeshBuilder.surface_override(_mesh, surface)


func set_surface_material(surface: int, mat: Material) -> void:
	_mesh.set_surface_override_material(surface, mat)
