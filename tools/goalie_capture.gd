extends SceneTree

# Dev visualizer: renders the goalie offscreen from three standing angles plus
# a butterfly, so goalie mesh/pose changes can be SEEN without launching the
# game. A bare-instantiated goalie is a collapsed lump — every part is placed
# per-tick by its controller — so this drives the real pose builder directly:
# a GoalieBodyConfigBuilder.Inputs bundle (state + defaults) rebuilt and
# snapped with apply_body_config(config, 1.0) each frame. The goalie faces −Z.
#
# Needs a real (software) renderer, not --headless. On the web container:
#
#   LIBGL_ALWAYS_SOFTWARE=1 xvfb-run -a godot --path . \
#       --rendering-driver opengl3 --audio-driver Dummy \
#       -s res://tools/goalie_capture.gd
#
# Locally any GPU works: drop the env var and xvfb-run. Output paths print
# on save (user:// — never the repo tree, so captures can't be committed).

var _frames: int = 0
var _camera: Camera3D = null
var _goalie: Node3D = null
var _builder: GoalieBodyConfigBuilder = null
var _inputs: GoalieBodyConfigBuilder.Inputs = null


func _init() -> void:
	DisplayServer.window_set_size(Vector2i(512, 640))
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.10, 0.11, 0.14)
	env.environment = e
	root.add_child(env)

	_camera = Camera3D.new()
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
	plane.size = Vector2(8, 8)
	floor_mesh.mesh = plane
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(0.55, 0.60, 0.66)
	floor_mesh.material_override = fm
	root.add_child(floor_mesh)

	process_frame.connect(_on_frame)


func _on_frame() -> void:
	_frames += 1
	if _frames == 2:
		# Deferred past _init: autoload identifiers inside the goalie's
		# scripts don't compile-resolve until the tree is up.
		var scene: PackedScene = load("res://Scenes/Goalie.tscn")
		_goalie = scene.instantiate()
		root.add_child(_goalie)
		_goalie.call("apply_uniform", TeamColorRegistry.get_colors(1, 0))
		_goalie.call("apply_jersey_info", "MELON", 31)
		_builder = GoalieBodyConfigBuilder.new()
		_inputs = GoalieBodyConfigBuilder.Inputs.new()
		_inputs.state = GoalieStateMachine.State.READY
	elif _frames > 2:
		# Re-snap the pose every frame (the goalie lerps toward the config).
		_goalie.call("apply_body_config", _builder.build(_inputs), 1.0)
	if _frames == 20:
		_camera.position = Vector3(0.0, 1.0, -3.0)
		_camera.look_at(Vector3(0.0, 0.8, 0.0))
	elif _frames == 22:
		_save("goalie_front.png")
		_camera.position = Vector3(-2.8, 1.0, -1.2)
		_camera.look_at(Vector3(0.0, 0.75, 0.0))
	elif _frames == 30:
		_save("goalie_34.png")
		_camera.position = Vector3(-3.0, 1.0, 0.0)
		_camera.look_at(Vector3(0.0, 0.75, 0.0))
	elif _frames == 38:
		_save("goalie_side.png")
		_inputs.state = GoalieStateMachine.State.BUTTERFLY
		_camera.position = Vector3(-0.9, 1.0, -2.8)
		_camera.look_at(Vector3(0.0, 0.6, 0.0))
	elif _frames == 50:
		_save("goalie_butterfly.png")
		quit()


func _save(fname: String) -> void:
	var img: Image = root.get_texture().get_image()
	var path: String = "user://" + fname
	img.save_png(path)
	print("saved ", ProjectSettings.globalize_path(path))
