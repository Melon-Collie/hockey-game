@tool
class_name HockeyRink
extends StaticBody3D

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
# Collision tessellation runs independently of the visual mesh. The puck slides
# along the inner face of a triangulated arc, and every facet transition leaks
# a sliver of energy through bounce restitution (puck velocity isn't tangent
# to the next facet's normal). Energy retained per corner ≈ exp(-(1-e²)·π²/(4N))
# for restitution e and N segments — at N=256 with e=0.4 the restitution loss
# per corner is under 1%. Visual mesh stays at corner_segments for cheap rendering.
#
# Restitution is only half the corner-loss story, and NOT the half that made
# rim-arounds feel dead: the puck also slides the curve under sustained normal
# (centripetal) load, so board FRICTION bleeds tangential speed capstan-style —
# retained speed ≈ exp(-μ·π/2) per 90° corner, independent of N (tessellation
# fixes only the restitution facet loss above). At the engine-default μ≈1.0 a
# rim shed ~80% of its speed per corner, and even the first corrected value
# (0.3) still shed ~38%. Physics/boards.tres now sets μ=0.15 — real dasher
# facing is HDPE/UHMW sheet, chosen for exactly this slickness (rubber-on-
# polyethylene kinetic μ ≈ 0.1–0.2) — so a hard rim keeps ~79% of its pace per
# corner, the classic rim-around. Tune the rim feel there, not by raising
# segment count.
@export var corner_collision_segments: int = 256:
	set(v):
		corner_collision_segments = v
		_rebuild()
@export var wall_color: Color = Color(0.95, 0.95, 0.95):
	set(v):
		wall_color = v
		_rebuild()
@export_range(0.0, 2.0) var wall_emission_energy: float = 0.0:
	set(v):
		wall_emission_energy = v
		_rebuild()
@export var kickplate_color: Color = Color(1.0, 0.824, 0.357):
	set(v):
		kickplate_color = v
		_rebuild()
@export_range(0.0, 2.0) var kickplate_emission_energy: float = 0.0:
	set(v):
		kickplate_emission_energy = v
		_rebuild()
@export var cap_rail_color: Color = Color(0.0, 0.220, 0.659):
	set(v):
		cap_rail_color = v
		_rebuild()
@export_range(0.0, 2.0) var cap_rail_emission_energy: float = 0.0:
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
@export_range(0.0, 1.0) var ice_roughness_head_on: float = 0.20:
	set(v):
		ice_roughness_head_on = v
		_rebuild()
@export_range(0.0, 1.0) var ice_roughness_grazing: float = 0.04:
	set(v):
		ice_roughness_grazing = v
		_rebuild()
@export_group("")
@export var rebuild: bool = false:
	set(v):
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
# Collision-only perimeter height. Must stay above the puck's vertical clamp
# (Puck.max_height 3.0 + ice half-height 0.0125 ≈ 3.01 m) so an elevated
# deflection that pegs the clamp can't slip over the visible glass and out of the
# rink. Purely a collider extent — the glass mesh stops at glass_y_top.
const COLLISION_OVERGLASS_TOP: float = 3.2
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

# Texture resolution: pixels per meter
var _px_per_meter: float = 80.0

# Persistent skate-scratch overlay. Created at runtime only (not in editor)
# and bound to the ice shader's scratch_tex.
var _scratch_map: IceScratchMap = null
# The center-ice decal SubViewport and the ice material, held so exit teardown
# can release the ViewportTexture shader bindings and free the render targets
# before the RenderingServer is finalized — see _teardown_render_targets().
var _decal_vp: SubViewport = null
var _ice_material: ShaderMaterial = null
var _render_targets_freed: bool = false

func _ready() -> void:
	# Boards live on their own collision layer (puck masks it, skaters don't) so a
	# skater CharacterBody cylinder never wedges in the concave corner mesh; the
	# skater is held inside the rink analytically instead. See Constants.LAYER_BOARDS.
	collision_layer = Constants.LAYER_BOARDS
	_rebuild()
	if not Engine.is_editor_hint() and _scratch_map != null:
		# period_synced emits `new_period: int`; clear() takes no args, so we
		# unbind the int — without this, Godot errors silently each emit
		# ("Expected 0 arguments, got 1") and the ice never resets.
		GameManager.period_synced.connect(_scratch_map.clear.unbind(1))

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
	_ice_material = null
	if is_instance_valid(_scratch_map):
		_scratch_map.free()
	_scratch_map = null
	if is_instance_valid(_decal_vp):
		_decal_vp.free()
	_decal_vp = null

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

	# --- Ice surface ---
	_add_ice()

	# --- Walls (continuous mesh around the entire perimeter) ---
	# Previously the four straight walls were BoxMesh / BoxShape3D and the four
	# corners were separate ArrayMesh / ConcavePolygonShape3D rings. The seam
	# between them produced both visual (flat-vs-smooth shading) and physical
	# (contact-normal kink) artifacts. Merging into one continuous loop per
	# band eliminates every seam.
	var stations: Array = _build_perimeter_stations(corner_segments)

	var board_top: float = wall_height - CAP_RAIL_HEIGHT
	var rail_top: float = wall_height
	var glass_y_bot: float = rail_top + GLASS_LIFT
	var glass_y_top: float = glass_y_bot + glass_height

	var board_half_thick: float = wall_thickness / 2.0
	var kick_half_thick: float = board_half_thick + KICKPLATE_PROTRUSION
	var cap_half_thick: float = board_half_thick + CAP_RAIL_PROTRUSION
	var glass_half_thick: float = glass_thickness / 2.0

	# Solid bands use cull_disabled — the ArrayMesh inner face is otherwise
	# culled by Godot's renderer even though the world-space winding looks
	# correct on paper. BoxMesh works because its vertex order compensates.
	var kp_mat: StandardMaterial3D = _make_solid_material(kickplate_color, kickplate_emission_energy)
	kp_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var board_mat: StandardMaterial3D = _make_solid_material(wall_color, wall_emission_energy)
	board_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var cap_mat: StandardMaterial3D = _make_solid_material(cap_rail_color, cap_rail_emission_energy)
	cap_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	# Kickplate (yellow lip with full caps — top cap forms the inward and
	# outward shelves, bottom cap closes the volume). Bottom recessed below
	# the ice plane to avoid coplanar z-fight (see KICKPLATE_ICE_OFFSET).
	_add_perimeter_band(stations, kick_half_thick, kick_half_thick,
			-KICKPLATE_ICE_OFFSET, kickplate_height, kp_mat)
	# White board — top and bottom faces are covered by the kickplate's top
	# cap and the cap rail's bottom cap, so skip its caps to avoid coplanar
	# z-fight with those lips.
	_add_perimeter_band(stations, board_half_thick, board_half_thick,
			kickplate_height, board_top, board_mat, false, false)
	# Cap rail (blue lip).
	_add_perimeter_band(stations, cap_half_thick, cap_half_thick,
			board_top, rail_top, cap_mat)
	# Glass — transparent, narrower than the boards, lifted by GLASS_LIFT so
	# its bottom cap doesn't z-fight the cap rail's top.
	_add_perimeter_band(stations, glass_half_thick, glass_half_thick,
			glass_y_bot, glass_y_top, _make_glass_material())

	# Single collision around the entire perimeter. Replaces the BoxShape3D /
	# ConcavePolygonShape3D pair that previously caught fast pucks at the
	# straight↔corner seam. Collision uses its own (much higher) corner
	# tessellation so rim-around contact loss stays under 1% per corner.
	#
	# The INNER face sits at the kickplate lip (kick_half_thick), the innermost
	# visible surface, so the puck stops at what the player sees instead of
	# sinking 1 cm into the kickplate against the boards' face. This is the same
	# surface the blade clamp, AI trajectory reflection, and puck-OOB check use
	# (GameRules.INNER_* / KICKPLATE_INWARD_LIP — keep them in sync).
	#
	# The collision extends ABOVE the visible glass (glass_y_top ≈ 2.90 m) up to
	# COLLISION_OVERGLASS_TOP: the puck's vertical clamp (Puck.max_height + its
	# ice half-height ≈ 3.01 m) sits above the glass, so without this an elevated
	# deflection that pegs the clamp cruised through the gap between the glass top
	# and the clamp and escaped the rink. Collision-only — the visual glass stays
	# at glass_y_top. Keep COLLISION_OVERGLASS_TOP comfortably above Puck.max_height.
	var collision_stations: Array = _build_perimeter_stations(corner_collision_segments)
	_add_perimeter_collision(collision_stations, kick_half_thick, board_half_thick,
			0.0, maxf(glass_y_top, COLLISION_OVERGLASS_TOP))

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

	_add_side_board_stripes(half_w)


func _add_ice() -> void:
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

	# Create texture
	var tex = ImageTexture.create_from_image(img)

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

	# Ice collision — needs its own StaticBody3D so physics_material_override applies
	var ice_body := StaticBody3D.new()
	# Ice stays on LAYER_WALLS (skaters + puck both collide with it). Only the
	# perimeter boards move to LAYER_BOARDS; the ice is a flat slab and never
	# produces the concave-corner crease that wedged the skater.
	ice_body.collision_layer = Constants.LAYER_WALLS
	# Single source of truth: the live ice friction the host simulates IS
	# GameRules.ICE_FRICTION (realistic puck-on-ice μ ~0.05). The AI/client
	# prediction model reads the same constant, so the two can never drift — no
	# hand-sync, no ice .tres. (Puck-on-ice glide only; boards own the rim feel.)
	var phys_mat := PhysicsMaterial.new()
	phys_mat.friction = GameRules.ICE_FRICTION
	phys_mat.bounce = 0.0
	ice_body.physics_material_override = phys_mat
	add_child(ice_body)

	# Ice collision: a deep slab, top face at y=0. Depth matters — a flat-bottomed
	# body resting flush on a *thin* slab generates contacts against BOTH faces
	# (the collision margin spans the volume), so a skater on the ice picked up an
	# opposing +Y/-Y normal pair. Harmless on open ice (Y is axis-locked), but in
	# a corner those two verticals plus the wall normal leave move_and_slide no
	# free direction and the skater freezes against the boards. A 2 m slab keeps
	# the bottom face far below any body resting on the surface, so only the +Y
	# top contact is ever generated. Invisible and free (nothing lives below y=0).
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(rink_width, 2.0, rink_length)
	col.shape = shape
	col.position = Vector3(0, -1.0, 0)
	ice_body.add_child(col)

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

func _add_side_board_stripes(half_w: float) -> void:
	# Paint center red line and blue zone lines as a texture on the inner board face,
	# identical to how rink ice lines are drawn — no physical depth, no z-fighting.
	var wall_len: float = rink_length - 2.0 * corner_radius
	var y_bot: float = kickplate_height
	var y_top: float = wall_height - CAP_RAIL_HEIGHT
	var band_h: float = y_top - y_bot
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

	var tex := ImageTexture.create_from_image(img)

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


# Builds and adds one visual band wrapping the entire perimeter.
func _add_perimeter_band(stations: Array,
		inner_offset: float, outer_offset: float,
		y_bot: float, y_top: float, material: Material,
		with_top_cap: bool = true, with_bottom_cap: bool = true) -> void:
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
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = material
	add_child(mi)


# Builds and adds a single ConcavePolygonShape3D wrapping the entire wall.
# inner_offset is the kickplate's half-thickness so the collision's inner face
# sits at the kickplate lip (the innermost visible surface); outer_offset is
# the boards' wall_thickness/2 (the outer board face).
func _add_perimeter_collision(stations: Array,
		inner_offset: float, outer_offset: float,
		y_bot: float, y_top: float) -> void:
	var data: Dictionary = _emit_perimeter_band_arrays(
			stations, inner_offset, outer_offset, y_bot, y_top, true, true)
	var tris := PackedVector3Array()
	var idx: PackedInt32Array = data.indices
	var verts: PackedVector3Array = data.verts
	for j in range(0, idx.size(), 3):
		tris.append(verts[idx[j]])
		tris.append(verts[idx[j + 1]])
		tris.append(verts[idx[j + 2]])
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(tris)
	# Backface collision so a puck that ends up on the wrong side of a
	# triangle (CCD glance, reconcile nudge, numerical penetration) still
	# generates contacts instead of falling through the band unopposed. Note
	# this is best-effort, not a guarantee: the triangles are zero-thickness
	# surfaces, so once a sliding puck's center crosses a facet plane the
	# nearest-side depenetration can just as well push it OUTWARD. The hard
	# containment guarantee is analytic — Puck._integrate_forces clamps any
	# escaped puck back inside GameRules.clamp_to_rink_inner (the same
	# boundary this collider is built on) and reflects its outward velocity.
	shape.backface_collision = true
	var col := CollisionShape3D.new()
	col.shape = shape
	add_child(col)


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
