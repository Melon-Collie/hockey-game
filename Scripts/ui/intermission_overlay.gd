class_name IntermissionOverlay
extends CanvasLayer

# Between-periods presentation, scrim-first like the game-over screen but
# lighter: the period's goal replays roll behind a soft dim wash while a top
# band carries "END OF 1ST PERIOD" + the score, a lower-third caption credits
# the goal currently replaying, and a bottom-right skip line mirrors the HUD's
# vote tally. Pure presentation — no buttons; the skip vote itself stays on
# the HUD's skip_replay action, and Tab's box score renders on a higher layer
# over this as usual.
#
# Owned by HUD, driven by GameManager's intermission_* signals.

const _WHITE := MenuStyle.BROADCAST_CREAM
const _DIM := MenuStyle.BROADCAST_DIM

# Lighter than the modal MenuStyle.SCRIM (0.55): the replays are the content
# here, the wash just seats the typography on them.
const _REEL_SCRIM := Color(0.024, 0.039, 0.071, 0.32)

var _scrim: ColorRect = null
var _band: VBoxContainer = null
var _title_label: Label = null
var _home_stripe_style: StyleBoxFlat = null
var _away_stripe_style: StyleBoxFlat = null
var _home_score_label: Label = null
var _away_score_label: Label = null
var _caption_block: VBoxContainer = null
var _caption_tag: Label = null
var _caption_scorer: Label = null
var _caption_assists: Label = null
var _skip_label: Label = null
var _countdown_label: Label = null
var _present_tween: Tween = null
var _caption_tween: Tween = null
var _skip_pulse: Tween = null

# Break time remaining, counted down locally (seeded from the shared
# GameRules constants on every peer, so it tracks the host's end timer up to
# clock skew — cosmetic). Label text only rebuilds when the displayed second
# changes.
var _countdown_left: float = 0.0
var _last_countdown_secs: int = -1


func _ready() -> void:
	layer = 4  # over HUD chrome, under GameOverPopup (5) and the Tab box score
	_build_ui()
	visible = false


func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_scrim = ColorRect.new()
	_scrim.color = _REEL_SCRIM
	_scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_scrim)

	_band = VBoxContainer.new()
	_band.alignment = BoxContainer.ALIGNMENT_BEGIN
	_band.add_theme_constant_override("separation", 8)
	_band.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_band.offset_top = 56
	_band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_band)

	_title_label = _lbl("", 40, _WHITE)
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_band.add_child(_title_label)

	_band.add_child(_build_score_row())

	var hint := _lbl("TAB · BOX SCORE", 12, MenuStyle.TEXT_MUTED)
	hint.add_theme_font_override("font", MenuStyle.UI_FONT)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_band.add_child(hint)

	_build_caption(root)

	# Bottom-right skip line, same spot the HUD's replay prompt uses — text is
	# pushed in by the HUD so the vote tally stays single-sourced.
	_skip_label = _lbl("", 18, _WHITE)
	_skip_label.add_theme_font_override("font", MenuStyle.UI_FONT)
	_skip_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_skip_label.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_skip_label.offset_left = -324.0
	_skip_label.offset_right = -52.0
	_skip_label.offset_top = -52.0
	_skip_label.offset_bottom = -24.0
	root.add_child(_skip_label)

	# Break countdown, stacked just above the skip line.
	_countdown_label = _lbl("", 22, _WHITE)
	_countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_countdown_label.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_countdown_label.offset_left = -324.0
	_countdown_label.offset_right = -52.0
	_countdown_label.offset_top = -84.0
	_countdown_label.offset_bottom = -54.0
	root.add_child(_countdown_label)


# Compact version of the game-over score row: [stripe] HOME 2 — 1 AWAY [stripe].
func _build_score_row() -> Control:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)

	_home_stripe_style = _stripe_style()
	row.add_child(_stripe(_home_stripe_style))
	row.add_child(_lbl("HOME", 18, _WHITE))
	_home_score_label = _lbl("0", 40, _WHITE)
	row.add_child(_home_score_label)

	var dash := _lbl("—", 22, _DIM)
	dash.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(dash)

	_away_score_label = _lbl("0", 40, _WHITE)
	row.add_child(_away_score_label)
	row.add_child(_lbl("AWAY", 18, _WHITE))
	_away_stripe_style = _stripe_style()
	row.add_child(_stripe(_away_stripe_style))
	return row


# Lower-third goal credit for the clip currently replaying.
func _build_caption(root: Control) -> void:
	_caption_block = VBoxContainer.new()
	_caption_block.alignment = BoxContainer.ALIGNMENT_END
	_caption_block.add_theme_constant_override("separation", 2)
	_caption_block.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_caption_block.offset_top = -190
	_caption_block.offset_bottom = -110
	_caption_block.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_caption_block.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_caption_block)

	_caption_tag = _lbl("GOAL", 14, MenuStyle.GOLD)
	_caption_tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_caption_block.add_child(_caption_tag)

	_caption_scorer = _lbl("", 30, _WHITE)
	_caption_scorer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_caption_block.add_child(_caption_scorer)

	_caption_assists = _lbl("", 14, _DIM)
	_caption_assists.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_caption_block.add_child(_caption_assists)


func present(title: String, home_score: int, away_score: int,
		home_stripe: Color, away_stripe: Color, countdown_seconds: float) -> void:
	_title_label.text = title
	_home_score_label.text = str(home_score)
	_away_score_label.text = str(away_score)
	_home_stripe_style.bg_color = home_stripe
	_away_stripe_style.bg_color = away_stripe
	_caption_block.modulate.a = 0.0
	_countdown_left = countdown_seconds
	_last_countdown_secs = -1
	_refresh_countdown()
	visible = true
	if _present_tween != null and _present_tween.is_running():
		_present_tween.kill()
	_scrim.modulate.a = 0.0
	_band.modulate.a = 0.0
	_present_tween = create_tween()
	_present_tween.tween_property(_scrim, "modulate:a", 1.0, 0.30)
	_present_tween.parallel().tween_property(_band, "modulate:a", 1.0, 0.35) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	if _skip_pulse != null and _skip_pulse.is_running():
		_skip_pulse.kill()
	_skip_pulse = MenuStyle.pulse(_skip_label)


# Caption the clip that just started. `team_color` tints the GOAL tag with the
# scoring side; empty scorer (untracked scramble) shows a plain GOAL tag.
func set_goal_caption(team_color: Color, scorer_name: String, assist_text: String) -> void:
	_caption_tag.add_theme_color_override("font_color", team_color)
	_caption_scorer.text = scorer_name
	_caption_scorer.visible = not scorer_name.is_empty()
	_caption_assists.text = "ASST: %s" % assist_text
	_caption_assists.visible = not assist_text.is_empty()
	if _caption_tween != null and _caption_tween.is_running():
		_caption_tween.kill()
	_caption_block.modulate.a = 0.0
	_caption_tween = create_tween()
	_caption_tween.tween_property(_caption_block, "modulate:a", 1.0, 0.25) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func set_skip_text(text: String) -> void:
	_skip_label.text = text


func _process(delta: float) -> void:
	if not visible or _countdown_left <= 0.0:
		return
	_countdown_left = maxf(_countdown_left - delta, 0.0)
	_refresh_countdown()


func _refresh_countdown() -> void:
	var secs: int = int(ceilf(_countdown_left))
	if secs == _last_countdown_secs:
		return
	_last_countdown_secs = secs
	_countdown_label.text = "%d:%02d" % [secs / 60, secs % 60]


func hide_overlay() -> void:
	if _present_tween != null and _present_tween.is_running():
		_present_tween.kill()
	if _caption_tween != null and _caption_tween.is_running():
		_caption_tween.kill()
	if _skip_pulse != null and _skip_pulse.is_running():
		_skip_pulse.kill()
	visible = false


func _stripe_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.5, 0.5, 0.5)
	s.set_corner_radius_all(2)
	return s


func _stripe(style: StyleBoxFlat, height: int = 30) -> Panel:
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
