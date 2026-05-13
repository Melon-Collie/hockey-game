class_name CareerStatsScreen extends Control

# Two-tab career screen: lifetime totals (existing) + per-game history with
# replay-launch buttons (Feature C). Both tabs fetch concurrently on open()
# and surface their own loading / empty states.

var _reporter := CareerStatsReporter.new()

# Hand-rolled tab switcher (matches OptionsPanel pattern); avoids Godot's
# native TabContainer which doesn't pick up our themed TabButton variations.
var _tab_btns: Array[Button] = []
var _tab_contents: Array[Control] = []

# Career Totals tab.
var _totals_content: VBoxContainer = null
var _totals_status: Label = null

# Recent Games tab. Each game renders as a card panel with score,
# period breakdown, team-grouped player rows, and a Watch Replay button.
var _recent_content: VBoxContainer = null
var _recent_status: Label = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var overlay := ColorRect.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.color = MenuStyle.SCRIM
	add_child(overlay)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(640.0, 0.0)
	panel.add_theme_stylebox_override("panel", MenuStyle.panel(8, 32))
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)
	panel.add_child(vbox)

	var header := HBoxContainer.new()
	vbox.add_child(header)

	var title := Label.new()
	title.text = "Career"
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", MenuStyle.TEXT_TITLE)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)

	var close_btn: Button = MenuStyle.close_button()
	close_btn.pressed.connect(hide)
	header.add_child(close_btn)

	vbox.add_child(_build_tab_switcher())

	hide()


# Mirrors OptionsPanel._build_tab_switcher: a horizontal Button bar tagged
# with the TabButton/TabButtonActive theme variations, a separator line, then
# content panels that swap by visibility.
func _build_tab_switcher() -> Control:
	var wrapper := VBoxContainer.new()
	wrapper.add_theme_constant_override("separation", 0)

	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 0)
	wrapper.add_child(bar)

	var sep := ColorRect.new()
	sep.color = MenuStyle.TEXT_SEP
	sep.custom_minimum_size = Vector2(0, 1)
	wrapper.add_child(sep)

	var content_margin := MarginContainer.new()
	content_margin.add_theme_constant_override("margin_top", 16)
	content_margin.add_theme_constant_override("margin_bottom", 8)
	wrapper.add_child(content_margin)

	var totals_tab := _build_totals_tab()
	var recent_tab := _build_recent_games_tab()
	_tab_contents = [totals_tab, recent_tab]
	content_margin.add_child(totals_tab)
	content_margin.add_child(recent_tab)

	var labels: Array[String] = ["Career Totals", "Recent Games"]
	for i: int in labels.size():
		var btn := Button.new()
		btn.text = labels[i]
		btn.flat = true
		btn.custom_minimum_size = Vector2(140, 40)
		btn.add_theme_font_size_override("font_size", 18)
		bar.add_child(btn)
		_tab_btns.append(btn)
		SoundManager.wire_button(btn)
		btn.pressed.connect(_activate_tab.bind(i))

	_activate_tab(0)
	return wrapper


func _activate_tab(idx: int) -> void:
	for i: int in _tab_contents.size():
		_tab_contents[i].visible = (i == idx)
	for i: int in _tab_btns.size():
		MenuStyle.apply_tab_button(_tab_btns[i], i == idx)


func open() -> void:
	show()
	_refresh_totals()
	_refresh_recent_games()


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed(&"ui_cancel"):
		hide()
		get_viewport().set_input_as_handled()


# ── Totals tab ───────────────────────────────────────────────────────────────

func _build_totals_tab() -> Control:
	var tab := VBoxContainer.new()
	tab.add_theme_constant_override("separation", 6)

	_totals_status = Label.new()
	_totals_status.text = "Loading..."
	_totals_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_totals_status.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	tab.add_child(_totals_status)

	_totals_content = VBoxContainer.new()
	_totals_content.add_theme_constant_override("separation", 6)
	tab.add_child(_totals_content)
	return tab


func _refresh_totals() -> void:
	_clear_totals_content()
	_totals_status.text = "Loading..."
	_totals_status.visible = true
	_reporter.fetch_totals(_on_totals_received)


func _on_totals_received(totals: Dictionary) -> void:
	_totals_status.visible = false
	if totals.is_empty():
		_totals_status.text = "No games recorded yet."
		_totals_status.visible = true
		return
	_clear_totals_content()
	_add_totals_row("Games Played",  str(_safe_int(totals.get("games_played", 0))))
	_add_totals_row("Record (W-L)",  "%d-%d" % [_safe_int(totals.get("wins", 0)), _safe_int(totals.get("losses", 0))])
	_add_totals_separator()
	_add_totals_row("Goals",         str(_safe_int(totals.get("goals", 0))))
	_add_totals_row("Assists",       str(_safe_int(totals.get("assists", 0))))
	_add_totals_row("Points",        str(_safe_int(totals.get("points", 0))))
	_add_totals_row("Shots on Goal", str(_safe_int(totals.get("shots_on_goal", 0))))
	_add_totals_row("Hits",          str(_safe_int(totals.get("hits", 0))))
	_add_totals_row("Shots Blocked", str(_safe_int(totals.get("shots_blocked", 0))))
	_add_totals_separator()
	_add_totals_row("+/-",           "%+d" % _safe_int(totals.get("plus_minus", 0)))
	_add_totals_row("Goals For",     str(_safe_int(totals.get("goals_for", 0))))
	_add_totals_row("Goals Against", str(_safe_int(totals.get("goals_against", 0))))
	_add_totals_separator()
	_add_totals_row("Time on Ice",   _format_toi(totals.get("toi_seconds", 0)))
	_add_totals_row("G/60",          "%.2f" % _safe_float(totals.get("goals_per_60", 0.0)))
	_add_totals_row("A/60",          "%.2f" % _safe_float(totals.get("assists_per_60", 0.0)))
	_add_totals_row("P/60",          "%.2f" % _safe_float(totals.get("points_per_60", 0.0)))


func _add_totals_row(label_text: String, value_text: String) -> void:
	var row := HBoxContainer.new()
	_totals_content.add_child(row)
	var lbl := Label.new()
	lbl.text = label_text
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	row.add_child(lbl)
	var val := Label.new()
	val.text = value_text
	val.add_theme_color_override("font_color", MenuStyle.TEXT_BODY)
	row.add_child(val)


func _add_totals_separator() -> void:
	var sep := HSeparator.new()
	sep.add_theme_color_override("color", MenuStyle.TEXT_SEP)
	_totals_content.add_child(sep)


func _clear_totals_content() -> void:
	for child: Node in _totals_content.get_children():
		child.queue_free()


# ── Recent Games tab ─────────────────────────────────────────────────────────

func _build_recent_games_tab() -> Control:
	var tab := VBoxContainer.new()
	tab.add_theme_constant_override("separation", 6)
	tab.custom_minimum_size = Vector2(0, 520)

	_recent_status = Label.new()
	_recent_status.text = "Loading..."
	_recent_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_recent_status.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	tab.add_child(_recent_status)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tab.add_child(scroll)

	_recent_content = VBoxContainer.new()
	_recent_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_recent_content.add_theme_constant_override("separation", 14)
	scroll.add_child(_recent_content)
	return tab


func _refresh_recent_games() -> void:
	_clear_recent_content()
	_recent_status.text = "Loading..."
	_recent_status.visible = true
	_reporter.fetch_recent_games(PlayerPrefs.player_uuid, 20, _on_recent_received)


func _on_recent_received(games: Array) -> void:
	_recent_status.visible = false
	if games.is_empty():
		_recent_status.text = "No recent games yet. Play a multiplayer game to fill this list."
		_recent_status.visible = true
		return
	_clear_recent_content()
	for entry: Variant in games:
		_recent_content.add_child(_build_game_card(entry as Dictionary))


func _clear_recent_content() -> void:
	for child: Node in _recent_content.get_children():
		child.queue_free()


# Card layout: date · score line | period breakdown | separator |
# home roster grid | away roster grid | Watch Replay button.
func _build_game_card(game: Dictionary) -> Control:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", MenuStyle.panel(4, 12))
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	card.add_child(vbox)

	vbox.add_child(_build_score_line(game))

	var period_line: Control = _build_period_breakdown(game)
	if period_line != null:
		vbox.add_child(period_line)

	var sep := HSeparator.new()
	sep.add_theme_color_override("color", MenuStyle.TEXT_SEP)
	vbox.add_child(sep)

	var players: Array = game.get("players", []) as Array
	var home_players: Array = []
	var away_players: Array = []
	for p_var: Variant in players:
		var p: Dictionary = p_var as Dictionary
		if _safe_int(p.get("team_id", 0)) == 0:
			home_players.append(p)
		else:
			away_players.append(p)
	if not home_players.is_empty():
		vbox.add_child(_build_player_table(home_players, "HOME"))
	if not away_players.is_empty():
		vbox.add_child(_build_player_table(away_players, "AWAY"))
	# Bots don't record stats; mention it so the screen doesn't look broken.
	if home_players.is_empty() or away_players.is_empty():
		var note := Label.new()
		note.text = "Bot opponents — no individual stats recorded."
		note.add_theme_font_size_override("font_size", 11)
		note.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
		vbox.add_child(note)

	var bottom := HBoxContainer.new()
	bottom.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(spacer)
	bottom.add_child(_build_replay_button(game))
	vbox.add_child(bottom)

	return card


func _build_score_line(game: Dictionary) -> Control:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)

	var date_label := Label.new()
	date_label.text = _format_date(str(game.get("ended_at", "")))
	date_label.add_theme_font_size_override("font_size", 12)
	date_label.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	date_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(date_label)

	var score_label := Label.new()
	score_label.text = "%d — %d" % [_safe_int(game.get("home_score", 0)), _safe_int(game.get("away_score", 0))]
	score_label.add_theme_font_size_override("font_size", 18)
	score_label.add_theme_color_override("font_color", MenuStyle.TEAL_HOVER)
	hbox.add_child(score_label)

	return hbox


# Period breakdown grid mirroring the in-game tab scoreboard: a row per team
# (AWAY on top to match rink-perspective convention), columns for each
# regulation + OT period, plus a T column for totals. Period headers label
# OT periods correctly when num_periods is known. Returns null on missing
# or malformed period_scores.
#
# Plain HOME/AWAY text labels (no colored badges) — career_stats doesn't
# store the resolved home/away color IDs today; adding them is a small
# follow-up if we want the badges to match the in-game look.
func _build_period_breakdown(game: Dictionary) -> Control:
	var ps: Variant = game.get("period_scores", null)
	if not ps is Array or (ps as Array).size() < 2:
		return null
	var ps_arr: Array = ps as Array
	var team0: Array = ps_arr[0] as Array
	var team1: Array = ps_arr[1] as Array
	if team0.is_empty() or team0.size() != team1.size():
		return null
	var total_periods: int = team0.size()
	var num_periods: int = _safe_int(game.get("num_periods", 0))

	var center := HBoxContainer.new()
	center.alignment = BoxContainer.ALIGNMENT_CENTER

	var grid := GridContainer.new()
	grid.columns = 2 + total_periods  # row label + periods + total
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 3)
	center.add_child(grid)

	var col_min: Vector2 = Vector2(28, 0)
	var label_min: Vector2 = Vector2(48, 0)

	# Header row: blank + period labels + T
	var blank := Control.new()
	blank.custom_minimum_size = label_min
	grid.add_child(blank)
	for p: int in total_periods:
		var period_num: int = p + 1
		var header_text: String
		if num_periods > 0 and period_num > num_periods:
			header_text = "OT%d" % (period_num - num_periods)
		else:
			header_text = str(period_num)
		grid.add_child(_grid_cell(header_text, col_min, true))
	grid.add_child(_grid_cell("T", col_min, true))

	# AWAY row first (team 1), then HOME (team 0) — matches in-game convention.
	for team_id: int in [1, 0]:
		var team_label: String = "AWAY" if team_id == 1 else "HOME"
		grid.add_child(_grid_cell(team_label, label_min, false, HORIZONTAL_ALIGNMENT_LEFT))
		var team_scores: Array = team1 if team_id == 1 else team0
		var total: int = 0
		for p: int in total_periods:
			var goals: int = _safe_int(team_scores[p])
			total += goals
			grid.add_child(_grid_cell(str(goals), col_min, false))
		grid.add_child(_grid_cell(str(total), col_min, false))

	return center


func _grid_cell(text: String, min_size: Vector2, is_header: bool,
		align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_CENTER) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 12 if is_header else 13)
	l.add_theme_color_override("font_color", MenuStyle.TEXT_DIM if is_header else MenuStyle.TEXT_BODY)
	l.custom_minimum_size = min_size
	l.horizontal_alignment = align
	return l


# Compact 7-column grid: HOME/AWAY tag · player name · G · A · P · SOG · +/-.
# Header row uses dim text; player rows use body text.
func _build_player_table(players: Array, side_label: String) -> Control:
	var grid := GridContainer.new()
	grid.columns = 7
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 2)

	var headers: PackedStringArray = PackedStringArray([side_label, "Player", "G", "A", "P", "SOG", "+/-"])
	for h: String in headers:
		grid.add_child(_table_cell(h, true))

	for p_var: Variant in players:
		var p: Dictionary = p_var as Dictionary
		grid.add_child(_table_cell(""))  # blank under side tag
		grid.add_child(_table_cell(str(p.get("player_name", "Player"))))
		var goals: int = _safe_int(p.get("goals", 0))
		var assists: int = _safe_int(p.get("assists", 0))
		grid.add_child(_table_cell(str(goals)))
		grid.add_child(_table_cell(str(assists)))
		grid.add_child(_table_cell(str(goals + assists)))
		grid.add_child(_table_cell(str(_safe_int(p.get("shots_on_goal", 0)))))
		grid.add_child(_table_cell("%+d" % _safe_int(p.get("plus_minus", 0))))

	return grid


func _table_cell(text: String, is_header: bool = false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 11 if is_header else 12)
	l.add_theme_color_override("font_color", MenuStyle.TEXT_DIM if is_header else MenuStyle.TEXT_BODY)
	return l


# Watch button enabled iff the .mreplay file is on this machine. Otherwise
# disabled with an explanatory tooltip — covers games played from another
# machine or a re-installed OS.
func _build_replay_button(game: Dictionary) -> Button:
	var btn := Button.new()
	btn.text = "▶  Watch Replay"
	btn.custom_minimum_size = Vector2(150, 32)
	var game_id: String = str(game.get("game_id", ""))
	if game_id.is_empty():
		btn.disabled = true
		btn.tooltip_text = "Replay not available"
		return btn
	var path: String = "user://replays/%s.mreplay" % game_id
	if FileAccess.file_exists(path):
		btn.pressed.connect(_on_watch_pressed.bind(path))
	else:
		btn.disabled = true
		btn.tooltip_text = "Replay not on this machine"
	return btn


func _on_watch_pressed(path: String) -> void:
	NetworkManager.pending_replay_path = path
	get_tree().change_scene_to_file(Constants.SCENE_REPLAY_VIEWER)


# Supabase fields can come back as null (e.g. MAX() FILTER with no matching
# rows, or columns that were NULL on the row). int(null) errors out with
# "Nonexistent 'int' constructor", so route every JSON-derived integer
# through this helper.
static func _safe_int(v: Variant, default: int = 0) -> int:
	if v is int:
		return v
	if v is float:
		return int(v)
	return default


static func _safe_float(v: Variant, default: float = 0.0) -> float:
	if v is float:
		return v
	if v is int:
		return float(v)
	return default


# Supabase returns ISO-8601 like "2026-04-28T15:30:45.123+00:00". Trim to
# "YYYY-MM-DD HH:MM" for compactness.
func _format_date(ended_at_iso: String) -> String:
	if ended_at_iso.is_empty():
		return "—"
	var no_tz: String = ended_at_iso.split("+")[0].split(".")[0].replace("T", " ")
	if no_tz.length() >= 16:
		return no_tz.substr(0, 16)
	return no_tz


static func _format_toi(seconds: Variant) -> String:
	var s: int = _safe_int(seconds)
	@warning_ignore("integer_division")
	var minutes: int = s / 60
	return "%d:%02d" % [minutes, s % 60]
