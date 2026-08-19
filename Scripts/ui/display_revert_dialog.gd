class_name DisplayRevertDialog
extends CanvasLayer

# Post-apply safety net for display changes. After a window mode / resolution /
# monitor switch, this asks "Keep these display settings?" with a live countdown
# and auto-reverts when it hits zero — so a pick that blanks or mis-sizes the
# screen recovers on its own without the player needing to see the buttons. The
# revert action is supplied by the caller (OptionsPanel) as a Callable; this
# dialog only owns the countdown and the choice. Frees itself on resolution.


const _REVERT_DEFAULT_SECONDS: float = 15.0

var _label: Label = null
var _keep_btn: Button = null
var _remaining: float = 0.0
var _on_revert: Callable = Callable()
# Controller focus scope: the Options panel underneath (walled off while we're
# up) and the control focus returns to once we resolve.
var _focus_background: Control = null
var _focus_restore: Control = null


func _ready() -> void:
	layer = 23  # above ConfirmDialog (22) and the Options overlay
	_build_ui()
	visible = false
	set_process(false)


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

	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", 24)
	_label.add_theme_color_override("font_color", MenuStyle.TEXT_BODY)
	vbox.add_child(_label)

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 16)
	vbox.add_child(btn_row)

	var keep_btn := MenuStyle.popup_button("Keep")
	keep_btn.custom_minimum_size = Vector2(150, 48)
	keep_btn.pressed.connect(_on_keep)
	SoundManager.wire_button(keep_btn)
	btn_row.add_child(keep_btn)
	_keep_btn = keep_btn  # controller default focus — B/Escape/timeout still revert

	var revert_btn := MenuStyle.popup_button("Revert Now")
	revert_btn.custom_minimum_size = Vector2(150, 48)
	revert_btn.pressed.connect(_do_revert)
	SoundManager.wire_button(revert_btn)
	btn_row.add_child(revert_btn)

	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(overlay)
	root.add_child(panel)
	add_child(root)


# `background` is the Options panel this covers; pass it so the pad lands on Keep
# and can't step back onto the options behind — a display change the player can
# only confirm with the mouse is a trap on a controller (the timeout would revert
# a setting they actually wanted).
func open(seconds: float, on_revert: Callable, background: Control = null) -> void:
	_remaining = seconds if seconds > 0.0 else _REVERT_DEFAULT_SECONDS
	_on_revert = on_revert
	_focus_background = background
	_focus_restore = ControllerNav.focus_owner(self)
	_update_label()
	visible = true
	set_process(true)
	ControllerNav.open_modal(_focus_background, self, _keep_btn)


func _process(delta: float) -> void:
	_remaining -= delta
	if _remaining <= 0.0:
		_do_revert()
		return
	_update_label()


func _update_label() -> void:
	_label.text = "Keep these display settings?\nReverting in %d…" % ceili(_remaining)


# Escape reverts — the safe default, matching the auto-timeout, since a player
# who can't read the dialog can still mash it to recover.
func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed(&"ui_cancel"):
		_do_revert()
		get_viewport().set_input_as_handled()


func _on_keep() -> void:
	_close()
	queue_free()


func _do_revert() -> void:
	_close()
	if _on_revert.is_valid():
		_on_revert.call()
	queue_free()


func _close() -> void:
	set_process(false)
	visible = false
	ControllerNav.close_modal(_focus_background, _focus_restore)
