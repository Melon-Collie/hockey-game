class_name SkaterUniformCoordinator
extends RefCounted

var _skater: Skater
var _upper_body_mesh: MeshInstance3D
var _blade_mesh: MeshInstance3D
var _helmet: MeshInstance3D
var _shoulder_l: MeshInstance3D
var _shoulder_r: MeshInstance3D
var _hip_l: MeshInstance3D
var _hip_r: MeshInstance3D
var _thigh_l: MeshInstance3D
var _thigh_r: MeshInstance3D
var _knee_l: MeshInstance3D
var _knee_r: MeshInstance3D
var _sock_l: MeshInstance3D
var _sock_r: MeshInstance3D
var _skate_l: MeshInstance3D
var _skate_r: MeshInstance3D
var _foot_l: MeshInstance3D
var _foot_r: MeshInstance3D

# Cached jersey inputs. The torso material samples a SubViewport that draws
# all of these in one pass (see JerseyDecal); each apply_* function stores
# its relevant fields and bumps the viewport's update mode so the texture
# refreshes on the next frame.
var _jersey_color: Color = Color.WHITE
var _jersey_stripe_color: Color = Color.BLACK
var _pants_color: Color = Color.WHITE
var _socks_color: Color = Color.WHITE
var _player_name: String = ""
var _jersey_number: int = 0
var _text_color: Color = Color.BLACK
var _text_outline_color: Color = Color.BLACK
var _jersey_viewport: SubViewport
var _jersey_decal: JerseyDecal
var _shoulder_viewport: SubViewport
var _shoulder_decal: ShoulderDecal


func setup(skater: Skater) -> void:
	_skater = skater
	_upper_body_mesh = skater.upper_body.get_node("UpperBodyMesh") as MeshInstance3D
	_blade_mesh = skater.blade.get_node("MeshInstance3D") as MeshInstance3D
	_helmet = skater.upper_body.get_node("Helmet") as MeshInstance3D
	_shoulder_l = skater.upper_body.get_node("ShoulderL") as MeshInstance3D
	_shoulder_r = skater.upper_body.get_node("ShoulderR") as MeshInstance3D
	_hip_l = skater.lower_body.get_node("HipL") as MeshInstance3D
	_hip_r = skater.lower_body.get_node("HipR") as MeshInstance3D
	_thigh_l = skater.lower_body.get_node("ThighL") as MeshInstance3D
	_thigh_r = skater.lower_body.get_node("ThighR") as MeshInstance3D
	_knee_l = skater.lower_body.get_node("KneeL") as MeshInstance3D
	_knee_r = skater.lower_body.get_node("KneeR") as MeshInstance3D
	_sock_l = skater.lower_body.get_node("SockL") as MeshInstance3D
	_sock_r = skater.lower_body.get_node("SockR") as MeshInstance3D
	_skate_l = skater.lower_body.get_node("SkateL") as MeshInstance3D
	_skate_r = skater.lower_body.get_node("SkateR") as MeshInstance3D
	_foot_l = skater.lower_body.get_node("FootL") as MeshInstance3D
	_foot_r = skater.lower_body.get_node("FootR") as MeshInstance3D
	_create_jersey_viewport()
	_create_shoulder_viewport()


# Spawns the SubViewport + JerseyDecal child that renders the procedural
# jersey texture, and points the torso material at the viewport's texture.
# Once set up, _rebuild_jersey_texture() just refreshes the decal and
# bumps the viewport update mode — the material is never recreated, so
# ghost-mode transparency and other material state survive team swaps.
#
# Matches the SubViewport pattern used by HockeyRink for its center-ice
# decals: 2D-only, no input, render-on-demand.
func _create_jersey_viewport() -> void:
	_jersey_viewport = SubViewport.new()
	_jersey_viewport.name = "JerseyViewport"
	_jersey_viewport.size = Vector2i(JerseyDecal.IMG_W, JerseyDecal.IMG_H)
	_jersey_viewport.transparent_bg = false
	_jersey_viewport.disable_3d = true
	_jersey_viewport.handle_input_locally = false
	_jersey_viewport.gui_disable_input = true
	_jersey_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_skater.add_child(_jersey_viewport)

	_jersey_decal = JerseyDecal.new()
	_jersey_decal.name = "JerseyDecal"
	_jersey_viewport.add_child(_jersey_decal)

	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _jersey_viewport.get_texture()
	# uv1_offset.x = 0.25 rotates the wrap 90° around the cylinder so the
	# texture's back-center (texel x=128) lands at the skater's +Z (the
	# back). Godot's CylinderMesh starts U=0 at +Z and increases CCW.
	# V mapping is identity — Godot's cylinder side uses roughly the top
	# half of V (cap disks use the bottom half), so JerseyDecal keeps
	# all visible content in that range; see JerseyDecal.SIDE_V_MAX_PX.
	mat.uv1_offset = Vector3(0.25, 0.0, 0.0)
	_upper_body_mesh.material_override = mat


# Spawns a small SubViewport + ShoulderDecal shared by both shoulder
# spheres. Godot's SphereMesh starts U=0 at +Z and increases CCW, so the
# number drawn at texture-U=0.5 lands at sphere-U=0.5 (-Z = front) by
# default; per-shoulder uv1_offset.x rotates the wrap a quarter turn each
# way so the number faces outward (-X on left, +X on right).
func _create_shoulder_viewport() -> void:
	_shoulder_viewport = SubViewport.new()
	_shoulder_viewport.name = "ShoulderViewport"
	_shoulder_viewport.size = Vector2i(ShoulderDecal.IMG_W, ShoulderDecal.IMG_H)
	_shoulder_viewport.transparent_bg = false
	_shoulder_viewport.disable_3d = true
	_shoulder_viewport.handle_input_locally = false
	_shoulder_viewport.gui_disable_input = true
	_shoulder_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_skater.add_child(_shoulder_viewport)

	_shoulder_decal = ShoulderDecal.new()
	_shoulder_decal.name = "ShoulderDecal"
	_shoulder_viewport.add_child(_shoulder_decal)

	var tex: ViewportTexture = _shoulder_viewport.get_texture()
	var mat_l := StandardMaterial3D.new()
	mat_l.albedo_texture = tex
	mat_l.uv1_offset = Vector3(-0.25, 0.0, 0.0)  # rotate so number at sphere -X
	_shoulder_l.material_override = mat_l
	var mat_r := StandardMaterial3D.new()
	mat_r.albedo_texture = tex
	mat_r.uv1_offset = Vector3(0.25, 0.0, 0.0)   # rotate so number at sphere +X
	_shoulder_r.material_override = mat_r


func apply_colors(
		jersey_color: Color,
		helmet_color: Color,
		pants_color: Color,
		socks_color: Color,
		blade_color: Color,
		gloves_color: Color) -> void:
	_jersey_color = jersey_color
	_pants_color = pants_color
	_socks_color = socks_color
	_rebuild_jersey_texture()
	_rebuild_shoulder_texture()
	var jersey_mat: StandardMaterial3D = _make_solid_mat(jersey_color)
	var pants_mat: StandardMaterial3D = _make_solid_mat(pants_color)
	var socks_mat: StandardMaterial3D = _make_solid_mat(socks_color)
	var gloves_mat: StandardMaterial3D = _make_solid_mat(gloves_color)
	var skate_mat: StandardMaterial3D = _make_solid_mat(Color(0.08, 0.08, 0.08))
	# Torso and shoulders use procedural textures from their viewports
	# (jersey/shoulder rebuilds above); jersey_mat is still applied to the
	# arm bones so the uniform reads consistently across the upper body.
	_blade_mesh.material_override = _make_solid_mat(blade_color)
	_set_bone_material(_skater.upper_arm_mesh, jersey_mat)
	_set_bone_material(_skater.forearm_mesh, jersey_mat)
	_set_bone_material(_skater.bottom_upper_arm_mesh, jersey_mat)
	_set_bone_material(_skater.bottom_forearm_mesh, jersey_mat)
	# Elbow spheres get re-painted in apply_stripes() with jersey_stripe_color
	# (the user-facing accent stripe lives at the elbow). Default to jersey
	# here so they're never blank during a brief window before stripes apply.
	if _skater.top_elbow_sphere != null:
		_skater.top_elbow_sphere.material_override = jersey_mat.duplicate()
	if _skater.bottom_elbow_sphere != null:
		_skater.bottom_elbow_sphere.material_override = jersey_mat.duplicate()
	# Hand spheres represent the back-of-hand part of the glove.
	if _skater.top_hand_sphere != null:
		_skater.top_hand_sphere.material_override = gloves_mat.duplicate()
	if _skater.bottom_hand_sphere != null:
		_skater.bottom_hand_sphere.material_override = gloves_mat.duplicate()
	_helmet.material_override = _make_solid_mat(helmet_color)
	_hip_l.material_override = pants_mat.duplicate()
	_hip_r.material_override = pants_mat.duplicate()
	_thigh_l.material_override = pants_mat.duplicate()
	_thigh_r.material_override = pants_mat.duplicate()
	_knee_l.material_override = pants_mat.duplicate()
	_knee_r.material_override = pants_mat.duplicate()
	_sock_l.material_override = socks_mat.duplicate()
	_sock_r.material_override = socks_mat.duplicate()
	_skate_l.material_override = skate_mat.duplicate()
	_skate_r.material_override = skate_mat.duplicate()
	_foot_l.material_override = skate_mat.duplicate()
	_foot_r.material_override = skate_mat.duplicate()
	# Fixed colors — set explicitly so ghost mode never creates a blank gray
	# override and corrupts the color after ghost ends.
	_skater.stick_mesh.material_override = _make_solid_mat(Color(0.705, 0.640, 0.605))

	# Glove cuffs — short cylinders just past the wrist that extend back
	# along the forearm. Part of the glove, so created here (in apply_colors)
	# alongside the gloves color; not in apply_stripes. Recreated each call
	# so team-swap / color-change re-applies without stale materials.
	_rebuild_glove_cuffs(gloves_color)


func _rebuild_glove_cuffs(gloves_color: Color) -> void:
	if _skater.top_cuff_mesh != null and is_instance_valid(_skater.top_cuff_mesh):
		_skater.upper_body.remove_child(_skater.top_cuff_mesh)
		_skater.top_cuff_mesh.queue_free()
	_skater.top_cuff_mesh = null
	if _skater.bot_cuff_mesh != null and is_instance_valid(_skater.bot_cuff_mesh):
		_skater.upper_body.remove_child(_skater.bot_cuff_mesh)
		_skater.bot_cuff_mesh.queue_free()
	_skater.bot_cuff_mesh = null
	var cuff_radius: float = _skater.arm_mesh_thickness * 0.6
	_skater.top_cuff_mesh = _make_glove_cuff_mesh(cuff_radius, 0.06, gloves_color, "CuffTop")
	_skater.upper_body.add_child(_skater.top_cuff_mesh)
	_skater.bot_cuff_mesh = _make_glove_cuff_mesh(cuff_radius, 0.06, gloves_color, "CuffBot")
	_skater.upper_body.add_child(_skater.bot_cuff_mesh)


# Bone mesh wrappers are Node3D; the visible cylinder is a child MeshInstance3D
# resolved via Skater.bone_visual(). Returns silently if either is null.
func _set_bone_material(bone: Node3D, mat: StandardMaterial3D) -> void:
	var visual: MeshInstance3D = _skater.bone_visual(bone)
	if visual == null:
		return
	visual.material_override = mat.duplicate()


func apply_jersey_info(p_name: String, number: int, text_color: Color, text_outline_color: Color) -> void:
	# Clean up legacy floating decals from older box-geometry runs, if any.
	for child: Node in _skater.upper_body.get_children():
		if child.name in ["JerseyBackMesh", "JerseyShoulderL", "JerseyShoulderR"]:
			_skater.upper_body.remove_child(child)
			child.queue_free()

	_player_name = p_name
	_jersey_number = number
	_text_color = text_color
	_text_outline_color = text_outline_color
	_rebuild_jersey_texture()
	_rebuild_shoulder_texture()


func apply_stripes(
		jersey_stripe_color: Color,
		pants_stripe_color: Color,
		socks_stripe_color: Color) -> void:
	# Sweep stripe meshes left over from older mesh-based stripe builds.
	for node: Node in _skater.upper_body.get_children():
		if node.name.begins_with("Stripe_"):
			_skater.upper_body.remove_child(node)
			node.queue_free()
	for node: Node in _skater.lower_body.get_children():
		if node.name.begins_with("Stripe_"):
			_skater.lower_body.remove_child(node)
			node.queue_free()

	# Jersey hem stripe — painted into the torso texture (no separate mesh).
	_jersey_stripe_color = jersey_stripe_color
	_rebuild_jersey_texture()

	# Forearm sleeve stripe — horizontal band painted into a small texture
	# applied to each forearm cylinder. V=0 maps to the elbow end of the
	# bone (cylinder's local +Y, mapped to wrapper +Z which is opposite the
	# look_at target = the hand), so a band at V≈0.10-0.20 reads as
	# "middle top of the lower arm" — hockey-style sleeve placement near
	# the elbow, not at the cuff.
	var forearm_tex: ImageTexture = _make_v_stripe_texture(
			_jersey_color, jersey_stripe_color, 32, 0.12, 0.20)
	_set_bone_texture(_skater.forearm_mesh, forearm_tex)
	_set_bone_texture(_skater.bottom_forearm_mesh, forearm_tex)

	# Pants side stripe — vertical column in the texture, per-thigh
	# uv1_offset rotates the wrap to put it on each thigh's outer face
	# (sphere/cylinder U=0 is at +Z, U=0.25 at +X, U=0.75 at -X).
	var pants_tex: ImageTexture = _make_u_stripe_texture(
			_pants_color, pants_stripe_color, 64, 0.47, 0.53)
	_apply_side_stripe_material(_thigh_l, pants_tex, -0.25)
	_apply_side_stripe_material(_thigh_r, pants_tex, 0.25)

	# Sock stripe — horizontal band in the side V range. CylinderMesh
	# allocates roughly V=0..0.5 of the texture to the side surface (caps
	# use the rest), so V≈0.20-0.30 centers the band on the cylinder side.
	var sock_tex: ImageTexture = _make_v_stripe_texture(
			_socks_color, socks_stripe_color, 32, 0.20, 0.30)
	_sock_l.material_override = _make_texture_material(sock_tex)
	_sock_r.material_override = _make_texture_material(sock_tex)


# Pushes the cached uniform inputs into the JerseyDecal and refreshes the
# SubViewport. The torso material's albedo already points at the viewport
# texture (set once in _create_jersey_viewport), so we don't touch the
# material here — ghost-mode transparency and any other material state
# survives the refresh.
func _rebuild_jersey_texture() -> void:
	if _jersey_decal == null:
		return
	_jersey_decal.update_jersey(
			_jersey_color, _jersey_stripe_color,
			_player_name, _jersey_number, _text_color, _text_outline_color)
	_jersey_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


# Pushes the cached jersey color + number + text color into the
# ShoulderDecal and refreshes the shared shoulder SubViewport.
func _rebuild_shoulder_texture() -> void:
	if _shoulder_decal == null:
		return
	_shoulder_decal.update_shoulder(_jersey_color, _jersey_number, _text_color, _text_outline_color)
	_shoulder_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


# Builds a small ImageTexture with a horizontal stripe band at V=[v_start, v_end]
# over a base color fill. The texture is 4 px wide (cylinder UV wraps the
# horizontal axis; the actual width doesn't matter for a uniform band — 4 px
# gives some texel margin for filtering without z-fighting risk). Height is the
# resolution of the V axis.
func _make_v_stripe_texture(
		base: Color, stripe: Color,
		height_px: int, v_start: float, v_end: float) -> ImageTexture:
	var img := Image.create(4, height_px, false, Image.FORMAT_RGBA8)
	img.fill(base)
	var y0: int = int(v_start * float(height_px))
	var y1: int = int(v_end * float(height_px))
	if y1 > y0:
		img.fill_rect(Rect2i(0, y0, 4, y1 - y0), stripe)
	return ImageTexture.create_from_image(img)


# Builds a small ImageTexture with a vertical stripe column at U=[u_start, u_end]
# over a base color fill. The stripe becomes a vertical line on the cylinder
# side; the caller positions it via the material's uv1_offset.x.
func _make_u_stripe_texture(
		base: Color, stripe: Color,
		width_px: int, u_start: float, u_end: float) -> ImageTexture:
	var img := Image.create(width_px, 4, false, Image.FORMAT_RGBA8)
	img.fill(base)
	var x0: int = int(u_start * float(width_px))
	var x1: int = int(u_end * float(width_px))
	if x1 > x0:
		img.fill_rect(Rect2i(x0, 0, x1 - x0, 4), stripe)
	return ImageTexture.create_from_image(img)


func _make_texture_material(tex: Texture2D) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	return mat


# Applies a stripe texture to a thigh / leg cylinder with the given
# uv1_offset.x. Negative for the left side (puts the texture's vertical
# stripe at sphere/cylinder -X = outward for the left leg); positive
# 0.25 for the right side.
func _apply_side_stripe_material(
		mesh: MeshInstance3D, tex: Texture2D, u_offset: float) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.uv1_offset = Vector3(u_offset, 0.0, 0.0)
	mesh.material_override = mat


# Sets the textured albedo on a bone wrapper's child cylinder. Used for the
# forearm sleeve stripe; the wrapper itself is a Node3D, the visible cylinder
# is reached via Skater.bone_visual().
func _set_bone_texture(bone: Node3D, tex: Texture2D) -> void:
	var visual: MeshInstance3D = _skater.bone_visual(bone)
	if visual == null:
		return
	visual.material_override = _make_texture_material(tex)


func apply_ghost(ghost: bool) -> void:
	var meshes: Array[MeshInstance3D] = [
			_upper_body_mesh, _blade_mesh, _skater.stick_mesh,
			_skater.bone_visual(_skater.upper_arm_mesh),
			_skater.bone_visual(_skater.forearm_mesh),
			_skater.bone_visual(_skater.bottom_upper_arm_mesh),
			_skater.bone_visual(_skater.bottom_forearm_mesh),
			_skater.top_elbow_sphere, _skater.top_hand_sphere,
			_skater.bottom_elbow_sphere, _skater.bottom_hand_sphere,
			_helmet, _shoulder_l, _shoulder_r,
			_hip_l, _hip_r, _thigh_l, _thigh_r,
			_knee_l, _knee_r, _sock_l, _sock_r,
			_skate_l, _skate_r, _foot_l, _foot_r,
			_skater.top_cuff_mesh, _skater.bot_cuff_mesh,
		]
	for mesh: MeshInstance3D in meshes:
		if mesh == null:
			continue
		var mat: StandardMaterial3D = mesh.material_override as StandardMaterial3D
		if mat == null:
			mat = StandardMaterial3D.new()
			mesh.material_override = mat
		if ghost:
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.albedo_color.a = 0.3
		else:
			mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
			mat.albedo_color.a = 1.0


func _make_solid_mat(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	return mat


func _make_glove_cuff_mesh(radius: float, height: float, color: Color, mesh_name: String) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	m.name = mesh_name
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = height
	cyl.radial_segments = 16
	m.mesh = cyl
	m.material_override = _make_solid_mat(color)
	return m
