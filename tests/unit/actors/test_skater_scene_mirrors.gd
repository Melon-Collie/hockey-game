extends GutTest

# Scenes/Skater.tscn is hand-edited in the Godot editor; the constants that
# restate it live in text files edited separately. Nothing reads both, so a
# proportion moved in the editor and a constant left behind cannot disagree
# loudly — they disagree in the render, or worse, in the reach math.
#
# The sibling of test_goalie_scene_mirrors.gd, and the same argument: the scene
# is the authored truth for where a shoulder or a knee sits, and the code around
# it is a copy that has to keep up.
#
# The rig is doubly scene-coupled: Skater._build_arm_rig / _build_leg_rig read
# each node's authored transform out of the scene and then FREE the subtree, so
# a renamed or reparented node is not a missing-node error at runtime — it is a
# bone that silently keeps its identity transform.

const _SCENE: String = "res://Scenes/Skater.tscn"

var _origins: Dictionary = {}


func before_all() -> void:
	var st: SceneState = (load(_SCENE) as PackedScene).get_state()
	for i: int in st.get_node_count():
		var path: String = "%s/%s" % [st.get_node_path(i, true), st.get_node_name(i)]
		for p: int in st.get_node_property_count(i):
			if st.get_node_property_name(i, p) == "transform":
				_origins[path] = (st.get_node_property_value(i, p) as Transform3D).origin


func _origin(path: String) -> Vector3:
	assert_true(_origins.has(path), "no node at `%s` in %s" % [path, _SCENE])
	return _origins.get(path, Vector3.ZERO)


# The one mirror where a silent drift changes GAMEPLAY rather than the picture.
# shoulder_offset / shoulder_height feed SkaterController.apply_attributes'
# backhand reach solve (reach = sqrt(arm_eff² − drop²)), so a shoulder moved in
# the editor moves how far a skater can actually reach across their body.
func test_shoulder_anchors_mirror_the_scene() -> void:
	var left: Vector3 = _origin("./MeshRoot/UpperBody/ShoulderL")
	var right: Vector3 = _origin("./MeshRoot/UpperBody/ShoulderR")
	var skater: Skater = Skater.new()
	assert_almost_eq(skater.shoulder_offset, absf(left.x), 1e-6,
			"shoulder_offset must equal ShoulderL's lateral offset")
	assert_almost_eq(skater.shoulder_offset, absf(right.x), 1e-6,
			"and ShoulderR's — the rig assumes the pair is symmetric")
	assert_almost_eq(skater.shoulder_height, left.y, 1e-6,
			"shoulder_height must equal the shoulder ball's height, which is the " +
			"top of the backhand reach triangle")
	assert_almost_eq(left.y, right.y, 1e-6, "both shoulders sit at one height")
	skater.free()


func test_helmet_and_torso_stations_mirror_the_scene() -> void:
	assert_almost_eq(_origin("./MeshRoot/UpperBody/Helmet").y, 0.65, 1e-6,
			"the neck profile is built in helmet-local space from this origin — move " +
			"the helmet and the neck stops sinking into the traps")
	var torso_origin: float = _origin("./MeshRoot/UpperBody/UpperBodyMesh").y
	assert_almost_eq(torso_origin, 0.195, 1e-6,
			"the torso lathe is built around this origin")
	assert_almost_eq(torso_origin + 0.275, 0.47, 1e-6,
			"torso origin plus the trap-line station (_TORSO_PROFILE[0].x) is the " +
			"shoulder shelf the neck profile is sized against")


# _HIP_RADIUS deliberately does NOT carry the seat bias — the scene node does,
# so the ball is a plain sphere and the offset is authored where it is visible.
func test_hip_seat_bias_lives_in_the_scene_not_the_radius() -> void:
	assert_almost_eq(_origin("./MeshRoot/LowerBody/LegL/HipL").z, 0.035, 1e-6,
			"the rearward seat bias is the HipL node's own z")
	assert_almost_eq(_origin("./MeshRoot/LowerBody/LegR/HipR").z, 0.035, 1e-6,
			"and HipR's, symmetric about the body axis")


# The knee ball has to span the gap the thigh and sock leave between them, or
# the leg shows daylight at the joint through the whole stride.
func test_the_knee_ball_covers_the_thigh_to_sock_gap() -> void:
	var thigh_bottom: float = _origin("./MeshRoot/LowerBody/LegL/ThighL").y + (-0.15)
	var shin: float = _origin("./MeshRoot/LowerBody/LegL/ShinL").y
	var sock_top: float = shin + _origin("./MeshRoot/LowerBody/LegL/ShinL/SockL").y + 0.150
	var gap: float = thigh_bottom - sock_top
	assert_gt(0.095 * 2.0, gap,
			"_KNEE_RADIUS (0.095) must span the %.3f m the thigh and sock leave " % gap +
			"between them")


# The skate collar perches ON the boot with an overlap seal rather than dropping
# past the heel — which only holds while the scene seats SkateL at the heel-top
# line. The profile ends 1 cm below its own origin to make the seal.
func test_the_skate_collar_seats_at_the_boot_heel_line() -> void:
	assert_almost_eq(_origin("./MeshRoot/LowerBody/LegL/ShinL/SkateL").y, -0.41, 1e-5,
			"SkateL's origin is the heel-top line the collar profile is authored against")


# Every bone the rig reads out of the scene. These are the paths
# Skater._build_leg_rig / _build_upper_rig resolve before freeing the subtree —
# a rename in the editor leaves the bone at identity, which is a silent
# mispose rather than an error.
func test_every_authored_bone_node_still_exists() -> void:
	for path: String in SkaterMeshBuilder.LEG_BONE_NODE:
		assert_true(_origins.has("./MeshRoot/LowerBody/%s" % path),
				"LEG_BONE_NODE names `%s`, which is not in %s — the bone would " % [path, _SCENE] +
				"silently keep its identity transform")
	for path: String in SkaterMeshBuilder.UPPER_BONE_NODE:
		if path.is_empty():
			continue  # the arm parts are placed by IK, not authored in the scene
		assert_true(_origins.has("./MeshRoot/UpperBody/%s" % path),
				"UPPER_BONE_NODE names `%s`, which is not in %s" % [path, _SCENE])


func test_the_scene_scan_actually_saw_the_rig() -> void:
	assert_gt(_origins.size(), 20, "expected the whole rig — the parser may have broken")
	assert_true(_origins.has("./MeshRoot/UpperBody/ShoulderL"), "sanity: ShoulderL found")
