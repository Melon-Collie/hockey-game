extends SceneTree

# Offscreen renderer for the arena bowl — the one thing a headless test cannot
# check about procedural geometry is whether it LOOKS right. Builds an
# ArenaStands (plus a rink floor plane for the eye to sit on), points a camera at
# a named shot, and writes a PNG.
#
#   xvfb-run -a godot --path . --rendering-driver opengl3 \
#       --rendering-method gl_compatibility --resolution 1280x720 \
#       -s res://tools/arena_preview.gd
#
# A run prints one "Failed to load script ... Compilation failed" before it
# works: Godot compiles the `-s` script once before the autoloads that own the
# class names it depends on have registered, then again after. The second pass
# is the one that runs.
#
# The Compatibility renderer is what makes this work without a GPU: Vulkan on
# llvmpipe is far slower and forward+ needs it. Shot list and output directory
# come from the environment so the caller drives it without editing this file:
# ARENA_PREVIEW_OUT (default user://arena_preview), ARENA_PREVIEW_SHOTS (comma
# separated names from _SHOTS, default all).

# Each shot is a camera placement in world metres. `bench` and `box` are the
# reason this exists — they frame rinkside staff against the crowd behind them,
# which is where a mis-scaled figure is obvious and nowhere else is.
const _SHOTS: Dictionary = {
	"coaches": {
		"from": Vector3(9.0, 2.0, 4.4),
		"look_at": Vector3(14.1, 2.0, 4.4),
		"fov": 50.0,
	},
	"timekeepers": {
		"from": Vector3(-9.0, 2.0, 0.0),
		"look_at": Vector3(-14.1, 2.0, 0.0),
		"fov": 50.0,
	},
	"attendant": {
		"from": Vector3(-9.5, 2.0, -4.2),
		"look_at": Vector3(-14.1, 2.0, -4.2),
		"fov": 50.0,
	},
	"bench": {
		"from": Vector3(8.0, 2.6, 9.5),
		"look_at": Vector3(14.1, 1.9, 4.4),
		"fov": 55.0,
	},
	"wide": {
		"from": Vector3(26.0, 14.0, 34.0),
		"look_at": Vector3(0.0, 2.0, 0.0),
		"fov": 50.0,
	},
}


func _initialize() -> void:
	_render_shots()


# Deferred one frame past _initialize: the root window is not finished setting
# itself up when a `-s` script first runs, and nodes parented into it before
# that report themselves as outside the tree (so global_position and look_at
# both fail).
func _render_shots() -> void:
	await process_frame
	var out_dir: String = OS.get_environment("ARENA_PREVIEW_OUT")
	if out_dir.is_empty():
		out_dir = "user://arena_preview"
	DirAccess.make_dir_recursive_absolute(out_dir)

	var wanted: Array[String] = []
	var requested: String = OS.get_environment("ARENA_PREVIEW_SHOTS")
	if requested.is_empty():
		for name: String in _SHOTS:
			wanted.append(name)
	else:
		for name: String in requested.split(",", false):
			wanted.append(name.strip_edges())

	var world := Node3D.new()
	root.add_child(world)
	_light(world)
	var stands := ArenaStands.new()
	world.add_child(stands)
	_ice(world, stands)

	var cam := Camera3D.new()
	world.add_child(cam)
	cam.current = true

	for name: String in wanted:
		if not _SHOTS.has(name):
			push_warning("unknown shot: %s" % name)
			continue
		var shot: Dictionary = _SHOTS[name]
		cam.fov = shot.fov
		cam.global_position = shot.from
		cam.look_at(shot.look_at)
		# Two frames: the first commits the transform, the second is drawn with it.
		await process_frame
		await process_frame
		var image: Image = root.get_texture().get_image()
		var path: String = "%s/%s.png" % [out_dir, name]
		image.save_png(path)
		print("[arena_preview] %s -> %s" % [name, ProjectSettings.globalize_path(path)])

	quit()


# Sun plus a lifted ambient, standing in for the arena rig: the staff take a lit
# material, so an unlit render says nothing about how they read.
func _light(world: Node3D) -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55.0, -35.0, 0.0)
	sun.light_energy = 1.1
	world.add_child(sun)
	var env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.05, 0.06, 0.08)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.75, 0.78, 0.85)
	environment.ambient_light_energy = 0.55
	env.environment = environment
	world.add_child(env)


# A plain white sheet at y=0 the size of the rink — not the real ice, just a
# floor so figures have something to stand against instead of a void.
func _ice(world: Node3D, stands: ArenaStands) -> void:
	var plane := MeshInstance3D.new()
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(stands.rink_width, stands.rink_length)
	plane.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.88, 0.91, 0.95)
	plane.material_override = mat
	world.add_child(plane)
