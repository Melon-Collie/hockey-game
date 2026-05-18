@tool
class_name ArenaStands
extends Node3D

# Procedural terraced stands wrapping the rink, plus a MultiMeshInstance3D
# spectator crowd. Pattern mirrors HockeyRink — single rebuild on @export
# change, no runtime updates. Geometry is two draw calls: one ArrayMesh for
# all terraces, one MultiMesh for all spectators.

@export var rink_length: float = 60.0:
	set(v):
		rink_length = v
		_request_rebuild()
@export var rink_width: float = 26.0:
	set(v):
		rink_width = v
		_request_rebuild()
@export var corner_radius: float = 8.53:
	set(v):
		corner_radius = v
		_request_rebuild()
# Seat height of the first row. Fans look over the boards (Y=1.07) and
# through the glass (Y=1.07–2.22). With a seated body+head ~0.69 m tall,
# tread_y=0.8 puts eyes at ~1.5 m — mid-glass, behind the protective
# barrier, exactly how rinkside seats work.
@export var stands_base_y: float = 0.8:
	set(v):
		stands_base_y = v
		_request_rebuild()
@export var num_terraces: int = 15:
	set(v):
		num_terraces = v
		_request_rebuild()
@export var tread_depth: float = 0.6:
	set(v):
		tread_depth = v
		_request_rebuild()
@export var riser_height: float = 0.4:
	set(v):
		riser_height = v
		_request_rebuild()
# Outward offset measured from rink_width/2 (the wall/glass center). Boards
# and glass have wall_thickness=0.3 centered on this line, so their outer
# face sits at +0.15, and the kickplate/cap-rail lips protrude another
# ~1 cm beyond that. Default 0.20 keeps a few cm of clearance past the
# lips; values below ~0.17 will clip into the cap rail in the corners.
@export var base_outward_offset: float = 0.20:
	set(v):
		base_outward_offset = v
		_request_rebuild()
@export var corner_segments: int = 14:
	set(v):
		corner_segments = v
		_request_rebuild()
@export var concrete_color: Color = Color(0.42, 0.42, 0.45):
	set(v):
		concrete_color = v
		_request_rebuild()

@export_group("Crowd")
@export var spectator_spacing: float = 0.55:
	set(v):
		spectator_spacing = v
		_request_rebuild()
@export var spectator_inset_from_riser: float = 0.18:
	set(v):
		spectator_inset_from_riser = v
		_request_rebuild()
@export var spectator_yaw_jitter_deg: float = 18.0:
	set(v):
		spectator_yaw_jitter_deg = v
		_request_rebuild()
@export var spectator_y_jitter: float = 0.03:
	set(v):
		spectator_y_jitter = v
		_request_rebuild()

@export_group("Fan Mix")
# Crowd composition. Home + away + neutral should sum to 1.0; the neutral
# fraction is derived as max(0, 1 - home - away). Defaults model a typical
# home arena: a wall of home colors, a sprinkling of neutrals, and a small
# visiting-fan section's worth of away colors scattered through.
@export_range(0.0, 1.0) var home_fan_ratio: float = 0.65:
	set(v):
		home_fan_ratio = v
		_request_rebuild()
@export_range(0.0, 1.0) var away_fan_ratio: float = 0.08:
	set(v):
		away_fan_ratio = v
		_request_rebuild()
# Of team fans, fraction wearing secondary instead of primary. Keeps the
# bowl from reading as a solid block of one shade.
@export_range(0.0, 1.0) var secondary_color_ratio: float = 0.30:
	set(v):
		secondary_color_ratio = v
		_request_rebuild()
# Fraction of team fans whose head matches the team color (caps / face paint).
# Most heads use the neutral skin/hat palette regardless.
@export_range(0.0, 1.0) var team_cap_ratio: float = 0.22:
	set(v):
		team_cap_ratio = v
		_request_rebuild()

@export_group("Team Colors")
# Initial defaults; GameManager re-runs setup() with real team colors once
# TeamColorRegistry resolves them after _spawn_world.
@export var home_color: Color = Color(0.85, 0.20, 0.22):
	set(v):
		home_color = v
		_request_rebuild()
@export var home_color_secondary: Color = Color(0.97, 0.78, 0.20):
	set(v):
		home_color_secondary = v
		_request_rebuild()
@export var away_color: Color = Color(0.18, 0.40, 0.85):
	set(v):
		away_color = v
		_request_rebuild()
@export var away_color_secondary: Color = Color(0.92, 0.92, 0.95):
	set(v):
		away_color_secondary = v
		_request_rebuild()

@export_group("")
@export var rebuild: bool = false:
	set(_v):
		_request_rebuild()

# Deterministic seed so the editor preview matches the runtime build.
const _SEED: int = 31337
# Spectator body dimensions — stacked boxes matching the skater art style.
const _BODY_SIZE: Vector3 = Vector3(0.28, 0.45, 0.28)
const _HEAD_SIZE: Vector3 = Vector3(0.22, 0.22, 0.22)
# Tiny lift to keep the body bottom face off the tread without a visible gap.
# Without it the two co-planar surfaces z-fight; without keeping the bottom
# face at all, back-row spectators look hollow when the camera ends up below
# their row (upper-bowl rows reach ~6 m, well above typical camera height).
const _BODY_Y_LIFT: float = 0.002

# Civilian shirts/coats for the neutral fan slice.
var _neutral_body_palette: Array[Color] = [
	Color(0.25, 0.25, 0.28),  # charcoal
	Color(0.55, 0.45, 0.35),  # khaki
	Color(0.78, 0.74, 0.70),  # cream
	Color(0.40, 0.36, 0.32),  # taupe
	Color(0.92, 0.88, 0.85),  # off-white
	Color(0.35, 0.40, 0.45),  # slate
	Color(0.62, 0.30, 0.20),  # rust
]
# Skin tones + hat colors used for the head MultiMesh. Independent of body
# color (no team correlation) so the bowl reads as a sea of people, not a
# wall of identical avatars.
var _head_palette: Array[Color] = [
	Color(0.94, 0.82, 0.70),  # light skin
	Color(0.85, 0.69, 0.55),  # medium-light skin
	Color(0.72, 0.55, 0.42),  # medium skin
	Color(0.55, 0.40, 0.30),  # tan
	Color(0.40, 0.28, 0.22),  # dark skin
	Color(0.12, 0.10, 0.10),  # black hair / dark cap
	Color(0.32, 0.22, 0.16),  # brown hair
	Color(0.78, 0.74, 0.68),  # grey hair / pale cap
]


func _ready() -> void:
	_rebuild()
	var gm: Node = get_node_or_null("/root/GameManager")
	if gm != null and gm.has_signal("team_colors_ready"):
		gm.team_colors_ready.connect(setup)


# Called from GameManager.team_colors_ready once TeamColorRegistry resolves
# the live team colors (and again on any mid-game color change). Rebuild is
# the full path — cheap, and keeps the per-instance roll deterministic.
func setup(home_primary: Color, home_secondary: Color,
		away_primary: Color, away_secondary: Color) -> void:
	home_color = home_primary
	home_color_secondary = home_secondary
	away_color = away_primary
	away_color_secondary = away_secondary
	_rebuild()


func _request_rebuild() -> void:
	if is_inside_tree():
		_rebuild()


func _rebuild() -> void:
	if rink_length <= 0.0 or rink_width <= 0.0 or num_terraces <= 0:
		return
	for child: Node in get_children():
		child.queue_free()
	_build_terraces()
	_build_spectators()


# ── Terrace geometry ─────────────────────────────────────────────────────────

func _build_terraces() -> void:
	# Compute step counts ONCE based on the base path (no offset). All rings
	# share the same sample count so tread quads stay aligned between the
	# inner and outer perimeter of each terrace.
	var counts: Vector2i = _path_step_counts()
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PrimitiveType.PRIMITIVE_TRIANGLES)
	for i: int in num_terraces:
		var inner_off: float = base_outward_offset + i * tread_depth
		var outer_off: float = inner_off + tread_depth
		var y_top: float = stands_base_y + i * riser_height
		var y_bot: float = y_top - riser_height
		var inner_pts: PackedVector2Array = _sample_offset_path(inner_off, counts.x, counts.y)
		var outer_pts: PackedVector2Array = _sample_offset_path(outer_off, counts.x, counts.y)
		_emit_tread(st, inner_pts, outer_pts, y_top)
		_emit_riser(st, inner_pts, y_bot, y_top)
	st.generate_normals()
	var mesh: ArrayMesh = st.commit()
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = mesh
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = concrete_color
	mat.roughness = 0.95
	# Stands are only ever viewed from the rink side; double-siding keeps
	# the geometry visible if the user re-orients the scene during dev.
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	mi.name = "Terraces"
	add_child(mi)


# Tread: horizontal quad strip between inner and outer perimeter rings.
func _emit_tread(st: SurfaceTool, inner: PackedVector2Array, outer: PackedVector2Array, y: float) -> void:
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


# Riser: vertical wall along the inner perimeter, facing toward the rink.
func _emit_riser(st: SurfaceTool, inner: PackedVector2Array, y_bot: float, y_top: float) -> void:
	var n: int = inner.size()
	for i: int in n:
		var j: int = (i + 1) % n
		var ba: Vector3 = Vector3(inner[i].x, y_bot, inner[i].y)
		var ta: Vector3 = Vector3(inner[i].x, y_top, inner[i].y)
		var bb: Vector3 = Vector3(inner[j].x, y_bot, inner[j].y)
		var tb: Vector3 = Vector3(inner[j].x, y_top, inner[j].y)
		# Cull disabled on the material — winding here only affects normals,
		# which generate_normals() resolves consistently across the strip.
		st.add_vertex(ba)
		st.add_vertex(tb)
		st.add_vertex(bb)
		st.add_vertex(ba)
		st.add_vertex(ta)
		st.add_vertex(tb)


# Compute the (straight-X, straight-Z) sample counts, derived once from the
# base path so every ring shares the same vertex count regardless of offset.
func _path_step_counts() -> Vector2i:
	var arc_step_base: float = (PI / 2.0) * corner_radius / float(corner_segments)
	var straight_x: float = rink_width - 2.0 * corner_radius
	var straight_z: float = rink_length - 2.0 * corner_radius
	var nx: int = max(1, int(round(straight_x / arc_step_base)))
	var nz: int = max(1, int(round(straight_z / arc_step_base)))
	return Vector2i(nx, nz)


# Sample a rounded-rectangle path offset outward from the board outer face
# by `off` meters, using fixed step counts so rings stay vertex-aligned.
# Returns XZ points in CCW order (viewed from above with +X right, +Z up).
func _sample_offset_path(off: float, n_straight_x: int = -1, n_straight_z: int = -1) -> PackedVector2Array:
	var half_w: float = rink_width / 2.0
	var half_l: float = rink_length / 2.0
	var r: float = corner_radius
	var r_off: float = r + off
	# Corner arc centers (same as rink corner centers).
	var c_br: Vector2 = Vector2( half_w - r, -half_l + r)
	var c_tr: Vector2 = Vector2( half_w - r,  half_l - r)
	var c_tl: Vector2 = Vector2(-half_w + r,  half_l - r)
	var c_bl: Vector2 = Vector2(-half_w + r, -half_l + r)
	if n_straight_x < 0 or n_straight_z < 0:
		var counts: Vector2i = _path_step_counts()
		n_straight_x = counts.x
		n_straight_z = counts.y

	var pts: PackedVector2Array = PackedVector2Array()
	# Order, CCW from above: bottom edge → bottom-left corner → left edge →
	# top-left corner → top edge → top-right corner → right edge → bottom-right corner.
	_append_straight(pts,
			Vector2( half_w - r, -half_l - off),
			Vector2(-half_w + r, -half_l - off), n_straight_x)
	_append_arc(pts, c_bl, r_off, -PI / 2.0, -PI, corner_segments)
	_append_straight(pts,
			Vector2(-half_w - off, -half_l + r),
			Vector2(-half_w - off,  half_l - r), n_straight_z)
	_append_arc(pts, c_tl, r_off, PI, PI / 2.0, corner_segments)
	_append_straight(pts,
			Vector2(-half_w + r, half_l + off),
			Vector2( half_w - r, half_l + off), n_straight_x)
	_append_arc(pts, c_tr, r_off, PI / 2.0, 0.0, corner_segments)
	_append_straight(pts,
			Vector2(half_w + off,  half_l - r),
			Vector2(half_w + off, -half_l + r), n_straight_z)
	_append_arc(pts, c_br, r_off, 0.0, -PI / 2.0, corner_segments)
	return pts


# Append straight segment samples [start, ..., end) — endpoint omitted so
# the next segment's start point is not duplicated.
func _append_straight(pts: PackedVector2Array, start: Vector2, end: Vector2, steps: int) -> void:
	for i: int in steps:
		var t: float = float(i) / float(steps)
		pts.append(start.lerp(end, t))


# Append arc samples sweeping from a0 to a1 across `segments` steps.
# Endpoint omitted (matches _append_straight convention).
func _append_arc(pts: PackedVector2Array, center: Vector2, radius: float,
		a0: float, a1: float, segments: int) -> void:
	for i: int in segments:
		var t: float = float(i) / float(segments)
		var ang: float = lerp(a0, a1, t)
		pts.append(center + Vector2(cos(ang), sin(ang)) * radius)


# ── Spectator MultiMesh ──────────────────────────────────────────────────────

func _build_spectators() -> void:
	# Two MultiMesh instances share transforms: bodies tinted with the
	# team-mix color, heads tinted from the skin/hat palette. One extra
	# draw call vs. a combined mesh, but it lets the head pick a color
	# independent of the body without a custom shader.
	var body_mesh: ArrayMesh = _build_body_mesh()
	var head_mesh: ArrayMesh = _build_head_mesh()
	var body_mm: MultiMesh = MultiMesh.new()
	body_mm.transform_format = MultiMesh.TRANSFORM_3D
	body_mm.use_colors = true
	body_mm.mesh = body_mesh
	var head_mm: MultiMesh = MultiMesh.new()
	head_mm.transform_format = MultiMesh.TRANSFORM_3D
	head_mm.use_colors = true
	head_mm.mesh = head_mesh

	var transforms: Array[Transform3D] = []
	var body_colors: Array[Color] = []
	var head_colors: Array[Color] = []
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = _SEED
	for i: int in num_terraces:
		var inner_off: float = base_outward_offset + i * tread_depth
		# Spectators sit on the tread, inset slightly outward from the inner
		# (rink-facing) edge so their feet aren't on the riser corner.
		var spectator_off: float = inner_off + spectator_inset_from_riser
		var y: float = stands_base_y + i * riser_height
		var samples: PackedVector2Array = _sample_offset_path(spectator_off)
		var resampled: PackedVector2Array = _resample_uniform(samples, spectator_spacing)
		for p: Vector2 in resampled:
			var pos: Vector3 = Vector3(p.x, y + rng.randf_range(-spectator_y_jitter, spectator_y_jitter), p.y)
			# Face the rink: local forward (-Z) should point from p toward XZ
			# origin. With Basis(Y, yaw), forward_world = (-sin yaw, 0, -cos yaw);
			# solving for that to equal -p.normalized() yields yaw = atan2(p.x, p.z).
			var yaw: float = atan2(p.x, p.y) \
					+ deg_to_rad(rng.randf_range(-spectator_yaw_jitter_deg, spectator_yaw_jitter_deg))
			var spectator_basis: Basis = Basis(Vector3.UP, yaw)
			transforms.append(Transform3D(spectator_basis, pos))
			var picked: Array[Color] = _pick_spectator_colors(rng)
			body_colors.append(picked[0])
			head_colors.append(picked[1])

	var n: int = transforms.size()
	body_mm.instance_count = n
	head_mm.instance_count = n
	for i: int in n:
		body_mm.set_instance_transform(i, transforms[i])
		body_mm.set_instance_color(i, body_colors[i])
		head_mm.set_instance_transform(i, transforms[i])
		head_mm.set_instance_color(i, head_colors[i])

	# Godot's auto-AABB for MultiMesh is unreliable when transforms are pushed
	# via set_instance_transform individually (vs. a single `buffer` set), and
	# especially when the source mesh AABB is offset from origin (the head box
	# is centered at y~0.58). Without an explicit AABB the renderer culls
	# entire sections of crowd from certain camera angles.
	var bowl_aabb: AABB = _spectator_bowl_aabb()
	body_mm.custom_aabb = bowl_aabb
	head_mm.custom_aabb = bowl_aabb

	var body_mmi: MultiMeshInstance3D = MultiMeshInstance3D.new()
	body_mmi.multimesh = body_mm
	body_mmi.name = "SpectatorBodies"
	add_child(body_mmi)
	var head_mmi: MultiMeshInstance3D = MultiMeshInstance3D.new()
	head_mmi.multimesh = head_mm
	head_mmi.name = "SpectatorHeads"
	add_child(head_mmi)


# Conservative bounds around every spectator instance, in ArenaStands-local
# space. Rotated bodies can extend by the box diagonal in any horizontal dir;
# top of the head sits at body_h + head_h above the top tread.
func _spectator_bowl_aabb() -> AABB:
	var outer_extent: float = base_outward_offset \
			+ (num_terraces - 1) * tread_depth \
			+ spectator_inset_from_riser
	var horizontal_margin: float = max(_BODY_SIZE.x, _BODY_SIZE.z) * 0.71 + 0.05
	var half_x: float = rink_width * 0.5 + outer_extent + horizontal_margin
	var half_z: float = rink_length * 0.5 + outer_extent + horizontal_margin
	var top_y: float = stands_base_y + (num_terraces - 1) * riser_height \
			+ spectator_y_jitter + _BODY_SIZE.y + _HEAD_SIZE.y + 0.1
	var bot_y: float = stands_base_y - spectator_y_jitter - 0.1
	return AABB(
			Vector3(-half_x, bot_y, -half_z),
			Vector3(2.0 * half_x, top_y - bot_y, 2.0 * half_z))


# Body box, origin at the spectator's base. Lifted 2 mm off the tread so the
# bottom face doesn't z-fight — the bottom is visible from any camera below
# the spectator's row (common for back-row spectators in the upper bowl).
func _build_body_mesh() -> ArrayMesh:
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PrimitiveType.PRIMITIVE_TRIANGLES)
	_emit_box(st, Vector3(0.0, _BODY_Y_LIFT + _BODY_SIZE.y * 0.5, 0.0), _BODY_SIZE)
	st.generate_normals()
	st.set_material(_spectator_material())
	return st.commit()


# Head box, positioned above the body so it lines up when applied with the
# same transform as the body MultiMesh. Lifted with the body.
func _build_head_mesh() -> ArrayMesh:
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PrimitiveType.PRIMITIVE_TRIANGLES)
	var head_center_y: float = _BODY_Y_LIFT + _BODY_SIZE.y + _HEAD_SIZE.y * 0.5 + 0.02
	_emit_box(st, Vector3(0.0, head_center_y, 0.0), _HEAD_SIZE)
	st.generate_normals()
	st.set_material(_spectator_material())
	return st.commit()


# Shared material — vertex color (white) multiplied by the per-instance
# MultiMesh color produces the final albedo. Both bodies and heads use it.
# Cull disabled matches the terrace material: back-face culling on individual
# spectators was leaving rink-facing faces invisible at certain camera angles
# (the boxes looked hollow), and the extra triangles are cheap on a few
# thousand instances of an 8-vert mesh.
func _spectator_material() -> StandardMaterial3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color.WHITE
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.85
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


func _emit_box(st: SurfaceTool, center: Vector3, size: Vector3) -> void:
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
	_emit_quad(st, p[4], p[7], p[6], p[5])
	# -Y (bottom)
	_emit_quad(st, p[0], p[1], p[2], p[3])
	# +Z (front)
	_emit_quad(st, p[3], p[2], p[6], p[7])
	# -Z (back)
	_emit_quad(st, p[1], p[0], p[4], p[5])
	# +X (right)
	_emit_quad(st, p[2], p[1], p[5], p[6])
	# -X (left)
	_emit_quad(st, p[0], p[3], p[7], p[4])


func _emit_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	st.add_vertex(a)
	st.add_vertex(b)
	st.add_vertex(c)
	st.add_vertex(a)
	st.add_vertex(c)
	st.add_vertex(d)


# Walk the (already-CCW) sample polyline at uniform arc-length `spacing` and
# return the resampled points. Keeps spectator placement even regardless of
# the underlying corner_segments / straight-step density.
func _resample_uniform(samples: PackedVector2Array, spacing: float) -> PackedVector2Array:
	var out: PackedVector2Array = PackedVector2Array()
	if samples.size() < 2 or spacing <= 0.0:
		return out
	var cum: float = 0.0
	var next_t: float = spacing * 0.5  # half-step inset so the first/last don't crowd a seam
	var n: int = samples.size()
	for i: int in n:
		var a: Vector2 = samples[i]
		var b: Vector2 = samples[(i + 1) % n]
		var seg_len: float = a.distance_to(b)
		if seg_len <= 0.0:
			continue
		while next_t <= cum + seg_len:
			var t: float = (next_t - cum) / seg_len
			out.append(a.lerp(b, t))
			next_t += spacing
		cum += seg_len
	return out


# Roll a body + head color pair for one spectator. Returns [body, head].
# Body roll: home_fan_ratio of home colors, away_fan_ratio of away colors,
# rest neutral civilian shirts. Real arenas skew heavily toward home, with
# only a small visiting-supporters section, so neutrals fill the gap.
# Within each team slice, secondary_color_ratio swap to the secondary tint.
# Head roll: skin/hat palette by default, with a small team_cap_ratio chance
# of a team-colored hat for committed fans.
func _pick_spectator_colors(rng: RandomNumberGenerator) -> Array[Color]:
	var roll: float = rng.randf()
	var body: Color
	var team_loyalty: Color = Color(0, 0, 0, 0)  # alpha=0 sentinel = neutral
	if roll < home_fan_ratio:
		var base: Color = home_color_secondary if rng.randf() < secondary_color_ratio else home_color
		body = _shade(base, rng)
		team_loyalty = home_color
	elif roll < home_fan_ratio + away_fan_ratio:
		var base: Color = away_color_secondary if rng.randf() < secondary_color_ratio else away_color
		body = _shade(base, rng)
		team_loyalty = away_color
	else:
		body = _neutral_body_palette[rng.randi() % _neutral_body_palette.size()]
	var head: Color
	if team_loyalty.a > 0.0 and rng.randf() < team_cap_ratio:
		head = _shade(team_loyalty, rng)
	else:
		head = _head_palette[rng.randi() % _head_palette.size()]
	return [body, head]


func _shade(base: Color, rng: RandomNumberGenerator) -> Color:
	var s: float = rng.randf_range(-0.18, 0.18)
	return base.lightened(s) if s > 0.0 else base.darkened(-s)
