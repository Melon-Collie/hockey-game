class_name PlayerSettingsPopup
extends Control

# The player screen — who you are, one column: name, number, handedness,
# preferred position, skin tone, height, weight, the two equipment workbench
# launchers side by side — the stick (StickEditorPopup: gear + tape + live
# preview) and the gear (GearEditorPopup: blade profile + skate/glove color +
# live preview) — and the team pick last.
#
# One build per player, no presets — edits land directly on PlayerPrefs' flat
# fields. Opened from the main menu only (the lobby has no build editor).
#
# Snapshot-and-commit pattern: edits buffer in _pending_* until Apply is
# pressed. Cancel / ESC / overlay-click revert. Mirrors OptionsPanel. The
# workbenches are sub-editors — their Done lands in this popup's pending
# fields; Apply/Cancel here commit or discard it with everything else.
#
# During an active online match the BUILD half (height, weight, profile, stick
# gear) is locked — attributes replicate at join time — while cosmetics (skin,
# tape, skate/glove color) stay live.

signal name_changed(new_name: String)
signal jersey_number_changed(new_number: int)
signal handedness_changed(is_left: bool)
signal position_changed(position: int)
signal preferred_color_changed(color_slot: int)
signal attributes_changed(attrs: PlayerAttributes)

# Hover tooltips. Headline effects only.
const _HEIGHT_TOOLTIP: String = "Frame length: reach, stick length, and the speed/agility/shot baselines.\nSmall = shiftier with quicker turns; big = longer reach & harder shot."
const _WEIGHT_TOOLTIP: String = "Frame mass, bounded by your height.\nLean = quicker first step, fast stamina recovery, easier to move.\nHeavy = harder hits & harder to move, deep but slow-refilling tank."
const _POSITION_TOOLTIP: String = "Preferred position — where a lobby seats you when you join.\nIn 3v3 the wings and D pair up on their side: LW/LD take the left,\nRW/RD the right. A taken seat falls back to the first open one."
# Dropdown display order (hockey-natural, wings around the C) → position
# index (PlayerRules.POSITION_NAMES order), with the display keys in lockstep.
const _POSITION_ORDER: Array[int] = [1, 0, 2, 3, 4]
const _POSITION_KEYS: Array[StringName] = [
	&"POSITION_LW", &"POSITION_C", &"POSITION_RW", &"POSITION_LD", &"POSITION_RD"]

# Controls — kept as refs so Cancel can restore them from the snapshot.
var _name_field: LineEdit = null
var _name_warning: Label = null
var _number_field: LineEdit = null
var _number_warning: Label = null
var _left_btn: Button = null
var _right_btn: Button = null
var _color_dropdown: PaletteDropdown = null
var _skin_buttons: Array[Button] = []
var _position_btn: OptionButton = null
var _height_slider: HSlider = null
var _height_value_label: Label = null
var _weight_slider: HSlider = null
var _weight_value_label: Label = null
var _lock_label: Label = null
var _apply_btn: Button = null
# The two workbenches, opened over this popup by their Edit buttons.
var _stick_popup: StickEditorPopup = null
var _gear_popup: GearEditorPopup = null
# Gold "unapplied changes" notes beside each Edit button — pending workbench
# edits are otherwise invisible until Apply.
var _stick_pending_label: Label = null
var _gear_pending_label: Label = null

# Pending state — what Apply will commit.
var _pending_name: String = ""
var _pending_number: int = 0
var _pending_is_left: bool = false
var _pending_position: int = 0
var _pending_color_slot: int = -1
var _pending_skin: int = SkinToneRegistry.DEFAULT_INDEX
# The pending build in canonical order (height in, weight lbs, gear 0/2).
var _pending_height: int = PlayerAttributes.HEIGHT_MEDIUM
var _pending_weight: int = int(PlayerAttributes.NEUTRAL_WEIGHT_LBS)
var _pending_profile: int = PlayerAttributes.GEAR_BALANCED
var _pending_curve: int = PlayerAttributes.GEAR_BALANCED
var _pending_flex: int = PlayerAttributes.GEAR_BALANCED
var _pending_length: int = PlayerAttributes.GEAR_BALANCED
var _pending_tape: int = StickTapeConfig.DEFAULT_CODE
var _pending_skate_model: int = 0
var _pending_glove_model: int = 0
var _pending_lace_color: int = GearStyleConfig.LACE_DEFAULT_INDEX
var _pending_stick_model: int = 0
var _name_valid: bool = true
var _number_valid: bool = true
# Online matches lock the build (attributes replicate at join); cosmetics stay
# editable. Latched on open().
var _build_locked: bool = false
# Reentrancy guard for _refresh_build(): assigning the weight slider's min/max
# there can re-clamp its value and emit value_changed (Godot's Range
# set_min/set_max route through set_value, which is NOT silenced by
# set_value_no_signal). Left unguarded, that reentrant _on_weight_changed
# clobbers the pending weight with a band-clamped value.
var _refreshing: bool = false
# The in-game on-screen keyboard for controller name entry (works on every
# platform, unlike Steam's Big-Picture-only OSK). Created in _ready.
var _keyboard: ControllerKeyboard = null

# Snapshot taken on open(). Cancel restores from this.
var _snapshot: Dictionary = {}


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Controller mode: give toggles/dropdowns a visible focus ring (see the Options
	# panel). Only defines "focus"; everything else falls through to the project theme.
	var focus_theme: Theme = MenuStyle.controller_focus_theme()
	if focus_theme != null:
		theme = focus_theme
	_build()
	_keyboard = ControllerKeyboard.new()
	_keyboard.submitted.connect(_on_keyboard_submitted)
	_keyboard.cancelled.connect(func() -> void: ControllerNav.grab_focus(_name_field))
	add_child(_keyboard)
	visible = false


# Controller text entry: the number is a D-pad stepper (no keyboard needed), and
# the name opens the on-screen keyboard on A. Both only when the field is focused
# in controller mode; handled at _input (ahead of GUI) so ui_left/right don't just
# move the LineEdit caret. ui_cancel stays in _unhandled_input.
func _input(event: InputEvent) -> void:
	if not visible or not ControllerNav.active():
		return
	if _number_field != null and _number_field.has_focus():
		if event.is_action_pressed(&"ui_left"):
			_step_number(-1)
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed(&"ui_right"):
			_step_number(1)
			get_viewport().set_input_as_handled()
	elif _name_field != null and _name_field.has_focus() and event.is_action_pressed(&"ui_accept"):
		# `self` as the background: the key grid covers this form, and focus has to
		# stay on the grid until it's dismissed.
		_keyboard.open(_name_field.text, _name_field.max_length, self)
		get_viewport().set_input_as_handled()


func _step_number(delta: int) -> void:
	var next: int = clampi(_number_field.text.to_int() + delta, 0, 99)
	_number_field.text = str(next)
	_on_number_text_changed(_number_field.text)  # programmatic set doesn't emit text_changed


func _on_keyboard_submitted(text: String) -> void:
	_name_field.text = text
	_on_name_text_changed(text)  # programmatic set doesn't emit text_changed
	ControllerNav.grab_focus(_name_field)


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
	vbox.add_theme_constant_override("separation", 16)
	panel.add_child(vbox)

	_add_close_row(vbox)

	var title := Label.new()
	title.text = "Player"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	MenuStyle.apply_heading(title)
	vbox.add_child(title)

	# One column, every row on the shared label gutter. Fixed width (gutter +
	# separation + field) so the panel doesn't breathe as warnings and pending
	# notes come and go.
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	col.custom_minimum_size = Vector2(_IDENTITY_LABEL_W + 12.0 + _FIELD_W, 0)
	vbox.add_child(col)

	_build_name_section(col)
	_build_number_section(col)
	_build_handedness_section(col)
	_build_position_section(col)
	_build_skin_section(col)
	_build_height_section(col)
	_build_weight_section(col)
	_build_workbench_row(col)
	_build_team_section(col)

	_lock_label = Label.new()
	_lock_label.text = "Build locked during online play."
	_lock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lock_label.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	_lock_label.add_theme_font_size_override("font_size", 13)
	_lock_label.visible = false
	col.add_child(_lock_label)

	_build_action_row(vbox)

	_stick_popup = StickEditorPopup.new()
	_stick_popup.stick_edited.connect(_on_stick_edited)
	add_child(_stick_popup)

	_gear_popup = GearEditorPopup.new()
	_gear_popup.gear_edited.connect(_on_gear_edited)
	add_child(_gear_popup)


# The two workbench launchers side by side — the buttons name themselves, so
# the gutter stays empty (a spacer keeps the pair on the field column's
# edges). Each button's gold "unapplied changes" note sits beneath it
# (pending workbench edits are otherwise invisible until Apply); the notes
# reserve their line so the column doesn't jump.
func _build_workbench_row(vbox: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_BEGIN
	row.add_theme_constant_override("separation", 12)
	vbox.add_child(row)
	var gutter := Control.new()
	gutter.custom_minimum_size = Vector2(_IDENTITY_LABEL_W, 0)
	row.add_child(gutter)
	# One shared note string — sitting under its own button makes "whose
	# changes" unambiguous, and the short form fits the half-field button.
	_stick_pending_label = _add_workbench_launcher(
			row, tr(&"STICK_EDIT_BUTTON"), tr(&"EDIT_PENDING_NOTE"), _open_stick_editor)
	_gear_pending_label = _add_workbench_launcher(
			row, tr(&"GEAR_EDIT_BUTTON"), tr(&"EDIT_PENDING_NOTE"), _open_gear_editor)


# One launcher: the Edit button with its pending note reserved beneath.
# Returns the note label so the caller can toggle it.
func _add_workbench_launcher(row: HBoxContainer, button_text: String,
		note_text: String, on_pressed: Callable) -> Label:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	row.add_child(box)
	var edit_btn := Button.new()
	edit_btn.text = button_text
	edit_btn.custom_minimum_size = Vector2(_PAIR_W, 48)
	edit_btn.add_theme_font_size_override("font_size", 17)
	MenuStyle.wire_hover_scale(edit_btn)
	SoundManager.wire_button(edit_btn)
	edit_btn.pressed.connect(on_pressed)
	box.add_child(edit_btn)
	var note := Label.new()
	note.text = note_text
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.add_theme_color_override("font_color", MenuStyle.GOLD)
	note.add_theme_font_size_override("font_size", 12)
	# Invisible-but-space-reserving so a note appearing doesn't reflow the rows
	# below (Label has no reserve mode; modulate keeps layout, unlike visible).
	note.modulate = Color(1, 1, 1, 0)
	box.add_child(note)
	return note


func _open_stick_editor() -> void:
	# TEAM tape swatches resolve against the pending team pick, so the swatch
	# previews the kit the player is about to wear.
	var accent: Color = _pending_team_colors().primary
	_stick_popup.set_focus_scope(self, null)
	_stick_popup.open(_pending_attributes(), _pending_tape, _pending_stick_model,
			_build_locked, accent)


func _on_stick_edited(curve: int, flex: int, length: int, tape_code: int,
		stick_model: int) -> void:
	if not _build_locked:
		_pending_curve = curve
		_pending_flex = flex
		_pending_length = length
	_pending_tape = tape_code
	_pending_stick_model = stick_model
	_update_apply_state()


func _open_gear_editor() -> void:
	# The whole kit goes over: a model resolves its TEAM / ACCENT / LIGHT zones
	# against the pending team pick, not just one accent color.
	_gear_popup.set_focus_scope(self, null)
	_gear_popup.open(_pending_profile, _pending_skate_model, _pending_glove_model,
			_pending_lace_color, _build_locked, _pending_team_colors(),
			_pending_attributes())


func _on_gear_edited(profile: int, skate_model: int, glove_model: int,
		lace_color: int) -> void:
	if not _build_locked:
		_pending_profile = profile
	_pending_skate_model = skate_model
	_pending_glove_model = glove_model
	_pending_lace_color = lace_color
	_update_apply_state()


func _add_close_row(vbox: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	var close_btn := MenuStyle.close_button()
	close_btn.pressed.connect(_cancel)
	SoundManager.wire_button(close_btn)
	row.add_child(close_btn)
	vbox.add_child(row)


# Rows share a fixed label gutter — labels LEFT-aligned so they all start on
# the same edge (right-aligned labels left the block's left side ragged and
# the card read off-center) — and every control region fills the same
# _FIELD_W (the number field is the one deliberate exception — two digits in
# a 260px box read wrong), so the card is a clean rectangle: label starts,
# field left edges, and field right edges each run straight top to bottom.
# Paired controls (Shoots, the workbench buttons) split the width; the
# sliders' 60px value label counts inside it.
const _IDENTITY_LABEL_W: float = 92.0
const _FIELD_W: float = 260.0
const _FIELD_VALUE_W: float = 60.0
const _PAIR_W: float = (_FIELD_W - 12.0) / 2.0


func _make_identity_label(text: String, tooltip: String = "") -> Label:
	var label := Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(_IDENTITY_LABEL_W, 0)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.add_theme_font_size_override("font_size", 20)
	label.add_theme_color_override("font_color", MenuStyle.TEXT_BODY)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if not tooltip.is_empty():
		label.mouse_filter = Control.MOUSE_FILTER_STOP
		label.tooltip_text = tooltip
	return label


func _build_name_section(vbox: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_BEGIN
	row.add_theme_constant_override("separation", 12)
	vbox.add_child(row)

	row.add_child(_make_identity_label("Name:"))

	_name_field = LineEdit.new()
	_name_field.placeholder_text = "Player"
	# 12 fits the skater jersey nameplate at font 28 without clipping at the
	# back-center seam (jersey_decal.gd centers the name in ~256px of room),
	# and the lobby slot cards shrink-to-fit anything up to it.
	_name_field.max_length = 12
	_name_field.custom_minimum_size = Vector2(_FIELD_W, 48)
	_name_field.add_theme_font_size_override("font_size", 18)
	row.add_child(_name_field)

	_name_warning = Label.new()
	_name_warning.text = "Name not allowed"
	_name_warning.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_warning.add_theme_color_override("font_color", MenuStyle.DANGER)
	_name_warning.add_theme_font_size_override("font_size", 14)
	_name_warning.visible = false
	vbox.add_child(_name_warning)

	_name_field.text_changed.connect(_on_name_text_changed)


func _on_name_text_changed(t: String) -> void:
	var trimmed: String = t.strip_edges()
	if trimmed.is_empty():
		_name_warning.visible = false
		_name_valid = false
		_pending_name = ""
		_update_apply_state()
		return
	if not NameFilter.is_alphanumeric(trimmed):
		_name_warning.text = "Letters and numbers only"
		_name_warning.visible = true
		_name_valid = false
		_update_apply_state()
		return
	if not NameFilter.is_clean(trimmed):
		_name_warning.text = "Name not allowed"
		_name_warning.visible = true
		_name_valid = false
		_update_apply_state()
		return
	_name_warning.visible = false
	_name_valid = true
	_pending_name = trimmed
	_update_apply_state()


func _build_number_section(vbox: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_BEGIN
	row.add_theme_constant_override("separation", 12)
	vbox.add_child(row)

	row.add_child(_make_identity_label("Number:"))

	_number_field = LineEdit.new()
	_number_field.placeholder_text = "10"
	_number_field.max_length = 2
	_number_field.custom_minimum_size = Vector2(80, 48)
	_number_field.add_theme_font_size_override("font_size", 18)
	row.add_child(_number_field)

	_number_warning = Label.new()
	_number_warning.text = "Numbers only"
	_number_warning.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_number_warning.add_theme_color_override("font_color", MenuStyle.DANGER)
	_number_warning.add_theme_font_size_override("font_size", 14)
	_number_warning.visible = false
	vbox.add_child(_number_warning)

	_number_field.text_changed.connect(_on_number_text_changed)


func _on_number_text_changed(t: String) -> void:
	if t.is_empty():
		_number_warning.visible = false
		_number_valid = false
		_update_apply_state()
		return
	if not t.is_valid_int():
		_number_warning.visible = true
		_number_valid = false
		_update_apply_state()
		return
	_number_warning.visible = false
	_number_valid = true
	_pending_number = clamp(t.to_int(), 0, 99)
	_update_apply_state()


func _build_handedness_section(vbox: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_BEGIN
	row.add_theme_constant_override("separation", 12)
	vbox.add_child(row)

	row.add_child(_make_identity_label("Shoots:"))

	_left_btn = Button.new()
	_left_btn.text = "Left"
	_left_btn.toggle_mode = true
	_left_btn.custom_minimum_size = Vector2(_PAIR_W, 48)
	_left_btn.add_theme_font_size_override("font_size", 18)
	MenuStyle.wire_hover_scale(_left_btn)
	SoundManager.wire_button(_left_btn)
	row.add_child(_left_btn)

	_right_btn = Button.new()
	_right_btn.text = "Right"
	_right_btn.toggle_mode = true
	_right_btn.custom_minimum_size = Vector2(_PAIR_W, 48)
	_right_btn.add_theme_font_size_override("font_size", 18)
	MenuStyle.wire_hover_scale(_right_btn)
	SoundManager.wire_button(_right_btn)
	row.add_child(_right_btn)

	_left_btn.toggled.connect(func(pressed: bool) -> void:
		if not pressed and not _right_btn.button_pressed:
			_left_btn.button_pressed = true
			return
		_right_btn.button_pressed = not pressed
		_pending_is_left = pressed
		_update_apply_state())
	_right_btn.toggled.connect(func(pressed: bool) -> void:
		if not pressed and not _left_btn.button_pressed:
			_right_btn.button_pressed = true
			return
		_left_btn.button_pressed = not pressed
		_pending_is_left = not pressed
		_update_apply_state())


# Position dropdown (LW C RW LD RD in rink order); the pick is only read at
# lobby seat time, so it never locks.
func _build_position_section(vbox: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_BEGIN
	row.add_theme_constant_override("separation", 12)
	vbox.add_child(row)

	row.add_child(_make_identity_label(tr(&"PLAYER_POSITION_LABEL"), _POSITION_TOOLTIP))

	_position_btn = OptionButton.new()
	_position_btn.custom_minimum_size = Vector2(_FIELD_W, 48)
	_position_btn.add_theme_font_size_override("font_size", 16)
	_position_btn.tooltip_text = _POSITION_TOOLTIP
	for i: int in _POSITION_KEYS.size():
		_position_btn.add_item(tr(_POSITION_KEYS[i]), i)
	SoundManager.wire_button(_position_btn)
	_position_btn.item_selected.connect(func(index: int) -> void:
		_pending_position = _POSITION_ORDER[index]
		_update_apply_state())
	row.add_child(_position_btn)


func _select_position(position: int) -> void:
	_pending_position = clampi(position, 0, PlayerRules.POSITION_NAMES.size() - 1)
	if _position_btn != null:
		_position_btn.select(maxi(_POSITION_ORDER.find(_pending_position), 0))
	_update_apply_state()


# One toggle swatch per palette tone; the picked one wears a white ring.
# Selection is exclusive-managed by _select_skin (set_pressed_no_signal on
# the rest) so a swatch can never be un-picked into "no skin".
func _build_skin_section(vbox: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_BEGIN
	row.add_theme_constant_override("separation", 12)
	vbox.add_child(row)

	row.add_child(_make_identity_label(tr(&"PLAYER_SKIN_LABEL")))

	# The swatch strip fills the shared field width — each swatch takes an
	# equal share of it rather than a fixed size.
	var swatches := HBoxContainer.new()
	swatches.add_theme_constant_override("separation", 6)
	swatches.custom_minimum_size = Vector2(_FIELD_W, 0)
	row.add_child(swatches)
	_skin_buttons.clear()
	for i: int in SkinToneRegistry.TONES.size():
		var btn := Button.new()
		btn.toggle_mode = true
		btn.custom_minimum_size = Vector2(0, 48)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var plain := StyleBoxFlat.new()
		plain.bg_color = SkinToneRegistry.TONES[i]
		plain.set_corner_radius_all(6)
		var ringed := plain.duplicate() as StyleBoxFlat
		ringed.border_color = Color.WHITE
		ringed.set_border_width_all(3)
		btn.add_theme_stylebox_override("normal", plain)
		btn.add_theme_stylebox_override("hover", ringed)
		btn.add_theme_stylebox_override("pressed", ringed)
		btn.add_theme_stylebox_override("hover_pressed", ringed)
		SoundManager.wire_button(btn)
		var index: int = i
		btn.pressed.connect(func() -> void: _select_skin(index))
		swatches.add_child(btn)
		_skin_buttons.append(btn)


func _select_skin(index: int) -> void:
	_pending_skin = SkinToneRegistry.clamp_index(index)
	for i: int in _skin_buttons.size():
		_skin_buttons[i].set_pressed_no_signal(i == _pending_skin)
	_update_apply_state()


func _build_height_section(vbox: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_BEGIN
	row.add_theme_constant_override("separation", 12)
	vbox.add_child(row)

	row.add_child(_make_identity_label("Height:", _HEIGHT_TOOLTIP))

	_height_slider = HSlider.new()
	_height_slider.min_value = PlayerAttributes.HEIGHT_MIN
	_height_slider.max_value = PlayerAttributes.HEIGHT_MAX
	_height_slider.step = 1
	_height_slider.custom_minimum_size = Vector2(_FIELD_W - _FIELD_VALUE_W - 12.0, 36)
	_height_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_height_slider.set_value_no_signal(PlayerAttributes.HEIGHT_MEDIUM)
	_height_slider.tooltip_text = _HEIGHT_TOOLTIP
	_height_slider.value_changed.connect(_on_height_changed)
	row.add_child(_height_slider)

	_height_value_label = Label.new()
	_height_value_label.custom_minimum_size = Vector2(_FIELD_VALUE_W, 0)
	_height_value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_height_value_label.add_theme_font_size_override("font_size", 18)
	_height_value_label.add_theme_color_override("font_color", MenuStyle.TEXT_BODY)
	_height_value_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_height_value_label)


func _build_weight_section(vbox: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_BEGIN
	row.add_theme_constant_override("separation", 12)
	vbox.add_child(row)

	row.add_child(_make_identity_label("Weight:", _WEIGHT_TOOLTIP))

	_weight_slider = HSlider.new()
	_weight_slider.step = 1
	_weight_slider.custom_minimum_size = Vector2(_FIELD_W - _FIELD_VALUE_W - 12.0, 36)
	_weight_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_weight_slider.tooltip_text = _WEIGHT_TOOLTIP
	_weight_slider.value_changed.connect(_on_weight_changed)
	row.add_child(_weight_slider)

	_weight_value_label = Label.new()
	_weight_value_label.custom_minimum_size = Vector2(_FIELD_VALUE_W, 0)
	_weight_value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_weight_value_label.add_theme_font_size_override("font_size", 18)
	_weight_value_label.add_theme_color_override("font_color", MenuStyle.TEXT_BODY)
	_weight_value_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_weight_value_label)


func _on_height_changed(value: float) -> void:
	if _refreshing or _build_locked:
		return
	# Preserve the FRAME across the height change: ride frame-t, not raw BMI —
	# the band's lean half is truncated by the absolute playable-mass floor at
	# the short heights, so carrying the frame position is what keeps a lean
	# build lean (and pins a neutral build to neutral) across the whole range.
	var frame: float = PlayerAttributes.frame_t_for(_pending_height, _pending_weight)
	_pending_height = int(value)
	_pending_weight = PlayerAttributes.weight_for_frame_t(_pending_height, frame)
	_refresh_build()
	_update_apply_state()


func _on_weight_changed(value: float) -> void:
	if _refreshing or _build_locked:
		return
	_pending_weight = PlayerAttributes.coerce_weight(_pending_height, int(value))
	_refresh_build()
	_update_apply_state()


func _build_team_section(vbox: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_BEGIN
	row.add_theme_constant_override("separation", 12)
	vbox.add_child(row)

	row.add_child(_make_identity_label("Team:"))

	var initial_slot: int = PlayerPrefs.preferred_color_slot
	if initial_slot < 0:
		initial_slot = TeamColorRegistry.DEFAULT_HOME_SLOT
	_color_dropdown = PaletteDropdown.new(initial_slot, Vector2(_FIELD_W, 48))
	row.add_child(_color_dropdown)

	_color_dropdown.selected.connect(func(slot: int) -> void:
		_pending_color_slot = slot
		_update_apply_state())


func _build_action_row(vbox: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	vbox.add_child(row)

	_apply_btn = Button.new()
	_apply_btn.text = "Apply"
	MenuStyle.apply_primary_cta(_apply_btn, 18)
	_apply_btn.custom_minimum_size = Vector2(140, 44)
	_apply_btn.pressed.connect(_apply)
	SoundManager.wire_button(_apply_btn)
	row.add_child(_apply_btn)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.custom_minimum_size = Vector2(140, 44)
	cancel_btn.add_theme_font_size_override("font_size", 18)
	cancel_btn.pressed.connect(_cancel)
	SoundManager.wire_button(cancel_btn)
	row.add_child(cancel_btn)


# The pending build as a coerced PlayerAttributes (what the stick editor
# previews — its stick gear rides real height, so it needs the body too).
func _pending_attributes() -> PlayerAttributes:
	return PlayerAttributes.new(_pending_height, _pending_weight, _pending_profile,
			_pending_curve, _pending_flex, _pending_length)


func _pending_team_colors() -> Dictionary:
	return TeamColorRegistry.get_colors(maxi(_pending_color_slot, 0), 0)


func _pending_gear_code() -> int:
	return GearStyleConfig.new(_pending_skate_model, _pending_glove_model,
			_pending_lace_color, _pending_stick_model).to_code()


func _snapshot_gear() -> GearStyleConfig:
	return GearStyleConfig.from_code(
			int(_snapshot.get("gear", GearStyleConfig.DEFAULT_CODE)))


# Whether the stick the player would get on Apply differs from the one the rink
# is showing — pending stick edits are otherwise invisible behind the button.
# The stick MODEL is compared apart from the rest of the gear code because it
# is edited here, in the stick workbench, not the gear one.
func _is_stick_dirty() -> bool:
	return _pending_curve != int(_snapshot.get("curve", 0)) \
			or _pending_flex != int(_snapshot.get("flex", 0)) \
			or _pending_length != int(_snapshot.get("length", 0)) \
			or _pending_tape != int(_snapshot.get("tape", 0)) \
			or _pending_stick_model != _snapshot_gear().stick_model


# Same visibility contract for the gear workbench's picks (its three fields of
# the gear code — the stick model field belongs to the stick note above).
func _is_gear_dirty() -> bool:
	var gear: GearStyleConfig = _snapshot_gear()
	return _pending_profile != int(_snapshot.get("profile", 0)) \
			or _pending_skate_model != gear.skate_model \
			or _pending_glove_model != gear.glove_model \
			or _pending_lace_color != gear.lace_color


func _is_build_dirty() -> bool:
	return _pending_height != int(_snapshot.get("height", 0)) \
			or _pending_weight != int(_snapshot.get("weight", 0)) \
			or _pending_profile != int(_snapshot.get("profile", 0)) \
			or _pending_curve != int(_snapshot.get("curve", 0)) \
			or _pending_flex != int(_snapshot.get("flex", 0)) \
			or _pending_length != int(_snapshot.get("length", 0))


# Apply is disabled when (a) nothing changed, or (b) any field is invalid.
func _update_apply_state() -> void:
	if _apply_btn == null:
		return
	var changed: bool = (_pending_name != _snapshot.get("name", "")
		or _pending_number != _snapshot.get("number", 0)
		or _pending_is_left != _snapshot.get("is_left", false)
		or _pending_position != int(_snapshot.get("position", 0))
		or _pending_color_slot != _snapshot.get("color_slot", -1)
		or _pending_skin != int(_snapshot.get("skin", SkinToneRegistry.DEFAULT_INDEX))
		or _pending_tape != int(_snapshot.get("tape", StickTapeConfig.DEFAULT_CODE))
		or _pending_gear_code() != int(_snapshot.get("gear", GearStyleConfig.DEFAULT_CODE))
		or _is_build_dirty())
	_apply_btn.disabled = not changed or not _name_valid or not _number_valid
	# The notes fade via modulate, not `visible` — they reserve their line so
	# the rows below never reflow.
	if _stick_pending_label != null:
		_stick_pending_label.modulate.a = 1.0 if _is_stick_dirty() else 0.0
	if _gear_pending_label != null:
		_gear_pending_label.modulate.a = 1.0 if _is_gear_dirty() else 0.0


func _apply() -> void:
	if not _name_valid or not _number_valid:
		return
	var name_changed_b: bool = _pending_name != _snapshot.get("name", "")
	var number_changed_b: bool = _pending_number != _snapshot.get("number", 0)
	var hand_changed_b: bool = _pending_is_left != _snapshot.get("is_left", false)
	var color_changed_b: bool = _pending_color_slot != _snapshot.get("color_slot", -1)
	if name_changed_b:
		PlayerPrefs.player_name = _pending_name
		name_changed.emit(_pending_name)
	if number_changed_b:
		PlayerPrefs.jersey_number = _pending_number
		jersey_number_changed.emit(_pending_number)
	if hand_changed_b:
		PlayerPrefs.is_left_handed = _pending_is_left
		handedness_changed.emit(_pending_is_left)
	if name_changed_b or number_changed_b or hand_changed_b:
		# Single call writes NetworkManager.local_* and emits the
		# local_identity_changed signal that GameManager listens to so the
		# live skater updates without a respawn.
		NetworkManager.apply_local_identity(_pending_name, _pending_number, _pending_is_left)
	if _pending_position != int(_snapshot.get("position", 0)):
		PlayerPrefs.preferred_position = _pending_position
		# Peer-map mirror only — the preference is read at the next lobby
		# seat, never live. The signal is for menu chrome (the player card).
		NetworkManager.apply_local_position(_pending_position)
		position_changed.emit(_pending_position)
	if _pending_skin != int(_snapshot.get("skin", SkinToneRegistry.DEFAULT_INDEX)):
		PlayerPrefs.skin_tone = _pending_skin
		# Writes the peer map and emits local_skin_changed so GameManager
		# repaints the live skater — same live-cosmetic path as the tape job.
		NetworkManager.apply_local_skin(_pending_skin)
	if color_changed_b:
		# apply_preferred_color writes PlayerPrefs.preferred_color_slot and
		# emits local_preferred_color_changed so GameManager can re-tint
		# the home team's actors and re-roll away if the new home collides.
		NetworkManager.apply_preferred_color(_pending_color_slot)
		preferred_color_changed.emit(_pending_color_slot)
	if _is_build_dirty() and not _build_locked:
		var new_attrs: PlayerAttributes = _pending_attributes()
		PlayerPrefs.set_player_attributes(new_attrs)
		# Update NetworkManager._peer_attributes[1] so the next spawn picks
		# the new values up. The emitted signal also re-applies the multipliers
		# to the live local skater when allowed (offline / free-play only —
		# GameManager's handler is the gate).
		NetworkManager.apply_local_attributes(new_attrs)
		attributes_changed.emit(new_attrs)
	if _pending_tape != int(_snapshot.get("tape", StickTapeConfig.DEFAULT_CODE)):
		PlayerPrefs.stick_tape_code = _pending_tape
		NetworkManager.apply_local_tape(_pending_tape)
	var gear_code: int = _pending_gear_code()
	if gear_code != int(_snapshot.get("gear", GearStyleConfig.DEFAULT_CODE)):
		PlayerPrefs.gear_style_code = gear_code
		# Same live-cosmetic path as tape and skin.
		NetworkManager.apply_local_gear_style(gear_code)
	PlayerPrefs.save()
	visible = false


# Cancel restores form controls to snapshot values so re-opening shows the
# saved state, not the abandoned edits.
func _cancel() -> void:
	_restore_from_snapshot()
	visible = false


func _restore_from_snapshot() -> void:
	_pending_name = _snapshot.get("name", "")
	_pending_number = _snapshot.get("number", 0)
	_pending_is_left = _snapshot.get("is_left", false)
	_pending_color_slot = _snapshot.get("color_slot", TeamColorRegistry.DEFAULT_HOME_SLOT)
	_select_position(int(_snapshot.get("position", 0)))
	_select_skin(int(_snapshot.get("skin", SkinToneRegistry.DEFAULT_INDEX)))
	_pending_height = int(_snapshot.get("height", PlayerAttributes.HEIGHT_MEDIUM))
	_pending_weight = int(_snapshot.get("weight", int(PlayerAttributes.NEUTRAL_WEIGHT_LBS)))
	_pending_profile = int(_snapshot.get("profile", PlayerAttributes.GEAR_BALANCED))
	_pending_curve = int(_snapshot.get("curve", PlayerAttributes.GEAR_BALANCED))
	_pending_flex = int(_snapshot.get("flex", PlayerAttributes.GEAR_BALANCED))
	_pending_length = int(_snapshot.get("length", PlayerAttributes.GEAR_BALANCED))
	_pending_tape = int(_snapshot.get("tape", StickTapeConfig.DEFAULT_CODE))
	var gear := GearStyleConfig.from_code(
			int(_snapshot.get("gear", GearStyleConfig.DEFAULT_CODE)))
	_pending_skate_model = gear.skate_model
	_pending_glove_model = gear.glove_model
	_pending_lace_color = gear.lace_color
	_pending_stick_model = gear.stick_model
	_name_field.text = _pending_name
	_number_field.text = str(_pending_number)
	_left_btn.button_pressed = _pending_is_left
	_right_btn.button_pressed = not _pending_is_left
	if _color_dropdown != null:
		_color_dropdown.set_selected(_pending_color_slot)
	_name_warning.visible = false
	_number_warning.visible = false
	_name_valid = true
	_number_valid = true
	_refresh_build()
	_update_apply_state()


# Refresh the build controls (sliders + value labels) from the pending build,
# and apply the online-match lock. The profile row lives in the gear workbench,
# which reads the pending value fresh on every open.
func _refresh_build() -> void:
	if _height_slider == null:
		return
	# Guard the whole pass: assigning the weight slider's bounds below can emit
	# a reentrant value_changed that would clobber the pending weight.
	_refreshing = true
	_height_slider.set_value_no_signal(_pending_height)
	_height_slider.editable = not _build_locked
	_height_value_label.text = PlayerAttributes.inches_label(_pending_height)
	# Bounds first, then the value — setting a value outside the slider's
	# current range would clamp it before the new bounds land.
	_weight_slider.min_value = PlayerAttributes.weight_min(_pending_height)
	_weight_slider.max_value = PlayerAttributes.weight_max(_pending_height)
	_weight_slider.set_value_no_signal(_pending_weight)
	_weight_slider.editable = not _build_locked
	_weight_value_label.text = "%d lbs" % _pending_weight
	if _lock_label != null:
		_lock_label.visible = _build_locked
	_refreshing = false


func _on_overlay_clicked(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		_cancel()


func open() -> void:
	var saved_slot: int = PlayerPrefs.preferred_color_slot
	if saved_slot < 0:
		saved_slot = TeamColorRegistry.DEFAULT_HOME_SLOT
	_build_locked = NetworkManager.is_in_online_match()
	_snapshot = {
		"name": PlayerPrefs.player_name,
		"number": PlayerPrefs.jersey_number,
		"is_left": PlayerPrefs.is_left_handed,
		"position": clampi(PlayerPrefs.preferred_position, 0,
				PlayerRules.POSITION_NAMES.size() - 1),
		"color_slot": saved_slot,
		"skin": SkinToneRegistry.clamp_index(PlayerPrefs.skin_tone),
		"height": PlayerPrefs.attr_height,
		"weight": PlayerPrefs.attr_weight,
		"profile": PlayerPrefs.attr_profile,
		"curve": PlayerPrefs.attr_curve,
		"flex": PlayerPrefs.attr_flex,
		"length": PlayerPrefs.attr_length,
		"tape": PlayerPrefs.stick_tape_code,
		"gear": GearStyleConfig.from_code(PlayerPrefs.gear_style_code).to_code(),
	}
	_restore_from_snapshot()
	visible = true
	ControllerNav.focus_first(self)  # controller: take focus off the Side Menu behind


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed(&"ui_cancel"):
		_cancel()
		get_viewport().set_input_as_handled()
