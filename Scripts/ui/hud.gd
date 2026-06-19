class_name HUD
extends CanvasLayer

var _period_label: Label
var _clock_label: Label
var _home_score_label: Label
var _away_score_label: Label
var _phase_panel: PanelContainer
var _phase_wrapper: Control
var _scorebug_panel: PanelContainer = null
var _top_goal_banner: Control = null
var _top_goal_main_panel: PanelContainer = null
var _top_goal_panel_style: StyleBoxFlat = null
var _top_goal_label: Label = null
var _top_goal_tween: Tween = null
var _phase_label: Label
var _tagline_label: Label
var _scorer_label: Label
var _assist_tag_label: Label
var _assist_label: Label
var _phase_style: StyleBoxFlat
var _game_over_popup: GameOverPopup = null
var _pause_menu: PauseMenu = null
var _side_menu: SideMenu = null
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
var _clock_warning_label: Label = null
var _warned_one_min: bool = false
var _warned_thirty: bool = false
var _last_warning_pulse_second: int = -1
var _confirm_dialog: ConfirmDialog = null
var _confirm_callback: Callable = Callable()
var _rematch_votes: Dictionary[int, bool] = {}
var _local_voted: bool = false
var _phase_banner_root: Control = null
var _phase_slide_tween: Tween = null
var _faceoff_countdown_tween: Tween = null
var _skip_prompt_label: Label = null
var _skip_prompt_tween: Tween = null
var _menu_hint_label: Label = null
var _menu_hint_tween: Tween = null
var _skip_vote_current: int = 0
var _skip_vote_total: int = 0
var _spectator_banner: PanelContainer = null
var _spectator_wrapper: Control = null
var _fps_label: Label = null
var _stamina_root: Control = null
var _stamina_fill: ColorRect = null

const _STAMINA_W: float = 240.0
const _STAMINA_H: float = 12.0
const _STAMINA_NORMAL := MenuStyle.HUD_RING_SELF             # matches your own skater ring color
const _STAMINA_LOW    := Color(0.95, 0.65, 0.20, 1.0)        # amber when running low
const _STAMINA_LOCKED := MenuStyle.DANGER                    # red while exhausted

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
	_build_clock_warning()
	_build_top_goal_banner()
	_build_version_tag()
	_build_fps_label()
	_build_stamina_bar()
	_build_bug_icon()
	_build_skip_replay_prompt()
	_bug_dialog = BugReportDialog.new()
	add_child(_bug_dialog)
	_game_over_popup = GameOverPopup.new()
	_game_over_popup.rematch_toggled.connect(_on_rematch_vote_pressed)
	_game_over_popup.host_action_pressed.connect(_on_game_over_host_action)
	_game_over_popup.free_play_pressed.connect(_on_game_over_free_play)
	_game_over_popup.exit_pressed.connect(_on_game_over_exit)
	add_child(_game_over_popup)
	_pause_menu = PauseMenu.new()
	_pause_menu.opened.connect(func() -> void: GameManager.set_input_blocked(true))
	_pause_menu.closed.connect(func() -> void: GameManager.set_input_blocked(false))
	add_child(_pause_menu)
	_side_menu = SideMenu.new()
	_side_menu.opened.connect(func() -> void: GameManager.set_input_blocked(true))
	_side_menu.closed.connect(func() -> void: GameManager.set_input_blocked(false))
	add_child(_side_menu)
	# Free play IS the main menu, so land with the SideMenu open (it's obvious
	# one exists) and keep a pulsing "[ESC] MENU" affordance up whenever it's
	# closed. Only in free play — a real match uses the PauseMenu instead.
	if NetworkManager.is_free_play_mode:
		_build_menu_hint()
		_side_menu.opened.connect(_hide_menu_hint)
		_side_menu.closed.connect(_show_menu_hint)
		_side_menu.open()
	_confirm_dialog = ConfirmDialog.new()
	_confirm_dialog.confirmed.connect(_on_confirm_dialog_confirmed)
	_confirm_dialog.cancelled.connect(_on_confirm_dialog_cancelled)
	add_child(_confirm_dialog)
	_toast_stack = ToastStack.new()
	add_child(_toast_stack)
	# Surface the connection error from whatever session dumped us back here
	# (host quit, join failed, timed out, kicked). pending_error is written
	# right before return_to_free_play() and was previously read by nothing —
	# every connection failure was a silent teleport to free play.
	if not NetworkManager.pending_error.is_empty():
		_toast_stack.push(NetworkManager.pending_error, Color(0.95, 0.55, 0.5))
		NetworkManager.pending_error = ""
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
	GameManager.faceoff_prep_announced.connect(_on_faceoff_prep_announced)
	GameManager.period_changed.connect(_on_period_changed)
	GameManager.clock_updated.connect(_on_clock_updated)
	GameManager.game_over.connect(_on_game_over)
	GameManager.game_reset.connect(_on_game_reset)
	NetworkManager.rematch_vote_changed.connect(_on_rematch_vote_changed)
	NetworkManager.peer_disconnected.connect(_on_rematch_peer_disconnected)
	GameManager.shots_on_goal_changed.connect(_on_shots_on_goal_changed)
	GameManager.player_joined.connect(func(n: String, c: Color) -> void: _toast_stack.push(n + " joined", c))
	GameManager.player_left.connect(func(n: String, c: Color) -> void: _toast_stack.push(n + " left", c))
	GameManager.puck_out_of_play.connect(_on_puck_out_of_play)
	GameManager.icing_called.connect(_on_icing_called)
	GameManager.offside_called.connect(_on_offside_called)
	GameManager.local_player_hit.connect(_on_local_player_hit)
	GameManager.replay_started.connect(_on_replay_started)
	GameManager.replay_stopped.connect(_on_replay_stopped)
	GameManager.skip_replay_vote_updated.connect(_on_skip_replay_vote_updated)
	GameManager.local_spectator_state_changed.connect(func(is_spec: bool) -> void:
		_apply_spectator_chrome()
		if is_spec and _toast_stack != null:
			_toast_stack.push("C: camera  ·  ↑↓: player  ·  RMB drag: look", _WHITE))
	_apply_spectator_chrome()
	# Catch the case where the local peer entered the scene already a
	# spectator (lobby-assigned slot) — the signal was emitted before this
	# HUD's connect, so push the toast inline.
	if GameManager.is_local_spectator() and _toast_stack != null:
		_toast_stack.push("C: camera  ·  ↑↓: player  ·  RMB drag: look", _WHITE)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"skip_replay"):
		# Gate on the skip-prompt visibility so the (Space-shared) brake key
		# never accidentally fires a vote outside of the cinematic window.
		if _skip_prompt_label != null and _skip_prompt_label.visible:
			GameManager.request_local_skip_vote()
			get_viewport().set_input_as_handled()
		return
	if not event.is_action_pressed(&"ui_cancel"):
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

func _build_scorebug() -> void:
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = _DARK_BG
	panel_style.set_corner_radius_all(4)
	panel_style.border_color = MenuStyle.BROADCAST_BORDER_T
	panel_style.border_width_top = 1

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", panel_style)
	_scorebug_panel = panel
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
	# Stripes are anchored inside the rows but bleed past the row bounds so
	# they hug the panel's full left edge top-to-bottom. The top stripe gets
	# the panel's top-left curve, the bottom stripe gets the bottom-left
	# curve; they meet flush at the midpoint of the inter-row separation.
	var away_row := _build_scorebug_team_row(1, "AWAY")
	_away_badge_style = away_row.get_meta(&"stripe_style") as StyleBoxFlat
	_away_score_label = away_row.get_meta(&"score_label") as Label
	var away_stripe: Panel = away_row.get_meta(&"stripe") as Panel
	_away_badge_style.corner_radius_top_left = 4
	away_stripe.offset_top = -5
	away_stripe.offset_bottom = 2
	teams_vbox.add_child(away_row)
	var home_row := _build_scorebug_team_row(0, "HOME")
	_home_badge_style = home_row.get_meta(&"stripe_style") as StyleBoxFlat
	_home_score_label = home_row.get_meta(&"score_label") as Label
	var home_stripe: Panel = home_row.get_meta(&"stripe") as Panel
	_home_badge_style.corner_radius_bottom_left = 4
	home_stripe.offset_top = -2
	home_stripe.offset_bottom = 4
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
	# Placeholder reserves the 6px column in the HBox; the visible stripe
	# is anchored inside it so the caller can bleed it past the row bounds
	# (offset_top / offset_bottom) to hug the scorebug panel's true edges
	# — same pattern slot_grid_panel.gd uses for the lobby card stripes.
	var stripe_slot := Control.new()
	stripe_slot.custom_minimum_size = Vector2(6, 28)
	stripe_slot.size_flags_vertical = Control.SIZE_FILL
	stripe_slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(stripe_slot)
	var stripe := Panel.new()
	stripe.add_theme_stylebox_override("panel", stripe_style)
	stripe.set_anchors_preset(Control.PRESET_FULL_RECT)
	stripe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stripe_slot.add_child(stripe)

	var abbr_margin := MarginContainer.new()
	abbr_margin.add_theme_constant_override("margin_left", 8)
	abbr_margin.add_theme_constant_override("margin_right", 4)
	row.add_child(abbr_margin)
	var abbr_label := _lbl(abbr, 18, _WHITE)
	abbr_label.custom_minimum_size = Vector2(50, 0)
	abbr_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	abbr_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	abbr_margin.add_child(abbr_label)

	# Center-aligned in a fixed-width slot so single- vs two-digit scores
	# don't drift visually (right-alignment made "1" read as offset from
	# "0" because the glyphs have different widths).
	var score_margin := MarginContainer.new()
	score_margin.add_theme_constant_override("margin_left", 4)
	score_margin.add_theme_constant_override("margin_right", 8)
	row.add_child(score_margin)
	var score_label := _lbl("0", 26, _WHITE)
	score_label.custom_minimum_size = Vector2(36, 0)
	score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	score_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	score_margin.add_child(score_label)

	row.set_meta(&"stripe_style", stripe_style)
	row.set_meta(&"stripe", stripe)
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
	_phase_banner_root = root
	add_child(root)

	var centering := CenterContainer.new()
	centering.set_anchors_preset(Control.PRESET_FULL_RECT)
	centering.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(centering)

	# 4px rounded corners to match the scorebug — single visual language across
	# the HUD chrome. No top border line: a thin border that has to follow the
	# corner curve reads as a competing stripe over the chyron's bold team-color
	# fill, which is what the "double-curve" complaint was actually pointing at.
	_phase_style = StyleBoxFlat.new()
	_phase_style.bg_color = MenuStyle.BROADCAST_BG
	_phase_style.set_corner_radius_all(4)
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

	# Tagline (e.g. "GOAL SCORED BY" / "FINAL") — small label above the hero
	# row, only visible for events that have a hero subject (goal scorer,
	# game-over winner). Hidden for FACEOFF / END OF PERIOD where the phase
	# label itself is the hero. Color is re-tinted per-goal in _on_goal_scored
	# to the scoring team's secondary; the WHITE default is just the fallback
	# for non-team contexts.
	_tagline_label = _lbl("", 16, _WHITE)
	_tagline_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tagline_label.visible = false
	vbox.add_child(_tagline_label)

	# Hero row for non-goal phases: "FACEOFF" / "END OF PERIOD" / "HOME WINS"
	_phase_label = _lbl("", 44, _WHITE)
	_phase_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_phase_label)

	# Hero row for goal phase: the scorer's name, big and bold. Color is
	# overridden per-goal to the scoring team's secondary color in
	# _on_goal_scored.
	_scorer_label = _lbl("", 52, _WHITE)
	_scorer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_scorer_label.visible = false
	vbox.add_child(_scorer_label)

	# "ASSISTED BY" tag — secondary tagline between the hero and the assist
	# names. Hidden when there are no assists.
	_assist_tag_label = _lbl("ASSISTED BY", 16, _WHITE)
	_assist_tag_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_assist_tag_label.visible = false
	vbox.add_child(_assist_tag_label)

	# Assist player names (e.g. "PLAYER1  /  PLAYER2") — sub-hero row
	_assist_label = _lbl("", 24, _WHITE)
	_assist_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_assist_label.visible = false
	vbox.add_child(_assist_label)

# "GOAL" wash banner — slides in from the left and overlays the scorebug for
# the dramatic moment of a goal. Lower-third phase chyron with scorer/assist
# info appears separately during the replay phase. Built once at _ready and
# kept hidden; _play_top_goal_banner drives the slide-in/hold/slide-out
# animation when a goal fires.
func _build_top_goal_banner() -> void:
	# bg_color is a placeholder; _play_top_goal_banner re-tints the whole panel
	# in the scoring team's primary color per goal, so the entire bar reads as
	# that team's wash overlaying the scorebug.
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = MenuStyle.BROADCAST_BG
	panel_style.set_corner_radius_all(4)
	panel_style.anti_aliasing = false
	_top_goal_panel_style = panel_style

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", panel_style)
	_top_goal_main_panel = panel

	var text_margin := MarginContainer.new()
	text_margin.add_theme_constant_override("margin_left", 14)
	text_margin.add_theme_constant_override("margin_right", 14)
	text_margin.add_theme_constant_override("margin_top", 8)
	text_margin.add_theme_constant_override("margin_bottom", 8)
	panel.add_child(text_margin)
	_top_goal_label = _lbl("G  O  A  L", 32, _WHITE)
	_top_goal_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_top_goal_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	text_margin.add_child(_top_goal_label)

	_top_goal_banner = MenuStyle.wrap_drop_shadow(panel, Vector2(4, 4))
	_top_goal_banner.position = Vector2(8, 8)
	_top_goal_banner.visible = false
	add_child(_top_goal_banner)

func _play_top_goal_banner(primary: Color, secondary: Color) -> void:
	if _top_goal_tween != null and _top_goal_tween.is_running():
		_top_goal_tween.kill()
	_top_goal_panel_style.bg_color = primary
	_top_goal_label.add_theme_color_override("font_color", secondary)
	# Match the scorebug's current rendered size so the wash overlays it
	# pixel-exact, regardless of font / margin / scoreboard-content drift.
	if _scorebug_panel != null and _scorebug_panel.size != Vector2.ZERO:
		_top_goal_main_panel.custom_minimum_size = _scorebug_panel.size
	# Off-screen left of the screen edge so the slide-in feels like it enters
	# the frame from outside the viewport, not from a halfway position.
	_top_goal_banner.position = Vector2(-300, 8)
	_top_goal_banner.visible = true
	_top_goal_tween = create_tween()
	_top_goal_tween.tween_property(_top_goal_banner, "position:x", 8.0, 0.4) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_top_goal_tween.tween_interval(2.0)
	_top_goal_tween.tween_property(_top_goal_banner, "position:x", -300.0, 0.4) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_top_goal_tween.tween_callback(func() -> void: _top_goal_banner.visible = false)

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

# Bottom-right "[SPACE] TO SKIP" prompt shown during goal replays. Lives outside
# the chyron because the skip-UX is a player affordance, not broadcast chrome —
# the broadcast chyron itself stays focused on the goal info. The pulse draws
# the eye to the prompt without yelling.
func _build_skip_replay_prompt() -> void:
	_skip_prompt_label = _lbl("[SPACE] TO SKIP", 18, _WHITE)
	_skip_prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_skip_prompt_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_skip_prompt_label.anchor_left = 1.0
	_skip_prompt_label.anchor_right = 1.0
	_skip_prompt_label.anchor_top = 1.0
	_skip_prompt_label.anchor_bottom = 1.0
	# Right edge sits at -52 so the prompt clears the bug-report icon (which
	# spans -36 to -8 from the right edge) with ~16px of breathing room.
	_skip_prompt_label.offset_left = -324.0
	_skip_prompt_label.offset_right = -52.0
	_skip_prompt_label.offset_top = -52.0
	_skip_prompt_label.offset_bottom = -24.0
	_skip_prompt_label.visible = false
	add_child(_skip_prompt_label)

func _build_menu_hint() -> void:
	_menu_hint_label = _lbl("[ESC] MENU", 16, _WHITE)
	# Bottom-center: anchored to the bottom edge, horizontally centered (a ~200px
	# box straddling the 0.5 anchor), sitting 16px above the bottom.
	_menu_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_menu_hint_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_menu_hint_label.anchor_left = 0.5
	_menu_hint_label.anchor_right = 0.5
	_menu_hint_label.anchor_top = 1.0
	_menu_hint_label.anchor_bottom = 1.0
	_menu_hint_label.offset_left = -100.0
	_menu_hint_label.offset_right = 100.0
	_menu_hint_label.offset_top = -40.0
	_menu_hint_label.offset_bottom = -16.0
	# Starts hidden — _ready opens the menu right away, which fires the opened
	# signal and keeps the hint down until the player first closes the menu.
	_menu_hint_label.visible = false
	add_child(_menu_hint_label)

func _show_menu_hint() -> void:
	if _menu_hint_label == null:
		return
	_menu_hint_label.visible = true
	if _menu_hint_tween != null and _menu_hint_tween.is_running():
		_menu_hint_tween.kill()
	_menu_hint_tween = MenuStyle.pulse(_menu_hint_label)

func _hide_menu_hint() -> void:
	if _menu_hint_label == null:
		return
	if _menu_hint_tween != null and _menu_hint_tween.is_running():
		_menu_hint_tween.kill()
	_menu_hint_tween = null
	_menu_hint_label.modulate.a = 1.0
	_menu_hint_label.visible = false

func _start_skip_prompt_pulse() -> void:
	if _skip_prompt_tween != null and _skip_prompt_tween.is_running():
		_skip_prompt_tween.kill()
	_skip_prompt_tween = MenuStyle.pulse(_skip_prompt_label)

func _stop_skip_prompt_pulse() -> void:
	if _skip_prompt_tween != null and _skip_prompt_tween.is_running():
		_skip_prompt_tween.kill()
	_skip_prompt_tween = null
	_skip_prompt_label.modulate.a = 1.0

# Slide the chyron up from below the screen on goal replays. Non-goal phases
# (FACEOFF / END OF PERIOD / GAME OVER) call _show_phase_banner_at_rest()
# instead so they appear instantly at the resting position.
func _slide_in_phase_banner() -> void:
	if _phase_slide_tween != null and _phase_slide_tween.is_running():
		_phase_slide_tween.kill()
	# Park the band below the screen, then animate up. The band height is 170
	# (offset_top -220 vs offset_bottom -50); 220 of offset moves it fully off.
	_phase_banner_root.offset_top = 0.0
	_phase_banner_root.offset_bottom = 170.0
	_phase_wrapper.visible = true
	_phase_slide_tween = create_tween().set_parallel(true)
	_phase_slide_tween.tween_property(_phase_banner_root, "offset_top", -220.0, 0.4) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_phase_slide_tween.tween_property(_phase_banner_root, "offset_bottom", -50.0, 0.4) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

func _show_phase_banner_at_rest() -> void:
	if _phase_slide_tween != null and _phase_slide_tween.is_running():
		_phase_slide_tween.kill()
	_phase_banner_root.offset_top = -220.0
	_phase_banner_root.offset_bottom = -50.0
	_phase_wrapper.visible = true

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

func _build_fps_label() -> void:
	_fps_label = _lbl("", 14, _WHITE)
	_fps_label.anchor_left = 1.0
	_fps_label.anchor_right = 1.0
	_fps_label.anchor_top = 0.0
	_fps_label.anchor_bottom = 0.0
	_fps_label.offset_left = -88.0
	_fps_label.offset_right = -8.0
	_fps_label.offset_top = 8.0
	_fps_label.offset_bottom = 28.0
	_fps_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_fps_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fps_label.visible = PlayerPrefs.show_fps
	add_child(_fps_label)

# Sprint stamina bar — a thin gauge centred along the bottom edge. Only the
# local player's stamina is shown; it's driven each frame from the local
# controller in _update_stamina_bar(). Hidden for spectators (no controller).
func _build_stamina_bar() -> void:
	_stamina_root = Control.new()
	_stamina_root.anchor_left = 0.5
	_stamina_root.anchor_right = 0.5
	_stamina_root.anchor_top = 1.0
	_stamina_root.anchor_bottom = 1.0
	_stamina_root.offset_left = -_STAMINA_W * 0.5
	_stamina_root.offset_right = _STAMINA_W * 0.5
	_stamina_root.offset_top = -44.0
	_stamina_root.offset_bottom = -44.0 + _STAMINA_H
	_stamina_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stamina_root.visible = false

	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(_DARK_BG.r, _DARK_BG.g, _DARK_BG.b, 0.72)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stamina_root.add_child(bg)

	# Fill spans 0..stamina of the root width via anchor_right; a 1px inset keeps
	# the dark background reading as a frame around it.
	_stamina_fill = ColorRect.new()
	_stamina_fill.anchor_left = 0.0
	_stamina_fill.anchor_top = 0.0
	_stamina_fill.anchor_right = 1.0
	_stamina_fill.anchor_bottom = 1.0
	_stamina_fill.offset_left = 1.0
	_stamina_fill.offset_top = 1.0
	_stamina_fill.offset_bottom = -1.0
	_stamina_fill.color = _STAMINA_NORMAL
	_stamina_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stamina_root.add_child(_stamina_fill)

	add_child(_stamina_root)

func _update_stamina_bar() -> void:
	if _stamina_root == null:
		return
	var record: PlayerRecord = GameManager.get_local_player()
	var controller: SkaterController = record.controller if record != null else null
	if controller == null:
		_stamina_root.visible = false
		return
	_stamina_root.visible = true
	var s: float = clampf(controller.stamina, 0.0, 1.0)
	# Fill width: inset by 1px on the right so it never overhangs the frame.
	_stamina_fill.offset_right = -1.0 - (1.0 - s) * (_STAMINA_W - 2.0)
	if controller.is_sprint_exhausted():
		_stamina_fill.color = _STAMINA_LOCKED
	elif s < 0.3:
		_stamina_fill.color = _STAMINA_LOW
	else:
		_stamina_fill.color = _STAMINA_NORMAL

var _hud_scale_applied: float = -1.0
var _hud_scale_viewport: Vector2i = Vector2i.ZERO

func _process(_delta: float) -> void:
	_update_hud_scale()
	var enabled: bool = PlayerPrefs.show_fps
	if _fps_label.visible != enabled:
		_fps_label.visible = enabled
	if enabled:
		_fps_label.text = "FPS: %d" % Engine.get_frames_per_second()
	_update_stamina_bar()


# Applies PlayerPrefs.hud_scale to this CanvasLayer about the viewport center,
# so edge-anchored widgets pull inward as the scale drops. Re-applies only when
# the scale or the viewport size actually changes (dirty-check), so the steady
# state costs one float + one Vector2i compare per frame. Child CanvasLayers
# (menus, dialogs, toasts) render on their own layers and are unaffected.
func _update_hud_scale() -> void:
	var s: float = PlayerPrefs.hud_scale
	var vp: Vector2i = Vector2i(get_viewport().get_visible_rect().size)
	if is_equal_approx(s, _hud_scale_applied) and vp == _hud_scale_viewport:
		return
	_hud_scale_applied = s
	_hud_scale_viewport = vp
	scale = Vector2(s, s)
	# Keep the viewport center fixed: a point p maps to s*p + offset, so the
	# center stays put when offset = center * (1 - s).
	offset = Vector2(vp) * 0.5 * (1.0 - s)


# ---------------------------------------------------------------------------
# Signal handlers
# ---------------------------------------------------------------------------

func _on_score_changed(score_0: int, score_1: int) -> void:
	_score_0 = score_0
	_score_1 = score_1
	_home_score_label.text = str(score_0)
	_away_score_label.text = str(score_1)

func _on_goal_scored(scoring_team: Team, scorer_name: String, assist1_name: String, assist2_name: String) -> void:
	# Pull the scoring team's contrast pair: primary fills the panels/flashes,
	# secondary tints every piece of text on top so the whole goal moment
	# reads as that team's broadcast wash.
	var team_colors: Dictionary = TeamColorRegistry.get_colors(
			GameManager.teams[scoring_team.team_id].color_slot, scoring_team.team_id)
	var team_primary: Color = team_colors.primary
	var team_secondary: Color = team_colors.secondary

	var score_label: Label = _away_score_label if scoring_team.team_id == 1 else _home_score_label
	score_label.add_theme_color_override("font_color", team_primary)
	var tween := create_tween()
	tween.tween_method(
		func(c: Color) -> void: score_label.add_theme_color_override("font_color", c),
		team_primary, _WHITE, 1.5)

	# Score digit pop
	score_label.pivot_offset = score_label.size / 2.0
	var pop := create_tween()
	pop.tween_property(score_label, "scale", Vector2(1.6, 1.6), 0.0)
	pop.tween_property(score_label, "scale", Vector2.ONE, 0.5) \
		.set_trans(Tween.TRANS_SPRING).set_ease(Tween.EASE_OUT)

	# Two-beat goal moment, broadcast-style:
	#   1. Top wash slides in over the scorebug ("G O A L"), then dismisses.
	#   2. During the replay phase, the lower-third chyron appears with the
	#      data (GOAL SCORED BY / <scorer> / ASSISTED BY / <assists>).
	# Here we (a) play the top wash and (b) preload the chyron labels with the
	# goal data so the replay handler can just toggle visibility.
	_play_top_goal_banner(team_primary, team_secondary)

	_tagline_label.text = "GOAL SCORED BY"
	_tagline_label.add_theme_color_override("font_color", team_secondary)
	_phase_label.visible = false
	_scorer_label.text = scorer_name
	_scorer_label.add_theme_color_override("font_color", team_secondary)
	_assist_tag_label.add_theme_color_override("font_color", team_secondary)
	_assist_label.add_theme_color_override("font_color", team_secondary)
	_phase_style.bg_color = team_primary
	if not assist1_name.is_empty():
		var assist_text: String = assist1_name
		if not assist2_name.is_empty():
			assist_text += "  /  " + assist2_name
		_assist_label.text = assist_text
	else:
		_assist_label.text = ""

	_flash_overlay.flash(team_primary)

func _initial_team_primary(team_id: int) -> Color:
	if GameManager.teams.size() > team_id:
		return TeamColorRegistry.get_colors(GameManager.teams[team_id].color_slot, team_id).primary
	return Color(0.5, 0.5, 0.5)  # placeholder; team_colors_ready overwrites

func _on_team_colors_ready(home_primary: Color, _home_secondary: Color, away_primary: Color, _away_secondary: Color) -> void:
	# In the chyron layout the AWAY/HOME labels sit on the dark panel, not on
	# the team color, so their text stays cream regardless of team palette.
	if _home_badge_style != null:
		_home_badge_style.bg_color = home_primary
	if _away_badge_style != null:
		_away_badge_style.bg_color = away_primary

func _on_replay_started() -> void:
	# Lower-third chyron with goal data appears during replay. The labels were
	# preloaded by _on_goal_scored; we slide the band up from below the screen
	# so the entry feels like a broadcast lower-third drop-in.
	_tagline_label.visible = true
	_scorer_label.visible = not _scorer_label.text.is_empty()
	_assist_tag_label.visible = not _assist_label.text.is_empty()
	_assist_label.visible = not _assist_label.text.is_empty()
	_slide_in_phase_banner()
	# Vote counters are reset in _on_replay_stopped from the previous clip;
	# we don't clear them here because GameManager's host-side broadcast of
	# (0, total) may run before this listener and we'd clobber the count.
	_refresh_skip_prompt_text()
	_skip_prompt_label.visible = true
	_start_skip_prompt_pulse()

func _on_replay_stopped() -> void:
	# Instant hide on the chyron (no slide-out): the natural follow-up is the
	# FACEOFF banner appearing in the same spot, and a slide-out would just
	# add a flicker between the two. Reset offsets so any subsequent show
	# (e.g. FACEOFF) appears at rest.
	# Skip the hide if the faceoff countdown is already up: on clients the
	# host's faceoff_positions RPC can land before our local replay's outro
	# ends, in which case _on_faceoff_prep_announced has already shown the
	# countdown and hiding the wrapper here would erase "FACEOFF IN 2".
	var faceoff_already_up: bool = _faceoff_countdown_tween != null \
			and _faceoff_countdown_tween.is_valid()
	if not faceoff_already_up:
		_phase_wrapper.visible = false
		if _phase_banner_root != null:
			_phase_banner_root.offset_top = -220.0
			_phase_banner_root.offset_bottom = -50.0
	_stop_skip_prompt_pulse()
	_skip_prompt_label.visible = false
	_skip_vote_current = 0
	_skip_vote_total = 0

func _on_skip_replay_vote_updated(current: int, total: int) -> void:
	_skip_vote_current = current
	_skip_vote_total = total
	_refresh_skip_prompt_text()

func _refresh_skip_prompt_text() -> void:
	if _skip_prompt_label == null:
		return
	if _skip_vote_total <= 1:
		# Solo session — no tally, the single press just skips.
		_skip_prompt_label.text = "[SPACE] TO SKIP"
	else:
		_skip_prompt_label.text = "[SPACE] TO SKIP  (%d/%d)" % [_skip_vote_current, _skip_vote_total]

func _on_phase_changed(new_phase: int) -> void:
	match new_phase:
		GamePhase.Phase.PLAYING:
			_stop_faceoff_countdown()
			_phase_wrapper.visible = false
			_phase_label.add_theme_color_override("font_color", _WHITE)
			_phase_style.bg_color = MenuStyle.BROADCAST_BG
			_clear_goal_template()
		GamePhase.Phase.GOAL_CELEBRATION:
			# Live celebration beat — top wash already playing via _on_goal_scored,
			# lower-third stays hidden until the replay phase fires. Clear the
			# final-10 countdown if a goal interrupts the dying seconds.
			_hide_clock_warning()
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
			_stop_faceoff_countdown()
			_phase_label.text = "DROP!"
			_phase_label.add_theme_color_override("font_color", _WHITE)
			_phase_label.visible = true
			_phase_style.bg_color = MenuStyle.BROADCAST_BG
			_show_phase_banner_at_rest()
		GamePhase.Phase.END_OF_PERIOD:
			_stop_faceoff_countdown()
			_hide_clock_warning()
			_clear_goal_template()
			_sound_period_end()
			_phase_label.text = "END OF PERIOD"
			_phase_label.add_theme_color_override("font_color", _WHITE)
			_phase_label.visible = true
			_phase_style.bg_color = MenuStyle.BROADCAST_BG
			_show_phase_banner_at_rest()
		GamePhase.Phase.GAME_OVER:
			_stop_faceoff_countdown()
			_hide_clock_warning()
			_sound_period_end()
			_show_phase_banner_at_rest()  # text + color set by _on_game_over
		_:
			_clear_goal_template()
			_phase_label.text = "FACEOFF"
			_phase_label.add_theme_color_override("font_color", _WHITE)
			_phase_label.visible = true
			_phase_style.bg_color = MenuStyle.BROADCAST_BG
			_show_phase_banner_at_rest()


# Fires on the same reliable beat that teleports the local skater to the dot,
# so the countdown banner can't appear before the skater is in position (the
# pre-fix bug: client sees "FACEOFF IN 2" while their skater is still parked
# at the post-goal position, then pops onto the dot mid-countdown).
func _on_faceoff_prep_announced() -> void:
	_clear_goal_template()
	_phase_label.add_theme_color_override("font_color", _WHITE)
	_phase_label.visible = true
	_phase_style.bg_color = MenuStyle.BROADCAST_BG
	_show_phase_banner_at_rest()
	_start_faceoff_countdown()


# Drives a "2 → 1 → DROP!" countdown on the phase banner during FACEOFF_PREP.
# Pure cosmetic: the puck unlock is gated by the authoritative phase change to
# FACEOFF, so a client running a frame or two behind still sees the right beat.
func _start_faceoff_countdown() -> void:
	_stop_faceoff_countdown()
	_phase_label.text = "FACEOFF IN 2"
	var prep: float = GameRules.FACEOFF_PREP_DURATION
	var t := create_tween()
	# Half-second tween to "1" mid-window if prep >= 2s; final "DROP!" sits in
	# the FACEOFF phase entry. Steps are evenly split so 2.0s → ~1.0s per beat.
	t.tween_interval(prep * 0.5)
	t.tween_callback(func() -> void:
		if _phase_label != null:
			_phase_label.text = "FACEOFF IN 1")
	_faceoff_countdown_tween = t


func _stop_faceoff_countdown() -> void:
	if _faceoff_countdown_tween != null and _faceoff_countdown_tween.is_valid():
		_faceoff_countdown_tween.kill()
	_faceoff_countdown_tween = null


func _on_puck_out_of_play() -> void:
	if _toast_stack != null:
		_toast_stack.push("PUCK OUT OF PLAY", _WHITE)


func _on_icing_called() -> void:
	if _toast_stack != null:
		_toast_stack.push("ICING", _WHITE)


func _on_offside_called() -> void:
	if _toast_stack != null:
		_toast_stack.push("OFFSIDE", _WHITE)

# Reset the four goal-template rows (tagline, scorer, ASSISTED BY, assist
# names) to hidden so non-goal phases show only the phase_label hero.
func _clear_goal_template() -> void:
	_tagline_label.visible = false
	_scorer_label.visible = false
	_assist_tag_label.visible = false
	_assist_label.visible = false

func _on_period_changed(new_period: int) -> void:
	_period_label.text = _period_ordinal(new_period)
	_warned_one_min = false
	_warned_thirty = false
	_hide_clock_warning()

# Big, screen-centered countdown shown only in the final 10 seconds of a
# period — the small scorebug clock is easy to miss while watching the puck,
# so this is the unmissable "the period is about to end" cue. Hidden by
# default; driven by _on_clock_updated. mouse_filter IGNORE so it never eats
# input, and it sits below the goal/phase banners' layer ordering by being
# added before them.
func _build_clock_warning() -> void:
	_clock_warning_label = _lbl("", 150, _GOLD)
	_clock_warning_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_clock_warning_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_clock_warning_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_clock_warning_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_clock_warning_label.modulate = Color(1.0, 1.0, 1.0, 0.9)
	_clock_warning_label.visible = false
	add_child(_clock_warning_label)

func _hide_clock_warning() -> void:
	if _clock_warning_label != null:
		_clock_warning_label.visible = false
	_last_warning_pulse_second = -1

# Buzzer + screen flash when a period (or the game) ends — the definitive
# "it's over" cue. The PERIOD_BUZZER asset existed but was never played.
func _sound_period_end() -> void:
	SoundManager.play_sfx(SoundManager.Sound.PERIOD_BUZZER)
	if _flash_overlay != null:
		_flash_overlay.flash(_GOLD, 0.35, 0.5)

func _on_clock_updated(t: float) -> void:
	_clock_label.text = _format_clock(t)
	if NetworkManager.is_offline_mode:
		_clock_label.add_theme_color_override("font_color", _WHITE)
		_last_clock_pulse_second = -1
		_hide_clock_warning()
		return
	_clock_label.add_theme_color_override("font_color", _GOLD if t <= 30.0 and t > 0.0 else _WHITE)
	# Advance warnings (one-shot per period) so the clock doesn't sneak up on a
	# player focused on the puck. _warned_* re-arm when the clock resets above
	# the threshold (period start / next-period faceoff).
	if t > 60.0:
		_warned_one_min = false
		_warned_thirty = false
	if t <= 60.0 and t > 30.0 and not _warned_one_min:
		_warned_one_min = true
		if _toast_stack != null:
			_toast_stack.push("1 MINUTE LEFT", _GOLD)
	if t <= 30.0 and t > 0.0 and not _warned_thirty:
		_warned_thirty = true
		if _toast_stack != null:
			_toast_stack.push("30 SECONDS LEFT", _STAMINA_LOW)
	# Final-10 hero countdown + per-second pulse on both the big number and the
	# scorebug clock.
	if t > 0.0 and t <= 10.0:
		var sec := int(ceil(t))
		if _clock_warning_label != null:
			_clock_warning_label.text = str(sec)
			_clock_warning_label.visible = true
		if sec != _last_clock_pulse_second:
			_last_clock_pulse_second = sec
			_clock_label.pivot_offset = _clock_label.size / 2.0
			var cp := create_tween()
			cp.tween_property(_clock_label, "scale", Vector2(1.3, 1.3), 0.0)
			cp.tween_property(_clock_label, "scale", Vector2.ONE, 0.25) \
				.set_trans(Tween.TRANS_SPRING).set_ease(Tween.EASE_OUT)
		if sec != _last_warning_pulse_second and _clock_warning_label != null:
			_last_warning_pulse_second = sec
			_clock_warning_label.pivot_offset = _clock_warning_label.size / 2.0
			var wp := create_tween()
			wp.tween_property(_clock_warning_label, "scale", Vector2(1.5, 1.5), 0.0)
			wp.tween_property(_clock_warning_label, "scale", Vector2.ONE, 0.45) \
				.set_trans(Tween.TRANS_SPRING).set_ease(Tween.EASE_OUT)
	else:
		_last_clock_pulse_second = -1
		_hide_clock_warning()

func _on_game_over() -> void:
	_phase_style.bg_color = MenuStyle.BROADCAST_BG  # clear any residual goal tint
	_tagline_label.text = "FINAL"
	_tagline_label.visible = true
	_phase_label.visible = true
	_scorer_label.visible = false
	_assist_tag_label.visible = false
	_assist_label.visible = false
	if _score_0 > _score_1:
		_phase_label.text = "HOME WINS"
		_phase_label.add_theme_color_override("font_color", _initial_team_primary(0))
	elif _score_1 > _score_0:
		_phase_label.text = "AWAY WINS"
		_phase_label.add_theme_color_override("font_color", _initial_team_primary(1))
	else:
		_phase_label.text = "TIE"
		_phase_label.add_theme_color_override("font_color", _WHITE)
	_show_phase_banner_at_rest()
	_rematch_votes.clear()
	_local_voted = false
	_update_rematch_ui()
	_game_over_popup.show_popup()

func _on_game_reset() -> void:
	_game_over_popup.hide_popup()
	if _pause_menu != null:
		_pause_menu.close()
	if _side_menu != null:
		_side_menu.close()

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

# Online-host-only button (offline/clients don't show it): pull the whole
# group back to the shared lobby.
func _on_game_over_host_action() -> void:
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

func _on_game_over_exit() -> void:
	_show_confirm("Exit game?", func() -> void:
		await NetworkManager.announce_match_end()
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
	l.add_theme_font_override("font", MenuStyle.DISPLAY_FONT)
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
	return "%d:%02d" % [secs / 60, secs % 60]
