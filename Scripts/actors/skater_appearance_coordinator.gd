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
# maps to Y × m_height and the skate contact at y = 0 stays planted. That whole-
# skeleton scale is what realizes the documented 5'7"–6'5" Size heights: raising
# the torso alone yields about half the height spread on a long-torso/short-leg
# body. The physics origin, spawn height, and hitbox
# never move. Leg PIVOTS get their positions written here while the gait
# (Skater.set_leg_swing) writes their rotations — different properties, no
# clash; same contract as scale-vs-rotation on the leaf meshes.
#
# Upper-body PART POSITIONS scale too — scale alone stretches each mesh about its
# own origin, so a tall build's torso grows upward while its shoulder balls and
# helmet stay at baseline height (sunken shoulders, low head):
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
# Every lateral group reads the one grounded girth multiplier (PlayerAttributes
# .girth_mult — sqrt(mass/height)); body parts additionally take the height
# multiplier on Y. The helmet/head unit is the exception: it scales uniformly
# by its own mild table and never stretches with height — real adult heads are
# nearly constant across statures, and the constancy is what sells a tall
# build as big rather than zoomed.
# The upper-body parts are bones of the upper rig, not nodes.
const _SHOULDER_BONES: Array[int] = [
	SkaterMeshBuilder.UpperBone.SHOULDER_L, SkaterMeshBuilder.UpperBone.SHOULDER_R,
]
# The leg parts are bones of the leg rig, not nodes, so they are addressed by
# LegBone index (see SkaterMeshBuilder).
const _THIGH_BONES: Array[int] = [
	SkaterMeshBuilder.LegBone.THIGH_L, SkaterMeshBuilder.LegBone.THIGH_R,
	SkaterMeshBuilder.LegBone.KNEE_L,  SkaterMeshBuilder.LegBone.KNEE_R,
]
const _CALF_BONES: Array[int] = [
	SkaterMeshBuilder.LegBone.SOCK_L,  SkaterMeshBuilder.LegBone.SOCK_R,
	SkaterMeshBuilder.LegBone.SKATE_L, SkaterMeshBuilder.LegBone.SKATE_R,
]
# Leg pivot chain (no geometry) — POSITIONS scale with height so the skeleton's
# segment lengths ride m_height (hip 0.87 → 0.87·h world, knee 0.31·h below it).
# The gait rotates these same bones; positions here, rotations there — never the
# same component.
const _LEG_PIVOT_BONES: Array[int] = [
	SkaterMeshBuilder.LegBone.LEG_L,  SkaterMeshBuilder.LegBone.LEG_R,
	SkaterMeshBuilder.LegBone.SHIN_L, SkaterMeshBuilder.LegBone.SHIN_R,
]
# Feet are excluded from the mesh-scaling rig (rotated local frame — see the
# FootL/R note above), but their POSITION is in the shin's frame, so the Y
# offset still scales with the lengthened shin.
const _FOOT_BONES: Array[int] = [
	SkaterMeshBuilder.LegBone.FOOT_L, SkaterMeshBuilder.LegBone.FOOT_R,
]

var _skater: Skater = null
var _captured: bool = false
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
	_apply_upper_scale(SkaterMeshBuilder.UpperBone.TORSO, m_torso, m_height, m_torso)
	for bone: int in _SHOULDER_BONES:
		_apply_upper_scale(bone, m_shoulder, m_height, m_shoulder)
	_apply_upper_scale(SkaterMeshBuilder.UpperBone.HELMET, m_head, m_head, m_head)
	# The seat is the torso's own bulk carried below the waist — a heavier build
	# fills the pants the same way it fills the jersey.
	_apply_upper_scale(SkaterMeshBuilder.UpperBone.PELVIS, m_torso, m_height, m_torso)
	for bone: int in _THIGH_BONES:
		_apply_leg_scale(bone, m_thigh, m_height, m_thigh)
	for bone: int in _CALF_BONES:
		_apply_leg_scale(bone, m_calf, m_height, m_calf)
	# Positions: keep the upper-body parts assembled across builds. Y rides
	# height for everything (the torso cylinder's center rises with its
	# stretch, the shoulder balls sit at its top, the helmet above them).
	# Shoulder-ball X rides TORSO bulk — the deltoid sits on the torso
	# surface, so it's the torso's width that pushes it out, while
	# the ball's own size keeps reading Physical via _apply_scale above.
	_apply_upper_position(SkaterMeshBuilder.UpperBone.TORSO, 1.0, m_height)
	for bone: int in _SHOULDER_BONES:
		_apply_upper_position(bone, m_torso, m_height)
	_apply_upper_position(SkaterMeshBuilder.UpperBone.HELMET, 1.0, m_height)
	# Skeleton height: raise the body roots and scale every leg-chain Y offset
	# so the whole rig scales about the ice plane (see the class doc block).
	# The leaf meshes' Y scale already rides m_height above, so the stretched
	# meshes exactly fill the lengthened segments.
	_skater.set_skeleton_root_offset(
			(m_height - 1.0) * GameRules.FACEOFF_SPAWN_HEIGHT)
	for bone: int in _LEG_PIVOT_BONES:
		_apply_leg_position(bone, m_height)
	for bone: int in _THIGH_BONES:
		_apply_leg_position(bone, m_height)
	for bone: int in _CALF_BONES:
		_apply_leg_position(bone, m_height)
	for bone: int in _FOOT_BONES:
		_apply_leg_position(bone, m_height)
	_apply_arm_thickness(attrs.forearm_bulk_mult(), attrs.upper_arm_bulk_mult())


func _capture_baselines() -> void:
	# Both rigs captured their own baselines off the scene subtree before freeing
	# it (Skater._build_leg_rig / _build_upper_rig), so there is nothing to
	# capture here.
	# The arm parts have no scene node — they are placed by IK — so their
	# baselines come off the @exports the rig was seeded from.
	_base_arm_radius = _skater.arm_mesh_thickness * 0.5
	_base_elbow_sphere_radius = _skater.arm_ball_radius(
			SkaterMeshBuilder.UpperBone.TOP_ELBOW)
	_base_hand_sphere_radius = _skater.arm_ball_radius(
			SkaterMeshBuilder.UpperBone.TOP_HAND)
	_captured = true


func _apply_upper_scale(bone: int, x_mult: float, y_mult: float, z_mult: float) -> void:
	var base: Vector3 = _skater.upper_bone_base_scale(bone)
	_skater.set_upper_bone_scale(bone,
			Vector3(base.x * x_mult, base.y * y_mult, base.z * z_mult))


func _apply_upper_position(bone: int, x_mult: float, y_mult: float) -> void:
	var base: Vector3 = _skater.upper_bone_base_position(bone)
	_skater.set_upper_bone_position(bone,
			Vector3(base.x * x_mult, base.y * y_mult, base.z))


func _apply_leg_scale(bone: int, x_mult: float, y_mult: float, z_mult: float) -> void:
	var base: Vector3 = _skater.leg_bone_base_scale(bone)
	_skater.set_leg_bone_scale(bone,
			Vector3(base.x * x_mult, base.y * y_mult, base.z * z_mult))


# Leg positions only ever ride height on Y — the X multiplier the upper-body
# parts use has no leg equivalent (nothing moves a knee sideways with build).
func _apply_leg_position(bone: int, y_mult: float) -> void:
	var base: Vector3 = _skater.leg_bone_base_position(bone)
	_skater.set_leg_bone_position(bone, Vector3(base.x, base.y * y_mult, base.z))


# Arm bulk is split at the elbow so two stats read off one limb: Hands drives the
# forearms (+ the hand spheres and glove cuffs on that side), Shot drives the
# upper arms (+ the elbow joints on that side). A thick-forearm / normal-bicep
# reads as "hands"; the reverse reads as "shot".
func _apply_arm_thickness(forearm_mult: float, upper_mult: float) -> void:
	var fore_radius:  float = _base_arm_radius * forearm_mult
	var upper_radius: float = _base_arm_radius * upper_mult
	_skater.set_arm_bone_radius(SkaterMeshBuilder.UpperBone.TOP_UPPER_ARM, upper_radius)
	_skater.set_arm_bone_radius(SkaterMeshBuilder.UpperBone.BOTTOM_UPPER_ARM, upper_radius)
	_skater.set_arm_bone_radius(SkaterMeshBuilder.UpperBone.TOP_FOREARM, fore_radius)
	_skater.set_arm_bone_radius(SkaterMeshBuilder.UpperBone.BOTTOM_FOREARM, fore_radius)
	# The elbow ball is Shot's joint, but it must stay proud of BOTH adjoining
	# cylinders — a thick-forearm / thin-bicep build (high Hands, low Shot)
	# otherwise leaves the forearm cylinder's flat end cap poking out around a
	# smaller sphere. maxf keeps the joint reading as a bulge on every combo.
	var elbow_mult: float = maxf(upper_mult, forearm_mult)
	var elbow_radius: float = _base_elbow_sphere_radius * elbow_mult
	var hand_radius: float = _base_hand_sphere_radius * forearm_mult
	_skater.set_arm_ball_radius(SkaterMeshBuilder.UpperBone.TOP_ELBOW, elbow_radius)
	_skater.set_arm_ball_radius(SkaterMeshBuilder.UpperBone.BOTTOM_ELBOW, elbow_radius)
	_skater.set_arm_ball_radius(SkaterMeshBuilder.UpperBone.TOP_HAND, hand_radius)
	_skater.set_arm_ball_radius(SkaterMeshBuilder.UpperBone.BOTTOM_HAND, hand_radius)
	# Glove cuffs ride the forearm coaxially, so their radius must scale with it:
	# a fixed cuff radius meets the scaled forearm radius around Hands 4, and
	# coaxial cylinders of identical radius z-fight at the wrist.
	# Stamp the mult on the skater so the uniform pass sizes the cuff the same
	# way whichever of the two runs last.
	_skater.forearm_visual_mult = forearm_mult
	var cuff_radius: float = _skater.arm_mesh_thickness * 0.6 * forearm_mult
	_skater.set_arm_cuff_radius(SkaterMeshBuilder.UpperBone.TOP_CUFF, cuff_radius)
	_skater.set_arm_cuff_radius(SkaterMeshBuilder.UpperBone.BOTTOM_CUFF, cuff_radius)
