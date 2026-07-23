class_name HUD
extends CanvasLayer

# Playtest aid: toast the local player's released shot speed as
# "SHOT · 74 MPH · 89%". The % is of the shot family's own attribute-scaled
# ceiling (wrister/quick → max_wrister_power, slapper → max_slapper_power),
# so it reads as "where in my band did that release land" — the feedback loop
# for learning to hit in-between wrister speeds. DEBUG-BUILD ONLY: the hook
# below also gates on OS.is_debug_build(), so it never appears in a shipped
# (release-export) build. Flip this off to silence it in the editor too.
@export var debug_shot_speed_toast: bool = true
var _shot_toast_controller: SkaterController = null

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
var _intermission_overlay: IntermissionOverlay = null
var _matchup_overlay: MatchupIntroOverlay = null
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
# peer_id -> RematchVoteRules.Choice: the shared play-again vote pool
# (REMATCH and LOBBY are flavors of the same unanimous vote).
var _rematch_votes: Dictionary[int, int] = {}
var _local_vote: int = RematchVoteRules.Choice.NONE
# Authoritative voter-pool size (connected humans minus spectators). The host
# computes and broadcasts it (skip-vote pattern: host counts, peers display) —
# clients can't derive it locally because from-lobby spectators are only
# tracked host-side. 0 = no broadcast landed yet (client fallback estimate).
var _vote_total: int = 0
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
# Parent of all scalable HUD chrome — see _update_hud_scale. Popups/menus (own
# CanvasLayers) and the off-screen indicators live outside it.
var _scale_root: Control = null
var _ghost_banner_root: Control = null
var _ghost_reason_label: Label = null
var _ghost_instr_label: Label = null
var _ghost_pulse_t: float = 0.0
# HUD-local mirror of the offside hold: set when the local skater is observed
# offside during the current ghost spell, cleared when they tag up or the ghost
# lifts. Lets the banner distinguish an offside (held until tag-up, even after
# the puck enters the zone) from a pure crease violation deep in the attacking
# zone, where no offside ever occurred.
var _ghost_was_offside: bool = false

const _WARN_AMBER := Color(0.95, 0.65, 0.20, 1.0)            # clock-warning toast tint

const _DARK_BG    := MenuStyle.BROADCAST_BG
const _WHITE      := MenuStyle.BROADCAST_CREAM
const _DIM        := MenuStyle.BROADCAST_DIM
const _GOLD       := MenuStyle.GOLD
const _SEP_COLOR  := MenuStyle.BROADCAST_SEP

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
	_build_scorebug()
	_build_minimap()
	_build_phase_banner()
	_build_clock_warning()
	_build_top_goal_banner()
	_build_version_tag()
	_build_ghost_banner()
	_build_bug_icon()
	_build_skip_replay_prompt()
	_bug_dialog = BugReportDialog.new()
	add_child(_bug_dialog)
	_game_over_popup = GameOverPopup.new()
	_game_over_popup.rematch_toggled.connect(_on_rematch_vote_pressed)
	_game_over_popup.lobby_vote_toggled.connect(_on_lobby_vote_pressed)
	_game_over_popup.free_play_pressed.connect(_on_game_over_free_play)
	_game_over_popup.exit_pressed.connect(_on_game_over_exit)
	add_child(_game_over_popup)
	_intermission_overlay = IntermissionOverlay.new()
	add_child(_intermission_overlay)
	_matchup_overlay = MatchupIntroOverlay.new()
	add_child(_matchup_overlay)
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
	_scale_root.add_child(_toast_stack)
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
	GameManager.period_synced.connect(_on_period_synced)
	GameManager.clock_updated.connect(_on_clock_updated)
	GameManager.game_over.connect(_on_game_over)
	GameManager.game_reset.connect(_on_game_reset)
	NetworkManager.rematch_vote_changed.connect(_on_rematch_vote_changed)
	NetworkManager.rematch_voters_changed.connect(_on_rematch_voters_changed)
	NetworkManager.peer_disconnected.connect(_on_rematch_peer_disconnected)
	GameManager.shots_on_goal_changed.connect(_on_shots_on_goal_changed)
	GameManager.stats_updated.connect(_on_stats_updated_for_feed)
	GameManager.player_joined.connect(func(n: String, c: Color) -> void: _toast_stack.push_pair(n, "joined", c))
	GameManager.player_left.connect(func(n: String, c: Color) -> void: _toast_stack.push_pair(n, "left", c))
	GameManager.puck_out_of_play.connect(_on_puck_out_of_play)
	GameManager.icing_called.connect(_on_icing_called)
	GameManager.goalie_freeze_called.connect(_on_goalie_freeze_called)
	GameManager.offside_called.connect(_on_offside_called)
	GameManager.local_player_hit.connect(_on_local_player_hit)
	# Arrives just before faceoff_prep_announced on the opening faceoff; the
	# countdown builder consumes it to lead with the matchup card.
	GameManager.pregame_intro_started.connect(
			func(duration: float) -> void: _pending_intro_secs = duration)
	# Same idea for period / stoppage skate-ins: hold the countdown for the skate
	# window (no matchup card) so "2 → 1 → DROP" lands on the extended drop.
	GameManager.faceoff_skate_in_started.connect(
			func(delay: float) -> void: _pending_skate_secs = delay)
	# Period-start bench intro: same hold mechanic as the matchup card, with the
	# upcoming period as the hero card ("2ND PERIOD" / "OVERTIME").
	GameManager.period_intro_started.connect(
			func(period: int, duration: float) -> void:
				_pending_period_intro_num = period
				_pending_period_intro_secs = duration)
	GameManager.replay_started.connect(_on_replay_started)
	GameManager.replay_stopped.connect(_on_replay_stopped)
	GameManager.skip_replay_vote_updated.connect(_on_skip_replay_vote_updated)
	GameManager.intermission_started.connect(_on_intermission_started)
	GameManager.intermission_clip_started.connect(_on_intermission_clip_started)
	GameManager.intermission_ended.connect(_on_intermission_ended)
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
	if event.is_action_pressed(&"smart_ping"):
		# Context-sensitive team ping (chat bubble + bot directive). Resolution
		# and all gating (spectator/replay/cooldown/no-op contexts) live in
		# GameManager.try_send_smart_ping; the HUD only swallows the press when
		# a menu owns the screen.
		if not (_confirm_dialog.visible or _pause_menu.visible or _side_menu.visible):
			GameManager.try_send_smart_ping()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(&"skip_replay"):
		# Gate on the skip-prompt visibility (goal cinematic — HUD's own label;
		# intermission — the overlay's line) so the (Space-shared) brake key
		# never accidentally fires a vote outside of a skippable window.
		var skippable: bool = (_skip_prompt_label != null and _skip_prompt_label.visible) \
				or (_intermission_overlay != null and _intermission_overlay.visible)
		if skippable:
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
	_scale_root.add_child(shadow_wrap)

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
	stripe_style.bg_color = _scorebug_stripe(team_id)
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
	_scale_root.add_child(root)

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
	_scale_root.add_child(_top_goal_banner)

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

	_scale_root.add_child(root)
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
	_scale_root.add_child(_skip_prompt_label)

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
	_scale_root.add_child(_menu_hint_label)

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
	_scale_root.add_child(label)

# The FPS readout lives in NetworkDebugOverlay's top-right diagnostics row
# (next to the always-on network health dot) so the two can't overlap.

# (The old bottom-edge sprint stamina bar is gone — stamina now lives on the
# ice as the ring inside the player's own circle; see SkaterHUDCoordinator.)

# Local-player infraction banner. Shown whenever the local skater is ghosted
# for a reason the player can clear themselves (offside or crease violation),
# naming the infraction and the action that lifts it. Built once in code (like
# the rest of the HUD chrome) and driven each frame from the local skater's own
# position in _update_ghost_banner(); icing (a whole-team ghost) keeps its
# existing toast.
func _build_ghost_banner() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_TOP_WIDE)
	# Sits below the scorebug, centred in the upper third — out of the way of the
	# lower-third phase chyron.
	root.offset_top = 96.0
	root.offset_bottom = 220.0
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ghost_banner_root = root
	_scale_root.add_child(root)

	var centering := CenterContainer.new()
	centering.set_anchors_preset(Control.PRESET_FULL_RECT)
	centering.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(centering)

	var style := StyleBoxFlat.new()
	style.bg_color = MenuStyle.BROADCAST_BG
	style.set_corner_radius_all(4)
	style.anti_aliasing = false
	style.set_content_margin(SIDE_LEFT, 28)
	style.set_content_margin(SIDE_RIGHT, 28)
	style.set_content_margin(SIDE_TOP, 12)
	style.set_content_margin(SIDE_BOTTOM, 12)
	style.set_border_width_all(2)
	style.border_color = MenuStyle.DANGER

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", style)
	var wrapper: Control = MenuStyle.wrap_drop_shadow(panel, Vector2(4, 4))
	centering.add_child(wrapper)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 2)
	panel.add_child(vbox)

	_ghost_reason_label = _lbl("", 30, MenuStyle.DANGER)
	_ghost_reason_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_ghost_reason_label)

	_ghost_instr_label = _lbl("", 16, _WHITE)
	_ghost_instr_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_ghost_instr_label)

	root.visible = false

func _update_ghost_banner() -> void:
	if _ghost_banner_root == null:
		return
	var record: PlayerRecord = GameManager.get_local_player()
	var skater: Skater = record.skater if record != null else null
	if skater == null or record.team == null or not skater.is_ghost:
		if _ghost_banner_root.visible:
			_ghost_banner_root.visible = false
		_ghost_was_offside = false
		return
	var pos: Vector3 = skater.global_position
	var team_id: int = record.team.team_id
	var reason: String = ""
	var instruction: String = ""
	# Track whether an offside actually occurred during this ghost spell. An
	# offside ghost is held until the player tags up (has_tagged_up), so once we
	# see them offside we latch it and keep showing OFFSIDE until they cross back
	# — even after the puck enters the zone (which makes is_offside read false).
	# Tagging up clears the latch.
	var tagged_up: bool = InfractionRules.has_tagged_up(pos.z, team_id)
	if tagged_up:
		_ghost_was_offside = false
	elif GameManager.get_rule_set() == GameRules.RuleSet.ARCADE:
		var puck: Puck = GameManager.get_puck()
		if puck != null:
			var is_carrier: bool = puck.carrier == skater
			if InfractionRules.is_offside(pos.z, team_id, puck.global_position.z, is_carrier):
				_ghost_was_offside = true
	# Reason is derived from the local skater's position. Offside takes priority:
	# a skater serving an offside in the opponent crease must skate back to the
	# blue line, which clears the crease violation incidentally on the way. But a
	# player who is merely camping the crease while ONSIDE never went offside, so
	# the latch stays false and they get the crease prompt. (A defender camping
	# their OWN crease is never offside either — has_tagged_up holds in their own
	# end — so that case also falls through to the crease prompt.)
	if _ghost_was_offside and not tagged_up:
		reason = "OFFSIDE"
		instruction = "Skate back to your blue line to tag up"
	elif CreaseRules.is_in_crease(Vector2(pos.x, pos.z)):
		reason = "CREASE VIOLATION"
		instruction = "Clear out of the goal crease to rejoin the play"
	else:
		# Any other ghost cause (e.g. a whole-team icing ghost) surfaces through
		# its own toast — no per-player recovery action to prompt here.
		if _ghost_banner_root.visible:
			_ghost_banner_root.visible = false
		return
	if _ghost_reason_label.text != reason:
		_ghost_reason_label.text = reason
	if _ghost_instr_label.text != instruction:
		_ghost_instr_label.text = instruction
	_ghost_banner_root.visible = true
	# Slow attention pulse on the banner alpha so a persistent ghost keeps
	# drawing the eye without flashing.
	_ghost_pulse_t += get_process_delta_time() * 4.0
	_ghost_banner_root.modulate.a = 0.75 + 0.25 * sin(_ghost_pulse_t)

var _hud_scale_applied: float = -1.0
var _hud_scale_viewport: Vector2i = Vector2i.ZERO

func _process(_delta: float) -> void:
	_update_hud_scale()
	_update_shot_speed_toast_hook()
	_update_ghost_banner()


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
	_toast_stack.push(text, _WHITE)


# Applies PlayerPrefs.hud_scale by sizing _scale_root to a virtual viewport of
# (vp / s) and scaling it up by s about the top-left: (vp/s)·s always fills the
# screen exactly, so edge-anchored widgets stay glued to the true screen edges
# at ANY scale. (The old approach scaled the whole CanvasLayer about the
# viewport center, which pushed edge widgets off-screen for s > 1 — a scaled
# canvas is wider than the screen, so no offset can keep both edges visible.)
# Re-applies only when the scale or the viewport size actually changes
# (dirty-check), so the steady state costs one float + one Vector2i compare
# per frame. Menus/dialogs (own CanvasLayers) and the off-screen player
# indicators (drawn at unprojected screen coordinates) sit outside the root
# and are unaffected.
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
	# Restore the goal-chyron tag — game over borrows this label for
	# "STAR OF THE GAME", so re-stamp it on every goal preload.
	_assist_tag_label.text = "ASSISTED BY"
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

# Scorebug stripe color for a team: always its own primary, so a team's color
# is consistent regardless of who it's playing.
func _scorebug_stripe(team_id: int) -> Color:
	if GameManager.teams.size() > 1:
		var pair: Dictionary = TeamColorRegistry.get_score_stripe_pair(
				GameManager.teams[0].color_slot, GameManager.teams[1].color_slot)
		return pair.home if team_id == 0 else pair.away
	return Color(0.5, 0.5, 0.5)  # placeholder; team_colors_ready overwrites

func _on_team_colors_ready(_home_primary: Color, _home_secondary: Color, _away_primary: Color, _away_secondary: Color) -> void:
	# In the chyron layout the AWAY/HOME labels sit on the dark panel, not on
	# the team color, so their text stays cream regardless of team palette. The
	# stripes are each team's own primary color (see _scorebug_stripe) rather
	# than the raw signal colors.
	if _home_badge_style != null:
		_home_badge_style.bg_color = _scorebug_stripe(0)
	if _away_badge_style != null:
		_away_badge_style.bg_color = _scorebug_stripe(1)

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
	var text: String = _skip_prompt_text()
	if _skip_prompt_label != null:
		_skip_prompt_label.text = text
	# The intermission overlay shows its own skip line (the HUD label would sit
	# under its scrim); keep it fed with the same tally.
	if _intermission_overlay != null and _intermission_overlay.visible:
		_intermission_overlay.set_skip_text(text)

func _skip_prompt_text() -> String:
	if _skip_vote_total <= 1:
		# Solo session — no tally, the single press just skips.
		return "[SPACE] TO SKIP"
	return "[SPACE] TO SKIP  (%d/%d)" % [_skip_vote_current, _skip_vote_total]

# ── Intermission (between-periods highlight reel) ────────────────────────────

func _on_intermission_started(period: int, reel_seconds: float) -> void:
	# The band replaces the END-OF-PERIOD chyron; the reel is already rolling
	# behind it.
	_phase_wrapper.visible = false
	_intermission_overlay.present(_intermission_title(period),
			_score_0, _score_1, _scorebug_stripe(0), _scorebug_stripe(1),
			reel_seconds)
	_intermission_overlay.set_skip_text(_skip_prompt_text())

func _on_intermission_clip_started(scoring_team_id: int, scorer_name: String,
		assist1_name: String, assist2_name: String) -> void:
	var assists: PackedStringArray = PackedStringArray()
	if not assist1_name.is_empty():
		assists.append(assist1_name)
	if not assist2_name.is_empty():
		assists.append(assist2_name)
	var tag_color: Color = _scorebug_stripe(scoring_team_id) \
			if scoring_team_id >= 0 else _WHITE
	_intermission_overlay.set_goal_caption(
			tag_color, scorer_name, ", ".join(assists))

func _on_intermission_ended() -> void:
	_intermission_overlay.hide_overlay()
	_skip_vote_current = 0
	_skip_vote_total = 0

# Band title for the break after period `p`: "END OF 1ST PERIOD", or
# "END OF OVERTIME" when repeated OT ties keep the game going.
func _intermission_title(p: int) -> String:
	var n: int = GameManager.get_num_periods()
	if p <= n:
		return "END OF %s PERIOD" % _period_ordinal(p)
	var ot: int = p - n
	if ot <= 1:
		return "END OF OVERTIME"
	return "END OF OVERTIME %d" % ot

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
			_flash_period_end()
			_phase_label.text = "END OF PERIOD"
			_phase_label.add_theme_color_override("font_color", _WHITE)
			_phase_label.visible = true
			_phase_style.bg_color = MenuStyle.BROADCAST_BG
			_show_phase_banner_at_rest()
		GamePhase.Phase.GAME_OVER:
			_stop_faceoff_countdown()
			_hide_clock_warning()
			_flash_period_end()
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
	# A reel-less (scoreless) break's band has no intermission_ended to dismiss
	# it — the next prep is its exit. Idempotent for reel breaks (already hidden).
	_on_intermission_ended()
	_clear_goal_template()
	_phase_label.add_theme_color_override("font_color", _WHITE)
	_phase_label.visible = true
	_phase_style.bg_color = MenuStyle.BROADCAST_BG
	_show_phase_banner_at_rest()
	_start_faceoff_countdown()


# Drives a "2 → 1 → DROP!" countdown on the phase banner during FACEOFF_PREP.
# Pure cosmetic: the puck unlock is gated by the authoritative phase change to
# FACEOFF, so a client running a frame or two behind still sees the right beat.
# On the opening faceoff (pregame_intro_started arrived just before this), the
# full-screen matchup roster overlay leads for the intro window — the camera
# sweep plays under it — then hands off to the normal banner countdown.
var _pending_intro_secs: float = 0.0
var _pending_skate_secs: float = 0.0
var _pending_period_intro_secs: float = 0.0
var _pending_period_intro_num: int = 0

func _start_faceoff_countdown() -> void:
	_stop_faceoff_countdown()
	var intro: float = _pending_intro_secs
	_pending_intro_secs = 0.0
	var period_card: float = _pending_period_intro_secs
	_pending_period_intro_secs = 0.0
	var period_num: int = _pending_period_intro_num
	var skate: float = _pending_skate_secs
	_pending_skate_secs = 0.0
	var prep: float = GameRules.FACEOFF_PREP_DURATION
	var t := create_tween()
	if intro > 0.0:
		# Full-screen matchup rosters over the camera sweep; the banner stays
		# down until the screen dismisses into the normal countdown.
		_phase_wrapper.visible = false
		_show_matchup_overlay()
		t.tween_interval(intro)
		t.tween_callback(func() -> void:
			if _matchup_overlay != null:
				_matchup_overlay.hide_overlay()
			if _phase_wrapper != null:
				_phase_wrapper.visible = true
			if _phase_label != null:
				_phase_label.text = "FACEOFF IN 2")
	elif period_card > 0.0:
		# Period-start card over the camera sweep + bench skate-on, then the
		# normal countdown lands on the extended drop.
		_phase_label.text = _period_intro_title(period_num)
		t.tween_interval(period_card)
		t.tween_callback(func() -> void:
			if _phase_label != null:
				_phase_label.text = "FACEOFF IN 2")
	elif skate > 0.0:
		# Players are skating in — hold on a plain banner, then start the numbered
		# countdown so it ends on the extended drop.
		_phase_label.text = "FACEOFF"
		t.tween_interval(skate)
		t.tween_callback(func() -> void:
			if _phase_label != null:
				_phase_label.text = "FACEOFF IN 2")
	else:
		_phase_label.text = "FACEOFF IN 2"
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
	# The matchup screen lives under this tween's watch (its dismissal is a
	# tween callback), so an interrupted countdown must take it down too.
	if _matchup_overlay != null:
		_matchup_overlay.hide_overlay()


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
			_scorebug_stripe(0), _scorebug_stripe(1))


func _on_puck_out_of_play() -> void:
	if _toast_stack != null:
		_toast_stack.push("PUCK OUT OF PLAY", _WHITE)


func _on_icing_called() -> void:
	if _toast_stack != null:
		_toast_stack.push("ICING", _WHITE)


func _on_goalie_freeze_called() -> void:
	if _toast_stack != null:
		_toast_stack.push("GOALIE FREEZES IT", _WHITE)


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

func _on_period_synced(new_period: int) -> void:
	_period_label.text = _period_ordinal(new_period)

# Big, screen-centered countdown shown only in the final 10 seconds of a
# period — the small scorebug clock is easy to miss while watching the puck,
# so this is the unmissable "the period is about to end" cue. Hidden by
# default; driven by _on_clock_updated. mouse_filter IGNORE so it never eats
# input, and it sits below the goal/phase banners' layer ordering by being
# added before them.
func _build_clock_warning() -> void:
	_clock_warning_label = _lbl("", 150, _GOLD)
	_clock_warning_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	# Sit slightly above screen center rather than dead-center: cap the band at
	# 80% of the height so the vertical-centered text lands around 40% down —
	# clear of the puck/action in the lower-middle of the rink. Resolution-
	# independent (anchor fraction, not a pixel offset).
	_clock_warning_label.anchor_bottom = 0.8
	_clock_warning_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_clock_warning_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_clock_warning_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Semi-transparent so the final seconds of play stay readable behind it.
	_clock_warning_label.modulate = Color(1.0, 1.0, 1.0, 0.6)
	_clock_warning_label.visible = false
	_scale_root.add_child(_clock_warning_label)

func _hide_clock_warning() -> void:
	if _clock_warning_label != null:
		_clock_warning_label.visible = false
	_last_warning_pulse_second = -1

# Gold screen flash when a period (or the game) ends — a visual partner to the
# period buzzer, which GameManager already fires on these same phases.
func _flash_period_end() -> void:
	if _flash_overlay != null:
		_flash_overlay.flash(_GOLD, 0.35, 0.5)

func _on_clock_updated(t: float) -> void:
	_clock_label.text = _format_clock(t)
	# Untimed periods (free play / practice) count UP from zero — there's no
	# end-of-period to warn about, and the count-up would otherwise trip the
	# final-10 countdown during the first 10 seconds. Keep the clock plain. A
	# TIMED offline match (real period length) still gets the full treatment.
	if GameManager.get_period_duration() <= 0.0:
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
			_toast_stack.push("30 SECONDS LEFT", _WARN_AMBER)
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

# The final-horn beat plays on the ice first (gold flash + "HOME WINS" chyron
# via _on_phase_changed / here), then the full end-of-game screen takes over.
# This delay is that breath; the presentation tween is killed by _on_game_reset
# if a rematch fires inside the window.
const _GAME_OVER_PRESENT_DELAY: float = 2.2
var _game_over_present_tween: Tween = null

func _on_game_over() -> void:
	_phase_style.bg_color = MenuStyle.BROADCAST_BG  # clear any residual goal tint
	_tagline_label.text = "FINAL"
	# Clear the last goal's team tint (_on_goal_scored overrides this label's
	# color per-goal); FINAL is a non-team context, so it reads in the default.
	_tagline_label.add_theme_color_override("font_color", _WHITE)
	_tagline_label.visible = true
	_phase_label.visible = true
	_scorer_label.visible = false
	_assist_tag_label.visible = false
	_assist_label.visible = false
	var result_text: String
	var result_color: Color
	if _score_0 > _score_1:
		result_text = "HOME WINS"
		result_color = _initial_team_primary(0)
	elif _score_1 > _score_0:
		result_text = "AWAY WINS"
		result_color = _initial_team_primary(1)
	else:
		result_text = "TIE GAME"
		result_color = _WHITE
	_phase_label.text = result_text
	_phase_label.add_theme_color_override("font_color", result_color)
	_show_phase_banner_at_rest()
	_rematch_votes.clear()
	_local_vote = RematchVoteRules.Choice.NONE
	# Zeroing forces the host's refresh below to see a change and broadcast a
	# fresh total (clients just zeroed their mirror and are waiting on it).
	_vote_total = 0
	_update_rematch_ui()
	if _game_over_present_tween != null and _game_over_present_tween.is_running():
		_game_over_present_tween.kill()
	_game_over_present_tween = create_tween()
	_game_over_present_tween.tween_interval(_GAME_OVER_PRESENT_DELAY)
	_game_over_present_tween.tween_callback(
			_present_game_over_screen.bind(result_text, result_color))

func _present_game_over_screen(result_text: String, result_color: Color) -> void:
	# The screen carries the same FINAL info, so the chyron behind it retires.
	_phase_wrapper.visible = false
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
					_score_1 if opp == 1 else _score_0))
		else:
			star_lines.append(_star_stat_line(star.stats))
		star_stripes.append(_scorebug_stripe(star.team.team_id))
	_game_over_popup.present(_score_0, _score_1,
			_scorebug_stripe(0), _scorebug_stripe(1),
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
	if _pause_menu != null:
		_pause_menu.close()
	if _side_menu != null:
		_side_menu.close()

# The two vote buttons toggle their own flavor and steal from the other:
# pressing the flavor you already voted withdraws (NONE); pressing the other
# switches the vote in one click.
func _on_rematch_vote_pressed() -> void:
	_toggle_local_vote(RematchVoteRules.Choice.REMATCH)

func _on_lobby_vote_pressed() -> void:
	_toggle_local_vote(RematchVoteRules.Choice.LOBBY)

func _toggle_local_vote(choice: int) -> void:
	_local_vote = RematchVoteRules.Choice.NONE if _local_vote == choice else choice
	NetworkManager.send_rematch_vote(_local_vote)

func _on_rematch_vote_changed(peer_id: int, vote: int) -> void:
	_rematch_votes[peer_id] = vote
	_update_rematch_ui()
	if NetworkManager.is_host:
		_check_rematch_unanimous()

func _on_rematch_peer_disconnected(peer_id: int) -> void:
	_rematch_votes.erase(peer_id)
	_update_rematch_ui()
	if NetworkManager.is_host:
		_check_rematch_unanimous()

func _on_rematch_voters_changed(total: int) -> void:
	_vote_total = total
	_update_rematch_ui()

# Host-side: recompute the voter pool and broadcast it when it moves. Spectators
# don't have a vote button; spectator_peer_count already includes the host's
# peer (1) if the host is itself a spectator, so a single subtraction yields
# the actual pool. Re-run on every vote/disconnect funnel so a mid-screen
# spectator demotion is picked up on the next vote event.
func _refresh_voter_total() -> void:
	if not NetworkManager.is_host:
		return
	var total: int = NetworkManager.connected_peer_ids().size() + 1 \
			- GameManager.spectator_peer_count()
	if total == _vote_total:
		return
	_vote_total = total
	NetworkManager.send_rematch_voters_to_all(total)

func _update_rematch_ui() -> void:
	_refresh_voter_total()
	# Client fallback until the host's total lands: everyone connected. It can
	# overcount (unreplicated from-lobby spectators) for at most the RPC gap.
	var total: int = _vote_total if _vote_total > 0 \
			else NetworkManager.connected_peer_ids().size() + 1
	_game_over_popup.update_votes(_rematch_votes, total, _local_vote)

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

# Host-side. Every caller runs _update_rematch_ui first, so _vote_total is
# freshly recomputed by the time the pool is resolved.
func _check_rematch_unanimous() -> void:
	match RematchVoteRules.resolve(_rematch_votes, _vote_total):
		RematchVoteRules.Choice.REMATCH:
			GameManager.reset_game()
		RematchVoteRules.Choice.LOBBY:
			GameManager.return_to_lobby()

func _on_bug_report_pressed() -> void:
	_bug_dialog.open()

func _on_local_player_hit(magnitude: float) -> void:
	if magnitude < 3.0:
		return
	var strength := clampf(magnitude / 12.0, 0.2, 0.55)
	_flash_overlay.vignette_pulse(strength)

# ── Stat feed ────────────────────────────────────────────────────────────────
# Ticker toast per recorded counting stat ("JONES · BLOCKED SHOT"), derived by
# diffing each player's replicated stat counters against the last snapshot —
# the same numbers on every peer, so host and clients see identical toasts
# with no extra RPC. Goals/assists are excluded (the goal banner + chyron own
# that moment); see StatFeedRules for the full exclusion rationale.

const _STAT_FEED_LABELS: Dictionary[StringName, String] = {
	StatFeedRules.EVENT_SHOT_ON_GOAL: "SHOT ON GOAL",
	StatFeedRules.EVENT_BLOCKED_SHOT: "BLOCKED SHOT",
	StatFeedRules.EVENT_HIT: "HIT",
	StatFeedRules.EVENT_TAKEAWAY: "TAKEAWAY",
	StatFeedRules.EVENT_FACEOFF_WIN: "FACEOFF WON",
}

# peer_id -> PlayerStats snapshot from the previous stats_updated.
var _stat_feed_baseline: Dictionary[int, PlayerStats] = {}

func _on_stats_updated_for_feed() -> void:
	if _toast_stack == null:
		return
	var players: Dictionary = GameManager.get_players()
	for pid: int in players:
		var record: PlayerRecord = players[pid] as PlayerRecord
		if record == null or record.stats == null:
			continue
		var snapshot: PlayerStats = PlayerStats.from_array(record.stats.to_array())
		var prev: PlayerStats = _stat_feed_baseline.get(pid)
		# First sight of a player just establishes the baseline — joining
		# mid-game must not replay their whole stat line as toasts.
		if prev != null:
			for event: StringName in StatFeedRules.feed_events(prev, snapshot):
				_toast_stack.push_pair(record.display_name(),
						"· %s" % _STAT_FEED_LABELS[event], _stat_feed_color(record))
		_stat_feed_baseline[pid] = snapshot
	# Drop baselines for departed players so a reused peer id starts fresh.
	for pid: int in _stat_feed_baseline.keys():
		if not players.has(pid):
			_stat_feed_baseline.erase(pid)

# Same color the join/leave toasts use for this player's team.
func _stat_feed_color(record: PlayerRecord) -> Color:
	if record.team == null:
		return _WHITE
	return TeamColorRegistry.get_colors(
			record.team.color_slot, record.team.team_id).primary

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

# Hero text for the period-start intro card: "2ND PERIOD" for regulation,
# "OVERTIME" for the first OT, numbered beyond (repeated ties keep cycling OT).
func _period_intro_title(p: int) -> String:
	var n: int = GameManager.get_num_periods()
	if p <= n:
		return "%s PERIOD" % _period_ordinal(p)
	var ot: int = p - n
	if ot <= 1:
		return "OVERTIME"
	return "OVERTIME %d" % ot

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
