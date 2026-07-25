class_name CareerStatsScreen extends Control

# Three-tab career screen: lifetime totals + per-game online history
# (both Supabase-backed, gated per-tab on share_gameplay_stats) + local
# replays. The Replays tab lists the .mreplay files on THIS machine and is
# deliberately NOT gated on stat sharing — watching a replay file you
# already own is a local action; it has nothing to do with whether you
# upload career stats. It also includes bot-lobby games, which never appear
# in the Supabase-backed Recent Games history. All tabs refresh on open()
# and surface their own loading / empty / gated states.

var _reporter := CareerStatsReporter.new()

# Hand-rolled tab switcher (matches OptionsPanel pattern); avoids Godot's
# native TabContainer which doesn't pick up our themed TabButton variations.
var _tab_btns: Array[Button] = []
var _tab_contents: Array[Control] = []
var _active_idx: int = 0  # active tab, for controller bumper switching + focus

const _TAB_REPLAYS: int = 2

# Career Totals tab.
var _totals_content: VBoxContainer = null
var _totals_status: Label = null
var _identity_label: Label = null
var _hero_row: HBoxContainer = null
var _heat_map: CareerHeatMap = null

# The Recent Games and Replays tabs were designed for the old narrow column and
# read fine; the shell is now full-bleed for the Career tab's sake, so those two
# keep their original measure instead of stretching across the screen.
const _NARROW_TAB_WIDTH: float = 660.0

# Recent Games tab. Each game renders as a card panel with score,
# period breakdown, team-grouped player rows, and a Watch Replay button.
var _recent_content: VBoxContainer = null
var _recent_status: Label = null

# Replays tab: local .mreplay files (ReplayFileIndex.list + read_meta).
var _replays_content: VBoxContainer = null
var _replays_status: Label = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	# Full-bleed reading surface rather than a narrow centred card: the career
	# page carries a shot map and wide stat groups, and the old 640 px column
	# forced everything into a single cramped list. Same broadcast language as
	# the post-game analytics screen.
	var overlay := ColorRect.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.color = Color(0.024, 0.039, 0.071, 0.96)
	add_child(overlay)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 56)
	margin.add_theme_constant_override("margin_right", 56)
	margin.add_theme_constant_override("margin_top", 26)
	margin.add_theme_constant_override("margin_bottom", 22)
	add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	margin.add_child(vbox)

	# Header row: title on the left, player identity centre, close on the right.
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	vbox.add_child(head)

	var title := _display_label("CAREER", 30, MenuStyle.BROADCAST_CREAM)
	head.add_child(title)

	_identity_label = _ui_label("", 13, MenuStyle.TEXT_MUTED)
	_identity_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_identity_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_identity_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	head.add_child(_identity_label)

	var close_btn: Button = MenuStyle.close_button()
	close_btn.pressed.connect(hide)
	SoundManager.wire_button(close_btn)
	head.add_child(close_btn)

	vbox.add_child(_build_tab_switcher())

	hide()


# ── Shared visual language (mirrors PostGameAnalytics) ───────────────────────

func _display_label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", MenuStyle.DISPLAY_FONT)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


func _ui_label(text: String, size: int, color: Color) -> Label:
	var l := _display_label(text, size, color)
	l.add_theme_font_override("font", MenuStyle.UI_FONT)
	return l


func _broadcast_panel() -> PanelContainer:
	var p := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = MenuStyle.BROADCAST_BG
	style.set_corner_radius_all(8)
	style.set_border_width_all(1)
	style.border_color = MenuStyle.BROADCAST_SEP
	style.set_content_margin_all(14)
	p.add_theme_stylebox_override("panel", style)
	return p


func _section_title(text: String) -> Label:
	var l := _ui_label(text.to_upper(), 12, MenuStyle.TEXT_MUTED)
	return l


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
	content_margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	wrapper.add_child(content_margin)

	var totals_tab := _build_totals_tab()
	var recent_tab := _narrow(_build_recent_games_tab())
	var replays_tab := _narrow(_build_replays_tab())
	_tab_contents = [totals_tab, recent_tab, replays_tab]
	content_margin.add_child(totals_tab)
	content_margin.add_child(recent_tab)
	content_margin.add_child(replays_tab)

	var labels: Array[String] = ["Career Totals", "Recent Games", "Replays"]
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


# Holds a tab to its original measure inside the full-bleed shell, centred.
func _narrow(tab: Control) -> Control:
	var holder := HBoxContainer.new()
	holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var left := Control.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	holder.add_child(left)
	tab.custom_minimum_size = Vector2(_NARROW_TAB_WIDTH, tab.custom_minimum_size.y)
	tab.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	tab.size_flags_vertical = Control.SIZE_EXPAND_FILL
	holder.add_child(tab)
	var right := Control.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	holder.add_child(right)
	return holder


func _activate_tab(idx: int) -> void:
	_active_idx = idx
	for i: int in _tab_contents.size():
		_tab_contents[i].visible = (i == idx)
	for i: int in _tab_btns.size():
		MenuStyle.apply_tab_button(_tab_btns[i], i == idx)


# Controller: LB / RB cycle tabs (console convention). Only while on screen, so it
# never touches the game's LB during play. Refocuses the new page's first control.
func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	var delta: int = ControllerNav.bumper_tab_delta(event)
	if delta != 0:
		var n: int = _tab_btns.size()
		if n > 0:
			_activate_tab((_active_idx + delta + n) % n)
			_focus_active_tab()
		get_viewport().set_input_as_handled()


func _focus_active_tab() -> void:
	if _active_idx >= 0 and _active_idx < _tab_contents.size():
		ControllerNav.focus_first(_tab_contents[_active_idx])


func open() -> void:
	show()
	# With stat sharing off the Supabase tabs are just gate notices, so land
	# on the one tab with content — the local replays.
	_activate_tab(_TAB_REPLAYS if not PlayerPrefs.share_gameplay_stats else 0)
	_refresh_totals()
	_refresh_recent_games()
	_refresh_replays()
	_focus_active_tab()  # controller: land on the active tab's content, LB/RB switch tabs


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed(&"ui_cancel"):
		hide()
		get_viewport().set_input_as_handled()


# ── Totals tab ───────────────────────────────────────────────────────────────

# Layout: a hero row of headline figures across the top, then two columns —
# grouped stat cards on the left, the career shot map on the right. The old
# version was a single flat list of ~20 label/value rows, which buried the
# numbers that matter and had nowhere to put the shot data.
func _build_totals_tab() -> Control:
	var tab := VBoxContainer.new()
	tab.add_theme_constant_override("separation", 12)
	tab.size_flags_vertical = Control.SIZE_EXPAND_FILL

	_totals_status = Label.new()
	_totals_status.text = "Loading..."
	_totals_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_totals_status.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	tab.add_child(_totals_status)

	_hero_row = HBoxContainer.new()
	_hero_row.add_theme_constant_override("separation", 10)
	tab.add_child(_hero_row)

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 12)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tab.add_child(body)

	# Left: the stat groups.
	var left := _broadcast_panel()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_stretch_ratio = 1.25
	_totals_content = VBoxContainer.new()
	_totals_content.add_theme_constant_override("separation", 10)
	left.add_child(_totals_content)
	body.add_child(left)

	# Right: the career shot map.
	var right := _broadcast_panel()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_stretch_ratio = 1.0
	var right_col := VBoxContainer.new()
	right_col.add_theme_constant_override("separation", 8)
	right.add_child(right_col)
	var map_head := HBoxContainer.new()
	map_head.add_child(_section_title("Shot Map"))
	var map_spacer := Control.new()
	map_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_head.add_child(map_spacer)
	map_head.add_child(_ui_label("all games · brighter = more shots", 11, MenuStyle.TEXT_MUTED))
	right_col.add_child(map_head)
	_heat_map = CareerHeatMap.new()
	_heat_map.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_heat_map.custom_minimum_size = Vector2(0, 300)
	right_col.add_child(_heat_map)
	right_col.add_child(_build_heat_legend())
	body.add_child(right)
	return tab


func _build_heat_legend() -> Control:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 14)
	var ramp := HeatRamp.new()
	ramp.custom_minimum_size = Vector2(110, 10)
	ramp.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(ramp)
	row.add_child(_ui_label("shot volume", 11, MenuStyle.TEXT_MUTED))
	var goal_dot := GoalDot.new()
	goal_dot.custom_minimum_size = Vector2(12, 12)
	goal_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(goal_dot)
	row.add_child(_ui_label("goals scored", 11, MenuStyle.TEXT_MUTED))
	return row


const _STAT_SHARING_GATE_TEXT: String = \
		"Career stats need stat sharing.\nEnable “Share Gameplay Stats” in Options → Game."


func _refresh_totals() -> void:
	_clear_totals_content()
	if not PlayerPrefs.share_gameplay_stats:
		_totals_status.text = _STAT_SHARING_GATE_TEXT
		_totals_status.visible = true
		return
	if SteamManager.steam_id == 0:
		_totals_status.text = "Sign in to Steam to view career stats."
		_totals_status.visible = true
		return
	_totals_status.text = "Loading..."
	_totals_status.visible = true
	_reporter.fetch_totals(_on_totals_received)
	_reporter.fetch_shot_heatmap(SteamManager.steam_id, _on_heatmap_received)


func _on_heatmap_received(buckets: Array) -> void:
	if _heat_map != null:
		_heat_map.configure(buckets)


func _on_totals_received(totals: Dictionary) -> void:
	_totals_status.visible = false
	if totals.is_empty():
		_totals_status.text = "No games recorded yet."
		_totals_status.visible = true
		return
	_clear_totals_content()

	var games: int = _safe_int(totals.get("games_played", 0))
	var wins: int = _safe_int(totals.get("wins", 0))
	var losses: int = _safe_int(totals.get("losses", 0))
	var toi: int = _safe_int(totals.get("toi_seconds", 0))
	_identity_label.text = "%s · %d game%s · %s on ice" % [
		String(totals.get("player_name", "")), games,
		"" if games == 1 else "s", _format_toi(toi)]

	# Hero figures: the five numbers a player actually looks for.
	_clear_children(_hero_row)
	_add_hero("POINTS", str(_safe_int(totals.get("points", 0))), MenuStyle.GOLD)
	_add_hero("GOALS", str(_safe_int(totals.get("goals", 0))), MenuStyle.BROADCAST_CREAM)
	_add_hero("ASSISTS", str(_safe_int(totals.get("assists", 0))), MenuStyle.BROADCAST_CREAM)
	_add_hero("RECORD", "%d-%d" % [wins, losses], MenuStyle.BROADCAST_CREAM)
	_add_hero("P/60", "%.2f" % _safe_float(totals.get("points_per_60", 0.0)),
			MenuStyle.BROADCAST_CREAM)

	# Grouped cards rather than one 20-row list.
	var faceoff_taken: int = _safe_int(totals.get("faceoff_wins", 0)) \
			+ _safe_int(totals.get("faceoff_losses", 0))
	_add_stat_group("Scoring", [
		["Shots on goal", str(_safe_int(totals.get("shots_on_goal", 0)))],
		["Shooting %", "%.1f%%" % (100.0 * float(_safe_int(totals.get("goals", 0)))
				/ maxf(float(_safe_int(totals.get("shots_on_goal", 0))), 1.0))
				if _safe_int(totals.get("shots_on_goal", 0)) > 0 else "—"],
		["G/60", "%.2f" % _safe_float(totals.get("goals_per_60", 0.0))],
		["A/60", "%.2f" % _safe_float(totals.get("assists_per_60", 0.0))],
	])
	# Advanced group. PDO / xGF% are null until games with the tracked columns
	# exist (older rows carry zero denominators) — show an em dash, not a zero.
	var pdo: Variant = totals.get("pdo", null)
	var xgf: Variant = totals.get("xgf_pct", null)
	_add_stat_group("Chances", [
		["Shot attempts (Corsi)", str(_safe_int(totals.get("shot_attempts", 0)))],
		["Fenwick", str(_safe_int(totals.get("fenwick", 0)))],
		["Expected goals", "%.2f" % _safe_float(totals.get("xg_for", 0.0))],
		["Goals above expected", "%+.2f" % _safe_float(totals.get("goals_above_expected", 0.0))],
		["xGF %", "%.1f%%" % _safe_float(xgf) if xgf != null else "—"],
		["PDO", "%d" % _safe_int(pdo) if pdo != null else "—"],
	], true)
	_add_stat_group("Two-way", [
		["+/-", "%+d" % _safe_int(totals.get("plus_minus", 0))],
		["Takeaways", str(_safe_int(totals.get("takeaways", 0)))],
		["Giveaways", str(_safe_int(totals.get("giveaways", 0)))],
		["Faceoff %", "%.1f%%" % _safe_float(totals.get("faceoff_pct", 0.0))
				if faceoff_taken > 0 else "—"],
	])
	_add_stat_group("Physical", [
		["Hits", str(_safe_int(totals.get("hits", 0)))],
		["Hits taken", str(_safe_int(totals.get("hits_taken", 0)))],
		["Shots blocked", str(_safe_int(totals.get("shots_blocked", 0)))],
	])


# One headline figure: big value over a small caps label.
func _add_hero(label_text: String, value_text: String, color: Color) -> void:
	var tile := _broadcast_panel()
	tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	tile.add_child(col)
	var value := _display_label(value_text, 38, color)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(value)
	var caption := _ui_label(label_text, 10, MenuStyle.TEXT_MUTED)
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(caption)
	_hero_row.add_child(tile)


# A titled group of label/value rows. `advanced` tags the group with the
# analytics accent — these are the stats no other hockey game surfaces.
func _add_stat_group(title: String, rows: Array, advanced: bool = false) -> void:
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	head.add_child(_section_title(title))
	if advanced:
		var tag := _ui_label("ADVANCED", 9, MenuStyle.GOLD)
		tag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		head.add_child(tag)
	_totals_content.add_child(head)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 18)
	grid.add_theme_constant_override("v_separation", 4)
	_totals_content.add_child(grid)
	for row: Variant in rows:
		var pair: Array = row as Array
		var lbl := _ui_label(String(pair[0]), 13, MenuStyle.TEXT_DIM)
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(lbl)
		var val := _display_label(String(pair[1]), 16, MenuStyle.BROADCAST_CREAM)
		val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		grid.add_child(val)


func _clear_children(node: Node) -> void:
	for child: Node in node.get_children():
		child.queue_free()


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
	scroll.follow_focus = true  # controller: scroll to keep the focused row in view
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
	if not PlayerPrefs.share_gameplay_stats:
		_recent_status.text = _STAT_SHARING_GATE_TEXT
		_recent_status.visible = true
		return
	if SteamManager.steam_id == 0:
		_recent_status.text = "Sign in to Steam to view recent games."
		_recent_status.visible = true
		return
	_recent_status.text = "Loading..."
	_recent_status.visible = true
	_reporter.fetch_recent_games(SteamManager.steam_id, 20, _on_recent_received)


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

	# Derive final score from period_scores rather than the RPC's home_score/
	# away_score columns: the period breakdown rendered just below is the
	# authoritative per-game record, so summing it guarantees the headline
	# score and the grid totals can't disagree.
	var score_label := Label.new()
	var home_score: int = 0
	var away_score: int = 0
	var ps: Variant = game.get("period_scores", null)
	if ps is Array and (ps as Array).size() >= 2:
		var ps_arr: Array = ps as Array
		for g: Variant in ps_arr[0] as Array:
			home_score += _safe_int(g)
		for g: Variant in ps_arr[1] as Array:
			away_score += _safe_int(g)
	else:
		home_score = _safe_int(game.get("home_score", 0))
		away_score = _safe_int(game.get("away_score", 0))
	score_label.text = "%d — %d" % [home_score, away_score]
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
	GameManager.on_scene_exit()
	get_tree().change_scene_to_file(Constants.SCENE_REPLAY_VIEWER)


# ── Replays tab ──────────────────────────────────────────────────────────────
# Local .mreplay files, read entirely off disk — no Supabase, no stat-sharing
# gate. Includes bot-lobby games, which Recent Games (online history) never
# lists. Oldest files are pruned past PlayerPrefs.replay_keep_count, so this
# is "what you can watch right now", not a permanent record.

func _build_replays_tab() -> Control:
	var tab := VBoxContainer.new()
	tab.add_theme_constant_override("separation", 6)
	tab.custom_minimum_size = Vector2(0, 520)

	_replays_status = Label.new()
	_replays_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_replays_status.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	tab.add_child(_replays_status)

	var scroll := ScrollContainer.new()
	scroll.follow_focus = true  # controller: scroll to keep the focused row in view
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tab.add_child(scroll)

	_replays_content = VBoxContainer.new()
	_replays_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_replays_content.add_theme_constant_override("separation", 10)
	scroll.add_child(_replays_content)
	return tab


func _refresh_replays() -> void:
	for child: Node in _replays_content.get_children():
		child.queue_free()
	var paths: Array[String] = ReplayFileIndex.list()
	if paths.is_empty():
		_replays_status.text = "No replays on this machine yet. Play a match (online or vs bots) to record one."
		_replays_status.visible = true
		return
	_replays_status.visible = false
	for path: String in paths:
		var meta: Dictionary = ReplayFileReader.read_meta(path)
		if not bool(meta.get("ok", false)):
			continue  # unreadable / wrong-version file — skip silently
		_replays_content.add_child(_build_replay_file_card(path, meta))


# One card per replay file: date + score headline, per-team box score, Watch
# button. Box-score columns differ from Recent Games because the .mreplay
# footer records a different stat set (hits/blocks, no plus-minus).
func _build_replay_file_card(path: String, meta: Dictionary) -> Control:
	var header: Dictionary = meta.get("header", {})
	var footer: Dictionary = meta.get("footer", {})
	var truncated: bool = bool(meta.get("truncated", false))

	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", MenuStyle.panel(4, 12))
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	card.add_child(vbox)

	vbox.add_child(_build_replay_headline(header, footer, truncated))

	# peer_id -> display name, from the header roster.
	var names: Dictionary = {}
	for r_var: Variant in (header.get("roster", []) as Array):
		var r: Dictionary = r_var as Dictionary
		names[_safe_int(r.get("peer_id", 0))] = str(r.get("player_name", "Player"))

	var players: Array = footer.get("players", []) as Array
	if not players.is_empty():
		var sep := HSeparator.new()
		sep.add_theme_color_override("color", MenuStyle.TEXT_SEP)
		vbox.add_child(sep)
		var home: Array = []
		var away: Array = []
		for p_var: Variant in players:
			var p: Dictionary = p_var as Dictionary
			if _safe_int(p.get("team_id", 0)) == 0:
				home.append(p)
			else:
				away.append(p)
		if not home.is_empty():
			vbox.add_child(_build_replay_player_table(home, names, "HOME"))
		if not away.is_empty():
			vbox.add_child(_build_replay_player_table(away, names, "AWAY"))

	var bottom := HBoxContainer.new()
	bottom.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(spacer)
	var watch := Button.new()
	watch.text = "▶  Watch Replay"
	watch.custom_minimum_size = Vector2(150, 32)
	watch.pressed.connect(_on_watch_pressed.bind(path))
	bottom.add_child(watch)
	vbox.add_child(bottom)

	return card


func _build_replay_headline(header: Dictionary, footer: Dictionary, truncated: bool) -> Control:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)

	var when: int = _safe_int(footer.get("ended_at", header.get("started_at", 0)))
	var date_label := Label.new()
	date_label.text = "—" if when <= 0 else Time.get_datetime_string_from_unix_time(when, true).substr(0, 16)
	date_label.add_theme_font_size_override("font_size", 12)
	date_label.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	date_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(date_label)

	var score := Label.new()
	if truncated or not footer.has("final_score_home"):
		score.text = "Unfinished"
		score.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	else:
		score.text = "%d — %d" % [_safe_int(footer.get("final_score_home", 0)),
				_safe_int(footer.get("final_score_away", 0))]
		score.add_theme_color_override("font_color", MenuStyle.TEAL_HOVER)
	score.add_theme_font_size_override("font_size", 18)
	hbox.add_child(score)

	return hbox


func _build_replay_player_table(players: Array, names: Dictionary, side_label: String) -> Control:
	var grid := GridContainer.new()
	grid.columns = 6
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 2)

	for h: String in PackedStringArray([side_label, "G", "A", "SOG", "Hits", "Blk"]):
		grid.add_child(_table_cell(h, true))

	for p_var: Variant in players:
		var p: Dictionary = p_var as Dictionary
		grid.add_child(_table_cell(str(names.get(_safe_int(p.get("peer_id", 0)), "Player"))))
		grid.add_child(_table_cell(str(_safe_int(p.get("goals", 0)))))
		grid.add_child(_table_cell(str(_safe_int(p.get("assists", 0)))))
		grid.add_child(_table_cell(str(_safe_int(p.get("shots_on_goal", 0)))))
		grid.add_child(_table_cell(str(_safe_int(p.get("hits", 0)))))
		grid.add_child(_table_cell(str(_safe_int(p.get("shots_blocked", 0)))))

	return grid


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
	var minutes: int = s / 60
	return "%d:%02d" % [minutes, s % 60]


# ── Career shot map ──────────────────────────────────────────────────────────

# Attacking-end shot density over a player's whole career. The buckets arrive
# already normalised to one attacking end by the shot_heatmap view (team 1's
# shots are rotated 180°), so a player who has skated both ends still reads as
# one coherent map — and their off-wing tendency survives the fold rather than
# cancelling itself out.
#
# Drawn goal-at-the-bottom: the attacking half is ~26 m wide by ~30 m deep, which
# fills a portrait panel far better than the landscape full-rink view the
# post-game map uses.
class CareerHeatMap extends Control:
	const _ICE := Color(0.075, 0.098, 0.141, 1.0)
	const _BOARDS := Color(0.24, 0.27, 0.33, 1.0)
	const _RED := Color(0.69, 0.31, 0.35, 0.70)
	const _BLUE := Color(0.23, 0.44, 0.69, 0.70)
	# Sequential ramp: one hue, dim -> bright. On a dark surface brightness is
	# the magnitude channel (the inverse of light-mode's light -> dark).
	const _HEAT_LOW := Color(0.13, 0.28, 0.52, 1.0)
	const _HEAT_HIGH := Color(0.42, 0.83, 0.95, 1.0)
	const _GOAL := Color(1.00, 0.85, 0.20, 1.0)

	var _buckets: Array = []
	var _peak: float = 1.0
	var _scale: float = 1.0
	var _origin := Vector2.ZERO

	func configure(buckets: Array) -> void:
		_buckets = buckets
		_peak = 1.0
		for b: Variant in buckets:
			var d: Dictionary = b as Dictionary
			_peak = maxf(_peak, float(d.get("shots", 0)))
		queue_redraw()

	# Attacking-half rink (z in [-30, 0], x in [-13, 13]) -> local pixels, goal
	# at the bottom.
	func _p(rx: float, rz: float) -> Vector2:
		return _origin + Vector2(rx * _scale, (-rz) * _scale)

	func _draw() -> void:
		var w: float = size.x
		var h: float = size.y
		if w <= 8.0 or h <= 8.0:
			return
		var half_w: float = GameRules.RINK_HALF_WIDTH
		var half_l: float = GameRules.RINK_HALF_LENGTH
		_scale = minf(w / (half_w * 2.0 + 1.0), h / (half_l + 1.0))
		_origin = Vector2(w * 0.5, (h - half_l * _scale) * 0.5)
		_draw_ice(half_w, half_l)
		_draw_buckets()
		if _buckets.is_empty():
			_draw_empty_note(w, h)

	func _draw_ice(half_w: float, half_l: float) -> void:
		var tl: Vector2 = _p(-half_w, 0.0)
		var br: Vector2 = _p(half_w, -half_l)
		draw_rect(Rect2(Vector2(tl.x, tl.y), Vector2(br.x - tl.x, br.y - tl.y)), _ICE, true)
		draw_rect(Rect2(Vector2(tl.x, tl.y), Vector2(br.x - tl.x, br.y - tl.y)),
				_BOARDS, false, 1.4)
		# Blue line, goal line, and the net mouth — enough reference to read
		# where a cluster sits without drawing a full rink diagram.
		var blue_z: float = -GameRules.BLUE_LINE_Z
		draw_line(_p(-half_w, blue_z), _p(half_w, blue_z), _BLUE, 2.0)
		var goal_z: float = -GameRules.GOAL_LINE_Z
		draw_line(_p(-half_w, goal_z), _p(half_w, goal_z), _RED, 1.2)
		var nhw: float = GameRules.NET_HALF_WIDTH
		draw_line(_p(-nhw, goal_z), _p(nhw, goal_z), _GOAL, 2.4)
		# Faceoff dots for scale.
		for fx: float in [-6.5, 6.5]:
			draw_arc(_p(fx, -20.0), 4.5 * _scale, 0.0, TAU, 28, _RED, 0.8)

	func _draw_buckets() -> void:
		var cell: float = _scale  # buckets are 1 m
		for b: Variant in _buckets:
			var d: Dictionary = b as Dictionary
			var shots: float = float(d.get("shots", 0))
			if shots <= 0.0:
				continue
			var bx: float = float(d.get("bucket_x", 0))
			var bz: float = float(d.get("bucket_z", 0))
			# Normalised buckets sit in the -Z attacking half; anything on the
			# far side is stale data from before the view normalised, so skip it
			# rather than drawing it off the panel.
			if bz > 0.0:
				continue
			var t: float = clampf(shots / _peak, 0.0, 1.0)
			# sqrt keeps the low end visible — most buckets are one or two shots,
			# and a linear ramp renders them almost invisible next to a hot slot.
			var col: Color = _HEAT_LOW.lerp(_HEAT_HIGH, sqrt(t))
			col.a = 0.30 + 0.65 * sqrt(t)
			var top_left: Vector2 = _p(bx - 0.5, bz + 0.5)
			draw_rect(Rect2(top_left, Vector2(cell, cell)), col, true)
			var goals: int = int(d.get("goals", 0))
			if goals > 0:
				var centre: Vector2 = _p(bx, bz)
				draw_circle(centre, maxf(2.0, cell * 0.28), _GOAL)

	func _draw_empty_note(w: float, h: float) -> void:
		var font: Font = MenuStyle.UI_FONT
		if font == null:
			return
		draw_string(font, Vector2(0.0, h * 0.5), "No shots recorded yet",
				HORIZONTAL_ALIGNMENT_CENTER, w, 13, MenuStyle.TEXT_MUTED)


# Legend swatch: the density ramp as a horizontal gradient.
class HeatRamp extends Control:
	func _draw() -> void:
		var steps: int = 24
		var step_w: float = size.x / float(steps)
		for i: int in steps:
			var t: float = float(i) / float(steps - 1)
			var col: Color = CareerHeatMap._HEAT_LOW.lerp(CareerHeatMap._HEAT_HIGH, t)
			col.a = 0.30 + 0.65 * t
			draw_rect(Rect2(Vector2(float(i) * step_w, 0.0),
					Vector2(step_w + 1.0, size.y)), col, true)


# Legend swatch: a goal marker.
class GoalDot extends Control:
	func _draw() -> void:
		draw_circle(Vector2(size.x * 0.5, size.y * 0.5), 4.0, CareerHeatMap._GOAL)
