class_name ArenaDeckMesh
extends RefCounted

# The poured concrete: the terraced bowl, the perimeter shell wall, and the
# tunnels behind the portals cut through both.
#
# Meshes are built separately from the nodes that carry them, because the
# terrace and shell meshes are the expensive half of a rebuild and are cached
# across rebuilds by `ArenaStands`, while the colors sit on per-instance
# material_overrides so a color tweak repaints without invalidating that cache.

var _spec: ArenaBowlSpec
var _path: ArenaBowlPath
var _rake: ArenaBowlRake


func _init(spec: ArenaBowlSpec, path: ArenaBowlPath, rake: ArenaBowlRake) -> void:
	_spec = spec
	_path = path
	_rake = rake


# ── Terraces ─────────────────────────────────────────────────────────────────

func build_terrace_mesh() -> ArrayMesh:
	# Compute step counts ONCE based on the base path (no offset). All rings
	# share the same sample count so tread quads stay aligned between the
	# inner and outer perimeter of each terrace.
	var counts: Vector2i = _path.path_step_counts()
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PrimitiveType.PRIMITIVE_TRIANGLES)
	for i: int in _rake.lower_row_count():
		var inner_off: float = _rake.lower_row_offset(i)
		_emit_terrace_row(st, i,
				_path.sample_offset_path(inner_off, counts.x, counts.y),
				_path.sample_offset_path(inner_off + _spec.tread_depth,
						counts.x, counts.y))
	# Concourse walkway: the top tread's level continues outward as a flat ring
	# to the upper-deck fascia (or the shell wall when the deck is disabled).
	if _spec.walkway_depth > 0.0:
		var walk_in: float = _rake.lower_row_offset(_rake.lower_row_count())
		ArenaMeshEmit.tread(st,
				_path.sample_offset_path(walk_in, counts.x, counts.y),
				_path.sample_offset_path(walk_in + _spec.walkway_depth,
						counts.x, counts.y),
				_rake.lower_top_tread_y())
	if _rake.upper_row_count() > 0:
		_emit_fascia(st, counts)
	for j: int in _rake.upper_row_count():
		var inner_off: float = _rake.upper_row_offset(j)
		var y_top: float = _rake.upper_row_y(j)
		var inner_pts: PackedVector2Array = _path.sample_offset_path(
				inner_off, counts.x, counts.y)
		var outer_pts: PackedVector2Array = _path.sample_offset_path(
				inner_off + _spec.tread_depth, counts.x, counts.y)
		ArenaMeshEmit.tread(st, inner_pts, outer_pts, y_top)
		if j > 0:
			ArenaMeshEmit.riser(st, inner_pts,
					y_top - _spec.upper_riser_height, y_top)
	st.generate_normals()
	return st.commit()


# Upper-deck fascia (balcony front): one tall riser spanning the whole walkway →
# first-tread rise. Concrete like the terraces — it's the same poured structure.
# The deck's row 0 emits no riser of its own, since a duplicate co-planar wall
# here would z-fight this one.
func _emit_fascia(st: SurfaceTool, counts: Vector2i) -> void:
	var walkway_y: float = _rake.lower_top_tread_y()
	var deck_y: float = _rake.upper_deck_base_y()
	var fascia_head: float = _rake.fascia_portal_head()
	if fascia_head <= walkway_y:
		ArenaMeshEmit.riser(st,
				_path.sample_offset_path(_rake.upper_deck_inner_offset(),
						counts.x, counts.y),
				walkway_y, deck_y)
		return
	# Portals through to the concourse, at the head of every lower-bowl stairway.
	# Same treatment as the shell wall: resampled fine enough that an opening
	# always spans several segments, cut below, solid above.
	var fine: PackedVector2Array = ArenaBowlPath.resample_uniform(
			_path.sample_offset_path(_rake.upper_deck_inner_offset()),
			ArenaBowlRake.VOMITORY_SAMPLE_M)
	ArenaMeshEmit.riser_gapped(st, fine, _rake.shell_cut_flags(fine),
			walkway_y, fascia_head)
	ArenaMeshEmit.riser(st, fine, fascia_head, deck_y)


# One lower-bowl row: its tread, the riser at its inner edge, and the side walls
# where a rinkside well cuts it down. Every segment is decided from its own
# midpoint, so tread, riser and wall agree on which sample the well's edge falls
# on — the cutout lands on a segment boundary rather than through a quad.
func _emit_terrace_row(st: SurfaceTool, row: int, inner: PackedVector2Array,
		outer: PackedVector2Array) -> void:
	var n: int = inner.size()
	var floor_ys: PackedFloat32Array = PackedFloat32Array()
	var riser_ys: PackedFloat32Array = PackedFloat32Array()
	floor_ys.resize(n)
	riser_ys.resize(n)
	for i: int in n:
		var mid: Vector2 = (inner[i] + inner[(i + 1) % n]) * 0.5
		floor_ys[i] = _rake.row_floor_y(row, mid)
		riser_ys[i] = _rake.riser_bottom_y(row, mid)
	for i: int in n:
		var j: int = (i + 1) % n
		var y: float = floor_ys[i]
		# Tread, CCW from above so the normal points +Y.
		ArenaMeshEmit.quad(st,
				Vector3(inner[i].x, y, inner[i].y), Vector3(inner[j].x, y, inner[j].y),
				Vector3(outer[j].x, y, outer[j].y), Vector3(outer[i].x, y, outer[i].y))
		# A row inside the well is level with the one in front of it, which
		# leaves nothing for a riser to span.
		if riser_ys[i] < y - 0.0001:
			ArenaMeshEmit.quad(st,
					Vector3(inner[i].x, riser_ys[i], inner[i].y),
					Vector3(inner[j].x, riser_ys[i], inner[j].y),
					Vector3(inner[j].x, y, inner[j].y),
					Vector3(inner[i].x, y, inner[i].y))
		var prev: float = floor_ys[(i + n - 1) % n]
		if not is_equal_approx(prev, y):
			# The concrete the well was carved out of, exposed at its end. Faces
			# into the well — whichever of the two neighbouring segments is the
			# lower one — because the terrace material culls back faces.
			ArenaMeshEmit.well_side(st, inner[i], outer[i], minf(prev, y),
					maxf(prev, y),
					inner[j] - inner[i] if y < prev else inner[i] - inner[j])


# Concrete color lives on a per-instance material_override, not in the cached
# mesh, so a concrete_color tweak repaints without invalidating the layout.
func add_terraces(root: Node3D, mesh: ArrayMesh) -> void:
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = mesh
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = _spec.concrete_color
	mat.roughness = 0.95
	# Every face is wound front-toward-the-bowl-interior (treads up, risers /
	# fascia rinkward), and the under-tread volumes are sealed by the riser
	# below, so back-face culling drops only never-visible geometry. Caveat: a
	# free-cam flight OUTSIDE the arena sees through the bowl's outer side —
	# acceptable for a dev/spectator edge case.
	mat.cull_mode = BaseMaterial3D.CULL_BACK
	mi.material_override = mat
	mi.name = "Terraces"
	root.add_child(mi)


# ── Shell wall ───────────────────────────────────────────────────────────────

# Perimeter shell wall, its own mesh with the dark shell material. Split from
# the terrace mesh so the two can be colored independently without vertex
# colors or a second surface.
func build_shell_mesh() -> ArrayMesh:
	var counts: Vector2i = _path.path_step_counts()
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PrimitiveType.PRIMITIVE_TRIANGLES)
	if _spec.shell_height > 0.0:
		var base_y: float = _rake.top_tread_y()
		var top_y: float = base_y + _spec.shell_height
		var wall_pts: PackedVector2Array = _path.sample_offset_path(
				_rake.shell_offset(), counts.x, counts.y)
		if _rake.vomitories_wanted():
			# The wall is resampled at a fixed spacing before the openings are
			# cut. Its own sampling is geometric — the corners get
			# `corner_segments` steps regardless of how far out the shell sits,
			# which at this radius stretches them to ~3 m — and an opening barely
			# wider than that would fall between two samples and never appear.
			var fine: PackedVector2Array = ArenaBowlPath.resample_uniform(
					wall_pts, ArenaBowlRake.VOMITORY_SAMPLE_M)
			var head_y: float = minf(base_y + _spec.vomitory_height, top_y)
			ArenaMeshEmit.riser_gapped(st, fine, _rake.shell_cut_flags(fine),
					base_y, head_y)
			ArenaMeshEmit.riser(st, fine, head_y, top_y)
		else:
			ArenaMeshEmit.riser(st, wall_pts, base_y, top_y)
	st.generate_normals()
	return st.commit()


# Shell color lives on a per-instance material_override (same pattern as the
# terraces' concrete) so a color tweak repaints without a layout rebuild.
func add_shell(root: Node3D, mesh: ArrayMesh) -> void:
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = mesh
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = _spec.shell_color
	mat.roughness = 1.0
	# Same winding contract as the terraces: the wall's front faces the bowl
	# interior, so cull the never-visible outward side.
	mat.cull_mode = BaseMaterial3D.CULL_BACK
	mi.material_override = mat
	# The wall is beyond every shadow-casting spotlight's range; skip it in the
	# shadow maps like the crowd.
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.name = "Shell"
	root.add_child(mi)


# ── Vomitories ───────────────────────────────────────────────────────────────

# A hole in the shell is only an improvement if it leads somewhere. Each opening
# gets a short recessed tunnel — two side walls, a ceiling, and a back wall lit
# as if the concourse beyond it were — so the portal reads as a way out rather
# than as a puncture showing the background colour through the building.
#
# Built as two meshes because the back wall is the only lit surface: everything
# else is the same dark concrete as the shell it is cut into.
func add_vomitory_tunnels(root: Node3D) -> void:
	if not _rake.vomitories_wanted():
		return
	var walls := SurfaceTool.new()
	var backs := SurfaceTool.new()
	walls.begin(Mesh.PrimitiveType.PRIMITIVE_TRIANGLES)
	backs.begin(Mesh.PrimitiveType.PRIMITIVE_TRIANGLES)

	# The back of the top deck. These bore out through the shell, which is the
	# last thing modelled — the arena has no exterior and is not meant to, so
	# what they leave on the outside is not a consideration. Both rings are cut
	# to the same depth, and the depth is chosen for how a portal reads from
	# inside the bowl.
	var shell_base: float = _rake.top_tread_y()
	_emit_vomitory_ring(walls, backs, _rake.shell_offset(), shell_base,
			minf(shell_base + _spec.vomitory_height,
					shell_base + _spec.shell_height))
	# And the back of the lower bowl, boring outward UNDER the upper deck, which
	# is where a real concourse runs.
	var fascia_head: float = _rake.fascia_portal_head()
	if _rake.upper_row_count() > 0 and fascia_head > _rake.lower_top_tread_y():
		_emit_vomitory_ring(walls, backs, _rake.upper_deck_inner_offset(),
				_rake.lower_top_tread_y(), fascia_head)

	walls.generate_normals()
	backs.generate_normals()
	# From a lit bowl a portal reads as a DARK hole with a hint of warmth deep in
	# it. A bright panel reads as something stuck ON the wall rather than cut into
	# it. The back is a little lighter than the sides on purpose: that gradient
	# from dark edges to a warmer centre is the only depth cue a 2.6 m recess gets
	# at this distance.
	_add_tunnel_instance(root, walls.commit(), "VomitoryTunnels",
			Color(0.055, 0.055, 0.065))
	_add_tunnel_instance(root, backs.commit(), "VomitoryLightSpill",
			Color(0.20, 0.16, 0.12))


# Tunnels behind every portal in one ring of wall.
#
# Extruded from the removed segments themselves rather than built as a box at
# each aisle's centre. An opening is cut by arc on the BASE path while the wall
# it is cut into stands metres further out, so the same arc span is a WIDER hole
# out there — wider still through a corner, and by a different amount for the
# fascia than for the shell. A box sized to the nominal width leaves daylight
# down both sides of every portal; following the cut segments makes each tunnel
# exactly as wide as its own hole, whatever that ring's radius did to it.
func _emit_vomitory_ring(walls: SurfaceTool, backs: SurfaceTool, offset: float,
		base_y: float, head_y: float) -> void:
	var wall: PackedVector2Array = ArenaBowlPath.resample_uniform(
			_path.sample_offset_path(offset), ArenaBowlRake.VOMITORY_SAMPLE_M)
	var count: int = wall.size()
	if count < 4 or head_y <= base_y:
		return
	var cut: PackedByteArray = _rake.shell_cut_flags(wall)

	for i: int in count:
		if cut[i] == 0:
			continue
		var j: int = (i + 1) % count
		var a: Vector2 = wall[i]
		var b: Vector2 = wall[j]
		var a_out: Vector2 = a + ArenaBowlPath.outward_at(wall, i) * _spec.vomitory_depth
		var b_out: Vector2 = b + ArenaBowlPath.outward_at(wall, j) * _spec.vomitory_depth
		# Back wall — the lit face at the end of the passage.
		ArenaMeshEmit.vertical_quad(backs, a_out, b_out, base_y, head_y)
		# Ceiling and floor. The floor matters: the ring's own walkway stops at
		# the wall, so without one a portal looks down into nothing.
		ArenaMeshEmit.deck_quad(walls, a, b, b_out, a_out, head_y)
		ArenaMeshEmit.deck_quad(walls, a, b, b_out, a_out, base_y)
		# Side walls, only where a run of cut segments begins or ends.
		if cut[(i - 1 + count) % count] == 0:
			ArenaMeshEmit.vertical_quad(walls, a, a_out, base_y, head_y)
		if cut[j] == 0:
			ArenaMeshEmit.vertical_quad(walls, b, b_out, base_y, head_y)


func _add_tunnel_instance(root: Node3D, mesh: ArrayMesh, node_name: String,
		color: Color) -> void:
	if mesh == null:
		return
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	# Unshaded, for two reasons. These surfaces are double-sided with winding
	# that carries no meaning (see ArenaMeshEmit.vertical_quad), so generated
	# normals would light half of them from behind and flatten the recess the
	# values are there to describe. And a concourse keeps its own lights: the
	# tunnels holding steady while the house dims for a skate-on is correct, not
	# a miss.
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mi)
