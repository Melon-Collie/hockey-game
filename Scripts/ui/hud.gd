class_name HUD
extends CanvasLayer

# Orchestrates the in-game chrome. The panels under Scripts/ui/hud/ each own
# their own widgets and state; this file owns the session wiring — which signal
# drives which panel, which overlay is up, and who eats a key press.

# Playtest aid: toast the local player's released shot speed as
# "SHOT · 74 MPH · 89%". The % is of the shot family's own attribute-scaled
# ceiling (wrister/quick → max_wrister_power, slapper → max_slapper_power),
# so it reads as "where in my band did that release land" — the feedback loop
# for learning to hit in-between wrister speeds. Off silences it in the editor.
@export var debug_shot_speed_toast: bool = true
var _shot_toast_controller: SkaterController = null

var _scorebug: HudScorebug = null
var _chyron: HudGoalChyron = null
var _prompts: HudPrompts = null
var _ghost_banner: HudGhostBanner = null
var _stat_feed: HudStatFeed = HudStatFeed.new()
var _votes: HudRematchVotes = HudRematchVotes.new()

var _game_over_popup: GameOverPopup = null
var _post_game_analytics: PostGameAnalytics = null
var _intermission_overlay: IntermissionOverlay = null
var _matchup_overlay: MatchupIntroOverlay = null
var _pause_menu: PauseMenu = null
var _side_menu: SideMenu = null
var _bug_dialog: BugReportDialog = null
var _toast_stack: ToastStack = null
var _flash_overlay: FlashOverlay = null
var _confirm_dialog: ConfirmDialog = null
var _confirm_callback: Callable = Callable()
var _spectator_banner: PanelContainer = null
var _spectator_wrapper: Control = null
# Parent of all scalable HUD chrome — see _update_hud_scale.
var _scale_root: Control = null

func _ready() -> void:
	GameManager.team_colors_ready.connect(_on_team_colors_ready)
	# Indicators stay a direct child (added before the scale root so the chrome
	# still draws over them): they render at unprojected screen coordinates,
	# which must not go through the HUD-scale transform.
	_build_offscreen_indicators()
	# All HUD chrome hangs off this root; _update_hud_scale sizes it to a
	# virtual viewport of (vp / s) and scales it up by s, so edge-anchored
	# widgets stay glued to the true screen edges at any scale.
	_scale_root = Control.new()
	_scale_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_scale_root)
	# Size the root before the builders run so their anchors resolve against
	# the virtual viewport immediately, not on the first _process.
	_update_hud_scale()
	# Build order IS z-order: each panel adds its widgets to _scale_root as it
	# is called, and later widgets draw over earlier ones.
	_scorebug = HudScorebug.new()
	add_child(_scorebug)
	_scorebug.warning_toast.connect(_on_scorebug_warning_toast)
	_scorebug.build(_scale_root)
	_build_minimap()
	_chyron = HudGoalChyron.new()
	add_child(_chyron)
	_chyron.matchup_intro_requested.connect(_show_matchup_overlay)
	_chyron.matchup_intro_dismissed.connect(_hide_matchup_overlay)
	_chyron.build(_scale_root)
	_scorebug.build_clock_warning(_scale_root)
	_chyron.build_wash(_scale_root)
	_build_version_tag()
	_ghost_banner = HudGhostBanner.new()
	add_child(_ghost_banner)
	_ghost_banner.build(_scale_root)
	_build_bug_icon()
	_prompts = HudPrompts.new()
	add_child(_prompts)
	_prompts.skip_text_changed.connect(_on_skip_text_changed)
	_prompts.build_skip(_scale_root)
	_prompts.build_clip(_scale_root)
	_bug_dialog = BugReportDialog.new()
	add_child(_bug_dialog)
	_game_over_popup = GameOverPopup.new()
	_game_over_popup.rematch_toggled.connect(_on_rematch_vote_pressed)
	_game_over_popup.lobby_vote_toggled.connect(_on_lobby_vote_pressed)
	_game_over_popup.free_play_pressed.connect(_on_game_over_free_play)
	_game_over_popup.exit_pressed.connect(_on_game_over_exit)
	_game_over_popup.analytics_pressed.connect(_on_game_over_analytics)
	add_child(_game_over_popup)
	_post_game_analytics = PostGameAnalytics.new()
	# Controller: the analytics reader covers the game-over screen, so focus is
	# walled off from its buttons and handed back when the reader closes.
	_post_game_analytics.set_focus_background(_game_over_popup.focus_root())
	add_child(_post_game_analytics)
	_intermission_overlay = IntermissionOverlay.new()
	add_child(_intermission_overlay)
	_matchup_overlay = MatchupIntroOverlay.new()
	add_child(_matchup_overlay)
	_pause_menu = PauseMenu.new()
	_pause_menu.opened.connect(func() -> void: GameManager.set_input_blocked(true))
	_pause_menu.closed.connect(func() -> void: GameManager.set_input_blocked(false))
	# Both menus route their Report Bug entry through the HUD's single dialog,
	# handing over their own content root so focus is walled off behind it.
	_pause_menu.bug_report_requested.connect(func() -> void:
		_on_bug_report_pressed(_pause_menu.focus_root()))
	add_child(_pause_menu)
	_side_menu = SideMenu.new()
	_side_menu.opened.connect(func() -> void: GameManager.set_input_blocked(true))
	_side_menu.closed.connect(func() -> void: GameManager.set_input_blocked(false))
	_side_menu.bug_report_requested.connect(func() -> void:
		_on_bug_report_pressed(_side_menu.focus_root()))
	add_child(_side_menu)
	# Free play IS the main menu, so land with the SideMenu open (it's obvious
	# one exists) and keep a pulsing "[ESC] MENU" affordance up whenever it's
	# closed. Only in free play — a real match uses the PauseMenu instead.
	if NetworkManager.is_free_play_mode:
		_prompts.build_menu_hint(_scale_root)
		_side_menu.opened.connect(_prompts.hide_menu_hint)
		_side_menu.closed.connect(_prompts.show_menu_hint)
		_side_menu.open()
	_confirm_dialog = ConfirmDialog.new()
	_confirm_dialog.confirmed.connect(_on_confirm_dialog_confirmed)
	_confirm_dialog.cancelled.connect(_on_confirm_dialog_cancelled)
	add_child(_confirm_dialog)
	_toast_stack = ToastStack.new()
	_scale_root.add_child(_toast_stack)
	# Surface the connection error from whatever session dumped us back here
	# (host quit, join failed, timed out, kicked); pending_error is written
	# right before return_to_free_play(). Without this the failure is silent.
	if not NetworkManager.pending_error.is_empty():
		_toast_stack.push(NetworkManager.pending_error, Color(0.95, 0.55, 0.5))
		NetworkManager.pending_error = ""
	_flash_overlay = FlashOverlay.new()
	add_child(_flash_overlay)
	_stat_feed.feed_event.connect(_on_stat_feed_event)
	_votes.tally_changed.connect(_on_vote_tally_changed)
	_votes.resolved.connect(_on_vote_resolved)
	GameManager.score_changed.connect(_scorebug.set_score)
	GameManager.goal_scored.connect(_on_goal_scored)
	GameManager.phase_changed.connect(_on_phase_changed)
	GameManager.faceoff_prep_announced.connect(_on_faceoff_prep_announced)
	GameManager.period_synced.connect(_scorebug.set_period)
	GameManager.clock_updated.connect(_scorebug.update_clock)
	GameManager.game_over.connect(_on_game_over)
	GameManager.game_reset.connect(_on_game_reset)
	NetworkManager.rematch_vote_changed.connect(_votes.on_vote_changed)
	NetworkManager.rematch_voters_changed.connect(_votes.on_voters_changed)
	NetworkManager.peer_disconnected.connect(_votes.on_peer_disconnected)
	GameManager.shots_on_goal_changed.connect(_scorebug.set_shots)
	GameManager.stats_updated.connect(_stat_feed.poll)
	GameManager.player_joined.connect(func(n: String, c: Color) -> void: _toast_stack.push_pair(n, "joined", c))
	GameManager.player_left.connect(func(n: String, c: Color) -> void: _toast_stack.push_pair(n, "left", c))
	GameManager.puck_out_of_play.connect(_on_puck_out_of_play)
	GameManager.icing_called.connect(_on_icing_called)
	GameManager.goalie_freeze_called.connect(_on_goalie_freeze_called)
	GameManager.offside_called.connect(_on_offside_called)
	GameManager.local_player_hit.connect(_on_local_player_hit)
	# Arrives just before faceoff_prep_announced on the opening faceoff; the
	# countdown consumes it to lead with the matchup card.
	GameManager.pregame_intro_started.connect(_chyron.queue_intro)
	# Same idea for period / stoppage skate-ins: hold the countdown for the skate
	# window (no matchup card) so "2 → 1 → DROP" lands on the extended drop.
	GameManager.faceoff_skate_in_started.connect(_chyron.queue_skate)
	# Period-start bench intro: same hold mechanic as the matchup card, with the
	# upcoming period as the hero card ("2ND PERIOD" / "OVERTIME").
	GameManager.period_intro_started.connect(_chyron.queue_period_intro)
	GameManager.replay_started.connect(_on_replay_started)
	GameManager.replay_stopped.connect(_on_replay_stopped)
	GameManager.skip_replay_vote_updated.connect(_prompts.set_skip_votes)
	GameManager.goal_clip_available_changed.connect(_prompts.set_clip_available)
	GameManager.goal_clip_state_changed.connect(_prompts.set_clip_state)
	GameManager.goal_clip_export_finished.connect(_on_goal_clip_export_finished)
	# Prompts follow the active device: rebuild the persistent on-screen hints when
	# the mouse↔pad handoff flips (auto-disconnected when this HUD frees).
	InputDeviceTracker.device_changed.connect(_on_device_changed)
	GameManager.intermission_started.connect(_on_intermission_started)
	GameManager.intermission_clip_started.connect(_on_intermission_clip_started)
	GameManager.intermission_ended.connect(_on_intermission_ended)
	GameManager.local_spectator_state_changed.connect(func(is_spec: bool) -> void:
		_apply_spectator_chrome()
		if is_spec and _toast_stack != null:
			_toast_stack.push(_spectator_controls_hint(), MenuStyle.BROADCAST_CREAM))
	_apply_spectator_chrome()
	# Catch the case where the local peer entered the scene already a
	# spectator (lobby-assigned slot) — the signal was emitted before this
	# HUD's connect, so push the toast inline.
	if GameManager.is_local_spectator() and _toast_stack != null:
		_toast_stack.push(_spectator_controls_hint(), MenuStyle.BROADCAST_CREAM)

# Spectator camera-control hint, resolved to the active device. Pad: Y cycles the
# camera mode, D-pad ↑↓ switches the followed player, the right stick free-looks
# (see CameraDirector's joypad binds + FreeCamera's pad path). Keyboard: C / ↑↓ /
# RMB-drag.
func _spectator_controls_hint() -> String:
	return ControllerGlyphs.prompt(
			"C: camera  ·  ↑↓: player  ·  RMB drag: look",
			"%s: camera  ·  ↑↓: player  ·  Right-stick: look" % ControllerGlyphs.joy_label(JOY_BUTTON_Y))

func _unhandled_input(event: InputEvent) -> void:
	var menu_open: bool = _confirm_dialog.visible or _pause_menu.visible or _side_menu.visible
	# Pad ping: the rebindable pad button (D-pad Up by default). Only fires — and
	# only consumes — when no menu owns the screen, so the D-pad still navigates an
	# open menu (which the GUI would have consumed before this anyway).
	var pad_ping: bool = InputDeviceTracker.is_gamepad_active() and not menu_open \
			and event is InputEventJoypadButton and event.pressed \
			and (event as InputEventJoypadButton).button_index == PlayerPrefs.pad_button("smart_ping")
	if pad_ping:
		GameManager.try_send_smart_ping()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(&"smart_ping"):
		# Context-sensitive team ping (chat bubble + bot directive). Resolution
		# and all gating (spectator/replay/cooldown/no-op contexts) live in
		# GameManager.try_send_smart_ping; the HUD only swallows the press when
		# a menu owns the screen.
		if not menu_open:
			GameManager.try_send_smart_ping()
		get_viewport().set_input_as_handled()
		return
	# Save the goal clip as a GIF: F (keyboard) or pad X. Consumes the press only
	# when it actually acts, so X keeps its gameplay/menu meanings everywhere
	# else — unlike the skip binds below, this isn't the only thing X could mean
	# in the window.
	var pad_save_clip: bool = InputDeviceTracker.is_gamepad_active() \
			and event is InputEventJoypadButton and event.pressed \
			and (event as InputEventJoypadButton).button_index == JOY_BUTTON_X
	if (event.is_action_pressed(&"save_goal_clip") or pad_save_clip) \
			and not menu_open and GameManager.can_export_goal_clip():
		GameManager.request_goal_clip_export()
		get_viewport().set_input_as_handled()
		return
	# Skip vote: Space (keyboard) or pad A. A is the pad's block during play, but a
	# skip is gated on a skippable window (goal cinematic / intermission) where
	# gameplay input is blocked, so reusing it as the "confirm skip" button is safe
	# and needs no free button. Hardcoded like the Start menu-open below (an
	# InputMap joypad bind would be wiped by keyboard-rebind's action_erase_events).
	var pad_skip: bool = InputDeviceTracker.is_gamepad_active() and event is InputEventJoypadButton \
			and event.pressed and (event as InputEventJoypadButton).button_index == JOY_BUTTON_A
	if event.is_action_pressed(&"skip_replay") or pad_skip:
		# Gate on the skip-prompt visibility (goal cinematic — the HUD's own
		# label; intermission — the overlay's line) so the (Space-shared) brake
		# key never accidentally fires a vote outside of a skippable window.
		var skippable: bool = _prompts.skip_visible() \
				or (_intermission_overlay != null and _intermission_overlay.visible)
		if skippable:
			GameManager.request_local_skip_vote()
			get_viewport().set_input_as_handled()
		return
	# Menu OPEN is keyboard Escape or gamepad Start — NOT gamepad B (ui_cancel):
	# B stays a gameplay input (brake) and is only used to back OUT of an open menu.
	var kb_open: bool = event.is_action_pressed(&"ui_cancel") and not (event is InputEventJoypadButton)
	var pad_open: bool = event is InputEventJoypadButton and event.pressed \
			and (event as InputEventJoypadButton).button_index == JOY_BUTTON_START
	if not (kb_open or pad_open):
		return
	if _confirm_dialog.visible or _pause_menu.visible or _side_menu.visible:
		return
	if _game_over_popup.visible:
		# The game-over popup is persistent chrome, not a dismissable modal —
		# closing it would strand the player with no post-game actions. Esc
		# instead opens the pause menu over it so Options stays reachable.
		_pause_menu.open()
		get_viewport().set_input_as_handled()
		return
	if NetworkManager.is_free_play_mode:
		_side_menu.open()
	else:
		_pause_menu.open()
	get_viewport().set_input_as_handled()

# ---------------------------------------------------------------------------
# Build helpers
# ---------------------------------------------------------------------------

# Persistent banner shown on spectator clients only. Sits centered at the top
# of the screen, above the phase banner area. Toggled by _apply_spectator_chrome.
func _build_spectator_banner() -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = MenuStyle.BROADCAST_BG
	style.set_corner_radius_all(4)
	style.border_color = MenuStyle.BROADCAST_BORDER_T
	style.border_width_top = 1
	style.anti_aliasing = false
	style.set_content_margin(SIDE_LEFT, 14)
	style.set_content_margin(SIDE_RIGHT, 14)
	style.set_content_margin(SIDE_TOP, 4)
	style.set_content_margin(SIDE_BOTTOM, 4)

	_spectator_banner = PanelContainer.new()
	_spectator_banner.add_theme_stylebox_override("panel", style)
	_spectator_banner.add_child(HudChrome.lbl("SPECTATING", 20, MenuStyle.GOLD))
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

	_scale_root.add_child(root)
	_spectator_wrapper.visible = false

# Hides local-only menu options (Rematch, Change Position) when the local peer
# is a spectator and shows the spectator banner.
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

# Top-down rink minimap, bottom-left corner. Lives under _scale_root so it honors
# the HUD-scale pref and anchors to the true screen corner; it self-gates on
# PlayerPrefs.minimap_enabled (drawing nothing when off), so no visibility wiring
# is needed here.
func _build_minimap() -> void:
	var minimap := Minimap.new()
	_scale_root.add_child(minimap)

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
	# Mouse affordance only: its focus stylebox is deliberately transparent, so if
	# it stayed focusable the D-pad could wander onto it out of an open menu and
	# the ring would simply vanish. The pad reaches the reporter through the side
	# menu footer / pause menu instead.
	btn.focus_mode = Control.FOCUS_NONE
	btn.anchor_left = 1.0
	btn.anchor_right = 1.0
	btn.anchor_top = 1.0
	btn.anchor_bottom = 1.0
	btn.offset_left = -36.0
	btn.offset_right = -8.0
	btn.offset_top = -52.0
	btn.offset_bottom = -24.0
	btn.pressed.connect(_on_bug_report_pressed)
	_scale_root.add_child(btn)

func _build_version_tag() -> void:
	var label := HudChrome.lbl("v%s" % BuildInfo.VERSION, 11, MenuStyle.BROADCAST_DIM)
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
	_scale_root.add_child(label)

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

var _hud_scale_applied: float = -1.0
var _hud_scale_viewport: Vector2i = Vector2i.ZERO

func _process(_delta: float) -> void:
	_update_hud_scale()
	_update_shot_speed_toast_hook()
	_ghost_banner.update()


# Keeps puck_release_requested from the CURRENT local controller connected.
# Polled per frame (re-fetching the record each time) because the local
# controller changes across respawns, session changes, and spectator swaps —
# the comparison is a no-op except on the frame it actually changes.
func _update_shot_speed_toast_hook() -> void:
	# Debug-build only — never connects (and so never toasts) in a release export.
	if not debug_shot_speed_toast or not OS.is_debug_build():
		return
	var record: PlayerRecord = GameManager.get_local_player()
	var controller: SkaterController = record.controller if record != null else null
	if controller == _shot_toast_controller:
		return
	if _shot_toast_controller != null and is_instance_valid(_shot_toast_controller):
		_shot_toast_controller.puck_release_requested.disconnect(_on_local_shot_released)
		_shot_toast_controller.one_timer_release_requested.disconnect(_on_local_one_timer_released)
	_shot_toast_controller = controller
	if controller != null:
		controller.puck_release_requested.connect(_on_local_shot_released)
		controller.one_timer_release_requested.connect(_on_local_one_timer_released)


# The leniency one-timer releases through its own signal; it's a slapper.
func _on_local_one_timer_released(direction: Vector3, power: float) -> void:
	_on_local_shot_released(direction, power, true)


func _on_local_shot_released(_direction: Vector3, power: float, is_slapper: bool) -> void:
	if _toast_stack == null or _shot_toast_controller == null:
		return
	var family_max: float = _shot_toast_controller.max_slapper_power if is_slapper \
			else _shot_toast_controller.max_wrister_power
	var mph: float = power * 2.23694
	var pct: float = 100.0 * power / maxf(family_max, 0.001)
	var text: String = "SHOT · %.0f MPH · %.0f%%" % [mph, pct]
	# FH/BH is a wrister-only concept (quick passes take no penalty, there is
	# no backhand slapper) — gate on !is_slapper so a leniency one-timer can't
	# surface a stale hand from an earlier wrister.
	if not is_slapper and _shot_toast_controller.last_release_hand != "":
		text += " · " + _shot_toast_controller.last_release_hand
		# Stroke travel behind the release (charged wristers only, -1 for the
		# rest) — the calibration readout for wrister_full_stroke_travel: an
		# honest sweep should land at/past it, a twitch far under.
		var travel: float = _shot_toast_controller.last_release_stroke_travel
		if travel >= 0.0 and is_finite(travel):
			text += " · %.2fM" % travel
	_toast_stack.push(text, MenuStyle.BROADCAST_CREAM)


# Applies PlayerPrefs.hud_scale by sizing _scale_root to a virtual viewport of
# (vp / s) and scaling it up by s about the top-left: (vp/s)·s always fills the
# screen exactly, so edge-anchored widgets stay glued to the true screen edges
# at ANY scale. Never scale the whole CanvasLayer instead: scaled about the
# viewport center it is wider than the screen for s > 1, and no offset can keep
# both edges visible. The dirty-check keeps the steady state at one float + one
# Vector2i compare per frame. Menus/dialogs (own CanvasLayers) and the
# off-screen player indicators (drawn at unprojected screen coordinates) sit
# outside the root and are unaffected.
func _update_hud_scale() -> void:
	var s: float = PlayerPrefs.hud_scale
	var vp: Vector2i = Vector2i(get_viewport().get_visible_rect().size)
	if is_equal_approx(s, _hud_scale_applied) and vp == _hud_scale_viewport:
		return
	_hud_scale_applied = s
	_hud_scale_viewport = vp
	_scale_root.scale = Vector2(s, s)
	_scale_root.size = Vector2(vp) / s


# ---------------------------------------------------------------------------
# Signal handlers
# ---------------------------------------------------------------------------

func _on_goal_scored(scoring_team: Team, scorer_name: String, assist1_name: String, assist2_name: String) -> void:
	# Pull the scoring team's contrast pair: primary fills the panels/flashes,
	# secondary tints every piece of text on top so the whole goal moment
	# reads as that team's broadcast wash.
	var team_colors: Dictionary = TeamColorRegistry.get_colors(
			GameManager.teams[scoring_team.team_id].color_slot, scoring_team.team_id)
	var team_primary: Color = team_colors.primary
	var team_secondary: Color = team_colors.secondary

	_scorebug.celebrate_goal(scoring_team.team_id, team_primary)
	# Two-beat goal moment, broadcast-style:
	#   1. Top wash slides in over the scorebug ("G O A L"), then dismisses.
	#   2. During the replay phase, the lower-third chyron appears with the
	#      data (GOAL SCORED BY / <scorer> / ASSISTED BY / <assists>).
	_chyron.play_wash(team_primary, team_secondary, _scorebug.panel_size())
	_chyron.preload_goal(scorer_name, assist1_name, assist2_name,
			team_primary, team_secondary)
	_flash_overlay.flash(team_primary)

func _on_team_colors_ready(_home_primary: Color, _home_secondary: Color, _away_primary: Color, _away_secondary: Color) -> void:
	_scorebug.refresh_team_colors()

func _on_scorebug_warning_toast(text: String, color: Color) -> void:
	if _toast_stack != null:
		_toast_stack.push(text, color)

func _on_replay_started() -> void:
	_chyron.on_replay_started()
	# Vote counters are reset in _on_replay_stopped from the previous clip;
	# we don't clear them here because GameManager's host-side broadcast of
	# (0, total) may run before this listener and we'd clobber the count.
	_prompts.show_skip()

func _on_replay_stopped() -> void:
	_chyron.on_replay_stopped()
	_prompts.hide_skip()

# The intermission overlay draws its own skip line (the HUD label would sit
# under its scrim); keep it fed with the same tally.
func _on_skip_text_changed(text: String) -> void:
	if _intermission_overlay != null and _intermission_overlay.visible:
		_intermission_overlay.set_skip_text(text)

func _on_device_changed(_is_gamepad: bool) -> void:
	_prompts.refresh_device_prompts()

func _on_goal_clip_export_finished(path: String, ok: bool) -> void:
	if _toast_stack == null:
		return
	if ok:
		# The filename carries the scorer and timestamp, which is what makes one
		# clip findable among sixty; the folder is the same every time.
		_toast_stack.push("%s  %s" % [tr("CLIP_SAVED"), path.get_file()], MenuStyle.BROADCAST_CREAM)
	else:
		_toast_stack.push(tr("CLIP_SAVE_FAILED"), HudChrome.WARN_AMBER)

# ── Intermission (between-periods highlight reel) ────────────────────────────

func _on_intermission_started(period: int, reel_seconds: float) -> void:
	# The band replaces the END-OF-PERIOD chyron; the reel is already rolling
	# behind it.
	_chyron.hide_banner()
	_intermission_overlay.present(HudChrome.intermission_title(period),
			_scorebug.home_score(), _scorebug.away_score(),
			HudChrome.team_stripe(0), HudChrome.team_stripe(1),
			reel_seconds)
	_intermission_overlay.set_skip_text(_prompts.skip_text())

func _on_intermission_clip_started(scoring_team_id: int, scorer_name: String,
		assist1_name: String, assist2_name: String) -> void:
	var assists: PackedStringArray = PackedStringArray()
	if not assist1_name.is_empty():
		assists.append(assist1_name)
	if not assist2_name.is_empty():
		assists.append(assist2_name)
	var tag_color: Color = HudChrome.team_stripe(scoring_team_id) \
			if scoring_team_id >= 0 else MenuStyle.BROADCAST_CREAM
	_intermission_overlay.set_goal_caption(
			tag_color, scorer_name, ", ".join(assists))

func _on_intermission_ended() -> void:
	_intermission_overlay.hide_overlay()
	_prompts.reset_skip_votes()

func _on_phase_changed(new_phase: int) -> void:
	match new_phase:
		GamePhase.Phase.PLAYING:
			_chyron.stop_faceoff_countdown()
			_chyron.on_play_resumed()
		GamePhase.Phase.GOAL_CELEBRATION:
			# Live celebration beat — top wash already playing via _on_goal_scored,
			# lower-third stays hidden until the replay phase fires. Clear the
			# final-10 countdown if a goal interrupts the dying seconds.
			_scorebug.hide_clock_warning()
		GamePhase.Phase.GOAL_SCORED:
			# Replay phase. Chyron is driven by _on_replay_started, not by this
			# signal — wait for that.
			pass
		GamePhase.Phase.FACEOFF_PREP:
			# Banner + countdown are driven by faceoff_prep_announced (reliable
			# RPC) so they can't appear before the skater teleport on a client.
			pass
		GamePhase.Phase.FACEOFF:
			# Drop instant: hold "DROP!" briefly, then dismiss on PLAYING.
			# No whistle here — refs whistle to stop play, not to start it.
			_chyron.stop_faceoff_countdown()
			_chyron.show_hero("DROP!")
		GamePhase.Phase.END_OF_PERIOD:
			_chyron.stop_faceoff_countdown()
			_scorebug.hide_clock_warning()
			_chyron.clear_goal_template()
			_flash_period_end()
			_chyron.show_hero("END OF PERIOD")
		GamePhase.Phase.GAME_OVER:
			_chyron.stop_faceoff_countdown()
			_scorebug.hide_clock_warning()
			_flash_period_end()
			_chyron.show_at_rest()  # text + color set by _on_game_over
		_:
			_chyron.clear_goal_template()
			_chyron.show_hero("FACEOFF")


func _on_faceoff_prep_announced() -> void:
	# A reel-less (scoreless) break's band has no intermission_ended to dismiss
	# it — the next prep is its exit. Idempotent for reel breaks (already hidden).
	_on_intermission_ended()
	_chyron.begin_faceoff_prep()


# Compose the opening matchup rosters from the live registry: one column per
# team in slot order. The overlay reads name / number / attribute build off
# the records itself.
func _show_matchup_overlay() -> void:
	var home_records: Array[PlayerRecord] = []
	var away_records: Array[PlayerRecord] = []
	for record: PlayerRecord in GameManager.get_players().values():
		if record.team.team_id == 0:
			home_records.append(record)
		else:
			away_records.append(record)
	var by_slot: Callable = func(a: PlayerRecord, b: PlayerRecord) -> bool:
		return a.team_slot < b.team_slot
	home_records.sort_custom(by_slot)
	away_records.sort_custom(by_slot)
	_matchup_overlay.present(home_records, away_records,
			HudChrome.team_stripe(0), HudChrome.team_stripe(1))

func _hide_matchup_overlay() -> void:
	if _matchup_overlay != null:
		_matchup_overlay.hide_overlay()


func _on_puck_out_of_play() -> void:
	if _toast_stack != null:
		_toast_stack.push("PUCK OUT OF PLAY", MenuStyle.BROADCAST_CREAM)


func _on_icing_called() -> void:
	if _toast_stack != null:
		_toast_stack.push("ICING", MenuStyle.BROADCAST_CREAM)


func _on_goalie_freeze_called() -> void:
	if _toast_stack != null:
		_toast_stack.push("GOALIE FREEZES IT", MenuStyle.BROADCAST_CREAM)


func _on_offside_called() -> void:
	if _toast_stack != null:
		_toast_stack.push("OFFSIDE", MenuStyle.BROADCAST_CREAM)

# Gold screen flash when a period (or the game) ends — a visual partner to the
# period buzzer, which GameManager already fires on these same phases.
func _flash_period_end() -> void:
	if _flash_overlay != null:
		_flash_overlay.flash(MenuStyle.GOLD, 0.35, 0.5)

# The final-horn beat plays on the ice first (gold flash + "HOME WINS" chyron
# via _on_phase_changed / here), then the full end-of-game screen takes over.
# This delay is that breath; the presentation tween is killed by _on_game_reset
# if a rematch fires inside the window.
const _GAME_OVER_PRESENT_DELAY: float = 2.2
var _game_over_present_tween: Tween = null

func _on_game_over() -> void:
	var result_text: String
	var result_color: Color
	if _scorebug.home_score() > _scorebug.away_score():
		result_text = "HOME WINS"
		result_color = HudChrome.team_primary(0)
	elif _scorebug.away_score() > _scorebug.home_score():
		result_text = "AWAY WINS"
		result_color = HudChrome.team_primary(1)
	else:
		result_text = "TIE GAME"
		result_color = MenuStyle.BROADCAST_CREAM
	_chyron.show_final(result_text, result_color)
	_votes.reset()
	if _game_over_present_tween != null and _game_over_present_tween.is_running():
		_game_over_present_tween.kill()
	_game_over_present_tween = create_tween()
	_game_over_present_tween.tween_interval(_GAME_OVER_PRESENT_DELAY)
	_game_over_present_tween.tween_callback(
			_present_game_over_screen.bind(result_text, result_color))

func _present_game_over_screen(result_text: String, result_color: Color) -> void:
	# The screen carries the same FINAL info, so the chyron behind it retires.
	_chyron.hide_banner()
	# Up to three ranked stars; zero-stat players never star, so a quiet game
	# shows fewer (or none — the whole stars block stays hidden).
	var star_names: Array[String] = []
	var star_lines: Array[String] = []
	var star_stripes: Array[Color] = []
	for star: PlayerRecord in GameManager.get_stars_of_game():
		star_names.append(star.display_name())
		if star.is_goalie:
			var opp: int = 1 - star.team.team_id
			star_lines.append(_goalie_star_line(GameManager.get_team_shots(opp),
					_scorebug.away_score() if opp == 1 else _scorebug.home_score()))
		else:
			star_lines.append(_star_stat_line(star.stats))
		star_stripes.append(HudChrome.team_stripe(star.team.team_id))
	_game_over_popup.present(_scorebug.home_score(), _scorebug.away_score(),
			HudChrome.team_stripe(0), HudChrome.team_stripe(1),
			result_text, result_color,
			star_names, star_lines, star_stripes)

# Compact stat line for a star row. Scorers show goals/assists (plus the GWG
# tag — the clutch credit the selection weighted); a star who earned it on
# volume/defense (a 0-point grinder game) shows those instead.
func _star_stat_line(stats: PlayerStats) -> String:
	var parts: PackedStringArray = PackedStringArray()
	if stats.goals > 0:
		parts.append("%dG" % stats.goals)
	if stats.assists > 0:
		parts.append("%dA" % stats.assists)
	if stats.game_winning_goals > 0:
		parts.append("GWG")
	if parts.is_empty():
		if stats.shots_on_goal > 0:
			parts.append("%d SOG" % stats.shots_on_goal)
		if stats.shots_blocked > 0:
			parts.append("%d BLK" % stats.shots_blocked)
		if stats.takeaways > 0:
			parts.append("%d TKA" % stats.takeaways)
		if stats.hits > 0:
			parts.append("%d HITS" % stats.hits)
	return " · ".join(parts)


# Saves line for a starred goalie: save count + save percentage in the
# broadcast ".900" style, or the shutout tag when nothing got through. Shots
# on goal include goals (NHL convention), so saves = shots faced − GA.
func _goalie_star_line(shots_faced: int, goals_against: int) -> String:
	var saves: int = maxi(0, shots_faced - goals_against)
	if goals_against == 0:
		return "%d SV · SO" % saves
	if shots_faced <= 0:
		return ""
	var pct: String = ("%.3f" % (float(saves) / float(shots_faced))).trim_prefix("0")
	return "%d SV · %s" % [saves, pct]

func _on_game_reset() -> void:
	if _game_over_present_tween != null and _game_over_present_tween.is_running():
		_game_over_present_tween.kill()
	_game_over_present_tween = null
	_game_over_popup.hide_popup()
	if _post_game_analytics != null:
		_post_game_analytics.close()
	if _pause_menu != null:
		_pause_menu.close()
	if _side_menu != null:
		_side_menu.close()

func _on_rematch_vote_pressed() -> void:
	_votes.toggle_local(RematchVoteRules.Choice.REMATCH)

func _on_lobby_vote_pressed() -> void:
	_votes.toggle_local(RematchVoteRules.Choice.LOBBY)

func _on_vote_tally_changed(votes: Dictionary, total: int, local_vote: int) -> void:
	_game_over_popup.update_votes(votes, total, local_vote)

func _on_vote_resolved(choice: int) -> void:
	match choice:
		RematchVoteRules.Choice.REMATCH:
			GameManager.reset_game()
		RematchVoteRules.Choice.LOBBY:
			GameManager.return_to_lobby()

# Drop to solo free play. For an online host this tears down the server, so the
# confirm spells out that it ends the match for everyone.
func _on_game_over_free_play() -> void:
	var msg: String = "Return to free play?"
	if NetworkManager.is_host and not NetworkManager.is_offline_mode:
		msg = "Return to free play? This ends the match for everyone."
	_show_confirm(msg, func() -> void:
		await NetworkManager.announce_match_end()
		GameManager.return_to_free_play())

# Opens the post-game analytics views (shot map / tale of the tape / xG flow)
# over the game-over screen. Reads only local per-game data, so it works
# identically offline and online.
func _on_game_over_analytics() -> void:
	if _post_game_analytics != null:
		_post_game_analytics.present()


func _on_game_over_exit() -> void:
	_show_confirm("Exit game?", func() -> void:
		await NetworkManager.announce_match_end()
		GameManager.on_scene_exit()
		NetworkManager.reset()
		get_tree().quit())

# `background` is the menu that raised it (null for the mouse-only HUD icon,
# which has no menu behind it) — walled off so the pad stays in the dialog.
func _on_bug_report_pressed(background: Control = null) -> void:
	_bug_dialog.open(background)

func _on_local_player_hit(magnitude: float) -> void:
	if magnitude < 3.0:
		return
	var strength := clampf(magnitude / 12.0, 0.2, 0.55)
	_flash_overlay.vignette_pulse(strength)

func _on_stat_feed_event(subject: String, detail: String, color: Color) -> void:
	if _toast_stack != null:
		_toast_stack.push_pair(subject, detail, color)
