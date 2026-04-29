class_name SkaterUniformCoordinator
extends RefCounted

var _skater: Skater
var _upper_body_mesh: MeshInstance3D
var _blade_mesh: MeshInstance3D
var _lower_body_mesh: MeshInstance3D
var _direction_indicator: MeshInstance3D
var _sock_mesh: MeshInstance3D
var _skate_mesh: MeshInstance3D


func setup(skater: Skater) -> void:
	_skater = skater
	_upper_body_mesh = skater.upper_body.get_node("UpperBodyMesh") as MeshInstance3D
	_blade_mesh = skater.blade.get_node("MeshInstance3D") as MeshInstance3D
	_lower_body_mesh = skater.lower_body.get_node("LowerBodyMesh") as MeshInstance3D
	_direction_indicator = skater.upper_body.get_node("DirectionIndicator") as MeshInstance3D
	_sock_mesh = skater.lower_body.get_node_or_null("SockMesh") as MeshInstance3D
	_skate_mesh = skater.lower_body.get_node_or_null("SkateMesh") as MeshInstance3D


func apply_colors(
		jersey_color: Color,
		helmet_color: Color,
		pants_color: Color,
		socks_color: Color,
		blade_color: Color) -> void:
	var jersey_mat: StandardMaterial3D = _make_solid_mat(jersey_color)
	_upper_body_mesh.material_override = jersey_mat
	_blade_mesh.material_override = _make_solid_mat(blade_color)
	if _skater.upper_arm_mesh != null:
		_skater.upper_arm_mesh.material_override = jersey_mat.duplicate()
	if _skater.forearm_mesh != null:
		_skater.forearm_mesh.material_override = jersey_mat.duplicate()
	if _skater.bottom_upper_arm_mesh != null:
		_skater.bottom_upper_arm_mesh.material_override = jersey_mat.duplicate()
	if _skater.bottom_forearm_mesh != null:
		_skater.bottom_forearm_mesh.material_override = jersey_mat.duplicate()
	_direction_indicator.material_override = _make_solid_mat(helmet_color)
	_lower_body_mesh.material_override = _make_solid_mat(pants_color)
	if _sock_mesh != null:
		_sock_mesh.material_override = _make_solid_mat(socks_color)
	# Fixed colors — set explicitly so ghost mode never creates a blank gray
	# override and corrupts the color after ghost ends.
	_skater.stick_mesh.material_override = _make_solid_mat(Color(0.705, 0.640, 0.605))
	if _skate_mesh != null:
		_skate_mesh.material_override = _make_solid_mat(Color(0.08, 0.08, 0.08))


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

	# UpperBodyMesh is a 0.5×0.65×0.28 BoxMesh centered at (0, 0.3, 0) in
	# UpperBody local space. Back surface is at Z = +0.14; place the quad just
	# outside it. Quad faces +Z by default (toward viewer standing behind).
	var quad := QuadMesh.new()
	quad.size = Vector2(0.40, 0.30)  # 4:3 matches 256×192 texture
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "JerseyBackMesh"
	mesh_inst.mesh = quad
	mesh_inst.material_override = mat
	mesh_inst.position = Vector3(0.0, 0.36, 0.15)
	_skater.upper_body.add_child(mesh_inst)

	var shoulder_tex: ImageTexture = JerseyTextureGenerator.make_shoulder_texture(number, text_color)
	var left_shoulder: MeshInstance3D = JerseyTextureGenerator.make_shoulder_mesh(shoulder_tex, -0.14)
	left_shoulder.name = "JerseyShoulderL"
	var right_shoulder: MeshInstance3D = JerseyTextureGenerator.make_shoulder_mesh(shoulder_tex, 0.14)
	right_shoulder.name = "JerseyShoulderR"
	_skater.upper_body.add_child(left_shoulder)
	_skater.upper_body.add_child(right_shoulder)


func apply_stripes(
		jersey_stripe_color: Color,
		pants_stripe_color: Color,
		socks_stripe_color: Color) -> void:
	# Free cuff meshes from a previous call before rebuilding.
	if _skater.top_cuff_mesh != null and is_instance_valid(_skater.top_cuff_mesh):
		_skater.upper_body.remove_child(_skater.top_cuff_mesh)
		_skater.top_cuff_mesh.queue_free()
	_skater.top_cuff_mesh = null
	if _skater.bot_cuff_mesh != null and is_instance_valid(_skater.bot_cuff_mesh):
		_skater.upper_body.remove_child(_skater.bot_cuff_mesh)
		_skater.bot_cuff_mesh.queue_free()
	_skater.bot_cuff_mesh = null

	# Remove any previously generated stripe nodes.
	for node: Node in _skater.upper_body.get_children():
		if node.name.begins_with("Stripe_"):
			_skater.upper_body.remove_child(node)
			node.queue_free()
	for node: Node in _skater.lower_body.get_children():
		if node.name.begins_with("Stripe_"):
			_skater.lower_body.remove_child(node)
			node.queue_free()

	# Jersey hem band — bottom 0.08 m of the UpperBodyMesh
	# (BoxMesh 0.5×0.65×0.28, center (0,0.3,0) → bottom at y = -0.025).
	var hem_quads: Array = JerseyTextureGenerator.make_box_stripe_band(
			Vector3(0.0, 0.3, 0.0), Vector3(0.25, 0.325, 0.14),
			-0.025, 0.08, jersey_stripe_color, "Stripe_JerseyHem")
	for q: MeshInstance3D in hem_quads:
		_skater.upper_body.add_child(q)

	# Sleeve cuffs — solid box meshes as children of upper_body. Their
	# transforms are updated each frame in Skater.update_arm_mesh() /
	# update_bottom_arm_mesh() using the elbow→hand direction.
	var cuff_size: float = _skater.arm_mesh_thickness + 0.02
	_skater.top_cuff_mesh = _make_cuff_mesh(cuff_size, 0.06, jersey_stripe_color, "CuffTop")
	_skater.upper_body.add_child(_skater.top_cuff_mesh)
	_skater.bot_cuff_mesh = _make_cuff_mesh(cuff_size, 0.06, jersey_stripe_color, "CuffBot")
	_skater.upper_body.add_child(_skater.bot_cuff_mesh)

	# Pants side stripe — full-height vertical piping on the ±X faces
	# (LowerBodyMesh BoxMesh 0.45×0.4×0.3, center (0,−0.2,0)).
	var pants_quads: Array = JerseyTextureGenerator.make_box_side_stripe(
			Vector3(0.0, -0.2, 0.0), Vector3(0.225, 0.2, 0.15),
			0.07, pants_stripe_color, "Stripe_Pants")
	for q: MeshInstance3D in pants_quads:
		_skater.lower_body.add_child(q)

	# Sock stripe — if SockMesh is present in the scene.
	if _sock_mesh != null:
		var sock_box: BoxMesh = _sock_mesh.mesh as BoxMesh
		if sock_box != null:
			var sh: Vector3 = sock_box.size * 0.5
			var sc: Vector3 = _sock_mesh.position
			var sock_quads: Array = JerseyTextureGenerator.make_box_stripe_band(
					sc, sh, sc.y + sh.y * 0.3, sh.y * 0.4,
					socks_stripe_color, "Stripe_Sock")
			for q: MeshInstance3D in sock_quads:
				_skater.lower_body.add_child(q)


func apply_ghost(ghost: bool) -> void:
	var meshes: Array[MeshInstance3D] = [
			_upper_body_mesh, _blade_mesh, _skater.stick_mesh,
			_skater.upper_arm_mesh, _skater.forearm_mesh,
			_skater.bottom_upper_arm_mesh, _skater.bottom_forearm_mesh,
			_lower_body_mesh, _direction_indicator,
			_sock_mesh, _skate_mesh,
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
	for n: String in ["JerseyBackMesh", "JerseyShoulderL", "JerseyShoulderR"]:
		var m: Node = _skater.upper_body.get_node_or_null(n)
		if m:
			m.visible = not ghost
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


func _make_cuff_mesh(cross_size: float, height: float, color: Color, mesh_name: String) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	m.name = mesh_name
	var box := BoxMesh.new()
	box.size = Vector3(cross_size, cross_size, height)
	m.mesh = box
	m.material_override = _make_solid_mat(color)
	return m
