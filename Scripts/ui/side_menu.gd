class_name SideMenu
extends CanvasLayer

# Right-anchored activity menu shown when the player presses Escape during
# free play. Replaces the old centered MainMenu. Composes the existing popups
# (PlayerSettingsPopup, OnlinePopup, CareerStatsScreen, OptionsPanel,
# ConfirmDialog) — each opens as a centered overlay on top of the side panel.
#
# Visual style is "Variant B" — flat dark panel anchored to the right edge,
# text-only activity rows that brighten and grow a 2px teal accent bar on
# hover. No primary CTA; all rows are visually equal.

signal opened
signal closed

const _PANEL_WIDTH: float = 340.0

var _root: Control = null
var _panel: PanelContainer = null
var _player_card_name: Label = null
var _player_card_number: Label = null
var _player_card_hand: Label = null
var _player_card_panel: PanelContainer = null
var _player_card_normal: StyleBoxFlat = null
var _player_card_hover: StyleBoxFlat = null
var _player_card_edit_icon: TextureRect = null
var _player_card_callout: Label = null
var _player_card_callout_tween: Tween = null
var _player_popup: PlayerSettingsPopup = null
var _online_popup: OnlinePopup = null
var _career_screen: CareerStatsScreen = null
var _options_container: Control = null
var _exit_container: Control = null
var _tutorial_container: Control = null
var _tutorial_rows_vbox: VBoxContainer = null
var _loading_screen: LoadingScreen = null


func _ready() -> void:
	layer = 20
	visible = false
	_build_panel()
	_build_popups()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if not event.is_action_pressed(&"ui_cancel"):
		return
	if _options_container != null and _options_container.visible:
		_options_container.visible = false
	elif _exit_container != null and _exit_container.visible:
		_exit_container.visible = false
	elif _tutorial_container != null and _tutorial_container.visible:
		_tutorial_container.visible = false
	elif _player_popup != null and _player_popup.visible:
		# PlayerSettingsPopup handles its own ui_cancel — let it through.
		return
	elif _online_popup != null and _online_popup.visible:
		# OnlinePopup handles its own ui_cancel — let it through.
		return
	elif _career_screen != null and _career_screen.visible:
		# CareerStatsScreen handles its own ui_cancel — let it through.
		return
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
	if _options_container != null:
		_options_container.visible = false
	if _exit_container != null:
		_exit_container.visible = false
	if _tutorial_container != null:
		_tutorial_container.visible = false
	visible = false
	closed.emit()


func toggle() -> void:
	if visible:
		close()
	else:
		open()


# ── Build helpers ────────────────────────────────────────────────────────────

func _build_panel() -> void:
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Cascade UI_FONT (Manrope) to every Label/Button under the side menu.
	# DISPLAY_FONT is applied per-control where we want the heavy condensed
	# look (player name, jersey number).
	_root.theme = MenuStyle.ui_theme()
	add_child(_root)

	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = MenuStyle.PANEL_BG
	panel_style.border_color = MenuStyle.TEAL_DIM
	panel_style.border_width_left = 1
	panel_style.set_content_margin(SIDE_LEFT, 22)
	panel_style.set_content_margin(SIDE_RIGHT, 22)
	panel_style.set_content_margin(SIDE_TOP, 22)
	panel_style.set_content_margin(SIDE_BOTTOM, 16)

	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", panel_style)
	_panel.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	_panel.offset_left = -_PANEL_WIDTH
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 0)
	_panel.add_child(vbox)

	_build_player_card(vbox)

	var card_gap := Control.new()
	card_gap.custom_minimum_size = Vector2(0, 14)
	vbox.add_child(card_gap)

	_add_row(vbox, "Play Online", false, _on_play_online_pressed)
	_add_row(vbox, "Play vs Bots", false, _on_play_vs_bots_pressed)
	_add_row(vbox, "Tutorial", false, _on_tutorial_pressed)
	_add_row(vbox, "Career", false, _on_career_pressed)
	_add_row(vbox, "Options", false, _on_options_pressed)
	_add_row(vbox, "Exit Game", true, _on_exit_pressed)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(spacer)

	_build_footer(vbox)


func _build_player_card(parent: VBoxContainer) -> void:
	_player_card_normal = StyleBoxFlat.new()
	_player_card_normal.bg_color = MenuStyle.PANEL_BG
	_player_card_normal.set_corner_radius_all(6)
	_player_card_normal.set_content_margin_all(14)
	_player_card_normal.border_color = MenuStyle.TEAL_DIM
	_player_card_normal.set_border_width_all(1)

	_player_card_hover = StyleBoxFlat.new()
	_player_card_hover.bg_color = MenuStyle.SURFACE_ELEV
	_player_card_hover.set_corner_radius_all(6)
	_player_card_hover.set_content_margin_all(14)
	_player_card_hover.border_color = MenuStyle.TEAL
	_player_card_hover.set_border_width_all(1)

	_player_card_panel = PanelContainer.new()
	_player_card_panel.add_theme_stylebox_override("panel", _player_card_normal)
	_player_card_panel.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_player_card_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	parent.add_child(_player_card_panel)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 14)
	_player_card_panel.add_child(hbox)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(vbox)

	_player_card_name = Label.new()
	_player_card_name.text = PlayerPrefs.player_name
	_player_card_name.add_theme_font_override("font", MenuStyle.DISPLAY_FONT)
	_player_card_name.add_theme_font_size_override("font_size", 28)
	_player_card_name.add_theme_color_override("font_color", MenuStyle.TEXT_TITLE)
	vbox.add_child(_player_card_name)

	var detail_row := HBoxContainer.new()
	detail_row.add_theme_constant_override("separation", 10)
	vbox.add_child(detail_row)

	_player_card_number = Label.new()
	_player_card_number.text = "#%d" % PlayerPrefs.jersey_number
	_player_card_number.add_theme_font_override("font", MenuStyle.DISPLAY_FONT)
	_player_card_number.add_theme_font_size_override("font_size", 18)
	_player_card_number.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	detail_row.add_child(_player_card_number)

	_player_card_hand = Label.new()
	_player_card_hand.text = "Shoots %s" % ("L" if PlayerPrefs.is_left_handed else "R")
	_player_card_hand.add_theme_font_size_override("font_size", 14)
	_player_card_hand.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	detail_row.add_child(_player_card_hand)

	_player_card_edit_icon = TextureRect.new()
	_player_card_edit_icon.texture = load("res://Assets/Icons/edit.svg") as Texture2D
	_player_card_edit_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_player_card_edit_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_player_card_edit_icon.custom_minimum_size = Vector2(16, 16)
	_player_card_edit_icon.modulate = MenuStyle.TEXT_MUTED
	_player_card_edit_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_player_card_edit_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hbox.add_child(_player_card_edit_icon)

	_player_card_panel.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_on_player_card_pressed())
	_player_card_panel.mouse_entered.connect(func() -> void:
		_player_card_panel.add_theme_stylebox_override("panel", _player_card_hover)
		_player_card_edit_icon.modulate = MenuStyle.TEAL_HOVER)
	_player_card_panel.mouse_exited.connect(func() -> void:
		_player_card_panel.add_theme_stylebox_override("panel", _player_card_normal)
		_player_card_edit_icon.modulate = MenuStyle.TEXT_MUTED)

	# First-run callout: point new players at the card so they discover the
	# name / number / handedness / attributes editor. Pulses to draw the eye and
	# is dismissed for good the first time the card is opened.
	if not PlayerPrefs.has_opened_player_settings:
		_player_card_callout = Label.new()
		_player_card_callout.text = "↑ New here? Tap to set your name, number & attributes"
		_player_card_callout.add_theme_font_size_override("font_size", 13)
		_player_card_callout.add_theme_color_override("font_color", MenuStyle.TEAL_HOVER)
		_player_card_callout.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_player_card_callout.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		parent.add_child(_player_card_callout)
		_player_card_callout_tween = MenuStyle.pulse(_player_card_callout)


# A single activity row — text-only, with a 2px teal left accent bar and a
# small text shift on hover. `danger` makes the row use the warning color
# (Exit Game). The row is built as a Control + child Label so we can paint
# the accent bar via a ColorRect anchored to the left edge.
func _add_row(parent: VBoxContainer, label_text: String, danger: bool, handler: Callable) -> void:
	var row := Control.new()
	row.custom_minimum_size = Vector2(0, 42)
	row.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	parent.add_child(row)

	var accent := ColorRect.new()
	accent.color = MenuStyle.DANGER if danger else MenuStyle.TEAL
	accent.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	accent.offset_right = 2.0
	accent.offset_top = 12.0
	accent.offset_bottom = -12.0
	accent.modulate.a = 0.0
	accent.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(accent)

	var rest_color: Color = MenuStyle.DANGER if danger else MenuStyle.TEXT_DIM
	var hover_color: Color = MenuStyle.TEXT_TITLE if not danger else MenuStyle.DANGER

	var label := Label.new()
	label.text = label_text
	label.add_theme_font_size_override("font_size", 17)
	label.add_theme_color_override("font_color", rest_color)
	label.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	label.offset_left = 4.0
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(label)

	if danger:
		label.modulate.a = 0.85

	row.mouse_entered.connect(func() -> void:
		label.add_theme_color_override("font_color", hover_color)
		label.offset_left = 18.0
		accent.modulate.a = 1.0
		if danger:
			label.modulate.a = 1.0
		SoundManager.play_ui(SoundManager.Sound.UI_HOVER))
	row.mouse_exited.connect(func() -> void:
		label.add_theme_color_override("font_color", rest_color)
		label.offset_left = 4.0
		accent.modulate.a = 0.0
		if danger:
			label.modulate.a = 0.85)
	row.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			SoundManager.play_ui(SoundManager.Sound.UI_CLICK)
			handler.call())


func _build_footer(parent: VBoxContainer) -> void:
	var separator := ColorRect.new()
	separator.color = MenuStyle.TEXT_SEP
	separator.custom_minimum_size = Vector2(0, 1)
	parent.add_child(separator)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 12)
	parent.add_child(gap)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	parent.add_child(hbox)

	var esc_style := StyleBoxFlat.new()
	esc_style.bg_color = Color(0, 0, 0, 0)
	esc_style.border_color = MenuStyle.TEXT_SEP
	esc_style.set_border_width_all(1)
	esc_style.set_corner_radius_all(3)
	esc_style.set_content_margin(SIDE_LEFT, 6)
	esc_style.set_content_margin(SIDE_RIGHT, 6)
	esc_style.set_content_margin(SIDE_TOP, 2)
	esc_style.set_content_margin(SIDE_BOTTOM, 2)

	var esc_panel := PanelContainer.new()
	esc_panel.add_theme_stylebox_override("panel", esc_style)
	hbox.add_child(esc_panel)

	var esc_label := Label.new()
	esc_label.text = "ESC"
	esc_label.add_theme_font_size_override("font_size", 10)
	esc_label.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	esc_panel.add_child(esc_label)

	var close_label := Label.new()
	close_label.text = "Close"
	close_label.add_theme_font_size_override("font_size", 12)
	close_label.add_theme_color_override("font_color", MenuStyle.TEXT_MUTED)
	close_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hbox.add_child(close_label)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(spacer)

	# Version label. The update-checker alert dot will land here in a follow-up
	# pass; for now we just show the build version so players know what they
	# have.
	var version_label := Label.new()
	version_label.text = "v%s" % BuildInfo.VERSION
	version_label.add_theme_font_size_override("font_size", 12)
	version_label.add_theme_color_override("font_color", MenuStyle.TEXT_MUTED)
	version_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hbox.add_child(version_label)


# ── Popups ───────────────────────────────────────────────────────────────────

func _build_popups() -> void:
	_player_popup = PlayerSettingsPopup.new()
	_player_popup.name_changed.connect(_on_player_name_changed)
	_player_popup.jersey_number_changed.connect(_on_player_number_changed)
	_player_popup.handedness_changed.connect(_on_player_handedness_changed)
	add_child(_player_popup)

	_online_popup = OnlinePopup.new()
	_online_popup.host_pressed.connect(_on_host_pressed)
	_online_popup.join_pressed.connect(_on_join_pressed)
	add_child(_online_popup)

	# Steam overlay "Join Game" / accepted invite (and `+connect_lobby` launch)
	# routes straight into the join flow.
	SteamManager.lobby_invite_accepted.connect(_on_join_pressed)

	_career_screen = CareerStatsScreen.new()
	add_child(_career_screen)

	_build_options_overlay()
	_build_exit_overlay()
	_build_tutorial_overlay()

	_loading_screen = LoadingScreen.new()
	_loading_screen.cancel_pressed.connect(_on_join_cancelled)
	add_child(_loading_screen)


func _build_options_overlay() -> void:
	var overlay := ColorRect.new()
	overlay.color = MenuStyle.SCRIM
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed:
			_options_container.visible = false)

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
	_options_container.visible = false
	_options_container.add_child(overlay)
	_options_container.add_child(panel)
	add_child(_options_container)


func _build_exit_overlay() -> void:
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

	var close_row := HBoxContainer.new()
	var close_spacer := Control.new()
	close_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	close_row.add_child(close_spacer)
	var close_btn := MenuStyle.close_button()
	close_btn.pressed.connect(func() -> void: _exit_container.visible = false)
	SoundManager.wire_button(close_btn)
	close_row.add_child(close_btn)
	vbox.add_child(close_row)

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

	var confirm_btn := MenuStyle.popup_button("Exit")
	confirm_btn.custom_minimum_size = Vector2(140, 48)
	confirm_btn.pressed.connect(func() -> void: get_tree().quit())
	btn_row.add_child(confirm_btn)

	var cancel_btn := MenuStyle.popup_button("Cancel")
	cancel_btn.custom_minimum_size = Vector2(140, 48)
	cancel_btn.pressed.connect(func() -> void: _exit_container.visible = false)
	btn_row.add_child(cancel_btn)

	_exit_container = Control.new()
	_exit_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_exit_container.visible = false
	_exit_container.add_child(overlay)
	_exit_container.add_child(panel)
	add_child(_exit_container)


# Tutorial picker modal. Iterates TutorialRegistry.ALL_IDS so adding a new
# tutorial later (drills, advanced+, etc.) automatically grows the list with
# no changes here. Row shows a checkmark when PlayerPrefs marks the tutorial
# complete.
func _build_tutorial_overlay() -> void:
	var overlay := ColorRect.new()
	overlay.color = MenuStyle.SCRIM
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed:
			_tutorial_container.visible = false)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", MenuStyle.panel(6, 32))
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	panel.custom_minimum_size = Vector2(360, 0)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)
	panel.add_child(vbox)

	var close_row := HBoxContainer.new()
	var close_spacer := Control.new()
	close_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	close_row.add_child(close_spacer)
	var close_btn := MenuStyle.close_button()
	close_btn.pressed.connect(func() -> void: _tutorial_container.visible = false)
	SoundManager.wire_button(close_btn)
	close_row.add_child(close_btn)
	vbox.add_child(close_row)

	var heading := Label.new()
	heading.text = "Tutorial"
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_font_size_override("font_size", 22)
	heading.add_theme_color_override("font_color", MenuStyle.TEXT_TITLE)
	vbox.add_child(heading)

	_tutorial_rows_vbox = VBoxContainer.new()
	_tutorial_rows_vbox.add_theme_constant_override("separation", 8)
	vbox.add_child(_tutorial_rows_vbox)

	_tutorial_container = Control.new()
	_tutorial_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_tutorial_container.visible = false
	_tutorial_container.add_child(overlay)
	_tutorial_container.add_child(panel)
	add_child(_tutorial_container)

	_refresh_tutorial_rows()


# Rebuilds the row list. Called when the picker opens so the checkmark next to
# each tutorial reflects the latest PlayerPrefs state (e.g. the player just
# completed Basics in a previous session this run).
func _refresh_tutorial_rows() -> void:
	if _tutorial_rows_vbox == null:
		return
	for child: Node in _tutorial_rows_vbox.get_children():
		child.queue_free()
	for tutorial_id: String in TutorialRegistry.ALL_IDS:
		# "Part 1 of 2 · Basics" framing so the picker reads as one ordered
		# course rather than two standalone options.
		var seq: String = TutorialRegistry.get_sequence_label(tutorial_id)
		var label_text: String = "%s · %s" % [seq, TutorialRegistry.get_display_name(tutorial_id)] \
			if seq != "" else TutorialRegistry.get_display_name(tutorial_id)
		if PlayerPrefs.is_tutorial_complete(tutorial_id):
			label_text += "    ✓"
		var btn := MenuStyle.popup_button(label_text)
		btn.custom_minimum_size = Vector2(280, 44)
		var id_copy: String = tutorial_id
		btn.pressed.connect(func() -> void:
			_tutorial_container.visible = false
			_launch_tutorial(id_copy))
		SoundManager.wire_button(btn)
		_tutorial_rows_vbox.add_child(btn)


# ── Action handlers ──────────────────────────────────────────────────────────

func _on_player_card_pressed() -> void:
	_dismiss_player_card_callout()
	_player_popup.open()


# Tears down the first-run callout and latches the flag so it never shows again.
func _dismiss_player_card_callout() -> void:
	if _player_card_callout == null:
		return
	PlayerPrefs.mark_player_settings_opened()
	if _player_card_callout_tween != null and _player_card_callout_tween.is_running():
		_player_card_callout_tween.kill()
	_player_card_callout_tween = null
	_player_card_callout.queue_free()
	_player_card_callout = null


func _on_player_name_changed(new_name: String) -> void:
	if _player_card_name != null:
		_player_card_name.text = new_name


func _on_player_number_changed(new_number: int) -> void:
	if _player_card_number != null:
		_player_card_number.text = "#%d" % new_number


func _on_player_handedness_changed(is_left: bool) -> void:
	if _player_card_hand != null:
		_player_card_hand.text = "Shoots %s" % ("L" if is_left else "R")


func _on_play_online_pressed() -> void:
	_online_popup.open()


func _on_play_vs_bots_pressed() -> void:
	# Reset clears the free-play flag and the offline session so the lobby
	# starts from a clean slate. Then start_offline re-arms host-side state
	# and we hand off to Lobby, which owns the with-bots flow.
	GameManager.on_scene_exit()
	NetworkSimManager.clear_pending()
	NetworkManager.reset()
	NetworkManager.start_offline()
	get_tree().change_scene_to_file(Constants.SCENE_LOBBY)


func _on_tutorial_pressed() -> void:
	# Opens the tutorial submenu so the player can pick between Basics,
	# Advanced, and any future tutorials. Selection routes through
	# _launch_tutorial(id) which mirrors the original direct-launch flow.
	if _tutorial_container == null:
		return
	_refresh_tutorial_rows()
	_tutorial_container.visible = true


func _launch_tutorial(id: String) -> void:
	GameManager.on_scene_exit()
	NetworkSimManager.clear_pending()
	NetworkManager.reset()
	NetworkManager.start_tutorial(id)
	get_tree().change_scene_to_file(Constants.SCENE_HOCKEY)


func _on_career_pressed() -> void:
	_career_screen.open()


func _on_options_pressed() -> void:
	_options_container.visible = true


func _on_exit_pressed() -> void:
	_exit_container.visible = true


func _on_host_pressed() -> void:
	if not SteamManager.is_available:
		_loading_screen.show_error("Steam isn't running.\nStart Steam and relaunch to play online.")
		return
	GameManager.on_scene_exit()
	NetworkSimManager.clear_pending()
	NetworkManager.reset()
	# Steam lobby creation is async — wait for host_lobby_ready before changing
	# scene (mirrors the client's existing one-shot wait pattern below).
	_loading_screen.show_hosting()
	NetworkManager.host_lobby_ready.connect(_on_host_lobby_ready, CONNECT_ONE_SHOT)
	NetworkManager.host_lobby_failed.connect(_on_host_lobby_failed, CONNECT_ONE_SHOT)
	NetworkManager.start_host()


func _on_host_lobby_ready() -> void:
	if NetworkManager.host_lobby_failed.is_connected(_on_host_lobby_failed):
		NetworkManager.host_lobby_failed.disconnect(_on_host_lobby_failed)
	_loading_screen.close_when_ready(func() -> void:
		get_tree().change_scene_to_file(Constants.SCENE_LOBBY))


func _on_host_lobby_failed(reason: String) -> void:
	if NetworkManager.host_lobby_ready.is_connected(_on_host_lobby_ready):
		NetworkManager.host_lobby_ready.disconnect(_on_host_lobby_ready)
	NetworkManager.reset()
	_loading_screen.show_error(reason)


# `lobby_id` comes from the public lobby browser or a Steam friend invite.
func _on_join_pressed(lobby_id: int) -> void:
	if not SteamManager.is_available:
		_loading_screen.show_error("Steam isn't running.\nStart Steam and relaunch to play online.")
		return
	GameManager.on_scene_exit()
	NetworkSimManager.clear_pending()
	_disconnect_join_signals()
	NetworkManager.reset()
	NetworkManager.start_client_lobby(lobby_id)
	_loading_screen.show_joining_lobby()
	# Lobby-join phase failure (Steam couldn't enter the lobby) surfaces here;
	# the four signals after it are the unchanged post-connect handshake waits.
	NetworkManager.client_lobby_failed.connect(_on_join_lobby_failed, CONNECT_ONE_SHOT)
	NetworkManager.client_connected.connect(_on_loading_connected, CONNECT_ONE_SHOT)
	NetworkManager.clock_ready.connect(_on_loading_clock_ready, CONNECT_ONE_SHOT)
	NetworkManager.lobby_roster_synced.connect(_on_join_got_lobby, CONNECT_ONE_SHOT)
	NetworkManager.join_in_progress.connect(_on_join_got_game, CONNECT_ONE_SHOT)


func _on_join_lobby_failed(reason: String) -> void:
	_disconnect_join_signals()
	NetworkManager.reset()
	_loading_screen.show_error(reason)


func _on_join_cancelled() -> void:
	_disconnect_join_signals()
	NetworkManager.reset()
	_loading_screen.visible = false


func _disconnect_join_signals() -> void:
	if NetworkManager.client_lobby_failed.is_connected(_on_join_lobby_failed):
		NetworkManager.client_lobby_failed.disconnect(_on_join_lobby_failed)
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
