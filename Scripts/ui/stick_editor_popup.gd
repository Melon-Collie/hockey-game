class_name StickEditorPopup
extends Control

# The stick workbench: every stick-related pick in one modal — the three gear
# slots (LENGTH / CURVE / FLEX, the stick rows that used to sit in
# AttributePickerPanel) and the tape job (blade tape color + coverage, knob
# color, handle wrap style) — arranged as compact dropdown rows around a live
# turntable preview assembled from the real in-game pieces: the procedural
# blade mesh at the picked pattern, the wrapped tape band, the flex shader
# pulsing a load-and-release bow scaled by the picked flex (and painting the
# picked handle wrap), and the shaft cut to the picked length.
#
# Rows whose pick changes gameplay (the gear) carry a gold asterisk; tape rows
# are cosmetic and never lock. A sub-editor, not a committer: opened by
# PlayerSettingsPopup or LobbyBuildPopup over their own modal, it edits
# pending values and hands them back through `stick_edited` on Done — the HOST
# owns snapshot/commit/revert, so Cancel here just discards this dialog's
# edits and the host's Cancel still reverts an applied Done.

signal stick_edited(curve: int, flex: int, length: int, tape_code: int)

# Gear tooltips (headline effects only, same prose the attribute panel used).
const _LENGTH_TOOLTIP: String = "Cut relative to your height.\nShort = snappier blade, finest close control, less reach.\nLong = more reach & sweep, slower to cut back."
const _CURVE_TOOLTIP: String = "Blade face.\nClosed = best backhand, hardest to elevate.\nOpen = easy elevation & quick release, weak backhand."
const _FLEX_TOOLTIP: String = "Shaft stiffness.\nWhippy = fastest release, softer shot ceiling.\nStiff = biggest shot, slower to load."

# Preview geometry mirrors the Skater defaults (blade_lie_deg,
# blade_hosel_length, shaft BoxMesh cross-section) — the preview is the same
# stick the rink renders, minus the hands holding it.
const _LIE_DEG: float = 42.0
const _HOSEL_LEN_M: float = 0.085
const _SHAFT_CROSS := Vector2(0.04, 0.05)
const _KNOB_HEIGHT_M: float = 0.05
const _STICK_FLEX_SHADER: Shader = preload("res://Shaders/stick_flex.gdshader")
const _SHAFT_COLOR := Color(0.06, 0.06, 0.07)
const _BLADE_COLOR := Color(0.05, 0.05, 0.05)
# Load-and-release pulse amplitude per FLEX gear (whippy bows deepest) — the
# preview's stand-in for charging a shot.
const _FLEX_PULSE_AMP_M: Array[float] = [0.085, 0.060, 0.040]
const _FLEX_PULSE_PERIOD_S: float = 1.6
const _TURNTABLE_RAD_PER_S: float = 0.7

# Dropdown option tables: display order + the wire value each row maps to.
const _LENGTH_KEYS: Array[StringName] = [
	&"STICK_LENGTH_SHORT", &"STICK_LENGTH_STANDARD", &"STICK_LENGTH_LONG"]
const _CURVE_KEYS: Array[StringName] = [
	&"STICK_CURVE_CLOSED", &"STICK_CURVE_BALANCED", &"STICK_CURVE_OPEN"]
const _FLEX_KEYS: Array[StringName] = [
	&"STICK_FLEX_WHIPPY", &"STICK_FLEX_MEDIUM", &"STICK_FLEX_STIFF"]
const _SPAN_OPTIONS: Array[int] = [
	StickTapeConfig.Span.FULL,
	StickTapeConfig.Span.HEEL_TO_MID,
	StickTapeConfig.Span.MID,
	StickTapeConfig.Span.TOE,
	StickTapeConfig.Span.NONE,
]
const _SPAN_KEYS: Array[StringName] = [
	&"TAPE_SPAN_FULL", &"TAPE_SPAN_HEEL_TO_MID", &"TAPE_SPAN_MID",
	&"TAPE_SPAN_TOE", &"TAPE_SPAN_NONE",
]
const _STYLE_OPTIONS: Array[int] = [
	StickTapeConfig.KnobStyle.KNOB,
	StickTapeConfig.KnobStyle.CANDY_CANE,
	StickTapeConfig.KnobStyle.FULL,
]
const _STYLE_KEYS: Array[StringName] = [
	&"TAPE_HANDLE_KNOB", &"TAPE_HANDLE_CANDY", &"TAPE_HANDLE_FULL",
]

# Pending picks (working state between open() and Done).
var _curve: int = PlayerAttributes.GEAR_BALANCED
var _flex: int = PlayerAttributes.GEAR_BALANCED
var _length: int = PlayerAttributes.GEAR_BALANCED
var _tape: StickTapeConfig = StickTapeConfig.new()
var _body: PlayerAttributes = null          # full build, for stick_len_mult()
var _gear_locked: bool = false
var _team_accent: Color = Color.WHITE

# Controls.
var _length_btn: OptionButton = null
var _curve_btn: OptionButton = null
var _flex_btn: OptionButton = null
var _span_btn: OptionButton = null
var _style_btn: OptionButton = null
var _blade_color_dd: SwatchDropdown = null
var _knob_color_dd: SwatchDropdown = null
var _lock_label: Label = null

# Preview scene.
var _viewport: SubViewport = null
var _turntable: Node3D = null
var _shaft: MeshInstance3D = null
var _shaft_mat: ShaderMaterial = null
var _blade: MeshInstance3D = null
var _tape_mesh: MeshInstance3D = null
var _knob: MeshInstance3D = null
var _floor_disc: MeshInstance3D = null
var _pulse_t: float = 0.0

# Focus scope (see LobbyBuildPopup.set_focus_scope).
var _focus_background: Control = null
var _focus_restore: Control = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	visible = false


func _process(delta: float) -> void:
	if not visible or _turntable == null:
		return
	_turntable.rotate_y(_TURNTABLE_RAD_PER_S * delta)
	# Charge-and-snap flex cycle: slow load to full bow, quick release. The
	# shader's endpoints are pinned, so only the material between them bends.
	_pulse_t = fmod(_pulse_t + delta, _FLEX_PULSE_PERIOD_S)
	var t: float = _pulse_t / _FLEX_PULSE_PERIOD_S
	var load: float = minf(t / 0.7, 1.0) if t < 0.7 else maxf(1.0 - (t - 0.7) / 0.12, 0.0)
	var amp: float = _FLEX_PULSE_AMP_M[clampi(_flex, 0, _FLEX_PULSE_AMP_M.size() - 1)]
	if _shaft_mat != null:
		_shaft_mat.set_shader_parameter(&"flex_m", amp * load)


# ── Construction ─────────────────────────────────────────────────────────────

func _build() -> void:
	var overlay := ColorRect.new()
	overlay.color = MenuStyle.SCRIM
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.gui_input.connect(_on_overlay_clicked)
	add_child(overlay)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", MenuStyle.panel())
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 12)
	panel.add_child(vbox)

	var close_row := HBoxContainer.new()
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	close_row.add_child(spacer)
	var close_btn := MenuStyle.close_button()
	close_btn.pressed.connect(_cancel)
	SoundManager.wire_button(close_btn)
	close_row.add_child(close_btn)
	vbox.add_child(close_row)

	var title := Label.new()
	title.text = tr(&"STICK_EDITOR_TITLE")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	MenuStyle.apply_heading(title)
	vbox.add_child(title)

	_build_preview(vbox)

	_lock_label = Label.new()
	_lock_label.text = tr(&"STICK_GEAR_LOCKED")
	_lock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lock_label.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	_lock_label.add_theme_font_size_override("font_size", 13)
	_lock_label.visible = false
	vbox.add_child(_lock_label)

	# Two columns under the preview: gameplay gear (asterisked) on the left,
	# tape (cosmetic) on the right — the split itself reinforces the legend.
	var columns := HBoxContainer.new()
	columns.alignment = BoxContainer.ALIGNMENT_CENTER
	columns.add_theme_constant_override("separation", 40)
	vbox.add_child(columns)

	var gear_col := VBoxContainer.new()
	gear_col.alignment = BoxContainer.ALIGNMENT_BEGIN
	gear_col.add_theme_constant_override("separation", 12)
	columns.add_child(gear_col)
	gear_col.add_child(_make_column_header(tr(&"STICK_COL_GEAR")))

	var tape_col := VBoxContainer.new()
	tape_col.alignment = BoxContainer.ALIGNMENT_BEGIN
	tape_col.add_theme_constant_override("separation", 12)
	columns.add_child(tape_col)
	tape_col.add_child(_make_column_header(tr(&"STICK_COL_TAPE")))

	_length_btn = _make_option_btn(_LENGTH_KEYS, _LENGTH_TOOLTIP, _on_length_selected)
	_add_row(gear_col, tr(&"STICK_GEAR_LENGTH"), _length_btn, true, _LENGTH_TOOLTIP)
	_curve_btn = _make_option_btn(_CURVE_KEYS, _CURVE_TOOLTIP, _on_curve_selected)
	_add_row(gear_col, tr(&"STICK_GEAR_CURVE"), _curve_btn, true, _CURVE_TOOLTIP)
	_flex_btn = _make_option_btn(_FLEX_KEYS, _FLEX_TOOLTIP, _on_flex_selected)
	_add_row(gear_col, tr(&"STICK_GEAR_FLEX"), _flex_btn, true, _FLEX_TOOLTIP)

	var legend := Label.new()
	legend.text = tr(&"STICK_GAMEPLAY_LEGEND")
	legend.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	legend.add_theme_color_override("font_color", MenuStyle.GOLD)
	legend.add_theme_font_size_override("font_size", 13)
	gear_col.add_child(legend)

	_blade_color_dd = SwatchDropdown.new()
	_blade_color_dd.selected.connect(_on_blade_color_selected)
	_add_row(tape_col, tr(&"TAPE_BLADE_LABEL"), _blade_color_dd, false, "")
	_span_btn = _make_option_btn(_SPAN_KEYS, "", _on_span_selected)
	_add_row(tape_col, tr(&"TAPE_COVERAGE_LABEL"), _span_btn, false, "")
	_knob_color_dd = SwatchDropdown.new()
	_knob_color_dd.selected.connect(_on_knob_color_selected)
	_add_row(tape_col, tr(&"TAPE_KNOB_LABEL"), _knob_color_dd, false, "")
	_style_btn = _make_option_btn(_STYLE_KEYS, "", _on_style_selected)
	_add_row(tape_col, tr(&"TAPE_HANDLE_LABEL"), _style_btn, false, "")

	var action_row := HBoxContainer.new()
	action_row.alignment = BoxContainer.ALIGNMENT_CENTER
	action_row.add_theme_constant_override("separation", 12)
	vbox.add_child(action_row)

	var done_btn := Button.new()
	done_btn.text = tr(&"STICK_EDITOR_DONE")
	MenuStyle.apply_primary_cta(done_btn, 18)
	done_btn.custom_minimum_size = Vector2(140, 44)
	done_btn.pressed.connect(_done)
	SoundManager.wire_button(done_btn)
	action_row.add_child(done_btn)

	var cancel_btn := Button.new()
	cancel_btn.text = tr(&"STICK_EDITOR_CANCEL")
	cancel_btn.custom_minimum_size = Vector2(140, 44)
	cancel_btn.add_theme_font_size_override("font_size", 18)
	cancel_btn.pressed.connect(_cancel)
	SoundManager.wire_button(cancel_btn)
	action_row.add_child(cancel_btn)


# Small muted all-caps column caption (the CSV rows are stored uppercase).
func _make_column_header(text: String) -> Label:
	var header := Label.new()
	header.text = text
	header.add_theme_font_size_override("font_size", 13)
	header.add_theme_color_override("font_color", MenuStyle.TEXT_MUTED)
	return header


func _make_option_btn(keys: Array[StringName], tooltip: String,
		handler: Callable) -> OptionButton:
	var btn := OptionButton.new()
	btn.custom_minimum_size = Vector2(180, 36)
	btn.add_theme_font_size_override("font_size", 15)
	btn.tooltip_text = tooltip
	for i: int in keys.size():
		btn.add_item(tr(keys[i]), i)
	SoundManager.wire_button(btn)
	btn.item_selected.connect(handler)
	return btn


# One labelled row. `gameplay` rows carry the gold asterisk the legend
# explains — the pick changes on-ice behavior, not just paint. Rows lead-align
# so the label column lines up within each side of the two-column layout.
func _add_row(vbox: VBoxContainer, label_text: String, control: Control,
		gameplay: bool, tooltip: String) -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_BEGIN
	row.add_theme_constant_override("separation", 12)
	vbox.add_child(row)

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(110, 0)
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", MenuStyle.TEXT_BODY)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_STOP
	label.tooltip_text = tooltip
	row.add_child(label)

	var star := Label.new()
	star.text = "*" if gameplay else " "
	star.custom_minimum_size = Vector2(14, 0)
	star.add_theme_font_size_override("font_size", 20)
	star.add_theme_color_override("font_color", MenuStyle.GOLD)
	star.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	star.tooltip_text = tr(&"STICK_GAMEPLAY_LEGEND") if gameplay else ""
	star.mouse_filter = Control.MOUSE_FILTER_STOP if gameplay else Control.MOUSE_FILTER_IGNORE
	row.add_child(star)

	row.add_child(control)


# The turntable viewport in a "display case": an inset well with a soft ice
# disc the stick stands on (and casts a real shadow onto — the grounding is
# what keeps the spin from reading flat). Own 3D world so the stick renders
# over the menu scrim. All meshes are the real in-game pieces.
func _build_preview(vbox: VBoxContainer) -> void:
	var case_panel := PanelContainer.new()
	var case_style := StyleBoxFlat.new()
	case_style.bg_color = MenuStyle.SURFACE_INPUT
	case_style.set_corner_radius_all(6)
	case_style.set_border_width_all(1)
	case_style.border_color = MenuStyle.TEAL_DIM
	case_style.set_content_margin_all(4)
	case_panel.add_theme_stylebox_override("panel", case_style)
	case_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	vbox.add_child(case_panel)

	var container := SubViewportContainer.new()
	container.stretch = true
	container.custom_minimum_size = Vector2(420, 250)
	case_panel.add_child(container)

	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.transparent_bg = true
	_viewport.msaa_3d = Viewport.MSAA_4X
	container.add_child(_viewport)

	var camera := Camera3D.new()
	# Far enough that the whole diagonal (butt to toe ≈ 1.55 m, spinning about
	# its midpoint) stays inside the vertical frustum at every rotation angle;
	# raised and pitched a touch so the ice disc reads as a ground plane.
	camera.position = Vector3(0.0, 0.35, 2.6)
	camera.rotation_degrees = Vector3(-7.7, 0.0, 0.0)
	camera.fov = 45.0
	_viewport.add_child(camera)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-42.0, 35.0, 0.0)
	light.light_energy = 1.3
	light.shadow_enabled = true
	_viewport.add_child(light)

	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-15.0, -140.0, 0.0)
	fill.light_energy = 0.5
	_viewport.add_child(fill)

	# Ice puddle under the stick. Outside the turntable (a spinning circle is
	# invisible motion anyway); _rebuild_preview seats it just under the sole,
	# which moves with the picked stick length.
	_floor_disc = MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = 0.85
	disc.bottom_radius = 0.85
	disc.height = 0.02
	disc.radial_segments = 48
	_floor_disc.mesh = disc
	var disc_mat := StandardMaterial3D.new()
	disc_mat.albedo_color = MenuStyle.SURFACE_ELEV
	disc_mat.roughness = 0.35
	_floor_disc.material_override = disc_mat
	_viewport.add_child(_floor_disc)

	_turntable = Node3D.new()
	_viewport.add_child(_turntable)

	_shaft = MeshInstance3D.new()
	var shaft_box := BoxMesh.new()
	shaft_box.size = Vector3(_SHAFT_CROSS.x, _SHAFT_CROSS.y, 1.0)
	shaft_box.subdivide_depth = 12  # the flex shader needs length-wise vertices
	_shaft.mesh = shaft_box
	_shaft_mat = ShaderMaterial.new()
	_shaft_mat.shader = _STICK_FLEX_SHADER
	_shaft_mat.set_shader_parameter(&"albedo", _SHAFT_COLOR)
	_shaft_mat.set_shader_parameter(&"roughness", 0.4)
	_shaft.material_override = _shaft_mat
	_turntable.add_child(_shaft)

	_blade = MeshInstance3D.new()
	_blade.material_override = _make_mat(_BLADE_COLOR, 0.5)
	_turntable.add_child(_blade)

	_tape_mesh = MeshInstance3D.new()
	_blade.add_child(_tape_mesh)

	_knob = MeshInstance3D.new()
	var knob_cyl := CylinderMesh.new()
	knob_cyl.top_radius = 0.035
	knob_cyl.bottom_radius = 0.03
	knob_cyl.height = _KNOB_HEIGHT_M
	knob_cyl.radial_segments = 12
	_knob.mesh = knob_cyl
	_turntable.add_child(_knob)


# ── Host API ─────────────────────────────────────────────────────────────────

func set_focus_scope(background: Control, restore: Control) -> void:
	_focus_background = background
	_focus_restore = restore


# `attrs` is the host's PENDING build (this popup edits its stick gear);
# `gear_locked` mirrors the attribute lock (online match) — tape stays live.
func open(attrs: PlayerAttributes, tape_code: int, gear_locked: bool,
		team_accent: Color) -> void:
	_body = attrs
	_curve = attrs.curve
	_flex = attrs.flex
	_length = attrs.length
	_tape = StickTapeConfig.from_code(tape_code)
	_gear_locked = gear_locked
	_team_accent = team_accent
	_pulse_t = 0.0
	_refresh()
	_rebuild_preview()
	visible = true
	ControllerNav.open_modal(_focus_background, self, _length_btn)


func _done() -> void:
	stick_edited.emit(_curve, _flex, _length, _tape.to_code())
	_close()


func _cancel() -> void:
	_close()


func _close() -> void:
	visible = false
	ControllerNav.close_modal(_focus_background, _focus_restore)


func _on_overlay_clicked(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		_cancel()


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed(&"ui_cancel"):
		_cancel()
		get_viewport().set_input_as_handled()


# ── Interaction ──────────────────────────────────────────────────────────────

func _on_length_selected(option: int) -> void:
	if not _gear_locked:
		_length = option
	_refresh()
	_rebuild_preview()


func _on_curve_selected(option: int) -> void:
	if not _gear_locked:
		_curve = option
	_refresh()
	_rebuild_preview()


func _on_flex_selected(option: int) -> void:
	if not _gear_locked:
		_flex = option
	_refresh()
	_rebuild_preview()


func _on_blade_color_selected(index: int) -> void:
	_tape = StickTapeConfig.new(index, _tape.span, _tape.knob_color, _tape.knob_style)
	_rebuild_preview()


func _on_knob_color_selected(index: int) -> void:
	_tape = StickTapeConfig.new(_tape.blade_color, _tape.span, index, _tape.knob_style)
	_rebuild_preview()


func _on_span_selected(option: int) -> void:
	_tape = StickTapeConfig.new(_tape.blade_color, _SPAN_OPTIONS[option],
			_tape.knob_color, _tape.knob_style)
	_rebuild_preview()


func _on_style_selected(option: int) -> void:
	_tape = StickTapeConfig.new(_tape.blade_color, _tape.span,
			_tape.knob_color, _STYLE_OPTIONS[option])
	_rebuild_preview()


# ── Rendering ────────────────────────────────────────────────────────────────

func _refresh() -> void:
	_length_btn.select(clampi(_length, 0, _LENGTH_KEYS.size() - 1))
	_curve_btn.select(clampi(_curve, 0, _CURVE_KEYS.size() - 1))
	_flex_btn.select(clampi(_flex, 0, _FLEX_KEYS.size() - 1))
	for btn: OptionButton in [_length_btn, _curve_btn, _flex_btn]:
		btn.disabled = _gear_locked
	_lock_label.visible = _gear_locked

	var colors: Array[Color] = []
	var names: Array[String] = []
	var chip_labels: Array[String] = []
	for i: int in TapeColorRegistry.count():
		colors.append(TapeColorRegistry.resolve(i, _team_accent))
		names.append(tr(TapeColorRegistry.NAME_KEYS[i]))
		# The TEAM chip says so — it tracks the kit rather than being one
		# more fixed color.
		chip_labels.append(tr(&"TAPE_COLOR_TEAM_SHORT")
				if i == TapeColorRegistry.TEAM_INDEX else "")
	_blade_color_dd.set_palette(colors, names, chip_labels)
	_blade_color_dd.set_selected(_tape.blade_color)
	_knob_color_dd.set_palette(colors, names, chip_labels)
	_knob_color_dd.set_selected(_tape.knob_color)
	_span_btn.select(maxi(_SPAN_OPTIONS.find(_tape.span), 0))
	_style_btn.select(maxi(_STYLE_OPTIONS.find(_tape.knob_style), 0))


# Reassembles the turntable stick from the current picks: blade at the picked
# pattern, tape at the picked span/color, shaft cut by the picked length with
# the picked handle wrap painted on, knob in the picked knob color.
# Heel-origin blade frame (the builder's): the shaft climbs from the heel at
# the lie angle; the whole assembly is then centered so the turntable spins
# about the stick's middle.
func _rebuild_preview() -> void:
	if _blade == null or _body == null:
		return
	var p := StickBladeMeshBuilder.Params.new()
	p.length = GameRules.DEFAULT_BLADE_LENGTH_M
	p.curve_depth = Skater.BLADE_PATTERN_DEPTH[clampi(_curve, 0, 2)]
	p.curve_power = Skater.BLADE_PATTERN_POWER[clampi(_curve, 0, 2)]
	p.curve_sign = 1.0 if PlayerPrefs.is_left_handed else -1.0
	p.hosel_length = _HOSEL_LEN_M
	p.hosel_angle_deg = _LIE_DEG
	_blade.mesh = StickBladeMeshBuilder.build(p)

	var tape_p := StickBladeMeshBuilder.Params.new()
	tape_p.length = p.length
	tape_p.curve_depth = p.curve_depth
	tape_p.curve_power = p.curve_power
	tape_p.curve_sign = p.curve_sign
	_tape_mesh.mesh = StickBladeMeshBuilder.build_tape(tape_p, _tape.span_range()) \
			if _tape.has_blade_tape() else null
	_tape_mesh.material_override = _make_mat(
			TapeColorRegistry.resolve(_tape.blade_color, _team_accent), 0.9)

	# Shaft: heel → butt along the lie axis, cut to the picked length (the
	# same stick_len_mult the rink uses, so LONG visibly outreaches SHORT).
	# LOCAL transforms only — look_at_from_position places in GLOBAL space,
	# which fought the turntable's live rotation: the shaft snapped back to
	# the world frame on every option change while the blade stayed rotated.
	var attrs := PlayerAttributes.new(_body.height, _body.weight, _body.profile,
			_curve, _flex, _length)
	var stick_len: float = GameRules.DEFAULT_STICK_LENGTH_M * attrs.stick_len_mult()
	var lie: float = deg_to_rad(_LIE_DEG)
	var axis := Vector3(0.0, sin(lie), cos(lie))
	_shaft.transform = Transform3D(
			Basis.looking_at(-axis, Vector3.UP) * Basis.from_scale(Vector3(1.0, 1.0, stick_len)),
			axis * (stick_len * 0.5))
	var knob_color: Color = TapeColorRegistry.resolve(_tape.knob_color, _team_accent)
	_shaft_mat.set_shader_parameter(&"grip_mode", _tape.knob_style)
	_shaft_mat.set_shader_parameter(&"grip_color", knob_color)
	_shaft_mat.set_shader_parameter(&"shaft_len_m", stick_len)

	# Same composition as Skater._update_stick_knob: cylinder long axis onto
	# the shaft line, taper end toward the blade.
	_knob.transform = Transform3D(
			Basis.looking_at(axis, Vector3.UP) * Basis(Vector3.RIGHT, PI * 0.5),
			axis * (stick_len + _KNOB_HEIGHT_M * 0.5))
	_knob.material_override = _make_mat(knob_color, 0.9)

	# Center the assembly on the turntable pivot: midpoint of butt and toe.
	# Positions were all just set absolutely above (blade at the origin), so
	# the shift never accumulates across rebuilds.
	var butt: Vector3 = axis * stick_len
	var toe := Vector3(0.0, 0.0, -p.length)
	var center: Vector3 = (butt + toe) * 0.5
	_blade.position = -center
	_shaft.position -= center
	_knob.position -= center
	# (_tape_mesh rides _blade.)
	# Seat the ice disc just under the blade sole (which moves with the
	# centering as the picked length changes), so the stick stands ON it.
	if _floor_disc != null:
		_floor_disc.position = Vector3(0.0, -center.y - 0.042, 0.0)


static func _make_mat(color: Color, roughness: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	return mat
