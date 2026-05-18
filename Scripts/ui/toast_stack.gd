class_name ToastStack
extends VBoxContainer


func _init() -> void:
	anchor_left = 1.0
	anchor_right = 1.0
	offset_left = -240.0
	offset_top = 8.0
	add_theme_constant_override("separation", 6)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func push(text: String, name_color: Color) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = MenuStyle.BROADCAST_BG
	style.set_corner_radius_all(4)
	style.border_color = MenuStyle.BROADCAST_BORDER_T
	style.border_width_top = 1
	style.anti_aliasing = false
	style.set_content_margin(SIDE_LEFT, 12)
	style.set_content_margin(SIDE_RIGHT, 12)
	style.set_content_margin(SIDE_TOP, 6)
	style.set_content_margin(SIDE_BOTTOM, 6)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", style)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var parts := text.split(" ", false, 1)
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 5)
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var name_lbl := _make_label(parts[0], 16, name_color)
	hbox.add_child(name_lbl)
	if parts.size() > 1:
		var action_lbl := _make_label(parts[1], 16, MenuStyle.BROADCAST_DIM)
		hbox.add_child(action_lbl)
	panel.add_child(hbox)

	var wrapper := MenuStyle.wrap_drop_shadow(panel, Vector2(3, 3))
	add_child(wrapper)

	_slide_in(wrapper)

	var tween := create_tween()
	tween.tween_interval(2.5)
	tween.tween_method(func(a: float) -> void: wrapper.modulate.a = a, 1.0, 0.0, 0.5)
	tween.tween_callback(wrapper.queue_free)


func _make_label(text: String, font_size: int, color: Color) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_override("font", MenuStyle.DISPLAY_FONT)
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", color)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return lbl


func _slide_in(node: Control) -> void:
	await get_tree().process_frame
	if not is_instance_valid(node):
		return
	node.position.x += 240.0
	var st := create_tween()
	st.tween_property(node, "position:x", node.position.x - 240.0, 0.18) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
