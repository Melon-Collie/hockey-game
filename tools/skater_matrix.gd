extends SceneTree

# Dev visualizer: renders a five-build proportion matrix — lean/heavy at both
# height extremes around the neutral — each skater dressed, given the
# appearance pass, and the controller's visual arm/shoulder scalings, so
# "does this build look right?" is answerable without launching the game.
# Sister tool to skate_capture.gd; same runner:
#
#   LIBGL_ALWAYS_SOFTWARE=1 xvfb-run -a godot --path . \
#       --rendering-driver opengl3 --audio-driver Dummy \
#       -s res://tools/skater_matrix.gd
#
# Locally any GPU works: drop the env var and xvfb-run. Output path prints on
# save (user:// — never the repo tree, so captures can't be committed).

# [height in, weight lbs, jersey name, team color slot] per column.
const BUILDS: Array = [
	[67, 162, "MIN", 7],
	[67, 185, "STOCK", 8],
	[73, 201, "NEUT", 1],
	[80, 209, "SLIM", 4],
	[80, 264, "TANK", 2],
]

var _frames: int = 0
var _camera: Camera3D = null


func _init() -> void:
	DisplayServer.window_set_size(Vector2i(1024, 640))
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.10, 0.11, 0.14)
	env.environment = e
	root.add_child(env)

	_camera = Camera3D.new()
	_camera.position = Vector3(0.0, 1.1, 7.0)
	_camera.rotation_degrees = Vector3(-4.0, 0.0, 0.0)
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

	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(14, 8)
	floor_mesh.mesh = plane
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(0.55, 0.60, 0.66)
	floor_mesh.material_override = fm
	root.add_child(floor_mesh)

	process_frame.connect(_on_frame)


func _on_frame() -> void:
	_frames += 1
	if _frames == 2:
		# Deferred past _init: autoload identifiers don't resolve for
		# dependent-script compiles until the tree is up.
		_spawn_builds()
	elif _frames == 30:
		var img: Image = root.get_texture().get_image()
		var path: String = "user://skater_matrix.png"
		img.save_png(path)
		print("saved ", ProjectSettings.globalize_path(path))
		quit()


func _spawn_builds() -> void:
	var scene: PackedScene = load("res://Scenes/Skater.tscn")
	for i: int in BUILDS.size():
		var b: Array = BUILDS[i]
		var attrs = PlayerAttributes.new(int(b[0]), int(b[1]), 1, 1, 1, 1)
		var s: Node3D = scene.instantiate()
		root.add_child(s)
		s.position = Vector3(-2.3 + 1.15 * i, GameRules.FACEOFF_SPAWN_HEIGHT, 0.0)
		s.call("set_uniform", TeamColorRegistry.get_colors(int(b[3]), 0))
		s.call("set_jersey_info", String(b[2]), int(b[1]) % 100)
		s.call("apply_appearance", attrs)
		# The controller's visual-side scalings (arm bones, shoulder anchor)
		# — mirrored from SkaterController.apply_attributes so the bare rig
		# wears the same proportions the game gives it.
		var h: float = attrs.height_mult()
		s.set("upper_arm_length", s.get("upper_arm_length") * h)
		s.set("forearm_length", s.get("forearm_length") * h)
		s.call("set_shoulder_anchor", 0.22 * attrs.torso_bulk_mult(), 0.40 * h)
		# Bare rig: the stick mesh rides the blade anchor, so seat it in a
		# stance spot on the ice (the scene default floats it at chest height
		# 1.5 m ahead). The HANDS stay at their rest markers regardless —
		# hand targets are controller-driven (pose coordinator), so the arms
		# hold an akimbo rest pose here and can intersect the hips on wide
		# builds. That interpenetration is a bare-rig artifact, not a game
		# pose; judge PROPORTIONS from this view, never arm posing.
		var blade: Node3D = s.get_node("MeshRoot/UpperBody/Blade") as Node3D
		blade.position = Vector3(0.3, 0.06 - GameRules.FACEOFF_SPAWN_HEIGHT, -0.75)
