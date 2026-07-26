class_name BugReportDialog extends Control

# Pad text entry goes through the same on-screen keyboard PlayerSettingsPopup
# uses (Steam's own keyboard only exists in Big Picture / on Deck). The grid
# produces one flat string, so a pad report is a single paragraph — well under
# BugReporter.MAX_DESCRIPTION_CHARS, which the mouse path can still fill.
const _PAD_ENTRY_MAX_CHARS: int = 500

var _description: TextEdit
var _submit_button: Button
var _status_label: Label
var _pad_hint: Label
var _keyboard: ControllerKeyboard
var _bug_reporter := BugReporter.new()
# The menu that opened this, walled off while we're up; focus returns to it.
var _focus_background: Control = null
var _focus_restore: Control = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var overlay := ColorRect.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.color = MenuStyle.SCRIM
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
	MenuStyle.apply_heading(title, 18)
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

	# Device-aware entry hint: the pad can't type into a TextEdit, so it says how
	# to open the on-screen keyboard. Rebuilt on a device swap like every other
	# persistent prompt.
	_pad_hint = Label.new()
	_pad_hint.add_theme_color_override("font_color", MenuStyle.TEXT_MUTED)
	_pad_hint.add_theme_font_size_override("font_size", 12)
	vbox.add_child(_pad_hint)
	InputDeviceTracker.device_changed.connect(_refresh_pad_hint)
	_refresh_pad_hint(InputDeviceTracker.is_gamepad_active())

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

	_keyboard = ControllerKeyboard.new()
	_keyboard.submitted.connect(_on_keyboard_submitted)
	_keyboard.cancelled.connect(func() -> void: ControllerNav.grab_focus(_description))
	add_child(_keyboard)

	hide()


func _refresh_pad_hint(is_gamepad: bool) -> void:
	_pad_hint.visible = is_gamepad
	if is_gamepad:
		_pad_hint.text = "Press %s on the box above to type." % ControllerGlyphs.joy_label(JOY_BUTTON_A)


# `background` is the menu that opened this — walled off so the pad can't step
# out of the dialog and back onto it.
func open(background: Control = null) -> void:
	_description.text = ""
	_status_label.text = ""
	_submit_button.disabled = false
	_focus_background = background
	_focus_restore = ControllerNav.focus_owner(self)
	show()
	# Land on the description either way: it's the field a keyboard player types
	# into, and the one a pad player presses A on to raise the on-screen keyboard.
	# (grab_focus errors if the dialog was never parented, hence the tree check.)
	if _description.is_inside_tree():
		ControllerNav.open_modal(_focus_background, self, _description)
		_description.grab_focus()


# A on the focused description raises the on-screen keyboard. Handled at _input,
# ahead of the GUI, so ui_accept doesn't just insert a newline in the TextEdit.
func _input(event: InputEvent) -> void:
	if not visible or not ControllerNav.active():
		return
	if _description.has_focus() and event.is_action_pressed(&"ui_accept"):
		_keyboard.open(_description.text, _PAD_ENTRY_MAX_CHARS, self)
		get_viewport().set_input_as_handled()


func _on_keyboard_submitted(text: String) -> void:
	_description.text = text
	ControllerNav.grab_focus(_description)


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed(&"ui_cancel"):
		_close()
		get_viewport().set_input_as_handled()


func _close() -> void:
	hide()
	ControllerNav.close_modal(_focus_background, _focus_restore)


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
	_close()
