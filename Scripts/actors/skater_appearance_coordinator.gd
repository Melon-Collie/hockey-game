class_name SkaterAppearanceCoordinator
extends RefCounted

# Per-attribute visual scaling. Sister to SkaterUniformCoordinator /
# SkaterHUDCoordinator — owned by Skater, lives in Scripts/actors/ even
# though the multiplier tables are tuning data. Modifies transform.scale
# on leaf MeshInstance3D nodes (not Node3D parents) so the procedural
# arm-bone IK and reconcile-driven MeshRoot.position stay untouched.
#
# Idempotent: captures baseline scales / mesh radii on the first apply()
# call; every subsequent call recomputes from those baselines so mid-game
# attribute changes never compound multipliers.

# Multiplier tables indexed by (level - 1): [BAD, MEDIUM, GOOD]. Medium is
# 1.0 everywhere so all-medium renders identical to the pre-attributes
# baseline. Spreads are wider than the gameplay multipliers — readable at
# a glance from the third-person hockey camera matters more than realism,
# so a Size-good skater is visibly chunkier than a Size-bad one, etc.
# Height multiplier itself lives on PlayerAttributes (shared with the
# controller's arm/stick length scaling) so all "proportional to height"
# scaling pulls from one table.
const _TORSO_BULK_MULTS: Array[float] = [0.82, 1.00, 1.18]
const _HEAD_BULK_MULTS:  Array[float] = [0.92, 1.00, 1.08]
const _THIGH_MULTS:      Array[float] = [0.82, 1.00, 1.18]
const _CALF_MULTS:       Array[float] = [0.82, 1.00, 1.18]
const _ARM_MULTS:        Array[float] = [0.78, 1.00, 1.40]

# Body-chain leaf nodes that get scale.y from Size (height). All paths
# are relative to MeshRoot. FootL/R deliberately omitted — their scene
# transform is rotated 90° around X so the local-axis mapping doesn't
# match the simple rule. The feet are small and mostly hidden under
# the skates, so dropping them from the rig doesn't read.
const _TORSO_PATHS: Array[String] = [
	"UpperBody/UpperBodyMesh",
	"UpperBody/ShoulderL", "UpperBody/ShoulderR",
]
const _HELMET_PATH: String = "UpperBody/Helmet"
const _THIGH_PATHS: Array[String] = [
	"LowerBody/HipL",   "LowerBody/HipR",
	"LowerBody/ThighL", "LowerBody/ThighR",
	"LowerBody/KneeL",  "LowerBody/KneeR",
]
const _CALF_PATHS: Array[String] = [
	"LowerBody/SockL",  "LowerBody/SockR",
	"LowerBody/SkateL", "LowerBody/SkateR",
]

var _skater: Skater = null
var _captured: bool = false
var _base_scales: Dictionary = {}  # mesh_root-relative path -> Vector3
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
	var m_height: float = PlayerAttributes.height_scale_for(attrs.size)
	var m_torso:  float = _mult_for(_TORSO_BULK_MULTS, attrs.size)
	var m_head:   float = _mult_for(_HEAD_BULK_MULTS,  attrs.size)
	var m_thigh:  float = _mult_for(_THIGH_MULTS,      attrs.speed)
	var m_calf:   float = _mult_for(_CALF_MULTS,       attrs.agility)
	var m_arm:    float = _mult_for(_ARM_MULTS,        attrs.shot)
	for path: String in _TORSO_PATHS:
		_apply_scale(path, m_torso, m_height, m_torso)
	_apply_scale(_HELMET_PATH, m_head, m_height, m_head)
	for path: String in _THIGH_PATHS:
		_apply_scale(path, m_thigh, m_height, m_thigh)
	for path: String in _CALF_PATHS:
		_apply_scale(path, m_calf, m_height, m_calf)
	_apply_arm_thickness(m_arm)


func _capture_baselines() -> void:
	for path: String in _TORSO_PATHS:
		_capture_scale(path)
	_capture_scale(_HELMET_PATH)
	for path: String in _THIGH_PATHS:
		_capture_scale(path)
	for path: String in _CALF_PATHS:
		_capture_scale(path)
	# All four arm bones are created in Skater._ready() from the same
	# arm_mesh_thickness, so reading one captures the shared baseline.
	var up_cyl: MeshInstance3D = _skater.bone_visual(_skater.upper_arm_mesh)
	if up_cyl != null:
		var cyl: CylinderMesh = up_cyl.mesh as CylinderMesh
		if cyl != null:
			_base_arm_radius = cyl.top_radius
	_base_elbow_sphere_radius = _sphere_radius(_skater.top_elbow_sphere)
	_base_hand_sphere_radius  = _sphere_radius(_skater.top_hand_sphere)
	_captured = true


func _capture_scale(path: String) -> void:
	var node: Node3D = _skater.mesh_root.get_node_or_null(path) as Node3D
	if node != null:
		_base_scales[path] = node.scale


func _apply_scale(path: String, x_mult: float, y_mult: float, z_mult: float) -> void:
	var node: Node3D = _skater.mesh_root.get_node_or_null(path) as Node3D
	if node == null:
		return
	var base: Vector3 = _base_scales.get(path, Vector3.ONE)
	node.scale = Vector3(base.x * x_mult, base.y * y_mult, base.z * z_mult)


func _apply_arm_thickness(mult: float) -> void:
	var new_radius: float = _base_arm_radius * mult
	var new_elbow:  float = _base_elbow_sphere_radius * mult
	var new_hand:   float = _base_hand_sphere_radius  * mult
	_set_bone_radius(_skater.upper_arm_mesh,        new_radius)
	_set_bone_radius(_skater.forearm_mesh,          new_radius)
	_set_bone_radius(_skater.bottom_upper_arm_mesh, new_radius)
	_set_bone_radius(_skater.bottom_forearm_mesh,   new_radius)
	_set_sphere_radius(_skater.top_elbow_sphere,    new_elbow)
	_set_sphere_radius(_skater.bottom_elbow_sphere, new_elbow)
	_set_sphere_radius(_skater.top_hand_sphere,     new_hand)
	_set_sphere_radius(_skater.bottom_hand_sphere,  new_hand)


func _set_bone_radius(bone: Node3D, radius: float) -> void:
	if bone == null:
		return
	var mi: MeshInstance3D = _skater.bone_visual(bone)
	if mi == null:
		return
	var cyl: CylinderMesh = mi.mesh as CylinderMesh
	if cyl == null:
		return
	cyl.top_radius = radius
	cyl.bottom_radius = radius


func _set_sphere_radius(mi: MeshInstance3D, radius: float) -> void:
	if mi == null:
		return
	var s: SphereMesh = mi.mesh as SphereMesh
	if s == null:
		return
	s.radius = radius
	s.height = radius * 2.0


static func _sphere_radius(mi: MeshInstance3D) -> float:
	if mi == null:
		return 0.0
	var s: SphereMesh = mi.mesh as SphereMesh
	if s == null:
		return 0.0
	return s.radius


static func _mult_for(table: Array[float], level: int) -> float:
	var idx: int = clampi(level - PlayerAttributes.LEVEL_MIN, 0, table.size() - 1)
	return table[idx]
