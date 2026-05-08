class_name PlayerSettingsPopup
extends Control

signal name_changed(new_name: String)
signal jersey_number_changed(new_number: int)
signal handedness_changed(is_left: bool)


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	visible = false


func _build() -> void:
	var overlay := ColorRect.new()
	overlay.color = Color(0.0, 0.0, 0.0, 0.6)
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


func _add_close_row(vbox: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	var close_btn := MenuStyle.close_button()
	close_btn.pressed.connect(func() -> void: visible = false)
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
	name_label.add_theme_color_override("font_color", Color.WHITE)
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(name_label)

	var field := LineEdit.new()
	field.placeholder_text = "Player"
	field.max_length = 10
	field.custom_minimum_size = Vector2(200, 48)
	field.add_theme_font_size_override("font_size", 18)
	field.text = PlayerPrefs.player_name
	NetworkManager.local_player_name = PlayerPrefs.player_name
	row.add_child(field)

	var warning := Label.new()
	warning.text = "Name not allowed"
	warning.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	warning.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
	warning.add_theme_font_size_override("font_size", 14)
	warning.visible = false
	vbox.add_child(warning)

	field.text_changed.connect(func(t: String) -> void:
		if t.strip_edges().is_empty():
			warning.visible = false
			return
		var trimmed: String = t.strip_edges()
		if not NameFilter.is_alphanumeric(trimmed):
			warning.text = "Letters and numbers only"
			warning.visible = true
			return
		if not NameFilter.is_clean(trimmed):
			warning.text = "Name not allowed"
			warning.visible = true
			return
		warning.visible = false
		NetworkManager.local_player_name = trimmed
		PlayerPrefs.player_name = trimmed
		PlayerPrefs.save()
		name_changed.emit(trimmed))


func _build_number_section(vbox: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	vbox.add_child(row)

	var label := Label.new()
	label.text = "Number:"
	label.add_theme_font_size_override("font_size", 20)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)

	var field := LineEdit.new()
	field.placeholder_text = "10"
	field.max_length = 2
	field.custom_minimum_size = Vector2(80, 48)
	field.add_theme_font_size_override("font_size", 18)
	field.text = str(PlayerPrefs.jersey_number)
	NetworkManager.local_jersey_number = PlayerPrefs.jersey_number
	row.add_child(field)

	var warning := Label.new()
	warning.text = "Numbers only"
	warning.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	warning.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
	warning.add_theme_font_size_override("font_size", 14)
	warning.visible = false
	vbox.add_child(warning)

	field.text_changed.connect(func(t: String) -> void:
		if not t.is_empty() and not t.is_valid_int():
			warning.visible = true
			return
		warning.visible = false
		var n: int = t.to_int() if t.is_valid_int() else PlayerPrefs.jersey_number
		n = clamp(n, 0, 99)
		NetworkManager.local_jersey_number = n
		PlayerPrefs.jersey_number = n
		PlayerPrefs.save()
		jersey_number_changed.emit(n))


func _build_handedness_section(vbox: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	vbox.add_child(row)

	var label := Label.new()
	label.text = "Shoots:"
	label.add_theme_font_size_override("font_size", 20)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)

	var left_btn := Button.new()
	left_btn.text = "Left"
	left_btn.toggle_mode = true
	left_btn.button_pressed = PlayerPrefs.is_left_handed
	left_btn.custom_minimum_size = Vector2(90, 48)
	left_btn.add_theme_font_size_override("font_size", 18)
	MenuStyle.wire_hover_scale(left_btn)
	SoundManager.wire_button(left_btn)
	row.add_child(left_btn)

	var right_btn := Button.new()
	right_btn.text = "Right"
	right_btn.toggle_mode = true
	right_btn.button_pressed = not PlayerPrefs.is_left_handed
	right_btn.custom_minimum_size = Vector2(90, 48)
	right_btn.add_theme_font_size_override("font_size", 18)
	MenuStyle.wire_hover_scale(right_btn)
	SoundManager.wire_button(right_btn)
	row.add_child(right_btn)

	NetworkManager.local_is_left_handed = PlayerPrefs.is_left_handed

	left_btn.toggled.connect(func(pressed: bool) -> void:
		if not pressed and not right_btn.button_pressed:
			left_btn.button_pressed = true
			return
		right_btn.button_pressed = not pressed
		_apply_handedness(pressed))
	right_btn.toggled.connect(func(pressed: bool) -> void:
		if not pressed and not left_btn.button_pressed:
			right_btn.button_pressed = true
			return
		left_btn.button_pressed = not pressed
		_apply_handedness(not pressed))


func _apply_handedness(is_left: bool) -> void:
	NetworkManager.local_is_left_handed = is_left
	PlayerPrefs.is_left_handed = is_left
	PlayerPrefs.save()
	handedness_changed.emit(is_left)


func _on_overlay_clicked(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		visible = false


func open() -> void:
	visible = true


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed(&"ui_cancel"):
		visible = false
		get_viewport().set_input_as_handled()
