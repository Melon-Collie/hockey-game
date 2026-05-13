class_name MainMenu
extends Control

var _error_label: Label = null
var _player_popup: PlayerSettingsPopup = null
var _center_container: CenterContainer = null
var _title_logo: TextureRect = null
var _version_label: Label = null
var _player_card_panel: PanelContainer = null
var _options_popup: Control = null
var _offline_popup: OfflineModePopup = null
var _team_color_popup: TeamColorPopup = null
var _online_popup: OnlinePopup = null
var _offline_home_color_id: String = TeamColorRegistry.DEFAULT_HOME_ID
var _offline_away_color_id: String  = TeamColorRegistry.DEFAULT_AWAY_ID
var _career_screen: CareerStatsScreen = null
var _loading_screen: LoadingScreen = null
var _exit_popup: Control = null
var _card_name_label: Label = null
var _card_number_label: Label = null
var _card_hand_label: Label = null

func _ready() -> void:
	TeamColorRegistry.ensure_loaded()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	if not NetworkManager.pending_error.is_empty():
		_error_label.text = NetworkManager.pending_error
		_error_label.visible = true
		NetworkManager.pending_error = ""

func _build_ui() -> void:
	var bg := TextureRect.new()
	bg.texture = load("res://Assets/Mitts_ice_background.png")
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# ── Center stack ──────────────────────────────────────────────────────────
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	_center_container = center
	_center_container.modulate.a = 0.0

	var menu_panel_style := MenuStyle.panel(8, 40)
	menu_panel_style.set_content_margin(SIDE_TOP, 36)
	menu_panel_style.set_content_margin(SIDE_BOTTOM, 36)

	var menu_panel := PanelContainer.new()
	menu_panel.add_theme_stylebox_override("panel", menu_panel_style)
	menu_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(menu_panel)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 12)
	menu_panel.add_child(vbox)

	# Logo is rendered as two stacked TextureRects in the same vbox slot: a
	# behind-rect that runs the ui_glow shader (soft teal halo), and the real
	# logo on top. Both share a fixed slot via a Control wrapper so the glow
	# doesn't push the menu layout around. The slot is sized larger than the
	# visible logo to give the glow room to fall off — the padded PNG variant
	# carries ~10% transparent margin so the blur fades naturally instead of
	# clipping at the texture edge.
	var logo_slot := Control.new()
	logo_slot.custom_minimum_size = Vector2(650, 280)
	vbox.add_child(logo_slot)

	var logo_tex: Texture2D = load("res://Assets/logos/Mitts_logo_full_padded.png")

	var glow := TextureRect.new()
	glow.texture = logo_tex
	glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glow.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var glow_mat := ShaderMaterial.new()
	glow_mat.shader = load("res://Assets/Shaders/ui_glow.gdshader")
	glow.material = glow_mat
	logo_slot.add_child(glow)

	var logo := TextureRect.new()
	logo.texture = logo_tex
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	logo.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	logo_slot.add_child(logo)
	_title_logo = logo
	_title_logo.item_rect_changed.connect(func() -> void:
		_title_logo.pivot_offset = _title_logo.size / 2.0)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 8)
	vbox.add_child(spacer)

	# Primary CTA — online multiplayer is the headline pitch of the project,
	# so it gets the solid-teal button. Everything else is ghost-style.
	var online_btn := _make_primary_button("Play Online")
	online_btn.pressed.connect(func() -> void: _online_popup.open())
	vbox.add_child(online_btn)

	var offline_btn := _make_button("Offline")
	offline_btn.pressed.connect(_on_offline_pressed)
	vbox.add_child(offline_btn)

	var career_btn := _make_button("Career")
	career_btn.pressed.connect(func() -> void: _career_screen.open())
	vbox.add_child(career_btn)

	var options_btn := _make_button("Options")
	options_btn.pressed.connect(_on_options_pressed)
	vbox.add_child(options_btn)

	# Divider before Exit Game — visually separates "menu options" from
	# "leave the app." Exit Game itself is a quiet text-only link.
	var exit_divider := Control.new()
	exit_divider.custom_minimum_size = Vector2(0, 8)
	vbox.add_child(exit_divider)

	var exit_btn := _make_tertiary_button("Exit Game")
	exit_btn.pressed.connect(func() -> void: _exit_popup.visible = true)
	vbox.add_child(exit_btn)

	_error_label = Label.new()
	_error_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_error_label.add_theme_font_size_override("font_size", 16)
	_error_label.add_theme_color_override("font_color", Color(1.0, 0.45, 0.45, 1.0))
	_error_label.visible = false
	vbox.add_child(_error_label)

	var update_checker: UpdateChecker = UpdateChecker.new()
	update_checker.custom_minimum_size = Vector2(380, 0)
	vbox.add_child(update_checker)

	# ── Version label — bottom-right corner ───────────────────────────────────
	_version_label = Label.new()
	_version_label.text = "v%s" % BuildInfo.VERSION
	_version_label.add_theme_font_size_override("font_size", 14)
	_version_label.add_theme_color_override("font_color", Color(0.55, 0.55, 0.60, 1.0))
	_version_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_version_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_version_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_version_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_version_label.offset_right = -16
	_version_label.offset_bottom = -12
	_version_label.modulate.a = 0.0
	add_child(_version_label)

	_career_screen = CareerStatsScreen.new()
	add_child(_career_screen)
	_player_popup = PlayerSettingsPopup.new()
	_player_popup.name_changed.connect(_on_player_name_changed)
	_player_popup.jersey_number_changed.connect(_on_player_number_changed)
	_player_popup.handedness_changed.connect(_on_player_handedness_changed)
	add_child(_player_popup)
	_build_options_popup()
	_build_exit_popup()
	_offline_popup = OfflineModePopup.new()
	_offline_popup.tutorial_pressed.connect(_do_start_tutorial)
	_offline_popup.free_play_pressed.connect(_on_free_play_pressed)
	_offline_popup.with_bots_pressed.connect(_on_with_bots_pressed)
	add_child(_offline_popup)
	_team_color_popup = TeamColorPopup.new()
	_team_color_popup.play_pressed.connect(_on_team_colors_chosen)
	_team_color_popup.back_pressed.connect(_on_team_color_back_pressed)
	add_child(_team_color_popup)
	_online_popup = OnlinePopup.new()
	_online_popup.host_pressed.connect(_on_host_pressed)
	_online_popup.join_pressed.connect(_on_join_pressed)
	add_child(_online_popup)
	_build_player_card()
	_loading_screen = LoadingScreen.new()
	_loading_screen.cancel_pressed.connect(_on_join_cancelled)
	add_child(_loading_screen)

	var intro := MenuIntro.new()
	intro.intro_finished.connect(_on_intro_finished)
	add_child(intro)

func _build_player_card() -> void:
	# Resting state — solid panel-bg with a visible teal-line border so the
	# card looks interactive at rest, not just a static info chip.
	var normal_style := StyleBoxFlat.new()
	normal_style.bg_color = MenuStyle.PANEL_BG
	normal_style.set_corner_radius_all(6)
	normal_style.set_content_margin_all(14)
	normal_style.border_color = MenuStyle.TEAL_DIM
	normal_style.set_border_width_all(1)

	# Hover state — surface lifts to SURFACE_ELEV with a brighter teal border.
	var hover_style := StyleBoxFlat.new()
	hover_style.bg_color = MenuStyle.SURFACE_ELEV
	hover_style.set_corner_radius_all(6)
	hover_style.set_content_margin_all(14)
	hover_style.border_color = MenuStyle.TEAL
	hover_style.set_border_width_all(1)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", normal_style)
	panel.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	panel.mouse_filter = Control.MOUSE_FILTER_STOP

	# Two-column layout: identity vbox on the left (name + meta), "Edit"
	# affordance text on the right. HBox keeps the icon anchored to the right
	# edge regardless of how long the name is.
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 18)
	panel.add_child(hbox)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 5)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(vbox)

	_card_name_label = Label.new()
	_card_name_label.text = PlayerPrefs.player_name
	_card_name_label.add_theme_font_size_override("font_size", 20)
	_card_name_label.add_theme_color_override("font_color", MenuStyle.TEXT_TITLE)
	vbox.add_child(_card_name_label)

	var detail_row := HBoxContainer.new()
	detail_row.add_theme_constant_override("separation", 10)
	vbox.add_child(detail_row)

	_card_number_label = Label.new()
	_card_number_label.text = "#%d" % PlayerPrefs.jersey_number
	_card_number_label.add_theme_font_size_override("font_size", 15)
	_card_number_label.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	detail_row.add_child(_card_number_label)

	_card_hand_label = Label.new()
	_card_hand_label.text = "Shoots %s" % ("L" if PlayerPrefs.is_left_handed else "R")
	_card_hand_label.add_theme_font_size_override("font_size", 15)
	_card_hand_label.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	detail_row.add_child(_card_hand_label)

	# Material edit-pencil icon (Assets/Icons/edit.svg). Tinted via modulate
	# so we can switch color on hover the same way as the panel border.
	var edit_icon := TextureRect.new()
	edit_icon.texture = load("res://Assets/Icons/edit.svg") as Texture2D
	edit_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	edit_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	edit_icon.custom_minimum_size = Vector2(16, 16)
	edit_icon.modulate = MenuStyle.TEXT_MUTED
	edit_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	edit_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hbox.add_child(edit_icon)

	panel.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_player_popup.open())
	panel.mouse_entered.connect(func() -> void:
		panel.add_theme_stylebox_override("panel", hover_style)
		edit_icon.modulate = MenuStyle.TEAL_HOVER)
	panel.mouse_exited.connect(func() -> void:
		panel.add_theme_stylebox_override("panel", normal_style)
		edit_icon.modulate = MenuStyle.TEXT_MUTED)

	panel.position = Vector2(16.0, 16.0)
	panel.modulate.a = 0.0
	_player_card_panel = panel
	add_child(panel)

func _build_options_popup() -> void:
	var overlay := ColorRect.new()
	overlay.color = MenuStyle.SCRIM
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed:
			_options_popup.visible = false)

	var panel_style := MenuStyle.panel()

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", panel_style)
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH

	var options := OptionsPanel.new()
	options.close_requested.connect(func() -> void: _options_popup.visible = false)
	panel.add_child(options)

	_options_popup = Control.new()
	_options_popup.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_options_popup.visible = false
	_options_popup.add_child(overlay)
	_options_popup.add_child(panel)
	add_child(_options_popup)

func _build_exit_popup() -> void:
	var overlay := ColorRect.new()
	overlay.color = MenuStyle.SCRIM
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP

	var panel_style := MenuStyle.panel(6, 36)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", panel_style)
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 20)
	panel.add_child(vbox)

	var exit_close_row := HBoxContainer.new()
	var exit_close_spacer := Control.new()
	exit_close_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	exit_close_row.add_child(exit_close_spacer)
	var exit_close_btn := MenuStyle.close_button()
	exit_close_btn.pressed.connect(func() -> void: _exit_popup.visible = false)
	SoundManager.wire_button(exit_close_btn)
	exit_close_row.add_child(exit_close_btn)
	vbox.add_child(exit_close_row)
	var label := Label.new()
	label.text = "Exit game?"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 26)
	label.add_theme_color_override("font_color", MenuStyle.TEXT_TITLE)
	vbox.add_child(label)

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_row.add_theme_constant_override("separation", 16)
	vbox.add_child(btn_row)

	var confirm_btn := _make_button("Exit")
	confirm_btn.custom_minimum_size = Vector2(140, 48)
	confirm_btn.pressed.connect(func() -> void: get_tree().quit())
	btn_row.add_child(confirm_btn)

	var cancel_btn := _make_button("Cancel")
	cancel_btn.custom_minimum_size = Vector2(140, 48)
	cancel_btn.pressed.connect(func() -> void: _exit_popup.visible = false)
	btn_row.add_child(cancel_btn)

	_exit_popup = Control.new()
	_exit_popup.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_exit_popup.visible = false
	_exit_popup.add_child(overlay)
	_exit_popup.add_child(panel)
	add_child(_exit_popup)

func _on_join_cancelled() -> void:
	_disconnect_join_signals()
	NetworkManager.reset()
	_loading_screen.visible = false

func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed(&"ui_cancel"):
		return
	if _loading_screen != null and _loading_screen.visible:
		_on_join_cancelled()
		get_viewport().set_input_as_handled()
	elif _options_popup.visible:
		_options_popup.visible = false
		get_viewport().set_input_as_handled()
	elif _exit_popup.visible:
		_exit_popup.visible = false
		get_viewport().set_input_as_handled()

func _on_intro_finished() -> void:
	if _title_logo != null:
		_title_logo.scale = Vector2(1.18, 1.18)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(_center_container, "modulate:a", 1.0, 0.38) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	if _title_logo != null:
		tw.tween_property(_title_logo, "scale", Vector2.ONE, 0.32) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(_player_card_panel, "modulate:a", 1.0, 0.32) \
		.set_delay(0.10).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	if _version_label != null:
		tw.tween_property(_version_label, "modulate:a", 1.0, 0.28) \
			.set_delay(0.16)

func _on_options_pressed() -> void:
	_options_popup.visible = true

func _make_button(label: String) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.custom_minimum_size = Vector2(308, 48)
	btn.add_theme_font_size_override("font_size", 20)
	MenuStyle.wire_hover_scale(btn)
	SoundManager.wire_button(btn)
	return btn


func _make_primary_button(label: String) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.theme_type_variation = &"ButtonPrimary"
	btn.custom_minimum_size = Vector2(308, 52)
	btn.add_theme_font_size_override("font_size", 21)
	MenuStyle.wire_hover_scale(btn)
	SoundManager.wire_button(btn)
	return btn


func _make_tertiary_button(label: String) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.theme_type_variation = &"ButtonTertiary"
	btn.custom_minimum_size = Vector2(308, 32)
	btn.add_theme_font_size_override("font_size", 13)
	SoundManager.wire_button(btn)
	return btn

func _on_offline_pressed() -> void:
	_offline_popup.open()

func _on_free_play_pressed() -> void:
	_team_color_popup.open(TeamColorPopup.Mode.FREE_PLAY, _offline_home_color_id, _offline_away_color_id)

func _on_with_bots_pressed() -> void:
	_team_color_popup.open(TeamColorPopup.Mode.WITH_BOTS, _offline_home_color_id, _offline_away_color_id)

func _on_team_colors_chosen(mode: TeamColorPopup.Mode, home_id: String, away_id: String) -> void:
	_offline_home_color_id = home_id
	_offline_away_color_id = away_id
	if mode == TeamColorPopup.Mode.FREE_PLAY:
		_do_start_offline()
	else:
		_do_start_offline_with_bots()

func _on_team_color_back_pressed(_mode: TeamColorPopup.Mode) -> void:
	_offline_popup.open()

func _on_player_name_changed(new_name: String) -> void:
	if _card_name_label != null:
		_card_name_label.text = new_name

func _on_player_number_changed(new_number: int) -> void:
	if _card_number_label != null:
		_card_number_label.text = "#%d" % new_number

func _on_player_handedness_changed(is_left: bool) -> void:
	if _card_hand_label != null:
		_card_hand_label.text = "Shoots %s" % ("L" if is_left else "R")

func _do_start_offline() -> void:
	NetworkManager.pending_home_color_id = _offline_home_color_id
	NetworkManager.pending_away_color_id = _offline_away_color_id
	NetworkManager.start_offline()
	get_tree().change_scene_to_file(Constants.SCENE_HOCKEY)


# Same setup as _do_start_offline but routes through the lobby so the
# host can mark bot slots before starting. NetworkManager.start_offline()
# bypasses ENet entirely; the lobby's RPC dispatchers iterate
# connected_peer_ids() which is empty in offline mode, so all the
# notify_* broadcasts harmlessly no-op while local signals still fire.
func _do_start_offline_with_bots() -> void:
	NetworkManager.pending_home_color_id = _offline_home_color_id
	NetworkManager.pending_away_color_id = _offline_away_color_id
	NetworkManager.start_offline()
	get_tree().change_scene_to_file(Constants.SCENE_LOBBY)


func _do_start_tutorial() -> void:
	NetworkManager.pending_home_color_id = _offline_home_color_id
	NetworkManager.pending_away_color_id = _offline_away_color_id
	NetworkManager.start_tutorial()
	get_tree().change_scene_to_file(Constants.SCENE_HOCKEY)


func _on_host_pressed() -> void:
	NetworkManager.start_host()
	get_tree().change_scene_to_file(Constants.SCENE_LOBBY)

func _on_join_pressed(ip: String) -> void:
	PlayerPrefs.last_ip = ip
	PlayerPrefs.save()
	_disconnect_join_signals()
	NetworkManager.start_client(ip)
	_loading_screen.show_joining(ip)
	NetworkManager.client_connected.connect(_on_loading_connected, CONNECT_ONE_SHOT)
	NetworkManager.clock_ready.connect(_on_loading_clock_ready, CONNECT_ONE_SHOT)
	NetworkManager.lobby_roster_synced.connect(_on_join_got_lobby, CONNECT_ONE_SHOT)
	NetworkManager.join_in_progress.connect(_on_join_got_game, CONNECT_ONE_SHOT)

func _disconnect_join_signals() -> void:
	if NetworkManager.client_connected.is_connected(_on_loading_connected):
		NetworkManager.client_connected.disconnect(_on_loading_connected)
	if NetworkManager.clock_ready.is_connected(_on_loading_clock_ready):
		NetworkManager.clock_ready.disconnect(_on_loading_clock_ready)
	if NetworkManager.lobby_roster_synced.is_connected(_on_join_got_lobby):
		NetworkManager.lobby_roster_synced.disconnect(_on_join_got_lobby)
	if NetworkManager.join_in_progress.is_connected(_on_join_got_game):
		NetworkManager.join_in_progress.disconnect(_on_join_got_game)

func _on_loading_connected() -> void:
	_loading_screen.set_status("Syncing clock")

func _on_loading_clock_ready() -> void:
	_loading_screen.set_status("Loading")

func _on_join_got_lobby(_roster: Array) -> void:
	if NetworkManager.join_in_progress.is_connected(_on_join_got_game):
		NetworkManager.join_in_progress.disconnect(_on_join_got_game)
	_loading_screen.close_when_ready(func() -> void:
		get_tree().change_scene_to_file(Constants.SCENE_LOBBY))

func _on_join_got_game(config: Dictionary) -> void:
	if NetworkManager.lobby_roster_synced.is_connected(_on_join_got_lobby):
		NetworkManager.lobby_roster_synced.disconnect(_on_join_got_lobby)
	NetworkManager.pending_game_config = config
	_loading_screen.close_when_ready(func() -> void:
		get_tree().change_scene_to_file(Constants.SCENE_HOCKEY))
