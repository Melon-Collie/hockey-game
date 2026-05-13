class_name HUD
extends CanvasLayer

var _period_label: Label
var _clock_label: Label
var _home_score_label: Label
var _away_score_label: Label
var _phase_panel: PanelContainer
var _phase_wrapper: Control
var _phase_label: Label
var _scorer_label: Label
var _assist_label: Label
var _phase_style: StyleBoxFlat
var _game_over_popup: GameOverPopup = null
var _pause_menu: PauseMenu = null
var _bug_dialog: BugReportDialog = null
var _toast_stack: ToastStack = null
var _flash_overlay: FlashOverlay = null
var _home_sog_label: Label = null
var _away_sog_label: Label = null
var _score_0: int = 0
var _score_1: int = 0
var _home_badge_style: StyleBoxFlat = null
var _away_badge_style: StyleBoxFlat = null
var _last_clock_pulse_second: int = -1
var _confirm_dialog: ConfirmDialog = null
var _confirm_callback: Callable = Callable()
var _rematch_votes: Dictionary[int, bool] = {}
var _local_voted: bool = false
var _replay_label: Label = null
var _spectator_banner: PanelContainer = null
var _spectator_wrapper: Control = null

const _DARK_BG    := MenuStyle.BROADCAST_BG
const _WHITE      := MenuStyle.BROADCAST_CREAM
const _DIM        := MenuStyle.BROADCAST_DIM
const _GOLD       := MenuStyle.GOLD
const _SEP_COLOR  := MenuStyle.BROADCAST_SEP

func _ready() -> void:
	GameManager.team_colors_ready.connect(_on_team_colors_ready)
	_build_offscreen_indicators()
	_build_scorebug()
	_build_phase_banner()
	_build_version_tag()
	_build_bug_icon()
	_bug_dialog = BugReportDialog.new()
	add_child(_bug_dialog)
	_game_over_popup = GameOverPopup.new()
	_game_over_popup.rematch_toggled.connect(_on_rematch_vote_pressed)
	_game_over_popup.host_action_pressed.connect(_on_game_over_host_action)
	_game_over_popup.disconnect_pressed.connect(_on_game_over_disconnect)
	_game_over_popup.exit_pressed.connect(_on_game_over_exit)
	add_child(_game_over_popup)
	_pause_menu = PauseMenu.new()
	_pause_menu.opened.connect(func() -> void: GameManager.set_input_blocked(true))
	_pause_menu.closed.connect(func() -> void: GameManager.set_input_blocked(false))
	add_child(_pause_menu)
	_confirm_dialog = ConfirmDialog.new()
	_confirm_dialog.confirmed.connect(_on_confirm_dialog_confirmed)
	_confirm_dialog.cancelled.connect(_on_confirm_dialog_cancelled)
	add_child(_confirm_dialog)
	_toast_stack = ToastStack.new()
	add_child(_toast_stack)
	_flash_overlay = FlashOverlay.new()
	add_child(_flash_overlay)
	_period_label.text = _period_ordinal(1)
	_clock_label.text = _format_clock(GameManager.get_period_duration())
	_home_score_label.text = "0"
	_away_score_label.text = "0"
	_phase_wrapper.visible = false
	GameManager.score_changed.connect(_on_score_changed)
	GameManager.goal_scored.connect(_on_goal_scored)
	GameManager.phase_changed.connect(_on_phase_changed)
	GameManager.period_changed.connect(_on_period_changed)
	GameManager.clock_updated.connect(_on_clock_updated)
	GameManager.game_over.connect(_on_game_over)
	GameManager.game_reset.connect(_on_game_reset)
	NetworkManager.rematch_vote_changed.connect(_on_rematch_vote_changed)
	NetworkManager.peer_disconnected.connect(_on_rematch_peer_disconnected)
	GameManager.shots_on_goal_changed.connect(_on_shots_on_goal_changed)
	GameManager.player_joined.connect(func(n: String, c: Color) -> void: _toast_stack.push(n + " joined", c))
	GameManager.player_left.connect(func(n: String, c: Color) -> void: _toast_stack.push(n + " left", c))
	GameManager.local_player_hit.connect(_on_local_player_hit)
	GameManager.replay_started.connect(_on_replay_started)
	GameManager.replay_stopped.connect(_on_replay_stopped)
	GameManager.local_spectator_state_changed.connect(func(_is_spec: bool) -> void: _apply_spectator_chrome())
	_apply_spectator_chrome()

func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed(&"ui_cancel"):
		return
	if _game_over_popup.visible:
		return
	if _confirm_dialog.visible or _pause_menu.visible:
		return
	_pause_menu.open()
	get_viewport().set_input_as_handled()

# ---------------------------------------------------------------------------
# Build helpers
# ---------------------------------------------------------------------------

func _build_scorebug() -> void:
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = _DARK_BG
	panel_style.set_corner_radius_all(0)
	panel_style.border_color = MenuStyle.BROADCAST_BORDER_T
	panel_style.border_width_top = 1
	panel_style.anti_aliasing = false  # crisp edges to match the layered shadow

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", panel_style)
	var shadow_wrap := MenuStyle.wrap_drop_shadow(panel, Vector2(4, 4))
	shadow_wrap.position = Vector2(8, 8)
	add_child(shadow_wrap)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 0)
	panel.add_child(hbox)

	# === Teams column ===
	# Each team row is [stripe | abbr label | score]. Stripes carry the team
	# color the way a chyron lower-third does, replacing the old badge.
	var teams_outer := MarginContainer.new()
	teams_outer.add_theme_constant_override("margin_top", 4)
	teams_outer.add_theme_constant_override("margin_bottom", 4)
	hbox.add_child(teams_outer)
	var teams_vbox := VBoxContainer.new()
	teams_vbox.add_theme_constant_override("separation", 4)
	teams_outer.add_child(teams_vbox)
	var away_row := _build_scorebug_team_row(1, "AWAY")
	_away_badge_style = away_row.get_meta(&"stripe_style") as StyleBoxFlat
	_away_score_label = away_row.get_meta(&"score_label") as Label
	teams_vbox.add_child(away_row)
	var home_row := _build_scorebug_team_row(0, "HOME")
	_home_badge_style = home_row.get_meta(&"stripe_style") as StyleBoxFlat
	_home_score_label = home_row.get_meta(&"score_label") as Label
	teams_vbox.add_child(home_row)

	hbox.add_child(_vsep())

	# === Shots column ===
	var shots_cell := _cell(10, 4)
	hbox.add_child(shots_cell)
	var shots_vbox := VBoxContainer.new()
	shots_vbox.add_theme_constant_override("separation", 2)
	shots_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	shots_cell.add_child(shots_vbox)
	_away_sog_label = _lbl("0", 18, _WHITE)
	_away_sog_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_away_sog_label.custom_minimum_size = Vector2(28, 0)
	shots_vbox.add_child(_away_sog_label)
	var shots_header := _lbl("SHOTS", 10, _DIM)
	shots_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	shots_vbox.add_child(shots_header)
	_home_sog_label = _lbl("0", 18, _WHITE)
	_home_sog_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_home_sog_label.custom_minimum_size = Vector2(28, 0)
	shots_vbox.add_child(_home_sog_label)

	hbox.add_child(_vsep())

	# === Period + Clock column ===
	var time_cell := _cell(14, 4)
	hbox.add_child(time_cell)
	var time_vbox := VBoxContainer.new()
	time_vbox.add_theme_constant_override("separation", 2)
	time_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	time_cell.add_child(time_vbox)
	_period_label = _lbl("1ST", 13, _DIM)
	_period_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	time_vbox.add_child(_period_label)
	_clock_label = _lbl("4:00", 26, _WHITE)
	_clock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_clock_label.custom_minimum_size = Vector2(62, 0)
	time_vbox.add_child(_clock_label)

# One row of the teams column. Returns an HBox whose .get_meta() exposes the
# stripe StyleBox + abbreviation + score Labels for live updates.
func _build_scorebug_team_row(team_id: int, abbr: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 0)

	var stripe_style := StyleBoxFlat.new()
	stripe_style.bg_color = _initial_team_primary(team_id)
	var stripe := PanelContainer.new()
	stripe.add_theme_stylebox_override("panel", stripe_style)
	stripe.custom_minimum_size = Vector2(6, 28)
	row.add_child(stripe)

	var abbr_margin := MarginContainer.new()
	abbr_margin.add_theme_constant_override("margin_left", 8)
	abbr_margin.add_theme_constant_override("margin_right", 4)
	row.add_child(abbr_margin)
	var abbr_label := _lbl(abbr, 18, _WHITE)
	abbr_label.custom_minimum_size = Vector2(50, 0)
	abbr_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	abbr_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	abbr_margin.add_child(abbr_label)

	var score_margin := MarginContainer.new()
	score_margin.add_theme_constant_override("margin_right", 8)
	row.add_child(score_margin)
	var score_label := _lbl("0", 26, _WHITE)
	score_label.custom_minimum_size = Vector2(28, 0)
	score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	score_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	score_margin.add_child(score_label)

	row.set_meta(&"stripe_style", stripe_style)
	row.set_meta(&"score_label", score_label)
	return row

func _build_phase_banner() -> void:
	# Lower-third position. Broadcast goal/event chyrons traditionally sit in
	# the bottom ~20% of the frame; here we anchor a band to the bottom edge
	# of the screen and let CenterContainer center the wrapper within it
	# both horizontally and vertically so different banner heights still feel
	# centered around the same anchor line.
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	root.offset_top = -220.0
	root.offset_bottom = -50.0
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	var centering := CenterContainer.new()
	centering.set_anchors_preset(Control.PRESET_FULL_RECT)
	centering.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(centering)

	_phase_style = StyleBoxFlat.new()
	_phase_style.bg_color = MenuStyle.BROADCAST_BG
	_phase_style.set_corner_radius_all(0)
	_phase_style.border_color = MenuStyle.BROADCAST_BORDER_T
	_phase_style.border_width_top = 1
	_phase_style.anti_aliasing = false
	_phase_style.set_content_margin(SIDE_LEFT, 36)
	_phase_style.set_content_margin(SIDE_RIGHT, 36)
	_phase_style.set_content_margin(SIDE_TOP, 14)
	_phase_style.set_content_margin(SIDE_BOTTOM, 14)

	_phase_panel = PanelContainer.new()
	_phase_panel.add_theme_stylebox_override("panel", _phase_style)
	_phase_wrapper = MenuStyle.wrap_drop_shadow(_phase_panel, Vector2(5, 5))
	centering.add_child(_phase_wrapper)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 2)
	_phase_panel.add_child(vbox)

	# "GOAL!" / "FACEOFF" / "END OF PERIOD" / "HOME WINS" — chyron hero text
	_phase_label = _lbl("", 44, _GOLD)
	_phase_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_phase_label)

	# Scorer name on its own line under "GOAL!" so the visual hierarchy reads
	# like a broadcast goal graphic: hero / who / how
	_scorer_label = _lbl("", 26, _WHITE)
	_scorer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_scorer_label.visible = false
	vbox.add_child(_scorer_label)

	_assist_label = _lbl("", 16, _DIM)
	_assist_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_assist_label.visible = false
	vbox.add_child(_assist_label)

	_replay_label = _lbl("◀  REPLAY  ▶", 16, _DIM)
	_replay_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_replay_label.visible = false
	vbox.add_child(_replay_label)

# Persistent banner shown on spectator clients only. Sits centered at the top
# of the screen, above the phase banner area. Toggled by _apply_spectator_chrome.
func _build_spectator_banner() -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = MenuStyle.BROADCAST_BG
	style.set_corner_radius_all(0)
	style.border_color = MenuStyle.BROADCAST_BORDER_T
	style.border_width_top = 1
	style.anti_aliasing = false
	style.set_content_margin(SIDE_LEFT, 14)
	style.set_content_margin(SIDE_RIGHT, 14)
	style.set_content_margin(SIDE_TOP, 4)
	style.set_content_margin(SIDE_BOTTOM, 4)

	_spectator_banner = PanelContainer.new()
	_spectator_banner.add_theme_stylebox_override("panel", style)
	_spectator_banner.add_child(_lbl("SPECTATING", 20, _GOLD))
	_spectator_wrapper = MenuStyle.wrap_drop_shadow(_spectator_banner, Vector2(3, 3))

	# Centered horizontally, anchored to the top.
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var centering := HBoxContainer.new()
	centering.alignment = BoxContainer.ALIGNMENT_CENTER
	centering.anchor_right = 1.0
	centering.offset_top = 14.0
	centering.offset_bottom = 40.0
	centering.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(centering)
	centering.add_child(_spectator_wrapper)

	add_child(root)
	_spectator_wrapper.visible = false

# Hides local-only menu options (Rematch, Change Position) when the local peer
# is a spectator and shows the spectator banner. Off-screen indicators and the
# rink scoreboard already gate on registry membership, so they need no change.
func _apply_spectator_chrome() -> void:
	var is_spec: bool = GameManager.is_local_spectator()
	if _spectator_banner == null and is_spec:
		_build_spectator_banner()
	if _spectator_wrapper != null:
		_spectator_wrapper.visible = is_spec
	if _game_over_popup != null:
		_game_over_popup.set_spectator(is_spec)
	if _pause_menu != null:
		_pause_menu.apply_spectator_chrome(is_spec)

func _build_offscreen_indicators() -> void:
	var indicators := OffScreenPlayerIndicators.new()
	add_child(indicators)

func _build_bug_icon() -> void:
	var icon_tex := load("res://Assets/Icons/bug_report.svg") as Texture2D

	var normal_style := StyleBoxFlat.new()
	normal_style.bg_color = Color(0.0, 0.0, 0.0, 0.0)

	var hover_style := StyleBoxFlat.new()
	hover_style.bg_color = Color(1.0, 1.0, 1.0, 0.08)
	hover_style.set_corner_radius_all(4)

	var focus_style := StyleBoxFlat.new()
	focus_style.bg_color = Color(0.0, 0.0, 0.0, 0.0)

	var btn := Button.new()
	btn.icon = icon_tex
	btn.expand_icon = true
	btn.custom_minimum_size = Vector2(28, 28)
	btn.add_theme_stylebox_override("normal", normal_style)
	btn.add_theme_stylebox_override("hover", hover_style)
	btn.add_theme_stylebox_override("pressed", hover_style)
	btn.add_theme_stylebox_override("focus", focus_style)
	btn.add_theme_color_override("icon_normal_color", Color(0.7, 0.7, 0.75, 0.55))
	btn.add_theme_color_override("icon_hover_color", Color(1.0, 1.0, 1.0, 0.90))
	btn.add_theme_color_override("icon_pressed_color", Color(1.0, 1.0, 1.0, 0.70))
	btn.tooltip_text = "Report Bug"
	btn.anchor_left = 1.0
	btn.anchor_right = 1.0
	btn.anchor_top = 1.0
	btn.anchor_bottom = 1.0
	btn.offset_left = -36.0
	btn.offset_right = -8.0
	btn.offset_top = -52.0
	btn.offset_bottom = -24.0
	btn.pressed.connect(_on_bug_report_pressed)
	add_child(btn)

func _show_confirm(message: String, callback: Callable) -> void:
	_confirm_callback = callback
	_confirm_dialog.open(message)

func _on_confirm_dialog_confirmed() -> void:
	var cb := _confirm_callback
	_confirm_callback = Callable()
	if cb.is_valid():
		cb.call()

func _on_confirm_dialog_cancelled() -> void:
	_confirm_callback = Callable()

func _build_version_tag() -> void:
	var label := _lbl("v%s" % BuildInfo.VERSION, 11, _DIM)
	label.anchor_left = 1.0
	label.anchor_right = 1.0
	label.anchor_top = 1.0
	label.anchor_bottom = 1.0
	label.offset_left = -80.0
	label.offset_right = -8.0
	label.offset_top = -20.0
	label.offset_bottom = -4.0
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)


# ---------------------------------------------------------------------------
# Signal handlers
# ---------------------------------------------------------------------------

func _on_score_changed(score_0: int, score_1: int) -> void:
	_score_0 = score_0
	_score_1 = score_1
	_home_score_label.text = str(score_0)
	_away_score_label.text = str(score_1)

func _on_goal_scored(scoring_team: Team, scorer_name: String, assist1_name: String, assist2_name: String) -> void:
	var score_label: Label = _away_score_label if scoring_team.team_id == 1 else _home_score_label
	score_label.add_theme_color_override("font_color", _GOLD)
	var tween := create_tween()
	tween.tween_method(
		func(c: Color) -> void: score_label.add_theme_color_override("font_color", c),
		_GOLD, _WHITE, 1.5)

	# Score digit pop
	score_label.pivot_offset = score_label.size / 2.0
	var pop := create_tween()
	pop.tween_property(score_label, "scale", Vector2(1.6, 1.6), 0.0)
	pop.tween_property(score_label, "scale", Vector2.ONE, 0.5) \
		.set_trans(Tween.TRANS_SPRING).set_ease(Tween.EASE_OUT)

	_phase_label.text = "GOAL!"
	_phase_label.add_theme_color_override("font_color", _GOLD)
	_scorer_label.text = scorer_name
	_scorer_label.visible = not scorer_name.is_empty()
	var team_color: Color = TeamColorRegistry.get_colors(GameManager.teams[scoring_team.team_id].color_id, scoring_team.team_id).primary
	_phase_style.bg_color = Color(team_color.r * 0.25, team_color.g * 0.25, team_color.b * 0.25, 0.92)
	if not assist1_name.is_empty():
		var assist_text: String = assist1_name
		if not assist2_name.is_empty():
			assist_text += "  /  " + assist2_name
		_assist_label.text = "ASSISTED BY  " + assist_text
		_assist_label.visible = true
	else:
		_assist_label.visible = false

	_flash_overlay.flash(team_color)

func _initial_team_primary(team_id: int) -> Color:
	if GameManager.teams.size() > team_id:
		return TeamColorRegistry.get_colors(GameManager.teams[team_id].color_id, team_id).primary
	return Color(0.5, 0.5, 0.5)  # placeholder; team_colors_ready overwrites

func _on_team_colors_ready(home_primary: Color, _home_secondary: Color, away_primary: Color, _away_secondary: Color) -> void:
	# In the chyron layout the AWAY/HOME labels sit on the dark panel, not on
	# the team color, so their text stays cream regardless of team palette.
	if _home_badge_style != null:
		_home_badge_style.bg_color = home_primary
	if _away_badge_style != null:
		_away_badge_style.bg_color = away_primary

func _on_replay_started() -> void:
	if _replay_label != null:
		_replay_label.visible = true

func _on_replay_stopped() -> void:
	if _replay_label != null:
		_replay_label.visible = false

func _on_phase_changed(new_phase: int) -> void:
	match new_phase:
		GamePhase.Phase.PLAYING:
			_phase_wrapper.visible = false
			_phase_label.add_theme_color_override("font_color", _GOLD)
			_phase_style.bg_color = MenuStyle.BROADCAST_BG
			_scorer_label.visible = false
			_assist_label.visible = false
			if _replay_label != null:
				_replay_label.visible = false
		GamePhase.Phase.GOAL_SCORED:
			_phase_wrapper.visible = true  # text + color set by _on_goal_scored
		GamePhase.Phase.END_OF_PERIOD:
			_phase_label.text = "END OF PERIOD"
			_phase_label.add_theme_color_override("font_color", _GOLD)
			_phase_style.bg_color = MenuStyle.BROADCAST_BG
			_scorer_label.visible = false
			_assist_label.visible = false
			_phase_wrapper.visible = true
		GamePhase.Phase.GAME_OVER:
			_phase_wrapper.visible = true  # text + color set by _on_game_over
		_:
			_phase_label.text = "FACEOFF"
			_phase_label.add_theme_color_override("font_color", _GOLD)
			_phase_style.bg_color = MenuStyle.BROADCAST_BG
			_scorer_label.visible = false
			_assist_label.visible = false
			_phase_wrapper.visible = true

func _on_period_changed(new_period: int) -> void:
	_period_label.text = _period_ordinal(new_period)

func _on_clock_updated(t: float) -> void:
	_clock_label.text = _format_clock(t)
	if NetworkManager.is_offline_mode:
		_clock_label.add_theme_color_override("font_color", _WHITE)
		_last_clock_pulse_second = -1
		return
	_clock_label.add_theme_color_override("font_color", _GOLD if t <= 30.0 and t > 0.0 else _WHITE)
	if t > 0.0 and t <= 10.0:
		var sec := int(ceil(t))
		if sec != _last_clock_pulse_second:
			_last_clock_pulse_second = sec
			_clock_label.pivot_offset = _clock_label.size / 2.0
			var cp := create_tween()
			cp.tween_property(_clock_label, "scale", Vector2(1.3, 1.3), 0.0)
			cp.tween_property(_clock_label, "scale", Vector2.ONE, 0.25) \
				.set_trans(Tween.TRANS_SPRING).set_ease(Tween.EASE_OUT)
	else:
		_last_clock_pulse_second = -1

func _on_game_over() -> void:
	_phase_style.bg_color = MenuStyle.BROADCAST_BG  # clear any residual goal tint
	if _score_0 > _score_1:
		_phase_label.text = "HOME WINS"
		_phase_label.add_theme_color_override("font_color", _GOLD)
	elif _score_1 > _score_0:
		_phase_label.text = "AWAY WINS"
		_phase_label.add_theme_color_override("font_color", Color(0.55, 0.75, 1.0))
	else:
		_phase_label.text = "TIE"
		_phase_label.add_theme_color_override("font_color", _WHITE)
	_scorer_label.visible = false
	_assist_label.visible = false
	_phase_wrapper.visible = true
	_rematch_votes.clear()
	_local_voted = false
	_update_rematch_ui()
	_game_over_popup.show_popup()

func _on_game_reset() -> void:
	_game_over_popup.hide_popup()
	if _pause_menu != null:
		_pause_menu.close()

func _on_rematch_vote_pressed() -> void:
	_local_voted = not _local_voted
	NetworkManager.send_rematch_vote(_local_voted)

func _on_rematch_vote_changed(peer_id: int, vote: bool) -> void:
	_rematch_votes[peer_id] = vote
	_update_rematch_ui()
	if NetworkManager.is_host:
		_check_rematch_unanimous()

func _on_rematch_peer_disconnected(peer_id: int) -> void:
	_rematch_votes.erase(peer_id)
	_update_rematch_ui()
	if NetworkManager.is_host:
		_check_rematch_unanimous()

func _update_rematch_ui() -> void:
	var total: int = NetworkManager.connected_peer_ids().size() + 1
	_game_over_popup.update_votes(_rematch_votes, total, _local_voted)

func _on_game_over_host_action() -> void:
	if NetworkManager.is_offline_mode:
		GameManager.exit_to_main_menu()
	else:
		GameManager.return_to_lobby()

func _on_game_over_disconnect() -> void:
	_show_confirm("Return to main menu?", GameManager.exit_to_main_menu)

func _on_game_over_exit() -> void:
	_show_confirm("Exit game?", func() -> void:
		GameManager.on_scene_exit()
		NetworkManager.reset()
		get_tree().quit())

func _check_rematch_unanimous() -> void:
	# Host-side: spectators don't have a vote button. spectator_peer_count
	# already includes the host's peer (1) if the host is itself a spectator,
	# so a single subtraction here yields the actual voter pool.
	var total: int = NetworkManager.connected_peer_ids().size() + 1 \
			- GameManager.spectator_peer_count()
	var count: int = 0
	for v: bool in _rematch_votes.values():
		if v:
			count += 1
	if total > 0 and count >= total:
		GameManager.reset_game()

func _on_bug_report_pressed() -> void:
	_bug_dialog.open()

func _on_local_player_hit(magnitude: float) -> void:
	if magnitude < 3.0:
		return
	var strength := clampf(magnitude / 12.0, 0.2, 0.55)
	_flash_overlay.vignette_pulse(strength)

func _on_shots_on_goal_changed(sog_0: int, sog_1: int) -> void:
	if _home_sog_label != null:
		_home_sog_label.text = str(sog_0)
	if _away_sog_label != null:
		_away_sog_label.text = str(sog_1)

# ---------------------------------------------------------------------------
# Utility
# ---------------------------------------------------------------------------

func _cell(h_margin: int, v_margin: int) -> MarginContainer:
	var c := MarginContainer.new()
	c.add_theme_constant_override("margin_left", h_margin)
	c.add_theme_constant_override("margin_right", h_margin)
	c.add_theme_constant_override("margin_top", v_margin)
	c.add_theme_constant_override("margin_bottom", v_margin)
	return c

func _vsep() -> VSeparator:
	var sep := VSeparator.new()
	var style := StyleBoxFlat.new()
	style.bg_color = _SEP_COLOR
	style.set_content_margin_all(0)
	sep.add_theme_stylebox_override("separator", style)
	sep.custom_minimum_size = Vector2(1, 0)
	return sep

func _lbl(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", MenuStyle.BROADCAST_FONT)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l

func _period_ordinal(p: int) -> String:
	var n: int = GameManager.get_num_periods()
	if p > n:
		return "OT%d" % (p - n)
	match p:
		1: return "1ST"
		2: return "2ND"
		3: return "3RD"
		_: return "P%d" % p

func _format_clock(t: float) -> String:
	var secs: int = int(ceil(t))
	return "%d:%02d" % [int(secs / 60.0), secs % 60]
