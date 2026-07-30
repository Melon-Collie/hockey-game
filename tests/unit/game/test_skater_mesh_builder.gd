extends GutTest

# SkaterMeshBuilder invariants a display-less run can still check. Three
# things break silently if a generator drifts, and each is pinned here:
#
#   1. Winding — Godot front faces are clockwise-from-outside, so an outward-
#      wound closed solid has NEGATIVE signed volume. An inside-out part still
#      "works" headless but renders as a hollow shell in game.
#   2. UV conventions — SkaterUniformCoordinator paints against the engine
#      primitive layouts (cylinder side V ∈ [0, 0.5], sphere equirect V ∈
#      [0, 1], everything inside [0, 1]). A part whose UVs drift out of range
#      wraps its jersey paint somewhere unintended.
#   3. Envelope — each part must stay inside the primitive it replaced (plus
#      millimetres), because ice contact, board clearance, and the gear that
#      overlaps it were all tuned around the primitive silhouettes.
#
# Proportion changes inside those bounds are free — this suite deliberately
# pins none of the shaping.

const _EPS: float = 0.005  # envelope tolerance, metres


class PartSpec:
	var label: String
	var mesh: ArrayMesh
	var max_size: Vector3
	var side_only_v: bool  # lathed part: side V capped at 0.5 (caps use the rest)

	func _init(p_label: String, p_mesh: ArrayMesh, p_max: Vector3, p_side: bool) -> void:
		label = p_label
		mesh = p_mesh
		max_size = p_max
		side_only_v = p_side


# Envelopes come from the primitives in Scenes/Skater.tscn: torso cylinder
# r 0.22 h 0.55, helmet sphere r 0.155, shoulder r 0.11, hip r 0.13, knee
# r 0.095, thigh cylinder r 0.14 h 0.3, sock r 0.09 h 0.3, skate r 0.09
# h 0.2, foot prolate sphere r 0.08 half-length 0.125.
func _parts() -> Array[PartSpec]:
	return [
		PartSpec.new("torso", SkaterMeshBuilder._build_torso(),
				Vector3(0.47, 0.55, 0.44), true),
		PartSpec.new("helmet", SkaterMeshBuilder._build_helmet(),
				Vector3(0.31, 0.31, 0.31), false),
		PartSpec.new("shoulder", SkaterMeshBuilder._build_shoulder(),
				Vector3(0.22, 0.22, 0.22), false),
		PartSpec.new("hip", SkaterMeshBuilder._build_hip(),
				Vector3(0.26, 0.26, 0.26), false),
		PartSpec.new("knee", SkaterMeshBuilder._build_knee(),
				Vector3(0.19, 0.19, 0.19), false),
		PartSpec.new("thigh", SkaterMeshBuilder._build_thigh(),
				Vector3(0.29, 0.30, 0.28), true),
		PartSpec.new("sock", SkaterMeshBuilder._build_sock(),
				Vector3(0.19, 0.30, 0.19), true),
		PartSpec.new("skate", SkaterMeshBuilder._build_skate(),
				Vector3(0.18, 0.20, 0.18), true),
		PartSpec.new("boot", SkaterMeshBuilder._build_boot(),
				Vector3(0.16, 0.25, 0.16), false),
	]


func test_every_part_is_wound_outward() -> void:
	for part: PartSpec in _parts():
		var vol: float = _signed_volume(part.mesh)
		assert_lt(vol, -1e-7,
				"%s should be a closed outward-wound solid (negative signed volume)"
				% part.label)


func test_every_part_has_unit_flat_normals() -> void:
	# Degenerate pole quads are allowed a zero-area filler triangle; every
	# triangle with real area must carry a unit normal (flat shading gives one
	# normal per face, so a bad one shows as a black facet).
	for part: PartSpec in _parts():
		var arrays: Array = part.mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var bad: int = 0
		for i in range(0, verts.size(), 3):
			var area2: float = (verts[i + 1] - verts[i]).cross(verts[i + 2] - verts[i]).length()
			if area2 > 1e-9 and absf(normals[i].length() - 1.0) > 0.01:
				bad += 1
		assert_eq(bad, 0, "%s should have unit normals on every real face" % part.label)


func test_uvs_stay_inside_painter_conventions() -> void:
	for part: PartSpec in _parts():
		var arrays: Array = part.mesh.surface_get_arrays(0)
		var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var v_side_max: float = 0.0
		for uv: Vector2 in uvs:
			assert_between(uv.x, 0.0, 1.0, "%s U inside [0, 1]" % part.label)
			assert_between(uv.y, 0.0, 1.0, "%s V inside [0, 1]" % part.label)
			if part.side_only_v and uv.y <= 0.5:
				v_side_max = maxf(v_side_max, uv.y)
		if part.side_only_v:
			# The side band should actually reach (near) the 0.5 boundary —
			# a shrunken V range would squash the stripe bands visibly.
			assert_gt(v_side_max, 0.45,
					"%s side V should span up to ~0.5 like the engine cylinder" % part.label)


func test_every_part_stays_inside_its_primitive_envelope() -> void:
	for part: PartSpec in _parts():
		var size: Vector3 = part.mesh.get_aabb().size
		for axis in 3:
			assert_lt(size[axis], part.max_size[axis] + _EPS,
					"%s axis %d should stay inside the replaced primitive's envelope"
					% [part.label, axis])


func test_boot_blade_reaches_the_replaced_spheres_ice_depth() -> void:
	# The foot node's local +Z is down; the prolate foot sphere it replaces
	# bottomed out at z = +0.08 ≈ the ice. The blade runner must reach that
	# depth (or the skate floats) without passing it (or it sinks).
	var aabb: AABB = SkaterMeshBuilder._build_boot().get_aabb()
	assert_almost_eq(aabb.position.z + aabb.size.z, 0.08, 0.002,
			"blade runner should bottom out at the old sphere's contact depth")


func test_apply_swaps_scene_primitives_and_keeps_default_materials() -> void:
	# Miniature stand-in for the Skater scene hierarchy: one lathed part and
	# one ball part with the scene's primitive meshes and default materials.
	# The cache is cleared first because the first swap wins the right to stamp
	# its default material on the shared mesh — a real Skater spawned by an
	# earlier test would otherwise have claimed it already.
	SkaterMeshBuilder._cache.clear()
	var upper := Node3D.new()
	var lower := Node3D.new()
	add_child_autofree(upper)
	add_child_autofree(lower)
	var torso := MeshInstance3D.new()
	torso.name = "UpperBodyMesh"
	var cyl := CylinderMesh.new()
	var default_mat := StandardMaterial3D.new()
	cyl.material = default_mat
	torso.mesh = cyl
	upper.add_child(torso)
	var helmet := MeshInstance3D.new()
	helmet.name = "Helmet"
	helmet.mesh = SphereMesh.new()
	upper.add_child(helmet)

	SkaterMeshBuilder.apply(upper, lower)

	assert_true(torso.mesh is ArrayMesh, "torso primitive should be swapped")
	assert_true(helmet.mesh is ArrayMesh, "helmet primitive should be swapped")
	assert_eq((torso.mesh as ArrayMesh).surface_get_material(0), default_mat,
			"the scene default material should ride the swapped mesh")


func _signed_volume(mesh: ArrayMesh) -> float:
	var arrays: Array = mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var total: float = 0.0
	for i in range(0, verts.size(), 3):
		total += verts[i].dot(verts[i + 1].cross(verts[i + 2])) / 6.0
	return total
