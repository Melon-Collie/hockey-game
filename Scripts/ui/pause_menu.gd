class_name PauseMenu
extends CanvasLayer

signal opened
signal closed

var _slot_grid_container: Control = null
var _options_container: Control = null
var _leave_container: Control = null
var _slot_grid: SlotGridPanel = null
var _change_position_btn: Button = null
var _spectate_btn: Button = null
var _confirm: ConfirmDialog = null
var _confirm_callback: Callable = Callable()
# Latches once a leave/exit teardown starts: the confirm dialog closes before the
# 0.5s announce_match_end() await completes, leaving the leave menu interactive, so
# a second click would start an overlapping teardown (double scene change). One-way.
var _leaving: bool = false


func _ready() -> void:
	layer = 20
	_build_menu()
	_build_slot_grid_overlay()
	_build_options_overlay()
	_build_leave_overlay()
	_confirm = ConfirmDialog.new()
	_confirm.confirmed.connect(_on_confirm_confirmed)
	_confirm.cancelled.connect(_on_confirm_cancelled)
	add_child(_confirm)
	GameManager.stats_updated.connect(_on_stats_updated)
	visible = false


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if not event.is_action_pressed(&"ui_cancel"):
		return
	if _confirm.visible:
		return
	if _options_container.visible:
		_options_container.visible = false
	elif _slot_grid_container.visible:
		_slot_grid_container.visible = false
	elif _leave_container.visible:
		_leave_container.visible = false
	else:
		close()
	get_viewport().set_input_as_handled()


func open() -> void:
	if visible:
		return
	visible = true
	opened.emit()


func close() -> void:
	if not visible:
		return
	_slot_grid_container.visible = false
	_options_container.visible = false
	_leave_container.visible = false
	visible = false
	closed.emit()


func toggle() -> void:
	if visible:
		close()
	else:
		open()


func apply_spectator_chrome(is_spec: bool) -> void:
	if _spectate_btn != null:
		_spectate_btn.visible = not is_spec
	if _change_position_btn != null:
		_change_position_btn.disabled = false


# ── Build helpers ────────────────────────────────────────────────────────────

func _build_menu() -> void:
	var overlay := ColorRect.new()
	overlay.color = MenuStyle.SCRIM
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", MenuStyle.panel())
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 16)
	panel.add_child(vbox)

	var resume_btn := MenuStyle.popup_button("Resume")
	MenuStyle.apply_primary_cta(resume_btn)
	resume_btn.pressed.connect(close)
	vbox.add_child(resume_btn)

	_add_host_button(vbox, "Rematch", func() -> void:
		close()
		GameManager.reset_game())

	_change_position_btn = MenuStyle.popup_button("Change Position")
	_change_position_btn.pressed.connect(_on_change_position_pressed)
	vbox.add_child(_change_position_btn)

	_spectate_btn = MenuStyle.popup_button("Spectate")
	_spectate_btn.pressed.connect(_on_spectate_pressed)
	vbox.add_child(_spectate_btn)

	var options_btn := MenuStyle.popup_button("Options")
	options_btn.pressed.connect(func() -> void: _options_container.visible = true)
	vbox.add_child(options_btn)

	var leave_btn := MenuStyle.popup_button("Leave Game")
	leave_btn.pressed.connect(func() -> void: _leave_container.visible = true)
	vbox.add_child(leave_btn)

	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(overlay)
	root.add_child(panel)
	add_child(root)


func _build_slot_grid_overlay() -> void:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", MenuStyle.panel())
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	panel.custom_minimum_size = Vector2(960, 0)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 16)
	panel.add_child(vbox)

	var close_row := HBoxContainer.new()
	var close_spacer := Control.new()
	close_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	close_row.add_child(close_spacer)
	var close_btn := MenuStyle.close_button()
	close_btn.pressed.connect(func() -> void: _slot_grid_container.visible = false)
	SoundManager.wire_button(close_btn)
	close_row.add_child(close_btn)
	vbox.add_child(close_row)

	var title := Label.new()
	title.text = "Change Position"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	MenuStyle.apply_heading(title, 26)
	vbox.add_child(title)

	_slot_grid = SlotGridPanel.new()
	_slot_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slot_grid.slot_selected.connect(_on_slot_selected)
	_slot_grid.kick_requested.connect(_on_kick_requested)
	vbox.add_child(_slot_grid)

	_slot_grid_container = Control.new()
	_slot_grid_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_slot_grid_container.add_child(panel)
	_slot_grid_container.visible = false

	var canvas_layer := CanvasLayer.new()
	canvas_layer.layer = 21
	canvas_layer.add_child(_slot_grid_container)
	add_child(canvas_layer)


func _build_options_overlay() -> void:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", MenuStyle.panel())
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH

	var options := OptionsPanel.new()
	options.close_requested.connect(func() -> void: _options_container.visible = false)
	panel.add_child(options)

	_options_container = Control.new()
	_options_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_options_container.add_child(panel)
	_options_container.visible = false

	var canvas_layer := CanvasLayer.new()
	canvas_layer.layer = 21
	canvas_layer.add_child(_options_container)
	add_child(canvas_layer)


func _build_leave_overlay() -> void:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", MenuStyle.panel())
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 16)
	panel.add_child(vbox)

	var close_row := HBoxContainer.new()
	var close_spacer := Control.new()
	close_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	close_row.add_child(close_spacer)
	var close_btn := MenuStyle.close_button()
	close_btn.pressed.connect(func() -> void: _leave_container.visible = false)
	SoundManager.wire_button(close_btn)
	close_row.add_child(close_btn)
	vbox.add_child(close_row)

	var title := Label.new()
	title.text = "Leave Game"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	MenuStyle.apply_heading(title)
	vbox.add_child(title)

	# "Return to Lobby" only exists for an online host — it pulls the whole
	# group back to the shared lobby. Offline has no lobby, and clients can't
	# drive everyone's scene, so neither sees this button. (Mirrors the
	# game-over popup's leave buttons.)
	if NetworkManager.is_host and not NetworkManager.is_offline_mode:
		_add_host_button(vbox, "Return to Lobby", func() -> void: GameManager.return_to_lobby())

	# Always available: drop to solo free play. Offline this is the only leave
	# action; for an online client it disconnects just them; for an online host
	# it tears down the server (everyone drops out), so the confirm says so.
	var free_play_btn := MenuStyle.popup_button("Return to Free Play")
	free_play_btn.pressed.connect(func() -> void:
		var msg: String = "Return to free play?"
		if NetworkManager.is_host and not NetworkManager.is_offline_mode:
			msg = "Return to free play? This ends the match for everyone."
		_show_confirm(msg, func() -> void:
			if _leaving:
				return
			_leaving = true
			await NetworkManager.announce_match_end()
			GameManager.return_to_free_play()))
	vbox.add_child(free_play_btn)

	var exit_btn := MenuStyle.popup_button("Exit Game")
	exit_btn.pressed.connect(func() -> void:
		_show_confirm("Exit game?", func() -> void:
			if _leaving:
				return
			_leaving = true
			await NetworkManager.announce_match_end()
			GameManager.on_scene_exit()
			NetworkManager.reset()
			get_tree().quit()))
	vbox.add_child(exit_btn)

	_leave_container = Control.new()
	_leave_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_leave_container.add_child(panel)
	_leave_container.visible = false

	var canvas_layer := CanvasLayer.new()
	canvas_layer.layer = 21
	canvas_layer.add_child(_leave_container)
	add_child(canvas_layer)


func _add_host_button(vbox: VBoxContainer, text: String, handler: Callable) -> void:
	if not NetworkManager.is_host:
		return
	var b := MenuStyle.popup_button(text)
	b.pressed.connect(handler)
	vbox.add_child(b)


# ── Action handlers ──────────────────────────────────────────────────────────

func _on_change_position_pressed() -> void:
	_slot_grid_container.visible = not _slot_grid_container.visible
	if _slot_grid_container.visible:
		_refresh_slot_grid()


func _on_spectate_pressed() -> void:
	# Spectator slot index is irrelevant mid-game — host's demote helper picks
	# one. Slot 0 is just a placeholder.
	NetworkManager.send_request_slot_swap(GameRules.SPECTATOR_TEAM_ID, 0)
	close()


func _on_slot_selected(team_id: int, slot: int) -> void:
	NetworkManager.send_request_slot_swap(team_id, slot)
	close()


func _on_kick_requested(peer_id: int, player_name: String) -> void:
	_show_confirm("Kick %s from the game?" % player_name, func() -> void:
		NetworkManager.kick_peer(peer_id, "You were kicked by the host."))


func _on_stats_updated() -> void:
	if visible and _slot_grid != null:
		_refresh_slot_grid()


func _refresh_slot_grid() -> void:
	# No bot add/remove mid-match, but the host keeps the kick X on connected
	# peers' cards.
	_slot_grid.refresh(GameManager.get_slot_roster(), _get_team_colors(), {},
			NetworkManager.is_host, {}, false)


func _get_team_colors() -> Array[Dictionary]:
	if GameManager.teams.size() < 2:
		return []
	return [
		TeamColorRegistry.get_colors(GameManager.teams[0].color_slot, 0),
		TeamColorRegistry.get_colors(GameManager.teams[1].color_slot, 1),
	]


func _show_confirm(message: String, callback: Callable) -> void:
	_confirm_callback = callback
	_confirm.open(message)


func _on_confirm_confirmed() -> void:
	var cb := _confirm_callback
	_confirm_callback = Callable()
	if cb.is_valid():
		cb.call()


func _on_confirm_cancelled() -> void:
	_confirm_callback = Callable()
