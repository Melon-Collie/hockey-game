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
	var jersey_mat: StandardMaterial3D = _make_solid_mat(jersey_color)
	var pants_mat: StandardMaterial3D = _make_solid_mat(pants_color)
	var socks_mat: StandardMaterial3D = _make_solid_mat(socks_color)
	var gloves_mat: StandardMaterial3D = _make_solid_mat(gloves_color)
	var skate_mat: StandardMaterial3D = _make_solid_mat(Color(0.08, 0.08, 0.08))
	_upper_body_mesh.material_override = jersey_mat
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
	for child: Node in _skater.upper_body.get_children():
		if child.name in ["JerseyBackMesh", "JerseyShoulderL", "JerseyShoulderR"]:
			_skater.upper_body.remove_child(child)
			child.queue_free()

	var tex: ImageTexture = JerseyTextureGenerator.make_jersey_texture(p_name, number, text_color)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = false

	# UpperBodyMesh is now a CylinderMesh (top_radius=0.20, bottom_radius=0.22,
	# height=0.55) centered at (0, 0.195, 0). At Y=0.25 the cylinder's radius
	# is ~0.208; placing the flat quad at Z=0.215 sits it just behind the back
	# surface. Quad faces +Z by default (toward a viewer standing behind the
	# player). The decal renders flat against a curved surface — readable from
	# behind but visibly floating off the sides; a curved cylinder-segment
	# decal is a future improvement.
	var quad := QuadMesh.new()
	quad.size = Vector2(0.36, 0.27)  # 4:3 matches 256×192 texture, slightly narrower than torso radius * 2
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "JerseyBackMesh"
	mesh_inst.mesh = quad
	mesh_inst.material_override = mat
	mesh_inst.position = Vector3(0.0, 0.25, 0.215)
	_skater.upper_body.add_child(mesh_inst)

	# Shoulder texture decals are obsolete now that ShoulderL/R are 3D spheres
	# painted with the jersey color via apply_colors(). The flat texture quads
	# would clip into the spheres and look broken on a cylindrical torso.


func apply_stripes(
		jersey_stripe_color: Color,
		_pants_stripe_color: Color,
		_socks_stripe_color: Color) -> void:
	# Remove any previously generated stripe nodes (from older box-geometry runs).
	for node: Node in _skater.upper_body.get_children():
		if node.name.begins_with("Stripe_"):
			_skater.upper_body.remove_child(node)
			node.queue_free()
	for node: Node in _skater.lower_body.get_children():
		if node.name.begins_with("Stripe_"):
			_skater.lower_body.remove_child(node)
			node.queue_free()

	# Elbow spheres carry the jersey stripe accent in the new geometry — the
	# sphere reads as a colored elbow pad at the natural break in the sleeve.
	# apply_colors() pre-tints them with jersey so they're never blank in the
	# brief window before stripes apply.
	var stripe_mat: StandardMaterial3D = _make_solid_mat(jersey_stripe_color)
	if _skater.top_elbow_sphere != null:
		_skater.top_elbow_sphere.material_override = stripe_mat.duplicate()
	if _skater.bottom_elbow_sphere != null:
		_skater.bottom_elbow_sphere.material_override = stripe_mat.duplicate()

	# TODO: Jersey hem band, pants side stripe, and sock stripe were quad-faces
	# wrapping the old box geometry — they don't fit a cylinder torso or split
	# leg cylinders. Reimplementing as curved/ring-shaped strip meshes that
	# wrap the cylinders is follow-up work. The pants/socks stripe colors are
	# accepted on this API but currently unused.


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
	var back_mesh: Node = _skater.upper_body.get_node_or_null("JerseyBackMesh")
	if back_mesh:
		back_mesh.visible = not ghost
	for node: Node in _skater.upper_body.get_children():
		if node.name.begins_with("Stripe_"):
			node.visible = not ghost
	for node: Node in _skater.lower_body.get_children():
		if node.name.begins_with("Stripe_"):
			node.visible = not ghost


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
