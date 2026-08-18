@tool
class_name HockeyRink
extends Node3D

@export var rink_length: float = 60.0:
	set(v):
		rink_length = v
		_rebuild()
@export var rink_width: float = 26.0:
	set(v):
		rink_width = v
		_rebuild()
@export var corner_radius: float = 8.53:
	set(v):
		corner_radius = v
		_rebuild()
# Default single-sourced from GameRules.BOARD_TOP_HEIGHT (the HUD's
# puck-behind-boards check reads that constant); don't override in the scene.
@export var wall_height: float = GameRules.BOARD_TOP_HEIGHT:
	set(v):
		wall_height = v
		_rebuild()
@export var wall_thickness: float = 0.3:
	set(v):
		wall_thickness = v
		_rebuild()
@export var corner_segments: int = 48:
	set(v):
		corner_segments = v
		_rebuild()
@export var wall_color: Color = Color(0.95, 0.95, 0.95):
	set(v):
		wall_color = v
		_rebuild()
# Boards are near-vertical, so the top-down ceiling rig grazes past them and
# they read dark whatever its brightness. A touch of self-emission (each band
# emits its own color — white wall, gold kickplate, navy cap rail) gives the
# boards a color floor so they show their intended look from top-down, without
# spilling any light onto the ice or crowd. Kept well under the glow HDR
# threshold so they don't bloom.
@export_range(0.0, 2.0) var wall_emission_energy: float = 0.15:
	set(v):
		wall_emission_energy = v
		_rebuild()
@export var kickplate_color: Color = Color(1.0, 0.824, 0.357):
	set(v):
		kickplate_color = v
		_rebuild()
@export_range(0.0, 2.0) var kickplate_emission_energy: float = 0.5:
	set(v):
		kickplate_emission_energy = v
		_rebuild()
@export var cap_rail_color: Color = Color(0.0, 0.220, 0.659):
	set(v):
		cap_rail_color = v
		_rebuild()
@export_range(0.0, 2.0) var cap_rail_emission_energy: float = 0.5:
	set(v):
		cap_rail_emission_energy = v
		_rebuild()
@export var board_stripe_z_nudge: float = 0.0:
	set(v):
		board_stripe_z_nudge = v
		_rebuild()
@export var kickplate_height: float = 0.20:
	set(v):
		kickplate_height = v
		_rebuild()
@export var glass_height: float = 1.83:
	set(v):
		glass_height = v
		_rebuild()
@export var glass_thickness: float = 0.05:
	set(v):
		glass_thickness = v
		_rebuild()
@export var glass_color: Color = Color(0.85, 0.93, 1.0, 0.12):
	set(v):
		glass_color = v
		_rebuild()
@export var ice_color: Color = Color(0.84, 0.91, 1.0):
	set(v):
		ice_color = v
		_rebuild()
@export var red_line_color: Color = Color(0.784, 0.063, 0.180):
	set(v):
		red_line_color = v
		_rebuild()
@export var blue_line_color: Color = Color(0.0, 0.220, 0.659):
	set(v):
		blue_line_color = v
		_rebuild()
@export_group("Ice Shader")
@export var ice_fog_color: Color = Color(0.84, 0.91, 1.0):
	set(v):
		ice_fog_color = v
		_rebuild()
@export_range(0.0, 3.0) var ice_subsurface_fade: float = 0.2:
	set(v):
		ice_subsurface_fade = v
		_rebuild()
@export_range(0.0, 0.05) var ice_subsurface_depth: float = 0.012:
	set(v):
		ice_subsurface_depth = v
		_rebuild()
@export_range(0.0, 1.0) var ice_specular: float = 0.6:
	set(v):
		ice_specular = v
		_rebuild()
# Head-on roughness governs how sharp screen-space reflections read when you
# look down at the ice (grazing stays the mirror streak). Nudged 0.20 → 0.15
# so skater/goal reflections hold together once SSR is enabled in the
# WorldEnvironment (see docs/arena-atmosphere-spec.md); still short of a full
# mirror, so the ice keeps its slightly-diffuse-head-on read.
@export_range(0.0, 1.0) var ice_roughness_head_on: float = 0.15:
	set(v):
		ice_roughness_head_on = v
		_rebuild()
@export_range(0.0, 1.0) var ice_roughness_grazing: float = 0.04:
	set(v):
		ice_roughness_grazing = v
		_rebuild()
@export_group("Sponsors")
@export var board_ads_enabled: bool = true:
	set(v):
		board_ads_enabled = v
		_rebuild()
@export var ice_ads_enabled: bool = true:
	set(v):
		ice_ads_enabled = v
		_rebuild()
@export_group("")
# Editor escape hatch: also drops the static build cache, so geometry *code*
# edits mid-session can't be masked by stale cached products.
@export var rebuild: bool = false:
	set(_v):
		_build_cache.clear()
		_rebuild()

# Board stack, bottom to top:
#   kickplate (yellow lip)  → white board → cap rail (blue lip) → glass
# Kickplate and cap rail are bands that wrap the board with a small lip on
# both the inside (puck-facing) and outside (stands-facing) — they're wider
# in the radial / wall-thickness axis than the board itself. The cap rail is
# the visible band at the top of the board where it meets the glass.
const KICKPLATE_PROTRUSION: float = 0.01
const CAP_RAIL_PROTRUSION: float = 0.01
const CAP_RAIL_HEIGHT: float = 0.05
# Lift the glass 1 mm above the cap rail so the glass's bottom face isn't
# coplanar with the cap rail's top face. Glass material uses cull_disabled
# (renders both sides), and coplanar opaque-vs-double-sided-transparent
# z-fights along the seam.
const GLASS_LIFT: float = 0.001
# Recess the kickplate's bottom this far below the ice plane. The merged
# perimeter band uses cull_disabled (renders both sides of every face), so
# the bottom cap would z-fight the ice plane at y=0 if they were coplanar.
# The ice plane occludes the recess from above so the visible kickplate
# still appears to sit on the ice; the recessed bottom cap still covers
# the small annular strip where the kickplate's outward lip protrudes past
# the ice rectangle (otherwise you'd see through to the dark background).
const KICKPLATE_ICE_OFFSET: float = 0.005
# NHL spec for reference (so future tuning has a target):
#   Board height (kickplate + white + cap): 1.07-1.22 m (42-48 in)
#   Glass height above boards:              1.52-2.44 m (5-8 ft)
#   Kickplate height:                       0.15-0.30 m (6-12 in)
#   Cap rail height:                        0.05-0.08 m (2-3 in)

# ── Sponsor panels ───────────────────────────────────────────────────────────
# The ad ribbon stands 1.5 mm inside the boards' face — half a millimetre in
# front of the painted stripes at 1 mm. They never share board (the layout
# reserves the paint), but the offset means a mis-sized reservation would show as
# an ad over a stripe rather than as a z-fight.
const AD_BAND_INSET: float = 0.0015
# White board left showing above and below each panel, so the ads read as mounted
# in the recessed channel between the kickplate and cap-rail lips rather than as
# a repaint of the whole wall.
const AD_BAND_MARGIN: float = 0.04
const AD_PANEL_GAP: float = 0.30
const AD_RUN_MARGIN: float = 0.35
# Bare board kept around each painted stripe. The side stripes are 0.3 m wide and
# the corner goal-line stripes 0.15 m, so these are half-widths plus clearance.
const AD_STRIPE_CLEARANCE: float = 0.25
const AD_SIDE_STRIPE_HALF: float = 0.15
const AD_GOAL_STRIPE_HALF: float = 0.075
# How finely the perimeter is walked when working out which stretches of board
# are already spoken for. 10 cm is far below the narrowest thing being avoided.
const AD_RESERVE_STEP: float = 0.1

# ── Gates ────────────────────────────────────────────────────────────────────
# Doors cut into the boards: one at the inner end of each player bench, one at
# the outer end of each penalty box, and one per end board for the resurfacer
# crew — which until now drove in through a solid wall.
#
# Drawn as an outline with a transparent interior, so the door is the board's
# own white with a frame around it rather than a differently-coloured patch that
# has to match the wall. Sits 1.2 mm proud: between the painted stripes at 1 mm
# and the ad panels at 1.5 mm, so no two of the three can ever land coplanar.
const GATE_INSET: float = 0.0012
const GATE_WIDTH: float = 1.2
const GATE_CLEARANCE: float = 0.2   # bare board an ad keeps off a gate
# Where the resurfacers appear from. IceResurfacer runs its two machines on
# point-mirrored lanes at x ≈ ±1.6–3.8, so a door at ±3.4 on each end board sits
# where each one enters instead of somewhere arbitrary along the wall.
const GATE_RESURFACER_X: float = 3.4

# ── End-zone netting ─────────────────────────────────────────────────────────
# The mesh that hangs above the end glass to catch pucks leaving the rink.
# Continues the glass plane upward and wraps both corners, reaching this far
# down the side boards — past the corner's start at half_length − corner_radius,
# which is what makes it read as a curtain around the end rather than a flat
# panel across it.
const NET_EDGE_Z: float = 14.0
const NET_HEIGHT: float = 4.5
# World size of one diamond in Assets/textures/net_diamond.png. The band's UVs
# are scaled by this so the mesh keeps a constant physical gauge whether it is
# crossing a straight or a corner, instead of stretching with the arc.
const NET_TILE_M: float = 0.14

# Texture resolution: pixels per meter
var _px_per_meter: float = 80.0

# cache key → products dict {ice_tex, stripe_tex, band_* ArrayMeshes}. Every
# product is a deterministic function of the exports
# in _cache_key() — the ice albedo alone is a ~10M-pixel image painted
# pixel-by-pixel in GDScript, the dominant rebuild cost — so they're built
# once per param set and shared across rink instances for the process
# lifetime (free play → lobby → game each instance a fresh rink). Materials,
# the scratch map, and the decal viewport hold live per-rink state and stay
# per-instance. Bounded by clearing on editor param churn.
static var _build_cache: Dictionary = {}

# Persistent skate-scratch overlay. Created at runtime only (not in editor)
# and bound to the ice shader's scratch_tex.
var _scratch_map: IceScratchMap = null
# The center-ice decal SubViewport and the ice material, held so exit teardown
# can release the ViewportTexture shader bindings and free the render targets
# before the RenderingServer is finalized — see _teardown_render_targets().
var _decal_vp: SubViewport = null
var _ice_material: ShaderMaterial = null
# Sponsor art render targets — the dasher-board atlas and the in-ice overlay.
# Held for the same reason as the decal viewport: their textures are bound into
# live materials and have to be released before the RenderingServer finalizes.
var _board_ad_vp: SubViewport = null
var _ice_ad_vp: SubViewport = null
var _board_ad_material: StandardMaterial3D = null
var _render_targets_freed: bool = false

func _ready() -> void:
	_rebuild()
	if not Engine.is_editor_hint() and _scratch_map != null:
		# period_synced emits `new_period: int`; clear() takes no args, so we
		# unbind the int — without this, Godot errors silently each emit
		# ("Expected 0 arguments, got 1") and the ice never resets.
		GameManager.period_synced.connect(_scratch_map.clear.unbind(1))
		# Resurfacer crew for scoreless intermissions. Both teardown signals are
		# needed: a reel break ends with intermission_ended, but a scoreless one
		# never emits it — the next faceoff prep is its exit (same dismissal the
		# HUD band uses), and it also covers a skip vote cutting the break short.
		var resurfacer := IceResurfacer.new()
		resurfacer.name = "IceResurfacer"
		resurfacer.setup(rink_width, rink_length, _scratch_map)
		add_child(resurfacer)
		GameManager.intermission_idle_started.connect(resurfacer.start_lap)
		GameManager.intermission_ended.connect(resurfacer.abort)
		GameManager.faceoff_prep_announced.connect(resurfacer.abort)

# Release the SubViewport render targets and their ViewportTexture shader
# bindings explicitly, before Godot finalizes the RenderingServer on quit. The
# ice material holds ViewportTextures for the scratch and center-ice decal
# overlays; left bound at exit, those viewports — plus the canvas items and
# text-shaping RIDs from their Node2D painters — are torn down after the server
# and reported as leaked RIDs / "resources still in use at exit". Clearing the
# params drops the material's references and freeing the viewports releases the
# RIDs in order. WM_CLOSE fires on the OS window close; _exit_tree covers the
# menu Quit / scene-change paths. Guarded so the two paths can't double-free.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_teardown_render_targets()

func _exit_tree() -> void:
	_teardown_render_targets()

func _teardown_render_targets() -> void:
	if _render_targets_freed:
		return
	_render_targets_freed = true
	if _ice_material != null:
		_ice_material.set_shader_parameter("scratch_tex", null)
		_ice_material.set_shader_parameter("decal_tex", null)
		_ice_material.set_shader_parameter("ads_tex", null)
	_ice_material = null
	if _board_ad_material != null:
		_board_ad_material.albedo_texture = null
	_board_ad_material = null
	if is_instance_valid(_scratch_map):
		_scratch_map.free()
	_scratch_map = null
	if is_instance_valid(_decal_vp):
		_decal_vp.free()
	_decal_vp = null
	if is_instance_valid(_board_ad_vp):
		_board_ad_vp.free()
	_board_ad_vp = null
	if is_instance_valid(_ice_ad_vp):
		_ice_ad_vp.free()
	_ice_ad_vp = null


# Drop the process-lifetime build cache. The cached products include the ice
# and side-stripe ImageTextures (the ice albedo alone is ~10M pixels), held in
# a static dict that survives scene changes for perf. A static var is freed at
# script-unload — AFTER the RenderingServer finalizes — so at exit those
# textures destruct with a null RenderingServer and their RIDs are reported as
# leaked. Clearing the dict here, from a real-shutdown hook (GameManager), drops
# the last reference while the server is still alive so they free cleanly. Only
# call at app quit — clearing mid-session would just force a rebuild.
static func release_shared_cache() -> void:
	_build_cache.clear()

func _rebuild() -> void:
	if rink_length <= 0 or rink_width <= 0:
		return

	# A prior _exit_tree (e.g. a reparent) may have latched the teardown guard;
	# clear it so a genuine later teardown still frees the freshly built targets.
	_render_targets_freed = false
	for child in get_children():
		child.queue_free()

	var half_l: float = rink_length / 2.0
	var half_w: float = rink_width / 2.0
	var r: float = corner_radius

	var products: Dictionary = _get_or_build_products()

	# --- Ice surface ---
	_add_ice(products.ice_tex)

	# --- Walls (continuous mesh around the entire perimeter) ---
	# Solid bands use cull_disabled — the ArrayMesh inner face is otherwise
	# culled by Godot's renderer even though the world-space winding looks
	# correct on paper. BoxMesh works because its vertex order compensates.
	# Materials are per-instance (cheap; emission/color exports apply without
	# invalidating the cached meshes).
	var kp_mat: StandardMaterial3D = _make_solid_material(kickplate_color, kickplate_emission_energy)
	kp_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var board_mat: StandardMaterial3D = _make_solid_material(wall_color, wall_emission_energy)
	board_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var cap_mat: StandardMaterial3D = _make_solid_material(cap_rail_color, cap_rail_emission_energy)
	cap_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_add_band_instance(products.band_kickplate, kp_mat)
	_add_band_instance(products.band_board, board_mat)
	_add_band_instance(products.band_cap, cap_mat)
	_add_band_instance(products.band_glass, _make_glass_material())

	# --- Painted stripes ---
	# Goal-line stripes on each corner's white-board zone, drawn where the line
	# crosses the curve. Position is the canonical goal-line Z from GameRules
	# so the stripe matches the painted goal line on the ice.
	var goal_z: float = GameRules.GOAL_LINE_Z
	var corner_stripes: Array = [
		{"z":  goal_z, "color": red_line_color},
		{"z": -goal_z, "color": red_line_color},
	]
	var corner_specs: Array = [
		{"center": Vector3(half_w - r, 0, -half_l + r), "a0": -PI / 2.0, "a1": 0.0},
		{"center": Vector3(half_w - r, 0, half_l - r), "a0": 0.0, "a1": PI / 2.0},
		{"center": Vector3(-half_w + r, 0, half_l - r), "a0": PI / 2.0, "a1": PI},
		{"center": Vector3(-half_w + r, 0, -half_l + r), "a0": PI, "a1": 3.0 * PI / 2.0},
	]
	for cs in corner_specs:
		for st in corner_stripes:
			_add_corner_stripe(cs.center, cs.a0, cs.a1, st)

	_add_side_board_stripes(products.stripe_tex)

	_add_gates(products.band_gates)
	_add_netting(products.band_netting)

	if board_ads_enabled:
		_add_board_ads(products.band_ads)


# ── Build cache ──────────────────────────────────────────────────────────────

# Every export that moves a cached product: dims/segments shape the meshes, the
# ice/line colors are baked into the two painted textures.
# Colors that only feed per-instance materials (wall/kickplate/cap/glass,
# emission, ice-shader params) are deliberately absent.
func _cache_key() -> String:
	return str([rink_length, rink_width, corner_radius, wall_height,
			wall_thickness, corner_segments,
			kickplate_height, glass_height, glass_thickness, _px_per_meter,
			ice_color, red_line_color, blue_line_color])


func _get_or_build_products() -> Dictionary:
	var key: String = _cache_key()
	if _build_cache.has(key):
		return _build_cache[key]
	if _build_cache.size() >= 4:
		_build_cache.clear()

	# Perimeter geometry. Previously the four straight walls were BoxMesh /
	# BoxShape3D and the four corners were separate ArrayMesh /
	# ConcavePolygonShape3D rings. The seam between them produced both visual
	# (flat-vs-smooth shading) and physical (contact-normal kink) artifacts.
	# Merging into one continuous loop per band eliminates every seam.
	var stations: Array = _build_perimeter_stations(corner_segments)
	var board_top: float = wall_height - CAP_RAIL_HEIGHT
	var rail_top: float = wall_height
	var glass_y_bot: float = rail_top + GLASS_LIFT
	var glass_y_top: float = glass_y_bot + glass_height
	var board_half_thick: float = wall_thickness / 2.0
	var kick_half_thick: float = board_half_thick + KICKPLATE_PROTRUSION
	var cap_half_thick: float = board_half_thick + CAP_RAIL_PROTRUSION
	var glass_half_thick: float = glass_thickness / 2.0

	# The kickplate lip (kick_half_thick) is the innermost visible surface, and it
	# is where the analytic boundary sits — so the puck and the skater stop at what
	# the player sees rather than at the boards' face 1 cm behind it. Same surface
	# the blade clamp, AI trajectory reflection, and puck-OOB check use
	# (GameRules.INNER_* / KICKPLATE_INWARD_LIP — keep them in sync).

	var products: Dictionary = {
		"ice_tex": _build_ice_texture(),
		"stripe_tex": _build_side_stripe_texture(),
		# Kickplate (yellow lip with full caps — top cap forms the inward and
		# outward shelves, bottom cap closes the volume). Bottom recessed below
		# the ice plane to avoid coplanar z-fight (see KICKPLATE_ICE_OFFSET).
		"band_kickplate": _perimeter_band_mesh(stations, kick_half_thick, kick_half_thick,
				-KICKPLATE_ICE_OFFSET, kickplate_height),
		# White board — top and bottom faces are covered by the kickplate's top
		# cap and the cap rail's bottom cap, so skip its caps to avoid coplanar
		# z-fight with those lips.
		"band_board": _perimeter_band_mesh(stations, board_half_thick, board_half_thick,
				kickplate_height, board_top, false, false),
		# Cap rail (blue lip).
		"band_cap": _perimeter_band_mesh(stations, cap_half_thick, cap_half_thick,
				board_top, rail_top),
		# Glass — transparent, narrower than the boards, lifted by GLASS_LIFT so
		# its bottom cap doesn't z-fight the cap rail's top.
		"band_glass": _perimeter_band_mesh(stations, glass_half_thick, glass_half_thick,
				glass_y_bot, glass_y_top),
		# Sponsor panels: one merged ribbon hugging the white board's inner face.
		# Built regardless of board_ads_enabled — it is a handful of quads, and
		# keeping it out of the cache key means toggling the ads in the editor
		# doesn't throw away the ten-million-pixel ice albedo alongside them.
		"band_ads": _build_ad_band(stations, board_half_thick),
		"band_gates": _build_gate_band(stations, board_half_thick),
		"band_netting": _build_net_band(stations, glass_half_thick),
	}
	_build_cache[key] = products
	return products


# Paint the full-rink albedo (lines, creases, faceoff markings) into an
# ImageTexture. Pixel-by-pixel GDScript over a ~10M-pixel image — by far the
# most expensive rebuild product, which is why it's cached.
func _build_ice_texture() -> ImageTexture:
	var img_w = int(rink_width * _px_per_meter)
	var img_h = int(rink_length * _px_per_meter)

	var img = Image.create(img_w, img_h, false, Image.FORMAT_RGBA8)
	img.fill(ice_color)

	# Image-coordinate convention used throughout this function:
	#   world +X → image +X
	#   world +Z → image -Y   (rink length runs along image Y)
	#   centre of rink → centre of image
	# All geometric positions come from GameRules so the painted lines and
	# dots stay locked to the gameplay coordinates the puck/skaters use.
	var blue_z: int = int(GameRules.BLUE_LINE_Z * _px_per_meter)
	var goal_z: int = int(GameRules.GOAL_LINE_Z * _px_per_meter)

	# Goalie creases — drawn before lines so lines render on top
	var crease_color: Color = Color(0.392, 0.765, 0.922)  # Pantone 298
	_draw_crease_fill(img, img_w / 2.0, img_h / 2.0 - goal_z, 1, crease_color)
	_draw_crease_fill(img, img_w / 2.0, img_h / 2.0 + goal_z, -1, crease_color)

	# Line widths in pixels — thick (center/blue): 0.3m, thin (goal/circles): 0.05m
	var thick_line: int = int(0.3 * _px_per_meter)
	var thin_line: int  = max(int(0.05 * _px_per_meter), 2)

	# Center red line (at Z=0)
	_draw_h_line(img, img_h / 2.0, thick_line, red_line_color)

	# Blue lines
	_draw_h_line(img, img_h / 2.0 - blue_z, thick_line, blue_line_color)
	_draw_h_line(img, img_h / 2.0 + blue_z, thick_line, blue_line_color)

	# Goal lines
	_draw_h_line(img, img_h / 2.0 - goal_z, thin_line, red_line_color)
	_draw_h_line(img, img_h / 2.0 + goal_z, thin_line, red_line_color)

	# Crease arc outlines (drawn after goal lines so arcs sit on top)
	_draw_crease_arc(img, img_w / 2.0, img_h / 2.0 - goal_z, 1, thin_line, red_line_color)
	_draw_crease_arc(img, img_w / 2.0, img_h / 2.0 + goal_z, -1, thin_line, red_line_color)

	# ── Faceoff markings ────────────────────────────────────────────────────────
	# Dot and circle sizes from NHL Official Rules — 2' diameter filled dot,
	# 15' radius surrounding circle.
	var dot_r:    float = 0.3048 * _px_per_meter
	var circle_r: float = 4.572  * _px_per_meter

	# Center ice circle + filled dot
	_draw_circle(img, img_w / 2.0, img_h / 2.0, circle_r, thin_line, blue_line_color)
	_draw_filled_circle(img, img_w / 2.0, img_h / 2.0, dot_r, blue_line_color)

	# End-zone faceoff dots + circles — positions sourced from GameRules so
	# faceoff teleports land exactly on the painted dot.
	for dot: Vector2 in GameRules.END_ZONE_FACEOFF_DOTS:
		var px: float = img_w / 2.0 + dot.x * _px_per_meter
		var py: float = img_h / 2.0 - dot.y * _px_per_meter
		_draw_filled_circle(img, px, py, dot_r, red_line_color)
		_draw_circle(img, px, py, circle_r, thin_line, red_line_color)

	# Neutral-zone faceoff dots (no surrounding circle per NHL spec)
	for dot: Vector2 in GameRules.NEUTRAL_ZONE_FACEOFF_DOTS:
		var px: float = img_w / 2.0 + dot.x * _px_per_meter
		var py: float = img_h / 2.0 - dot.y * _px_per_meter
		_draw_filled_circle(img, px, py, dot_r, red_line_color)

	return ImageTexture.create_from_image(img)


func _add_ice(tex: ImageTexture) -> void:
	# Ice mesh
	var mesh_instance = MeshInstance3D.new()
	var plane = PlaneMesh.new()
	plane.size = Vector2(rink_width, rink_length)
	mesh_instance.mesh = plane
	mesh_instance.position = Vector3(0, 0, 0)
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://Shaders/ice.gdshader")
	mat.set_shader_parameter("albedo_tex", tex)
	mat.set_shader_parameter("rink_size", Vector2(rink_width, rink_length))
	mat.set_shader_parameter("ice_fog_color", ice_fog_color)
	mat.set_shader_parameter("subsurface_fade", ice_subsurface_fade)
	mat.set_shader_parameter("subsurface_depth", ice_subsurface_depth)
	mat.set_shader_parameter("specular_strength", ice_specular)
	mat.set_shader_parameter("roughness_head_on", ice_roughness_head_on)
	mat.set_shader_parameter("roughness_grazing", ice_roughness_grazing)
	mesh_instance.material_override = mat
	_ice_material = mat
	add_child(mesh_instance)

	_add_ice_ads(mat)

	# Persistent skate scratches — runtime only. The SubViewport renders into
	# a texture that the ice shader samples as a surface overlay.
	if not Engine.is_editor_hint():
		var scratch_map: IceScratchMap = IceScratchMap.new()
		scratch_map.name = "IceScratchMap"
		scratch_map.rink_width = rink_width
		scratch_map.rink_length = rink_length
		add_child(scratch_map)
		mat.set_shader_parameter("scratch_tex", scratch_map.get_texture())
		_scratch_map = scratch_map

		# Player rings — the ice shader draws them analytically; this feeds it
		# the live positions. Sibling of the scratch map in every sense: same
		# owner, same job of turning skater state into an ice-shader input.
		var ring_field := IceRingField.new()
		ring_field.name = "IceRingField"
		ring_field.setup(mat)
		add_child(ring_field)

	# Center-ice decals (logo + curved "MITTS"/"ARENA" text). The content
	# only occupies a small patch at center ice (logo + text ring fit inside
	# ~5 m of the world origin), so we render into a tiny SubViewport instead
	# of one sized to the whole rink — ~36 MB GPU memory saved vs the full
	# albedo-resolution viewport.
	const DECAL_AREA_SIZE_M: float = 10.0
	const DECAL_VIEWPORT_SIZE: int = 1024
	var decal_px_per_m: float = float(DECAL_VIEWPORT_SIZE) / DECAL_AREA_SIZE_M

	var decal_vp: SubViewport = SubViewport.new()
	decal_vp.name = "CenterIceDecalsViewport"
	decal_vp.size = Vector2i(DECAL_VIEWPORT_SIZE, DECAL_VIEWPORT_SIZE)
	decal_vp.transparent_bg = true
	decal_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	decal_vp.disable_3d = true
	decal_vp.handle_input_locally = false
	decal_vp.gui_disable_input = true
	add_child(decal_vp)
	_decal_vp = decal_vp

	var decals: CenterIceDecals = CenterIceDecals.new()
	decals.img_size = Vector2(DECAL_VIEWPORT_SIZE, DECAL_VIEWPORT_SIZE)
	decals.px_per_meter = decal_px_per_m
	decals.text_color = blue_line_color
	decal_vp.add_child(decals)
	mat.set_shader_parameter("decal_tex", decal_vp.get_texture())

	# Tell the shader where the decal patch lives in rink-UV space, so it
	# can remap the parallax UV into the local decal-texture coords.
	var half_size: float = DECAL_AREA_SIZE_M * 0.5
	mat.set_shader_parameter("decal_uv_min", Vector2(
		0.5 - half_size / rink_width,
		0.5 - half_size / rink_length
	))
	mat.set_shader_parameter("decal_uv_max", Vector2(
		0.5 + half_size / rink_width,
		0.5 + half_size / rink_length
	))


func _draw_v_line(img: Image, x: float, thickness: int, color: Color) -> void:
	var half_t: float = thickness / 2.0
	for px in range(int(x - half_t), int(x + half_t) + 1):
		if px >= 0 and px < img.get_width():
			for py in range(img.get_height()):
				img.set_pixel(px, py, color)

func _draw_h_line(img: Image, y: int, thickness: int, color: Color) -> void:
	var half_t = thickness / 2.0
	for py in range(y - half_t, y + half_t + 1):
		if py >= 0 and py < img.get_height():
			for px in range(img.get_width()):
				img.set_pixel(px, py, color)

func _draw_circle(img: Image, cx: float, cy: float, radius: float, thickness: float, color: Color) -> void:
	var aa: float = 1.0
	var r_outer := radius + thickness / 2.0
	var r_inner := radius - thickness / 2.0
	for py in range(int(cy - r_outer - aa - 1), int(cy + r_outer + aa + 2)):
		for px in range(int(cx - r_outer - aa - 1), int(cx + r_outer + aa + 2)):
			if px >= 0 and px < img.get_width() and py >= 0 and py < img.get_height():
				var dist := sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy))
				var alpha := minf(
					clampf((dist - (r_inner - aa)) / aa, 0.0, 1.0),
					clampf(((r_outer + aa) - dist) / aa, 0.0, 1.0)
				)
				if alpha > 0.0:
					img.set_pixel(px, py, img.get_pixel(px, py).lerp(color, alpha))

func _draw_filled_circle(img: Image, cx: float, cy: float, radius: float, color: Color) -> void:
	var aa: float = 1.0
	for py in range(int(cy - radius - aa - 1), int(cy + radius + aa + 2)):
		for px in range(int(cx - radius - aa - 1), int(cx + radius + aa + 2)):
			if px >= 0 and px < img.get_width() and py >= 0 and py < img.get_height():
				var dist := sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy))
				var alpha := clampf((radius + aa - dist) / aa, 0.0, 1.0)
				if alpha > 0.0:
					img.set_pixel(px, py, img.get_pixel(px, py).lerp(color, alpha))

func _draw_crease_fill(img: Image, cx: float, goal_y: float, toward_center: int, color: Color) -> void:
	# NHL crease: D-shape — arc radius 6 ft (1.83m) from goal center, capped at 4 ft (1.22m)
	# either side of center (8 ft / 2.44m total width, 1 ft outside each post).
	# Straight sides run 4.5 ft (1.37m) from the goal line; arc connects their tops.
	var arc_r: float = 1.83 * _px_per_meter
	var half_w: float = 1.22 * _px_per_meter
	var aa: float = 1.0
	var search: int = int(arc_r + aa) + 2
	for py in range(int(goal_y) - search, int(goal_y) + search + 1):
		for px in range(int(cx) - search, int(cx) + search + 1):
			if px < 0 or px >= img.get_width() or py < 0 or py >= img.get_height():
				continue
			var dx: float = px - cx
			var dy: float = (py - goal_y) * toward_center
			if dy < -aa:
				continue
			# Signed distance inward from each boundary (positive = inside).
			var dist: float = sqrt(dx * dx + dy * dy)
			var inside_arc: float = arc_r - dist
			var inside_side: float = half_w - abs(dx)
			var inside_goal: float = dy
			var inside: float = minf(minf(inside_arc, inside_side), inside_goal)
			var alpha: float = clampf(inside / aa + 0.5, 0.0, 1.0)
			if alpha > 0.0:
				img.set_pixel(px, py, img.get_pixel(px, py).lerp(color, alpha))

func _draw_crease_arc(img: Image, cx: float, goal_y: float, toward_center: int, thickness: int, color: Color) -> void:
	# Curved arc (capped at crease half-width) + two straight side lines
	var arc_r: float = 1.83 * _px_per_meter
	var half_w: float = 1.22 * _px_per_meter
	var straight_depth: float = 1.37 * _px_per_meter  # where sides meet the arc
	var half_t: float = thickness / 2.0
	var aa: float = 1.0
	var r_outer: float = arc_r + half_t
	var search: int = int(r_outer + aa) + 2
	for py in range(int(goal_y) - search, int(goal_y) + search + 1):
		for px in range(int(cx) - search, int(cx) + search + 1):
			if px < 0 or px >= img.get_width() or py < 0 or py >= img.get_height():
				continue
			var dx: float = px - cx
			var dy: float = (py - goal_y) * toward_center
			if dy < -aa:
				continue
			var alpha: float = 0.0
			# Curved band of width `thickness` around arc_r. Extend the side cap by
			# half_t so the band's outer edge reaches the stroke's outer edge at the
			# corner (without the extension, those two outer terminations leave a
			# diagonal gap and the corner shows a notch).
			if abs(dx) <= half_w + half_t:
				var dist: float = sqrt(dx * dx + dy * dy)
				var band: float = half_t - abs(dist - arc_r)
				var arc_inside: float = minf(band, dy)
				alpha = maxf(alpha, clampf(arc_inside / aa + 0.5, 0.0, 1.0))
			# Straight side strokes at x = ±half_w. Hard-clip at the top (dy = straight_depth);
			# the arc band covers that interior boundary.
			if dy <= straight_depth:
				var stroke: float = half_t - abs(abs(dx) - half_w)
				var side_inside: float = minf(stroke, dy)
				alpha = maxf(alpha, clampf(side_inside / aa + 0.5, 0.0, 1.0))
			if alpha > 0.0:
				img.set_pixel(px, py, img.get_pixel(px, py).lerp(color, alpha))

# Paint center red line and blue zone lines as a texture for the inner board
# face, identical to how rink ice lines are drawn — no physical depth, no
# z-fighting. Cached alongside the ice albedo.
func _build_side_stripe_texture() -> ImageTexture:
	var wall_len: float = rink_length - 2.0 * corner_radius
	var band_h: float = (wall_height - CAP_RAIL_HEIGHT) - kickplate_height
	var img_w: int = maxi(int(wall_len * _px_per_meter), 1)
	var img_h: int = maxi(int(band_h * _px_per_meter), 1)

	var img := Image.create(img_w, img_h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))  # transparent — board color shows through

	var thick_px: int = int(0.3 * _px_per_meter)
	var cx: float = float(img_w) / 2.0
	var bx: float = GameRules.BLUE_LINE_Z * _px_per_meter
	_draw_v_line(img, cx,        thick_px, red_line_color)
	_draw_v_line(img, cx + bx,   thick_px, blue_line_color)
	_draw_v_line(img, cx - bx,   thick_px, blue_line_color)

	return ImageTexture.create_from_image(img)


func _add_side_board_stripes(tex: ImageTexture) -> void:
	var half_w: float = rink_width / 2.0
	var wall_len: float = rink_length - 2.0 * corner_radius
	var y_bot: float = kickplate_height
	var y_top: float = wall_height - CAP_RAIL_HEIGHT

	for side: float in [1.0, -1.0]:
		# Quad spans only the white-board band (between kickplate and cap-rail
		# lips). 1 mm inside the board inner face so it's never coplanar with
		# the board's own surface.
		var face_x: float = side * (half_w - wall_thickness / 2.0) - side * 0.001
		var z0: float = -wall_len / 2.0
		var z1: float =  wall_len / 2.0
		var norm := Vector3(-side, 0.0, 0.0)

		var verts   := PackedVector3Array([
			Vector3(face_x, y_bot, z0),
			Vector3(face_x, y_bot, z1),
			Vector3(face_x, y_top, z1),
			Vector3(face_x, y_top, z0),
		])
		var normals := PackedVector3Array([norm, norm, norm, norm])
		var uvs     := PackedVector2Array([
			Vector2(0.0, 1.0), Vector2(1.0, 1.0),
			Vector2(1.0, 0.0), Vector2(0.0, 0.0),
		])
		var indices := PackedInt32Array([0, 1, 2, 0, 2, 3])

		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX]  = verts
		arrays[Mesh.ARRAY_NORMAL]  = normals
		arrays[Mesh.ARRAY_TEX_UV]  = uvs
		arrays[Mesh.ARRAY_INDEX]   = indices

		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		var mat := StandardMaterial3D.new()
		mat.albedo_texture = tex
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.render_priority = 1
		mi.material_override = mat
		add_child(mi)

# ── Sponsor panels ───────────────────────────────────────────────────────────

# Height of the white board's visible channel — the strip between the kickplate
# lip and the cap rail — less the margin that keeps the board framing the ads.
func _ad_band_height() -> float:
	return maxf((wall_height - CAP_RAIL_HEIGHT) - kickplate_height
			- 2.0 * AD_BAND_MARGIN, 0.0)


# Panel width is DERIVED, never tuned: the atlas cell has a fixed aspect, so the
# only width that shows the art unstretched is the band height times that aspect.
func _ad_panel_width() -> float:
	return _ad_band_height() * float(BoardAdPainter.CELL_PX.x) / float(BoardAdPainter.CELL_PX.y)


# The stretches of board an ad may not take: the painted stripes, and the boards
# the player benches sit behind.
#
# Sampled by walking the perimeter at a fixed arc step rather than by testing the
# stations, because station spacing is geometric — the whole middle of a 43 m
# straight run, where the centre and blue stripes live, has no station near it.
func _ad_reserved_arcs(stations: Array, cumulative: PackedFloat32Array,
		perimeter: float) -> Array[Vector2]:
	var reserved: Array[Vector2] = []
	var s: float = 0.0
	while s < perimeter:
		if _ad_arc_is_reserved(BoardAdBandBuilder.sample_pos(stations, cumulative, s)):
			# Overlapping stubs; BoardAdLayout merges them into runs.
			reserved.append(Vector2(s - AD_RESERVE_STEP, AD_RESERVE_STEP * 2.0))
		s += AD_RESERVE_STEP
	return reserved


# `point` is a spot on the perimeter centerline, as (x, z) in metres.
func _ad_arc_is_reserved(point: Vector2) -> bool:
	var abs_z: float = absf(point.y)
	if abs_z < AD_SIDE_STRIPE_HALF + AD_STRIPE_CLEARANCE:
		return true   # centre red stripe
	if absf(abs_z - GameRules.BLUE_LINE_Z) < AD_SIDE_STRIPE_HALF + AD_STRIPE_CLEARANCE:
		return true   # blue stripes
	if absf(abs_z - GameRules.GOAL_LINE_Z) < AD_GOAL_STRIPE_HALF + AD_STRIPE_CLEARANCE:
		return true   # goal-line stripes, out on the corner arcs
	# Rinkside furniture: the benches run along the +X boards and the penalty
	# boxes along −X, and in each case the gap between the two halves is gate and
	# staff area rather than a stretch of wall, so the whole span is spoken for.
	var furniture_span: float = ArenaStands.BENCH_CENTER_Z + ArenaStands.BENCH_HALF_LEN \
			if point.x > 0.0 \
			else ArenaStands.PENALTY_BOX_CENTER_Z + ArenaStands.PENALTY_BOX_HALF_LEN
	if abs_z < furniture_span + AD_STRIPE_CLEARANCE:
		return true
	# Every gate is reserved explicitly rather than left to the furniture spans
	# to happen to cover — the resurfacer doors on the end boards are nowhere
	# near either span. All gates sit on straight wall, so a plain world-space
	# distance is a faithful stand-in for distance along the boards.
	for target: Vector2 in _gate_targets():
		if point.distance_to(target) < GATE_WIDTH * 0.5 + GATE_CLEARANCE:
			return true
	return false


# Gate centres on the perimeter centerline, as (x, z) in metres. Bench doors at
# the inner end of each bench, penalty doors at the outer end of each box, and
# one resurfacer door per end board on the side its machine drives in from.
func _gate_targets() -> Array[Vector2]:
	var half_w: float = rink_width / 2.0
	var half_l: float = rink_length / 2.0
	var penalty_end: float = ArenaStands.PENALTY_BOX_CENTER_Z \
			+ ArenaStands.PENALTY_BOX_HALF_LEN - GATE_WIDTH * 0.5
	return [
		Vector2( half_w,  1.55), Vector2( half_w, -1.55),
		Vector2(-half_w,  penalty_end), Vector2(-half_w, -penalty_end),
		Vector2(-GATE_RESURFACER_X,  half_l), Vector2(GATE_RESURFACER_X, -half_l),
	] as Array[Vector2]


func _build_ad_band(stations: Array, board_half_thick: float) -> ArrayMesh:
	var cumulative: PackedFloat32Array = BoardAdBandBuilder.cumulative_arcs(stations)
	var perimeter: float = BoardAdBandBuilder.perimeter_of(cumulative)
	var panel_width: float = _ad_panel_width()
	if panel_width <= 0.0:
		return null
	var placements: Array[Vector2] = BoardAdLayout.place_panels(
			perimeter, _ad_reserved_arcs(stations, cumulative, perimeter),
			panel_width, AD_PANEL_GAP, AD_RUN_MARGIN)
	if placements.is_empty():
		return null

	# Panels are dealt round-robin, so a lap of the rink shows every sponsor
	# before it repeats one.
	var brand_count: int = AdBrands.BRANDS.size()
	var uv_rects: Array[Rect2] = []
	for index: int in placements.size():
		uv_rects.append(BoardAdPainter.cell_uv(index % brand_count, brand_count))

	return BoardAdBandBuilder.build_band(stations, cumulative, placements, uv_rects,
			board_half_thick + AD_BAND_INSET,
			kickplate_height + AD_BAND_MARGIN,
			wall_height - CAP_RAIL_HEIGHT - AD_BAND_MARGIN)


func _add_board_ads(band: ArrayMesh) -> void:
	if band == null:
		return

	var atlas_vp := SubViewport.new()
	atlas_vp.name = "BoardAdAtlasViewport"
	atlas_vp.size = BoardAdPainter.atlas_size(AdBrands.BRANDS.size())
	atlas_vp.transparent_bg = true
	atlas_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	atlas_vp.disable_3d = true
	atlas_vp.handle_input_locally = false
	atlas_vp.gui_disable_input = true
	add_child(atlas_vp)
	_board_ad_vp = atlas_vp

	var painter := BoardAdPainter.new()
	painter.brands = AdBrands.BRANDS
	atlas_vp.add_child(painter)

	var mi := MeshInstance3D.new()
	mi.name = "BoardAds"
	mi.mesh = band
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = atlas_vp.get_texture()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Unshaded for the same reason the board bands self-emit: the ceiling rig
	# grazes these near-vertical faces, so a lit ad reads black from the top-down
	# gameplay camera (see docs/arena-atmosphere-spec.md). Matches the painted
	# stripes, which sit on the same wall.
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.render_priority = 1
	mi.material_override = mat
	_board_ad_material = mat
	add_child(mi)


# ── Gates ────────────────────────────────────────────────────────────────────

# Arc of the perimeter point nearest `target`, found by walking the loop rather
# than by solving per wall section. The walk costs nothing at build time and
# cannot be wrong about which section a point belongs to, which the closed-form
# version would have to get right for straights and arcs separately.
func _arc_nearest_to(stations: Array, cumulative: PackedFloat32Array,
		perimeter: float, target: Vector2) -> float:
	var best_arc: float = 0.0
	var best_dist: float = INF
	var s: float = 0.0
	while s < perimeter:
		var dist: float = BoardAdBandBuilder.sample_pos(stations, cumulative, s) \
				.distance_squared_to(target)
		if dist < best_dist:
			best_dist = dist
			best_arc = s
		s += AD_RESERVE_STEP
	return best_arc


func _build_gate_band(stations: Array, board_half_thick: float) -> ArrayMesh:
	var cumulative: PackedFloat32Array = BoardAdBandBuilder.cumulative_arcs(stations)
	var perimeter: float = BoardAdBandBuilder.perimeter_of(cumulative)
	var placements: Array[Vector2] = []
	var uv_rects: Array[Rect2] = []
	for target: Vector2 in _gate_targets():
		var arc: float = _arc_nearest_to(stations, cumulative, perimeter, target)
		placements.append(Vector2(arc - GATE_WIDTH * 0.5, GATE_WIDTH))
		# One texture for every gate — a door is a door.
		uv_rects.append(Rect2(0.0, 0.0, 1.0, 1.0))
	# Gates run the full height of the white board: a door reaches the rail.
	return BoardAdBandBuilder.build_band(stations, cumulative, placements, uv_rects,
			board_half_thick + GATE_INSET,
			kickplate_height, wall_height - CAP_RAIL_HEIGHT)


# A frame, a hinge stile, and a handle — drawn transparent inside so the door
# shows the boards' own white rather than a patch that has to match it.
func _build_gate_texture() -> ImageTexture:
	var px_per_m: float = 200.0
	var band_h: float = (wall_height - CAP_RAIL_HEIGHT) - kickplate_height
	var img_w: int = maxi(int(GATE_WIDTH * px_per_m), 1)
	var img_h: int = maxi(int(band_h * px_per_m), 1)
	var img := Image.create(img_w, img_h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))

	var frame := Color(0.32, 0.34, 0.38)
	var hardware := Color(0.20, 0.21, 0.24)
	var edge: int = maxi(int(0.035 * px_per_m), 2)
	# Frame: four bars around the opening.
	img.fill_rect(Rect2i(0, 0, img_w, edge), frame)
	img.fill_rect(Rect2i(0, img_h - edge, img_w, edge), frame)
	img.fill_rect(Rect2i(0, 0, edge, img_h), frame)
	img.fill_rect(Rect2i(img_w - edge, 0, edge, img_h), frame)
	# Hinge stile down the latch-side edge, and two hinge blocks on it.
	var stile: int = maxi(int(0.06 * px_per_m), 2)
	img.fill_rect(Rect2i(edge, 0, stile, img_h), frame.darkened(0.15))
	for hinge_frac: float in [0.22, 0.74]:
		img.fill_rect(Rect2i(edge, int(img_h * hinge_frac),
				stile * 3, maxi(int(0.05 * px_per_m), 2)), hardware)
	# Handle: a horizontal bar set in from the swinging edge.
	var handle_w: int = int(0.26 * px_per_m)
	img.fill_rect(Rect2i(img_w - edge - handle_w - int(0.05 * px_per_m),
			int(img_h * 0.46), handle_w, maxi(int(0.045 * px_per_m), 2)), hardware)
	return ImageTexture.create_from_image(img)


func _add_gates(band: ArrayMesh) -> void:
	if band == null:
		return
	var mi := MeshInstance3D.new()
	mi.name = "BoardGates"
	mi.mesh = band
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _build_gate_texture()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Unshaded for the reason the stripes and ads are — the ceiling rig grazes
	# these faces (see docs/arena-atmosphere-spec.md).
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.render_priority = 1
	mi.material_override = mat
	add_child(mi)


# ── End-zone netting ─────────────────────────────────────────────────────────

func _build_net_band(stations: Array, glass_half_thick: float) -> ArrayMesh:
	var cumulative: PackedFloat32Array = BoardAdBandBuilder.cumulative_arcs(stations)
	var perimeter: float = BoardAdBandBuilder.perimeter_of(cumulative)
	var half_w: float = rink_width / 2.0
	if NET_EDGE_Z >= rink_length / 2.0:
		return null

	# Each run starts on one side board, crosses a corner, the end, and the other
	# corner, and finishes on the opposite side board. Station order runs +Z up
	# the east wall and around, so the +Z run climbs in arc while the −Z run
	# wraps the seam — build_band samples modulo the perimeter, so the wrap needs
	# nothing but the right width.
	var runs: Array[Vector2] = [
		Vector2(half_w, NET_EDGE_Z), Vector2(-half_w, NET_EDGE_Z),
		Vector2(-half_w, -NET_EDGE_Z), Vector2(half_w, -NET_EDGE_Z),
	] as Array[Vector2]
	var placements: Array[Vector2] = []
	var uv_rects: Array[Rect2] = []
	for i: int in [0, 2]:
		var arc_start: float = _arc_nearest_to(stations, cumulative, perimeter, runs[i])
		var arc_end: float = _arc_nearest_to(stations, cumulative, perimeter, runs[i + 1])
		var width: float = arc_end - arc_start
		if width <= 0.0:
			width += perimeter
		placements.append(Vector2(arc_start, width))
		uv_rects.append(Rect2(0.0, 0.0, width / NET_TILE_M, NET_HEIGHT / NET_TILE_M))

	var glass_top: float = wall_height + GLASS_LIFT + glass_height
	return BoardAdBandBuilder.build_band(stations, cumulative, placements, uv_rects,
			glass_half_thick, glass_top, glass_top + NET_HEIGHT)


# One cell of diamond lattice: opaque strands, transparent holes.
#
# Drawn here rather than taken from Assets/textures/net_diamond.png, which looks
# like the right texture and is not: it is fully opaque, a diamond PATTERN that
# the goal-net shader tints and makes see-through through its own `tint` alpha
# uniform. Sampled straight into a StandardMaterial3D it is a solid wall.
func _build_net_texture() -> ImageTexture:
	var size: int = 64
	var half_strand: float = 0.055   # fraction of a cell, so gauge scales with it
	var aa: float = 1.5 / float(size)
	var img := Image.create(size, size, true, Image.FORMAT_RGBA8)
	for y: int in size:
		for x: int in size:
			var u: float = float(x) / float(size)
			var v: float = float(y) / float(size)
			# Two families of diagonals; a pixel is strand if it is near either.
			var alpha: float = maxf(
					_net_strand_alpha(fposmod(u + v, 1.0), half_strand, aa),
					_net_strand_alpha(fposmod(u - v, 1.0), half_strand, aa))
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


# Coverage of one strand, wrapped: `m` is the pixel's position within the cell
# along one diagonal family, so the line sits at both 0 and 1.
func _net_strand_alpha(m: float, half_strand: float, aa: float) -> float:
	var edge: float = minf(m, 1.0 - m)
	return clampf((half_strand - edge) / aa + 0.5, 0.0, 1.0)


func _add_netting(band: ArrayMesh) -> void:
	if band == null:
		return
	var mi := MeshInstance3D.new()
	mi.name = "EndZoneNetting"
	mi.mesh = band
	# On the jumbotron's layer, which is the project's established home for set
	# dressing the gameplay camera must not see (GameCamera and PovCamera both
	# clear this bit). The netting stands 4.5 m above the glass at both ends, so
	# left on the default layer it would hang between a top-down camera and the
	# play whenever the puck worked the end boards. Cinematic, replay, lobby and
	# free cameras keep the default everything-on mask and do see it.
	mi.layers = Jumbotron.RENDER_LAYER_MASK
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _build_net_texture()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(0.86, 0.88, 0.92, 0.85)
	mat.roughness = 0.9
	# It hangs in the dark above the lit boards; without a little self-emission
	# the mesh reads as a black smear rather than as a fine pale net.
	mat.emission_enabled = true
	mat.emission = Color(0.55, 0.60, 0.70)
	mat.emission_energy_multiplier = 0.25
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


func _add_ice_ads(mat: ShaderMaterial) -> void:
	if not ice_ads_enabled or AdBrands.ICE_SLOTS.is_empty():
		return

	var slots: Array[Dictionary] = []
	for slot: Dictionary in AdBrands.ICE_SLOTS:
		if slots.size() == IceAdPainter.MAX_SLOTS:
			push_warning("ICE_SLOTS is longer than IceAdPainter.MAX_SLOTS; the rest are dropped")
			break
		slots.append({
			"center": slot.center,
			"size": slot.size,
			"brand": AdBrands.brand_at(slot.brand as int),
		})

	var ads_vp := SubViewport.new()
	ads_vp.name = "IceAdsViewport"
	ads_vp.size = IceAdPainter.atlas_size(slots)
	ads_vp.transparent_bg = true
	ads_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	ads_vp.disable_3d = true
	ads_vp.handle_input_locally = false
	ads_vp.gui_disable_input = true
	add_child(ads_vp)
	_ice_ad_vp = ads_vp

	var painter := IceAdPainter.new()
	painter.slots = slots
	ads_vp.add_child(painter)

	# The two frames the shader has to bridge: where a slot sits on the ice, and
	# where its cell sits in the atlas. Kept full-length like the ring arrays —
	# the shader reads only the first ads_count entries.
	var slot_world := PackedVector4Array()
	var slot_atlas := PackedVector4Array()
	slot_world.resize(IceAdPainter.MAX_SLOTS)
	slot_atlas.resize(IceAdPainter.MAX_SLOTS)
	for index: int in slots.size():
		var centre: Vector2 = slots[index].center
		var half: Vector2 = (slots[index].size as Vector2) * 0.5
		slot_world[index] = Vector4(centre.x, centre.y, half.x, half.y)
		var uv: Rect2 = IceAdPainter.cell_uv(slots, index)
		slot_atlas[index] = Vector4(uv.position.x, uv.position.y, uv.size.x, uv.size.y)

	mat.set_shader_parameter("ads_tex", ads_vp.get_texture())
	mat.set_shader_parameter("ads_world", slot_world)
	mat.set_shader_parameter("ads_atlas", slot_atlas)
	mat.set_shader_parameter("ads_count", slots.size())
	mat.set_shader_parameter("ads_enabled", true)


func _make_glass_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = glass_color
	mat.roughness = 0.05
	mat.metallic = 0.0
	mat.metallic_specular = 1.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat

func _make_solid_material(color: Color, emission_energy: float = 0.0) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	if emission_energy > 0.0:
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = emission_energy
	return mat

# ── Continuous perimeter walls ────────────────────────────────────────────────
# The wall is a single closed loop around the rink: four straight runs plus
# four curved corners, sharing endpoints. Building each band (kickplate,
# white board, cap rail, glass) as a single ArrayMesh wrapping the entire
# perimeter eliminates the visual seam where flat-shaded BoxMesh meets
# smooth-shaded ArrayMesh corners. Building a single ConcavePolygonShape3D
# wrapping the same perimeter eliminates the physics seam where the box
# collider's contact normal kinks against the corner mesh's first triangle.

# Returns a closed loop of {pos: Vector2, inward: Vector2} stations sampled
# along the perimeter's centerline. Straight runs contribute one station per
# endpoint; corners contribute corner_segments stations along their arc.
# Junction stations are de-duplicated (each shared point appears once). The
# implicit closing edge connects the last station back to stations[0].
func _build_perimeter_stations(n: int) -> Array:
	var half_l: float = rink_length / 2.0
	var half_w: float = rink_width / 2.0
	var r: float = corner_radius
	var stations: Array = []

	# Walk counter-clockwise (viewed from above) starting at the south end
	# of the east wall. At each junction, the previous section's endpoint
	# IS the next section's start, so we only add new stations.

	# East wall (south → north)
	stations.append({"pos": Vector2(half_w, -(half_l - r)), "inward": Vector2(-1.0, 0.0)})
	stations.append({"pos": Vector2(half_w, half_l - r), "inward": Vector2(-1.0, 0.0)})

	# NE corner (angle 0 → π/2). i=0 coincides with east wall's north end.
	var ne_center := Vector2(half_w - r, half_l - r)
	for i in range(1, n + 1):
		var a: float = (PI / 2.0) * float(i) / float(n)
		var ca: float = cos(a)
		var sa: float = sin(a)
		stations.append({"pos": ne_center + r * Vector2(ca, sa), "inward": -Vector2(ca, sa)})

	# North wall (east → west). East endpoint is NE corner i=n.
	stations.append({"pos": Vector2(-(half_w - r), half_l), "inward": Vector2(0.0, -1.0)})

	# NW corner (π/2 → π).
	var nw_center := Vector2(-half_w + r, half_l - r)
	for i in range(1, n + 1):
		var a: float = (PI / 2.0) + (PI / 2.0) * float(i) / float(n)
		var ca: float = cos(a)
		var sa: float = sin(a)
		stations.append({"pos": nw_center + r * Vector2(ca, sa), "inward": -Vector2(ca, sa)})

	# West wall (north → south).
	stations.append({"pos": Vector2(-half_w, -(half_l - r)), "inward": Vector2(1.0, 0.0)})

	# SW corner (π → 3π/2).
	var sw_center := Vector2(-half_w + r, -half_l + r)
	for i in range(1, n + 1):
		var a: float = PI + (PI / 2.0) * float(i) / float(n)
		var ca: float = cos(a)
		var sa: float = sin(a)
		stations.append({"pos": sw_center + r * Vector2(ca, sa), "inward": -Vector2(ca, sa)})

	# South wall (west → east).
	stations.append({"pos": Vector2(half_w - r, -half_l), "inward": Vector2(0.0, 1.0)})

	# SE corner (3π/2 → 2π). Skip i=n — it equals stations[0]; the implicit
	# closing edge from stations[last] to stations[0] covers the last quad.
	var se_center := Vector2(half_w - r, -half_l + r)
	for i in range(1, n):
		var a: float = (3.0 * PI / 2.0) + (PI / 2.0) * float(i) / float(n)
		var ca: float = cos(a)
		var sa: float = sin(a)
		stations.append({"pos": se_center + r * Vector2(ca, sa), "inward": -Vector2(ca, sa)})

	return stations


# Builds arrays for a closed band wrapping the rink. inner_offset and
# outer_offset are the radial distances from the centerline to each face
# (both equal half-thickness for symmetric bands). Quads connect each
# station to the next, with the last station wrapping back to stations[0]
# so the band closes cleanly.
func _emit_perimeter_band_arrays(stations: Array,
		inner_offset: float, outer_offset: float,
		y_bot: float, y_top: float,
		with_top_cap: bool, with_bottom_cap: bool) -> Dictionary:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var n: int = stations.size()

	# Per-station position rows + per-station normal arrays.
	var inner_top := PackedVector3Array(); inner_top.resize(n)
	var inner_bot := PackedVector3Array(); inner_bot.resize(n)
	var outer_top := PackedVector3Array(); outer_top.resize(n)
	var outer_bot := PackedVector3Array(); outer_bot.resize(n)
	var inward_n := PackedVector3Array(); inward_n.resize(n)
	var outward_n := PackedVector3Array(); outward_n.resize(n)
	for i in range(n):
		var s = stations[i]
		var sp: Vector2 = s.pos
		var sn: Vector2 = s.inward
		var ip := sp + sn * inner_offset
		var op := sp - sn * outer_offset
		inner_top[i] = Vector3(ip.x, y_top, ip.y)
		inner_bot[i] = Vector3(ip.x, y_bot, ip.y)
		outer_top[i] = Vector3(op.x, y_top, op.y)
		outer_bot[i] = Vector3(op.x, y_bot, op.y)
		inward_n[i] = Vector3(sn.x, 0.0, sn.y)
		outward_n[i] = Vector3(-sn.x, 0.0, -sn.y)

	# Each face emits (n vertex pairs, n quads) that wrap the perimeter. The
	# four face emissions are inlined rather than extracted into a closure so
	# we don't rely on GDScript's lambda capture semantics for Packed arrays.

	# Inner face (top → bottom rows, inward normals).
	var base: int = verts.size()
	for i in range(n):
		verts.append(inner_top[i])
		verts.append(inner_bot[i])
		normals.append(inward_n[i])
		normals.append(inward_n[i])
		var u: float = float(i) / float(n)
		uvs.append(Vector2(u, 1.0))
		uvs.append(Vector2(u, 0.0))
	for i in range(n):
		var i_next: int = (i + 1) % n
		var a: int = base + i * 2
		var b: int = base + i_next * 2
		indices.append(a); indices.append(a + 1); indices.append(b + 1)
		indices.append(a); indices.append(b + 1); indices.append(b)

	# Outer face (bottom → top rows, outward normals).
	base = verts.size()
	for i in range(n):
		verts.append(outer_bot[i])
		verts.append(outer_top[i])
		normals.append(outward_n[i])
		normals.append(outward_n[i])
		var u: float = float(i) / float(n)
		uvs.append(Vector2(u, 1.0))
		uvs.append(Vector2(u, 0.0))
	for i in range(n):
		var i_next: int = (i + 1) % n
		var a: int = base + i * 2
		var b: int = base + i_next * 2
		indices.append(a); indices.append(a + 1); indices.append(b + 1)
		indices.append(a); indices.append(b + 1); indices.append(b)

	if with_top_cap:
		# Top cap (outer → inner at y_top, normal +Y).
		base = verts.size()
		for i in range(n):
			verts.append(outer_top[i])
			verts.append(inner_top[i])
			normals.append(Vector3.UP)
			normals.append(Vector3.UP)
			var u: float = float(i) / float(n)
			uvs.append(Vector2(u, 1.0))
			uvs.append(Vector2(u, 0.0))
		for i in range(n):
			var i_next: int = (i + 1) % n
			var a: int = base + i * 2
			var b: int = base + i_next * 2
			indices.append(a); indices.append(a + 1); indices.append(b + 1)
			indices.append(a); indices.append(b + 1); indices.append(b)

	if with_bottom_cap:
		# Bottom cap (inner → outer at y_bot, normal -Y).
		base = verts.size()
		for i in range(n):
			verts.append(inner_bot[i])
			verts.append(outer_bot[i])
			normals.append(Vector3.DOWN)
			normals.append(Vector3.DOWN)
			var u: float = float(i) / float(n)
			uvs.append(Vector2(u, 1.0))
			uvs.append(Vector2(u, 0.0))
		for i in range(n):
			var i_next: int = (i + 1) % n
			var a: int = base + i * 2
			var b: int = base + i_next * 2
			indices.append(a); indices.append(a + 1); indices.append(b + 1)
			indices.append(a); indices.append(b + 1); indices.append(b)

	return {"verts": verts, "normals": normals, "uvs": uvs, "indices": indices}


# Builds one visual band mesh wrapping the entire perimeter (cached; the
# material is applied per-instance by _add_band_instance).
func _perimeter_band_mesh(stations: Array,
		inner_offset: float, outer_offset: float,
		y_bot: float, y_top: float,
		with_top_cap: bool = true, with_bottom_cap: bool = true) -> ArrayMesh:
	var data: Dictionary = _emit_perimeter_band_arrays(
			stations, inner_offset, outer_offset, y_bot, y_top,
			with_top_cap, with_bottom_cap)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = data.verts
	arrays[Mesh.ARRAY_NORMAL] = data.normals
	arrays[Mesh.ARRAY_TEX_UV] = data.uvs
	arrays[Mesh.ARRAY_INDEX] = data.indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _add_band_instance(mesh: ArrayMesh, material: Material) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = material
	add_child(mi)


func _add_corner_stripe(center: Vector3, a0: float, a1: float, stripe: Dictionary) -> void:
	# Flat quad on the inner face at the arc angle where the stripe's world-Z
	# crosses the curve. Width is 2 × half_sw along the arc tangent; small enough
	# (~0.34° of arc) that flat vs curved is imperceptible.
	var sz: float = stripe["z"]
	var color: Color = stripe["color"]
	var r_face: float = corner_radius - wall_thickness / 2.0
	# Use r_face (inner face radius) instead of corner_radius when finding the
	# crossing angle: the stripe sits ON the inner face, not on the centerline,
	# so the angle where r_face·sin(a) reaches sz is what we want. With the
	# previous corner_radius-based formula, the base point ended up at a radius
	# slightly larger than r_face (i.e. embedded inside the wall) and was
	# occluded by the inner face from inside the rink.
	var s_arg: float = (sz - center.z) / r_face
	if absf(s_arg) >= 1.0:
		return
	var lo: float = minf(a0, a1)
	var hi: float = maxf(a0, a1)
	# sin(a) = s_arg has two principal solutions; offset by ±2π handles corners
	# whose arc spans live outside [-π, π] (e.g. the -x,-z corner at [π, 3π/2]).
	var a_primary: float = asin(s_arg)
	var a_secondary: float = PI - a_primary
	var a_cross: float = NAN
	for cand in [
		a_primary, a_secondary,
		a_primary - TAU, a_secondary - TAU,
		a_primary + TAU, a_secondary + TAU,
	]:
		if cand >= lo - 1e-6 and cand <= hi + 1e-6:
			a_cross = cand
			break
	if is_nan(a_cross):
		return

	var ca: float = cos(a_cross)
	var sa: float = sin(a_cross)
	var inset: float = 0.001
	# Stripe spans only the white-board band (between the kickplate lip and the
	# cap-rail lip). The base point sits 1 mm inward of the inner face so the
	# stripe renders in front of the wall instead of z-fighting against it.
	var base_pt: Vector3 = center + Vector3(
		(r_face - inset) * ca, 0.0, (r_face - inset) * sa)
	base_pt.z += board_stripe_z_nudge * signf(sz)
	var tangent: Vector3 = Vector3(-sa, 0.0, ca)
	var inward: Vector3 = Vector3(-ca, 0.0, -sa)
	# Match the ice goal line's Z extent. The ice line uses `thin_line` = 4 px
	# at 80 px/m, and _draw_h_line spans `half_t + half_t + 1` = 5 px, which
	# is 0.0625 m. The arc tangent at a_cross is not aligned with Z, so a
	# stripe of total tangent width W projects to a Z width of W · |cos(a)|.
	# Scale the tangent width up by 1/|cos(a)| so the wall stripe's Z extent
	# matches the ice line's. (Guarded against the tangent-perpendicular-to-Z
	# extreme at the corner's far end, but a_cross is well inside ±60° here.)
	# Tuned to match the perceived width of the ice goal line. The ice line
	# is nominally 6.25 cm but reads wider thanks to the ice shader's
	# parallax + subsurface fade softening its edges; a 6 cm wall stripe
	# looks too thin next to it. ~15 cm Z extent feels right.
	# (0.075 / |cos(a)| keeps Z extent constant across different a_cross.)
	var half_sw: float = 0.075 / maxf(absf(ca), 0.1)
	var y_bot: float = kickplate_height
	var y_top: float = wall_height - CAP_RAIL_HEIGHT
	var v0: Vector3 = base_pt + Vector3(-tangent.x * half_sw, y_bot, -tangent.z * half_sw)
	var v1: Vector3 = base_pt + Vector3( tangent.x * half_sw, y_bot,  tangent.z * half_sw)
	var v2: Vector3 = base_pt + Vector3( tangent.x * half_sw, y_top,  tangent.z * half_sw)
	var v3: Vector3 = base_pt + Vector3(-tangent.x * half_sw, y_top, -tangent.z * half_sw)

	var s_arrays: Array = []
	s_arrays.resize(Mesh.ARRAY_MAX)
	s_arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([v0, v1, v2, v3])
	s_arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([inward, inward, inward, inward])
	s_arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)])
	s_arrays[Mesh.ARRAY_INDEX]  = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var s_mesh := ArrayMesh.new()
	s_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, s_arrays)

	var mi := MeshInstance3D.new()
	mi.mesh = s_mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.render_priority = 1
	mi.material_override = mat
	add_child(mi)
