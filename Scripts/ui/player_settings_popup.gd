class_name PlayerSettingsPopup
extends Control

# Snapshot-and-commit pattern: edits buffer in _pending_* until Apply is
# pressed. Cancel / ESC / overlay-click revert. Mirrors OptionsPanel.

signal name_changed(new_name: String)
signal jersey_number_changed(new_number: int)
signal handedness_changed(is_left: bool)
signal preferred_color_changed(color_slot: int)
signal attributes_changed(attrs: PlayerAttributes)

const _ATTR_LABELS: Array[String] = ["Speed", "Agility", "Size", "Shot"]
const _ATTR_NONE: int = -1

# Controls — kept as refs so Cancel can restore them from the snapshot.
var _name_field: LineEdit = null
var _name_warning: Label = null
var _number_field: LineEdit = null
var _number_warning: Label = null
var _left_btn: Button = null
var _right_btn: Button = null
var _color_dropdown: PaletteDropdown = null
var _apply_btn: Button = null
var _strength_buttons: Array[Button] = []
var _weakness_buttons: Array[Button] = []
var _attribute_lock_label: Label = null

# Pending state — what Apply will commit.
var _pending_name: String = ""
var _pending_number: int = 0
var _pending_is_left: bool = false
var _pending_color_slot: int = -1
var _pending_strength: int = _ATTR_NONE
var _pending_weakness: int = _ATTR_NONE
var _name_valid: bool = true
var _number_valid: bool = true

# Snapshot taken on open(). Cancel restores from this.
var _snapshot: Dictionary = {}


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	visible = false


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
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", MenuStyle.TEXT_TITLE)
	vbox.add_child(title)

	_build_name_section(vbox)
	_build_number_section(vbox)
	_build_handedness_section(vbox)
	_build_team_section(vbox)
	_build_attributes_section(vbox)
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
	_name_field.max_length = 10
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


func _build_attributes_section(vbox: VBoxContainer) -> void:
	# Strength / weakness picker: one button bar per row, mutually exclusive
	# within the row, and strength + weakness can't be the same attribute.
	# Online play locks the picker — the lock label appears in place of the
	# helper hint. Storage is always the four levels; this UI is the only
	# place that knows the strength/weakness shortcut.
	var heading := Label.new()
	heading.text = "Attributes"
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_font_size_override("font_size", 20)
	heading.add_theme_color_override("font_color", MenuStyle.TEXT_TITLE)
	vbox.add_child(heading)

	_attribute_lock_label = Label.new()
	_attribute_lock_label.text = "Locked during online play."
	_attribute_lock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_attribute_lock_label.add_theme_color_override("font_color", MenuStyle.TEXT_BODY)
	_attribute_lock_label.add_theme_font_size_override("font_size", 13)
	_attribute_lock_label.visible = false
	vbox.add_child(_attribute_lock_label)

	_strength_buttons = _build_attribute_row(vbox, "Strength:", true)
	_weakness_buttons = _build_attribute_row(vbox, "Weakness:", false)


func _build_attribute_row(vbox: VBoxContainer, label_text: String, is_strength: bool) -> Array[Button]:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	vbox.add_child(row)

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(90, 0)
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", MenuStyle.TEXT_BODY)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)

	var buttons: Array[Button] = []
	for attr_idx: int in _ATTR_LABELS.size():
		var btn := Button.new()
		btn.text = _ATTR_LABELS[attr_idx]
		btn.toggle_mode = true
		btn.custom_minimum_size = Vector2(72, 36)
		btn.add_theme_font_size_override("font_size", 14)
		MenuStyle.wire_hover_scale(btn)
		SoundManager.wire_button(btn)
		btn.toggled.connect(_on_attribute_button_toggled.bind(attr_idx, is_strength))
		row.add_child(btn)
		buttons.append(btn)
	return buttons


func _on_attribute_button_toggled(pressed: bool, attr_idx: int, is_strength: bool) -> void:
	var picked: int = attr_idx if pressed else _ATTR_NONE
	# Selecting the same attribute as the other row clears the other so the
	# 3-2-2-1 invariant always holds (strength != weakness).
	if is_strength:
		_pending_strength = picked
		if pressed and _pending_weakness == attr_idx:
			_pending_weakness = _ATTR_NONE
	else:
		_pending_weakness = picked
		if pressed and _pending_strength == attr_idx:
			_pending_strength = _ATTR_NONE
	_refresh_attribute_buttons()
	_update_apply_state()


func _refresh_attribute_buttons() -> void:
	for i: int in _strength_buttons.size():
		_strength_buttons[i].set_pressed_no_signal(i == _pending_strength)
	for i: int in _weakness_buttons.size():
		_weakness_buttons[i].set_pressed_no_signal(i == _pending_weakness)


func _set_attribute_buttons_disabled(disabled: bool) -> void:
	for btn: Button in _strength_buttons:
		btn.disabled = disabled
	for btn: Button in _weakness_buttons:
		btn.disabled = disabled
	if _attribute_lock_label != null:
		_attribute_lock_label.visible = disabled


# Derives strength / weakness picks from a stored four-level spread. With the
# 3-2-2-1 invariant the picker enforces, exactly one attribute is GOOD
# (strength) and one is BAD (weakness) for any saved spread that came from
# this popup; an all-medium default has both unset.
static func _picks_from_attrs(attrs: PlayerAttributes) -> Dictionary:
	var strength: int = _ATTR_NONE
	var weakness: int = _ATTR_NONE
	for attr_idx: int in _ATTR_LABELS.size():
		var level: int = attrs.level_for(attr_idx)
		if level == PlayerAttributes.LEVEL_GOOD and strength == _ATTR_NONE:
			strength = attr_idx
		elif level == PlayerAttributes.LEVEL_BAD and weakness == _ATTR_NONE:
			weakness = attr_idx
	return {"strength": strength, "weakness": weakness}


func _build_action_row(vbox: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	vbox.add_child(row)

	_apply_btn = Button.new()
	_apply_btn.text = "Apply"
	_apply_btn.theme_type_variation = &"ButtonPrimary"
	_apply_btn.custom_minimum_size = Vector2(140, 44)
	_apply_btn.add_theme_font_size_override("font_size", 18)
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
	var changed: bool = (_pending_name != _snapshot.get("name", "")
		or _pending_number != _snapshot.get("number", 0)
		or _pending_is_left != _snapshot.get("is_left", false)
		or _pending_color_slot != _snapshot.get("color_slot", -1)
		or _pending_strength != _snapshot.get("strength", _ATTR_NONE)
		or _pending_weakness != _snapshot.get("weakness", _ATTR_NONE))
	_apply_btn.disabled = not changed or not _name_valid or not _number_valid


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
	var attrs_changed_b: bool = (_pending_strength != _snapshot.get("strength", _ATTR_NONE)
		or _pending_weakness != _snapshot.get("weakness", _ATTR_NONE))
	if attrs_changed_b:
		var new_attrs := PlayerAttributes.from_strength_weakness(_pending_strength, _pending_weakness)
		PlayerPrefs.set_player_attributes(new_attrs)
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
	_restore_from_snapshot()
	visible = false


func _restore_from_snapshot() -> void:
	_pending_name = _snapshot.get("name", "")
	_pending_number = _snapshot.get("number", 0)
	_pending_is_left = _snapshot.get("is_left", false)
	_pending_color_slot = _snapshot.get("color_slot", TeamColorRegistry.DEFAULT_HOME_SLOT)
	_pending_strength = _snapshot.get("strength", _ATTR_NONE)
	_pending_weakness = _snapshot.get("weakness", _ATTR_NONE)
	_name_field.text = _pending_name
	_number_field.text = str(_pending_number)
	_left_btn.button_pressed = _pending_is_left
	_right_btn.button_pressed = not _pending_is_left
	if _color_dropdown != null:
		_color_dropdown.set_selected(_pending_color_slot)
	_refresh_attribute_buttons()
	_set_attribute_buttons_disabled(NetworkManager.is_in_online_match())
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
	var saved_picks: Dictionary = _picks_from_attrs(PlayerPrefs.get_player_attributes())
	_snapshot = {
		"name": PlayerPrefs.player_name,
		"number": PlayerPrefs.jersey_number,
		"is_left": PlayerPrefs.is_left_handed,
		"color_slot": saved_slot,
		"strength": saved_picks.strength,
		"weakness": saved_picks.weakness,
	}
	_restore_from_snapshot()
	visible = true


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed(&"ui_cancel"):
		_cancel()
		get_viewport().set_input_as_handled()
