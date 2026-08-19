class_name ArenaMeshEmit

# SurfaceTool primitives the bowl's geometry is poured from. Pure emitters:
# every one appends triangles for the arguments it is given and reads nothing
# else, which is what lets the terraces, the seats and the spectator figures
# share them without any of the three depending on the others.
#
# Winding is CCW-is-front, matching Godot. Where a caller's material culls back
# faces (the terraces and the shell do) the winding is load-bearing and the
# caller's own comment says which way; where it culls nothing (the vomitory
# tunnels) either winding is fine.


# Horizontal quad strip between an inner and an outer perimeter ring, at `y`.
static func tread(st: SurfaceTool, inner: PackedVector2Array,
		outer: PackedVector2Array, y: float) -> void:
	var n: int = inner.size()
	for i: int in n:
		var j: int = (i + 1) % n
		var ia: Vector3 = Vector3(inner[i].x, y, inner[i].y)
		var oa: Vector3 = Vector3(outer[i].x, y, outer[i].y)
		var ib: Vector3 = Vector3(inner[j].x, y, inner[j].y)
		var ob: Vector3 = Vector3(outer[j].x, y, outer[j].y)
		# CCW from above so normals point +Y.
		st.add_vertex(ia)
		st.add_vertex(ib)
		st.add_vertex(ob)
		st.add_vertex(ia)
		st.add_vertex(ob)
		st.add_vertex(oa)


# Vertical wall along a perimeter ring, front face toward the rink interior.
static func riser(st: SurfaceTool, inner: PackedVector2Array,
		y_bot: float, y_top: float) -> void:
	var n: int = inner.size()
	for i: int in n:
		_riser_segment(st, inner[i], inner[(i + 1) % n], y_bot, y_top)


# `riser`, minus the segments flagged as doorways. `cut[i] == 1` drops the wall
# between point i and i+1.
static func riser_gapped(st: SurfaceTool, inner: PackedVector2Array,
		cut: PackedByteArray, y_bot: float, y_top: float) -> void:
	var n: int = inner.size()
	for i: int in n:
		if cut[i] == 1:
			continue
		_riser_segment(st, inner[i], inner[(i + 1) % n], y_bot, y_top)


# One wall panel. The winding is what fronts the whole bowl inward: on a path
# wound CCW from above, this order puts the front face toward the rink. The
# mirror winding fronts outward and is culled from every in-bowl camera, taking
# the risers, the fascia and the shell wall with it.
static func _riser_segment(st: SurfaceTool, a: Vector2, b: Vector2,
		y_bot: float, y_top: float) -> void:
	var ba := Vector3(a.x, y_bot, a.y)
	var ta := Vector3(a.x, y_top, a.y)
	var bb := Vector3(b.x, y_bot, b.y)
	var tb := Vector3(b.x, y_top, b.y)
	st.add_vertex(ba)
	st.add_vertex(bb)
	st.add_vertex(tb)
	st.add_vertex(ba)
	st.add_vertex(tb)
	st.add_vertex(ta)


# End wall of a rinkside well, at one ring sample: spans the row's tread
# inward-to-outward and the step the well cuts. `toward` points into the well,
# and the face is wound to look that way because the terrace material culls back
# faces.
static func well_side(st: SurfaceTool, p_in: Vector2, p_out: Vector2,
		y_lo: float, y_hi: float, toward: Vector2) -> void:
	var a := Vector3(p_in.x, y_lo, p_in.y)
	var b := Vector3(p_out.x, y_lo, p_out.y)
	var c := Vector3(p_out.x, y_hi, p_out.y)
	var d := Vector3(p_in.x, y_hi, p_in.y)
	if (b - a).cross(c - a).dot(Vector3(toward.x, 0.0, toward.y)) > 0.0:
		quad(st, a, b, c, d)
	else:
		quad(st, a, d, c, b)


# A horizontal quad through four ground points at height `y`.
static func deck_quad(st: SurfaceTool, a: Vector2, b: Vector2, c: Vector2,
		d: Vector2, y: float) -> void:
	st.add_vertex(Vector3(a.x, y, a.y))
	st.add_vertex(Vector3(b.x, y, b.y))
	st.add_vertex(Vector3(c.x, y, c.y))
	st.add_vertex(Vector3(a.x, y, a.y))
	st.add_vertex(Vector3(c.x, y, c.y))
	st.add_vertex(Vector3(d.x, y, d.y))


# A vertical quad between two ground points. Wound either way is fine for the
# only caller (the tunnels), whose surfaces are all double-sided.
static func vertical_quad(st: SurfaceTool, a: Vector2, b: Vector2,
		y_bot: float, y_top: float) -> void:
	st.add_vertex(Vector3(a.x, y_bot, a.y))
	st.add_vertex(Vector3(b.x, y_bot, b.y))
	st.add_vertex(Vector3(b.x, y_top, b.y))
	st.add_vertex(Vector3(a.x, y_bot, a.y))
	st.add_vertex(Vector3(b.x, y_top, b.y))
	st.add_vertex(Vector3(a.x, y_top, a.y))


static func box(st: SurfaceTool, center: Vector3, size: Vector3) -> void:
	var h: Vector3 = size * 0.5
	# 8 corners
	var p: Array[Vector3] = [
		center + Vector3(-h.x, -h.y, -h.z),  # 0
		center + Vector3( h.x, -h.y, -h.z),  # 1
		center + Vector3( h.x, -h.y,  h.z),  # 2
		center + Vector3(-h.x, -h.y,  h.z),  # 3
		center + Vector3(-h.x,  h.y, -h.z),  # 4
		center + Vector3( h.x,  h.y, -h.z),  # 5
		center + Vector3( h.x,  h.y,  h.z),  # 6
		center + Vector3(-h.x,  h.y,  h.z),  # 7
	]
	# Six faces, each two CCW-wound triangles (Godot front = CCW).
	# +Y (top)
	quad(st, p[4], p[7], p[6], p[5])
	# -Y (bottom)
	quad(st, p[0], p[1], p[2], p[3])
	# +Z (front)
	quad(st, p[3], p[2], p[6], p[7])
	# -Z (back)
	quad(st, p[1], p[0], p[4], p[5])
	# +X (right)
	quad(st, p[2], p[1], p[5], p[6])
	# -X (left)
	quad(st, p[0], p[3], p[7], p[4])


static func quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3,
		d: Vector3) -> void:
	st.add_vertex(a)
	st.add_vertex(b)
	st.add_vertex(c)
	st.add_vertex(a)
	st.add_vertex(c)
	st.add_vertex(d)
