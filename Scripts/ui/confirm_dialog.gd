class_name ConfirmDialog
extends CanvasLayer

signal confirmed
signal cancelled

var _label: Label = null


func _ready() -> void:
	layer = 22
	_build_ui()
	visible = false


func _build_ui() -> void:
	var overlay := ColorRect.new()
	overlay.color = MenuStyle.SCRIM
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", MenuStyle.panel(6, 36))
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 20)
	panel.add_child(vbox)

	var header := HBoxContainer.new()
	vbox.add_child(header)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	var close_btn := MenuStyle.close_button()
	close_btn.pressed.connect(_on_cancel)
	SoundManager.wire_button(close_btn)
	header.add_child(close_btn)

	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", 26)
	_label.add_theme_color_override("font_color", MenuStyle.TEXT_BODY)
	vbox.add_child(_label)

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 16)
	vbox.add_child(btn_row)

	var confirm_btn := MenuStyle.popup_button("Confirm")
	confirm_btn.custom_minimum_size = Vector2(140, 48)
	confirm_btn.pressed.connect(_on_confirm)
	btn_row.add_child(confirm_btn)

	var cancel_btn := MenuStyle.popup_button("Cancel")
	cancel_btn.custom_minimum_size = Vector2(140, 48)
	cancel_btn.pressed.connect(_on_cancel)
	btn_row.add_child(cancel_btn)

	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(overlay)
	root.add_child(panel)
	add_child(root)


func open(message: String) -> void:
	_label.text = message
	visible = true


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed(&"ui_cancel"):
		_on_cancel()
		get_viewport().set_input_as_handled()


func _on_confirm() -> void:
	visible = false
	confirmed.emit()


func _on_cancel() -> void:
	visible = false
	cancelled.emit()
