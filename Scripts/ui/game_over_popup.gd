class_name GameOverPopup
extends CanvasLayer

# Full-screen end-of-game presentation: scrim → FINAL score card → winner
# headline → Star of the Game reveal → post-game actions. HUD owns the timing
# (it lets the final-horn banner beat play on the ice first, then calls
# present()); this class is pure presentation + the action buttons.
#
# The box score is NOT embedded here — Tab still toggles the Scoreboard, which
# renders on a higher layer, so the deep numbers stay one keypress away while
# this screen carries the moment (score, star, what-next).

signal rematch_toggled
signal host_action_pressed
signal free_play_pressed
signal exit_pressed

const _GOLD := MenuStyle.GOLD
const _WHITE := MenuStyle.BROADCAST_CREAM
const _DIM := MenuStyle.BROADCAST_DIM

const _STAR_REVEAL_DELAY: float = 0.6

var _scrim: ColorRect = null
var _content: VBoxContainer = null
var _home_stripe_style: StyleBoxFlat = null
var _away_stripe_style: StyleBoxFlat = null
var _home_score_label: Label = null
var _away_score_label: Label = null
var _result_label: Label = null
var _star_card: Control = null
var _star_name_label: Label = null
var _star_line_label: Label = null
var _star_stripe_style: StyleBoxFlat = null
var _rematch_btn: Button = null
var _vote_label: Label = null
var _host_btn: Button = null
var _present_tween: Tween = null


func _ready() -> void:
	layer = 5
	_build_ui()
	visible = false


func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	# Scrim dims the frozen ice behind the presentation and makes this modal —
	# same dim every popup uses.
	_scrim = ColorRect.new()
	_scrim.color = MenuStyle.SCRIM
	_scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(_scrim)

	var centering := CenterContainer.new()
	centering.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(centering)

	_content = VBoxContainer.new()
	_content.alignment = BoxContainer.ALIGNMENT_CENTER
	_content.add_theme_constant_override("separation", 18)
	centering.add_child(_content)

	var final_tag := _lbl("FINAL", 18, _DIM)
	final_tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_content.add_child(final_tag)

	_content.add_child(_build_score_row())

	_result_label = _lbl("", 52, _WHITE)
	_result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_content.add_child(_result_label)

	_content.add_child(_build_star_card())

	var actions := VBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", 8)
	_content.add_child(actions)

	var rematch_box := VBoxContainer.new()
	rematch_box.add_theme_constant_override("separation", 4)
	actions.add_child(rematch_box)

	_rematch_btn = MenuStyle.popup_button("Rematch")
	_rematch_btn.pressed.connect(func() -> void: rematch_toggled.emit())
	rematch_box.add_child(_rematch_btn)

	_vote_label = Label.new()
	_vote_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_vote_label.add_theme_font_size_override("font_size", 13)
	_vote_label.add_theme_color_override("font_color", Color(0.62, 0.62, 0.68, 1.0))
	rematch_box.add_child(_vote_label)

	# "Return to Lobby" only exists for an online host — it pulls the whole
	# group back to the shared lobby. Offline has no lobby, and clients can't
	# drive everyone's scene, so neither sees this button.
	if NetworkManager.is_host and not NetworkManager.is_offline_mode:
		_host_btn = MenuStyle.popup_button("Return to Lobby")
		_host_btn.pressed.connect(func() -> void: host_action_pressed.emit())
		actions.add_child(_host_btn)

	# Always available: drop to solo free play. Offline this is the only leave
	# action; for an online client it disconnects just them; for an online host
	# it tears down the server (everyone drops out).
	var free_play_btn := MenuStyle.popup_button("Return to Free Play")
	free_play_btn.pressed.connect(func() -> void: free_play_pressed.emit())
	actions.add_child(free_play_btn)

	var exit_btn := MenuStyle.popup_button("Exit Game")
	exit_btn.pressed.connect(func() -> void: exit_pressed.emit())
	actions.add_child(exit_btn)

	var hint := _lbl("TAB · BOX SCORE", 12, MenuStyle.TEXT_MUTED)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_content.add_child(hint)


# [stripe] HOME  3   —   2  AWAY [stripe] — the scorebug's stripe language at
# hero scale, so the final score reads in the same visual system as the game.
func _build_score_row() -> Control:
	var wrap := HBoxContainer.new()
	wrap.alignment = BoxContainer.ALIGNMENT_CENTER
	wrap.add_theme_constant_override("separation", 14)

	_home_stripe_style = _stripe_style()
	wrap.add_child(_stripe(_home_stripe_style))
	wrap.add_child(_lbl("HOME", 24, _WHITE))
	_home_score_label = _lbl("0", 56, _WHITE)
	wrap.add_child(_home_score_label)

	var dash := _lbl("—", 30, _DIM)
	dash.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	wrap.add_child(dash)

	_away_score_label = _lbl("0", 56, _WHITE)
	wrap.add_child(_away_score_label)
	wrap.add_child(_lbl("AWAY", 24, _WHITE))
	_away_stripe_style = _stripe_style()
	wrap.add_child(_stripe(_away_stripe_style))
	return wrap


func _build_star_card() -> Control:
	var card_wrap := HBoxContainer.new()
	card_wrap.alignment = BoxContainer.ALIGNMENT_CENTER
	_star_card = card_wrap

	var style := StyleBoxFlat.new()
	style.bg_color = MenuStyle.BROADCAST_BG
	style.set_corner_radius_all(4)
	style.anti_aliasing = false
	style.set_border_width_all(1)
	style.border_color = Color(_GOLD.r, _GOLD.g, _GOLD.b, 0.55)
	style.set_content_margin(SIDE_LEFT, 34)
	style.set_content_margin(SIDE_RIGHT, 34)
	style.set_content_margin(SIDE_TOP, 12)
	style.set_content_margin(SIDE_BOTTOM, 14)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", style)
	card_wrap.add_child(MenuStyle.wrap_drop_shadow(panel, Vector2(4, 4)))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	panel.add_child(row)

	# Team-color stripe ties the star to their side at a glance.
	_star_stripe_style = _stripe_style()
	row.add_child(_stripe(_star_stripe_style, 44))

	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 2)
	row.add_child(col)

	var tag := _lbl("★  STAR OF THE GAME  ★", 14, _GOLD)
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(tag)

	_star_name_label = _lbl("", 32, _WHITE)
	_star_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_star_name_label)

	_star_line_label = _lbl("", 16, _DIM)
	_star_line_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_star_line_label)

	return card_wrap


# Fill the screen with this game's data and play the reveal: scrim + content
# fade in, then the star card pops in a beat later. `star_name` empty = no star
# (a nothing game with no counting stats), the card stays hidden.
func present(home_score: int, away_score: int,
		home_stripe: Color, away_stripe: Color,
		result_text: String, result_color: Color,
		star_name: String, star_line: String, star_stripe: Color) -> void:
	_home_score_label.text = str(home_score)
	_away_score_label.text = str(away_score)
	_home_stripe_style.bg_color = home_stripe
	_away_stripe_style.bg_color = away_stripe
	_result_label.text = result_text
	_result_label.add_theme_color_override("font_color", result_color)

	var has_star: bool = not star_name.is_empty()
	_star_card.visible = has_star
	if has_star:
		_star_name_label.text = star_name
		_star_line_label.text = star_line
		_star_line_label.visible = not star_line.is_empty()
		_star_stripe_style.bg_color = star_stripe

	visible = true
	if _present_tween != null and _present_tween.is_running():
		_present_tween.kill()
	_scrim.modulate.a = 0.0
	_content.modulate.a = 0.0
	if has_star:
		_star_card.modulate.a = 0.0
	_present_tween = create_tween()
	_present_tween.tween_property(_scrim, "modulate:a", 1.0, 0.30)
	_present_tween.parallel().tween_property(_content, "modulate:a", 1.0, 0.35) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	if has_star:
		_present_tween.tween_interval(_STAR_REVEAL_DELAY)
		_present_tween.tween_callback(func() -> void:
			_star_card.pivot_offset = _star_card.size / 2.0
			_star_card.scale = Vector2(1.12, 1.12))
		_present_tween.tween_property(_star_card, "modulate:a", 1.0, 0.20)
		_present_tween.parallel().tween_property(_star_card, "scale", Vector2.ONE, 0.35) \
			.set_trans(Tween.TRANS_SPRING).set_ease(Tween.EASE_OUT)


func set_spectator(is_spec: bool) -> void:
	_rematch_btn.visible = not is_spec
	_vote_label.visible = not is_spec


func hide_popup() -> void:
	if _present_tween != null and _present_tween.is_running():
		_present_tween.kill()
	visible = false


func update_votes(votes: Dictionary, total_voters: int, local_voted: bool) -> void:
	_rematch_btn.text = "Unvote" if local_voted else "Rematch"
	var count: int = 0
	for v: bool in votes.values():
		if v:
			count += 1
	_vote_label.text = "%d / %d voted" % [count, total_voters]


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
