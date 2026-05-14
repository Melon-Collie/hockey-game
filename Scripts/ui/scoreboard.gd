class_name Scoreboard
extends CanvasLayer

const _DARK_BG := MenuStyle.BROADCAST_BG
const _WHITE   := MenuStyle.BROADCAST_CREAM
const _DIM     := MenuStyle.BROADCAST_DIM
const _HEADER  := MenuStyle.BROADCAST_DIM
const _SEP     := MenuStyle.BROADCAST_SEP

const _POSITION_LABEL := ["C", "L", "R"]   # indexed by team_slot

var _rows_container: VBoxContainer = null
var _period_score_labels: Array = []  # [team_id][period_index, then total]
var _period_summary_grid: GridContainer = null
var _away_badge_style: StyleBoxFlat = null
var _home_badge_style: StyleBoxFlat = null
var _away_badge_label: Label = null
var _home_badge_label: Label = null

func _ready() -> void:
	layer = 10
	visible = false
	_build_panel()
	GameManager.stats_updated.connect(_refresh)
	GameManager.game_over.connect(_on_game_over)
	GameManager.team_colors_ready.connect(_on_team_colors_ready)
	var ping_timer := Timer.new()
	ping_timer.wait_time = 2.0
	ping_timer.autostart = true
	ping_timer.timeout.connect(_refresh)
	add_child(ping_timer)

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_TAB:
		visible = not visible
		get_viewport().set_input_as_handled()

func _on_game_over() -> void:
	visible = true
	_refresh()

func _on_team_colors_ready(home_primary: Color, home_secondary: Color, away_primary: Color, away_secondary: Color) -> void:
	if _home_badge_style != null:
		_home_badge_style.bg_color = home_primary
	if _home_badge_label != null:
		_home_badge_label.add_theme_color_override("font_color", home_secondary)
	if _away_badge_style != null:
		_away_badge_style.bg_color = away_primary
	if _away_badge_label != null:
		_away_badge_label.add_theme_color_override("font_color", away_secondary)

func _build_panel() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	var centering := VBoxContainer.new()
	centering.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	centering.alignment = BoxContainer.ALIGNMENT_CENTER
	centering.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(centering)

	var h_centering := HBoxContainer.new()
	h_centering.alignment = BoxContainer.ALIGNMENT_CENTER
	h_centering.mouse_filter = Control.MOUSE_FILTER_IGNORE
	centering.add_child(h_centering)

	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = _DARK_BG
	panel_style.set_corner_radius_all(0)
	panel_style.border_color = MenuStyle.BROADCAST_BORDER_T
	panel_style.border_width_top = 1
	panel_style.anti_aliasing = false  # crisp edges to match the layered shadow
	panel_style.set_content_margin_all(0)  # inner sections handle their own padding

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", panel_style)
	panel.custom_minimum_size = Vector2(610, 0)
	h_centering.add_child(MenuStyle.wrap_drop_shadow(panel, Vector2(5, 5)))

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 0)
	panel.add_child(vbox)

	# === Title strip ===
	var title_style := StyleBoxFlat.new()
	title_style.bg_color = MenuStyle.BROADCAST_TITLE_BG
	title_style.set_content_margin(SIDE_TOP, 8)
	title_style.set_content_margin(SIDE_BOTTOM, 8)
	title_style.set_content_margin(SIDE_LEFT, 18)
	title_style.set_content_margin(SIDE_RIGHT, 18)
	var title_panel := PanelContainer.new()
	title_panel.add_theme_stylebox_override("panel", title_style)
	var title_label := _lbl("BOX SCORE", 16, _WHITE)
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_panel.add_child(title_label)
	vbox.add_child(title_panel)

	# === Period summary ===
	var periods_outer := MarginContainer.new()
	periods_outer.add_theme_constant_override("margin_top", 12)
	periods_outer.add_theme_constant_override("margin_bottom", 4)
	periods_outer.add_theme_constant_override("margin_left", 22)
	periods_outer.add_theme_constant_override("margin_right", 22)
	vbox.add_child(periods_outer)
	var periods_vbox := VBoxContainer.new()
	periods_outer.add_child(periods_vbox)
	_build_period_summary(periods_vbox)

	# === Stats table strip ===
	var table_outer := MarginContainer.new()
	table_outer.add_theme_constant_override("margin_top", 12)
	table_outer.add_theme_constant_override("margin_bottom", 14)
	table_outer.add_theme_constant_override("margin_left", 18)
	table_outer.add_theme_constant_override("margin_right", 18)
	vbox.add_child(table_outer)
	var table_vbox := VBoxContainer.new()
	table_vbox.add_theme_constant_override("separation", 6)
	table_outer.add_child(table_vbox)

	var header_row := _make_row()
	_fill_row(header_row, ["PING", "#", "POS", "PLAYER", "G", "A", "PTS", "SOG", "HITS", "BLK"], _HEADER, true)
	table_vbox.add_child(header_row)

	_rows_container = VBoxContainer.new()
	_rows_container.add_theme_constant_override("separation", 3)
	table_vbox.add_child(_rows_container)

	# === Footer strip ===
	var footer_style := StyleBoxFlat.new()
	footer_style.bg_color = MenuStyle.BROADCAST_TITLE_BG
	footer_style.set_content_margin(SIDE_TOP, 6)
	footer_style.set_content_margin(SIDE_BOTTOM, 6)
	var footer_panel := PanelContainer.new()
	footer_panel.add_theme_stylebox_override("panel", footer_style)
	var footer := _lbl("PRESS TAB TO TOGGLE", 11, _DIM)
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	footer_panel.add_child(footer)
	vbox.add_child(footer_panel)

func _build_period_summary(vbox: VBoxContainer) -> void:
	var h_wrap := HBoxContainer.new()
	h_wrap.alignment = BoxContainer.ALIGNMENT_CENTER
	h_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(h_wrap)

	_period_summary_grid = GridContainer.new()
	_period_summary_grid.add_theme_constant_override("h_separation", 0)
	_period_summary_grid.add_theme_constant_override("v_separation", 5)
	h_wrap.add_child(_period_summary_grid)

	_rebuild_period_grid(GameManager.get_period_scores()[0].size())

func _rebuild_period_grid(num_periods: int) -> void:
	for child in _period_summary_grid.get_children():
		child.free()
	_period_score_labels.clear()

	var col_num: int = 32
	_period_summary_grid.columns = 2 + num_periods  # badge + periods + total

	_period_summary_grid.add_child(Control.new())
	for p: int in num_periods:
		var period_num: int = p + 1
		var header_text: String = "OT%d" % (period_num - GameManager.get_num_periods()) if period_num > GameManager.get_num_periods() else str(period_num)
		var h := _lbl(header_text, 12, _HEADER)
		h.custom_minimum_size = Vector2(col_num, 0)
		h.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_period_summary_grid.add_child(h)
	var t_header := _lbl("T", 12, _HEADER)
	t_header.custom_minimum_size = Vector2(col_num, 0)
	t_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_period_summary_grid.add_child(t_header)

	for team_id: int in [1, 0]:
		var label: String = "AWAY" if team_id == 1 else "HOME"
		var primary: Color = _HEADER
		if GameManager.teams.size() > team_id:
			primary = TeamColorRegistry.get_colors(GameManager.teams[team_id].color_id, team_id).primary
		var badge := _team_badge(label, primary)
		var badge_style := badge.get_theme_stylebox("panel") as StyleBoxFlat
		var badge_label := badge.get_child(0) as Label
		if team_id == 1:
			_away_badge_style = badge_style
			_away_badge_label = badge_label
		else:
			_home_badge_style = badge_style
			_home_badge_label = badge_label
		_period_summary_grid.add_child(badge)
		var row_labels: Array[Label] = []
		for _i: int in num_periods + 1:  # periods + total
			var l := _lbl("0", 13, _WHITE)
			l.custom_minimum_size = Vector2(col_num, 0)
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			_period_summary_grid.add_child(l)
			row_labels.append(l)
		_period_score_labels.append(row_labels)

func _refresh() -> void:
	if _rows_container == null:
		return

	if not _period_score_labels.is_empty():
		var ps: Array = GameManager.get_period_scores()
		var num_periods: int = ps[0].size()
		# Rebuild the grid if OT added a period
		if _period_score_labels[0].size() != num_periods + 1:
			_rebuild_period_grid(num_periods)
		# _period_score_labels[0] = away (team 1), [1] = home (team 0)
		for row: int in 2:
			var team_id: int = 1 if row == 0 else 0
			var total: int = 0
			for p: int in num_periods:
				var goals: int = ps[team_id][p]
				_period_score_labels[row][p].text = str(goals)
				total += goals
			_period_score_labels[row][num_periods].text = str(total)

	for child in _rows_container.get_children():
		child.queue_free()

	var sorted: Array[PlayerRecord] = []
	var all_players := GameManager.get_players()
	for pid: int in all_players:
		sorted.append(all_players[pid])
	sorted.sort_custom(func(a: PlayerRecord, b: PlayerRecord) -> bool:
		if a.team.team_id != b.team.team_id:
			return a.team.team_id > b.team.team_id  # team 1 (away) first
		return a.team_slot < b.team_slot
	)

	var last_team_id: int = -1
	for record: PlayerRecord in sorted:
		if record.team.team_id != last_team_id:
			last_team_id = record.team.team_id
			_rows_container.add_child(_make_team_header(record.team.team_id))
		var row := _make_row()
		_rows_container.add_child(row)
		var s := record.stats
		var pts := s.goals + s.assists
		var display_name: String = record.display_name()
		var ping_str: String = _ping_label(record.peer_id)
		var pos_str: String = _POSITION_LABEL[record.team_slot]
		var num_str: String = str(record.jersey_number)
		_fill_row(row,
			[ping_str, num_str, pos_str, display_name, str(s.goals), str(s.assists), str(pts), str(s.shots_on_goal), str(s.hits), str(s.shots_blocked)],
			_WHITE, false
		)

func _make_team_header(team_id: int) -> PanelContainer:
	var label: String = "AWAY" if team_id == 1 else "HOME"
	var color: Color = TeamColorRegistry.get_colors(GameManager.teams[team_id].color_id, team_id).primary
	var style := StyleBoxFlat.new()
	style.bg_color = Color(color.r, color.g, color.b, 0.32)
	style.set_corner_radius_all(0)
	style.set_content_margin(SIDE_LEFT, 14)
	style.set_content_margin(SIDE_RIGHT, 14)
	style.set_content_margin(SIDE_TOP, 5)
	style.set_content_margin(SIDE_BOTTOM, 5)
	style.border_color = color
	style.border_width_left = 6
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", style)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var lbl := _lbl(label, 16, _WHITE)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	panel.add_child(lbl)
	return panel

func _make_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 0)
	return row

func _ping_label(peer_id: int) -> String:
	var local_id: int = NetworkManager.local_peer_id()
	if peer_id == local_id:
		return "—" if NetworkManager.is_host else "%d ms" % int(NetworkManager.get_rtt_ms())
	var p: int = NetworkManager.get_peer_ping_ms(peer_id)
	return "%d ms" % p if p > 0 else "—"

func _fill_row(row: HBoxContainer, texts: Array, name_color: Color, is_header: bool) -> void:
	var widths := [52, 36, 36, 150, 38, 38, 48, 48, 56, 48]
	var font_size := 13 if is_header else 14
	for i in texts.size():
		var cell := Label.new()
		cell.text = texts[i]
		cell.custom_minimum_size = Vector2(widths[i], 0)
		cell.add_theme_font_override("font", MenuStyle.BROADCAST_FONT)
		cell.add_theme_font_size_override("font_size", font_size)
		var col := name_color if (i > 0 and i < 4 or is_header) else _WHITE
		cell.add_theme_color_override("font_color", col)
		cell.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT if i == 3 else HORIZONTAL_ALIGNMENT_CENTER
		row.add_child(cell)

func _team_badge(text: String, color: Color) -> PanelContainer:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(3)
	style.set_content_margin(SIDE_LEFT, 6)
	style.set_content_margin(SIDE_RIGHT, 6)
	style.set_content_margin(SIDE_TOP, 3)
	style.set_content_margin(SIDE_BOTTOM, 3)
	var badge := PanelContainer.new()
	badge.add_theme_stylebox_override("panel", style)
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var lum: float = 0.299 * color.r + 0.587 * color.g + 0.114 * color.b
	var text_color: Color = Color(0.06, 0.06, 0.06) if lum > 0.4 else _WHITE
	var lbl := _lbl(text, 11, text_color)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.add_child(lbl)
	return badge

func _hsep() -> HSeparator:
	var sep := HSeparator.new()
	var style := StyleBoxFlat.new()
	style.bg_color = _SEP
	style.set_content_margin_all(0)
	sep.add_theme_stylebox_override("separator", style)
	return sep

func _lbl(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", MenuStyle.BROADCAST_FONT)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l
