class_name HudScorebug
extends Node

# Top-left broadcast scorebug — team stripes, scores, shots, period and clock —
# plus the screen-centered final-10 countdown the clock drives.

# Advance warnings the clock crosses; the HUD owns the toast stack.
signal warning_toast(text: String, color: Color)

var _panel: PanelContainer = null
var _period_label: Label = null
var _clock_label: Label = null
var _home_score_label: Label = null
var _away_score_label: Label = null
var _home_sog_label: Label = null
var _away_sog_label: Label = null
var _home_badge_style: StyleBoxFlat = null
var _away_badge_style: StyleBoxFlat = null
var _score_0: int = 0
var _score_1: int = 0
var _clock_warning_label: Label = null
var _last_clock_pulse_second: int = -1
var _last_warning_pulse_second: int = -1
var _warned_one_min: bool = false
var _warned_thirty: bool = false

func build(scale_root: Control) -> void:
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = MenuStyle.BROADCAST_BG
	panel_style.set_corner_radius_all(4)
	panel_style.border_color = MenuStyle.BROADCAST_BORDER_T
	panel_style.border_width_top = 1

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", panel_style)
	_panel = panel
	var shadow_wrap := MenuStyle.wrap_drop_shadow(panel, Vector2(4, 4))
	shadow_wrap.position = Vector2(8, 8)
	scale_root.add_child(shadow_wrap)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 0)
	panel.add_child(hbox)

	# === Teams column ===
	# Each team row is [stripe | abbr label | score]. Stripes carry the team
	# color the way a chyron lower-third does.
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
	var away_row := _build_team_row(1, tr(&"TEAM_AWAY"))
	_away_badge_style = away_row.get_meta(&"stripe_style") as StyleBoxFlat
	_away_score_label = away_row.get_meta(&"score_label") as Label
	var away_stripe: Panel = away_row.get_meta(&"stripe") as Panel
	_away_badge_style.corner_radius_top_left = 4
	away_stripe.offset_top = -5
	away_stripe.offset_bottom = 2
	teams_vbox.add_child(away_row)
	var home_row := _build_team_row(0, tr(&"TEAM_HOME"))
	_home_badge_style = home_row.get_meta(&"stripe_style") as StyleBoxFlat
	_home_score_label = home_row.get_meta(&"score_label") as Label
	var home_stripe: Panel = home_row.get_meta(&"stripe") as Panel
	_home_badge_style.corner_radius_bottom_left = 4
	home_stripe.offset_top = -2
	home_stripe.offset_bottom = 4
	teams_vbox.add_child(home_row)

	hbox.add_child(HudChrome.vsep())

	# === Shots column ===
	var shots_cell := HudChrome.cell(10, 4)
	hbox.add_child(shots_cell)
	var shots_vbox := VBoxContainer.new()
	shots_vbox.add_theme_constant_override("separation", 2)
	shots_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	shots_cell.add_child(shots_vbox)
	_away_sog_label = HudChrome.lbl("0", 18, MenuStyle.BROADCAST_CREAM)
	_away_sog_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_away_sog_label.custom_minimum_size = Vector2(28, 0)
	shots_vbox.add_child(_away_sog_label)
	var shots_header := HudChrome.lbl(tr(&"SCOREBUG_SHOTS"), 10, MenuStyle.BROADCAST_DIM)
	shots_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	shots_vbox.add_child(shots_header)
	_home_sog_label = HudChrome.lbl("0", 18, MenuStyle.BROADCAST_CREAM)
	_home_sog_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_home_sog_label.custom_minimum_size = Vector2(28, 0)
	shots_vbox.add_child(_home_sog_label)

	hbox.add_child(HudChrome.vsep())

	# === Period + Clock column ===
	var time_cell := HudChrome.cell(14, 4)
	hbox.add_child(time_cell)
	var time_vbox := VBoxContainer.new()
	time_vbox.add_theme_constant_override("separation", 2)
	time_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	time_cell.add_child(time_vbox)
	_period_label = HudChrome.lbl(HudChrome.period_ordinal(1), 13, MenuStyle.BROADCAST_DIM)
	_period_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	time_vbox.add_child(_period_label)
	_clock_label = HudChrome.lbl(
			HudChrome.format_clock(GameManager.get_period_duration()), 26,
			MenuStyle.BROADCAST_CREAM)
	_clock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_clock_label.custom_minimum_size = Vector2(62, 0)
	time_vbox.add_child(_clock_label)

# One row of the teams column. Returns an HBox whose .get_meta() exposes the
# stripe StyleBox + abbreviation + score Labels for live updates.
func _build_team_row(team_id: int, abbr: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 0)

	var stripe_style := StyleBoxFlat.new()
	stripe_style.bg_color = HudChrome.team_stripe(team_id)
	# Placeholder reserves the 6px column in the HBox; the visible stripe
	# is anchored inside it so the caller can bleed it past the row bounds
	# (offset_top / offset_bottom) to hug the scorebug panel's true edges.
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
	var abbr_label := HudChrome.lbl(abbr, 18, MenuStyle.BROADCAST_CREAM)
	abbr_label.custom_minimum_size = Vector2(50, 0)
	abbr_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	abbr_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	abbr_margin.add_child(abbr_label)

	# Center-aligned in a fixed-width slot so single- vs two-digit scores
	# don't drift visually — under right-alignment "1" reads as offset from
	# "0", the glyphs having different widths.
	var score_margin := MarginContainer.new()
	score_margin.add_theme_constant_override("margin_left", 4)
	score_margin.add_theme_constant_override("margin_right", 8)
	row.add_child(score_margin)
	var score_label := HudChrome.lbl("0", 26, MenuStyle.BROADCAST_CREAM)
	score_label.custom_minimum_size = Vector2(36, 0)
	score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	score_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	score_margin.add_child(score_label)

	row.set_meta(&"stripe_style", stripe_style)
	row.set_meta(&"stripe", stripe)
	row.set_meta(&"score_label", score_label)
	return row

# Big, screen-centered countdown shown only in the final 10 seconds of a
# period — the small scorebug clock is easy to miss while watching the puck,
# so this is the unmissable "the period is about to end" cue. Hidden by
# default; driven by update_clock. mouse_filter IGNORE so it never eats input,
# and it sits below the goal/phase banners by being added before them.
func build_clock_warning(scale_root: Control) -> void:
	_clock_warning_label = HudChrome.lbl("", 150, MenuStyle.GOLD)
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
	scale_root.add_child(_clock_warning_label)

# The wash banner sizes itself to this so it overlays the scorebug pixel-exact.
func panel_size() -> Vector2:
	return _panel.size if _panel != null else Vector2.ZERO

func home_score() -> int:
	return _score_0

func away_score() -> int:
	return _score_1

func set_score(score_0: int, score_1: int) -> void:
	_score_0 = score_0
	_score_1 = score_1
	_home_score_label.text = str(score_0)
	_away_score_label.text = str(score_1)

func set_shots(sog_0: int, sog_1: int) -> void:
	if _home_sog_label != null:
		_home_sog_label.text = str(sog_0)
	if _away_sog_label != null:
		_away_sog_label.text = str(sog_1)

func set_period(new_period: int) -> void:
	_period_label.text = HudChrome.period_ordinal(new_period)

# In the chyron layout the AWAY/HOME labels sit on the dark panel, not on the
# team color, so their text stays cream regardless of team palette. The stripes
# are each team's own primary color (see HudChrome.team_stripe) rather than the
# raw signal colors.
func refresh_team_colors() -> void:
	if _home_badge_style != null:
		_home_badge_style.bg_color = HudChrome.team_stripe(0)
	if _away_badge_style != null:
		_away_badge_style.bg_color = HudChrome.team_stripe(1)

# Flash the scoring team's digit in their primary and spring it back to size.
func celebrate_goal(team_id: int, primary: Color) -> void:
	var score_label: Label = _away_score_label if team_id == 1 else _home_score_label
	score_label.add_theme_color_override("font_color", primary)
	var tween := create_tween()
	tween.tween_method(
		func(c: Color) -> void: score_label.add_theme_color_override("font_color", c),
		primary, MenuStyle.BROADCAST_CREAM, 1.5)

	score_label.pivot_offset = score_label.size / 2.0
	var pop := create_tween()
	pop.tween_property(score_label, "scale", Vector2(1.6, 1.6), 0.0)
	pop.tween_property(score_label, "scale", Vector2.ONE, 0.5) \
		.set_trans(Tween.TRANS_SPRING).set_ease(Tween.EASE_OUT)

func hide_clock_warning() -> void:
	if _clock_warning_label != null:
		_clock_warning_label.visible = false
	_last_warning_pulse_second = -1

func update_clock(t: float) -> void:
	_clock_label.text = HudChrome.format_clock(t)
	# Untimed periods (free play / practice) count UP from zero — there's no
	# end-of-period to warn about, and the count-up would otherwise trip the
	# final-10 countdown during the first 10 seconds. Keep the clock plain. A
	# TIMED offline match (real period length) still gets the full treatment.
	if GameManager.get_period_duration() <= 0.0:
		_clock_label.add_theme_color_override("font_color", MenuStyle.BROADCAST_CREAM)
		_last_clock_pulse_second = -1
		hide_clock_warning()
		return
	_clock_label.add_theme_color_override("font_color",
			MenuStyle.GOLD if t <= 30.0 and t > 0.0 else MenuStyle.BROADCAST_CREAM)
	# Advance warnings (one-shot per period) so the clock doesn't sneak up on a
	# player focused on the puck. _warned_* re-arm when the clock resets above
	# the threshold (period start / next-period faceoff).
	if t > 60.0:
		_warned_one_min = false
		_warned_thirty = false
	if t <= 60.0 and t > 30.0 and not _warned_one_min:
		_warned_one_min = true
		warning_toast.emit(tr(&"CLOCK_ONE_MINUTE_LEFT"), MenuStyle.GOLD)
	if t <= 30.0 and t > 0.0 and not _warned_thirty:
		_warned_thirty = true
		warning_toast.emit(tr(&"CLOCK_THIRTY_SECONDS_LEFT"), HudChrome.WARN_AMBER)
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
		hide_clock_warning()
