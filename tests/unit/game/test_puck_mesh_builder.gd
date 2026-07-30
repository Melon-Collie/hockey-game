extends GutTest

# PuckMeshBuilder invariants — the same silent-drift risks the skater/goalie
# builder suites pin (see test_skater_mesh_builder.gd for the reasoning),
# for the one puck mesh.


func test_puck_is_outward_wound_inside_its_envelope() -> void:
	var mesh: ArrayMesh = PuckMeshBuilder._build_puck()
	var arrays: Array = mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var vol: float = 0.0
	for i in range(0, verts.size(), 3):
		vol += verts[i].dot(verts[i + 1].cross(verts[i + 2])) / 6.0
	assert_lt(vol, -1e-7,
			"puck should be a closed outward-wound solid (negative signed volume)")
	# Envelope of the replaced CylinderMesh: r 0.065 × h 0.035.
	var size: Vector3 = mesh.get_aabb().size
	assert_lt(size.x, 0.135, "puck should stay inside the cylinder's diameter")
	assert_lt(size.z, 0.135, "puck should stay inside the cylinder's diameter")
	assert_almost_eq(size.y, 0.035, 0.001, "puck should keep the regulation height")
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	for uv: Vector2 in uvs:
		assert_between(uv.x, 0.0, 1.0, "puck U inside [0, 1]")
		assert_between(uv.y, 0.0, 1.0, "puck V inside [0, 1]")
