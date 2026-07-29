class_name StickEditorPopup
extends Control

# The stick workbench: every stick-related pick in one modal — the three gear
# slots (LENGTH / CURVE / FLEX, the stick rows that used to sit in
# AttributePickerPanel) and the tape job (blade tape color, coverage, knob
# color) — arranged around a live turntable preview assembled from the real
# in-game pieces: the procedural blade mesh at the picked pattern, the wrapped
# tape band, the flex shader pulsing a load-and-release bow scaled by the
# picked flex, and the shaft cut to the picked length.
#
# A sub-editor, not a committer: opened by PlayerSettingsPopup or
# LobbyBuildPopup over their own modal, it edits pending values and hands them
# back through `stick_edited` on Done — the HOST owns snapshot/commit/revert,
# so Cancel here just discards this dialog's edits and the host's Cancel still
# reverts an applied Done. Gear can be locked (online match) while tape stays
# editable — tape is cosmetic and never gameplay-locked.

signal stick_edited(curve: int, flex: int, length: int, tape_code: int)

# Gear rows (labels match the old AttributePickerPanel rows).
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

# Tape coverage buttons, in display order (wire values from StickTapeConfig.Span).
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

# Pending picks (working state between open() and Done).
var _curve: int = PlayerAttributes.GEAR_BALANCED
var _flex: int = PlayerAttributes.GEAR_BALANCED
var _length: int = PlayerAttributes.GEAR_BALANCED
var _tape: StickTapeConfig = StickTapeConfig.new()
var _body: PlayerAttributes = null          # full build, for stick_len_mult()
var _gear_locked: bool = false
var _team_accent: Color = Color.WHITE

# Controls.
var _gear_buttons: Dictionary = {}          # row key → Array[Button]
var _blade_swatches: Array[Button] = []
var _knob_swatches: Array[Button] = []
var _span_buttons: Array[Button] = []
var _lock_label: Label = null

# Preview scene.
var _viewport: SubViewport = null
var _turntable: Node3D = null
var _shaft: MeshInstance3D = null
var _shaft_mat: ShaderMaterial = null
var _blade: MeshInstance3D = null
var _tape_mesh: MeshInstance3D = null
var _knob: MeshInstance3D = null
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

	_build_gear_row(vbox, "length", tr(&"STICK_GEAR_LENGTH"), _LENGTH_TOOLTIP,
			[tr(&"STICK_LENGTH_SHORT"), tr(&"STICK_LENGTH_STANDARD"), tr(&"STICK_LENGTH_LONG")])
	_build_gear_row(vbox, "curve", tr(&"STICK_GEAR_CURVE"), _CURVE_TOOLTIP,
			[tr(&"STICK_CURVE_CLOSED"), tr(&"STICK_CURVE_BALANCED"), tr(&"STICK_CURVE_OPEN")])
	_build_gear_row(vbox, "flex", tr(&"STICK_GEAR_FLEX"), _FLEX_TOOLTIP,
			[tr(&"STICK_FLEX_WHIPPY"), tr(&"STICK_FLEX_MEDIUM"), tr(&"STICK_FLEX_STIFF")])

	_blade_swatches = _build_swatch_row(vbox, tr(&"TAPE_BLADE_LABEL"), _on_blade_swatch_pressed)
	_build_span_row(vbox)
	_knob_swatches = _build_swatch_row(vbox, tr(&"TAPE_KNOB_LABEL"), _on_knob_swatch_pressed)

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


# The turntable viewport: its own 3D world so the stick renders over the menu
# scrim, lit by a single key light. All meshes are the real in-game pieces.
func _build_preview(vbox: VBoxContainer) -> void:
	var container := SubViewportContainer.new()
	container.stretch = true
	container.custom_minimum_size = Vector2(360, 240)
	container.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	vbox.add_child(container)

	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.transparent_bg = true
	_viewport.msaa_3d = Viewport.MSAA_4X
	container.add_child(_viewport)

	var camera := Camera3D.new()
	# Far enough that the whole diagonal (butt to toe ≈ 1.55 m, spinning about
	# its midpoint) stays inside the vertical frustum at every rotation angle.
	camera.position = Vector3(0.0, 0.0, 2.6)
	camera.fov = 45.0
	_viewport.add_child(camera)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-35.0, 35.0, 0.0)
	light.light_energy = 1.3
	_viewport.add_child(light)

	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-15.0, -140.0, 0.0)
	fill.light_energy = 0.5
	_viewport.add_child(fill)

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


func _build_gear_row(vbox: VBoxContainer, key: String, label_text: String,
		tooltip: String, option_labels: Array[String]) -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	vbox.add_child(row)

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(96, 0)
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", MenuStyle.TEXT_BODY)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_STOP
	label.tooltip_text = tooltip
	row.add_child(label)

	var buttons: Array[Button] = []
	for i: int in option_labels.size():
		var btn := Button.new()
		btn.text = option_labels[i]
		btn.custom_minimum_size = Vector2(92, 40)
		btn.add_theme_font_size_override("font_size", 15)
		btn.tooltip_text = tooltip
		SoundManager.wire_button(btn)
		btn.pressed.connect(_on_gear_pressed.bind(key, i))
		row.add_child(btn)
		buttons.append(btn)
	_gear_buttons[key] = buttons
	# Controller: D-pad left/right cycles within the row, wrapping at the ends
	# (same as the attribute panel's gear rows).
	if ControllerNav.active() and buttons.size() > 1:
		for i: int in buttons.size():
			buttons[i].focus_neighbor_left = buttons[(i - 1 + buttons.size()) % buttons.size()].get_path()
			buttons[i].focus_neighbor_right = buttons[(i + 1) % buttons.size()].get_path()


# A row of small color-swatch buttons over the tape palette. TEAM (index 0)
# shows the live team accent.
func _build_swatch_row(vbox: VBoxContainer, label_text: String,
		handler: Callable) -> Array[Button]:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 6)
	vbox.add_child(row)

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(96, 0)
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", MenuStyle.TEXT_BODY)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)

	var swatches: Array[Button] = []
	for i: int in TapeColorRegistry.count():
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(30, 30)
		btn.tooltip_text = tr(TapeColorRegistry.NAME_KEYS[i])
		SoundManager.wire_button(btn)
		btn.pressed.connect(handler.bind(i))
		row.add_child(btn)
		swatches.append(btn)
	return swatches


func _build_span_row(vbox: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	vbox.add_child(row)

	var label := Label.new()
	label.text = tr(&"TAPE_COVERAGE_LABEL")
	label.custom_minimum_size = Vector2(96, 0)
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", MenuStyle.TEXT_BODY)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)

	for i: int in _SPAN_OPTIONS.size():
		var btn := Button.new()
		btn.text = tr(_SPAN_KEYS[i])
		btn.custom_minimum_size = Vector2(0, 36)
		btn.add_theme_font_size_override("font_size", 14)
		SoundManager.wire_button(btn)
		btn.pressed.connect(_on_span_pressed.bind(_SPAN_OPTIONS[i]))
		row.add_child(btn)
		_span_buttons.append(btn)


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
	ControllerNav.open_modal(_focus_background, self, _first_focus_target())


func _first_focus_target() -> Control:
	var buttons: Array[Button] = _gear_buttons.get("length", [] as Array[Button])
	return buttons[0] if not buttons.is_empty() else null


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

func _on_gear_pressed(key: String, option: int) -> void:
	if _gear_locked:
		return
	match key:
		"curve":
			_curve = option
		"flex":
			_flex = option
		"length":
			_length = option
	_refresh()
	_rebuild_preview()


func _on_blade_swatch_pressed(index: int) -> void:
	_tape = StickTapeConfig.new(index, _tape.span, _tape.knob_color)
	_refresh()
	_rebuild_preview()


func _on_knob_swatch_pressed(index: int) -> void:
	_tape = StickTapeConfig.new(_tape.blade_color, _tape.span, index)
	_refresh()
	_rebuild_preview()


func _on_span_pressed(span: int) -> void:
	_tape = StickTapeConfig.new(_tape.blade_color, span, _tape.knob_color)
	_refresh()
	_rebuild_preview()


# ── Rendering ────────────────────────────────────────────────────────────────

func _refresh() -> void:
	var picks: Dictionary = {"curve": _curve, "flex": _flex, "length": _length}
	for key: String in _gear_buttons:
		var buttons: Array[Button] = _gear_buttons[key]
		var opt: int = clampi(int(picks[key]), 0, buttons.size() - 1)
		for i: int in buttons.size():
			MenuStyle.apply_tab_button(buttons[i], i == opt)
			buttons[i].disabled = _gear_locked and i != opt
	_lock_label.visible = _gear_locked
	_paint_swatches(_blade_swatches, _tape.blade_color)
	_paint_swatches(_knob_swatches, _tape.knob_color)
	for i: int in _span_buttons.size():
		MenuStyle.apply_tab_button(_span_buttons[i], _SPAN_OPTIONS[i] == _tape.span)


func _paint_swatches(swatches: Array[Button], selected: int) -> void:
	for i: int in swatches.size():
		var sb := StyleBoxFlat.new()
		sb.bg_color = TapeColorRegistry.resolve(i, _team_accent)
		sb.set_corner_radius_all(4)
		if i == selected:
			sb.set_border_width_all(3)
			sb.border_color = MenuStyle.TEXT_BODY
		swatches[i].add_theme_stylebox_override("normal", sb)
		swatches[i].add_theme_stylebox_override("hover", sb)
		swatches[i].add_theme_stylebox_override("pressed", sb)


# Reassembles the turntable stick from the current picks: blade at the picked
# pattern, tape at the picked span/color, shaft cut by the picked length, knob
# in the picked knob color. Heel-origin blade frame (the builder's): the shaft
# climbs from the heel at the lie angle; the whole assembly is then centered
# so the turntable spins about the stick's middle.
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

	# Same composition as Skater._update_stick_knob: cylinder long axis onto
	# the shaft line, taper end toward the blade.
	_knob.transform = Transform3D(
			Basis.looking_at(axis, Vector3.UP) * Basis(Vector3.RIGHT, PI * 0.5),
			axis * (stick_len + _KNOB_HEIGHT_M * 0.5))
	_knob.material_override = _make_mat(
			TapeColorRegistry.resolve(_tape.knob_color, _team_accent), 0.9)

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


static func _make_mat(color: Color, roughness: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	return mat
