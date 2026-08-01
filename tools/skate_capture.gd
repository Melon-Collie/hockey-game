extends SceneTree

# Dev visualizer: renders the whole skate catalogue offscreen and saves PNGs
# from two angles, so gear changes — a new model, a retimed zone, moved
# geometry — can be SEEN without launching the game. Each skate is the gear
# workbench's own assembly (shared SkaterMeshBuilder parts, the seats from
# GearEditorPopup._build_preview — keep the two in sync) painted through
# GearModelRegistry, so what lands in the PNG is what the rink paints.
#
# Needs a real (software) renderer, not --headless. On the web container:
#
#   LIBGL_ALWAYS_SOFTWARE=1 xvfb-run -a godot --path . \
#       --rendering-driver opengl3 --audio-driver Dummy \
#       -s res://tools/skate_capture.gd
#
# Locally any GPU works: drop the env var and xvfb-run. Output paths print
# on save (user:// — never the repo tree, so captures can't be committed).

const _BOOT_ROT := Basis(Vector3(0, 0, -1), Vector3(1, 0, 0), Vector3(0, -1, 0))
const _BLADE_ICE_M: float = 0.080 + SkaterMeshBuilder.SKATE_LIFT_M
const _STEEL_COLOR := Color(0.82, 0.85, 0.88)
const _LACE_COLOR := Color(0.88, 0.88, 0.86)
# A loud kit color, so the models' TEAM zones are unmistakable against the
# black and white ones.
const _TEAM_ACCENT := Color(0.10, 0.22, 0.75)

# The row is shot with an ORTHOGONAL camera: perspective across a two-metre
# lineup would frame the outer skates differently from the middle ones, which
# is exactly the comparison the sheet exists to make.
const _SPACING_M: float = 0.42
# Total horizontal margin around the lineup, in metres of world space.
const _ORTHO_MARGIN_M: float = 0.44
# Yaw applied to every skate for the second shot — the same three-quarter
# angle on each, rather than moving the camera (which ortho would not honor).
const _THREE_QUARTER_DEG: float = 40.0

var _frames: int = 0
var _holders: Array[Node3D] = []


func _init() -> void:
	DisplayServer.window_set_size(Vector2i(1800, 520))
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.10, 0.11, 0.14)
	env.environment = e
	root.add_child(env)

	var count: int = GearModelRegistry.skate_count()
	var span: float = _SPACING_M * float(count - 1)

	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	# KEEP_WIDTH so `size` frames the lineup's WIDTH — the default keeps the
	# height instead, which sizes the shot off the one dimension that doesn't
	# grow when a model is added to the catalogue.
	camera.keep_aspect = Camera3D.KEEP_WIDTH
	camera.size = span + _ORTHO_MARGIN_M
	camera.position = Vector3(0.0, 0.11, 1.0)
	root.add_child(camera)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-42.0, 35.0, 0.0)
	light.light_energy = 1.3
	light.shadow_enabled = true
	root.add_child(light)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-15.0, -140.0, 0.0)
	fill.light_energy = 0.5
	root.add_child(fill)

	var disc_mi := MeshInstance3D.new()
	var disc := BoxMesh.new()
	disc.size = Vector3(span + _SPACING_M, 0.02, 0.6)
	disc_mi.mesh = disc
	disc_mi.material_override = _mat(Color(0.16, 0.18, 0.22), 0.6)
	disc_mi.position = Vector3(0.0, -0.011, 0.0)
	root.add_child(disc_mi)

	for model: int in count:
		var x: float = -span * 0.5 + _SPACING_M * float(model)
		# The skate hangs off a holder so the second shot can yaw the whole
		# assembly — collar and accent band included — in one write.
		var holder := Node3D.new()
		holder.position = Vector3(x, 0.0, 0.0)
		root.add_child(holder)
		_holders.append(holder)
		_build_skate(holder, model)
		# Labels are NOT children of the holder: they must keep facing the
		# camera when the skates turn.
		var label := Label3D.new()
		label.text = tr(GearModelRegistry.SKATE_NAME_KEYS[model])
		label.pixel_size = 0.0011
		label.font_size = 64
		label.position = Vector3(x, -0.055, 0.16)
		root.add_child(label)

	process_frame.connect(_on_frame)


# One skate under `holder`, painted from the model's zones. Mirrors
# GearEditorPopup._build_preview: the boot rides the rotated boot frame seated
# so the runner stands on the disc, and the collar takes the appearance rig's
# neutral-build scaling (calf girth laterally, height vertically — the boot
# deliberately never scales) with the accent band seated on it.
func _build_skate(holder: Node3D, model: int) -> void:
	var skate_at := Vector3(0.0, _BLADE_ICE_M, 0.0)
	var boot := MeshInstance3D.new()
	boot.mesh = SkaterMeshBuilder.shared_boot()
	boot.transform = Transform3D(_BOOT_ROT, skate_at)
	boot.material_override = _mat(_zone(model, GearModelRegistry.SKATE_BOOT), 0.42)
	holder.add_child(boot)

	var steel := MeshInstance3D.new()
	steel.mesh = SkaterMeshBuilder.shared_skate_blade()
	steel.transform = Transform3D(_BOOT_ROT, skate_at)
	steel.material_override = _mat(_STEEL_COLOR, 0.25)
	holder.add_child(steel)

	var laces := MeshInstance3D.new()
	laces.mesh = SkaterMeshBuilder.shared_laces()
	laces.transform = Transform3D(_BOOT_ROT, skate_at)
	laces.material_override = _mat(_LACE_COLOR, 0.9)
	holder.add_child(laces)

	var attrs := PlayerAttributes.all_average()
	var collar := MeshInstance3D.new()
	collar.mesh = SkaterMeshBuilder.shared_skate_collar()
	collar.scale = Vector3(attrs.calf_mult(), attrs.height_mult(), attrs.calf_mult())
	collar.position = skate_at + Vector3(0.10, 0.04 * attrs.height_mult(), 0.0)
	collar.material_override = _mat(_zone(model, GearModelRegistry.SKATE_COLLAR), 0.42)
	holder.add_child(collar)

	var stripe := MeshInstance3D.new()
	stripe.mesh = SkaterMeshBuilder.shared_skate_stripe()
	stripe.position = Vector3(0.0, 0.045, 0.0)
	stripe.scale = Vector3(0.092, 1.0, 0.092)
	stripe.material_override = _mat(_zone(model, GearModelRegistry.SKATE_STRIPE), 0.42)
	collar.add_child(stripe)


func _zone(model: int, zone: int) -> Color:
	return GearModelRegistry.skate_color(model, zone, _TEAM_ACCENT)


func _mat(c: Color, r: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = r
	return m


func _on_frame() -> void:
	_frames += 1
	if _frames == 12:
		_save("skates_side.png")
		for holder: Node3D in _holders:
			holder.rotation_degrees = Vector3(0.0, _THREE_QUARTER_DEG, 0.0)
	elif _frames == 24:
		_save("skates_three_quarter.png")
		quit()


func _save(fname: String) -> void:
	var img: Image = root.get_texture().get_image()
	var path: String = "user://" + fname
	img.save_png(path)
	print("saved ", ProjectSettings.globalize_path(path))
