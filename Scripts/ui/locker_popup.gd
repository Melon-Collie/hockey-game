class_name LockerPopup
extends Control

# The locker: every equipment pick a player owns, in one modal, around a live
# mannequin wearing all of them. Replaces the two turntable workbenches — the
# stick had its own case and the gear had another with a skate, a fist and a
# helmet orbiting a shared pivot, which read as a parts bin rather than a kit.
#
# Rows are grouped by the piece they dress, and the group you are working in is
# the group the camera is looking at: land on a SKATES row and the case dollies
# to the boots, a GLOVES row and it goes to the fists on the shaft, HELMET to
# the head. Nothing is focused, and it holds the whole figure at a slow turn.
# Focus drives it rather than hover alone so a pad player gets the same dolly
# walking the rows that a mouse player gets pointing at them.
#
# Rows whose pick changes gameplay (stick gear, blade profile) carry the gold
# asterisk the legend explains and lock during an online match — attributes
# replicate at join time. Models, tape, laces and face gear are cosmetic and
# never lock.
#
# A sub-editor, not a committer: opened by PlayerSettingsPopup over its own
# modal, it edits pending values and hands them back through `locker_edited` on
# Done. The HOST owns snapshot/commit/revert, so Cancel here just discards this
# dialog's edits and the host's Cancel still reverts an applied Done.

signal locker_edited(profile: int, curve: int, flex: int, length: int,
		tape_code: int, gear_code: int)

# Hover tooltips. Headline effects only.
const _LENGTH_TOOLTIP: String = "Cut relative to your height.\nShort = snappier blade, finest close control, less reach.\nLong = more reach & sweep, slower to cut back."
const _CURVE_TOOLTIP: String = "Blade pattern.\nM88 mid curve = best backhand & slappers, catches the hardest passes, flattest face.\nM92 mid-toe = the no-weakness all-rounder.\nM28 toe hook = easiest lift in tight; weakest backhand & slappers, hard passes bounce off."
const _FLEX_TOOLTIP: String = "Shaft stiffness, cut to your weight — the same number is a plank on a light build and a noodle on a heavy one.\nWhippy = fastest release, softer shot ceiling.\nStiff = biggest shot, slower to load."
const _PROFILE_TOOLTIP: String = "Blade grind.\nAgility = quicker first step & tighter cornering, lower top speed.\nPower = higher top speed & better glide, wider turns."

# Dropdown option tables: display order + the wire value each row maps to.
const _LENGTH_KEYS: Array[StringName] = [
	&"STICK_LENGTH_SHORT", &"STICK_LENGTH_STANDARD", &"STICK_LENGTH_LONG"]
const _CURVE_KEYS: Array[StringName] = [
	&"STICK_CURVE_M88", &"STICK_CURVE_M92", &"STICK_CURVE_M28"]
const _FLEX_KEYS: Array[StringName] = [
	&"STICK_FLEX_WHIPPY", &"STICK_FLEX_MEDIUM", &"STICK_FLEX_STIFF"]
const _PROFILE_KEYS: Array[StringName] = [
	&"GEAR_PROFILE_AGILITY", &"GEAR_PROFILE_BALANCED", &"GEAR_PROFILE_POWER"]
const _SPAN_OPTIONS: Array[int] = [
	StickTapeConfig.Span.FULL,
	StickTapeConfig.Span.HEEL_TO_MID,
	StickTapeConfig.Span.MID_TO_TOE,
	StickTapeConfig.Span.MID,
	StickTapeConfig.Span.TOE,
	StickTapeConfig.Span.NONE,
]
const _SPAN_KEYS: Array[StringName] = [
	&"TAPE_SPAN_FULL", &"TAPE_SPAN_HEEL_TO_MID", &"TAPE_SPAN_MID_TO_TOE",
	&"TAPE_SPAN_MID", &"TAPE_SPAN_TOE", &"TAPE_SPAN_NONE",
]
const _STYLE_OPTIONS: Array[int] = [
	StickTapeConfig.KnobStyle.KNOB,
	StickTapeConfig.KnobStyle.CANDY_CANE,
	StickTapeConfig.KnobStyle.FULL,
]
const _STYLE_KEYS: Array[StringName] = [
	&"TAPE_HANDLE_KNOB", &"TAPE_HANDLE_CANDY", &"TAPE_HANDLE_FULL",
]

# The swatch strip drawn on each model row: one band per paint zone.
const _SWATCH_W: int = 36
const _SWATCH_H: int = 18

const _CASE_SIZE := Vector2(340, 470)
const _LABEL_W: float = 96.0
const _FIELD_W: float = 176.0

# Camera easing. The dolly is quick enough to feel like a response to the row
# you landed on, slow enough that walking a column with the pad doesn't strobe.
const _EASE_PER_S: float = 7.0
# The wide shot turns; a focused shot holds still so the piece can be read.
const _IDLE_RAD_PER_S: float = 0.35
const _DRAG_RAD_PER_PX: float = 0.008

# Pending picks (working state between open() and Done).
var _attrs: PlayerAttributes = null
var _profile: int = PlayerAttributes.GEAR_BALANCED
var _curve: int = PlayerAttributes.GEAR_BALANCED
var _flex: int = PlayerAttributes.GEAR_BALANCED
var _length: int = PlayerAttributes.GEAR_BALANCED
var _tape: StickTapeConfig = StickTapeConfig.new()
var _gear: GearStyleConfig = GearStyleConfig.new()
var _gear_locked: bool = false
var _team_colors: Dictionary = {}
var _skin_tone: int = SkinToneRegistry.DEFAULT_INDEX
var _is_left_handed: bool = false

# Controls.
var _length_btn: OptionButton = null
var _curve_btn: OptionButton = null
var _flex_btn: OptionButton = null
var _stick_model_btn: OptionButton = null
var _blade_color_dd: SwatchDropdown = null
var _span_btn: OptionButton = null
var _knob_color_dd: SwatchDropdown = null
var _style_btn: OptionButton = null
var _profile_btn: OptionButton = null
var _skate_btn: OptionButton = null
var _lace_dd: SwatchDropdown = null
var _glove_btn: OptionButton = null
var _face_btn: OptionButton = null
var _lock_label: Label = null

# Display case.
var _viewport: SubViewport = null
var _mannequin: LockerMannequin = null
var _camera: Camera3D = null
var _focus: int = LockerMannequin.Focus.FULL
# Eased camera state — the target is whatever the focused group asks for.
var _anchor: Vector3 = Vector3.ZERO
var _dist: float = 2.45
var _pitch: float = 0.0
var _yaw: float = 0.0
var _target_yaw: float = 0.0
var _dragging: bool = false

# Focus scope (see ControllerNav.open_modal).
var _focus_background: Control = null
var _focus_restore: Control = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var focus_theme: Theme = MenuStyle.controller_focus_theme()
	if focus_theme != null:
		theme = focus_theme
	_build()
	visible = false


func _process(delta: float) -> void:
	if not visible or _mannequin == null:
		return
	if _focus == LockerMannequin.Focus.FULL and not _dragging:
		_target_yaw += _IDLE_RAD_PER_S * delta
	var t: float = minf(_EASE_PER_S * delta, 1.0)
	_yaw = lerpf(_yaw, _target_yaw, t)
	_dist = lerpf(_dist, _mannequin.focus_distance(_focus), t)
	_pitch = lerpf(_pitch, _mannequin.focus_pitch(_focus), t)
	_anchor = _anchor.lerp(_mannequin.focus_anchor(_focus), t)
	_mannequin.rotation.y = _yaw
	# The anchor is a point ON the figure, so it swings with the turn; the
	# camera itself stays in the case's own plane and only ever dollies.
	var aimed: Vector3 = Basis(Vector3.UP, _yaw) * _anchor
	_camera.position = aimed + Vector3(0.0, sin(_pitch), -cos(_pitch)) * _dist
	_camera.look_at(aimed)


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
	title.text = tr(&"LOCKER_TITLE")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	MenuStyle.apply_heading(title)
	vbox.add_child(title)

	# Case on the left, the rows it dresses on the right — two columns so the
	# twelve rows stay beside the figure instead of running past the bottom of
	# a portrait case.
	var main := HBoxContainer.new()
	main.alignment = BoxContainer.ALIGNMENT_CENTER
	main.add_theme_constant_override("separation", 24)
	vbox.add_child(main)

	_build_case(main)
	_build_stick_column(main)
	_build_gear_column(main)

	_lock_label = Label.new()
	_lock_label.text = tr(&"LOCKER_LOCKED_NOTE")
	_lock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lock_label.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	_lock_label.add_theme_font_size_override("font_size", 13)
	_lock_label.visible = false
	vbox.add_child(_lock_label)

	var legend := Label.new()
	legend.text = tr(&"STICK_GAMEPLAY_LEGEND")
	legend.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	legend.add_theme_color_override("font_color", MenuStyle.GOLD)
	legend.add_theme_font_size_override("font_size", 13)
	vbox.add_child(legend)

	var action_row := HBoxContainer.new()
	action_row.alignment = BoxContainer.ALIGNMENT_CENTER
	action_row.add_theme_constant_override("separation", 12)
	vbox.add_child(action_row)

	var done_btn := Button.new()
	done_btn.text = tr(&"EDITOR_DONE")
	MenuStyle.apply_primary_cta(done_btn, 18)
	done_btn.custom_minimum_size = Vector2(140, 44)
	done_btn.pressed.connect(_done)
	SoundManager.wire_button(done_btn)
	action_row.add_child(done_btn)

	var cancel_btn := Button.new()
	cancel_btn.text = tr(&"EDITOR_CANCEL")
	cancel_btn.custom_minimum_size = Vector2(140, 44)
	cancel_btn.add_theme_font_size_override("font_size", 18)
	cancel_btn.pressed.connect(_cancel)
	SoundManager.wire_button(cancel_btn)
	action_row.add_child(cancel_btn)


# The display case: an inset well with an ice disc the mannequin stands on,
# real shadows, and its own 3D world so the figure renders over the menu scrim.
func _build_case(row: HBoxContainer) -> void:
	var case_panel := PanelContainer.new()
	var case_style := StyleBoxFlat.new()
	case_style.bg_color = MenuStyle.SURFACE_INPUT
	case_style.set_corner_radius_all(6)
	case_style.set_border_width_all(1)
	case_style.border_color = MenuStyle.TEAL_DIM
	case_style.set_content_margin_all(4)
	case_panel.add_theme_stylebox_override("panel", case_style)
	case_panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(case_panel)

	var container := SubViewportContainer.new()
	container.stretch = true
	container.custom_minimum_size = _CASE_SIZE
	container.mouse_filter = Control.MOUSE_FILTER_STOP
	container.gui_input.connect(_on_case_input)
	case_panel.add_child(container)

	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.transparent_bg = true
	_viewport.msaa_3d = Viewport.MSAA_4X
	container.add_child(_viewport)

	_camera = Camera3D.new()
	_camera.fov = 45.0
	_viewport.add_child(_camera)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-42.0, 35.0, 0.0)
	key.light_energy = 1.3
	key.shadow_enabled = true
	_viewport.add_child(key)

	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-15.0, -140.0, 0.0)
	fill.light_energy = 0.5
	_viewport.add_child(fill)

	var floor_disc := MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = 0.75
	disc.bottom_radius = 0.75
	disc.height = 0.02
	disc.radial_segments = 48
	floor_disc.mesh = disc
	var disc_mat := StandardMaterial3D.new()
	disc_mat.albedo_color = MenuStyle.SURFACE_ELEV
	disc_mat.roughness = 0.35
	floor_disc.material_override = disc_mat
	floor_disc.position = Vector3(0.0, -0.011, 0.0)
	_viewport.add_child(floor_disc)

	# The mannequin's origin IS the ice plane, so it sits on the disc unposed.
	_mannequin = LockerMannequin.new()
	_viewport.add_child(_mannequin)


func _build_stick_column(row: HBoxContainer) -> void:
	var col := _column(row)
	col.add_child(_section_header(tr(&"LOCKER_SEC_STICK")))
	var stick: int = LockerMannequin.Focus.STICK

	_length_btn = _option_button(_LENGTH_KEYS, _LENGTH_TOOLTIP, _on_length_selected)
	_add_row(col, tr(&"STICK_GEAR_LENGTH"), _length_btn, true, _LENGTH_TOOLTIP, stick)
	_curve_btn = _option_button(_CURVE_KEYS, _CURVE_TOOLTIP, _on_curve_selected)
	_add_row(col, tr(&"STICK_GEAR_CURVE"), _curve_btn, true, _CURVE_TOOLTIP, stick)
	_flex_btn = _option_button(_FLEX_KEYS, _FLEX_TOOLTIP, _on_flex_selected)
	_add_row(col, tr(&"STICK_GEAR_FLEX"), _flex_btn, true, _FLEX_TOOLTIP, stick)

	# Stick colorways are fixed designs with no kit zones, so the items fill
	# once here rather than per open() the way the gear models do.
	_stick_model_btn = _bare_option_button(_on_stick_model_selected)
	for model: int in StickModelRegistry.count():
		_stick_model_btn.add_icon_item(
				_swatch_strip(StickModelRegistry.swatch_colors(model)),
				tr(StickModelRegistry.NAME_KEYS[model]), model)
	_add_row(col, tr(&"STICK_MODEL_LABEL"), _stick_model_btn, false, "", stick)

	_blade_color_dd = SwatchDropdown.new(Vector2(_FIELD_W, 36))
	_blade_color_dd.selected.connect(_on_blade_color_selected)
	_add_row(col, tr(&"TAPE_BLADE_LABEL"), _blade_color_dd, false, "", stick)
	_span_btn = _option_button(_SPAN_KEYS, "", _on_span_selected)
	_add_row(col, tr(&"TAPE_COVERAGE_LABEL"), _span_btn, false, "", stick)
	_knob_color_dd = SwatchDropdown.new(Vector2(_FIELD_W, 36))
	_knob_color_dd.selected.connect(_on_knob_color_selected)
	_add_row(col, tr(&"TAPE_KNOB_LABEL"), _knob_color_dd, false, "", stick)
	_style_btn = _option_button(_STYLE_KEYS, "", _on_style_selected)
	_add_row(col, tr(&"TAPE_HANDLE_LABEL"), _style_btn, false, "", stick)


func _build_gear_column(row: HBoxContainer) -> void:
	var col := _column(row)

	col.add_child(_section_header(tr(&"LOCKER_SEC_SKATES")))
	var skates: int = LockerMannequin.Focus.SKATES
	_profile_btn = _option_button(_PROFILE_KEYS, _PROFILE_TOOLTIP, _on_profile_selected)
	_add_row(col, tr(&"GEAR_PROFILE_LABEL"), _profile_btn, true, _PROFILE_TOOLTIP, skates)
	# Model items are rebuilt per open(): a model's TEAM zones resolve against
	# the kit the player is about to wear.
	_skate_btn = _bare_option_button(_on_skate_model_selected)
	_add_row(col, tr(&"STICK_MODEL_LABEL"), _skate_btn, false, "", skates)
	_lace_dd = SwatchDropdown.new(Vector2(_FIELD_W, 36))
	_lace_dd.selected.connect(_on_lace_color_selected)
	_add_row(col, tr(&"GEAR_LACES_LABEL"), _lace_dd, false, "", skates)

	col.add_child(_section_header(tr(&"LOCKER_SEC_GLOVES")))
	_glove_btn = _bare_option_button(_on_glove_model_selected)
	_add_row(col, tr(&"STICK_MODEL_LABEL"), _glove_btn, false, "",
			LockerMannequin.Focus.GLOVES)

	col.add_child(_section_header(tr(&"LOCKER_SEC_HELMET")))
	# Face options are fixed looks with no kit zones, so their items fill once.
	_face_btn = _bare_option_button(_on_face_option_selected)
	for i: int in GearModelRegistry.face_count():
		_face_btn.add_item(tr(GearModelRegistry.FACE_NAME_KEYS[i]), i)
	_add_row(col, tr(&"GEAR_FACE_LABEL"), _face_btn, false, "",
			LockerMannequin.Focus.HELMET)


func _column(row: HBoxContainer) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_BEGIN
	col.add_theme_constant_override("separation", 10)
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(col)
	return col


# Small muted all-caps caption naming the piece the rows below dress (the CSV
# rows are stored uppercase).
func _section_header(text: String) -> Label:
	var header := Label.new()
	header.text = text
	header.add_theme_font_size_override("font_size", 13)
	header.add_theme_color_override("font_color", MenuStyle.TEXT_MUTED)
	return header


# One labelled row. `gameplay` rows carry the gold asterisk the legend
# explains; `focus` is the framing this row asks the case for, on hover or on
# focus, so working a row and seeing the piece are the same gesture.
#
# Every piece of the row wires the hover, not just the row itself: the label and
# the control sit ON TOP of the container and take the pointer, so relying on
# the container alone leaves the framing stuck wherever it was.
func _add_row(col: VBoxContainer, label_text: String, control: Control,
		gameplay: bool, tooltip: String, focus: int) -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_BEGIN
	row.add_theme_constant_override("separation", 10)
	row.mouse_filter = Control.MOUSE_FILTER_PASS
	row.mouse_entered.connect(_set_focus.bind(focus))
	col.add_child(row)

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(_LABEL_W, 0)
	label.add_theme_font_size_override("font_size", 17)
	label.add_theme_color_override("font_color", MenuStyle.TEXT_BODY)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_STOP
	label.tooltip_text = tooltip
	label.mouse_entered.connect(_set_focus.bind(focus))
	row.add_child(label)

	var star := Label.new()
	star.text = "*" if gameplay else " "
	star.custom_minimum_size = Vector2(14, 0)
	star.add_theme_font_size_override("font_size", 20)
	star.add_theme_color_override("font_color", MenuStyle.GOLD)
	star.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	star.tooltip_text = tr(&"STICK_GAMEPLAY_LEGEND") if gameplay else ""
	star.mouse_filter = Control.MOUSE_FILTER_STOP if gameplay else Control.MOUSE_FILTER_IGNORE
	if gameplay:
		star.mouse_entered.connect(_set_focus.bind(focus))
	row.add_child(star)

	control.focus_entered.connect(_set_focus.bind(focus))
	control.mouse_entered.connect(_set_focus.bind(focus))
	row.add_child(control)


func _option_button(keys: Array[StringName], tooltip: String,
		handler: Callable) -> OptionButton:
	var btn := _bare_option_button(handler)
	btn.tooltip_text = tooltip
	for i: int in keys.size():
		btn.add_item(tr(keys[i]), i)
	return btn


func _bare_option_button(handler: Callable) -> OptionButton:
	var btn := OptionButton.new()
	btn.custom_minimum_size = Vector2(_FIELD_W, 36)
	btn.add_theme_font_size_override("font_size", 15)
	SoundManager.wire_button(btn)
	btn.item_selected.connect(handler)
	return btn


# ── Host API ─────────────────────────────────────────────────────────────────

func set_focus_scope(background: Control, restore: Control) -> void:
	_focus_background = background
	_focus_restore = restore


# Everything the mannequin has to wear and every row has to show, all of it the
# host's PENDING state: `attrs` is the pending build (its stick gear and blade
# profile are what this dialog edits), `team_colors` the pending team's
# TeamColorRegistry.get_colors dict, and `gear_locked` the online-match
# attribute lock — cosmetics stay live under it.
func open(attrs: PlayerAttributes, tape_code: int, gear_code: int,
		gear_locked: bool, team_colors: Dictionary, skin_tone: int,
		is_left_handed: bool) -> void:
	_attrs = attrs
	_profile = attrs.profile
	_curve = attrs.curve
	_flex = attrs.flex
	_length = attrs.length
	_tape = StickTapeConfig.from_code(tape_code)
	_gear = GearStyleConfig.from_code(gear_code)
	_gear_locked = gear_locked
	_team_colors = team_colors
	_skin_tone = SkinToneRegistry.clamp_index(skin_tone)
	_is_left_handed = is_left_handed
	_refresh()
	_redress()
	# Open on the wide shot, already settled there rather than swinging in.
	_focus = LockerMannequin.Focus.FULL
	_target_yaw = _mannequin.focus_yaw(_focus)
	_yaw = _target_yaw
	_dist = _mannequin.focus_distance(_focus)
	_pitch = _mannequin.focus_pitch(_focus)
	_anchor = _mannequin.focus_anchor(_focus)
	visible = true
	ControllerNav.open_modal(_focus_background, self, _length_btn)


func _done() -> void:
	locker_edited.emit(_profile, _curve, _flex, _length, _tape.to_code(),
			_gear.to_code())
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


# Drag inside the case to turn the figure — the one thing a fixed presentation
# angle can't give you, which is a look at the piece from the other side.
func _on_case_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_LEFT:
			_dragging = button.pressed
	elif event is InputEventMouseMotion and _dragging:
		_target_yaw += (event as InputEventMouseMotion).relative.x * _DRAG_RAD_PER_PX


# ── Interaction ──────────────────────────────────────────────────────────────

# The camera follows whichever group the player is working in. Re-aiming only
# on a CHANGE is what lets a drag hold its angle: the presented yaw is a
# starting point for the group, not a per-frame target.
func _set_focus(focus: int) -> void:
	if focus == _focus:
		return
	_focus = focus
	_target_yaw = _mannequin.focus_yaw(focus)


func _on_length_selected(option: int) -> void:
	if not _gear_locked:
		_length = option
	_refresh()
	_redress()


func _on_curve_selected(option: int) -> void:
	if not _gear_locked:
		_curve = option
	_refresh()
	_redress()


func _on_flex_selected(option: int) -> void:
	if not _gear_locked:
		_flex = option
	_refresh()
	_redress()


func _on_profile_selected(option: int) -> void:
	if not _gear_locked:
		_profile = option
	_refresh()


func _on_stick_model_selected(index: int) -> void:
	_gear.stick_model = index
	_redress()


func _on_blade_color_selected(index: int) -> void:
	_tape = StickTapeConfig.new(index, _tape.span, _tape.knob_color, _tape.knob_style)
	_redress()


func _on_knob_color_selected(index: int) -> void:
	_tape = StickTapeConfig.new(_tape.blade_color, _tape.span, index, _tape.knob_style)
	_redress()


func _on_span_selected(option: int) -> void:
	_tape = StickTapeConfig.new(_tape.blade_color, _SPAN_OPTIONS[option],
			_tape.knob_color, _tape.knob_style)
	_redress()


func _on_style_selected(option: int) -> void:
	_tape = StickTapeConfig.new(_tape.blade_color, _tape.span,
			_tape.knob_color, _STYLE_OPTIONS[option])
	_redress()


func _on_skate_model_selected(index: int) -> void:
	_gear.skate_model = index
	_redress()


func _on_glove_model_selected(index: int) -> void:
	_gear.glove_model = index
	_redress()


func _on_lace_color_selected(index: int) -> void:
	_gear.lace_color = index
	_redress()


func _on_face_option_selected(index: int) -> void:
	_gear.helmet_face = index
	_redress()


# ── Rendering ────────────────────────────────────────────────────────────────

# Re-dress the mannequin from the current picks. The stick gear rides the
# body, so the pending build is rebuilt around it rather than passing the
# host's original.
func _redress() -> void:
	if _mannequin == null or _attrs == null:
		return
	var build := PlayerAttributes.new(_attrs.height, _attrs.weight, _profile,
			_curve, _flex, _length)
	_mannequin.apply(build, _gear, _tape, _team_colors, _skin_tone, _is_left_handed)


func _refresh() -> void:
	_length_btn.select(clampi(_length, 0, _LENGTH_KEYS.size() - 1))
	_curve_btn.select(clampi(_curve, 0, _CURVE_KEYS.size() - 1))
	# Flex rows carry the real stiffness number, which is fitted to the build's
	# weight — so the row re-labels whenever a different body opens the locker,
	# and "Stiff" on a light frame reads a lower number than "Whippy" on a
	# heavy one.
	var lbs: int = _attrs.weight if _attrs != null else int(PlayerAttributes.NEUTRAL_WEIGHT_LBS)
	for i: int in _FLEX_KEYS.size():
		_flex_btn.set_item_text(i, tr(&"STICK_FLEX_ITEM")
				% [tr(_FLEX_KEYS[i]), PlayerAttributes.flex_number_for(lbs, i)])
	_flex_btn.select(clampi(_flex, 0, _FLEX_KEYS.size() - 1))
	_profile_btn.select(clampi(_profile, 0, _PROFILE_KEYS.size() - 1))
	_stick_model_btn.select(clampi(_gear.stick_model, 0, StickModelRegistry.count() - 1))
	_face_btn.select(_gear.helmet_face)
	for btn: OptionButton in [_length_btn, _curve_btn, _flex_btn, _profile_btn]:
		btn.disabled = _gear_locked
	_lock_label.visible = _gear_locked
	_span_btn.select(maxi(_SPAN_OPTIONS.find(_tape.span), 0))
	_style_btn.select(maxi(_STYLE_OPTIONS.find(_tape.knob_style), 0))
	_rebuild_model_items()

	var accent: Color = _team_colors.get("primary", Color.WHITE)
	var colors: Array[Color] = []
	var names: Array[String] = []
	var chip_labels: Array[String] = []
	for i: int in TapeColorRegistry.count():
		colors.append(TapeColorRegistry.resolve(i, accent))
		names.append(tr(TapeColorRegistry.NAME_KEYS[i]))
		# The TEAM chip says so — it tracks the kit rather than being one more
		# fixed color.
		chip_labels.append(tr(&"TAPE_COLOR_TEAM_SHORT")
				if i == TapeColorRegistry.TEAM_INDEX else "")
	_blade_color_dd.set_palette(colors, names, chip_labels)
	_blade_color_dd.set_selected(_tape.blade_color)
	_knob_color_dd.set_palette(colors, names, chip_labels)
	_knob_color_dd.set_selected(_tape.knob_color)
	_lace_dd.set_palette(colors, names, chip_labels)
	_lace_dd.set_selected(_gear.lace_color)


# Fills the skate and glove dropdowns with the catalogue, each item carrying a
# swatch strip of that model's own zones resolved against the pending kit.
func _rebuild_model_items() -> void:
	var team: Color = _team_colors.get("primary", Color.WHITE)
	var accent: Color = _team_colors.get("secondary", Color.WHITE)
	var light: Color = _team_colors.get("light", Color.WHITE)
	var glove_kit: Color = _team_colors.get("gloves", Color.BLACK)
	var glove_accent: Color = _team_colors.get("glove_accent", Color.WHITE)

	_skate_btn.clear()
	for model: int in GearModelRegistry.skate_count():
		var zones: Array[Color] = []
		for zone: int in GearModelRegistry.SKATE_ZONE_COUNT:
			zones.append(GearModelRegistry.skate_color(model, zone, team, accent, light))
		_skate_btn.add_icon_item(_swatch_strip(zones),
				tr(GearModelRegistry.SKATE_NAME_KEYS[model]), model)
	_skate_btn.select(_gear.skate_model)

	_glove_btn.clear()
	for model: int in GearModelRegistry.glove_count():
		var zones: Array[Color] = []
		for zone: int in GearModelRegistry.GLOVE_ZONE_COUNT:
			zones.append(GearModelRegistry.glove_color(model, zone,
					glove_kit, glove_accent, light))
		_glove_btn.add_icon_item(_swatch_strip(zones),
				tr(GearModelRegistry.GLOVE_NAME_KEYS[model]), model)
	_glove_btn.select(_gear.glove_model)


# One design's zones as a strip of equal vertical bands. The last band absorbs
# the rounding remainder so a 3-zone strip fills the same width as a 5-zone one.
func _swatch_strip(zones: Array[Color]) -> ImageTexture:
	var img := Image.create(_SWATCH_W, _SWATCH_H, false, Image.FORMAT_RGBA8)
	var band: int = _SWATCH_W / zones.size()
	for i: int in zones.size():
		var x0: int = i * band
		var w: int = _SWATCH_W - x0 if i == zones.size() - 1 else band
		img.fill_rect(Rect2i(x0, 0, w, _SWATCH_H), zones[i])
	return ImageTexture.create_from_image(img)
