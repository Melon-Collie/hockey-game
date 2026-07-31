extends SceneTree

# Dev visualizer: renders the gear workbench's skate assembly offscreen and
# saves PNGs from two angles, so gear-geometry changes can be SEEN without
# launching the game. Assembles the same shared SkaterMeshBuilder parts with
# the same seats as GearEditorPopup._build_preview — keep the two in sync.
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
# The stripe renders loud (red) so the paintable band is unmissable in the
# captures; laces keep their default white.
const _STRIPE_COLOR := Color(0.78, 0.10, 0.12)
const _LACE_COLOR := Color(0.88, 0.88, 0.86)

var _frames: int = 0
var _camera: Camera3D = null


func _init() -> void:
	DisplayServer.window_set_size(Vector2i(512, 512))
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.10, 0.11, 0.14)
	env.environment = e
	root.add_child(env)

	_camera = Camera3D.new()
	_camera.position = Vector3(0.0, 0.16, 0.55)
	_camera.rotation_degrees = Vector3(-10.0, 0.0, 0.0)
	_camera.fov = 45.0
	root.add_child(_camera)

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
	var disc := CylinderMesh.new()
	disc.top_radius = 0.45
	disc.bottom_radius = 0.45
	disc.height = 0.02
	disc_mi.mesh = disc
	disc_mi.material_override = _mat(Color(0.16, 0.18, 0.22), 0.6)
	disc_mi.position = Vector3(0.0, -0.011, 0.0)
	root.add_child(disc_mi)

	# ── The skate, assembled like GearEditorPopup._build_preview ─────────
	var skate_at := Vector3(0.0, _BLADE_ICE_M, 0.0)
	var boot := MeshInstance3D.new()
	boot.mesh = SkaterMeshBuilder.shared_boot()
	boot.transform = Transform3D(_BOOT_ROT, skate_at)
	boot.material_override = _mat(Color(0.08, 0.08, 0.08), 0.42)
	root.add_child(boot)

	var steel := MeshInstance3D.new()
	steel.mesh = SkaterMeshBuilder.shared_skate_blade()
	steel.transform = Transform3D(_BOOT_ROT, skate_at)
	steel.material_override = _mat(Color(0.82, 0.85, 0.88), 0.25)
	root.add_child(steel)

	var laces := MeshInstance3D.new()
	laces.mesh = SkaterMeshBuilder.shared_laces()
	laces.transform = Transform3D(_BOOT_ROT, skate_at)
	laces.material_override = _mat(_LACE_COLOR, 0.9)
	root.add_child(laces)

	# True in-game seat + the appearance rig's collar scaling for a neutral
	# build (calf girth laterally, height vertically — the boot never scales),
	# matching GearEditorPopup.open().
	var attrs := PlayerAttributes.all_average()
	var collar := MeshInstance3D.new()
	collar.mesh = SkaterMeshBuilder.shared_skate_collar()
	collar.scale = Vector3(attrs.calf_mult(), attrs.height_mult(), attrs.calf_mult())
	collar.position = skate_at + Vector3(0.10, 0.04 * attrs.height_mult(), 0.0)
	collar.material_override = _mat(Color(0.08, 0.08, 0.08), 0.42)
	root.add_child(collar)

	var stripe := MeshInstance3D.new()
	stripe.mesh = SkaterMeshBuilder.shared_skate_stripe()
	stripe.position = Vector3(0.0, 0.045, 0.0)
	stripe.scale = Vector3(0.092, 1.0, 0.092)
	stripe.material_override = _mat(_STRIPE_COLOR, 0.42)
	collar.add_child(stripe)

	process_frame.connect(_on_frame)


func _mat(c: Color, r: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = r
	return m


func _on_frame() -> void:
	_frames += 1
	if _frames == 12:
		_save("skate_side.png")
		# Three-quarter front view for the second shot.
		_camera.position = Vector3(-0.38, 0.22, 0.40)
		_camera.look_at(Vector3(-0.02, 0.12, 0.0))
	elif _frames == 24:
		_save("skate_front34.png")
		quit()


func _save(fname: String) -> void:
	var img: Image = root.get_texture().get_image()
	var path: String = "user://" + fname
	img.save_png(path)
	print("saved ", ProjectSettings.globalize_path(path))
