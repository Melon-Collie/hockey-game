extends GutTest

# GoalieAnatomy and GoalieStickRules are domain constants that restate the
# goalie's collision shapes from Scenes/Goalie.tscn. Both files say so in prose —
# "Values mirror Scenes/Goalie.tscn's collision shapes", "Geometry (mirrors
# Goalie.tscn)", "keep in sync with Goalie.tscn: Stick at y −0.25,
# StickBladeCollider at (−0.15, −0.67, 0)". This is what makes those executable.
#
# The goalie is the ONE actor that still carries colliders (see Constants →
# Collision Layers: nothing else in the game collides through the physics server,
# because his parts ARE the save geometry). So these constants are not a
# convenience copy — they are the AI's and the shot model's picture of the body
# that actually stops pucks. When they drift, the planner reasons about a goalie
# shaped differently from the one making saves, and every number downstream is
# quietly wrong: hole openness, the danger field, the beatability sweeps.
#
# A drift also cannot surface any other way. The scene is edited in the Godot
# editor and the constants in a text file, by different hands at different times,
# and no code path reads both.

const _GOALIE_SCENE: String = "res://Scenes/Goalie.tscn"
const _PUCK_MESH: String = "res://Assets/puck_mesh.tres"


# Collision shapes keyed "parent_path/node_name" — five nodes in this scene are
# named CollisionShape3D, so the name alone does not identify one.
func _goalie_shapes() -> Dictionary:
	var packed: PackedScene = load(_GOALIE_SCENE)
	assert_not_null(packed, "could not load %s" % _GOALIE_SCENE)
	var st: SceneState = packed.get_state()
	var out: Dictionary = {}
	for i: int in st.get_node_count():
		var shape: Variant = null
		var xform: Transform3D = Transform3D.IDENTITY
		for p: int in st.get_node_property_count(i):
			match st.get_node_property_name(i, p):
				"shape": shape = st.get_node_property_value(i, p)
				"transform": xform = st.get_node_property_value(i, p) as Transform3D
		if shape == null:
			continue
		var key: String = "%s/%s" % [st.get_node_path(i, true), st.get_node_name(i)]
		out[key] = {"shape": shape, "origin": xform.origin, "basis": xform.basis}
	return out


# Node transforms for nodes that carry no shape of their own (the Stick body).
func _goalie_origin(node_name: String) -> Vector3:
	var st: SceneState = (load(_GOALIE_SCENE) as PackedScene).get_state()
	for i: int in st.get_node_count():
		if st.get_node_name(i) != node_name:
			continue
		for p: int in st.get_node_property_count(i):
			if st.get_node_property_name(i, p) == "transform":
				return (st.get_node_property_value(i, p) as Transform3D).origin
	fail_test("no node named `%s` in %s" % [node_name, _GOALIE_SCENE])
	return Vector3.ZERO


func _box(key: String) -> Vector3:
	var shapes: Dictionary = _goalie_shapes()
	assert_true(shapes.has(key), "no collision shape at `%s` in %s" % [key, _GOALIE_SCENE])
	if not shapes.has(key):
		return Vector3.ZERO
	var s: Variant = shapes[key]["shape"]
	assert_true(s is BoxShape3D, "`%s` is not a BoxShape3D" % key)
	return (s as BoxShape3D).size


func test_pad_box_mirrors_the_scene() -> void:
	for side: String in ["LeftPad", "RightPad"]:
		var size: Vector3 = _box("./%s/CollisionShape3D" % side)
		assert_almost_eq(GoalieAnatomy.PAD_BOX_WIDTH_M, size.x, 1e-6,
				"PAD_BOX_WIDTH_M must equal %s's collider width" % side)
		assert_almost_eq(GoalieAnatomy.PAD_BOX_HEIGHT_M, size.y, 1e-6,
				"PAD_BOX_HEIGHT_M must equal %s's collider height" % side)


func test_torso_and_glove_boxes_mirror_the_scene() -> void:
	var torso: Vector3 = _box("./Body/CollisionShape3D")
	assert_almost_eq(GoalieAnatomy.TORSO_BOX_WIDTH_M, torso.x, 1e-6,
			"TORSO_BOX_WIDTH_M must equal Body's collider width")
	assert_almost_eq(GoalieAnatomy.TORSO_BOX_HEIGHT_M, torso.y, 1e-6,
			"TORSO_BOX_HEIGHT_M must equal Body's collider height")
	assert_almost_eq(GoalieAnatomy.GLOVE_BOX_WIDTH_M,
			_box("./Glove/CollisionShape3D").x, 1e-6,
			"GLOVE_BOX_WIDTH_M must equal Glove's collider width")


func test_stick_blade_and_paddle_mirror_the_scene() -> void:
	var blade: Vector3 = _box("./BlockArm/Stick/StickBladeCollider")
	assert_almost_eq(GoalieStickRules.BLADE_WIDTH_M, blade.x, 1e-6,
			"BLADE_WIDTH_M must equal StickBladeCollider's width — it is what the " +
			"standing keeper's low net measures shut with")
	assert_almost_eq(GoalieStickRules.BLADE_HEIGHT_M, blade.y, 1e-6,
			"BLADE_HEIGHT_M must equal StickBladeCollider's height — the shot model " +
			"leaves the stick out of the HIGH band because an elevated puck clears it")
	var paddle: Vector3 = _box("./BlockArm/Stick/StickPaddleCollier")
	assert_almost_eq(GoalieStickRules.PADDLE_WIDTH_M, paddle.x, 1e-6,
			"PADDLE_WIDTH_M must equal StickPaddleCollier's width")
	assert_almost_eq(GoalieStickRules.PADDLE_HEIGHT_M, paddle.y, 1e-6,
			"PADDLE_HEIGHT_M must equal StickPaddleCollier's height")
	# The toe cant is authored as the blade's own Z roll, and the tilt solve reads
	# it back as BLADE_TOE_CANT_DEG to work out the blade's vertical span — which
	# it dominates: 0.19 m of half-width tipped 13° outweighs the whole 0.07 m box.
	# Get it wrong and every stance seats the blade at the wrong height.
	var blade_basis: Basis = _goalie_shapes()["./BlockArm/Stick/StickBladeCollider"]["basis"]
	assert_almost_eq(GoalieStickRules.BLADE_TOE_CANT_DEG,
			rad_to_deg(atan2(blade_basis.x.y, blade_basis.x.x)), 1e-4,
			"BLADE_TOE_CANT_DEG must equal StickBladeCollider's authored Z roll")


# The one the comment spells out as arithmetic: "Stick at y −0.25,
# StickBladeCollider at (−0.15, −0.67, 0) → blade centre ≈ (−0.15, −0.92, 0)".
# Both terms live in the scene, so the sum is checkable rather than asserted.
func test_blade_assembly_offset_derives_from_the_scene_chain() -> void:
	var stick_origin: Vector3 = _goalie_origin("Stick")
	var blade_local: Vector3 = _goalie_shapes()["./BlockArm/Stick/StickBladeCollider"]["origin"]
	assert_almost_eq(GoalieStickRules.ASSEMBLY_LATERAL_M, blade_local.x, 1e-6,
			"ASSEMBLY_LATERAL_M is the blade's own lateral offset inside Stick")
	assert_almost_eq(GoalieStickRules.ASSEMBLY_DROP_M,
			-(stick_origin.y + blade_local.y), 1e-6,
			"ASSEMBLY_DROP_M must equal the Stick's drop plus the blade's drop inside it " +
			"(%.2f + %.2f) — the blade's height below the wrist"
			% [-stick_origin.y, -blade_local.y])


# GameRules called these "Puck.tscn CylinderShape3D" extents. There is no
# CylinderShape3D and no collider — the puck is a Node3D and every contact is
# solved analytically. The live geometry is the mesh resource, which is what the
# constants actually have to match, and what a player sees the disc as.
func test_puck_extents_mirror_the_mesh_resource() -> void:
	var mesh: CylinderMesh = load(_PUCK_MESH) as CylinderMesh
	assert_not_null(mesh, "could not load %s as a CylinderMesh" % _PUCK_MESH)
	assert_almost_eq(GameRules.PUCK_COLLISION_RADIUS, mesh.top_radius, 1e-6,
			"PUCK_COLLISION_RADIUS must equal the drawn disc's radius")
	assert_almost_eq(mesh.top_radius, mesh.bottom_radius, 1e-6,
			"the puck mesh must stay a straight cylinder — the analytic collision " +
			"assumes one radius")
	assert_almost_eq(GameRules.PUCK_COLLISION_HALF_HEIGHT, mesh.height * 0.5, 1e-6,
			"PUCK_COLLISION_HALF_HEIGHT must be half the drawn disc's height, so the " +
			"disc rests with its bottom face on y = 0")


# The chain the scene box actually feeds. GoalieBodyConfigBuilder states it in
# prose — the standing torso bottom "stays glued to the pad-top seam at 0.86",
# which is "body centre 1.22 minus the 0.72 Goalie.tscn torso box's half-height"
# — and GameRules re-states it as a literal for the bot shot model, where
# AIActionScoring uses it as the HIGH band's arrival floor: a lofted shot only
# counts as an over-the-pads target if its arc crosses the net line above it.
#
# So a torso box resized in the editor should move where a bot believes it can
# roof one. With TORSO_BOX_HEIGHT_M pinned to the scene above, asserting the
# derivation closes that path end to end — Goalie.tscn through to the shot model.
func test_pad_top_seam_derives_from_the_torso_box() -> void:
	var standing_centre: Vector3 = GoalieBodyConfigBuilder.resting_body_position_for_state(
			GoalieStateMachine.State.STANDING)
	assert_almost_eq(GameRules.DEFAULT_GOALIE_PAD_TOP_SEAM_M,
			standing_centre.y - GoalieAnatomy.TORSO_BOX_HEIGHT_M * 0.5, 1e-6,
			"DEFAULT_GOALIE_PAD_TOP_SEAM_M must be the standing body centre (%.2f) " % standing_centre.y +
			"minus half the torso box (%.2f) — resize the box in Goalie.tscn and the "
			% GoalieAnatomy.TORSO_BOX_HEIGHT_M +
			"bot's roofing floor has to follow, or it plans against a torso that isn't there.")
