class_name ControllerKeyboard
extends CanvasLayer

# Minimal on-screen keyboard for controller text entry that works on EVERY
# platform — Steam's gamepad keyboard only appears in Big Picture / on Deck, so a
# desktop pad user would otherwise have no way to type. Navigate the key grid with
# the stick / D-pad, A types a key, DEL / DONE finish; B cancels. The field owner
# opens it and listens on `submitted`.

signal submitted(text: String)
signal cancelled

# Uppercase letters + digits (the player name allows letters and numbers only).
const _ROWS: Array[String] = ["1234567890", "QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM"]

var _text: String = ""
var _max_len: int = 12
var _preview: Label = null
var _first_key: Button = null


func _ready() -> void:
	layer = 40  # above every menu
	visible = false
	_build()


func _build() -> void:
	var scrim := ColorRect.new()
	scrim.color = MenuStyle.SCRIM
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(scrim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", MenuStyle.panel(6, 24))
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)
	panel.add_child(vbox)

	_preview = Label.new()
	_preview.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	MenuStyle.apply_heading(_preview, 28)
	vbox.add_child(_preview)

	for row_i: int in _ROWS.size():
		var row := HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.add_theme_constant_override("separation", 6)
		vbox.add_child(row)
		var chars: String = _ROWS[row_i]
		for i: int in chars.length():
			var ch: String = chars[i]
			var key := _key_button(ch)
			key.pressed.connect(_on_key.bind(ch))
			row.add_child(key)
			if _first_key == null:
				_first_key = key

	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", 12)
	vbox.add_child(actions)
	var del := _key_button("DEL", Vector2(96, 44))
	del.pressed.connect(_backspace)
	actions.add_child(del)
	var done := MenuStyle.popup_button("DONE")
	done.custom_minimum_size = Vector2(140, 44)
	done.pressed.connect(_done)
	actions.add_child(done)


func _key_button(label: String, min_size: Vector2 = Vector2(44, 44)) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.custom_minimum_size = min_size
	btn.add_theme_font_size_override("font_size", 18)
	SoundManager.wire_button(btn)
	MenuStyle.apply_focus_ring(btn)
	return btn


func open(initial: String, max_len: int) -> void:
	_text = initial
	_max_len = max_len
	_update_preview()
	visible = true
	ControllerNav.grab_focus(_first_key)


func _on_key(ch: String) -> void:
	if _text.length() < _max_len:
		_text += ch
		_update_preview()


func _backspace() -> void:
	if not _text.is_empty():
		_text = _text.substr(0, _text.length() - 1)
		_update_preview()


func _done() -> void:
	visible = false
	submitted.emit(_text)


func _update_preview() -> void:
	_preview.text = _text if not _text.is_empty() else "…"


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed(&"ui_cancel"):
		visible = false
		cancelled.emit()
		get_viewport().set_input_as_handled()
