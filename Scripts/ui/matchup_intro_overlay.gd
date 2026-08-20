class_name MatchupIntroOverlay
extends CanvasLayer

# Opening-faceoff matchup screen, scrim-first: the pre-game camera sweep and
# bench skate-on stay visible through a medium dim wash while the two rosters
# read on top — team columns (color stripe + HOME/AWAY header, then per player
# jersey number + name) around a center VS. Deliberately no build readout: the
# attribute system is all-lateral (two body dials + gear leans, no build is
# "better"), so any summary — a hex radar of the resolved multipliers, scouting
# archetype tags — either implies a power ranking or editorializes; the bodies
# on the ice during the sweep are the honest preview. Pure presentation, no
# buttons; shown for the front
# of the PREGAME_INTRO_DURATION hold and dismissed before the faceoff
# countdown takes the banner.
#
# Owned by HUD, which passes the slot-sorted PlayerRecords per team.

const _WHITE := MenuStyle.BROADCAST_CREAM
const _DIM := MenuStyle.BROADCAST_DIM

# Between the intermission reel's light wash (0.32) and the modal scrim
# (0.55): the sweep behind is mood, not content, but should still read.
const _INTRO_SCRIM := Color(0.024, 0.039, 0.071, 0.40)

var _scrim: ColorRect = null
var _content: VBoxContainer = null
var _home_stripe_style: StyleBoxFlat = null
var _away_stripe_style: StyleBoxFlat = null
var _home_rows: VBoxContainer = null
var _away_rows: VBoxContainer = null
var _present_tween: Tween = null


func _ready() -> void:
	layer = 4  # same shelf as the intermission overlay; the two never coexist
	_build_ui()
	visible = false


func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_scrim = ColorRect.new()
	_scrim.color = _INTRO_SCRIM
	_scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_scrim)

	var centering := CenterContainer.new()
	centering.set_anchors_preset(Control.PRESET_FULL_RECT)
	centering.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(centering)

	_content = VBoxContainer.new()
	_content.alignment = BoxContainer.ALIGNMENT_CENTER
	_content.add_theme_constant_override("separation", 22)
	centering.add_child(_content)

	var tag := _lbl(tr(&"MATCHUP_TITLE"), 16, _DIM)
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_content.add_child(tag)

	var columns := HBoxContainer.new()
	columns.alignment = BoxContainer.ALIGNMENT_CENTER
	columns.add_theme_constant_override("separation", 56)
	_content.add_child(columns)

	_home_stripe_style = _stripe_style()
	var home_col := _build_team_column(tr(&"TEAM_HOME"), _home_stripe_style)
	_home_rows = home_col.get_meta(&"rows") as VBoxContainer
	columns.add_child(home_col)

	# Center spine: just the VS — the archetype tags carry the build story in
	# words, so there is no legend to key.
	var vs := _lbl(tr(&"MATCHUP_VS"), 30, _DIM)
	vs.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vs.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	columns.add_child(vs)

	_away_stripe_style = _stripe_style()
	var away_col := _build_team_column(tr(&"TEAM_AWAY"), _away_stripe_style)
	_away_rows = away_col.get_meta(&"rows") as VBoxContainer
	columns.add_child(away_col)


# One team's column: [stripe] HEADER, then a rows box the roster fills at
# present() time. The rows container rides along as metadata so _build_ui can
# grab it without plumbing a second return value.
func _build_team_column(header: String, stripe_style: StyleBoxFlat) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_BEGIN
	col.add_theme_constant_override("separation", 10)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	head.add_child(_stripe(stripe_style, 30))
	head.add_child(_lbl(header, 28, _WHITE))
	col.add_child(head)

	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 6)
	col.add_child(rows)
	col.set_meta(&"rows", rows)
	return col


func present(home_records: Array[PlayerRecord], away_records: Array[PlayerRecord],
		home_stripe: Color, away_stripe: Color) -> void:
	_home_stripe_style.bg_color = home_stripe
	_away_stripe_style.bg_color = away_stripe
	_fill_rows(_home_rows, home_records, 0)
	_fill_rows(_away_rows, away_records, 1)
	visible = true
	if _present_tween != null and _present_tween.is_running():
		_present_tween.kill()
	_scrim.modulate.a = 0.0
	_content.modulate.a = 0.0
	_present_tween = create_tween()
	_present_tween.tween_property(_scrim, "modulate:a", 1.0, 0.30)
	_present_tween.parallel().tween_property(_content, "modulate:a", 1.0, 0.40) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func hide_overlay() -> void:
	if _present_tween != null and _present_tween.is_running():
		_present_tween.kill()
	if not visible:
		return
	# Fade out rather than blink — the sweep continues underneath and the
	# banner countdown picks up the thread.
	_present_tween = create_tween()
	_present_tween.tween_property(_scrim, "modulate:a", 0.0, 0.25)
	_present_tween.parallel().tween_property(_content, "modulate:a", 0.0, 0.25)
	_present_tween.tween_callback(func() -> void: visible = false)


# Roster rebuilt per present(): once per match, a handful of rows. Each row:
# a position badge, jersey number, name. Records arrive slot-sorted (see
# hud.gd._show_matchup_overlay), so in 5v5 the forward group (C/LW/RW) always
# precedes defense (LD/RD) — thin "FORWARDS" / "DEFENSE" dividers label both
# groups so the matchup reads at a glance instead of five undifferentiated
# names (3v3 is position-free rovers, so it gets no dividers at all).
func _fill_rows(rows: VBoxContainer, records: Array[PlayerRecord],
		team_id: int) -> void:
	for child: Node in rows.get_children():
		child.queue_free()
	var is_5v5: bool = records.size() >= 5
	var open_group: int = -1  # -1 = none yet, 0 = forwards, 1 = defense
	for record: PlayerRecord in records:
		var group: int = 1 if PlayerRules.is_defense_slot(record.team_slot) else 0
		if is_5v5 and group != open_group:
			_add_group_header(rows,
					tr(&"MATCHUP_GROUP_DEFENSE") if group == 1 else tr(&"MATCHUP_GROUP_FORWARDS"),
					open_group != -1)
			open_group = group
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		# Badge left-aligned in its cell so C / LW / LD share a left rail with
		# the group headers above them; the jersey numbers keep the right
		# alignment that lines up 7 with 71.
		var pos := _lbl(
				tr(PositionLabels.badge_key(team_id, record.team_slot, is_5v5)), 14, _DIM)
		pos.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		pos.custom_minimum_size = Vector2(28, 0)
		pos.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(pos)
		var num := _lbl("%d" % record.jersey_number, 16, _DIM)
		num.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		num.custom_minimum_size = Vector2(30, 0)
		num.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(num)
		var name_label := _lbl(record.display_name(), 22, _WHITE)
		name_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(name_label)
		rows.add_child(row)


# A group divider over the rows that follow it, flush with the column's left
# edge (the same rail as the color stripe, the HOME/AWAY header, and the
# position badges). `lead_gap` opens a little air above a group that follows
# another one; the first group sits tight under the team header.
func _add_group_header(rows: VBoxContainer, text: String, lead_gap: bool) -> void:
	if lead_gap:
		var spacer := Control.new()
		spacer.custom_minimum_size = Vector2(0, 6)
		rows.add_child(spacer)
	var head := _lbl(text, 12, _DIM)
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	rows.add_child(head)


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
