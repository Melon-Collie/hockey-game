extends GutTest

# GoalieMeshBuilder invariants — same three silent-drift risks as the skater
# suite (outward winding, in-range UVs, primitive envelopes; see
# test_skater_mesh_builder.gd for the reasoning) plus the goalie_jersey
# shader's geometric contract on the body mesh, which no renderless check
# would otherwise catch.

const _EPS: float = 0.005  # envelope tolerance, metres


# label → [mesh, max AABB size]. Envelopes come from the primitives in
# Goalie.tscn: body box 0.52×0.72×0.28, head sphere r 0.17 h 0.26, pad box
# 0.28×0.84×0.2, blocker box 0.2×0.3×0.05, hand sphere r 0.05. The trapper
# parts (rim / pocket / cuff) are sculpted past their original primitives on
# purpose but must stay near the glove's 0.25×0.25×0.2 collision box. The connector tube is unit-sized (its stretch is basis scale).
func _parts() -> Dictionary:
	return {
		"body": [GoalieMeshBuilder._build_body(), Vector3(0.52, 0.72, 0.28)],
		"mask": [GoalieMeshBuilder._build_mask(), Vector3(0.34, 0.26, 0.34)],
		"pad": [GoalieMeshBuilder._build_pad(), Vector3(0.28, 0.84, 0.20)],
		"glove_ring": [GoalieMeshBuilder._build_glove_ring(), Vector3(0.30, 0.07, 0.28)],
		"glove_pocket": [GoalieMeshBuilder._build_glove_pocket(), Vector3(0.24, 0.12, 0.22)],
		"glove_cuff": [GoalieMeshBuilder._build_glove_cuff(), Vector3(0.16, 0.15, 0.09)],
		"blocker": [GoalieMeshBuilder._build_blocker(), Vector3(0.20, 0.30, 0.05)],
		"blocker_hand": [GoalieMeshBuilder._build_blocker_hand(), Vector3(0.10, 0.10, 0.10)],
		"connector": [GoalieMeshBuilder.shared_connector_tube(), Vector3(0.16, 1.0, 0.16)],
		"pants": [GoalieMeshBuilder._build_pants(), Vector3(0.46, 0.24, 0.28)],
	}


func test_every_part_is_wound_outward() -> void:
	for label: String in _parts():
		var vol: float = _signed_volume(_parts()[label][0])
		assert_lt(vol, -1e-7,
				"%s should be a closed outward-wound solid (negative signed volume)" % label)


func test_uvs_stay_inside_painter_conventions() -> void:
	for label: String in _parts():
		var mesh: ArrayMesh = _parts()[label][0]
		var uvs: PackedVector2Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV]
		for uv: Vector2 in uvs:
			assert_between(uv.x, 0.0, 1.0, "%s U inside [0, 1]" % label)
			assert_between(uv.y, 0.0, 1.0, "%s V inside [0, 1]" % label)


func test_every_part_stays_inside_its_primitive_envelope() -> void:
	for label: String in _parts():
		var size: Vector3 = (_parts()[label][0] as ArrayMesh).get_aabb().size
		var max_size: Vector3 = _parts()[label][1]
		for axis in 3:
			assert_lt(size[axis], max_size[axis] + _EPS,
					"%s axis %d should stay inside the replaced primitive's envelope"
					% [label, axis])


func test_body_keeps_the_jersey_shader_contract() -> void:
	# goalie_jersey.gdshader gates the nameplate on normal.z > 0.9 (flat +Z
	# back face), the yoke on normal.y > 0.9 (flat top face), and maps
	# stripes over object Y. A reshaped body that loses any of these paints
	# a blank back, a missing yoke, or squashed stripes — invisible headless.
	var mesh: ArrayMesh = GoalieMeshBuilder._build_body()
	var arrays: Array = mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var back_area: float = 0.0
	var top_area: float = 0.0
	for i in range(0, verts.size(), 3):
		var area: float = (verts[i + 1] - verts[i]).cross(verts[i + 2] - verts[i]).length() * 0.5
		if normals[i].z > 0.9:
			back_area += area
		if normals[i].y > 0.9:
			top_area += area
	# Nameplate face: the GoalieTextDecal projection needs room — require at
	# least a 0.3 × 0.5 m worth of back-facing area (old box face: 0.52×0.72).
	assert_gt(back_area, 0.15, "body needs a flat +Z back region for the nameplate")
	assert_gt(top_area, 0.02, "body needs a flat top face for the yoke")
	var aabb: AABB = mesh.get_aabb()
	assert_almost_eq(aabb.size.y, 0.72, 0.001,
			"stripes map over object Y — the body must keep the box's full height span")


func _signed_volume(mesh: ArrayMesh) -> float:
	var arrays: Array = mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var total: float = 0.0
	for i in range(0, verts.size(), 3):
		total += verts[i].dot(verts[i + 1].cross(verts[i + 2])) / 6.0
	return total
