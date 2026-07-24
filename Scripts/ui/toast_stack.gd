class_name ToastStack
extends VBoxContainer

# Transient event ticker, top-right under the diagnostics row (FPS + network
# health dot live above at y≈8, so the stack starts below them).

const _TOAST_WIDTH: float = 240.0
# Bound the stack so an event burst (stat feed + clock warning + join) can't
# crawl down the screen; oldest toasts drop first.
const _MAX_TOASTS: int = 5


func _init() -> void:
	anchor_left = 1.0
	anchor_right = 1.0
	offset_left = -_TOAST_WIDTH
	offset_top = 32.0
	add_theme_constant_override("separation", 6)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


# Single-part toast: the whole text in `color`.
func push(text: String, color: Color) -> void:
	_push_labels([_make_label(text, 16, color, MenuStyle.UI_FONT)])


# Two-part toast: `subject` (e.g. a player name — may contain spaces) in
# `subject_color`, `detail` dimmed after it.
func push_pair(subject: String, detail: String, subject_color: Color) -> void:
	_push_labels([
		_make_label(subject, 16, subject_color, MenuStyle.DISPLAY_FONT),
		_make_label(detail, 16, MenuStyle.BROADCAST_DIM, MenuStyle.UI_FONT),
	])


func _push_labels(labels: Array[Label]) -> void:
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

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 5)
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for lbl: Label in labels:
		hbox.add_child(lbl)
	panel.add_child(hbox)

	var wrapper := MenuStyle.wrap_drop_shadow(panel, Vector2(3, 3))
	while get_child_count() >= _MAX_TOASTS:
		var oldest: Node = get_child(0)
		remove_child(oldest)
		oldest.queue_free()
	add_child(wrapper)

	_slide_in(wrapper)

	# Bound to the wrapper (not the stack) so early eviction by _MAX_TOASTS
	# kills the fade tween instead of leaving it poking a freed node.
	var tween := wrapper.create_tween()
	tween.tween_interval(2.5)
	tween.tween_method(func(a: float) -> void: wrapper.modulate.a = a, 1.0, 0.0, 0.5)
	tween.tween_callback(wrapper.queue_free)


func _make_label(text: String, font_size: int, color: Color, font: Font) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_override("font", font)
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", color)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return lbl


func _slide_in(node: Control) -> void:
	await get_tree().process_frame
	if not is_instance_valid(node):
		return
	node.position.x += _TOAST_WIDTH
	var st := node.create_tween()
	st.tween_property(node, "position:x", node.position.x - _TOAST_WIDTH, 0.18) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
