extends SceneTree

# Dev visualizer: renders the whole stick-model catalogue offscreen — every
# colorway standing on its blade above its name — and saves PNGs from two
# angles, so stick designs can be SEEN without launching the game. Each stick
# is the stick workbench's own assembly (procedural blade at the M92 pattern,
# shaft box on the flex shader, butt knob — the seats from
# StickEditorPopup._rebuild_preview; keep the two in sync) painted through
# StickStyle/StickModelRegistry, so what lands in the PNG is what the rink
# renders. Bare blade and bare grip on purpose: the sheet shows the colorway,
# not a tape job over it.
#
# Needs a real (software) renderer, not --headless. On the web container:
#
#   LIBGL_ALWAYS_SOFTWARE=1 xvfb-run -a godot --path . \
#       --rendering-driver opengl3 --audio-driver Dummy \
#       -s res://tools/stick_capture.gd
#
# Locally any GPU works: drop the env var and xvfb-run. Output paths print
# on save (user:// — never the repo tree, so captures can't be committed).

const _LIE_DEG: float = 42.0
const _HOSEL_LEN_M: float = 0.085
const _SHAFT_CROSS := Vector2(0.04, 0.05)
const _KNOB_HEIGHT_M: float = 0.05
const _KNOB_COLOR := Color(0.88, 0.88, 0.86)
# The M92 all-rounder — one pattern across the sheet so only the colorway
# varies between columns.
const _PATTERN: int = 1

# Heel-to-heel spacing. The sticks lean much further than this, but they lean
# in parallel, so the columns rack like sticks against the bench wall.
const _SPACING_M: float = 0.5
const _ORTHO_MARGIN_M: float = 0.44
const _LABEL_DROP_M: float = 0.07
# Side shot: brand face square to the camera. Three-quarter: enough turn to
# read the blade face and the weave.
const _SIDE_DEG: float = 90.0
const _THREE_QUARTER_DEG: float = 35.0

var _frames: int = 0
var _holders: Array[Node3D] = []
var _stick_len: float = 0.0


func _init() -> void:
	DisplayServer.window_set_size(Vector2i(1600, 560))
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.10, 0.11, 0.14)
	# Flat ambient lift so the turned faces of the three-quarter shot keep
	# their honest color — this is a catalogue sheet, not a beauty render.
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color.WHITE
	e.ambient_light_energy = 0.55
	env.environment = e
	root.add_child(env)

	# The neutral build's cut, exactly as the rink computes it.
	_stick_len = GameRules.DEFAULT_STICK_LENGTH_M \
			* PlayerAttributes.all_average().stick_len_mult() + Skater.SHAFT_BUTT_EXTEND_M

	var count: int = StickModelRegistry.count()
	var span: float = _SPACING_M * float(count - 1)
	# At the side yaw the toe reaches one way and the leaning shaft the other;
	# the lineup's true extent (and its center) comes from those overhangs.
	var toe_reach: float = GameRules.DEFAULT_BLADE_LENGTH_M
	var butt_reach: float = cos(deg_to_rad(_LIE_DEG)) * _stick_len
	var center_x: float = (butt_reach - toe_reach) * 0.5

	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	# KEEP_WIDTH so `size` frames the lineup's WIDTH — the dimension that
	# grows when a model is added to the catalogue.
	camera.keep_aspect = Camera3D.KEEP_WIDTH
	camera.size = span + toe_reach + butt_reach + _ORTHO_MARGIN_M
	camera.position = Vector3(center_x, 0.45, 3.0)
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

	_add_shelf(span + toe_reach + butt_reach, center_x)

	for model: int in count:
		var x: float = -span * 0.5 + _SPACING_M * float(model)
		var holder := Node3D.new()
		holder.position = Vector3(x, 0.0, 0.0)
		holder.rotation_degrees = Vector3(0.0, _SIDE_DEG, 0.0)
		root.add_child(holder)
		_holders.append(holder)
		_build_stick(holder, model)

		var label := Label3D.new()
		label.text = tr(StickModelRegistry.NAME_KEYS[model])
		label.pixel_size = 0.0011
		label.font_size = 64
		label.position = Vector3(x, -_LABEL_DROP_M, 0.4)
		root.add_child(label)

	process_frame.connect(_on_frame)


func _add_shelf(width: float, center_x: float) -> void:
	var mi := MeshInstance3D.new()
	var slab := BoxMesh.new()
	slab.size = Vector3(width + _SPACING_M, 0.02, 0.9)
	mi.mesh = slab
	mi.material_override = _mat(Color(0.16, 0.18, 0.22), 0.6)
	mi.position = Vector3(center_x, -0.011, 0.0)
	root.add_child(mi)


# One stick under `holder`, StickEditorPopup._rebuild_preview's assembly:
# heel-origin blade at the pattern, shaft climbing from the heel at the lie
# angle, knob capping the butt. All materials come from the same factories
# the rink uses.
func _build_stick(holder: Node3D, model: int) -> void:
	var p := StickBladeMeshBuilder.Params.new()
	p.length = GameRules.DEFAULT_BLADE_LENGTH_M
	p.curve_depth = Skater.BLADE_PATTERN_DEPTH[_PATTERN]
	p.curve_power = Skater.BLADE_PATTERN_POWER[_PATTERN]
	p.face_open_deg = Skater.BLADE_PATTERN_FACE_DEG[_PATTERN]
	p.toe_round_m = Skater.BLADE_PATTERN_TOE_ROUND[_PATTERN]
	p.curve_sign = -1.0
	p.hosel_length = _HOSEL_LEN_M
	p.hosel_angle_deg = _LIE_DEG
	var blade := MeshInstance3D.new()
	blade.mesh = StickBladeMeshBuilder.build(p)
	blade.material_override = StickStyle.make_blade_material(model)
	holder.add_child(blade)

	var shaft := MeshInstance3D.new()
	var shaft_box := BoxMesh.new()
	shaft_box.size = Vector3(_SHAFT_CROSS.x, _SHAFT_CROSS.y, 1.0)
	shaft.mesh = shaft_box
	var shaft_mat: ShaderMaterial = StickStyle.make_shaft_material(model)
	# Live uniforms the rink drives per frame: the real length (band anchoring
	# reads it) and a bare grip so nothing covers the colorway.
	shaft_mat.set_shader_parameter(&"shaft_len_m", _stick_len)
	shaft_mat.set_shader_parameter(&"grip_mode", 0)
	shaft.material_override = shaft_mat
	var lie: float = deg_to_rad(_LIE_DEG)
	var axis := Vector3(0.0, sin(lie), cos(lie))
	shaft.transform = Transform3D(
			Basis.looking_at(-axis, Vector3.UP)
			* Basis.from_scale(Vector3(1.0, 1.0, _stick_len)),
			axis * (_stick_len * 0.5))
	holder.add_child(shaft)

	var knob := MeshInstance3D.new()
	var knob_cyl := CylinderMesh.new()
	knob_cyl.top_radius = 0.035
	knob_cyl.bottom_radius = 0.03
	knob_cyl.height = _KNOB_HEIGHT_M
	knob_cyl.radial_segments = 12
	knob.mesh = knob_cyl
	knob.transform = Transform3D(
			Basis.looking_at(axis, Vector3.UP) * Basis(Vector3.RIGHT, PI * 0.5),
			axis * (_stick_len - _KNOB_HEIGHT_M * 0.5 + 0.01))
	knob.material_override = _mat(_KNOB_COLOR, 0.9)
	holder.add_child(knob)


func _mat(c: Color, r: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = r
	return m


func _on_frame() -> void:
	_frames += 1
	if _frames == 12:
		_save("sticks_side.png")
		for holder: Node3D in _holders:
			holder.rotation_degrees = Vector3(0.0, _THREE_QUARTER_DEG, 0.0)
	elif _frames == 24:
		_save("sticks_three_quarter.png")
		quit()


func _save(fname: String) -> void:
	var img: Image = root.get_texture().get_image()
	var path: String = "user://" + fname
	img.save_png(path)
	print("saved ", ProjectSettings.globalize_path(path))
