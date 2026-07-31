extends GutTest

# The gait's rotations and the sizing seam's positions live on the leg rig's
# bones now, not on Node3Ds — see Skater.leg_bone_euler / leg_bone_position.
const _LEG_L: int = SkaterMeshBuilder.LegBone.LEG_L
const _SHIN_L: int = SkaterMeshBuilder.LegBone.SHIN_L

# Skeleton height scaling — SkaterAppearanceCoordinator scales the whole mesh
# rig about the ICE PLANE: the UpperBody/LowerBody roots rise by
# (height_mult − 1) × FACEOFF_SPAWN_HEIGHT and every leg-chain Y offset
# scales by height_mult, so a point at world height Y maps to Y × mult and
# the skate contact at y = 0 stays planted. The physics origin never moves.
# The roots' baseline is the on-skates stance: Skater._ready lifts both by
# SkaterMeshBuilder.SKATE_LIFT_M before the defaults are captured, so every
# expected root position sits on top of that lift.
# Pins: root offsets, leg pivot scaling, hand-height scaling on the
# controller, idempotency (re-applies never compound), and composition with
# the cosmetic skating-crouch drop (shared _apply_body_height writer).

const SKATER_SCENE: PackedScene = preload("res://Scenes/Skater.tscn")

# Mesh-native scene geometry (keep in sync with Scenes/Skater.tscn).
const LEG_PIVOT_Y: float = -0.13
const SHIN_PIVOT_Y: float = -0.31


class GameStateStub:
	extends Node

	func is_host() -> bool:
		return false

	func is_movement_locked() -> bool:
		return false


func _make_rig() -> Dictionary:
	var skater: Skater = SKATER_SCENE.instantiate() as Skater
	add_child_autofree(skater)
	skater.set_physics_process(false)
	skater.set_process(false)
	var puck: Puck = (preload("res://Scenes/Puck.tscn").instantiate()) as Puck
	add_child_autofree(puck)
	puck.set_physics_process(false)
	puck.global_position = Vector3(20.0, 0.0, 20.0)
	var gs := GameStateStub.new()
	add_child_autofree(gs)
	var controller := SkaterController.new()
	add_child_autofree(controller)
	controller.setup(skater, puck, gs)
	return {"skater": skater, "controller": controller}


static func _size_attrs(height_level: int) -> PlayerAttributes:
	# Weight 0 coerces to the height's neutral frame — the pure-height build.
	return PlayerAttributes.from_levels(height_level, 0)


func test_skeleton_scales_about_ice_plane() -> void:
	var rig: Dictionary = _make_rig()
	var skater: Skater = rig["skater"]
	var controller: SkaterController = rig["controller"]
	var attrs: PlayerAttributes = _size_attrs(PlayerAttributes.HEIGHT_MAX)
	var h: float = attrs.height_mult()
	controller.apply_attributes(attrs)

	# Roots rise by (h − 1) × their mesh-native ice height, on top of the
	# on-skates stance lift.
	var expected_root: float = SkaterMeshBuilder.SKATE_LIFT_M \
			+ (h - 1.0) * GameRules.FACEOFF_SPAWN_HEIGHT
	var upper: Node3D = skater.get_node("MeshRoot/UpperBody") as Node3D
	var lower: Node3D = skater.get_node("MeshRoot/LowerBody") as Node3D
	assert_almost_eq(upper.position.y, expected_root, 0.0001, "upper root rises")
	assert_almost_eq(lower.position.y, expected_root, 0.0001, "lower root rises")

	# Leg pivot offsets scale by h (segment lengths lengthen); X untouched.
	assert_almost_eq(skater.leg_bone_position(_LEG_L).y, LEG_PIVOT_Y * h, 0.0001, "hip pivot scales")
	assert_almost_eq(skater.leg_bone_position(_LEG_L).x, -0.13, 0.0001, "stance width untouched")
	assert_almost_eq(skater.leg_bone_position(_SHIN_L).y, SHIN_PIVOT_Y * h, 0.0001, "knee pivot scales")

	# Fixed-point check: the skeleton scales about the TOP of the skate stack
	# (the lift is a fixed, unscaled spacer under it), so a chain point at
	# mesh-native world height Y lands at Y × h + SKATE_LIFT_M — the knee
	# (0.56 above ice natively) at 0.56 × h plus the stack.
	var knee_above_ice: float = GameRules.FACEOFF_SPAWN_HEIGHT \
			+ expected_root + skater.leg_bone_position(_LEG_L).y + skater.leg_bone_position(_SHIN_L).y
	var native_knee: float = GameRules.FACEOFF_SPAWN_HEIGHT + LEG_PIVOT_Y + SHIN_PIVOT_Y
	assert_almost_eq(knee_above_ice, native_knee * h + SkaterMeshBuilder.SKATE_LIFT_M,
			0.0001, "knee height proportional")

	# Hand heights and the gait's leg scale ride the same multiplier.
	assert_almost_eq(controller.hand_rest_y, -0.10 * h, 0.0001, "hand rest scales")
	assert_almost_eq(controller.hand_y_max, 0.30 * h, 0.0001, "hand ceiling scales")
	assert_almost_eq(controller._skating.leg_scale, h, 0.0001, "gait leg scale set")

	# Derived backhand ROM: whole chain (arm + drop) scales by h, so the
	# solved reach is exactly h × the mesh-native solve. 0.66 = the two
	# 0.33 arm bones (Skater exports).
	var arm_eff: float = 0.66 * h * controller.rom_arm_extension
	var drop: float = skater.shoulder_height - controller.hand_rest_y
	assert_almost_eq(drop, 0.50 * h, 0.0001, "shoulder-to-hand drop proportional")
	assert_almost_eq(controller.rom_backhand_reach_max,
			sqrt(arm_eff * arm_eff - drop * drop), 0.0001, "backhand ROM chain solve")


func test_reapply_is_idempotent_and_reversible() -> void:
	var rig: Dictionary = _make_rig()
	var skater: Skater = rig["skater"]
	var controller: SkaterController = rig["controller"]
	var big: PlayerAttributes = _size_attrs(PlayerAttributes.HEIGHT_MAX)
	var upper: Node3D = skater.get_node("MeshRoot/UpperBody") as Node3D

	controller.apply_attributes(big)
	var once_root: float = upper.position.y
	var once_leg: float = skater.leg_bone_position(_LEG_L).y
	var once_hand: float = controller.hand_rest_y
	controller.apply_attributes(big)
	assert_almost_eq(upper.position.y, once_root, 0.0001, "re-apply must not compound root")
	assert_almost_eq(skater.leg_bone_position(_LEG_L).y, once_leg, 0.0001, "re-apply must not compound pivots")
	assert_almost_eq(controller.hand_rest_y, once_hand, 0.0001, "re-apply must not compound hand")

	# Free-play picker path: big → medium must land exactly where a fresh
	# medium application lands.
	var medium := PlayerAttributes.all_average()
	controller.apply_attributes(medium)
	var fresh: Dictionary = _make_rig()
	(fresh["controller"] as SkaterController).apply_attributes(medium)
	var fresh_skater: Skater = fresh["skater"] as Skater
	var fresh_upper: Node3D = fresh_skater.get_node("MeshRoot/UpperBody") as Node3D
	assert_almost_eq(upper.position.y, fresh_upper.position.y, 0.0001, "downsize matches fresh")
	assert_almost_eq(
			skater.leg_bone_position(_LEG_L).y,
			fresh_skater.leg_bone_position(_LEG_L).y,
			0.0001, "downsize matches fresh pivot")


func test_root_offset_composes_with_crouch_drop() -> void:
	var rig: Dictionary = _make_rig()
	var skater: Skater = rig["skater"]
	var controller: SkaterController = rig["controller"]
	var attrs: PlayerAttributes = _size_attrs(PlayerAttributes.HEIGHT_MAX)
	var h: float = attrs.height_mult()
	controller.apply_attributes(attrs)
	var root: float = SkaterMeshBuilder.SKATE_LIFT_M \
			+ (h - 1.0) * GameRules.FACEOFF_SPAWN_HEIGHT
	var upper: Node3D = skater.get_node("MeshRoot/UpperBody") as Node3D

	# Crouch after scaling: both offsets share _apply_body_height.
	skater.set_skating_crouch_drop(0.05)
	assert_almost_eq(upper.position.y, root - 0.05, 0.0001, "crouch stacks on root offset")
	# Re-applying attributes mid-crouch must preserve the crouch component.
	controller.apply_attributes(attrs)
	assert_almost_eq(upper.position.y, root - 0.05, 0.0001, "re-apply keeps crouch")
	skater.set_skating_crouch_drop(0.0)
	assert_almost_eq(upper.position.y, root, 0.0001, "crouch release returns to root offset")
