class_name LobbyBuildPopup
extends Control

# Pre-match build editor shown from the lobby. Wraps the shared
# AttributePickerPanel (sliders + presets) plus the Edit Stick workbench in a
# modal; unlike the free-play PlayerSettingsPopup it edits the build and stick
# ONLY — name/number/handedness are locked at join and the team color has its
# own lobby vote widget.
#
# On Apply it commits the working presets to PlayerPrefs and hands the active
# build to NetworkManager.update_lobby_attributes (and the tape job to
# update_lobby_tape), which stamps the values the host will spawn from (a
# client forwards them to the host for re-validation). No skater exists yet in
# the lobby, so there's no live re-apply.

var _panel: AttributePickerPanel = null
var _apply_btn: Button = null
# Stick workbench (gear + tape + preview) opened over this popup; its Done
# lands in the panel's pending gear + _pending_tape_code here.
var _stick_popup: StickEditorPopup = null
var _pending_tape_code: int = StickTapeConfig.DEFAULT_CODE
var _snapshot_tape_code: int = StickTapeConfig.DEFAULT_CODE
# Controller focus scope: the lobby content behind this popup (focus is walled
# off there while we're open) and the control focus returns to on close. Set by
# LobbyManager via set_focus_scope; null-safe if it never is.
var _focus_background: Control = null
var _focus_restore: Control = null


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

	var close_row := HBoxContainer.new()
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	close_row.add_child(spacer)
	var close_btn := MenuStyle.close_button()
	close_btn.pressed.connect(_cancel)
	SoundManager.wire_button(close_btn)
	close_row.add_child(close_btn)
	vbox.add_child(close_row)

	var title := Label.new()
	title.text = "Edit Build"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	MenuStyle.apply_heading(title)
	vbox.add_child(title)

	_panel = AttributePickerPanel.new()
	_panel.changed.connect(_update_apply_state)
	vbox.add_child(_panel)
	# Pad text entry for the preset name: the key grid walls this popup off while
	# it's up, so the D-pad can't step off the keys onto Apply/Cancel.
	_panel.set_keyboard_background(self)

	var stick_row := HBoxContainer.new()
	stick_row.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(stick_row)
	var edit_stick_btn := Button.new()
	edit_stick_btn.text = tr(&"STICK_EDIT_BUTTON")
	edit_stick_btn.custom_minimum_size = Vector2(180, 44)
	edit_stick_btn.add_theme_font_size_override("font_size", 17)
	MenuStyle.wire_hover_scale(edit_stick_btn)
	SoundManager.wire_button(edit_stick_btn)
	edit_stick_btn.pressed.connect(_open_stick_editor)
	stick_row.add_child(edit_stick_btn)

	_stick_popup = StickEditorPopup.new()
	_stick_popup.stick_edited.connect(_on_stick_edited)
	add_child(_stick_popup)

	var action_row := HBoxContainer.new()
	action_row.alignment = BoxContainer.ALIGNMENT_CENTER
	action_row.add_theme_constant_override("separation", 12)
	vbox.add_child(action_row)

	_apply_btn = Button.new()
	_apply_btn.text = "Apply"
	MenuStyle.apply_primary_cta(_apply_btn, 18)
	_apply_btn.custom_minimum_size = Vector2(140, 44)
	_apply_btn.pressed.connect(_apply)
	SoundManager.wire_button(_apply_btn)
	action_row.add_child(_apply_btn)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.custom_minimum_size = Vector2(140, 44)
	cancel_btn.add_theme_font_size_override("font_size", 18)
	cancel_btn.pressed.connect(_cancel)
	SoundManager.wire_button(cancel_btn)
	action_row.add_child(cancel_btn)


# `background` is the lobby content this popup covers; `restore` the button that
# opens it. Together they scope controller focus — see ControllerNav.open_modal.
func set_focus_scope(background: Control, restore: Control) -> void:
	_focus_background = background
	_focus_restore = restore


func open() -> void:
	# Editing is always allowed in the lobby (pre-match); the match-lock only
	# applies once play has started, which is a different scene.
	_panel.set_locked(false)
	_panel.snapshot()
	_pending_tape_code = PlayerPrefs.stick_tape_code
	_snapshot_tape_code = _pending_tape_code
	_update_apply_state()
	visible = true
	# Land on the height slider rather than the tree-first control (the close X),
	# and wall focus off from the lobby behind so the D-pad stays in the popup.
	ControllerNav.open_modal(_focus_background, self, _panel.first_focus_target())


func _open_stick_editor() -> void:
	# TEAM tape swatches resolve against the lobby's pending home kit.
	var accent: Color = TeamColorRegistry.get_colors(
			maxi(NetworkManager.pending_home_color_slot, 0), 0).primary
	_stick_popup.set_focus_scope(self, null)
	_stick_popup.open(_panel.get_pending_attributes(), _pending_tape_code, false, accent)


func _on_stick_edited(curve: int, flex: int, length: int, tape_code: int) -> void:
	_panel.set_pending_stick_gear(curve, flex, length)
	_pending_tape_code = tape_code
	_update_apply_state()


func _update_apply_state() -> void:
	if _apply_btn == null:
		return
	var dirty: bool = _panel.is_dirty() or _pending_tape_code != _snapshot_tape_code
	_apply_btn.disabled = not (dirty and _panel.is_valid())


func _apply() -> void:
	if not _panel.is_valid():
		return
	if _panel.is_dirty():
		var new_attrs: PlayerAttributes = _panel.commit()
		NetworkManager.update_lobby_attributes(new_attrs)
	if _pending_tape_code != _snapshot_tape_code:
		PlayerPrefs.stick_tape_code = _pending_tape_code
		NetworkManager.update_lobby_tape(_pending_tape_code)
	PlayerPrefs.save()
	_close()


func _cancel() -> void:
	_panel.restore()
	_pending_tape_code = _snapshot_tape_code
	_close()


func _close() -> void:
	visible = false
	ControllerNav.close_modal(_focus_background, _focus_restore)


func _on_overlay_clicked(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		_cancel()


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed(&"ui_cancel"):
		_cancel()
		get_viewport().set_input_as_handled()
