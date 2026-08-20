class_name GameOverPopup
extends CanvasLayer

# Full-screen end-of-game presentation, scrim-first: one dim wash over the
# highlight reel, typography sitting directly on it — no boxed cards, so the
# footage stays visible everywhere. Three bands: FINAL score + result up top,
# the Three Stars reveal (3rd → 2nd → 1st, arena order) in the middle, and the
# post-game actions in a strip along the bottom. HUD owns the timing (it lets
# the final-horn banner beat play on the ice first, then calls present());
# this class is pure presentation + the action buttons.
#
# The box score is NOT embedded here — Tab still toggles the Scoreboard, which
# renders on a higher layer, so the deep numbers stay one keypress away while
# this screen carries the moment (score, stars, what-next).

signal rematch_toggled
signal lobby_vote_toggled
signal free_play_pressed
signal exit_pressed
signal analytics_pressed

const _GOLD := MenuStyle.GOLD
const _WHITE := MenuStyle.BROADCAST_CREAM
const _DIM := MenuStyle.BROADCAST_DIM

# Reveal cadence: bands settle first, then stars land 3rd → 2nd → 1st so the
# first star is the climax beat (the arena announcement order).
const _STAR_REVEAL_DELAY: float = 0.55
const _STAR_REVEAL_GAP: float = 0.55

const _MAX_STARS: int = 3
# Translation keys, tr()'d at the display seam (see _build_star_row); localized
# copy lives in locale/translations.csv.
const _RANK_TAG_KEYS: Array[String] = ["STAR_FIRST", "STAR_SECOND", "STAR_THIRD"]
# First star reads bigger than the runners-up — rank is carried by scale and
# color, not by borders.
const _RANK_NAME_SIZES: Array[int] = [38, 24, 24]
const _RANK_LINE_SIZES: Array[int] = [16, 13, 13]
const _RANK_STRIPE_HEIGHTS: Array[int] = [34, 22, 22]
const _RANK_ROW_HEIGHTS: Array[int] = [50, 32, 32]
# Gap between the center stripe column and the tag / name on either side.
const _STRIPE_GUTTER: float = 16.0

var _root: Control = null
var _scrim: ColorRect = null
var _top_block: VBoxContainer = null
var _stars_block: VBoxContainer = null
var _bottom_block: VBoxContainer = null
var _home_stripe_style: StyleBoxFlat = null
var _away_stripe_style: StyleBoxFlat = null
var _home_score_label: Label = null
var _away_score_label: Label = null
var _result_label: Label = null
var _stars_tag: Label = null
var _star_rows: Array[Control] = []
var _star_name_labels: Array[Label] = []
var _star_line_labels: Array[Label] = []
var _star_stripe_styles: Array[StyleBoxFlat] = []
var _rematch_btn: Button = null
var _lobby_btn: Button = null
var _vote_label: Label = null
var _present_tween: Tween = null


func _ready() -> void:
	layer = 5
	_build_ui()
	visible = false


# The popup's content root, handed to a screen that opens OVER this one (the
# analytics reader) so focus can be walled off from these buttons while it's up.
func focus_root() -> Control:
	return _root


func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)
	_root = root

	# Scrim dims the highlight reel behind the presentation and makes this
	# modal — same dim every popup uses.
	_scrim = ColorRect.new()
	_scrim.color = MenuStyle.SCRIM
	_scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(_scrim)

	_build_top_block(root)
	_build_stars_block(root)
	_build_bottom_block(root)


# FINAL tag + hero score row + result headline, pinned to the upper band so
# the middle of the frame stays open for the reel and the stars.
func _build_top_block(root: Control) -> void:
	_top_block = VBoxContainer.new()
	_top_block.alignment = BoxContainer.ALIGNMENT_BEGIN
	_top_block.add_theme_constant_override("separation", 10)
	_top_block.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_top_block.offset_top = 64
	root.add_child(_top_block)

	var final_tag := _lbl(tr(&"FINAL"), 18, _DIM)
	final_tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_top_block.add_child(final_tag)

	_top_block.add_child(_build_score_row())

	_result_label = _lbl("", 52, _WHITE)
	_result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_top_block.add_child(_result_label)


# [stripe] HOME  3   —   2  AWAY [stripe] — the scorebug's stripe language at
# hero scale, so the final score reads in the same visual system as the game.
func _build_score_row() -> Control:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 14)

	_home_stripe_style = _stripe_style()
	row.add_child(_stripe(_home_stripe_style))
	row.add_child(_lbl(tr(&"TEAM_HOME"), 24, _WHITE))
	_home_score_label = _lbl("0", 56, _WHITE)
	row.add_child(_home_score_label)

	var dash := _lbl("—", 30, _DIM)
	dash.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(dash)

	_away_score_label = _lbl("0", 56, _WHITE)
	row.add_child(_away_score_label)
	row.add_child(_lbl(tr(&"TEAM_AWAY"), 24, _WHITE))
	_away_stripe_style = _stripe_style()
	row.add_child(_stripe(_away_stripe_style))
	return row


# Three star rows, typography straight on the scrim. Every row is anchored
# around the screen's horizontal center: the team stripe IS the center column,
# rank tags right-align to it, names flow left-aligned from it — so all three
# stripes (and both text spines) line up exactly regardless of name length.
func _build_stars_block(root: Control) -> void:
	_stars_block = VBoxContainer.new()
	_stars_block.alignment = BoxContainer.ALIGNMENT_CENTER
	_stars_block.add_theme_constant_override("separation", 14)
	_stars_block.set_anchors_preset(Control.PRESET_FULL_RECT)
	_stars_block.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_stars_block)

	_stars_tag = _lbl(tr("STARS_OF_THE_GAME"), 15, _GOLD)
	_stars_tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_stars_block.add_child(_stars_tag)

	for rank: int in _MAX_STARS:
		_stars_block.add_child(_build_star_row(rank))


func _build_star_row(rank: int) -> Control:
	var row := Control.new()
	row.custom_minimum_size = Vector2(0, _RANK_ROW_HEIGHTS[rank])
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var first: bool = rank == 0
	var tag := _lbl(tr(_RANK_TAG_KEYS[rank]), 14 if first else 12, _GOLD if first else _DIM)
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	tag.set_anchors_preset(Control.PRESET_FULL_RECT)
	tag.anchor_right = 0.5
	tag.offset_right = -_STRIPE_GUTTER
	row.add_child(tag)

	var stripe_style := _stripe_style()
	_star_stripe_styles.append(stripe_style)
	var stripe := _stripe(stripe_style, _RANK_STRIPE_HEIGHTS[rank])
	stripe.set_anchors_preset(Control.PRESET_CENTER)
	stripe.offset_left = -3.0
	stripe.offset_right = 3.0
	stripe.offset_top = -_RANK_STRIPE_HEIGHTS[rank] / 2.0
	stripe.offset_bottom = _RANK_STRIPE_HEIGHTS[rank] / 2.0
	row.add_child(stripe)

	var content := HBoxContainer.new()
	content.add_theme_constant_override("separation", 12)
	content.set_anchors_preset(Control.PRESET_FULL_RECT)
	content.anchor_left = 0.5
	content.offset_left = _STRIPE_GUTTER
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(content)

	var name_label := _lbl("", _RANK_NAME_SIZES[rank], _WHITE)
	name_label.uppercase = true
	name_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_star_name_labels.append(name_label)
	content.add_child(name_label)

	var line_label := _lbl("", _RANK_LINE_SIZES[rank], _DIM)
	line_label.add_theme_font_override("font", MenuStyle.UI_FONT)
	line_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_star_line_labels.append(line_label)
	content.add_child(line_label)

	_star_rows.append(row)
	return row


# Action strip along the bottom: horizontal buttons, vote tally, box-score hint.
func _build_bottom_block(root: Control) -> void:
	_bottom_block = VBoxContainer.new()
	_bottom_block.alignment = BoxContainer.ALIGNMENT_END
	_bottom_block.add_theme_constant_override("separation", 8)
	_bottom_block.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_bottom_block.offset_top = -190
	_bottom_block.offset_bottom = -36
	_bottom_block.grow_vertical = Control.GROW_DIRECTION_BEGIN
	root.add_child(_bottom_block)

	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", 12)
	_bottom_block.add_child(actions)

	# Leads the strip: the analytics screen is a VIEW of the game just played,
	# so it sits ahead of the what-next actions rather than among them.
	var analytics_btn := _action_button(tr(&"GAME_OVER_ANALYTICS"))
	analytics_btn.pressed.connect(func() -> void: analytics_pressed.emit())
	actions.add_child(analytics_btn)

	_rematch_btn = _action_button(tr(&"GAME_OVER_REMATCH"))
	_rematch_btn.pressed.connect(func() -> void: rematch_toggled.emit())
	actions.add_child(_rematch_btn)

	# "Return to Lobby" is the second flavor of the same play-again vote (see
	# RematchVoteRules): once the pool is unanimous, any lobby vote routes the
	# whole group to the shared lobby instead of an instant rematch. Shown
	# unconditionally — every real match starts from the unified lobby (offline
	# included), and game over never fires in the lobby-less modes (free play,
	# tutorial, drills). Offline the voter pool is just the host, so the vote
	# resolves on the click; a host who wants to force the lobby without
	# waiting on the vote still has the pause menu's instant Return to Lobby.
	_lobby_btn = _action_button(tr(&"GAME_OVER_RETURN_LOBBY"))
	_lobby_btn.pressed.connect(func() -> void: lobby_vote_toggled.emit())
	actions.add_child(_lobby_btn)

	# Always available: drop to solo free play. Offline this is the only leave
	# action; for an online client it disconnects just them; for an online host
	# it tears down the server (everyone drops out).
	var free_play_btn := _action_button(tr(&"GAME_OVER_RETURN_FREE_PLAY"))
	free_play_btn.pressed.connect(func() -> void: free_play_pressed.emit())
	actions.add_child(free_play_btn)

	var exit_btn := _action_button(tr(&"GAME_OVER_EXIT"))
	exit_btn.pressed.connect(func() -> void: exit_pressed.emit())
	actions.add_child(exit_btn)

	_vote_label = Label.new()
	_vote_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_vote_label.add_theme_font_size_override("font_size", 13)
	_vote_label.add_theme_color_override("font_color", Color(0.62, 0.62, 0.68, 1.0))
	_bottom_block.add_child(_vote_label)

	var hint := _lbl(tr(&"HINT_TAB_BOX_SCORE"), 12, MenuStyle.TEXT_MUTED)
	hint.add_theme_font_override("font", MenuStyle.UI_FONT)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_bottom_block.add_child(hint)


# Fill the screen with this game's data and play the reveal: scrim + bands
# fade in, then the stars land 3rd → 2nd → 1st. `star_names` is ranked best
# first and may be shorter than three (empty = a nothing game, the whole
# stars block stays hidden).
func present(home_score: int, away_score: int,
		home_stripe: Color, away_stripe: Color,
		result_text: String, result_color: Color,
		star_names: Array[String], star_lines: Array[String],
		star_stripes: Array[Color]) -> void:
	_home_score_label.text = str(home_score)
	_away_score_label.text = str(away_score)
	_home_stripe_style.bg_color = home_stripe
	_away_stripe_style.bg_color = away_stripe
	_result_label.text = result_text
	_result_label.add_theme_color_override("font_color", result_color)

	var star_count: int = mini(star_names.size(), _MAX_STARS)
	_stars_tag.visible = star_count > 0
	for rank: int in _MAX_STARS:
		var filled: bool = rank < star_count
		_star_rows[rank].visible = filled
		if filled:
			_star_name_labels[rank].text = star_names[rank]
			_star_line_labels[rank].text = star_lines[rank]
			_star_line_labels[rank].visible = not star_lines[rank].is_empty()
			_star_stripe_styles[rank].bg_color = star_stripes[rank]

	visible = true
	# Controller: focus the primary action (Rematch, or Lobby when Rematch is
	# hidden for spectators) so the pad can act on the post-game screen.
	if _rematch_btn != null and _rematch_btn.visible:
		ControllerNav.grab_focus(_rematch_btn)
	elif _lobby_btn != null:
		ControllerNav.grab_focus(_lobby_btn)
	if _present_tween != null and _present_tween.is_running():
		_present_tween.kill()
	_scrim.modulate.a = 0.0
	_top_block.modulate.a = 0.0
	_bottom_block.modulate.a = 0.0
	for rank: int in star_count:
		_star_rows[rank].modulate.a = 0.0
	_present_tween = create_tween()
	_present_tween.tween_property(_scrim, "modulate:a", 1.0, 0.30)
	_present_tween.parallel().tween_property(_top_block, "modulate:a", 1.0, 0.35) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_present_tween.parallel().tween_property(_bottom_block, "modulate:a", 1.0, 0.35) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	if star_count > 0:
		_present_tween.tween_interval(_STAR_REVEAL_DELAY)
		# Arena order: lowest rank announced first, first star last.
		for rank: int in range(star_count - 1, -1, -1):
			_append_star_reveal(rank)
			if rank > 0:
				_present_tween.tween_interval(_STAR_REVEAL_GAP)


# One star row's landing: quick fade with a spring settle from a slight
# overscale, scaled up for the first star.
func _append_star_reveal(rank: int) -> void:
	var row: Control = _star_rows[rank]
	var overscale: float = 1.14 if rank == 0 else 1.08
	_present_tween.tween_callback(func() -> void:
		row.pivot_offset = row.size / 2.0
		row.scale = Vector2(overscale, overscale))
	_present_tween.tween_property(row, "modulate:a", 1.0, 0.18)
	_present_tween.parallel().tween_property(row, "scale", Vector2.ONE, 0.35) \
		.set_trans(Tween.TRANS_SPRING).set_ease(Tween.EASE_OUT)


func set_spectator(is_spec: bool) -> void:
	_rematch_btn.visible = not is_spec
	_lobby_btn.visible = not is_spec
	_vote_label.visible = not is_spec


func hide_popup() -> void:
	if _present_tween != null and _present_tween.is_running():
		_present_tween.kill()
	visible = false


# `votes` is peer_id -> RematchVoteRules.Choice; `local_vote` is the local
# player's current flavor. The button you voted flips to "Unvote" (pressing
# the other flavor switches the vote instead); the tally line flags when the
# pool is already headed to the lobby.
func update_votes(votes: Dictionary[int, int], total_voters: int, local_vote: int) -> void:
	_rematch_btn.text = tr(&"GAME_OVER_UNVOTE") \
			if local_vote == RematchVoteRules.Choice.REMATCH else tr(&"GAME_OVER_REMATCH")
	_lobby_btn.text = tr(&"GAME_OVER_UNVOTE") \
			if local_vote == RematchVoteRules.Choice.LOBBY else tr(&"GAME_OVER_RETURN_LOBBY")
	var count: int = RematchVoteRules.count_voted(votes)
	# One key per phrasing rather than a suffix appended to the tally: the
	# clause does not attach at the end in every language.
	var key: StringName = &"GAME_OVER_VOTE_TALLY_LOBBY" \
			if RematchVoteRules.has_lobby_vote(votes) else &"GAME_OVER_VOTE_TALLY"
	_vote_label.text = tr(key) % [count, total_voters]


# Slimmer than MenuStyle.popup_button so four of them sit comfortably in one
# bottom strip; same hover/sound wiring.
func _action_button(label: String) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.custom_minimum_size = Vector2(170, 44)
	btn.add_theme_font_size_override("font_size", 17)
	MenuStyle.wire_hover_scale(btn)
	SoundManager.wire_button(btn)
	MenuStyle.apply_focus_ring(btn)
	return btn


func _stripe_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.5, 0.5, 0.5)
	s.set_corner_radius_all(2)
	return s


func _stripe(style: StyleBoxFlat, height: int = 40) -> Panel:
	var p := Panel.new()
	p.add_theme_stylebox_override("panel", style)
	p.custom_minimum_size = Vector2(6, height)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return p


func _lbl(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", MenuStyle.DISPLAY_FONT)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l
