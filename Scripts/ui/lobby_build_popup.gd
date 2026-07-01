class_name LobbyBuildPopup
extends Control

# Pre-match build editor shown from the lobby. Wraps the shared
# AttributePickerPanel (sliders + presets) in a modal; unlike the free-play
# PlayerSettingsPopup it edits attributes ONLY — name/number/handedness are
# locked at join and the team color has its own lobby vote widget.
#
# On Apply it commits the working presets to PlayerPrefs and hands the active
# build to NetworkManager.update_lobby_attributes, which stamps the value the
# host will spawn from (a client forwards it to the host for re-validation). No
# skater exists yet in the lobby, so there's no live re-apply.

signal build_committed(attrs: PlayerAttributes)

var _panel: AttributePickerPanel = null
var _apply_btn: Button = null


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
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", MenuStyle.TEXT_TITLE)
	vbox.add_child(title)

	_panel = AttributePickerPanel.new()
	_panel.changed.connect(_update_apply_state)
	vbox.add_child(_panel)

	var action_row := HBoxContainer.new()
	action_row.alignment = BoxContainer.ALIGNMENT_CENTER
	action_row.add_theme_constant_override("separation", 12)
	vbox.add_child(action_row)

	_apply_btn = Button.new()
	_apply_btn.text = "Apply"
	_apply_btn.theme_type_variation = &"ButtonPrimary"
	_apply_btn.custom_minimum_size = Vector2(140, 44)
	_apply_btn.add_theme_font_size_override("font_size", 18)
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


func open() -> void:
	# Editing is always allowed in the lobby (pre-match); the match-lock only
	# applies once play has started, which is a different scene.
	_panel.set_locked(false)
	_panel.snapshot()
	_update_apply_state()
	visible = true


func _update_apply_state() -> void:
	if _apply_btn == null:
		return
	_apply_btn.disabled = not (_panel.is_dirty() and _panel.is_valid())


func _apply() -> void:
	if not _panel.is_dirty() or not _panel.is_valid():
		return
	var new_attrs: PlayerAttributes = _panel.commit()
	PlayerPrefs.save()
	NetworkManager.update_lobby_attributes(new_attrs)
	build_committed.emit(new_attrs)
	visible = false


func _cancel() -> void:
	_panel.restore()
	visible = false


func _on_overlay_clicked(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		_cancel()


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed(&"ui_cancel"):
		_cancel()
		get_viewport().set_input_as_handled()
