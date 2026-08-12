class_name BoardAdBandBuilder
extends RefCounted

# Arc-length machinery for the dasher boards, and the ribbon mesh the sponsor
# panels ride on.
#
# HockeyRink's perimeter stations are spaced by GEOMETRY, not by distance: a 43 m
# straight run contributes two stations while a 13 m corner contributes
# `corner_segments` of them. So anything that has to be placed at a physical
# distance along the boards — a panel of a fixed width, a check for which paint
# sits under a given stretch — has to go through the cumulative arc table here,
# never through a station index. It is the same reason the band meshes' own UVs
# (which run on station index, see HockeyRink._emit_perimeter_band_arrays) cannot
# carry this art: a texture on them is crushed on the straights and smeared
# through the corners.
#
# Build-time only. Nothing in this file is reachable from a physics tick.

# Longest chord a ribbon quad may span. On a straight run this just subdivides a
# flat quad for nothing; through a corner it is what keeps the panel on the arc
# instead of chording across it. At 0.35 m the sag against an 8.53 m corner
# radius is under 2 mm — well inside the 1.5 mm the ribbon already stands off
# the boards, so a panel never dips behind the wall it is mounted on.
const MAX_SEGMENT_LEN: float = 0.35


# Cumulative distance along the station loop. n + 1 entries: the last is the full
# perimeter, since the closing edge from the last station back to stations[0] is
# part of the loop.
static func cumulative_arcs(stations: Array) -> PackedFloat32Array:
	var count: int = stations.size()
	var cumulative := PackedFloat32Array()
	cumulative.resize(count + 1)
	cumulative[0] = 0.0
	for i: int in count:
		var here: Vector2 = stations[i].pos
		var next: Vector2 = stations[(i + 1) % count].pos
		cumulative[i + 1] = cumulative[i] + here.distance_to(next)
	return cumulative


static func perimeter_of(cumulative: PackedFloat32Array) -> float:
	return cumulative[cumulative.size() - 1]


# Centerline position at arc `s`, wrapping the seam.
static func sample_pos(stations: Array, cumulative: PackedFloat32Array, s: float) -> Vector2:
	var index: int = _segment_at(cumulative, s)
	var fraction: float = _fraction_in(cumulative, index, s)
	var count: int = stations.size()
	var here: Vector2 = stations[index].pos
	var next: Vector2 = stations[(index + 1) % count].pos
	return here.lerp(next, fraction)


# Inward (rink-facing) unit normal at arc `s`. Lerped between stations rather
# than slerped — the corners are sampled finely enough that the difference is
# below a tenth of a degree.
static func sample_inward(stations: Array, cumulative: PackedFloat32Array, s: float) -> Vector2:
	var index: int = _segment_at(cumulative, s)
	var fraction: float = _fraction_in(cumulative, index, s)
	var count: int = stations.size()
	var here: Vector2 = stations[index].inward
	var next: Vector2 = stations[(index + 1) % count].inward
	var blended: Vector2 = here.lerp(next, fraction)
	if blended.length_squared() < 0.000001:
		return here
	return blended.normalized()


# One mesh for every panel on the boards: they share an atlas, so they share a
# material, so the whole perimeter of advertising is a single draw call.
#
# `placements` are (arc start, width) pairs from BoardAdLayout; `uv_rects` is the
# parallel list of atlas cells to sample. `radial_offset` is the distance from
# the station centerline to the ribbon's face, measured along the inward normal.
#
# Returns null when there is nothing to draw, so the caller can skip the node
# entirely rather than adding an empty MeshInstance3D.
static func build_band(stations: Array, cumulative: PackedFloat32Array,
		placements: Array[Vector2], uv_rects: Array[Rect2],
		radial_offset: float, y_bot: float, y_top: float) -> ArrayMesh:
	if placements.is_empty() or placements.size() != uv_rects.size():
		return null

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()

	for panel_index: int in placements.size():
		var placement: Vector2 = placements[panel_index]
		var cell: Rect2 = uv_rects[panel_index]
		var segments: int = maxi(1, ceili(placement.y / MAX_SEGMENT_LEN))
		var base: int = verts.size()

		for step: int in segments + 1:
			var along: float = float(step) / float(segments)
			var s: float = placement.x + placement.y * along
			var centerline: Vector2 = sample_pos(stations, cumulative, s)
			var inward: Vector2 = sample_inward(stations, cumulative, s)
			var face: Vector2 = centerline + inward * radial_offset
			var normal := Vector3(inward.x, 0.0, inward.y)
			# Top row first, so v runs with the image: the atlas cell's top edge
			# is the top of the panel on the wall.
			verts.append(Vector3(face.x, y_top, face.y))
			verts.append(Vector3(face.x, y_bot, face.y))
			normals.append(normal)
			normals.append(normal)
			var u: float = cell.position.x + cell.size.x * along
			uvs.append(Vector2(u, cell.position.y))
			uvs.append(Vector2(u, cell.position.y + cell.size.y))

		for step: int in segments:
			var a: int = base + step * 2
			var b: int = base + (step + 1) * 2
			indices.append(a); indices.append(a + 1); indices.append(b + 1)
			indices.append(a); indices.append(b + 1); indices.append(b)

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# Largest index whose cumulative arc is at or below `s` (after wrapping).
static func _segment_at(cumulative: PackedFloat32Array, s: float) -> int:
	var perimeter: float = perimeter_of(cumulative)
	var target: float = fposmod(s, perimeter)
	var lo: int = 0
	var hi: int = cumulative.size() - 2   # last valid segment start
	while lo < hi:
		var mid: int = (lo + hi + 1) >> 1
		if cumulative[mid] <= target:
			lo = mid
		else:
			hi = mid - 1
	return lo


static func _fraction_in(cumulative: PackedFloat32Array, index: int, s: float) -> float:
	var perimeter: float = perimeter_of(cumulative)
	var target: float = fposmod(s, perimeter)
	var span: float = cumulative[index + 1] - cumulative[index]
	if span <= 0.000001:
		return 0.0
	return clampf((target - cumulative[index]) / span, 0.0, 1.0)
