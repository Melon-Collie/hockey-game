class_name ToastStack
extends VBoxContainer

const _DARK_BG := Color(0.07, 0.07, 0.09, 0.92)
const _DIM := Color(0.62, 0.62, 0.68, 1.0)


func _init() -> void:
	anchor_left = 1.0
	anchor_right = 1.0
	offset_left = -220.0
	offset_top = 8.0
	add_theme_constant_override("separation", 4)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func push(text: String, name_color: Color) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = _DARK_BG
	style.set_corner_radius_all(3)
	style.set_content_margin(SIDE_LEFT, 12)
	style.set_content_margin(SIDE_RIGHT, 12)
	style.set_content_margin(SIDE_TOP, 6)
	style.set_content_margin(SIDE_BOTTOM, 6)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", style)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(panel)

	var parts := text.split(" ", false, 1)
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 5)
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var name_lbl := _make_label(parts[0], 14, name_color)
	hbox.add_child(name_lbl)
	if parts.size() > 1:
		var action_lbl := _make_label(parts[1], 14, _DIM)
		hbox.add_child(action_lbl)
	panel.add_child(hbox)

	_slide_in(panel)

	var tween := create_tween()
	tween.tween_interval(2.5)
	tween.tween_method(func(a: float) -> void: panel.modulate.a = a, 1.0, 0.0, 0.5)
	tween.tween_callback(panel.queue_free)


func _make_label(text: String, size: int, color: Color) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", size)
	lbl.add_theme_color_override("font_color", color)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return lbl


func _slide_in(panel: PanelContainer) -> void:
	await get_tree().process_frame
	if not is_instance_valid(panel):
		return
	panel.position.x += 240.0
	var st := create_tween()
	st.tween_property(panel, "position:x", panel.position.x - 240.0, 0.18) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
