class_name ArenaSignage
extends RefCounted

# The two lit surfaces in the building that nobody sits on: the LED ribbon board
# on the upper deck's fascia and the championship banners in the rafters.
#
# One file because they are the same machine twice — a SubViewport painted once,
# its texture on an unshaded band built by BoardAdBandBuilder around one of the
# bowl's own rings — and because both hold a render target that has to be
# released before the RenderingServer finalizes. Keeping the two viewports and
# `release_render_targets` together is what makes that contract one thing to get
# right instead of two.

# ── Ribbon board ─────────────────────────────────────────────────────────────
# The LED strip on the upper deck's fascia — the wall the lower bowl's back rows
# sit against, which is where a real arena puts one and which is otherwise a
# blank band of concrete right in the eyeline of every high camera. Its height
# and its clearance under the deck's lip live on ArenaBowlRake, because the
# concrete has to be poured around them.
#
# Stood this far proud of the fascia so the two faces are never coplanar.
const _RIBBON_INSET: float = 0.02
# Whole number of repeats around the bowl, and it must stay whole: the strip
# wraps in U, so a fractional count would put a hard seam where the band closes.
const _RIBBON_REPEATS: int = 3

# ── Rafter banners ───────────────────────────────────────────────────────────
# Hung inboard of the shell wall so they read as suspended over the bowl rather
# than as signs bolted to it, and high enough that the top deck's back row is
# well below them.
const _BANNER_INBOARD: float = 2.0
# Where the banners' top edge sits in the shell's height, as a fraction. Leaves
# the roof space above them dark, which is the whole reason they read as hanging
# from something rather than floating.
const _BANNER_TOP_FRACTION: float = 0.86
# Gap between a banner's two printed faces. Cloth is thinner than this; the
# number is set by depth precision at 30 m, not by upholstery.
const _BANNER_THICKNESS: float = 0.02
# How many times the registry goes round the ring. There are only a handful of
# banners and the ring is ~250 m, so hanging one of each would leave 60 m of
# empty roof between them and most cameras seeing none. Repeating puts a banner
# in view from anywhere without the roof becoming a wall of duplicates.
const _BANNER_RING_REPEATS: int = 2

var _spec: ArenaBowlSpec
var _path: ArenaBowlPath
var _rake: ArenaBowlRake

# Kept so teardown can drop the texture bindings before the RenderingServer
# finalizes, plus the world span of one ribbon repeat, which converts the scroll
# from m/s to UV/s.
var _ribbon_vp: SubViewport = null
var _ribbon_material: StandardMaterial3D = null
var _ribbon_span_m: float = 0.0
var _banner_vp: SubViewport = null
var _banner_material: StandardMaterial3D = null


func _init(spec: ArenaBowlSpec, path: ArenaBowlPath, rake: ArenaBowlRake) -> void:
	_spec = spec
	_path = path
	_rake = rake


# Advance the ribbon's scroll by `delta` at `speed` metres of board per second.
# Returns false when there is nothing to scroll, so the owner can stop calling.
func scroll_ribbon(delta: float, speed: float) -> bool:
	if _ribbon_material == null or _ribbon_span_m <= 0.0:
		return false
	var offset: Vector3 = _ribbon_material.uv1_offset
	offset.x = fposmod(offset.x + delta * speed / _ribbon_span_m, 1.0)
	_ribbon_material.uv1_offset = offset
	return true


# Release both render targets and their material bindings before Godot finalizes
# the RenderingServer on quit — same contract, and same reasoning, as
# HockeyRink._teardown_render_targets and Jumbotron._teardown_viewport: a
# ViewportTexture still bound at exit takes its viewport and that viewport's
# canvas and text-shaping RIDs down after the server, which reports them leaked.
func release_render_targets() -> void:
	if _ribbon_material != null:
		_ribbon_material.albedo_texture = null
	_ribbon_material = null
	if is_instance_valid(_ribbon_vp):
		_ribbon_vp.free()
	_ribbon_vp = null
	if _banner_material != null:
		_banner_material.albedo_texture = null
	_banner_material = null
	if is_instance_valid(_banner_vp):
		_banner_vp.free()
	_banner_vp = null


# ── Ribbon board ─────────────────────────────────────────────────────────────

# One continuous band around the fascia, sampled with U repeating
# _RIBBON_REPEATS times, so the whole board is a single mesh and a single
# material — and the scroll is one UV write per frame rather than anything
# rebuilt.
func add_ribbon_board(root: Node3D) -> void:
	if _rake.upper_row_count() <= 0:
		return   # no upper deck means no fascia to mount it on
	var stations: Array = _path.stations(_rake.upper_deck_inner_offset())
	var cumulative: PackedFloat32Array = BoardAdBandBuilder.cumulative_arcs(stations)
	var perimeter: float = BoardAdBandBuilder.perimeter_of(cumulative)
	var centre_y: float = _rake.upper_deck_base_y() \
			- ArenaBowlRake.RIBBON_FASCIA_MARGIN - ArenaBowlRake.RIBBON_HEIGHT * 0.5
	var half_h: float = ArenaBowlRake.RIBBON_HEIGHT * 0.5
	var band: ArrayMesh = BoardAdBandBuilder.build_band(stations, cumulative,
			[Vector2(0.0, perimeter)] as Array[Vector2],
			[Rect2(0.0, 0.0, float(_RIBBON_REPEATS), 1.0)] as Array[Rect2],
			_RIBBON_INSET, centre_y - half_h, centre_y + half_h)
	if band == null:
		return

	var strip_vp := _make_viewport(root, "RibbonStripViewport",
			RibbonPainter.strip_size(AdBrands.BRANDS.size()), false)
	_ribbon_vp = strip_vp
	var painter := RibbonPainter.new()
	painter.brands = AdBrands.BRANDS
	strip_vp.add_child(painter)

	var mi := MeshInstance3D.new()
	mi.name = "RibbonBoard"
	mi.mesh = band
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = strip_vp.get_texture()
	# Unshaded so the board is its own light source rather than something the
	# ceiling rig has to reach, which at this height and angle it does not.
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# Double-sided like every other band in the project: BoardAdBandBuilder's
	# winding does not survive Godot's culling the way the world-space geometry
	# suggests it should (see HockeyRink._rebuild), so nothing built by it relies
	# on which face the renderer thinks is front.
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mi)

	_ribbon_material = mat
	# One repeat spans this much wall, which converts the scroll speed from
	# metres per second into UV per second.
	_ribbon_span_m = perimeter / float(_RIBBON_REPEATS)


# ── Rafter banners ───────────────────────────────────────────────────────────

# Banners are spaced evenly around a ring inboard of the shell and built as one
# band, exactly like the boards' ad panels — a 2.6 m banner on a ring this wide
# is very nearly flat, so following the arc costs nothing and saves writing a
# second quad builder.
func add_rafter_banners(root: Node3D) -> void:
	if _spec.shell_height <= 0.0 or BannerRegistry.BANNERS.is_empty():
		return
	var stations: Array = _path.stations(_rake.shell_offset() - _BANNER_INBOARD)
	var cumulative: PackedFloat32Array = BoardAdBandBuilder.cumulative_arcs(stations)
	var perimeter: float = BoardAdBandBuilder.perimeter_of(cumulative)
	# Distinct banners (one atlas cell each) versus how many hang: the registry
	# goes round the ring more than once, so a name appears on opposite sides.
	var unique: int = BannerRegistry.BANNERS.size()
	var hung: int = unique * _BANNER_RING_REPEATS
	var width: float = _spec.banner_height \
			* float(BannerPainter.CELL_PX.x) / float(BannerPainter.CELL_PX.y)
	if width <= 0.0 or width * hung >= perimeter:
		return

	var placements: Array[Vector2] = []
	var uv_rects: Array[Rect2] = []
	for i: int in hung:
		# Evenly spaced around the ring, each centred on its share of it.
		var centre: float = perimeter * (float(i) + 0.5) / float(hung)
		placements.append(Vector2(centre - width * 0.5, width))
		uv_rects.append(BannerPainter.cell_uv(i % unique, unique))

	var top_y: float = _rake.top_tread_y() + _spec.shell_height * _BANNER_TOP_FRACTION
	var band: ArrayMesh = BoardAdBandBuilder.build_band(stations, cumulative,
			placements, uv_rects, 0.0, top_y - _spec.banner_height, top_y)
	if band == null:
		return
	# Cloth has two sides and a real banner is printed on both. A single
	# double-sided quad would show the reverse mirrored, so the back is its own
	# surface hung _BANNER_THICKNESS behind the front with its U reversed —
	# which reads right from outside the ring and keeps the two off each other's
	# depth.
	var back_rects: Array[Rect2] = []
	for cell: Rect2 in uv_rects:
		back_rects.append(Rect2(cell.position.x + cell.size.x, cell.position.y,
				-cell.size.x, cell.size.y))
	var back_band: ArrayMesh = BoardAdBandBuilder.build_band(stations, cumulative,
			placements, back_rects, -_BANNER_THICKNESS,
			top_y - _spec.banner_height, top_y)

	var atlas_vp := _make_viewport(root, "BannerAtlasViewport",
			BannerPainter.atlas_size(unique), true)
	_banner_vp = atlas_vp
	var painter := BannerPainter.new()
	painter.banners = BannerRegistry.BANNERS
	atlas_vp.add_child(painter)

	var mat := StandardMaterial3D.new()
	mat.albedo_texture = atlas_vp.get_texture()
	# Unshaded: nothing lights the roof space, so a lit banner is a black
	# rectangle. Double-sided per surface, like the ribbon board's band — the two
	# surfaces, not the culling, make the two sides.
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_banner_material = mat

	for face: Array in [["RafterBanners", band], ["RafterBannersBack", back_band]]:
		if face[1] == null:
			continue
		var mi := MeshInstance3D.new()
		mi.name = face[0]
		mi.mesh = face[1]
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(mi)


# A paint-once offscreen canvas. UPDATE_ONCE because the artwork never changes
# after the painter's first draw; 3D and input are off because it is a texture
# factory, not a viewport anyone looks through.
func _make_viewport(root: Node3D, node_name: String, size: Vector2i,
		transparent: bool) -> SubViewport:
	var vp := SubViewport.new()
	vp.name = node_name
	vp.size = size
	vp.transparent_bg = transparent
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	vp.disable_3d = true
	vp.handle_input_locally = false
	vp.gui_disable_input = true
	root.add_child(vp)
	return vp
