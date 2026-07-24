class_name PlayerSettingsPopup
extends Control

# Snapshot-and-commit pattern: edits buffer in _pending_* until Apply is
# pressed. Cancel / ESC / overlay-click revert. Mirrors OptionsPanel.

signal name_changed(new_name: String)
signal jersey_number_changed(new_number: int)
signal handedness_changed(is_left: bool)
signal preferred_color_changed(color_slot: int)
signal attributes_changed(attrs: PlayerAttributes)

# Controls — kept as refs so Cancel can restore them from the snapshot.
var _name_field: LineEdit = null
var _name_warning: Label = null
var _number_field: LineEdit = null
var _number_warning: Label = null
var _left_btn: Button = null
var _right_btn: Button = null
var _color_dropdown: PaletteDropdown = null
var _apply_btn: Button = null
# Attribute editing + presets live in a reusable child panel that self-manages
# its own snapshot/restore/commit; the popup just wires its `changed` signal
# into _update_apply_state and gates Apply on its is_dirty()/is_valid().
var _attr_panel: AttributePickerPanel = null

# Pending state — what Apply will commit.
var _pending_name: String = ""
var _pending_number: int = 0
var _pending_is_left: bool = false
var _pending_color_slot: int = -1
var _name_valid: bool = true
var _number_valid: bool = true
# True between opening the Steam text-input overlay for the name and its result,
# so text_input_dismissed only writes the name when we asked for it.
var _awaiting_name_input: bool = false

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
	SteamManager.text_input_dismissed.connect(_on_text_input_dismissed)
	visible = false


# Controller text entry: the number is a D-pad stepper (no keyboard needed), and
# the name opens Steam's on-screen keyboard on A. Both only when the field is
# focused in controller mode; handled at _input (ahead of GUI) so ui_left/right
# don't just move the LineEdit caret. ui_cancel stays in _unhandled_input.
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
		if _open_name_input():
			get_viewport().set_input_as_handled()


func _step_number(delta: int) -> void:
	var next: int = clampi(_number_field.text.to_int() + delta, 0, 99)
	_number_field.text = str(next)
	_on_number_text_changed(_number_field.text)  # programmatic set doesn't emit text_changed


# Returns whether the Steam keyboard actually opened (false → no Steam, so the
# field stays keyboard-editable and we don't consume the press).
func _open_name_input() -> bool:
	if SteamManager.show_text_input(_name_field.text, "Player Name", _name_field.max_length):
		_awaiting_name_input = true
		return true
	return false


func _on_text_input_dismissed(submitted: bool, text: String) -> void:
	if not _awaiting_name_input:
		return
	_awaiting_name_input = false
	if submitted:
		_name_field.text = text
		_on_name_text_changed(text)  # programmatic set doesn't emit text_changed


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

	_build_name_section(vbox)
	_build_number_section(vbox)
	_build_handedness_section(vbox)
	_build_team_section(vbox)
	_attr_panel = AttributePickerPanel.new()
	_attr_panel.changed.connect(_update_apply_state)
	vbox.add_child(_attr_panel)
	_build_action_row(vbox)


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


func _build_name_section(vbox: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	vbox.add_child(row)

	var name_label := Label.new()
	name_label.text = "Name:"
	name_label.add_theme_font_size_override("font_size", 20)
	name_label.add_theme_color_override("font_color", MenuStyle.TEXT_BODY)
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(name_label)

	_name_field = LineEdit.new()
	_name_field.placeholder_text = "Player"
	# 12 fits the skater jersey nameplate at font 28 without clipping at the
	# back-center seam (jersey_decal.gd centers the name in ~256px of room),
	# and the lobby slot cards shrink-to-fit anything up to it.
	_name_field.max_length = 12
	_name_field.custom_minimum_size = Vector2(200, 48)
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
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	vbox.add_child(row)

	var label := Label.new()
	label.text = "Number:"
	label.add_theme_font_size_override("font_size", 20)
	label.add_theme_color_override("font_color", MenuStyle.TEXT_BODY)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)

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
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	vbox.add_child(row)

	var label := Label.new()
	label.text = "Shoots:"
	label.add_theme_font_size_override("font_size", 20)
	label.add_theme_color_override("font_color", MenuStyle.TEXT_BODY)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)

	_left_btn = Button.new()
	_left_btn.text = "Left"
	_left_btn.toggle_mode = true
	_left_btn.custom_minimum_size = Vector2(90, 48)
	_left_btn.add_theme_font_size_override("font_size", 18)
	MenuStyle.wire_hover_scale(_left_btn)
	SoundManager.wire_button(_left_btn)
	row.add_child(_left_btn)

	_right_btn = Button.new()
	_right_btn.text = "Right"
	_right_btn.toggle_mode = true
	_right_btn.custom_minimum_size = Vector2(90, 48)
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


func _build_team_section(vbox: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	vbox.add_child(row)

	var label := Label.new()
	label.text = "Team:"
	label.add_theme_font_size_override("font_size", 20)
	label.add_theme_color_override("font_color", MenuStyle.TEXT_BODY)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)

	var initial_slot: int = PlayerPrefs.preferred_color_slot
	if initial_slot < 0:
		initial_slot = TeamColorRegistry.DEFAULT_HOME_SLOT
	_color_dropdown = PaletteDropdown.new(initial_slot, Vector2(200, 48))
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


# Apply is disabled when (a) nothing changed, or (b) any field is invalid.
func _update_apply_state() -> void:
	if _apply_btn == null:
		return
	var attrs_dirty: bool = _attr_panel != null and _attr_panel.is_dirty()
	var changed: bool = (_pending_name != _snapshot.get("name", "")
		or _pending_number != _snapshot.get("number", 0)
		or _pending_is_left != _snapshot.get("is_left", false)
		or _pending_color_slot != _snapshot.get("color_slot", -1)
		or attrs_dirty)
	# The picker panel owns attribute validity (full budget on any touched build);
	# name/number/etc. can apply on their own.
	var attrs_ok: bool = _attr_panel == null or _attr_panel.is_valid()
	_apply_btn.disabled = not changed or not _name_valid or not _number_valid or not attrs_ok


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
	if color_changed_b:
		# apply_preferred_color writes PlayerPrefs.preferred_color_slot and
		# emits local_preferred_color_changed so GameManager can re-tint
		# the home team's actors and re-roll away if the new home collides.
		NetworkManager.apply_preferred_color(_pending_color_slot)
		preferred_color_changed.emit(_pending_color_slot)
	if _attr_panel != null and _attr_panel.is_dirty():
		# commit() writes the working presets + active index back into PlayerPrefs
		# (which syncs the flat build) and returns the active PlayerAttributes.
		var new_attrs: PlayerAttributes = _attr_panel.commit()
		# Update NetworkManager._peer_attributes[1] so the next spawn picks
		# the new values up. The emitted signal also re-applies the multipliers
		# to the live local skater when allowed (offline / free-play only —
		# GameManager's handler is the gate).
		NetworkManager.apply_local_attributes(new_attrs)
		attributes_changed.emit(new_attrs)
	PlayerPrefs.save()
	visible = false


# Cancel restores form controls to snapshot values so re-opening shows the
# saved state, not the abandoned edits.
func _cancel() -> void:
	if _attr_panel != null:
		_attr_panel.restore()
	_restore_from_snapshot()
	visible = false


func _restore_from_snapshot() -> void:
	_pending_name = _snapshot.get("name", "")
	_pending_number = _snapshot.get("number", 0)
	_pending_is_left = _snapshot.get("is_left", false)
	_pending_color_slot = _snapshot.get("color_slot", TeamColorRegistry.DEFAULT_HOME_SLOT)
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
	_update_apply_state()


func _on_overlay_clicked(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		_cancel()


func open() -> void:
	var saved_slot: int = PlayerPrefs.preferred_color_slot
	if saved_slot < 0:
		saved_slot = TeamColorRegistry.DEFAULT_HOME_SLOT
	_snapshot = {
		"name": PlayerPrefs.player_name,
		"number": PlayerPrefs.jersey_number,
		"is_left": PlayerPrefs.is_left_handed,
		"color_slot": saved_slot,
	}
	if _attr_panel != null:
		_attr_panel.set_locked(NetworkManager.is_in_online_match())
		_attr_panel.snapshot()
	_restore_from_snapshot()
	visible = true
	ControllerNav.focus_first(self)  # controller: take focus off the Side Menu behind


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed(&"ui_cancel"):
		_cancel()
		get_viewport().set_input_as_handled()
