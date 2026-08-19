class_name ArenaSeating
extends RefCounted

# The seats themselves. Furniture, one per seating position, occupied or not —
# which is the whole point: a bowl at 0.93 attendance shows bare concrete in the
# empty spots and in the 0.27 m of daylight between neighbours at the shipping
# spacing.
#
# Same shape as the crowd — per-section MultiMeshes over the same angular slices,
# so seats frustum-cull with the spectators sitting in them — but built in a
# separate pass over the same rows rather than alongside them. Two reasons, and
# both are load-bearing:
#
#   A seat exists whether or not anyone is in it, so this pass has no vacancy
#   roll. Weaving that difference into the crowd's row walk would mean two
#   traversals of one rng stream, and the crowd's whole appearance is downstream
#   of that stream's order.
#
#   Seats are bolted to the concrete: no yaw jitter, no height jitter, no
#   animation. The crowd's sway/hop comes from its shader reading per-instance
#   custom data; seats want none of it, so they carry no custom data and use a
#   plain material instead.

# Seat furniture: a pan on the tread and a backrest behind it, in the seated
# spectator's own local frame (local −Z faces the rink, so +Z is outward).
#
# Every number here is bounded by something already fixed, and the body it has
# to clear is the LARGEST stature roll — 0.39 m across and deep, not the mesh's
# nominal 0.28 m. The seat is wider than that so it shows either side of an
# occupant, and narrower than the 0.55 m spacing so neighbours don't merge into a
# bench. The pan reaches 0.17 m forward — the spectator sits 0.18 m outward of
# the tread's inner edge, so a deeper pan would hang over the drop. The backrest
# starts at 0.205 m, clearing that body's 0.195 m back face, and ends at 0.255 m,
# short of the next riser 0.42 m out. It stands 0.38 m against a seated occupant
# of 0.80–0.96 m, so shoulders and head clear the top of the seat.
const WIDTH: float = 0.46
const PAN_DEPTH: float = 0.34
const PAN_THICKNESS: float = 0.05
const BACK_HEIGHT: float = 0.38
const BACK_THICKNESS: float = 0.05
# Clears the deepest body a stature roll can produce (the tallest roll is also
# the deepest); at 0.20 the backrest passes through it.
const BACK_OFFSET: float = 0.23
# Same trick as ArenaFigureMesh.BODY_Y_LIFT, for the same reason: the pan's
# underside would otherwise be coplanar with the tread it rests on.
const _Y_LIFT: float = 0.002
# Seats roll their shade from their own stream. Sharing the crowd's would tie
# the two together — a change to seat jitter would repaint every spectator.
const _SEED: int = 90210

var _spec: ArenaBowlSpec
var _path: ArenaBowlPath
var _rake: ArenaBowlRake


func _init(spec: ArenaBowlSpec, path: ArenaBowlPath, rake: ArenaBowlRake) -> void:
	_spec = spec
	_path = path
	_rake = rake


func fill_layout(layout: Dictionary) -> void:
	var transforms: Array[Transform3D] = []
	var shades: PackedFloat32Array = PackedFloat32Array()
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = _SEED
	for i: int in _rake.lower_row_count():
		_append_row(transforms, shades, rng,
				_rake.lower_row_offset(i) + _rake.seat_inset(),
				_rake.lower_row_y(i), i)
	for j: int in _rake.upper_row_count():
		_append_row(transforms, shades, rng,
				_rake.upper_row_offset(j) + _rake.seat_inset(),
				_rake.upper_row_y(j), -1)

	var seat_mesh: ArrayMesh = build_seat_mesh()
	var seat_mms: Array[MultiMesh] = []
	for idxs: PackedInt32Array in ArenaBowlPath.sector_bins(transforms):
		if idxs.is_empty():
			continue
		var mm: MultiMesh = MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = seat_mesh
		mm.instance_count = idxs.size()
		var seed_aabb: AABB = AABB(transforms[idxs[0]].origin, Vector3.ZERO)
		for n_i: int in idxs.size():
			var src: int = idxs[n_i]
			mm.set_instance_transform(n_i, transforms[src])
			# White scaled by the shade roll. The material's albedo carries the
			# actual colour and multiplies through, so seat_color stays a live
			# export instead of something baked into this cached layout.
			var shade: float = shades[src]
			mm.set_instance_color(n_i, Color(shade, shade, shade))
			seed_aabb = seed_aabb.expand(transforms[src].origin)
		mm.custom_aabb = grow_seat_aabb(seed_aabb)
		seat_mms.append(mm)
	layout["seat_mms"] = seat_mms


# One ring of seats. Mirrors the crowd's placement rules — the bench cutout and
# the aisles take precedence over furniture the same way they take precedence
# over people — minus the vacancy roll and every jitter.
func _append_row(transforms: Array[Transform3D], shades: PackedFloat32Array,
		rng: RandomNumberGenerator, seat_off: float, y: float,
		bench_row: int) -> void:
	var resampled: PackedVector2Array = ArenaBowlPath.resample_uniform(
			_path.sample_offset_path(seat_off), _spec.spectator_spacing)
	for i: int in resampled.size():
		var p: Vector2 = resampled[i]
		if bench_row >= 0 and ArenaRinksideLayout.in_bench_zone(bench_row, p):
			continue
		if _path.in_aisle(_path.base_path_s(p)):
			continue
		transforms.append(Transform3D(
				Basis(Vector3.UP, ArenaBowlPath.row_facing_yaw(resampled, i)),
				Vector3(p.x, y, p.y)))
		shades.append(1.0 - rng.randf() * _spec.seat_shade_variation)


# Unlike the crowd's, a seat's AABB needs no animation headroom — nothing here
# sways or hops. It still needs the mesh's own extent, since the seed box only
# covers instance ORIGINS, and the horizontal margin still has to allow for a
# seat rotated to any heading around the bowl.
func grow_seat_aabb(seed_aabb: AABB) -> AABB:
	var reach: float = Vector2(WIDTH, BACK_OFFSET + BACK_THICKNESS).length() * 0.5 + 0.1
	var pos: Vector3 = seed_aabb.position - Vector3(reach, 0.05, reach)
	var end: Vector3 = seed_aabb.end + Vector3(reach, BACK_HEIGHT + 0.1, reach)
	return AABB(pos, end - pos)


# Pan and backrest as one mesh. They are rigidly related and share a colour, so
# splitting them would double the instance count to buy nothing — unlike the
# crowd's body and head, which are separate only because they take different
# per-instance colours (shirt and skin) from the same transform.
func build_seat_mesh() -> ArrayMesh:
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PrimitiveType.PRIMITIVE_TRIANGLES)
	ArenaMeshEmit.box(st, Vector3(0.0, _Y_LIFT + PAN_THICKNESS * 0.5, 0.0),
			Vector3(WIDTH, PAN_THICKNESS, PAN_DEPTH))
	ArenaMeshEmit.box(st, Vector3(0.0, _Y_LIFT + BACK_HEIGHT * 0.5, BACK_OFFSET),
			Vector3(WIDTH, BACK_HEIGHT, BACK_THICKNESS))
	st.generate_normals()
	return st.commit()


func attach(root: Node3D, layout: Dictionary) -> void:
	var seat_mms: Array[MultiMesh] = layout.seat_mms
	if seat_mms.is_empty():
		return
	var mat: StandardMaterial3D = _material()
	for k: int in seat_mms.size():
		var mmi: MultiMeshInstance3D = MultiMeshInstance3D.new()
		mmi.multimesh = seat_mms[k]
		mmi.name = "Seats%d" % k
		mmi.material_override = mat
		# Shadows off for the same reason the crowd's are (see ArenaCrowd.attach).
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# And out of the GI probe: SDFGI voxelizes static geometry, which is
		# exactly what these are and exactly the volume it charges for. Seats
		# are small, dark, and mostly under an occupant — they have nothing to
		# contribute to bounce that the terrace beneath them doesn't already.
		mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		root.add_child(mmi)


# Flat and unshiny — moulded plastic, not furniture polish. Vertex colour is on
# so the per-instance shade roll multiplies into the albedo.
func _material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _spec.seat_color
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.85
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return mat
