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
@export var wall_height: float = 1.07:
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
@export var kickplate_color: Color = Color(1.0, 0.824, 0.357):
	set(v):
		kickplate_color = v
		_rebuild()
@export var cap_rail_color: Color = Color(0.0, 0.220, 0.659):
	set(v):
		cap_rail_color = v
		_rebuild()
@export var board_stripe_z_nudge: float = 0.0:
	set(v):
		board_stripe_z_nudge = v
		_rebuild()
@export var kickplate_height: float = 0.20:
	set(v):
		kickplate_height = v
		_rebuild()
@export var glass_height: float = 1.1:
	set(v):
		glass_height = v
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
@export var ice_friction: float = 0.01:
	set(v):
		ice_friction = v
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

func _ready() -> void:
	_rebuild()
	if not Engine.is_editor_hint() and _scratch_map != null:
		# period_changed emits `new_period: int`; clear() takes no args, so we
		# unbind the int — without this, Godot errors silently each emit
		# ("Expected 0 arguments, got 1") and the ice never resets.
		GameManager.period_changed.connect(_scratch_map.clear.unbind(1))

func _rebuild() -> void:
	if rink_length <= 0 or rink_width <= 0:
		return
	
	for child in get_children():
		child.queue_free()
	
	var half_l = rink_length / 2.0
	var half_w = rink_width / 2.0
	var r = corner_radius
	
	# --- Ice surface ---
	_add_ice(half_l)
	
	# --- Walls ---
	_add_wall(
		Vector3(half_w, wall_height / 2.0, 0),
		Vector3(wall_thickness, wall_height, rink_length - 2.0 * r)
	)
	_add_wall(
		Vector3(-half_w, wall_height / 2.0, 0),
		Vector3(wall_thickness, wall_height, rink_length - 2.0 * r)
	)
	_add_wall(
		Vector3(0, wall_height / 2.0, -half_l),
		Vector3(rink_width - 2.0 * r, wall_height, wall_thickness)
	)
	_add_wall(
		Vector3(0, wall_height / 2.0, half_l),
		Vector3(rink_width - 2.0 * r, wall_height, wall_thickness)
	)
	
	# Goal line Z: 3.35m from each end board — stripes painted on corner boards where the line meets them
	var goal_z: float = half_l - 3.35
	var corner_stripes: Array = [
		{"z":  goal_z, "color": red_line_color},
		{"z": -goal_z, "color": red_line_color},
	]
	_add_corner(Vector3(half_w - r, 0, -half_l + r), -PI / 2.0, 0.0, corner_stripes)
	_add_corner(Vector3(half_w - r, 0, half_l - r), 0.0, PI / 2.0, corner_stripes)
	_add_corner(Vector3(-half_w + r, 0, half_l - r), PI / 2.0, PI, corner_stripes)
	_add_corner(Vector3(-half_w + r, 0, -half_l + r), PI, 3.0 * PI / 2.0, corner_stripes)

	_add_side_board_stripes(half_w)

func _add_ice(half_l: float) -> void:
	var img_w = int(rink_width * _px_per_meter)
	var img_h = int(rink_length * _px_per_meter)
	
	var img = Image.create(img_w, img_h, false, Image.FORMAT_RGBA8)
	img.fill(ice_color)

	# Goalie creases — drawn before lines so lines render on top
	var crease_goal_z: int = int((half_l - 3.35) * _px_per_meter)
	var crease_color: Color = Color(0.392, 0.765, 0.922)  # Pantone 298
	_draw_crease_fill(img, img_w / 2.0, img_h / 2.0 - crease_goal_z, 1, crease_color)
	_draw_crease_fill(img, img_w / 2.0, img_h / 2.0 + crease_goal_z, -1, crease_color)

	# Line widths in pixels — thick (center/blue): 0.3m, thin (goal/circles): 0.05m
	var thick_line: int = int(0.3 * _px_per_meter)
	var thin_line: int  = max(int(0.05 * _px_per_meter), 2)
	
	# Helper: image coordinates
	# X axis (rink width) = image X
	# Z axis (rink length) = image Y
	# Center of rink = center of image
	
	# Center red line (at Z=0)
	_draw_h_line(img, img_h / 2.0, thick_line, red_line_color)
	
	# Blue lines (64 ft to near edge + half line width = 7.29m center on this rink)
	var blue_z = int(7.29 * _px_per_meter)
	_draw_h_line(img, img_h / 2.0 - blue_z, thick_line, blue_line_color)
	_draw_h_line(img, img_h / 2.0 + blue_z, thick_line, blue_line_color)
	
	# Goal lines (3.35m from end boards)
	var goal_z = int((half_l - 3.35) * _px_per_meter)
	_draw_h_line(img, img_h / 2.0 - goal_z, thin_line, red_line_color)
	_draw_h_line(img, img_h / 2.0 + goal_z, thin_line, red_line_color)

	# Crease arc outlines (drawn after goal lines so arcs sit on top)
	_draw_crease_arc(img, img_w / 2.0, img_h / 2.0 - goal_z, 1, thin_line, red_line_color)
	_draw_crease_arc(img, img_w / 2.0, img_h / 2.0 + goal_z, -1, thin_line, red_line_color)

	# ── Faceoff markings ─────────────────────────────────────────────────────────
	# All measurements from NHL Official Rules.
	var dot_r:    float = 0.3048 * _px_per_meter  # 2' diameter filled dot
	var circle_r: float = 4.572  * _px_per_meter  # 15' radius circle
	var ez_off_x: float = 6.7056 * _px_per_meter  # 22' from center (width)
	var ez_off_z: float = 6.096  * _px_per_meter  # 20' from goal line toward center
	var nz_off_x: float = 6.7056 * _px_per_meter  # same X as end-zone dots
	var nz_off_z: float = 1.524  * _px_per_meter  # 5' from near edge of blue line toward center

	# Center ice circle + filled dot
	_draw_circle(img, img_w / 2.0, img_h / 2.0, circle_r, thin_line, blue_line_color)
	_draw_filled_circle(img, img_w / 2.0, img_h / 2.0, dot_r, blue_line_color)

	# End-zone faceoff dots and circles
	var ez_dots: Array = [
		[img_w / 2.0 - ez_off_x, img_h / 2.0 - goal_z + ez_off_z],
		[img_w / 2.0 + ez_off_x, img_h / 2.0 - goal_z + ez_off_z],
		[img_w / 2.0 - ez_off_x, img_h / 2.0 + goal_z - ez_off_z],
		[img_w / 2.0 + ez_off_x, img_h / 2.0 + goal_z - ez_off_z],
	]
	for dot: Array in ez_dots:
		_draw_filled_circle(img, dot[0], dot[1], dot_r, red_line_color)
		_draw_circle(img, dot[0], dot[1], circle_r, thin_line, red_line_color)

	# Neutral-zone faceoff dots
	var nz_dots: Array = [
		[img_w / 2.0 - nz_off_x, img_h / 2.0 - blue_z + nz_off_z],
		[img_w / 2.0 + nz_off_x, img_h / 2.0 - blue_z + nz_off_z],
		[img_w / 2.0 - nz_off_x, img_h / 2.0 + blue_z - nz_off_z],
		[img_w / 2.0 + nz_off_x, img_h / 2.0 + blue_z - nz_off_z],
	]
	for dot: Array in nz_dots:
		_draw_filled_circle(img, dot[0], dot[1], dot_r, red_line_color)
	
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
	var phys_mat := PhysicsMaterial.new()
	phys_mat.friction = ice_friction
	phys_mat.bounce = 0.0
	ice_body.physics_material_override = phys_mat
	add_child(ice_body)

	# Ice collision: 0.1 m thick (top at y=0). Thicker than the visible mesh
	# costs nothing and avoids potential edge cases (CCD / contact normals)
	# that can happen with very thin collision volumes.
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(rink_width, 0.1, rink_length)
	col.shape = shape
	col.position = Vector3(0, -0.05, 0)
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

func _add_kickplate_box(kp_size: Vector3, kp_pos: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = kp_size
	mi.mesh = box
	mi.position = kp_pos
	var mat := StandardMaterial3D.new()
	mat.albedo_color = kickplate_color
	mi.material_override = mat
	add_child(mi)

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
	var bx: float = 7.29 * _px_per_meter
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

func _add_wall(pos: Vector3, size: Vector3) -> void:
	# Stack (bottom to top):
	#   y=0                                → y=kickplate_height                       kickplate lip
	#   y=kickplate_height                 → y=wall_height - CAP_RAIL_HEIGHT          white board
	#   y=wall_height - CAP_RAIL_HEIGHT    → y=wall_height                            cap-rail lip
	#   y=wall_height                      → y=wall_height + glass_height             glass
	# The kickplate and cap rail are slightly wider than the board on both sides
	# (inward toward the rink, outward toward the stands) so each forms a small
	# visible lip — what gives the boards their stacked-band silhouette.
	var board_top: float = size.y - CAP_RAIL_HEIGHT
	var board_h: float = board_top - kickplate_height
	var is_side_wall: bool = size.x <= size.z

	# Kickplate (yellow lip) — full-length single box; no longer cut at stripe
	# positions because the stripe decals now live only in the board zone above.
	var kp_size: Vector3
	if is_side_wall:
		kp_size = Vector3(size.x + 2.0 * KICKPLATE_PROTRUSION, kickplate_height, size.z)
	else:
		kp_size = Vector3(size.x, kickplate_height, size.z + 2.0 * KICKPLATE_PROTRUSION)
	_add_kickplate_box(kp_size, Vector3(pos.x, kickplate_height / 2.0, pos.z))

	# White board (clean slab between the two lips)
	var board_mi := MeshInstance3D.new()
	var board_box := BoxMesh.new()
	board_box.size = Vector3(size.x, board_h, size.z)
	board_mi.mesh = board_box
	board_mi.position = Vector3(pos.x, kickplate_height + board_h / 2.0, pos.z)
	var board_mat := StandardMaterial3D.new()
	board_mat.albedo_color = wall_color
	board_mi.material_override = board_mat
	add_child(board_mi)

	# Cap rail (blue lip) — sits at the very top of the boards where they meet
	# the glass. Wider than the board on both sides, like the kickplate.
	var cap_mi := MeshInstance3D.new()
	var cap_box := BoxMesh.new()
	if is_side_wall:
		cap_box.size = Vector3(size.x + 2.0 * CAP_RAIL_PROTRUSION, CAP_RAIL_HEIGHT, size.z)
	else:
		cap_box.size = Vector3(size.x, CAP_RAIL_HEIGHT, size.z + 2.0 * CAP_RAIL_PROTRUSION)
	cap_mi.mesh = cap_box
	cap_mi.position = Vector3(pos.x, board_top + CAP_RAIL_HEIGHT / 2.0, pos.z)
	var cap_mat := StandardMaterial3D.new()
	cap_mat.albedo_color = cap_rail_color
	cap_mi.material_override = cap_mat
	add_child(cap_mi)

	# Glass sits directly on top of the cap rail (which marks the top of the
	# boards). Same wall_thickness as the board so it's inset from the cap-rail
	# lip — that inset is exactly the visible top of the cap rail.
	var glass_mi := MeshInstance3D.new()
	var glass_box := BoxMesh.new()
	glass_box.size = Vector3(size.x, glass_height, size.z)
	glass_mi.mesh = glass_box
	glass_mi.position = Vector3(pos.x, size.y + glass_height / 2.0, pos.z)
	glass_mi.material_override = _make_glass_material()
	add_child(glass_mi)

	# Single collision covering the full board + glass height
	var total_height := size.y + glass_height
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(size.x, total_height, size.z)
	col.shape = shape
	col.position = Vector3(pos.x, total_height / 2.0, pos.z)
	add_child(col)

func _add_corner(center: Vector3, angle_start: float, angle_end: float, stripe_zs: Array = []) -> void:
	# One ArrayMesh per band (kickplate / board / cap rail / glass) wrapping
	# continuously around the arc, plus one ConcavePolygonShape3D for collision.
	# Same band stack as the straight walls (see _add_wall): kickplate and cap
	# rail are wider than the board on both sides (forming inward and outward
	# lips), with the white board as a narrower slab between them.
	var r_in: float      = corner_radius - wall_thickness / 2.0
	var r_out: float     = corner_radius + wall_thickness / 2.0
	var r_in_kick: float = r_in - KICKPLATE_PROTRUSION
	var r_out_kick: float = r_out + KICKPLATE_PROTRUSION
	var r_in_cap: float  = r_in - CAP_RAIL_PROTRUSION
	var r_out_cap: float = r_out + CAP_RAIL_PROTRUSION
	var board_top: float = wall_height - CAP_RAIL_HEIGHT
	var rail_top: float  = wall_height
	var glass_top: float = wall_height + glass_height

	# Kickplate ring (yellow lip)
	_add_corner_ring(center, angle_start, angle_end, r_in_kick, r_out_kick,
		0.0, kickplate_height, _make_solid_material(kickplate_color))
	# White board ring — caps hidden by kickplate (below) and cap rail (above),
	# so skip both to avoid coplanar z-fight against those lips' caps.
	_add_corner_ring(center, angle_start, angle_end, r_in, r_out,
		kickplate_height, board_top, _make_solid_material(wall_color), false, false)
	# Cap rail ring (blue lip)
	_add_corner_ring(center, angle_start, angle_end, r_in_cap, r_out_cap,
		board_top, rail_top, _make_solid_material(cap_rail_color))
	# Glass — skip bottom cap so it doesn't z-fight the opaque cap-rail top cap
	# at y=rail_top (glass is double-sided transparent, so both cap faces would
	# render coplanar at that height).
	_add_corner_ring(center, angle_start, angle_end, r_in, r_out,
		rail_top, glass_top, _make_glass_material(), true, false)

	for stripe in stripe_zs:
		_add_corner_stripe(center, angle_start, angle_end, stripe)

	_add_corner_collision(center, angle_start, angle_end, r_in, r_out, 0.0, glass_top)

func _make_solid_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	return mat

func _add_corner_ring(center: Vector3, a0: float, a1: float,
		r_in: float, r_out: float, y_bot: float, y_top: float,
		material: Material, with_top_cap: bool = true,
		with_bottom_cap: bool = true) -> void:
	# Build the four point rows around the arc — inner/outer × bottom/top —
	# plus per-vertex radial normals for the curved faces.
	var n: int = corner_segments
	var step: float = (a1 - a0) / float(n)
	var ib := PackedVector3Array(); ib.resize(n + 1)
	var it := PackedVector3Array(); it.resize(n + 1)
	var ob := PackedVector3Array(); ob.resize(n + 1)
	var ot := PackedVector3Array(); ot.resize(n + 1)
	var n_in := PackedVector3Array();  n_in.resize(n + 1)
	var n_out := PackedVector3Array(); n_out.resize(n + 1)
	for i in range(n + 1):
		var a: float = a0 + i * step
		var ca: float = cos(a)
		var sa: float = sin(a)
		ib[i] = Vector3(center.x + r_in  * ca, y_bot, center.z + r_in  * sa)
		it[i] = Vector3(center.x + r_in  * ca, y_top, center.z + r_in  * sa)
		ob[i] = Vector3(center.x + r_out * ca, y_bot, center.z + r_out * sa)
		ot[i] = Vector3(center.x + r_out * ca, y_top, center.z + r_out * sa)
		n_in[i]  = Vector3(-ca, 0.0, -sa)
		n_out[i] = Vector3( ca, 0.0,  sa)

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	# Row pairs are ordered so the emitted quad (row_a[i], row_b[i], row_b[i+1],
	# row_a[i+1]) winds CCW when viewed from the face's outward-normal side. All
	# call sites pass increasing angles, so this ordering is consistent across
	# the four corners.
	_emit_arc_strip(verts, normals, uvs, indices, it, ib, n_in)              # inner face (toward rink center)
	_emit_arc_strip(verts, normals, uvs, indices, ob, ot, n_out)             # outer face
	if with_top_cap:
		_emit_arc_strip_flat(verts, normals, uvs, indices, ot, it, Vector3.UP)   # top cap
	if with_bottom_cap:
		_emit_arc_strip_flat(verts, normals, uvs, indices, ib, ob, Vector3.DOWN) # bottom cap

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX]  = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = material
	add_child(mi)

func _emit_arc_strip(verts: PackedVector3Array, normals: PackedVector3Array,
		uvs: PackedVector2Array, indices: PackedInt32Array,
		row_a: PackedVector3Array, row_b: PackedVector3Array,
		per_vert_normals: PackedVector3Array) -> void:
	var base: int = verts.size()
	var n: int = row_a.size()
	for i in range(n):
		verts.append(row_a[i])
		verts.append(row_b[i])
		normals.append(per_vert_normals[i])
		normals.append(per_vert_normals[i])
		var u: float = float(i) / float(n - 1)
		uvs.append(Vector2(u, 1.0))
		uvs.append(Vector2(u, 0.0))
	for i in range(n - 1):
		var a: int = base + i * 2
		var b: int = base + (i + 1) * 2
		indices.append(a); indices.append(a + 1); indices.append(b + 1)
		indices.append(a); indices.append(b + 1); indices.append(b)

func _emit_arc_strip_flat(verts: PackedVector3Array, normals: PackedVector3Array,
		uvs: PackedVector2Array, indices: PackedInt32Array,
		row_a: PackedVector3Array, row_b: PackedVector3Array,
		normal: Vector3) -> void:
	var base: int = verts.size()
	var n: int = row_a.size()
	for i in range(n):
		verts.append(row_a[i])
		verts.append(row_b[i])
		normals.append(normal)
		normals.append(normal)
		var u: float = float(i) / float(n - 1)
		uvs.append(Vector2(u, 1.0))
		uvs.append(Vector2(u, 0.0))
	for i in range(n - 1):
		var a: int = base + i * 2
		var b: int = base + (i + 1) * 2
		indices.append(a); indices.append(a + 1); indices.append(b + 1)
		indices.append(a); indices.append(b + 1); indices.append(b)

func _add_corner_stripe(center: Vector3, a0: float, a1: float, stripe: Dictionary) -> void:
	# Flat quad on the inner face at the arc angle where the stripe's world-Z
	# crosses the curve. Width is 2 × half_sw along the arc tangent; small enough
	# (~0.34° of arc) that flat vs curved is imperceptible.
	var sz: float = stripe["z"]
	var color: Color = stripe["color"]
	var s_arg: float = (sz - center.z) / corner_radius
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
	var r_face: float = corner_radius - wall_thickness / 2.0
	var inset: float = 0.001
	# Stripe spans only the white-board band (between the kickplate lip and the
	# cap-rail lip). The lips protrude inward of r_face, so a stripe drawn at
	# r_face - 0.001 would be occluded by them — keeping the stripe inside the
	# board zone keeps it visible without splitting into multiple quads.
	var base_pt: Vector3 = center + Vector3(
		(r_face - inset) * ca, 0.0, (r_face - inset) * sa)
	base_pt.z = sz + board_stripe_z_nudge * signf(sz)
	var tangent: Vector3 = Vector3(-sa, 0.0, ca)
	var inward: Vector3 = Vector3(-ca, 0.0, -sa)
	var half_sw: float = 0.025
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

func _add_corner_collision(center: Vector3, a0: float, a1: float,
		r_in: float, r_out: float, y_bot: float, y_top: float) -> void:
	# Single ConcavePolygonShape3D wrapping the corner. With one collider per
	# corner (instead of N boxes), corner_segments is now purely a visual knob —
	# physics is the same regardless. End caps are omitted because the adjacent
	# straight walls' box colliders butt up against them.
	var n: int = corner_segments
	var step: float = (a1 - a0) / float(n)
	var ib: Array[Vector3] = []; ib.resize(n + 1)
	var it: Array[Vector3] = []; it.resize(n + 1)
	var ob: Array[Vector3] = []; ob.resize(n + 1)
	var ot: Array[Vector3] = []; ot.resize(n + 1)
	for i in range(n + 1):
		var a: float = a0 + i * step
		var ca: float = cos(a)
		var sa: float = sin(a)
		ib[i] = Vector3(center.x + r_in  * ca, y_bot, center.z + r_in  * sa)
		it[i] = Vector3(center.x + r_in  * ca, y_top, center.z + r_in  * sa)
		ob[i] = Vector3(center.x + r_out * ca, y_bot, center.z + r_out * sa)
		ot[i] = Vector3(center.x + r_out * ca, y_top, center.z + r_out * sa)

	var tris := PackedVector3Array()
	for i in range(n):
		# Inner face — front toward rink center
		tris.append(it[i]); tris.append(ib[i]);   tris.append(ib[i + 1])
		tris.append(it[i]); tris.append(ib[i + 1]); tris.append(it[i + 1])
		# Outer face
		tris.append(ob[i]); tris.append(ot[i]);   tris.append(ot[i + 1])
		tris.append(ob[i]); tris.append(ot[i + 1]); tris.append(ob[i + 1])
		# Top cap
		tris.append(ot[i]); tris.append(it[i]);   tris.append(it[i + 1])
		tris.append(ot[i]); tris.append(it[i + 1]); tris.append(ot[i + 1])
		# Bottom cap
		tris.append(ib[i]); tris.append(ob[i]);   tris.append(ob[i + 1])
		tris.append(ib[i]); tris.append(ob[i + 1]); tris.append(ib[i + 1])

	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(tris)
	# Backface collision makes the mesh act solid from either side. Without
	# this, a puck that ends up on the back of a triangle (e.g. CCD glance,
	# reconcile-loop nudge, or numerical penetration) passes through outward
	# and OOBs instead of being pushed back into the rink.
	shape.backface_collision = true
	var col := CollisionShape3D.new()
	col.shape = shape
	add_child(col)
