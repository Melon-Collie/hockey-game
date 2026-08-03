extends SceneTree

# Dev visualizer: renders the whole gear catalogue offscreen — every skate model
# above its name, every glove model above its own, and the helmet face options
# on a third shelf — and saves PNGs from two angles, so gear changes can be
# SEEN without launching the game. Each piece is the gear workbench's own
# assembly (shared SkaterMeshBuilder parts, the seats from
# GearEditorPopup._build_preview — keep the two in sync) painted through
# GearModelRegistry, so what lands in the PNG is what the rink paints.
#
# Needs a real (software) renderer, not --headless. On the web container:
#
#   LIBGL_ALWAYS_SOFTWARE=1 xvfb-run -a godot --path . \
#       --rendering-driver opengl3 --audio-driver Dummy \
#       -s res://tools/gear_capture.gd
#
# Locally any GPU works: drop the env var and xvfb-run. Output paths print
# on save (user:// — never the repo tree, so captures can't be committed).
#
# MITTS_TEAM_SLOT picks which team's kit the lineup is dressed in (default 0).
# Models resolve their LIGHT / TEAM / ACCENT zones against a real preset, so
# the sheet is only honest for the team it names — shoot a cream-white team
# and a pure-white one to see the spread.

const _BOOT_ROT := Basis(Vector3(0, 0, -1), Vector3(1, 0, 0), Vector3(0, -1, 0))
const _BLADE_ICE_M: float = 0.080 + SkaterMeshBuilder.SKATE_LIFT_M
const _LACE_COLOR := Color(0.88, 0.88, 0.86)
const _TEAM_SLOT_ENV: String = "MITTS_TEAM_SLOT"

# Both rows are shot with an ORTHOGONAL camera: perspective across a two-metre
# lineup would frame the outer pieces differently from the middle ones, which
# is exactly the comparison the sheet exists to make.
const _SPACING_M: float = 0.42
# Total horizontal margin around the lineup, in metres of world space.
const _ORTHO_MARGIN_M: float = 0.44
# The gloves stand on their own shelf above the skates; the helmets above both.
const _GLOVE_ROW_Y: float = 0.42
const _FACE_ROW_Y: float = 0.84
const _LABEL_DROP_M: float = 0.055
# Glove display sizes — larger than the workbench's, so a glove reads at about
# the scale of the skate under it (the live rig sizes the fist off the hand
# sphere; nothing here is a placement input).
const _FIST_SCALE: float = 0.105
const _CUFF_RADIUS: float = 0.080
# Yaw applied to every piece for the second shot — the same three-quarter
# angle on each, rather than moving the camera (which ortho would not honor).
const _THREE_QUARTER_DEG: float = 40.0

var _frames: int = 0
var _holders: Array[Node3D] = []
# The kit every model resolves against — home side, so TEAM lands on the
# jersey's own glove color for gloves and the primary for skates.
var _kit: Dictionary = {}
var _team_name: String = ""


func _init() -> void:
	DisplayServer.window_set_size(Vector2i(1800, 900))
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.10, 0.11, 0.14)
	env.environment = e
	root.add_child(env)

	var slot: int = int(OS.get_environment(_TEAM_SLOT_ENV))
	_kit = TeamColorRegistry.get_colors(slot, 0)
	_team_name = TeamColorRegistry.get_preset_name(slot)
	print("dressing the catalogue in ", _team_name)

	var count: int = maxi(GearModelRegistry.skate_count(), GearModelRegistry.glove_count())
	var span: float = _SPACING_M * float(count - 1)

	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	# KEEP_WIDTH so `size` frames the lineup's WIDTH — the default keeps the
	# height instead, which sizes the shot off the one dimension that doesn't
	# grow when a model is added to the catalogue.
	camera.keep_aspect = Camera3D.KEEP_WIDTH
	camera.size = span + _ORTHO_MARGIN_M
	camera.position = Vector3(0.0, 0.55, 1.0)
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

	_add_shelf(span, 0.0)
	_add_shelf(span, _GLOVE_ROW_Y)
	_add_shelf(span, _FACE_ROW_Y)

	for model: int in GearModelRegistry.skate_count():
		_place(span, float(model), model, 0.0,
				GearModelRegistry.SKATE_NAME_KEYS[model], _build_skate)
	for model: int in GearModelRegistry.glove_count():
		_place(span, float(model), model, _GLOVE_ROW_Y,
				GearModelRegistry.GLOVE_NAME_KEYS[model], _build_glove)
	# The face row is shorter than the model rows — shift it half the
	# difference so it sits centered over them.
	var face_shift: float = float(count - GearModelRegistry.face_count()) * 0.5
	for option: int in GearModelRegistry.face_count():
		_place(span, float(option) + face_shift, option, _FACE_ROW_Y,
				GearModelRegistry.FACE_NAME_KEYS[option], _build_face)

	process_frame.connect(_on_frame)


# Seats one catalogue row entry: the piece hangs off a holder so the second
# shot can yaw the whole assembly in one write, and its label is NOT a child
# of that holder — labels must keep facing the camera when the pieces turn.
# `col` is the lineup column (fractional for centered short rows); `model`
# is the catalogue index handed to `build`.
func _place(span: float, col: float, model: int, row_y: float, name_key: StringName,
		build: Callable) -> void:
	var x: float = -span * 0.5 + _SPACING_M * col
	var holder := Node3D.new()
	holder.position = Vector3(x, row_y, 0.0)
	root.add_child(holder)
	_holders.append(holder)
	build.call(holder, model)

	var label := Label3D.new()
	label.text = tr(name_key)
	label.pixel_size = 0.0011
	label.font_size = 64
	label.position = Vector3(x, row_y - _LABEL_DROP_M, 0.16)
	root.add_child(label)


func _add_shelf(span: float, y: float) -> void:
	var mi := MeshInstance3D.new()
	var slab := BoxMesh.new()
	slab.size = Vector3(span + _SPACING_M, 0.02, 0.6)
	mi.mesh = slab
	mi.material_override = _mat(Color(0.16, 0.18, 0.22), 0.6)
	mi.position = Vector3(0.0, y - 0.011, 0.0)
	root.add_child(mi)


# One skate under `holder`, painted from the model's zones. Mirrors
# GearEditorPopup._build_preview: the boot rides the rotated boot frame seated
# so the runner stands on the shelf, and the collar takes the appearance rig's
# neutral-build scaling (calf girth laterally, height vertically — the boot
# deliberately never scales) with the accent band seated on it.
func _build_skate(holder: Node3D, model: int) -> void:
	var skate_at := Vector3(0.0, _BLADE_ICE_M, 0.0)
	# Boot and blade are multi-surface pieces (quarter/toe, holder/runner), so
	# they paint per SURFACE — a material_override would flatten each pair.
	var boot := MeshInstance3D.new()
	boot.mesh = SkaterMeshBuilder.shared_boot()
	boot.transform = Transform3D(_BOOT_ROT, skate_at)
	boot.set_surface_override_material(SkaterMeshBuilder.BOOT_PART_QUARTER,
			_mat(_skate_zone(model, GearModelRegistry.SKATE_QUARTER), 0.42))
	boot.set_surface_override_material(SkaterMeshBuilder.BOOT_PART_TOE,
			_mat(_skate_zone(model, GearModelRegistry.SKATE_TOE), 0.42))
	holder.add_child(boot)

	var blade := MeshInstance3D.new()
	blade.mesh = SkaterMeshBuilder.shared_skate_blade()
	blade.transform = Transform3D(_BOOT_ROT, skate_at)
	blade.set_surface_override_material(SkaterMeshBuilder.BLADE_PART_HOLDER,
			_mat(_skate_zone(model, GearModelRegistry.SKATE_HOLDER), 0.42))
	blade.set_surface_override_material(SkaterMeshBuilder.BLADE_PART_RUNNER,
			_mat(SkaterMeshBuilder.BLADE_STEEL_COLOR, 0.25))
	holder.add_child(blade)

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
	collar.material_override = _mat(_skate_zone(model, GearModelRegistry.SKATE_COLLAR), 0.42)
	holder.add_child(collar)

	var stripe := MeshInstance3D.new()
	stripe.mesh = SkaterMeshBuilder.shared_skate_stripe()
	stripe.position = Vector3(0.0, 0.045, 0.0)
	stripe.scale = Vector3(0.092, 1.0, 0.092)
	stripe.material_override = _mat(_skate_zone(model, GearModelRegistry.SKATE_STRIPE), 0.42)
	collar.add_child(stripe)


# One glove under `holder`: the fist stands fingers-down (station order runs
# wrist → fingers along −Y) with the cuff ring at the wrist above it, the same
# arrangement the workbench turntable uses. The fist is a multi-surface piece
# (back of the hand / fingers), so it paints per surface.
func _build_glove(holder: Node3D, model: int) -> void:
	var fist := MeshInstance3D.new()
	fist.mesh = SkaterMeshBuilder.shared_glove_fist()
	fist.transform = Transform3D(
			Basis.from_scale(Vector3.ONE * _FIST_SCALE),
			Vector3(0.0, 0.95 * _FIST_SCALE + 0.001, 0.0))
	fist.set_surface_override_material(SkaterMeshBuilder.FIST_PART_BACK,
			_mat(_glove_zone(model, GearModelRegistry.GLOVE_BODY), 0.9))
	fist.set_surface_override_material(SkaterMeshBuilder.FIST_PART_FINGERS,
			_mat(_glove_zone(model, GearModelRegistry.GLOVE_FINGERS), 0.9))
	holder.add_child(fist)

	var cuff := MeshInstance3D.new()
	cuff.mesh = SkaterMeshBuilder.shared_cuff()
	cuff.transform = Transform3D(
			Basis.from_scale(Vector3(_CUFF_RADIUS, 1.0, _CUFF_RADIUS)),
			Vector3(0.0, 1.9 * _FIST_SCALE + SkaterMeshBuilder.CUFF_HEIGHT_M * 0.4, 0.0))
	cuff.material_override = _mat(_glove_zone(model, GearModelRegistry.GLOVE_CUFF), 0.9)
	holder.add_child(cuff)


# One helmet under `holder`, spun to face the camera (the mesh's face opening
# is −Z), wearing the option's piece and the kit's own helmet color; the
# head/neck skin surface keeps the assembly's default skin material. The face
# piece paints through the rink's own material factory, so the smoke/steel/
# clear looks in the PNG are the ones the ice shows.
func _build_face(holder: Node3D, option: int) -> void:
	var helmet_at := Transform3D(Basis(Vector3.UP, PI), Vector3(0.0, 0.115, 0.0))
	var helmet := MeshInstance3D.new()
	helmet.mesh = SkaterMeshBuilder.shared_helmet_assembly()
	helmet.transform = helmet_at
	helmet.set_surface_override_material(SkaterMeshBuilder.HELMET_SURF_SHELL,
			_mat(_kit.uniform.helmet, 0.28))
	holder.add_child(helmet)

	var piece := MeshInstance3D.new()
	piece.mesh = SkaterMeshBuilder.shared_face_gear(option)
	piece.material_override = SkaterMeshBuilder.make_face_gear_material(option)
	piece.transform = helmet_at
	holder.add_child(piece)


func _skate_zone(model: int, zone: int) -> Color:
	return GearModelRegistry.skate_color(model, zone,
			_kit.primary, _kit.secondary, _kit.light)


func _glove_zone(model: int, zone: int) -> Color:
	return GearModelRegistry.glove_color(model, zone,
			_kit.gloves, _kit.glove_accent, _kit.light)


func _mat(c: Color, r: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = r
	return m


func _on_frame() -> void:
	_frames += 1
	if _frames == 12:
		_save("gear_%s_side.png" % _team_name.to_lower())
		for holder: Node3D in _holders:
			holder.rotation_degrees = Vector3(0.0, _THREE_QUARTER_DEG, 0.0)
	elif _frames == 24:
		_save("gear_%s_three_quarter.png" % _team_name.to_lower())
		quit()


func _save(fname: String) -> void:
	var img: Image = root.get_texture().get_image()
	var path: String = "user://" + fname
	img.save_png(path)
	print("saved ", ProjectSettings.globalize_path(path))
