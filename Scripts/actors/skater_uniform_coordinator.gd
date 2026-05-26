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

# Cached jersey-texture inputs. The torso material's albedo is a procedural
# texture combining all of these, so each apply_* function stores its
# relevant fields and calls _rebuild_jersey_texture() — the texture always
# reflects the latest combined state regardless of call order. Initialised
# to safe defaults so an early apply_colors() can render even before
# apply_jersey_info / apply_stripes have been called.
var _jersey_color: Color = Color.WHITE
var _jersey_stripe_color: Color = Color.BLACK
var _player_name: String = ""
var _jersey_number: int = 0
var _text_color: Color = Color.BLACK


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


func apply_colors(
		jersey_color: Color,
		helmet_color: Color,
		pants_color: Color,
		socks_color: Color,
		blade_color: Color,
		gloves_color: Color) -> void:
	_jersey_color = jersey_color
	_rebuild_jersey_texture()
	var jersey_mat: StandardMaterial3D = _make_solid_mat(jersey_color)
	var pants_mat: StandardMaterial3D = _make_solid_mat(pants_color)
	var socks_mat: StandardMaterial3D = _make_solid_mat(socks_color)
	var gloves_mat: StandardMaterial3D = _make_solid_mat(gloves_color)
	var skate_mat: StandardMaterial3D = _make_solid_mat(Color(0.08, 0.08, 0.08))
	# Torso uses the procedural jersey texture (built by _rebuild_jersey_texture
	# above); jersey_mat is reused for the shoulder spheres + arm bones so the
	# uniform reads consistently across the upper body.
	_shoulder_l.material_override = jersey_mat.duplicate()
	_shoulder_r.material_override = jersey_mat.duplicate()
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


func apply_jersey_info(p_name: String, number: int, text_color: Color) -> void:
	# Clean up legacy floating decals from older box-geometry runs, if any.
	for child: Node in _skater.upper_body.get_children():
		if child.name in ["JerseyBackMesh", "JerseyShoulderL", "JerseyShoulderR"]:
			_skater.upper_body.remove_child(child)
			child.queue_free()

	_player_name = p_name
	_jersey_number = number
	_text_color = text_color
	_rebuild_jersey_texture()


func apply_stripes(
		jersey_stripe_color: Color,
		pants_stripe_color: Color,
		socks_stripe_color: Color) -> void:
	# Remove any previously generated stripe nodes (from older box-geometry
	# runs or a prior team-color application). The torso hem is now painted
	# into the jersey texture so no Stripe_JerseyHem mesh is created below,
	# but the cleanup still sweeps it if it exists from an older build.
	for node: Node in _skater.upper_body.get_children():
		if node.name.begins_with("Stripe_"):
			_skater.upper_body.remove_child(node)
			node.queue_free()
	for node: Node in _skater.lower_body.get_children():
		if node.name.begins_with("Stripe_"):
			_skater.lower_body.remove_child(node)
			node.queue_free()

	# Elbow spheres carry the jersey stripe accent — the sphere reads as a
	# colored elbow pad at the natural break in the sleeve. apply_colors()
	# pre-tints them with jersey so they're never blank in the brief window
	# before stripes apply.
	var stripe_mat: StandardMaterial3D = _make_solid_mat(jersey_stripe_color)
	if _skater.top_elbow_sphere != null:
		_skater.top_elbow_sphere.material_override = stripe_mat.duplicate()
	if _skater.bottom_elbow_sphere != null:
		_skater.bottom_elbow_sphere.material_override = stripe_mat.duplicate()

	# Jersey hem stripe — painted into the torso texture (no separate mesh).
	_jersey_stripe_color = jersey_stripe_color
	_rebuild_jersey_texture()

	# Pants side stripe — vertical piping cylinder on the outer side of
	# each thigh.
	_add_pants_side_stripe(_thigh_l, -1.0, pants_stripe_color, "Stripe_PantsL")
	_add_pants_side_stripe(_thigh_r, +1.0, pants_stripe_color, "Stripe_PantsR")

	# Sock stripe — horizontal band around the middle of each sock cylinder.
	_add_sock_stripe(_sock_l, socks_stripe_color, "Stripe_SockL")
	_add_sock_stripe(_sock_r, socks_stripe_color, "Stripe_SockR")


# Rebuilds the torso material from the cached uniform inputs. Called by
# apply_colors / apply_jersey_info / apply_stripes whenever any contributing
# field changes — the texture always reflects the latest combined state.
# Uses StandardMaterial3D defaults (shaded) so the jersey responds to
# lighting the same way the solid-color body parts do.
#
# UV transform:
#   - uv1_offset.x = 0.25 rotates the wrap 90° around so the texture's
#     back-center (texel x=128) lands at the skater's +Z (the back).
#     Godot's CylinderMesh starts U=0 at +Z and increases CCW; without
#     this shift content drawn at x=128 would appear at +X (right side).
#   - uv1_scale.y = -1 + uv1_offset.y = 1 flip the V axis so the bottom
#     row of the image lands at the bottom of the cylinder. Godot's
#     CylinderMesh has V=0 at the cylinder bottom and V=1 at the top,
#     which is inverted from image-pixel-y convention.
func _rebuild_jersey_texture() -> void:
	if _upper_body_mesh == null:
		return
	var tex: ImageTexture = JerseyTextureGenerator.make_jersey_cylinder_texture(
			_jersey_color, _jersey_stripe_color,
			_player_name, _jersey_number, _text_color)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.uv1_offset = Vector3(0.25, 1.0, 0.0)
	mat.uv1_scale = Vector3(1.0, -1.0, 1.0)
	_upper_body_mesh.material_override = mat


# Builds vertical piping cylinder on the outer side of a thigh. The piping
# center sits on the thigh's TOP outer surface (widest point); this keeps
# the piping flush at the top — the small taper-induced gap at the bottom
# reads naturally as a straight cord on a tapered leg.
func _add_pants_side_stripe(
		thigh: MeshInstance3D, side_sign: float, color: Color, mesh_name: String) -> void:
	var thigh_mesh: CylinderMesh = thigh.mesh as CylinderMesh
	if thigh_mesh == null:
		return
	const PIPING_RADIUS: float = 0.012
	var pipe := _make_band_cylinder(
			PIPING_RADIUS, thigh_mesh.height, color, mesh_name)
	var thigh_pos: Vector3 = thigh.position
	pipe.position = Vector3(
			thigh_pos.x + side_sign * thigh_mesh.top_radius,
			thigh_pos.y,
			thigh_pos.z)
	_skater.lower_body.add_child(pipe)


# Builds a horizontal CylinderMesh band wrapping the middle of a sock.
# Radius averages the sock's top/bottom (sock taper is small ~5mm so the
# average is flush enough across the band's height).
func _add_sock_stripe(sock: MeshInstance3D, color: Color, mesh_name: String) -> void:
	var sock_mesh: CylinderMesh = sock.mesh as CylinderMesh
	if sock_mesh == null:
		return
	const BAND_HEIGHT: float = 0.06
	var radius: float = (sock_mesh.top_radius + sock_mesh.bottom_radius) * 0.5 + 0.003
	var band := _make_band_cylinder(radius, BAND_HEIGHT, color, mesh_name)
	band.position = sock.position
	_skater.lower_body.add_child(band)


func _make_band_cylinder(
		radius: float, height: float, color: Color, mesh_name: String) -> MeshInstance3D:
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = height
	cyl.radial_segments = 24
	var m := MeshInstance3D.new()
	m.name = mesh_name
	m.mesh = cyl
	m.material_override = _make_solid_mat(color)
	return m


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
			_skate_l, _skate_r,
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
	# Stripe nodes alpha-fade alongside the body parts (rather than
	# vanishing entirely) so ghost mode looks consistent across the skater.
	for parent: Node in [_skater.upper_body, _skater.lower_body]:
		for node: Node in parent.get_children():
			if not node.name.begins_with("Stripe_"):
				continue
			var stripe_mesh: MeshInstance3D = node as MeshInstance3D
			if stripe_mesh == null:
				continue
			var smat: StandardMaterial3D = stripe_mesh.material_override as StandardMaterial3D
			if smat == null:
				continue
			if ghost:
				smat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				smat.albedo_color.a = 0.3
			else:
				smat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
				smat.albedo_color.a = 1.0


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
