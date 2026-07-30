class_name SkaterAppearanceCoordinator
extends RefCounted

# Per-attribute visual scaling. Sister to SkaterUniformCoordinator /
# SkaterHUDCoordinator — owned by Skater. Modifies transform.scale on
# leaf MeshInstance3D nodes (not Node3D parents) so the procedural
# arm-bone IK and reconcile-driven MeshRoot.position stay untouched.
#
# SKELETON HEIGHT scales about the ICE PLANE: the UpperBody/LowerBody roots
# rise by (m_height − 1) × their ice height (Skater.set_skeleton_root_offset)
# and every Y offset below them — leg pivots, leg mesh centers, and the
# upper-body part positions — scales by m_height, so any point at world Y
# maps to Y × m_height and the skate contact at y = 0 stays planted. This is
# what realizes the documented 5'7"–6'5" Size heights with proportional legs
# (previously only the torso rose, yielding ~half the height spread on
# long-torso/short-leg bodies). The physics origin, spawn height, and hitbox
# never move. Leg PIVOTS get their positions written here while the gait
# (Skater.set_leg_swing) writes their rotations — different properties, no
# clash; same contract as scale-vs-rotation on the leaf meshes.
#
# Upper-body PART POSITIONS scale too (scale alone stretches each mesh about
# its own origin, so a tall build's torso grew upward while its shoulder
# balls and helmet stayed at baseline height — sunken shoulders, low head):
# shoulder balls and helmet ride m_height on Y, and the shoulder balls ride
# the torso-bulk multiplier on X so a thick torso doesn't swallow them. The
# logical arm anchors mirror the same ball positions gameplay-side —
# SkaterController.apply_attributes calls Skater.set_shoulder_anchor with
# the identical multipliers, keeping the drawn arm and the IK rooted at the
# same point (keep the two in sync).
#
# Idempotent: captures baseline scales / positions / mesh radii on the first
# apply() call; every subsequent call recomputes from those baselines so
# mid-game attribute changes never compound multipliers.
#
# All multipliers come from PlayerAttributes — see that file for the
# tuning tables and how to add new scalings.

# Body-chain leaf nodes. All paths are relative to MeshRoot. FootL/R
# deliberately omitted — their scene transform is rotated 90° around X
# so the local-axis mapping doesn't match the simple rule. The feet are
# small and mostly hidden under the skates, so dropping them from the
# rig doesn't read.
# Torso/head read Size (frame/mass); shoulders read Physical (the grinder yoke),
# so a small-but-strong build reads broad-shouldered and a big-but-soft one
# narrow. Both groups still take the height multiplier on Y.
const _TORSO_PATHS: Array[String] = [
	"UpperBody/UpperBodyMesh",
]
const _SHOULDER_PATHS: Array[String] = [
	"UpperBody/ShoulderL", "UpperBody/ShoulderR",
]
const _HELMET_PATH: String = "UpperBody/Helmet"
const _THIGH_PATHS: Array[String] = [
	"LowerBody/LegL/HipL",   "LowerBody/LegR/HipR",
	"LowerBody/LegL/ThighL", "LowerBody/LegR/ThighR",
	"LowerBody/LegL/KneeL",  "LowerBody/LegR/KneeR",
]
const _CALF_PATHS: Array[String] = [
	"LowerBody/LegL/ShinL/SockL",  "LowerBody/LegR/ShinR/SockR",
	"LowerBody/LegL/ShinL/SkateL", "LowerBody/LegR/ShinR/SkateR",
]
# Leg pivot chain (Node3D, not leaves) — POSITIONS scale with height so the
# skeleton's segment lengths ride m_height (hip 0.87 → 0.87·h world, knee
# 0.31·h below it). The gait rotates these same nodes; positions here,
# rotations there — never the same property.
const _LEG_PIVOT_PATHS: Array[String] = [
	"LowerBody/LegL", "LowerBody/LegR",
	"LowerBody/LegL/ShinL", "LowerBody/LegR/ShinR",
]
# Feet are excluded from the mesh-scaling rig (rotated local frame — see the
# FootL/R note above), but their POSITION is in the shin's frame, so the Y
# offset still scales with the lengthened shin.
const _FOOT_PATHS: Array[String] = [
	"LowerBody/LegL/ShinL/FootL", "LowerBody/LegR/ShinR/FootR",
]

var _skater: Skater = null
var _captured: bool = false
var _base_scales: Dictionary = {}     # mesh_root-relative path -> Vector3
var _base_positions: Dictionary = {}  # mesh_root-relative path -> Vector3
var _base_arm_radius: float = 0.0
var _base_elbow_sphere_radius: float = 0.0
var _base_hand_sphere_radius: float = 0.0


func setup(skater: Skater) -> void:
	_skater = skater


func apply(attrs: PlayerAttributes) -> void:
	if _skater == null or attrs == null:
		return
	if not _captured:
		_capture_baselines()
	var m_height:   float = attrs.height_mult()
	var m_torso:    float = attrs.torso_bulk_mult()
	var m_shoulder: float = attrs.shoulder_bulk_mult()
	var m_head:     float = attrs.head_bulk_mult()
	var m_thigh:    float = attrs.thigh_mult()
	var m_calf:     float = attrs.calf_mult()
	for path: String in _TORSO_PATHS:
		_apply_scale(path, m_torso, m_height, m_torso)
	for path: String in _SHOULDER_PATHS:
		_apply_scale(path, m_shoulder, m_height, m_shoulder)
	_apply_scale(_HELMET_PATH, m_head, m_height, m_head)
	for path: String in _THIGH_PATHS:
		_apply_scale(path, m_thigh, m_height, m_thigh)
	for path: String in _CALF_PATHS:
		_apply_scale(path, m_calf, m_height, m_calf)
	# Positions: keep the upper-body parts assembled across builds. Y rides
	# height for everything (the torso cylinder's center rises with its
	# stretch, the shoulder balls sit at its top, the helmet above them).
	# Shoulder-ball X rides TORSO bulk — the deltoid sits on the torso
	# surface, so it's the torso's width that pushes it out, while
	# the ball's own size keeps reading Physical via _apply_scale above.
	for path: String in _TORSO_PATHS:
		_apply_position(path, 1.0, m_height)
	for path: String in _SHOULDER_PATHS:
		_apply_position(path, m_torso, m_height)
	_apply_position(_HELMET_PATH, 1.0, m_height)
	# Skeleton height: raise the body roots and scale every leg-chain Y offset
	# so the whole rig scales about the ice plane (see the class doc block).
	# The leaf meshes' Y scale already rides m_height above, so the stretched
	# meshes exactly fill the lengthened segments.
	_skater.set_skeleton_root_offset(
			(m_height - 1.0) * GameRules.FACEOFF_SPAWN_HEIGHT)
	for path: String in _LEG_PIVOT_PATHS:
		_apply_position(path, 1.0, m_height)
	for path: String in _THIGH_PATHS:
		_apply_position(path, 1.0, m_height)
	for path: String in _CALF_PATHS:
		_apply_position(path, 1.0, m_height)
	for path: String in _FOOT_PATHS:
		_apply_position(path, 1.0, m_height)
	_apply_arm_thickness(attrs.forearm_bulk_mult(), attrs.upper_arm_bulk_mult())


func _capture_baselines() -> void:
	for path: String in _TORSO_PATHS:
		_capture_scale(path)
	for path: String in _SHOULDER_PATHS:
		_capture_scale(path)
	_capture_scale(_HELMET_PATH)
	for path: String in _THIGH_PATHS:
		_capture_scale(path)
	for path: String in _CALF_PATHS:
		_capture_scale(path)
	# Pivots and feet only move — no mesh scale to capture.
	for path: String in _LEG_PIVOT_PATHS:
		_capture_position(path)
	for path: String in _FOOT_PATHS:
		_capture_position(path)
	# All four arm bones are created in Skater._ready() from the same
	# arm_mesh_thickness; joint balls carry their radius as node scale on the
	# shared unit-radius mesh (see _resolve_or_create_joint_sphere).
	_base_arm_radius = _skater.arm_mesh_thickness * 0.5
	_base_elbow_sphere_radius = _sphere_radius(_skater.top_elbow_sphere)
	_base_hand_sphere_radius  = _sphere_radius(_skater.top_hand_sphere)
	_captured = true


func _capture_scale(path: String) -> void:
	var node: Node3D = _skater.mesh_root.get_node_or_null(path) as Node3D
	if node != null:
		_base_scales[path] = node.scale
		_base_positions[path] = node.position


func _capture_position(path: String) -> void:
	var node: Node3D = _skater.mesh_root.get_node_or_null(path) as Node3D
	if node != null:
		_base_positions[path] = node.position


func _apply_scale(path: String, x_mult: float, y_mult: float, z_mult: float) -> void:
	var node: Node3D = _skater.mesh_root.get_node_or_null(path) as Node3D
	if node == null:
		return
	var base: Vector3 = _base_scales.get(path, Vector3.ONE)
	node.scale = Vector3(base.x * x_mult, base.y * y_mult, base.z * z_mult)


func _apply_position(path: String, x_mult: float, y_mult: float) -> void:
	var node: Node3D = _skater.mesh_root.get_node_or_null(path) as Node3D
	if node == null:
		return
	var base: Vector3 = _base_positions.get(path, Vector3.ZERO)
	node.position = Vector3(base.x * x_mult, base.y * y_mult, base.z)


# Arm bulk is split at the elbow so two stats read off one limb: Hands drives the
# forearms (+ the hand spheres and glove cuffs on that side), Shot drives the
# upper arms (+ the elbow joints on that side). A thick-forearm / normal-bicep
# reads as "hands"; the reverse reads as "shot".
func _apply_arm_thickness(forearm_mult: float, upper_mult: float) -> void:
	var fore_radius:  float = _base_arm_radius * forearm_mult
	var upper_radius: float = _base_arm_radius * upper_mult
	_set_bone_radius(_skater.upper_arm_mesh,        upper_radius)
	_set_bone_radius(_skater.bottom_upper_arm_mesh, upper_radius)
	_set_bone_radius(_skater.forearm_mesh,          fore_radius)
	_set_bone_radius(_skater.bottom_forearm_mesh,   fore_radius)
	# The elbow ball is Shot's joint, but it must stay proud of BOTH adjoining
	# cylinders — a thick-forearm / thin-bicep build (high Hands, low Shot)
	# otherwise leaves the forearm cylinder's flat end cap poking out around a
	# smaller sphere. maxf keeps the joint reading as a bulge on every combo.
	var elbow_mult: float = maxf(upper_mult, forearm_mult)
	_set_sphere_radius(_skater.top_elbow_sphere,    _base_elbow_sphere_radius * elbow_mult)
	_set_sphere_radius(_skater.bottom_elbow_sphere, _base_elbow_sphere_radius * elbow_mult)
	_set_sphere_radius(_skater.top_hand_sphere,     _base_hand_sphere_radius * forearm_mult)
	_set_sphere_radius(_skater.bottom_hand_sphere,  _base_hand_sphere_radius * forearm_mult)
	# Glove cuffs ride the forearm coaxially, so their radius must scale with
	# it — at Hands 4 the fixed cuff radius exactly equaled the scaled forearm
	# radius (coaxial cylinders, identical radii → z-fighting at the wrist).
	# Stamp the mult on the skater so _rebuild_glove_cuffs (uniform re-applies
	# recreate the cuffs) sizes fresh cuffs the same way, then resize any live
	# ones for the attrs-after-uniform order.
	_skater.forearm_visual_mult = forearm_mult
	var cuff_radius: float = _skater.arm_mesh_thickness * 0.6 * forearm_mult
	_set_cuff_radius(_skater.top_cuff_mesh, cuff_radius)
	_set_cuff_radius(_skater.bot_cuff_mesh, cuff_radius)


# Arm-rig meshes are shared unit-radius builds (SkaterMeshBuilder.shared_*),
# so all resizing below is node scale — never mesh mutation, which would leak
# one skater's build into every other skater on the ice.
func _set_bone_radius(bone: Node3D, radius: float) -> void:
	var mi: MeshInstance3D = _skater.bone_visual(bone)
	if mi == null:
		return
	# Cross-section only: the visual's local Y is the bone's length axis,
	# owned by the wrapper's per-frame Z scale (see _resolve_or_create_bone_mesh).
	mi.scale = Vector3(radius, 1.0, radius)


func _set_cuff_radius(mi: MeshInstance3D, radius: float) -> void:
	if mi == null or not is_instance_valid(mi):
		return
	# Height stays baked (CUFF_HEIGHT_M — the wrist placement offsets by it).
	mi.scale = Vector3(radius, 1.0, radius)


func _set_sphere_radius(mi: MeshInstance3D, radius: float) -> void:
	if mi == null:
		return
	mi.scale = Vector3.ONE * radius


static func _sphere_radius(mi: MeshInstance3D) -> float:
	if mi == null:
		return 0.0
	return mi.scale.x
