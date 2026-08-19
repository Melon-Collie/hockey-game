extends GutTest

# NetPanelBuilder turns the goal's panel corners into meshes the net shader can
# bulge. Three properties are load-bearing and none of them is visible in a
# screenshot:
#
#   1. The tessellated surface still IS the analytic surface. The mesh is what
#      the player sees; NetGeometry is what the puck collides with. They are two
#      descriptions of one net, and §1 of docs/net-play-plan.md is the record of
#      what happens when two descriptions drift.
#   2. UVs still tile the diamond texture at its real-world size, whatever the
#      subdivision — the tile size is a physical quantity (41 mm mesh), not a
#      texture-authoring convenience.
#   3. Normals point out of the cage on every panel, so the twine lights as one
#      surface rather than as eight independently-wound ones.

const TILE: float = HockeyGoal.NET_TEXTURE_TILE_SIZE


# A quad standing in for the back mesh: 1.83 m wide, leaning back as it drops.
func _back_panel_corners() -> Array[Vector3]:
	var z_top: float = GameRules.GOAL_LINE_Z + GameRules.NET_TOP_DEPTH
	var z_bot: float = GameRules.GOAL_LINE_Z + GameRules.NET_DEPTH
	return [
		Vector3(-GameRules.NET_CROWN_HALF_WIDTH, GameRules.NET_HEIGHT, z_top),
		Vector3( GameRules.NET_CROWN_HALF_WIDTH, GameRules.NET_HEIGHT, z_top),
		Vector3( GameRules.NET_HALF_WIDTH, 0.0, z_bot),
		Vector3(-GameRules.NET_HALF_WIDTH, 0.0, z_bot),
	]


func _cavity_center() -> Vector3:
	return Vector3(0.0, GameRules.NET_HEIGHT / 2.0,
			GameRules.GOAL_LINE_Z + GameRules.NET_DEPTH / 2.0)


func _verts(mesh: ArrayMesh) -> PackedVector3Array:
	return mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array


func _normals(mesh: ArrayMesh) -> PackedVector3Array:
	return mesh.surface_get_arrays(0)[Mesh.ARRAY_NORMAL] as PackedVector3Array


func _uvs(mesh: ArrayMesh) -> PackedVector2Array:
	return mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV] as PackedVector2Array


# THE mirror assertion: every vertex of the drawn back mesh sits on the plane
# NetGeometry.back_plane_distance describes. A tessellation bug that bowed the
# rest pose, or a corner passed in the wrong order, moves vertices off that
# plane while still looking like a net.
func test_back_panel_vertices_lie_on_the_analytic_back_plane() -> void:
	var c: Array[Vector3] = _back_panel_corners()
	var mesh: ArrayMesh = NetPanelBuilder.quad(c[0], c[1], c[2], c[3], TILE, _cavity_center())
	var verts: PackedVector3Array = _verts(mesh)
	assert_gt(verts.size(), 500,
			"the back mesh should tessellate to hundreds of vertices — a shader " +
			"cannot bulge a surface that has none to move")
	var worst: float = 0.0
	for v: Vector3 in verts:
		worst = maxf(worst, absf(NetGeometry.back_plane_distance(v)))
	# 0.1 mm. Mesh vertices are float32 at rink-scale coordinates (|z| ~ 27 m),
	# where one ulp is already ~2 um — so this is tight to the storage format,
	# not loose to the geometry.
	assert_almost_eq(worst, 0.0, 1e-4,
			"every drawn back-mesh vertex must lie on the analytic back plane — " +
			"the twine the player sees and the twine the puck hits are one surface")


# Cell size is what sets how local a bulge can be. Left unpinned, a change to
# TARGET_EDGE that quietly coarsened the grid would show up only as a bulge that
# had gone faceted, which nothing here can see.
func test_cells_are_about_the_target_edge() -> void:
	var c: Array[Vector3] = _back_panel_corners()
	var mesh: ArrayMesh = NetPanelBuilder.quad(c[0], c[1], c[2], c[3], TILE, _cavity_center())
	var verts: PackedVector3Array = _verts(mesh)
	var indices: PackedInt32Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX] as PackedInt32Array
	var longest: float = 0.0
	for i in range(0, indices.size(), 3):
		var a: Vector3 = verts[indices[i]]
		var b: Vector3 = verts[indices[i + 1]]
		var cc: Vector3 = verts[indices[i + 2]]
		longest = maxf(longest, maxf(a.distance_to(b), maxf(b.distance_to(cc), a.distance_to(cc))))
	# A cell's diagonal is the longest edge a triangle of it can have.
	assert_lt(longest, NetPanelBuilder.TARGET_EDGE * 2.0,
			"no triangle edge should run much past TARGET_EDGE — the grid is what " +
			"makes a strike bulge locally instead of moving the panel as a slab")


# The diamond grid is a physical 41 mm mesh, so a metre of panel must always be
# the same number of tiles however finely it is subdivided.
func test_uvs_tile_at_the_real_world_size() -> void:
	var c: Array[Vector3] = _back_panel_corners()
	var mesh: ArrayMesh = NetPanelBuilder.quad(c[0], c[1], c[2], c[3], TILE, _cavity_center())
	var verts: PackedVector3Array = _verts(mesh)
	var uvs: PackedVector2Array = _uvs(mesh)
	# Compare a UV span against the world distance it covers, over the widest
	# separation in the panel, so any accumulated scale error shows.
	var best_d: float = 0.0
	var best_uv: float = 0.0
	for i in verts.size():
		var d: float = verts[0].distance_to(verts[i])
		if d > best_d:
			best_d = d
			best_uv = uvs[0].distance_to(uvs[i])
	assert_almost_eq(best_uv, best_d / TILE, 1e-3,
			"UV distance must be world distance / NET_TEXTURE_TILE_SIZE — the mesh " +
			"is a real 41 mm diamond, not a texture stretched to fit the panel")


# Every panel of the cage, in the orientations HockeyGoal builds them, must face
# away from the cavity, so the twine shades as one surface from outside rather
# than as eight panels wound however their corner lists happened to read.
func test_every_panel_normal_faces_out_of_the_cage() -> void:
	var center: Vector3 = _cavity_center()
	var z_top: float = GameRules.GOAL_LINE_Z + GameRules.NET_TOP_DEPTH
	var z_bot: float = GameRules.GOAL_LINE_Z + GameRules.NET_DEPTH
	var hw: float = GameRules.NET_HALF_WIDTH
	var chw: float = GameRules.NET_CROWN_HALF_WIDTH
	var h: float = GameRules.NET_HEIGHT
	var panels: Array[Array] = [
		# Top roof, in HockeyGoal's corner order.
		[Vector3(-chw, h, GameRules.GOAL_LINE_Z), Vector3(chw, h, GameRules.GOAL_LINE_Z),
			Vector3(chw, h, z_top), Vector3(-chw, h, z_top)],
		# Back mesh.
		_back_panel_corners(),
		# Left side, then right side.
		[Vector3(-hw, 0.0, GameRules.GOAL_LINE_Z), Vector3(-hw, h, GameRules.GOAL_LINE_Z),
			Vector3(-hw, h, z_top), Vector3(-hw, 0.0, z_bot)],
		[Vector3(hw, 0.0, GameRules.GOAL_LINE_Z), Vector3(hw, h, GameRules.GOAL_LINE_Z),
			Vector3(hw, h, z_top), Vector3(hw, 0.0, z_bot)],
	]
	for corners: Array in panels:
		var mesh: ArrayMesh = NetPanelBuilder.quad(
				corners[0], corners[1], corners[2], corners[3], TILE, center)
		var n: Vector3 = _normals(mesh)[0]
		var centroid: Vector3 = (corners[0] + corners[1] + corners[2] + corners[3]) * 0.25
		assert_gt(n.dot(centroid - center), 0.0,
				"panel at %s must face away from the cavity, got normal %s" % [centroid, n])


func test_triangle_gusset_tessellates_and_stays_planar() -> void:
	var center: Vector3 = _cavity_center()
	var a := Vector3(GameRules.NET_HALF_WIDTH, 0.0, GameRules.GOAL_LINE_Z + GameRules.NET_DEPTH)
	var b := Vector3(GameRules.NET_CROWN_HALF_WIDTH, GameRules.NET_HEIGHT,
			GameRules.GOAL_LINE_Z + GameRules.NET_TOP_DEPTH)
	var c := Vector3(GameRules.NET_HALF_WIDTH, GameRules.NET_HEIGHT,
			GameRules.GOAL_LINE_Z + GameRules.NET_TOP_DEPTH)
	var mesh: ArrayMesh = NetPanelBuilder.tri(a, b, c, TILE, center)
	var verts: PackedVector3Array = _verts(mesh)
	var n: Vector3 = _normals(mesh)[0]
	assert_gt(verts.size(), 3, "the gusset should subdivide, not stay a single triangle")
	for v: Vector3 in verts:
		assert_almost_eq(n.dot(v - a), 0.0, 1e-4,
				"every gusset vertex must stay in the triangle's own plane")


# A degenerate ask (a panel far smaller than one cell) must still produce a
# usable mesh rather than a zero-cell grid.
func test_a_tiny_panel_still_builds_one_cell() -> void:
	var mesh: ArrayMesh = NetPanelBuilder.quad(
			Vector3.ZERO, Vector3(0.005, 0.0, 0.0),
			Vector3(0.005, 0.005, 0.0), Vector3(0.0, 0.005, 0.0),
			TILE, Vector3(0.0, 0.0, -1.0))
	assert_eq(_verts(mesh).size(), 4, "a sub-cell panel is one cell: four corners")
