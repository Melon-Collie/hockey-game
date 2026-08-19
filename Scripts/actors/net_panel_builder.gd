class_name NetPanelBuilder

# Builds the goal's twine panels as tessellated, indexed meshes so
# goal_net.gdshader can bulge them where the puck lands. HockeyGoal owns WHERE
# the panels are (which corners, from the frame it draws); this owns what the
# mesh made from those corners looks like.
#
# Two properties the shader depends on and cannot establish for itself:
#
#   1. Enough vertices to displace. A quad is two triangles, and displacing two
#      triangles along their normal moves the whole panel as a slab. The grid
#      here is what turns that into a local bulge.
#   2. Normals that point OUT of the cage, consistently, on every panel, so the
#      twine lights as one surface from the side the camera is on. Winding order
#      does not give that — callers pass corners in whatever order reads
#      naturally for their panel — so the outward test is done here against the
#      cavity centre. (The bulge does NOT ride these: it takes one direction per
#      impact, because per-face normals tear a panel seam open. See
#      NetGeometry.nearest_surface_normal.)
#
# Panels stay flat: this tessellates them, it does not sag them. The rest pose
# is the same surface NetGeometry describes analytically, which is what
# test_net_geometry_mirrors.gd holds.

# Target edge length. The twine's own diamond is 41 mm
# (HockeyGoal.NET_TEXTURE_TILE_SIZE / 4), so a cell about that size puts the
# deformation resolution at the scale of the mesh being deformed — finer buys
# nothing a player can see, coarser makes a bulge read as facets.
const TARGET_EDGE: float = 0.04

# Cells per panel edge, so a mistake in the corner maths cannot ask for a
# million-vertex panel. The largest real panel (the back mesh, 1.83 m) wants 46.
const MAX_CELLS: int = 64


# Tessellated quadrilateral panel. Corners in order around the quad; A→B and
# A→D are treated as the two spanning edges, so the surface is the bilinear
# patch between them (which is exact for the trapezoidal back mesh, whose top
# edge is narrower than its bottom).
#
# `uv_tile` is the world size one texture tile covers; `cavity_center` is the
# inside of the cage, used only to orient the normal outward.
static func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		uv_tile: float, cavity_center: Vector3) -> ArrayMesh:
	var ns: int = _cells(a.distance_to(b))
	var nt: int = _cells(a.distance_to(d))
	var normal: Vector3 = _outward_normal((b - a).cross(d - a), (a + b + c + d) * 0.25, cavity_center)
	var u_axis: Vector3 = (b - a).normalized()
	var v_axis: Vector3 = normal.cross(u_axis).normalized()
	var uv_scale: float = 1.0 / uv_tile

	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	verts.resize((ns + 1) * (nt + 1))
	uvs.resize((ns + 1) * (nt + 1))
	for j in nt + 1:
		var t: float = float(j) / float(nt)
		for i in ns + 1:
			var s: float = float(i) / float(ns)
			# Bilinear: lerp along A→B at the near edge and D→C at the far one,
			# then between the two. Exact for the trapezoidal back mesh.
			var p: Vector3 = a.lerp(b, s).lerp(d.lerp(c, s), t)
			var idx: int = j * (ns + 1) + i
			verts[idx] = p
			uvs[idx] = _project_uv(p, a, u_axis, v_axis, uv_scale)

	var indices := PackedInt32Array()
	indices.resize(ns * nt * 6)
	var w: int = 0
	for j in nt:
		for i in ns:
			var i00: int = j * (ns + 1) + i
			var i10: int = i00 + 1
			var i11: int = i00 + ns + 2
			var i01: int = i00 + ns + 1
			# Same cyclic order the untessellated panel used: (A,B,C) then (A,C,D).
			indices[w] = i00
			indices[w + 1] = i10
			indices[w + 2] = i11
			indices[w + 3] = i00
			indices[w + 4] = i11
			indices[w + 5] = i01
			w += 6
	return _commit(verts, uvs, indices, normal)


# Tessellated triangular panel, for the back-side gussets where a quad would
# degenerate. Subdivided on a barycentric grid: row i spans from A+(B−A)·i/n to
# A+(C−A)·i/n and carries i+1 vertices.
static func tri(a: Vector3, b: Vector3, c: Vector3,
		uv_tile: float, cavity_center: Vector3) -> ArrayMesh:
	var n: int = _cells(maxf(a.distance_to(b), maxf(b.distance_to(c), a.distance_to(c))))
	var normal: Vector3 = _outward_normal((b - a).cross(c - a), (a + b + c) / 3.0, cavity_center)
	var u_axis: Vector3 = (b - a).normalized()
	var v_axis: Vector3 = normal.cross(u_axis).normalized()
	var uv_scale: float = 1.0 / uv_tile

	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	# Row starts, so a row's vertices can be indexed without re-deriving them.
	var row_start := PackedInt32Array()
	row_start.resize(n + 1)
	for i in n + 1:
		row_start[i] = verts.size()
		var left: Vector3 = a.lerp(b, float(i) / float(n))
		var right: Vector3 = a.lerp(c, float(i) / float(n))
		for k in i + 1:
			# Row 0 is the apex: one vertex, and the lerp fraction is degenerate.
			var f: float = 0.0 if i == 0 else float(k) / float(i)
			var p: Vector3 = left.lerp(right, f)
			verts.append(p)
			uvs.append(_project_uv(p, a, u_axis, v_axis, uv_scale))

	var indices := PackedInt32Array()
	for i in n:
		for k in i + 1:
			# Upward triangle, one per vertex of the row above.
			indices.append(row_start[i] + k)
			indices.append(row_start[i + 1] + k)
			indices.append(row_start[i + 1] + k + 1)
			if k < i:
				# Downward triangle filling the gap between two upward ones.
				indices.append(row_start[i] + k)
				indices.append(row_start[i + 1] + k + 1)
				indices.append(row_start[i] + k + 1)
	return _commit(verts, uvs, indices, normal)


# Cells along an edge of `length`, at least one.
static func _cells(length: float) -> int:
	return clampi(ceili(length / TARGET_EDGE), 1, MAX_CELLS)


# `raw` oriented to point away from the cage. `centroid` is the panel's own
# centre; a panel is outside its cavity by construction, so the sign of the
# offset between them is what "outward" means for every panel of the cage.
static func _outward_normal(raw: Vector3, centroid: Vector3, cavity_center: Vector3) -> Vector3:
	var n: Vector3 = raw.normalized()
	return -n if n.dot(centroid - cavity_center) < 0.0 else n


# A point's UV: its offset from the panel anchor expressed in the panel's own
# 2D basis, scaled so the diamond texture tiles at its real-world size whatever
# the panel's dimensions are.
static func _project_uv(p: Vector3, anchor: Vector3, u_axis: Vector3, v_axis: Vector3,
		uv_scale: float) -> Vector2:
	var offset: Vector3 = p - anchor
	return Vector2(offset.dot(u_axis) * uv_scale, offset.dot(v_axis) * uv_scale)


# One flat panel: every vertex carries the panel normal, so the surface lights
# as the plane it is and the shader has a single direction to displace along.
static func _commit(verts: PackedVector3Array, uvs: PackedVector2Array,
		indices: PackedInt32Array, normal: Vector3) -> ArrayMesh:
	var normals := PackedVector3Array()
	normals.resize(verts.size())
	normals.fill(normal)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
