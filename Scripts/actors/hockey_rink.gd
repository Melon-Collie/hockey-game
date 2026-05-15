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
@export var corner_segments: int = 14:
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
@export var kickplate_gap_z_nudge: float = 0.084:
	set(v):
		kickplate_gap_z_nudge = v
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

# Kickplate protrudes this much inward from the board face toward the ice
const KICKPLATE_PROTRUSION: float = 0.01
const CAP_RAIL_HEIGHT: float = 0.05

# Texture resolution: pixels per meter
var _px_per_meter: float = 80.0

func _ready() -> void:
	_rebuild()

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
	
	# Ice collision — needs its own StaticBody3D so physics_material_override applies
	var ice_body := StaticBody3D.new()
	var phys_mat := PhysicsMaterial.new()
	phys_mat.friction = ice_friction
	phys_mat.bounce = 0.0
	ice_body.physics_material_override = phys_mat
	add_child(ice_body)

	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(rink_width, 0.01, rink_length)
	col.shape = shape
	col.position = Vector3(0, -0.005, 0)
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
			# Curved band of width `thickness` around arc_r. Hard-clip at the side
			# cap (|dx| = half_w); the side stroke covers that interior boundary,
			# so AA-fading it just produces a notch at the corner where curve meets line.
			if abs(dx) <= half_w:
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

func _kickplate_z_segments(z_start: float, z_end: float) -> Array:
	# Returns [[z0,z1], ...] covering [z_start, z_end] with gaps cut at stripe positions.
	var half_lw: float = 0.15  # half of 0.30m line width
	var cuts: Array = []
	for sz: float in [0.0, 7.29, -7.29]:
		var g0: float = sz - half_lw
		var g1: float = sz + half_lw
		if g1 > z_start and g0 < z_end:
			cuts.append([maxf(g0, z_start), minf(g1, z_end)])
	cuts.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var segs: Array = []
	var cur: float = z_start
	for gap in cuts:
		if gap[0] > cur + 0.001:
			segs.append([cur, gap[0]])
		cur = gap[1]
	if cur < z_end - 0.001:
		segs.append([cur, z_end])
	return segs

func _add_kickplate_rotated(kp_w: float, length: float, pos: Vector3, rot: float) -> void:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(kp_w, kickplate_height, length)
	mi.mesh = box
	mi.position = pos
	mi.rotation.y = rot
	var mat := StandardMaterial3D.new()
	mat.albedo_color = kickplate_color
	mi.material_override = mat
	add_child(mi)

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
	var img_w: int = maxi(int(wall_len * _px_per_meter), 1)
	var img_h: int = maxi(int(wall_height * _px_per_meter), 1)

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
		# Place quad 1 mm inside the board inner face so it's never coplanar with the board.
		var face_x: float = side * (half_w - wall_thickness / 2.0) - side * 0.001
		var z0: float = -wall_len / 2.0
		var z1: float =  wall_len / 2.0
		var norm := Vector3(-side, 0.0, 0.0)

		var verts   := PackedVector3Array([
			Vector3(face_x, 0.0,          z0),
			Vector3(face_x, 0.0,          z1),
			Vector3(face_x, wall_height,  z1),
			Vector3(face_x, wall_height,  z0),
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
	# Kickplate (yellow, bottom strip) — protrudes KICKPLATE_PROTRUSION inward.
	# Side walls are segmented to leave gaps at stripe positions.
	if size.x <= size.z:  # side wall — thickness in X
		var kp_x: float = pos.x - sign(pos.x) * KICKPLATE_PROTRUSION / 2.0
		var kp_w: float = size.x + KICKPLATE_PROTRUSION
		var z_start: float = pos.z - size.z / 2.0
		var z_end: float   = pos.z + size.z / 2.0
		for seg in _kickplate_z_segments(z_start, z_end):
			_add_kickplate_box(Vector3(kp_w, kickplate_height, seg[1] - seg[0]),
				Vector3(kp_x, kickplate_height / 2.0, (seg[0] + seg[1]) / 2.0))
	else:  # end wall — thickness in Z, one solid piece (no stripes here)
		var kp_z: float = pos.z - sign(pos.z) * KICKPLATE_PROTRUSION / 2.0
		_add_kickplate_box(Vector3(size.x, kickplate_height, size.z + KICKPLATE_PROTRUSION),
			Vector3(pos.x, kickplate_height / 2.0, kp_z))

	# Upper board (white)
	var board_h: float = size.y - kickplate_height
	var board_mi := MeshInstance3D.new()
	var board_box := BoxMesh.new()
	board_box.size = Vector3(size.x, board_h, size.z)
	board_mi.mesh = board_box
	board_mi.position = Vector3(pos.x, kickplate_height + board_h / 2.0, pos.z)
	var board_mat := StandardMaterial3D.new()
	board_mat.albedo_color = wall_color
	board_mi.material_override = board_mat
	add_child(board_mi)

	# Glass mesh sitting directly on top of the boards
	var glass_mi := MeshInstance3D.new()
	var glass_box := BoxMesh.new()
	glass_box.size = Vector3(size.x, glass_height, size.z)
	glass_mi.mesh = glass_box
	glass_mi.position = Vector3(pos.x, size.y + glass_height / 2.0, pos.z)
	glass_mi.material_override = _make_glass_material()
	add_child(glass_mi)

	# Cap rail (kickplate color, sits on top of glass)
	var cap_mi := MeshInstance3D.new()
	var cap_box := BoxMesh.new()
	cap_box.size = Vector3(size.x, CAP_RAIL_HEIGHT, size.z)
	cap_mi.mesh = cap_box
	cap_mi.position = Vector3(pos.x, size.y + CAP_RAIL_HEIGHT / 2.0, pos.z)
	var cap_mat := StandardMaterial3D.new()
	cap_mat.albedo_color = cap_rail_color
	cap_mi.material_override = cap_mat
	add_child(cap_mi)

	# Single collision covering the full board + glass height
	var total_height := size.y + glass_height
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(size.x, total_height, size.z)
	col.shape = shape
	col.position = Vector3(pos.x, total_height / 2.0, pos.z)
	add_child(col)

func _add_corner(center: Vector3, angle_start: float, angle_end: float, stripe_zs: Array = []) -> void:
	var angle_step := (angle_end - angle_start) / corner_segments
	for i in corner_segments:
		var a1 := angle_start + i * angle_step
		var a2 := angle_start + (i + 1) * angle_step

		var p1 := center + Vector3(cos(a1) * corner_radius, 0, sin(a1) * corner_radius)
		var p2 := center + Vector3(cos(a2) * corner_radius, 0, sin(a2) * corner_radius)

		var mid_xz := (p1 + p2) / 2.0
		var seg_length := p1.distance_to(p2)
		var dir := (p2 - p1).normalized()
		var rot_y := atan2(dir.x, dir.z)

		# Kickplate — split at stripe positions to leave gaps, protrudes inward
		var outward := (mid_xz - center).normalized()
		var kp_x: float = mid_xz.x - outward.x * KICKPLATE_PROTRUSION / 2.0
		var kp_z: float = mid_xz.z - outward.z * KICKPLATE_PROTRUSION / 2.0
		var kp_w: float = wall_thickness + KICKPLATE_PROTRUSION
		var crossing_t: float = -1.0
		var crossing_sz: float = 0.0
		for stripe in stripe_zs:
			var sz: float = stripe["z"]
			if (p1.z <= sz and sz <= p2.z) or (p2.z <= sz and sz <= p1.z):
				crossing_t = (sz - p1.z) / (p2.z - p1.z) if absf(p2.z - p1.z) > 0.001 else 0.5
				crossing_sz = sz
				break
		if crossing_t < 0.0:
			_add_kickplate_rotated(kp_w, seg_length, Vector3(kp_x, kickplate_height / 2.0, kp_z), rot_y)
		else:
			# Cut at Z = gap_sz ± half_gap (Z-perpendicular) so the gap aligns with
			# the board stripe and ice goal line rather than being a diagonal tangent cut.
			var half_gap: float = 0.025
			var gap_sz := crossing_sz + kickplate_gap_z_nudge * signf(crossing_sz)
			var dz: float = p2.z - p1.z
			var t_low  := clampf((gap_sz - half_gap - p1.z) / dz, 0.0, 1.0) if absf(dz) > 0.001 else crossing_t
			var t_high := clampf((gap_sz + half_gap - p1.z) / dz, 0.0, 1.0) if absf(dz) > 0.001 else crossing_t
			if t_low > t_high:
				var tmp := t_low; t_low = t_high; t_high = tmp
			var local_low  := (t_low  - 0.5) * seg_length
			var local_high := (t_high - 0.5) * seg_length
			var len1: float = local_low + seg_length / 2.0
			var len2: float = seg_length / 2.0 - local_high
			if len1 > 0.001:
				var c1: float = -seg_length / 2.0 + len1 / 2.0
				_add_kickplate_rotated(kp_w, len1,
					Vector3(kp_x + dir.x * c1, kickplate_height / 2.0, kp_z + dir.z * c1), rot_y)
			if len2 > 0.001:
				var c2: float = local_high + len2 / 2.0
				_add_kickplate_rotated(kp_w, len2,
					Vector3(kp_x + dir.x * c2, kickplate_height / 2.0, kp_z + dir.z * c2), rot_y)

		# Upper board (white)
		var board_h: float = wall_height - kickplate_height
		var board_mi := MeshInstance3D.new()
		var board_box := BoxMesh.new()
		board_box.size = Vector3(wall_thickness, board_h, seg_length)
		board_mi.mesh = board_box
		board_mi.position = Vector3(mid_xz.x, kickplate_height + board_h / 2.0, mid_xz.z)
		board_mi.rotation.y = rot_y
		var board_mat := StandardMaterial3D.new()
		board_mat.albedo_color = wall_color
		board_mi.material_override = board_mat
		add_child(board_mi)

		# Glass mesh on top of boards
		var glass_mi := MeshInstance3D.new()
		var glass_box := BoxMesh.new()
		glass_box.size = Vector3(wall_thickness, glass_height, seg_length)
		glass_mi.mesh = glass_box
		glass_mi.position = Vector3(mid_xz.x, wall_height + glass_height / 2.0, mid_xz.z)
		glass_mi.rotation.y = rot_y
		glass_mi.material_override = _make_glass_material()
		add_child(glass_mi)

		# Cap rail (kickplate color, sits on top of glass)
		var cap_mi := MeshInstance3D.new()
		var cap_box := BoxMesh.new()
		cap_box.size = Vector3(wall_thickness, CAP_RAIL_HEIGHT, seg_length)
		cap_mi.mesh = cap_box
		cap_mi.position = Vector3(mid_xz.x, wall_height + CAP_RAIL_HEIGHT / 2.0, mid_xz.z)
		cap_mi.rotation.y = rot_y
		var cap_mat := StandardMaterial3D.new()
		cap_mat.albedo_color = cap_rail_color
		cap_mi.material_override = cap_mat
		add_child(cap_mi)

		# Goal line (or other) stripes — flat ArrayMesh quad on the inner face, no depth.
		for stripe in stripe_zs:
			var sz: float = stripe["z"]
			if (p1.z <= sz and sz <= p2.z) or (p2.z <= sz and sz <= p1.z):
				var t: float = (sz - p1.z) / (p2.z - p1.z) if absf(p2.z - p1.z) > 0.001 else 0.5
				var hit := p1 + t * (p2 - p1)
				# Z-perpendicular stripe at exact goal-line Z.
				# The old tangent-aligned approach subtracted outward.z * wall_thickness/2
				# from hit.z (~9 cm at the 37° corner angle), visually offsetting the stripe
				# from the ice goal line. Using sz directly for Z and a Z-facing quad fixes that.
				var inward: float = wall_thickness / 2.0 + 0.001
				var x_base := hit.x - inward / outward.x if absf(outward.x) > 0.01 else hit.x - outward.x * inward
				var base := Vector3(x_base, 0.0, sz + board_stripe_z_nudge * signf(sz))
				var half_sw: float = 0.025
				var v0 := base + Vector3(-dir.x * half_sw, 0.0,         -dir.z * half_sw)
				var v1 := base + Vector3( dir.x * half_sw, 0.0,          dir.z * half_sw)
				var v2 := base + Vector3( dir.x * half_sw, wall_height,  dir.z * half_sw)
				var v3 := base + Vector3(-dir.x * half_sw, wall_height, -dir.z * half_sw)
				var norm_in := Vector3(-outward.x, 0.0, -outward.z)
				var s_arrays: Array = []
				s_arrays.resize(Mesh.ARRAY_MAX)
				s_arrays[Mesh.ARRAY_VERTEX]  = PackedVector3Array([v0, v1, v2, v3])
				s_arrays[Mesh.ARRAY_NORMAL]  = PackedVector3Array([norm_in, norm_in, norm_in, norm_in])
				s_arrays[Mesh.ARRAY_TEX_UV]  = PackedVector2Array([Vector2(0,1), Vector2(1,1), Vector2(1,0), Vector2(0,0)])
				s_arrays[Mesh.ARRAY_INDEX]   = PackedInt32Array([0, 1, 2, 0, 2, 3])
				var s_mesh := ArrayMesh.new()
				s_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, s_arrays)
				var stripe_mi := MeshInstance3D.new()
				stripe_mi.mesh = s_mesh
				var stripe_mat := StandardMaterial3D.new()
				stripe_mat.albedo_color = stripe["color"]
				stripe_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				stripe_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
				stripe_mat.render_priority = 1
				stripe_mi.material_override = stripe_mat
				add_child(stripe_mi)

		# Full-height collision
		var total_height := wall_height + glass_height
		var col := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(wall_thickness, total_height, seg_length)
		col.shape = shape
		col.position = Vector3(mid_xz.x, total_height / 2.0, mid_xz.z)
		col.rotation.y = rot_y
		add_child(col)
