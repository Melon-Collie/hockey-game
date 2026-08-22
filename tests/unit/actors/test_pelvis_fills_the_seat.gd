extends GutTest

# The seat: three agreements between parts, none of them visible in the file
# that would break one.
#
# The trunk texture rotates the torso bone about the fold pivot at the hips, so
# at the faceoff centre's fold the jersey hem swings up and away and leaves the
# body open from behind — a flat bottom cap tipped into view over the V-notch
# between two hip balls. A real pelvis does not fold with the spine, so the
# rig's does not fold with the torso: it is a part of the UPPER mesh that the
# trunk texture is not applied to. That only works while it stays hidden under
# the jersey at rest, meets the hips it sits between, and keeps its hands off
# the fold.

const _SCENE: String = "res://Scenes/Skater.tscn"

# Both hip balls, from Scenes/Skater.tscn (x from LegL/LegR, z bias from HipL).
var _hip_centre_y: float = 0.0
var _hip_centre_x: float = 0.0
var _torso_origin_y: float = 0.0


func before_all() -> void:
	var st: SceneState = (load(_SCENE) as PackedScene).get_state()
	var origins: Dictionary = {}
	for i: int in st.get_node_count():
		var path: String = "%s/%s" % [st.get_node_path(i, true), st.get_node_name(i)]
		for p: int in st.get_node_property_count(i):
			if st.get_node_property_name(i, p) == "transform":
				origins[path] = (st.get_node_property_value(i, p) as Transform3D).origin
	var leg: Vector3 = origins["./MeshRoot/LowerBody/LegL"]
	var hip: Vector3 = origins["./MeshRoot/LowerBody/LegL/HipL"]
	_hip_centre_y = leg.y + hip.y
	_hip_centre_x = absf(leg.x + hip.x)
	_torso_origin_y = origins["./MeshRoot/UpperBody/UpperBodyMesh"].y


# Radius of a lathe profile at height `y`, linearly between its stations, plus
# that station's rear sway — the profile's own back edge. Outside the profile's
# span it has no material, which the callers handle.
func _profile_back(profile: Array[Vector2], sway: Array[float], y: float) -> float:
	for i: int in profile.size() - 1:
		var hi: Vector2 = profile[i]
		var lo: Vector2 = profile[i + 1]
		if y <= hi.x and y >= lo.x:
			var t: float = (hi.x - y) / maxf(hi.x - lo.x, 1e-6)
			return lerpf(hi.y, lo.y, t) + lerpf(sway[i], sway[i + 1], t)
	return -1.0


# ── It must not show at rest ─────────────────────────────────────────────────

# The pelvis exists to be seen only where there was nothing. Anywhere the torso
# still has material — every height the two share — it has to sit inside the
# torso's own rings, or it reads as a bulge through the jersey in every pose in
# the game rather than as the seat under one.
func test_the_pelvis_hides_under_the_jersey_at_rest() -> void:
	var checked: int = 0
	for station: Vector2 in SkaterMeshBuilder._PELVIS_PROFILE:
		# Pelvis stations are UpperBody-space; the torso lathe is built around
		# its own scene origin.
		var torso_local: float = station.x - _torso_origin_y
		var torso: float = _profile_back(SkaterMeshBuilder._TORSO_PROFILE, SkaterMeshBuilder._TORSO_REAR_SWAY, torso_local)
		if torso < 0.0:
			continue  # below the hem — the pelvis is on its own down there
		var pelvis: float = _profile_back(
				SkaterMeshBuilder._PELVIS_PROFILE, SkaterMeshBuilder._PELVIS_REAR_SWAY, station.x)
		assert_lt(pelvis, torso,
				"at y %.3f the pelvis (%.3f) must sit inside the torso (%.3f)"
				% [station.x, pelvis, torso])
		checked += 1
	assert_gt(checked, 1, "the two parts must overlap in height at all")


# ── It must meet what it sits between ────────────────────────────────────────

# The hips are two balls with a V-notch between them; the pelvis is what closes
# it. Their surfaces have to overlap at every height the balls span, or the seat
# gains a seam of daylight exactly where the old notch was.
func test_the_pelvis_meets_both_hip_balls() -> void:
	var hip_r: float = SkaterMeshBuilder._HIP_RADIUS
	var y: float = _hip_centre_y + hip_r
	while y > _hip_centre_y - hip_r:
		var dy: float = y - _hip_centre_y
		var ball: float = sqrt(maxf(hip_r * hip_r - dy * dy, 0.0))
		var pelvis: float = _profile_back(
				SkaterMeshBuilder._PELVIS_PROFILE, SkaterMeshBuilder._PELVIS_REAR_SWAY, y) * SkaterMeshBuilder._TORSO_X_SCALE
		assert_gt(pelvis + ball, _hip_centre_x,
				"at y %.3f the seat (%.3f) and the hip ball (%.3f) must still overlap"
				% [y, pelvis, ball])
		y -= 0.02


# ── It must not fold ─────────────────────────────────────────────────────────

# The whole point, and a one-line mistake to undo: adding PELVIS to the list of
# bones SkaterArmRig.repose_bone rotates by the trunk texture would give the
# body a second hem that swings away with the first.
func test_the_pelvis_does_not_fold_with_the_chest() -> void:
	var skater: Skater = (load(_SCENE) as PackedScene).instantiate() as Skater
	add_child_autofree(skater)
	skater.set_physics_process(false)
	skater.set_process(false)
	var rig: Skeleton3D = skater.upper_body.get_node("UpperRig") as Skeleton3D
	var pelvis_rest: Transform3D = rig.get_bone_pose(SkaterMeshBuilder.UpperBone.PELVIS)

	skater.set_trunk_texture(-deg_to_rad(48.0), 0.0)

	assert_gt(rig.get_bone_pose(SkaterMeshBuilder.UpperBone.TORSO).basis.get_euler().x, -1.0,
			"the torso must take the fold")
	assert_lt(rig.get_bone_pose(SkaterMeshBuilder.UpperBone.TORSO).basis.get_euler().x, -0.5,
			"the torso must take the whole fold")
	assert_eq(rig.get_bone_pose(SkaterMeshBuilder.UpperBone.PELVIS), pelvis_rest,
			"and the pelvis must not move at all")
