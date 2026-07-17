@tool
class_name ArenaStands
extends Node3D

# Procedural terraced stands wrapping the rink, plus a MultiMeshInstance3D
# spectator crowd. Pattern mirrors HockeyRink — single rebuild on @export
# change, no runtime updates. Geometry is four draw calls: one ArrayMesh for
# all terraces (lower bowl + concourse walkway + upper deck), one for the
# arena shell (upper-deck fascia + perimeter wall), and two MultiMeshes for
# the spectators (bodies, heads). The walkway / upper deck / shell exist so
# every camera sightline that clears the crowd lands on building rather than
# the bare background color — the bowl used to just end in the void.

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

@export_group("Upper Deck")
# Concourse walkway between the lower bowl's top row and the upper deck — a
# flat ring continuing the top tread's level outward. Also the shell wall's
# standoff from the bowl when the upper deck is disabled.
@export var walkway_depth: float = 2.2:
	set(v):
		walkway_depth = v
		_request_rebuild()
# Rows in the second tier. 0 disables the deck entirely (the shell wall then
# closes in right behind the walkway) — PlayerPrefs.apply_video drops it to 0
# on LOW crowd density, since the deck roughly doubles the spectator count.
@export var upper_terraces: int = 10:
	set(v):
		upper_terraces = v
		_request_rebuild()
# Steeper rake than the lower bowl (same tread depth, taller risers), the way
# a real second deck stacks over a concourse.
@export var upper_riser_height: float = 0.55:
	set(v):
		upper_riser_height = v
		_request_rebuild()
# Balcony rise from the walkway up to the deck's first tread; the dark fascia
# wall the lower bowl's back rows sit against spans exactly this height.
@export var upper_deck_rise: float = 1.1:
	set(v):
		upper_deck_rise = v
		_request_rebuild()

@export_group("Shell")
# Arena shell wall: rises this far above the top spectator row's tread, all
# the way around. 8 m puts the wall top at ~20.5 m with the default decks —
# high enough that the lobby backdrop's orbit camera and the replay chase cam
# keep their frame on building. Colored near the environment background so
# whatever sliver of void remains visible above it reads as dark rafters.
@export var shell_height: float = 8.0:
	set(v):
		shell_height = v
		_request_rebuild()
@export var shell_color: Color = Color(0.14, 0.15, 0.2):
	set(v):
		shell_color = v
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
# Editor escape hatch: also drops the static layout cache, so geometry *code*
# edits mid-session can't be masked by a stale cached bowl.
@export var rebuild: bool = false:
	set(_v):
		_layout_cache.clear()
		_request_rebuild()

# Deterministic seed so the editor preview matches the runtime build.
const _SEED: int = 31337
# Crowd animation (Shaders/crowd.gdshader): how long a burst of excitement
# holds at peak and how long it takes to settle back to the idle murmur sway.
const _CROWD_SHADER_PATH: String = "res://Shaders/crowd.gdshader"
const _EXCITE_RISE_TIME: float = 0.25
const _EXCITE_HOLD_TIME: float = 3.5
const _EXCITE_DECAY_TIME: float = 3.0
# Player benches: two team benches on the +X side straddling center ice,
# carved out of the first rows of crowd. 3v3 fields no reserves, so they're
# empty furniture — the break in the crowd wall is what sells the rink.
const _BENCH_CENTER_Z: float = 4.4    # bench centers at ±this along the boards
const _BENCH_HALF_LEN: float = 3.0    # half-length of each bench along Z
const _BENCH_CLEAR_ROWS: int = 2      # spectator rows cleared behind the glass
const _BENCH_CLEAR_MARGIN: float = 0.3
const _BENCH_SEAT_X_OFFSET: float = 0.33  # seat center outward of the first tread's inner edge
const _BENCH_SEAT_HEIGHT: float = 0.46
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


# Shared by both crowd MultiMeshes and — static — across arena instances:
# the cached body/head meshes embed this material, so it must be the same
# object for every ArenaStands the process ever builds, or excitement writes
# from a fresh arena would land on a dead material.
static var _crowd_material: ShaderMaterial = null
var _excitement: float = 0.0
var _excite_tween: Tween = null
# Set while set_crowd_rows writes both row counts, so the two setters don't
# each trigger a rebuild of their own.
var _suspend_rebuild: bool = false

# geometry key → layout dict {terrace_mesh, body_mm, head_mm, paint_key}.
# Everything in a layout is color-independent and deterministic (fixed
# _SEED), so it's built once per geometry-param set and reused for the
# process lifetime — a scene change's rebuild (free play → lobby → game)
# becomes at most a crowd repaint, and a same-colors rebuild skips even
# that. Bounded by clearing on editor param churn (steady state is one
# entry per crowd-density level).
static var _layout_cache: Dictionary = {}


func _ready() -> void:
	_rebuild()
	# The crowd material is static (see its doc): a bowl mid-celebration when
	# the scene changed would otherwise carry its excitement into the fresh
	# arena. New bowls start at the idle murmur.
	_set_excitement(0.0)
	var gm: Node = get_node_or_null("/root/GameManager")
	if gm == null:
		return
	if gm.has_signal("team_colors_ready"):
		gm.team_colors_ready.connect(setup)
	if gm.has_signal("goal_scored"):
		gm.goal_scored.connect(_on_goal_scored)
	if gm.has_signal("phase_changed"):
		gm.phase_changed.connect(_on_phase_changed)
	if gm.has_signal("body_check_broadcast"):
		gm.body_check_broadcast.connect(_on_body_check_broadcast)
	if gm.has_signal("pregame_intro_started"):
		gm.pregame_intro_started.connect(_on_pregame_intro_started)
	if gm.has_signal("period_intro_started"):
		# Same anticipation buzz as the opening intro when a new period's
		# skate-on begins.
		gm.period_intro_started.connect(
				func(_period: int, duration: float) -> void:
					_on_pregame_intro_started(duration))


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
	if _suspend_rebuild:
		return
	if is_inside_tree():
		_rebuild()


# One-shot crowd-density setter for PlayerPrefs.apply_video: both row counts
# land in a single rebuild instead of one per setter (which would also litter
# the layout cache with a never-again-used intermediate geometry).
func set_crowd_rows(lower: int, upper: int) -> void:
	if lower == num_terraces and upper == upper_terraces:
		return
	_suspend_rebuild = true
	num_terraces = lower
	upper_terraces = upper
	_suspend_rebuild = false
	_request_rebuild()


func _rebuild() -> void:
	if rink_length <= 0.0 or rink_width <= 0.0 or num_terraces <= 0:
		return
	for child: Node in get_children():
		child.queue_free()
	var layout: Dictionary = _get_or_build_layout()
	_add_terraces(layout.terrace_mesh)
	_add_shell(layout.shell_mesh)
	_add_spectators(layout)
	_build_benches()


# ── Layout cache ─────────────────────────────────────────────────────────────

# Every param that moves geometry, transforms, or the AABB. Colors and fan
# ratios are deliberately absent — they only repaint.
func _geometry_key() -> String:
	return str([rink_length, rink_width, corner_radius, stands_base_y,
			num_terraces, tread_depth, riser_height, base_outward_offset,
			corner_segments, spectator_spacing, spectator_inset_from_riser,
			spectator_yaw_jitter_deg, spectator_y_jitter,
			walkway_depth, upper_terraces, upper_riser_height, upper_deck_rise,
			shell_height])


# Everything the paint pass reads: the four team colors + the mix ratios.
func _paint_key() -> String:
	return str([home_color, home_color_secondary, away_color,
			away_color_secondary, home_fan_ratio, away_fan_ratio,
			secondary_color_ratio, team_cap_ratio])


func _get_or_build_layout() -> Dictionary:
	var key: String = _geometry_key()
	if _layout_cache.has(key):
		return _layout_cache[key]
	if _layout_cache.size() >= 4:
		_layout_cache.clear()
	var layout: Dictionary = {
		"terrace_mesh": _build_terrace_mesh(),
		"shell_mesh": _build_shell_mesh(),
		"paint_key": "",
	}
	_fill_spectator_layout(layout)
	_layout_cache[key] = layout
	return layout


# ── Terrace geometry ─────────────────────────────────────────────────────────

func _build_terrace_mesh() -> ArrayMesh:
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
	# Concourse walkway: the top tread's level continues outward as a flat ring
	# to the upper-deck fascia (or the shell wall when the deck is disabled).
	if walkway_depth > 0.0:
		var walk_in: float = base_outward_offset + num_terraces * tread_depth
		_emit_tread(st,
				_sample_offset_path(walk_in, counts.x, counts.y),
				_sample_offset_path(walk_in + walkway_depth, counts.x, counts.y),
				_lower_top_tread_y())
	# Upper deck. Row 0 emits no riser: the fascia (shell mesh) spans the whole
	# walkway → first-tread rise at the same ring, and a duplicate co-planar
	# wall would z-fight it.
	for j: int in upper_terraces:
		var inner_off: float = _upper_deck_inner_offset() + j * tread_depth
		var outer_off: float = inner_off + tread_depth
		var y_top: float = _upper_deck_base_y() + j * upper_riser_height
		var inner_pts: PackedVector2Array = _sample_offset_path(inner_off, counts.x, counts.y)
		var outer_pts: PackedVector2Array = _sample_offset_path(outer_off, counts.x, counts.y)
		_emit_tread(st, inner_pts, outer_pts, y_top)
		if j > 0:
			_emit_riser(st, inner_pts, y_top - upper_riser_height, y_top)
	st.generate_normals()
	return st.commit()


# ── Derived deck geometry ────────────────────────────────────────────────────

# Tread height of the lower bowl's back row — also the walkway level.
func _lower_top_tread_y() -> float:
	return stands_base_y + (num_terraces - 1) * riser_height


# Outward offset of the upper deck's first row (= the fascia ring).
func _upper_deck_inner_offset() -> float:
	return base_outward_offset + num_terraces * tread_depth + walkway_depth


# Tread height of the upper deck's first row (= the fascia top).
func _upper_deck_base_y() -> float:
	return _lower_top_tread_y() + upper_deck_rise


# Outward offset of the shell wall: behind the upper deck's back row, or
# straight behind the walkway when the deck is disabled.
func _shell_offset() -> float:
	return _upper_deck_inner_offset() + upper_terraces * tread_depth


# Tread height of the very back spectator row, whichever deck that is on.
func _top_tread_y() -> float:
	if upper_terraces > 0:
		return _upper_deck_base_y() + (upper_terraces - 1) * upper_riser_height
	return _lower_top_tread_y()


# Fascia (upper-deck balcony front) + perimeter shell wall, one mesh with the
# dark shell material. Split from the terrace mesh so the two can be colored
# independently without vertex colors or a second surface.
func _build_shell_mesh() -> ArrayMesh:
	var counts: Vector2i = _path_step_counts()
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PrimitiveType.PRIMITIVE_TRIANGLES)
	if upper_terraces > 0:
		var fascia_pts: PackedVector2Array = _sample_offset_path(
				_upper_deck_inner_offset(), counts.x, counts.y)
		_emit_riser(st, fascia_pts, _lower_top_tread_y(), _upper_deck_base_y())
	if shell_height > 0.0:
		var wall_pts: PackedVector2Array = _sample_offset_path(
				_shell_offset(), counts.x, counts.y)
		_emit_riser(st, wall_pts, _top_tread_y(), _top_tread_y() + shell_height)
	st.generate_normals()
	return st.commit()


# Shell color lives on a per-instance material_override (same pattern as the
# terraces' concrete) so a color tweak repaints without a layout rebuild.
func _add_shell(mesh: ArrayMesh) -> void:
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = mesh
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = shell_color
	mat.roughness = 1.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	# The wall is beyond every shadow-casting spotlight's range; skip it in the
	# shadow maps like the crowd.
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.name = "Shell"
	add_child(mi)


# Concrete color lives on a per-instance material_override, not in the cached
# mesh, so a concrete_color tweak repaints without invalidating the layout.
func _add_terraces(mesh: ArrayMesh) -> void:
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

# Build the color-independent half of the crowd into `layout`: the two
# MultiMeshes with meshes, transforms, anim data, and AABB. Two MultiMesh
# instances share transforms: bodies tinted with the team-mix color, heads
# tinted from the skin/hat palette. One extra draw call vs. a combined mesh,
# but it lets the head pick a color independent of the body without a custom
# shader. Colors stay default until the first _paint_spectators pass (a fresh
# layout's paint_key is "").
func _fill_spectator_layout(layout: Dictionary) -> void:
	var body_mm: MultiMesh = MultiMesh.new()
	body_mm.transform_format = MultiMesh.TRANSFORM_3D
	body_mm.use_colors = true
	body_mm.use_custom_data = true
	body_mm.mesh = _build_body_mesh()
	var head_mm: MultiMesh = MultiMesh.new()
	head_mm.transform_format = MultiMesh.TRANSFORM_3D
	head_mm.use_colors = true
	head_mm.use_custom_data = true
	head_mm.mesh = _build_head_mesh()

	var transforms: Array[Transform3D] = []
	var anim_data: Array[Color] = []
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = _SEED
	for i: int in num_terraces:
		# Spectators sit on the tread, inset slightly outward from the inner
		# (rink-facing) edge so their feet aren't on the riser corner.
		_append_spectator_row(transforms, anim_data, rng,
				base_outward_offset + i * tread_depth + spectator_inset_from_riser,
				stands_base_y + i * riser_height, i)
	# Upper deck rows. bench_row -1: the bench cutout is an ice-level concern
	# only — the deck hangs far above the benches.
	for j: int in upper_terraces:
		_append_spectator_row(transforms, anim_data, rng,
				_upper_deck_inner_offset() + j * tread_depth + spectator_inset_from_riser,
				_upper_deck_base_y() + j * upper_riser_height, -1)

	var n: int = transforms.size()
	body_mm.instance_count = n
	head_mm.instance_count = n
	for i: int in n:
		body_mm.set_instance_transform(i, transforms[i])
		body_mm.set_instance_custom_data(i, anim_data[i])
		head_mm.set_instance_transform(i, transforms[i])
		head_mm.set_instance_custom_data(i, anim_data[i])

	# Godot's auto-AABB for MultiMesh is unreliable when transforms are pushed
	# via set_instance_transform individually (vs. a single `buffer` set), and
	# especially when the source mesh AABB is offset from origin (the head box
	# is centered at y~0.58). Without an explicit AABB the renderer culls
	# entire sections of crowd from certain camera angles.
	var bowl_aabb: AABB = _spectator_bowl_aabb()
	body_mm.custom_aabb = bowl_aabb
	head_mm.custom_aabb = bowl_aabb
	layout["body_mm"] = body_mm
	layout["head_mm"] = head_mm


# One ring of spectators at `spectator_off` outward of the boards, feet at
# `y`. bench_row is the lower-bowl row index for the bench cutout, or -1 for
# rows the cutout can never apply to (the upper deck).
func _append_spectator_row(transforms: Array[Transform3D], anim_data: Array[Color],
		rng: RandomNumberGenerator, spectator_off: float, y: float, bench_row: int) -> void:
	var samples: PackedVector2Array = _sample_offset_path(spectator_off)
	var resampled: PackedVector2Array = _resample_uniform(samples, spectator_spacing)
	for p: Vector2 in resampled:
		if bench_row >= 0 and _in_bench_zone(bench_row, p):
			continue
		var pos: Vector3 = Vector3(p.x, y + rng.randf_range(-spectator_y_jitter, spectator_y_jitter), p.y)
		# Face the rink: local forward (-Z) should point from p toward XZ
		# origin. With Basis(Y, yaw), forward_world = (-sin yaw, 0, -cos yaw);
		# solving for that to equal -p.normalized() yields yaw = atan2(p.x, p.z).
		var yaw: float = atan2(p.x, p.y) \
				+ deg_to_rad(rng.randf_range(-spectator_yaw_jitter_deg, spectator_yaw_jitter_deg))
		var spectator_basis: Basis = Basis(Vector3.UP, yaw)
		transforms.append(Transform3D(spectator_basis, pos))
		# Animation roll (crowd.gdshader INSTANCE_CUSTOM): phase de-sync,
		# sway amplitude, hop amplitude. Same data on body and head so the
		# two draw calls move as one person.
		anim_data.append(Color(
				rng.randf(),
				rng.randf_range(0.6, 1.4),
				rng.randf_range(0.2, 1.0),
				0.0))


# Attach the cached MultiMeshes and repaint only if the colors/ratios moved
# since the layout was last painted. A rebuild with unchanged colors (e.g.
# re-entering a scene) reattaches without touching a single instance.
func _add_spectators(layout: Dictionary) -> void:
	var paint_key: String = _paint_key()
	if layout.paint_key != paint_key:
		_paint_spectators(layout.body_mm, layout.head_mm)
		layout.paint_key = paint_key

	var body_mmi: MultiMeshInstance3D = MultiMeshInstance3D.new()
	body_mmi.multimesh = layout.body_mm
	body_mmi.name = "SpectatorBodies"
	# The crowd casts no shadows. Thousands of instances × the 8 shadow-casting
	# ceiling spotlights (RinkArena.tscn) is the arena's biggest shadow-map cost,
	# and crowd-on-crowd shadows up in the stands are never visible from the
	# rink-focused camera — a shimmer at best, given the sway/hop animation.
	# (The goalie disables shadow casting on its own parts the same way.)
	body_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(body_mmi)
	var head_mmi: MultiMeshInstance3D = MultiMeshInstance3D.new()
	head_mmi.multimesh = layout.head_mm
	head_mmi.name = "SpectatorHeads"
	head_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(head_mmi)


# Roll body/head colors for every spectator. Own rng stream (same _SEED) so
# the fan-mix assignment is deterministic and identical across repaints of
# the same layout.
func _paint_spectators(body_mm: MultiMesh, head_mm: MultiMesh) -> void:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = _SEED
	for i: int in body_mm.instance_count:
		var picked: Array[Color] = _pick_spectator_colors(rng)
		body_mm.set_instance_color(i, picked[0])
		head_mm.set_instance_color(i, picked[1])


# Conservative bounds around every spectator instance, in ArenaStands-local
# space. Rotated bodies can extend by the box diagonal in any horizontal dir;
# top of the head sits at body_h + head_h above the top tread.
func _spectator_bowl_aabb() -> AABB:
	var outer_extent: float = base_outward_offset \
			+ (num_terraces - 1) * tread_depth \
			+ spectator_inset_from_riser
	if upper_terraces > 0:
		outer_extent = _upper_deck_inner_offset() \
				+ (upper_terraces - 1) * tread_depth \
				+ spectator_inset_from_riser
	# Margins cover the shader animation (crowd.gdshader): up to ~0.18 m of
	# celebration hop on top, ~0.1 m of sway sideways.
	var horizontal_margin: float = max(_BODY_SIZE.x, _BODY_SIZE.z) * 0.71 + 0.15
	var half_x: float = rink_width * 0.5 + outer_extent + horizontal_margin
	var half_z: float = rink_length * 0.5 + outer_extent + horizontal_margin
	var top_y: float = _top_tread_y() \
			+ spectator_y_jitter + _BODY_SIZE.y + _HEAD_SIZE.y + 0.35
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


# Shared material — crowd.gdshader reads the per-instance MultiMesh color
# for albedo (matching the old vertex_color_use_as_albedo look) and animates
# sway/hop from INSTANCE_CUSTOM + the excitement uniform. One material across
# both MultiMeshes and across rebuilds, so excitement state persists and a
# single uniform write drives the whole bowl. Cull disabled matches the
# terrace material: back-face culling on individual spectators was leaving
# rink-facing faces invisible at certain camera angles (the boxes looked
# hollow), and the extra triangles are cheap on a few thousand instances of
# an 8-vert mesh.
func _spectator_material() -> ShaderMaterial:
	if _crowd_material == null:
		_crowd_material = ShaderMaterial.new()
		_crowd_material.shader = load(_CROWD_SHADER_PATH)
		_crowd_material.set_shader_parameter("excitement", _excitement)
	return _crowd_material


# True when a spectator slot falls inside the player-bench cutout: the first
# _BENCH_CLEAR_ROWS rows on the bench (+X) side, along the full stretch from
# one bench's far end to the other's — including the gap BETWEEN the bench
# spans, which is the gate/staff area; fans seated at ice level in that
# sliver read as people sitting between the two benches.
# Sample points are (x, z) packed as Vector2(x, y).
func _in_bench_zone(row: int, p: Vector2) -> bool:
	if row >= _BENCH_CLEAR_ROWS:
		return false
	if p.x < 0.0:
		return false
	return absf(p.y) < _BENCH_CENTER_Z + _BENCH_HALF_LEN + _BENCH_CLEAR_MARGIN


# ── Player benches ───────────────────────────────────────────────────────────

# One solid team-colored bench block + a charcoal backrest per team, sitting
# on the first-row tread where the crowd was cleared. Rebuilt with the bowl,
# so bench colors re-tint when team_colors_ready re-runs setup().
func _build_benches() -> void:
	var x_inner: float = rink_width / 2.0 + base_outward_offset
	var tread_y: float = stands_base_y
	for side: float in [-1.0, 1.0]:
		var center_z: float = side * _BENCH_CENTER_Z
		# Home (team 0) defends +Z, so its bench sits on the +Z half.
		var team_color: Color = home_color if side > 0.0 else away_color

		var seat := MeshInstance3D.new()
		seat.name = "BenchSeatHome" if side > 0.0 else "BenchSeatAway"
		var seat_mesh := BoxMesh.new()
		seat_mesh.size = Vector3(0.42, _BENCH_SEAT_HEIGHT, _BENCH_HALF_LEN * 2.0)
		var seat_mat := StandardMaterial3D.new()
		seat_mat.albedo_color = team_color.darkened(0.25)
		seat_mat.roughness = 0.8
		seat_mesh.material = seat_mat
		seat.mesh = seat_mesh
		seat.position = Vector3(x_inner + _BENCH_SEAT_X_OFFSET,
				tread_y + _BENCH_SEAT_HEIGHT * 0.5, center_z)
		add_child(seat)

		var backrest := MeshInstance3D.new()
		backrest.name = "BenchBackHome" if side > 0.0 else "BenchBackAway"
		var back_mesh := BoxMesh.new()
		back_mesh.size = Vector3(0.06, 0.5, _BENCH_HALF_LEN * 2.0)
		var back_mat := StandardMaterial3D.new()
		back_mat.albedo_color = Color(0.20, 0.20, 0.22)
		back_mat.roughness = 0.9
		back_mesh.material = back_mat
		backrest.mesh = back_mesh
		backrest.position = Vector3(x_inner + 0.57, tread_y + 0.55, center_z)
		add_child(backrest)


# Seat-surface center of a team's bench (top face of the seat block), in
# ArenaStands-local space. Home (team 0) sits on the +Z half, matching
# _build_benches. The lobby backdrop uses this to seat roster dummies.
func bench_seat_center(team_id: int) -> Vector3:
	var side: float = 1.0 if team_id == 0 else -1.0
	return Vector3(rink_width / 2.0 + base_outward_offset + _BENCH_SEAT_X_OFFSET,
			stands_base_y + _BENCH_SEAT_HEIGHT, side * _BENCH_CENTER_Z)


# ── Crowd excitement ─────────────────────────────────────────────────────────

# Ramp the bowl to at least `level` (0..1), hold, then settle back to the idle
# sway. A stronger burst always wins over a fading weaker one.
func excite(level: float) -> void:
	var target: float = clampf(maxf(level, _excitement), 0.0, 1.0)
	if target <= 0.0:
		return
	if _excite_tween != null and _excite_tween.is_valid():
		_excite_tween.kill()
	_excite_tween = create_tween()
	_excite_tween.tween_method(_set_excitement, _excitement, target, _EXCITE_RISE_TIME)
	_excite_tween.tween_interval(_EXCITE_HOLD_TIME * target)
	_excite_tween.tween_method(_set_excitement, target, 0.0, _EXCITE_DECAY_TIME)


func _set_excitement(v: float) -> void:
	_excitement = v
	_spectator_material().set_shader_parameter("excitement", v)


func _on_goal_scored(_team: Variant, _scorer: String, _a1: String, _a2: String) -> void:
	excite(1.0)


func _on_phase_changed(new_phase: int) -> void:
	if new_phase == GamePhase.Phase.END_OF_PERIOD or new_phase == GamePhase.Phase.GAME_OVER:
		excite(0.7)


# Big hits get a rumble out of the crowd, scaled by the same intensity curve
# the impact burst/sound use. Soft contact barely registers.
func _on_body_check_broadcast(force: float) -> void:
	excite(SkaterVFX.check_intensity(force) * 0.45)


# Pre-game buzz: the bowl comes alive under the opening camera sweep.
func _on_pregame_intro_started(_duration: float) -> void:
	excite(0.55)


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
