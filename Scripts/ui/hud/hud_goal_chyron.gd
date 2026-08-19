class_name HudGoalChyron
extends Node

# The broadcast lower-third band and the goal wash that overlays the scorebug.
# A goal is a two-beat moment: the wash slides in over the scorebug ("G O A L")
# and dismisses, then during the replay phase the chyron carries the data
# (GOAL SCORED BY / <scorer> / ASSISTED BY / <assists>). Non-goal phases reuse
# the same band for a single hero line.
#
# The band also owns the faceoff countdown, because the countdown writes the
# hero line and the wrapper's visibility on every beat.

# The opening faceoff leads with the full-screen matchup rosters; composing them
# needs the live registry, so the HUD presents and this asks.
signal matchup_intro_requested
signal matchup_intro_dismissed

var _banner_root: Control = null
var _wrapper: Control = null
var _panel: PanelContainer = null
var _style: StyleBoxFlat = null
var _phase_label: Label = null
var _tagline_label: Label = null
var _scorer_label: Label = null
var _assist_tag_label: Label = null
var _assist_label: Label = null
var _slide_tween: Tween = null

var _wash_root: Control = null
var _wash_panel: PanelContainer = null
var _wash_style: StyleBoxFlat = null
var _wash_label: Label = null
var _wash_tween: Tween = null

var _countdown_tween: Tween = null
var _pending_intro_secs: float = 0.0
var _pending_skate_secs: float = 0.0
var _pending_period_intro_secs: float = 0.0
var _pending_period_intro_num: int = 0

func build(scale_root: Control) -> void:
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
	_banner_root = root
	scale_root.add_child(root)

	var centering := CenterContainer.new()
	centering.set_anchors_preset(Control.PRESET_FULL_RECT)
	centering.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(centering)

	# 4px rounded corners to match the scorebug — single visual language across
	# the HUD chrome. No top border line: a thin border that has to follow the
	# corner curve reads as a competing stripe over the chyron's bold team-color
	# fill.
	_style = StyleBoxFlat.new()
	_style.bg_color = MenuStyle.BROADCAST_BG
	_style.set_corner_radius_all(4)
	_style.anti_aliasing = false
	_style.set_content_margin(SIDE_LEFT, 36)
	_style.set_content_margin(SIDE_RIGHT, 36)
	_style.set_content_margin(SIDE_TOP, 14)
	_style.set_content_margin(SIDE_BOTTOM, 14)

	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", _style)
	_wrapper = MenuStyle.wrap_drop_shadow(_panel, Vector2(5, 5))
	centering.add_child(_wrapper)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 2)
	_panel.add_child(vbox)

	# Tagline (e.g. "GOAL SCORED BY" / "FINAL") — small label above the hero
	# row, only visible for events that have a hero subject (goal scorer,
	# game-over winner). Hidden for FACEOFF / END OF PERIOD where the phase
	# label itself is the hero. Color is re-tinted per-goal to the scoring
	# team's secondary; the cream default is the fallback for non-team contexts.
	_tagline_label = HudChrome.lbl("", 16, MenuStyle.BROADCAST_CREAM)
	_tagline_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tagline_label.visible = false
	vbox.add_child(_tagline_label)

	# Hero row for non-goal phases: "FACEOFF" / "END OF PERIOD" / "HOME WINS"
	_phase_label = HudChrome.lbl("", 44, MenuStyle.BROADCAST_CREAM)
	_phase_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_phase_label)

	# Hero row for goal phase: the scorer's name, big and bold. Color is
	# overridden per-goal to the scoring team's secondary color.
	_scorer_label = HudChrome.lbl("", 52, MenuStyle.BROADCAST_CREAM)
	_scorer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_scorer_label.visible = false
	vbox.add_child(_scorer_label)

	# "ASSISTED BY" tag — secondary tagline between the hero and the assist
	# names. Hidden when there are no assists.
	_assist_tag_label = HudChrome.lbl("ASSISTED BY", 16, MenuStyle.BROADCAST_CREAM)
	_assist_tag_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_assist_tag_label.visible = false
	vbox.add_child(_assist_tag_label)

	# Assist player names (e.g. "PLAYER1  /  PLAYER2") — sub-hero row
	_assist_label = HudChrome.lbl("", 24, MenuStyle.BROADCAST_CREAM)
	_assist_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_assist_label.visible = false
	vbox.add_child(_assist_label)

	_wrapper.visible = false

# "GOAL" wash banner — slides in from the left and overlays the scorebug for
# the dramatic moment of a goal.
func build_wash(scale_root: Control) -> void:
	# bg_color is a placeholder; play_wash re-tints the whole panel in the
	# scoring team's primary color per goal, so the entire bar reads as that
	# team's wash overlaying the scorebug.
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = MenuStyle.BROADCAST_BG
	panel_style.set_corner_radius_all(4)
	panel_style.anti_aliasing = false
	_wash_style = panel_style

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", panel_style)
	_wash_panel = panel

	var text_margin := MarginContainer.new()
	text_margin.add_theme_constant_override("margin_left", 14)
	text_margin.add_theme_constant_override("margin_right", 14)
	text_margin.add_theme_constant_override("margin_top", 8)
	text_margin.add_theme_constant_override("margin_bottom", 8)
	panel.add_child(text_margin)
	_wash_label = HudChrome.lbl("G  O  A  L", 32, MenuStyle.BROADCAST_CREAM)
	_wash_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_wash_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	text_margin.add_child(_wash_label)

	_wash_root = MenuStyle.wrap_drop_shadow(panel, Vector2(4, 4))
	_wash_root.position = Vector2(8, 8)
	_wash_root.visible = false
	scale_root.add_child(_wash_root)

# `scorebug_size` matches the wash to the scorebug's current rendered size so it
# overlays pixel-exact, regardless of font / margin / scoreboard-content drift.
func play_wash(primary: Color, secondary: Color, scorebug_size: Vector2) -> void:
	if _wash_tween != null and _wash_tween.is_running():
		_wash_tween.kill()
	_wash_style.bg_color = primary
	_wash_label.add_theme_color_override("font_color", secondary)
	if scorebug_size != Vector2.ZERO:
		_wash_panel.custom_minimum_size = scorebug_size
	# Off-screen left of the screen edge so the slide-in feels like it enters
	# the frame from outside the viewport, not from a halfway position.
	_wash_root.position = Vector2(-300, 8)
	_wash_root.visible = true
	_wash_tween = create_tween()
	_wash_tween.tween_property(_wash_root, "position:x", 8.0, 0.4) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_wash_tween.tween_interval(2.0)
	_wash_tween.tween_property(_wash_root, "position:x", -300.0, 0.4) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_wash_tween.tween_callback(func() -> void: _wash_root.visible = false)

# ── Goal template ────────────────────────────────────────────────────────────

# Loads the chyron rows with this goal's data so the replay handler only has to
# toggle visibility.
func preload_goal(scorer_name: String, assist1_name: String, assist2_name: String,
		primary: Color, secondary: Color) -> void:
	_tagline_label.text = "GOAL SCORED BY"
	_tagline_label.add_theme_color_override("font_color", secondary)
	_phase_label.visible = false
	_scorer_label.text = scorer_name
	_scorer_label.add_theme_color_override("font_color", secondary)
	# Restore the goal-chyron tag — game over borrows this label for
	# "STAR OF THE GAME", so re-stamp it on every goal preload.
	_assist_tag_label.text = "ASSISTED BY"
	_assist_tag_label.add_theme_color_override("font_color", secondary)
	_assist_label.add_theme_color_override("font_color", secondary)
	_style.bg_color = primary
	if not assist1_name.is_empty():
		var assist_text: String = assist1_name
		if not assist2_name.is_empty():
			assist_text += "  /  " + assist2_name
		_assist_label.text = assist_text
	else:
		_assist_label.text = ""

# Reset the four goal-template rows (tagline, scorer, ASSISTED BY, assist
# names) to hidden so non-goal phases show only the phase_label hero.
func clear_goal_template() -> void:
	_tagline_label.visible = false
	_scorer_label.visible = false
	_assist_tag_label.visible = false
	_assist_label.visible = false

# ── Replay phase ─────────────────────────────────────────────────────────────

func on_replay_started() -> void:
	# The labels were preloaded by preload_goal; slide the band up from below
	# the screen so the entry feels like a broadcast lower-third drop-in.
	_tagline_label.visible = true
	_scorer_label.visible = not _scorer_label.text.is_empty()
	_assist_tag_label.visible = not _assist_label.text.is_empty()
	_assist_label.visible = not _assist_label.text.is_empty()
	_slide_in()

func on_replay_stopped() -> void:
	# Instant hide on the chyron (no slide-out): the natural follow-up is the
	# FACEOFF banner appearing in the same spot, and a slide-out would just
	# add a flicker between the two. Reset offsets so any subsequent show
	# (e.g. FACEOFF) appears at rest.
	# Skip the hide if the faceoff countdown is already up: on clients the
	# host's faceoff_positions RPC can land before our local replay's outro
	# ends, in which case the countdown is already showing "FACEOFF IN 2" and
	# hiding the wrapper here would erase it.
	if _countdown_tween != null and _countdown_tween.is_valid():
		return
	_wrapper.visible = false
	if _banner_root != null:
		_banner_root.offset_top = -220.0
		_banner_root.offset_bottom = -50.0

# Slide the chyron up from below the screen on goal replays. Non-goal phases
# call show_at_rest() instead so they appear instantly at the resting position.
func _slide_in() -> void:
	if _slide_tween != null and _slide_tween.is_running():
		_slide_tween.kill()
	# Park the band below the screen, then animate up. The band height is 170
	# (offset_top -220 vs offset_bottom -50); 220 of offset moves it fully off.
	_banner_root.offset_top = 0.0
	_banner_root.offset_bottom = 170.0
	_wrapper.visible = true
	_slide_tween = create_tween().set_parallel(true)
	_slide_tween.tween_property(_banner_root, "offset_top", -220.0, 0.4) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_slide_tween.tween_property(_banner_root, "offset_bottom", -50.0, 0.4) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

func show_at_rest() -> void:
	if _slide_tween != null and _slide_tween.is_running():
		_slide_tween.kill()
	_banner_root.offset_top = -220.0
	_banner_root.offset_bottom = -50.0
	_wrapper.visible = true

func hide_banner() -> void:
	_wrapper.visible = false

# ── Phase heroes ─────────────────────────────────────────────────────────────

# A single untinted hero line at rest: "DROP!" / "END OF PERIOD" / "FACEOFF".
func show_hero(text: String) -> void:
	_phase_label.text = text
	_reset_hero_styling()
	show_at_rest()

func on_play_resumed() -> void:
	_wrapper.visible = false
	_phase_label.add_theme_color_override("font_color", MenuStyle.BROADCAST_CREAM)
	_style.bg_color = MenuStyle.BROADCAST_BG
	clear_goal_template()

func show_final(result_text: String, result_color: Color) -> void:
	_style.bg_color = MenuStyle.BROADCAST_BG  # clear any residual goal tint
	_tagline_label.text = "FINAL"
	# Clear the last goal's team tint (preload_goal overrides this label's color
	# per-goal); FINAL is a non-team context, so it reads in the default.
	_tagline_label.add_theme_color_override("font_color", MenuStyle.BROADCAST_CREAM)
	_tagline_label.visible = true
	_phase_label.visible = true
	_scorer_label.visible = false
	_assist_tag_label.visible = false
	_assist_label.visible = false
	_phase_label.text = result_text
	_phase_label.add_theme_color_override("font_color", result_color)
	show_at_rest()

func _reset_hero_styling() -> void:
	_phase_label.add_theme_color_override("font_color", MenuStyle.BROADCAST_CREAM)
	_phase_label.visible = true
	_style.bg_color = MenuStyle.BROADCAST_BG

# ── Faceoff countdown ────────────────────────────────────────────────────────

# Held from the announcement signals until the countdown consumes them, so the
# banner leads with the matchup card / period card / skate-in hold before the
# numbered beats.
func queue_intro(seconds: float) -> void:
	_pending_intro_secs = seconds

func queue_skate(seconds: float) -> void:
	_pending_skate_secs = seconds

func queue_period_intro(period: int, seconds: float) -> void:
	_pending_period_intro_num = period
	_pending_period_intro_secs = seconds

# Fires on the same reliable beat that teleports the local skater to the dot, so
# the countdown banner can't appear on a client before the skater is in position.
func begin_faceoff_prep() -> void:
	clear_goal_template()
	_reset_hero_styling()
	show_at_rest()
	start_faceoff_countdown()

# Drives a "2 → 1 → DROP!" countdown on the phase banner during FACEOFF_PREP.
# Pure cosmetic: the puck unlock is gated by the authoritative phase change to
# FACEOFF, so a client running a frame or two behind still sees the right beat.
# On the opening faceoff (queue_intro arrived just before this), the full-screen
# matchup roster overlay leads for the intro window — the camera sweep plays
# under it — then hands off to the normal banner countdown.
func start_faceoff_countdown() -> void:
	stop_faceoff_countdown()
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
		_wrapper.visible = false
		matchup_intro_requested.emit()
		t.tween_interval(intro)
		t.tween_callback(func() -> void:
			matchup_intro_dismissed.emit()
			if _wrapper != null:
				_wrapper.visible = true
			if _phase_label != null:
				_phase_label.text = "FACEOFF IN 2")
	elif period_card > 0.0:
		# Period-start card over the camera sweep + bench skate-on, then the
		# normal countdown lands on the extended drop.
		_phase_label.text = HudChrome.period_intro_title(period_num)
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
	_countdown_tween = t

func stop_faceoff_countdown() -> void:
	if _countdown_tween != null and _countdown_tween.is_valid():
		_countdown_tween.kill()
	_countdown_tween = null
	# The matchup screen lives under this tween's watch (its dismissal is a
	# tween callback), so an interrupted countdown must take it down too.
	matchup_intro_dismissed.emit()
