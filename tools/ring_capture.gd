extends SceneTree

# Dev visualizer: renders the ice shader's HUD layer offscreen and saves a PNG,
# so the analytic rings and chevrons can be SEEN without launching the game.
# Drives the shader uniforms directly, which is the point — it needs no skaters,
# no camera rig and no game state, so it isolates the shader from everything
# that could otherwise explain a wrong-looking result.
#
# The skater matrix cannot cover this: it renders skaters on a blank plane, not
# the rink, so nothing there exercises the ice material at all.
#
# Needs a real (software) renderer, not --headless. On the web container:
#
#   LIBGL_ALWAYS_SOFTWARE=1 xvfb-run -a godot --path . \
#       --rendering-driver opengl3 --audio-driver Dummy \
#       -s res://tools/ring_capture.gd
#
# Locally any GPU works: drop the env var and xvfb-run. Output path prints on
# save (user:// — never the repo tree, so captures can't be committed).
var _frames: int = 0
func _init() -> void:
	DisplayServer.window_set_size(Vector2i(700, 700))
	var env := WorldEnvironment.new(); var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.05, 0.06, 0.09)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(1,1,1); e.ambient_light_energy = 1.0
	env.environment = e; root.add_child(env)
	var cam := Camera3D.new(); cam.position = Vector3(0,7,0)
	cam.rotation_degrees = Vector3(-90,0,0); root.add_child(cam)
	var plane := MeshInstance3D.new(); var pm := PlaneMesh.new()
	pm.size = Vector2(26,60); plane.mesh = pm
	var m := ShaderMaterial.new(); m.shader = load("res://Shaders/ice.gdshader")
	m.set_shader_parameter("rink_size", Vector2(26,60))
	m.set_shader_parameter("subsurface_fade", 0.0)
	var pos := PackedVector4Array(); pos.resize(12)
	var col := PackedVector4Array(); col.resize(12)
	var chev := PackedVector4Array(); chev.resize(12)
	pos[0] = Vector4(-2.0, 0.0, 0.45, 0.39); col[0] = Vector4(1,0.3,0.3,0.85)
	pos[1] = Vector4(0.5, 0.0, 0.45, 0.39);  col[1] = Vector4(0.3,1,0.4,0.85)
	pos[2] = Vector4(3.0, 0.0, 0.45, 0.39);  col[2] = Vector4(0.4,0.6,1,0.85)
	# 1, 2 and 3 stacked chevrons, apex offset to the side of each ring.
	chev[0] = Vector4(-2.0, 0.55, 1.0, 0.0)
	chev[1] = Vector4(0.5, 0.55, 2.0, 0.0)
	chev[2] = Vector4(3.0, 0.55, 3.0, 0.0)
	m.set_shader_parameter("ring_pos", pos); m.set_shader_parameter("ring_col", col)
	m.set_shader_parameter("ring_count", 3)
	m.set_shader_parameter("chevron_pos", chev)
	m.set_shader_parameter("chevron_count", 3)
	m.set_shader_parameter("hud_stroke_col", Vector4(1,1,1,0.9))
	# Slapper one-timer indicator (self-only, so a single set of uniforms).
	# Placed off to the right of the rings with a live aim and a half-converged
	# ring, which is the state that exercises every stroke at once.
	m.set_shader_parameter("slapper_active", true)
	m.set_shader_parameter("slapper_arrow", true)
	m.set_shader_parameter("slapper_zone", Vector4(-1.6, -1.7, 0.5, 0.55))
	m.set_shader_parameter("slapper_dir", Vector2(0.35, -1.0).normalized())
	# Stamina gauge at 35% under the middle ring — the fill should start at the
	# top and sweep toward screen-left, with the faint track completing the annulus.
	m.set_shader_parameter("stamina_active", true)
	m.set_shader_parameter("stamina_zone", Vector4(0.5, 1.6, 0.35, 0.0))
	m.set_shader_parameter("stamina_up", Vector2(0.0, -1.0))
	m.set_shader_parameter("stamina_fill_col", Vector4(0.20, 0.95, 0.40, 0.85))
	m.set_shader_parameter("stamina_track_col", Vector4(0.06, 0.08, 0.11, 0.47))
	m.set_shader_parameter("hud_screen_down", Vector2(0,1))
	plane.material_override = m; root.add_child(plane)
func _process(_d: float) -> bool:
	_frames += 1
	if _frames < 10: return false
	root.get_texture().get_image().save_png("user://ring_capture.png")
	print("saved"); return true
