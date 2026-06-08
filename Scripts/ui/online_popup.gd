class_name OnlinePopup
extends Control

signal host_pressed
# Emitted with the Steam lobby id of the game the player chose to join.
signal join_pressed(lobby_id: int)

var _list_box: VBoxContainer = null
var _status_label: Label = null
var _refresh_btn: Button = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	# Persistent: the autoload outlives this popup, so connect once.
	SteamManager.lobby_list_received.connect(_on_lobby_list)
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
	var close_spacer := Control.new()
	close_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	close_row.add_child(close_spacer)
	var close_btn := MenuStyle.close_button()
	close_btn.pressed.connect(func() -> void: visible = false)
	SoundManager.wire_button(close_btn)
	close_row.add_child(close_btn)
	vbox.add_child(close_row)

	var title := Label.new()
	title.text = "Online"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", MenuStyle.TEXT_TITLE)
	vbox.add_child(title)

	var host_btn := _menu_button("Host Game")
	host_btn.pressed.connect(func() -> void:
		visible = false
		host_pressed.emit())
	vbox.add_child(host_btn)

	# ── Public lobby browser ──────────────────────────────────────────────
	var browse_row := HBoxContainer.new()
	browse_row.custom_minimum_size = Vector2(308, 0)
	var browse_label := Label.new()
	browse_label.text = "Open Games"
	browse_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	browse_label.add_theme_font_size_override("font_size", 18)
	browse_label.add_theme_color_override("font_color", MenuStyle.TEXT_TITLE)
	browse_row.add_child(browse_label)
	_refresh_btn = Button.new()
	_refresh_btn.text = "Refresh"
	_refresh_btn.add_theme_font_size_override("font_size", 16)
	_refresh_btn.pressed.connect(_refresh_lobbies)
	MenuStyle.wire_hover_scale(_refresh_btn)
	SoundManager.wire_button(_refresh_btn)
	browse_row.add_child(_refresh_btn)
	vbox.add_child(browse_row)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(308, 220)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)

	_list_box = VBoxContainer.new()
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_box.add_theme_constant_override("separation", 6)
	scroll.add_child(_list_box)

	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_font_size_override("font_size", 16)
	_status_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65, 1.0))
	vbox.add_child(_status_label)


func _menu_button(label: String) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.custom_minimum_size = Vector2(308, 48)
	btn.add_theme_font_size_override("font_size", 20)
	MenuStyle.wire_hover_scale(btn)
	SoundManager.wire_button(btn)
	return btn


func _refresh_lobbies() -> void:
	if not SteamManager.is_available:
		_set_status("Steam isn't running.")
		return
	_clear_list()
	_set_status("Searching for games…")
	SteamManager.request_lobby_list()


func _on_lobby_list(lobbies: Array) -> void:
	if not visible:
		return
	_clear_list()
	if lobbies.is_empty():
		_set_status("No open games found.")
		return
	_set_status("")
	for lobby: Dictionary in lobbies:
		_list_box.add_child(_lobby_row(lobby))


func _lobby_row(lobby: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, 40)
	var name_label := Label.new()
	var lobby_name: String = lobby.get("name", "")
	if lobby_name.is_empty():
		lobby_name = "Game"
	name_label.text = "%s  (%d/%d)" % [lobby_name, int(lobby.get("members", 0)), int(lobby.get("max", 0))]
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.add_theme_font_size_override("font_size", 16)
	row.add_child(name_label)
	var join_btn := Button.new()
	join_btn.text = "Join"
	join_btn.add_theme_font_size_override("font_size", 16)
	var lobby_id: int = int(lobby.get("lobby_id", 0))
	join_btn.pressed.connect(func() -> void:
		visible = false
		join_pressed.emit(lobby_id))
	MenuStyle.wire_hover_scale(join_btn)
	SoundManager.wire_button(join_btn)
	row.add_child(join_btn)
	return row


func _clear_list() -> void:
	for child in _list_box.get_children():
		child.queue_free()


func _set_status(text: String) -> void:
	_status_label.text = text
	_status_label.visible = not text.is_empty()


func _on_overlay_clicked(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		visible = false


func open() -> void:
	visible = true
	if SteamManager.is_available:
		_refresh_lobbies()
	else:
		_clear_list()
		_set_status("Steam isn't running.\nStart Steam and relaunch to play online.")


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed(&"ui_cancel"):
		visible = false
		get_viewport().set_input_as_handled()
