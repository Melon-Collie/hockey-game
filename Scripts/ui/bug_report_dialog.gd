class_name BugReportDialog extends Control

var _description: TextEdit
var _submit_button: Button
var _status_label: Label
var _bug_reporter := BugReporter.new()


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var overlay := ColorRect.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.color = Color(0.0, 0.0, 0.0, 0.6)
	add_child(overlay)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(480.0, 0.0)
	panel.add_theme_stylebox_override("panel", MenuStyle.panel(8, 28))
	add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	panel.add_child(vbox)

	var header := HBoxContainer.new()
	vbox.add_child(header)

	var title := Label.new()
	title.text = "Report a Bug"
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", MenuStyle.TEXT_TITLE)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)

	var close_btn: Button = MenuStyle.close_button()
	close_btn.pressed.connect(_on_cancel_pressed)
	header.add_child(close_btn)

	var sep := HSeparator.new()
	sep.add_theme_color_override("color", MenuStyle.TEXT_SEP)
	vbox.add_child(sep)

	var desc_label := Label.new()
	desc_label.text = "Describe the bug:"
	desc_label.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	vbox.add_child(desc_label)

	_description = TextEdit.new()
	_description.custom_minimum_size = Vector2(0.0, 120.0)
	_description.placeholder_text = "What happened? What did you expect?"
	_description.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	vbox.add_child(_description)

	_status_label = Label.new()
	_status_label.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	_status_label.add_theme_font_size_override("font_size", 12)
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_status_label)

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	btn_row.add_theme_constant_override("separation", 8)
	vbox.add_child(btn_row)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.pressed.connect(_on_cancel_pressed)
	btn_row.add_child(cancel_btn)

	_submit_button = Button.new()
	_submit_button.text = "Submit"
	_submit_button.pressed.connect(_on_submit_pressed)
	btn_row.add_child(_submit_button)

	# Connect once — the BugReporter instance is reused across dialog opens.
	# CONNECT_DEFERRED isn't needed since the request_completed lambda already
	# runs on the main thread.
	_bug_reporter.submit_completed.connect(_on_submit_completed)

	hide()


func open() -> void:
	_description.text = ""
	_status_label.text = ""
	_submit_button.disabled = false
	show()
	_description.grab_focus()


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed(&"ui_cancel"):
		hide()
		get_viewport().set_input_as_handled()


func _on_submit_pressed() -> void:
	if _submit_button.disabled:
		return  # already submitting; defense in depth against double-press
	var text: String = _description.text.strip_edges()
	if text.is_empty():
		return
	_submit_button.disabled = true
	_status_label.text = "Submitting..."
	_bug_reporter.submit(text, NetworkTelemetry.instance)


func _on_submit_completed(result: BugReporter.Result, _http_code: int) -> void:
	# is_inside_tree guard: dialog could have been freed (scene change) between
	# request_completed firing and this handler running. The HTTPRequest is
	# parented to the scene root so it survives across scene changes; the
	# dialog usually doesn't.
	if not is_inside_tree():
		return
	match result:
		BugReporter.Result.SUCCESS:
			_status_label.text = "Submitted — thank you!"
			await get_tree().create_timer(1.5).timeout
			if is_inside_tree():
				hide()
		BugReporter.Result.RATE_LIMITED:
			_status_label.text = "Please wait a minute before submitting again."
			_submit_button.disabled = false
		BugReporter.Result.FAILED:
			_status_label.text = "Submission failed. Please try again later."
			_submit_button.disabled = false


func _on_cancel_pressed() -> void:
	hide()
