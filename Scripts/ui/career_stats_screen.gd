class_name CareerStatsScreen extends Control

# Two-tab career screen:
#   Career Totals — lifetime aggregates + the career shot map, Supabase-backed
#     and gated on share_gameplay_stats, sliceable by roster size (All/5v5/3v3).
#   Games — one chronological list merging backend game history with the
#     .mreplay files on THIS machine, joined on game_id (a replay file is named
#     `<game_id>.mreplay`). Replays were a separate tab because they are ungated
#     while history needed stat sharing, and because bot games never reached the
#     backend; the latter stopped being true when offline matches started
#     uploading, and the former is a per-ENTRY difference rather than a
#     per-tab one — so a game shows whatever it has: full box score, a watchable
#     local file, or both. Local replays render before the network answers.
# Both tabs refresh on open() and surface their own loading / empty / gated states.

var _reporter := CareerStatsReporter.new()

# Hand-rolled tab switcher (matches OptionsPanel pattern); avoids Godot's
# native TabContainer which doesn't pick up our themed TabButton variations.
var _tab_btns: Array[Button] = []
var _tab_contents: Array[Control] = []
var _active_idx: int = 0  # active tab, for controller bumper switching + focus

# With stat sharing off the Career tab is just a gate notice, so open on Games —
# local replays are listed regardless of any backend gate.
const _TAB_GAMES: int = 1

# Career Totals tab.
var _totals_content: VBoxContainer = null
var _totals_status: Label = null
var _identity_label: Label = null
var _hero_row: HBoxContainer = null
var _heat_map: CareerHeatMap = null
var _map_note: Label = null
# Roster-size filter for the Career tab: 0 = every mode pooled, else 3 or 5.
# 3v3 and 5v5 aren't comparable (3v3 has far more space — more attempts, higher
# xG per shot; 5v5 has traffic and point shots), so pooling them is informative
# only as a headline.
var _mode_filter: int = 0
const _MODE_VALUES: Array[int] = [0, 5, 3]
const _MODE_LABELS: Array[String] = ["All modes", "5v5", "3v3"]
# Raw heatmap rows as fetched (every mode). Cached so flipping the filter
# re-renders from memory instead of re-querying.
var _heat_rows: Array = []

# The Games tab's cards were designed for the old narrow column and read fine;
# the shell is now full-bleed for the Career tab's sake, so that tab keeps its
# original measure instead of stretching across the screen.
const _NARROW_TAB_WIDTH: float = 660.0

# Fallback palette for a game whose colours can't be recovered (a backend row
# with no local .mreplay). Matches PostGameAnalytics' own defaults.
const _NEUTRAL_HOME := Color(0.85, 0.35, 0.15)
const _NEUTRAL_AWAY := Color(0.22, 0.53, 0.90)

# Games tab. Every entry — backend row, local .mreplay, or both — normalises into
# one summary and renders through the same _build_game_card; only the badges and
# which actions are enabled differ.
var _recent_content: VBoxContainer = null
var _recent_status: Label = null
# Analytics viewer for a past game, created on first use (see _show_analytics).
var _analytics: PostGameAnalytics = null


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

func _display_label(text: String, font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", MenuStyle.DISPLAY_FONT)
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	return l


func _ui_label(text: String, font_size: int, color: Color) -> Label:
	var l := _display_label(text, font_size, color)
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
	var games_tab := _narrow(_build_games_tab())
	_tab_contents = [totals_tab, games_tab]
	content_margin.add_child(totals_tab)
	content_margin.add_child(games_tab)

	var labels: Array[String] = ["Career Totals", "Games"]
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
	_activate_tab(_TAB_GAMES if not PlayerPrefs.share_gameplay_stats else 0)
	# Drop the cached map so a reopen picks up games played since last time;
	# within one viewing, mode switches re-slice it without refetching.
	_heat_rows.clear()
	_refresh_totals()
	_refresh_games()
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

	# Mode filter. Everything on this tab — the hero figures, the stat groups, and
	# the shot map — reads the same selection, so the numbers and the map can
	# never disagree about which games they describe.
	var filter_row := HBoxContainer.new()
	filter_row.alignment = BoxContainer.ALIGNMENT_END
	filter_row.add_theme_constant_override("separation", 8)
	var filter_label := _ui_label("SHOWING", 11, MenuStyle.TEXT_MUTED)
	filter_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	filter_row.add_child(filter_label)
	var mode_picker := OptionButton.new()
	mode_picker.custom_minimum_size = Vector2(140, 32)
	mode_picker.add_theme_font_size_override("font_size", 14)
	for i: int in _MODE_LABELS.size():
		mode_picker.add_item(_MODE_LABELS[i], i)
	mode_picker.selected = 0
	MenuStyle.apply_focus_ring(mode_picker)
	SoundManager.wire_button(mode_picker)
	mode_picker.item_selected.connect(_on_mode_selected)
	filter_row.add_child(mode_picker)
	tab.add_child(filter_row)

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
	_map_note = _ui_label("offensive zone · brighter = more shots", 11, MenuStyle.TEXT_MUTED)
	map_head.add_child(_map_note)
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
	_reporter.fetch_totals(_on_totals_received, _mode_filter)
	# The map is fetched once per screen-open and re-sliced locally thereafter,
	# so switching modes costs no round trip.
	if _heat_rows.is_empty():
		_reporter.fetch_shot_heatmap(SteamManager.steam_id, _on_heatmap_received)
	else:
		_apply_heatmap_filter()


# Flipping the mode refetches the TOTALS (their ratios have to be recomputed
# server-side inside the filter) but re-renders the MAP from the cached rows —
# bucket counts are additive, so the client can slice them itself.
func _on_mode_selected(index: int) -> void:
	var next: int = _MODE_VALUES[index] if index >= 0 and index < _MODE_VALUES.size() else 0
	if next == _mode_filter:
		return
	_mode_filter = next
	_refresh_totals()


func _on_heatmap_received(buckets: Array) -> void:
	_heat_rows = buckets
	_apply_heatmap_filter()


# The view returns one row per (bucket, team_size), so an unfiltered map has the
# same square once per mode. Fold them together: drawing both would double the
# cell's alpha and skew the peak the ramp normalises against.
func _merged_buckets(rows: Array) -> Array:
	var by_cell: Dictionary = {}
	for b: Variant in rows:
		var d: Dictionary = b as Dictionary
		var key: String = "%d,%d" % [int(d.get("bucket_x", 0)), int(d.get("bucket_z", 0))]
		if by_cell.has(key):
			var acc: Dictionary = by_cell[key]
			acc["shots"] = int(acc["shots"]) + int(d.get("shots", 0))
			acc["goals"] = int(acc["goals"]) + int(d.get("goals", 0))
			acc["xg"] = float(acc["xg"]) + float(d.get("xg", 0.0))
		else:
			by_cell[key] = {
				"bucket_x": int(d.get("bucket_x", 0)),
				"bucket_z": int(d.get("bucket_z", 0)),
				"shots": int(d.get("shots", 0)),
				"goals": int(d.get("goals", 0)),
				"xg": float(d.get("xg", 0.0)),
			}
	return by_cell.values()


func _apply_heatmap_filter() -> void:
	if _heat_map == null:
		return
	var rows: Array = _heat_rows
	if _mode_filter > 0:
		rows = []
		for b: Variant in _heat_rows:
			var d: Dictionary = b as Dictionary
			if int(d.get("team_size", 0)) == _mode_filter:
				rows.append(d)
	else:
		rows = _merged_buckets(_heat_rows)
	_heat_map.configure(rows)
	# Shots taken from outside the offensive zone aren't drawn (clamping them to
	# the top row would invent a hot band on the blue line), so say so rather
	# than quietly losing them from the total.
	if _map_note != null:
		var outside: int = _heat_map.outside_zone_shots()
		_map_note.text = "offensive zone · brighter = more shots" if outside == 0 \
				else "offensive zone · brighter = more shots · %d outside" % outside


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

# ── Games tab (backend history + local replays, merged) ──────────────────────
# One chronological list of games rather than two tabs. They split originally
# because replays are ungated while history needed stat sharing, AND because
# bot-lobby games never reached the backend — the second reason disappeared when
# offline matches started uploading. What is left is a per-entry difference, not
# a per-tab one: a game may have backend stats, a local replay file, or both.
#
# The join key is free: replay files are named `<game_id>.mreplay`, the same id
# the backend rows carry.

func _build_games_tab() -> Control:
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
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tab.add_child(scroll)

	_recent_content = VBoxContainer.new()
	_recent_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_recent_content.add_theme_constant_override("separation", 14)
	scroll.add_child(_recent_content)
	return tab


# Local replays render immediately (no gate, no round trip); backend history
# folds in when it arrives, so the list is useful before the network answers.
func _refresh_games() -> void:
	_clear_recent_content()
	_render_games([])
	if not PlayerPrefs.share_gameplay_stats or SteamManager.steam_id == 0:
		return
	_reporter.fetch_recent_games(SteamManager.steam_id, 20, _render_games)


# Union of backend rows and on-disk replays, newest first. A backend row wins
# where both exist — it carries the full box score, and _build_game_card already
# enables or disables its own Watch button by testing for the file.
func _render_games(games: Array) -> void:
	_clear_recent_content()
	var entries: Array = []
	var seen: Dictionary = {}
	for entry: Variant in games:
		var game: Dictionary = entry as Dictionary
		var gid: String = str(game.get("game_id", ""))
		if not gid.is_empty():
			seen[gid] = true
		var gpath: String = "user://replays/%s.mreplay" % gid
		entries.append({
			"at": _iso_to_unix(str(game.get("ended_at", ""))),
			"game": game,
			"path": gpath if FileAccess.file_exists(gpath) else "",
		})
	for path: String in ReplayFileIndex.list():
		# Filename IS the game_id, so a replay already covered by a backend row
		# needs no separate card.
		if seen.has(path.get_file().get_basename()):
			continue
		entries.append({
			"at": FileAccess.get_modified_time(path),
			"game": {}, "path": path,
		})
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["at"]) > int(b["at"]))

	if entries.is_empty():
		_recent_status.text = "No games yet. Play a match (online or vs bots) to fill this list."
		_recent_status.visible = true
		return
	_recent_status.visible = false
	for e: Variant in entries:
		var row: Dictionary = e as Dictionary
		var path: String = String(row["path"])
		# The palette a match was played in lives only in the .mreplay header
		# (career_stats has no colour columns), so read it whenever the file is
		# here — including for backend-backed games, which then get their real
		# colours instead of the neutral fallback.
		var meta: Dictionary = ReplayFileReader.read_meta(path) if not path.is_empty() else {}
		if path.is_empty():
			_recent_content.add_child(
					_build_game_card(_summarise_backend(row["game"] as Dictionary, {})))
			continue
		if not bool(meta.get("ok", false)):
			continue  # unreadable / wrong-version file — skip silently
		if row["game"] != null and not (row["game"] as Dictionary).is_empty():
			_recent_content.add_child(
					_build_game_card(_summarise_backend(row["game"] as Dictionary, meta)))
		else:
			_recent_content.add_child(_build_game_card(_summarise_replay(path, meta)))


# ISO-8601 -> unix seconds, so backend rows sort against replay file mtimes.
# 0 when absent or unparseable, which sinks the entry rather than crashing.
func _iso_to_unix(iso: String) -> int:
	if iso.is_empty():
		return 0
	return int(Time.get_unix_time_from_datetime_string(iso))


func _clear_recent_content() -> void:
	for child: Node in _recent_content.get_children():
		child.queue_free()


# ── The game card ────────────────────────────────────────────────────────────
# ONE card style for every entry. Both sources normalise into the same summary
# (see _summarise_backend / _summarise_replay), so a game looks the same whether
# its data came from the backend, a local .mreplay, or both — only the badges and
# the enabled actions differ.
#
# Deliberately AT A GLANCE: date, mode, result, score, period line, actions. The
# old cards embedded full per-team box-score tables, which made the list
# something you read rather than scanned — and the deep numbers already live on
# the Career tab and the analytics screen.

func _build_game_card(summary: Dictionary) -> Control:
	var card := _broadcast_panel()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	card.add_child(vbox)

	# Top line: date on the left, badges on the right.
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	var date := _ui_label(String(summary.get("date", "")), 12, MenuStyle.TEXT_MUTED)
	date.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	date.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	top.add_child(date)
	var team_size: int = int(summary.get("team_size", 0))
	if team_size > 0:
		top.add_child(_badge("%dv%d" % [team_size, team_size], MenuStyle.TEXT_DIM))
	# Result and origin are independent — a local game can also be a win, and
	# showing only one of the two made the badge row look like it was picking.
	var outcome: String = String(summary.get("outcome", ""))
	if not outcome.is_empty():
		top.add_child(_badge(outcome.to_upper(), _outcome_color(outcome)))
	if String(summary.get("source", "")) == "local":
		top.add_child(_badge("LOCAL", MenuStyle.TEXT_MUTED))
	vbox.add_child(top)

	# Score line: the headline, and the only thing in a large size. Treated like
	# the in-game scorebug and the box score's period summary — the team's colour
	# is a BAND beside white lettering, never the lettering itself. Colouring the
	# digits made the score hard to read (a dark primary on the dark card) and
	# made two different-coloured numbers look like two different kinds of thing.
	var colors: Array = summary.get("colors", []) as Array
	var home_col: Color = colors[0] if colors.size() == 2 else _NEUTRAL_HOME
	var away_col: Color = colors[1] if colors.size() == 2 else _NEUTRAL_AWAY
	var score := HBoxContainer.new()
	score.alignment = BoxContainer.ALIGNMENT_CENTER
	score.add_theme_constant_override("separation", 8)
	score.add_child(_team_swatch(home_col))
	score.add_child(_ui_label("HOME", 12, MenuStyle.BROADCAST_CREAM))
	score.add_child(_display_label(str(int(summary.get("home", 0))), 30,
			MenuStyle.BROADCAST_CREAM))
	score.add_child(_display_label("—", 18, MenuStyle.TEXT_MUTED))
	score.add_child(_display_label(str(int(summary.get("away", 0))), 30,
			MenuStyle.BROADCAST_CREAM))
	score.add_child(_ui_label("AWAY", 12, MenuStyle.BROADCAST_CREAM))
	score.add_child(_team_swatch(away_col))
	vbox.add_child(score)

	var periods: Control = _period_grid(summary.get("periods", []) as Array,
			home_col, away_col)
	if periods != null:
		vbox.add_child(periods)

	# Who played — the strongest recognition cue on the card, which is what this
	# list is for. Names only; the per-player stat tables that used to live here
	# made the list something you read rather than scanned.
	var roster: Dictionary = summary.get("roster", {}) as Dictionary
	for team_id: int in 2:
		var names: Array = roster.get(team_id, []) as Array
		if names.is_empty():
			continue
		var line := _ui_label(" · ".join(PackedStringArray(names)), 11,
				home_col if team_id == 0 else away_col)
		line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		vbox.add_child(line)

	var you: String = String(summary.get("you", ""))
	if not you.is_empty():
		var mine := _ui_label(you, 11, MenuStyle.GOLD)
		mine.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vbox.add_child(mine)

	var actions := HBoxContainer.new()
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	actions.add_theme_constant_override("separation", 8)
	actions.add_child(_watch_button(String(summary.get("path", ""))))
	actions.add_child(_analytics_button(summary))
	vbox.add_child(actions)
	return card


# Backend history row -> card summary.
func _summarise_backend(game: Dictionary, meta: Dictionary) -> Dictionary:
	var gid: String = str(game.get("game_id", ""))
	var path: String = "user://replays/%s.mreplay" % gid
	# Score comes from period_scores when present: the period line rendered just
	# below is summed from it, so deriving the total the same way keeps the two
	# from ever disagreeing.
	var periods: Array = (game.get("period_scores", []) as Array) if game.get("period_scores") != null else []
	var home: int = _safe_int(game.get("home_score", 0))
	var away: int = _safe_int(game.get("away_score", 0))
	if periods.size() >= 2:
		home = _sum_periods(periods[0])
		away = _sum_periods(periods[1])
	return {
		"date": _format_date(str(game.get("ended_at", ""))),
		"home": home, "away": away, "periods": periods,
		"team_size": _safe_int(game.get("team_size", 0)),
		"outcome": str(game.get("outcome", "")),
		"path": path if FileAccess.file_exists(path) else "",
		"source": "backend",
		"game_id": gid,
		"colors": _colors_from_meta(meta),
		# Prefer the replay's roster: career_stats rows exist per HUMAN, so the
		# backend's player list omits bots entirely — a solo bot game would name
		# only you, which is the opposite of recognisable. The file's roster is
		# the full registry.
		"roster": _roster_from_meta(meta) if not _header_roster(meta).is_empty() \
				else _roster_from_backend(game),
		"you": _you_line_from_meta(meta),
		# recent_games_for counts the logged shots, so the Analytics action is
		# enabled only where there is something to draw — games recorded before
		# shot logging existed report 0 rather than opening an empty screen.
		"shots": _safe_int(game.get("shot_count", 0)),
	}


# Local .mreplay meta -> card summary. No outcome badge: the file records the
# match, not which side was yours.
func _summarise_replay(path: String, meta: Dictionary) -> Dictionary:
	var footer: Dictionary = meta.get("footer", {})
	var ended: float = float(footer.get("ended_at", 0.0))
	var date: String = Time.get_datetime_string_from_unix_time(int(ended)).replace("T", " ").substr(0, 16) \
			if ended > 0.0 else "Local replay"
	return {
		"date": date,
		"home": _safe_int(footer.get("final_score_home", 0)),
		"away": _safe_int(footer.get("final_score_away", 0)),
		"periods": (footer.get("period_scores", []) as Array) if footer.get("period_scores") != null else [],
		"team_size": _safe_int(footer.get("team_size", 0)),
		"outcome": _outcome_from_meta(meta),
		"path": path,
		"source": "local",
		"game_id": "",
		"colors": _colors_from_meta(meta),
		"roster": _roster_from_meta(meta),
		"you": _you_line_from_meta(meta),
		# Footers written before shot logging have no list, so this reads 0 and
		# the action stays disabled for older files.
		"shots": (footer.get("shot_events", []) as Array).size() \
				if footer.get("shot_events") != null else 0,
		"shot_rows": footer.get("shot_events", []),
	}


# The match's real palette, from the .mreplay header's colour slots. career_stats
# has no colour columns, so a backend game with no local file falls back to the
# neutral pair rather than borrowing the current session's colours — which would
# paint an old game in a palette it was never played in.
#
# Each team's own PRIMARY, via the score-stripe rule the scorebug and the box
# score's period summary already use — these cards are score surfaces, so they
# have to agree with the in-game ones. Not the jersey/* keys: those mirror the
# 3D uniform (away's is near-white) and read muddy or invisible in flat UI.
func _colors_from_meta(meta: Dictionary) -> Array[Color]:
	var header: Dictionary = meta.get("header", {})
	if not header.has("home_color_slot"):
		return [_NEUTRAL_HOME, _NEUTRAL_AWAY]
	var pair: Dictionary = TeamColorRegistry.get_score_stripe_pair(
			_safe_int(header.get("home_color_slot", 0)),
			_safe_int(header.get("away_color_slot", 1)))
	return [pair.home, pair.away]


# Win/loss for a LOCAL-only game. The footer records the score but not whose it
# was; the header's roster does, via the is_local flag on the recording peer's
# entry. Empty when the roster can't answer (a spectator recording, say).
# The .mreplay header calls its player list `roster`; the FOOTER calls its box
# score `players`. Two different keys for two different payloads — reading
# `players` off the header silently yields an empty list (which is exactly how
# the names, the local win/loss badge, and the YOU line all went missing), so
# every header read goes through here.
func _header_roster(meta: Dictionary) -> Array:
	var header: Dictionary = meta.get("header", {})
	return (header.get("roster", []) as Array) if header.get("roster") != null else []


func _outcome_from_meta(meta: Dictionary) -> String:
	var footer: Dictionary = meta.get("footer", {})
	var my_team: int = -1
	for entry: Variant in _header_roster(meta):
		var p: Dictionary = entry as Dictionary
		if bool(p.get("is_local", false)):
			my_team = _safe_int(p.get("team_id", -1))
			break
	if my_team < 0:
		return ""
	var home: int = _safe_int(footer.get("final_score_home", 0))
	var away: int = _safe_int(footer.get("final_score_away", 0))
	var mine: int = home if my_team == 0 else away
	var theirs: int = away if my_team == 0 else home
	if mine > theirs:
		return "win"
	return "loss" if mine < theirs else "draw"


# team_id -> display names, from the .mreplay header's full registry (bots
# included). The local player is marked so you can spot yourself in a lobby of
# similar names.
func _roster_from_meta(meta: Dictionary) -> Dictionary:
	var out: Dictionary = {0: [], 1: []}
	for entry: Variant in _header_roster(meta):
		var p: Dictionary = entry as Dictionary
		var team_id: int = clampi(_safe_int(p.get("team_id", 0)), 0, 1)
		var display: String = String(p.get("player_name", ""))
		if display.is_empty():
			continue
		if bool(p.get("is_local", false)):
			display += " (you)"
		(out[team_id] as Array).append(display)
	return out


# Fallback for a backend game with no local file: humans only, since that is all
# career_stats records.
func _roster_from_backend(game: Dictionary) -> Dictionary:
	var out: Dictionary = {0: [], 1: []}
	for entry: Variant in (game.get("players", []) as Array):
		var p: Dictionary = entry as Dictionary
		var team_id: int = clampi(_safe_int(p.get("team_id", 0)), 0, 1)
		var display: String = String(p.get("player_name", ""))
		if not display.is_empty():
			(out[team_id] as Array).append(display)
	return out


# "YOU · 2G 1A · 5 SOG" — your own line, which is what actually makes a game
# memorable ("the one where I had a hat trick"). Built from the replay footer's
# box score, joined to the header's is_local flag by peer_id. Empty when there is
# no local file: the backend's player JSON carries no steam_id, so there is no
# way to tell which of its rows is yours.
func _you_line_from_meta(meta: Dictionary) -> String:
	var footer: Dictionary = meta.get("footer", {})
	var my_peer: int = -1
	for entry: Variant in _header_roster(meta):
		var p: Dictionary = entry as Dictionary
		if bool(p.get("is_local", false)):
			my_peer = _safe_int(p.get("peer_id", -1))
			break
	if my_peer < 0:
		return ""
	for entry: Variant in (footer.get("players", []) as Array):
		var p: Dictionary = entry as Dictionary
		if _safe_int(p.get("peer_id", -2)) != my_peer:
			continue
		var goals: int = _safe_int(p.get("goals", 0))
		var assists: int = _safe_int(p.get("assists", 0))
		var sog: int = _safe_int(p.get("shots_on_goal", 0))
		return "YOU · %dG %dA · %d SOG" % [goals, assists, sog]
	return ""


func _sum_periods(row: Variant) -> int:
	var total: int = 0
	if row is Array:
		for v: Variant in row as Array:
			total += _safe_int(v)
	return total


# Period scoring as a real grid — a header row of period numbers over one row
# per team — matching how period scores are laid out everywhere else in the game.
# The previous run-together string ("1-1 · 2-1 · 1-1") gave no column alignment
# and no way to see which side a number belonged to. Null when there is nothing
# to show.
func _period_grid(periods: Array, home_col: Color, away_col: Color) -> Control:
	if periods.size() < 2 or not (periods[0] is Array) or not (periods[1] is Array):
		return null
	var home: Array = periods[0] as Array
	var away: Array = periods[1] as Array
	var count: int = mini(home.size(), away.size())
	if count <= 0:
		return null

	var grid := GridContainer.new()
	grid.columns = count + 1
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 2)
	grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER

	grid.add_child(_period_cell("", MenuStyle.TEXT_MUTED, 10))
	for i: int in count:
		# OT periods carry on past the configured regulation count; label them as
		# such rather than as "P4".
		var label: String = "P%d" % (i + 1) if i < 3 else "OT"
		grid.add_child(_period_cell(label, MenuStyle.TEXT_MUTED, 10))
	for row: int in 2:
		var side: Array = home if row == 0 else away
		var col: Color = home_col if row == 0 else away_col
		grid.add_child(_period_cell("H" if row == 0 else "A", col, 11))
		for i: int in count:
			grid.add_child(_period_cell(str(_safe_int(side[i])),
					MenuStyle.BROADCAST_CREAM, 12))
	return grid


func _period_cell(text: String, color: Color, font_size: int) -> Label:
	var l := _ui_label(text, font_size, color)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.custom_minimum_size = Vector2(22, 0)
	return l


func _team_swatch(color: Color) -> Control:
	var p := Panel.new()
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(2)
	p.add_theme_stylebox_override("panel", style)
	p.custom_minimum_size = Vector2(5, 30)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return p


func _badge(text: String, color: Color) -> Control:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(color.r, color.g, color.b, 0.14)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(4)
	style.content_margin_left = 7.0
	style.content_margin_right = 7.0
	panel.add_theme_stylebox_override("panel", style)
	panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	panel.add_child(_ui_label(text, 10, color))
	return panel


func _outcome_color(outcome: String) -> Color:
	match outcome:
		"win":
			return MenuStyle.GOLD
		"loss":
			return MenuStyle.TEXT_MUTED
		_:
			return MenuStyle.TEXT_DIM


func _watch_button(path: String) -> Button:
	var btn := Button.new()
	btn.text = "▶  Watch Replay"
	btn.custom_minimum_size = Vector2(160, 32)
	btn.add_theme_font_size_override("font_size", 14)
	MenuStyle.apply_focus_ring(btn)
	SoundManager.wire_button(btn)
	if path.is_empty():
		btn.disabled = true
		btn.tooltip_text = "Replay not on this machine"
	else:
		btn.pressed.connect(_on_watch_pressed.bind(path))
	return btn


# Opens the post-game analytics views for a PAST game. Local replays carry their
# shot log in the footer, so they open with no round trip; backend games fetch
# theirs by game_id. Disabled where nothing was logged (games predating shot
# logging), which the summary knows without a speculative query.
func _analytics_button(summary: Dictionary) -> Button:
	var btn := Button.new()
	btn.text = "◱  Analytics"
	btn.custom_minimum_size = Vector2(130, 32)
	btn.add_theme_font_size_override("font_size", 14)
	MenuStyle.apply_focus_ring(btn)
	SoundManager.wire_button(btn)
	if int(summary.get("shots", 0)) <= 0:
		btn.disabled = true
		btn.tooltip_text = "No shot data recorded for this game"
		return btn
	btn.pressed.connect(_on_analytics_pressed.bind(summary))
	return btn


func _on_analytics_pressed(summary: Dictionary) -> void:
	var home: int = int(summary.get("home", -1))
	var away: int = int(summary.get("away", -1))
	var label: String = "%s · replayed from the game's shot log" % String(summary.get("date", ""))
	var colors: Array[Color] = []
	for c: Variant in (summary.get("colors", []) as Array):
		colors.append(c as Color)
	if String(summary.get("source", "")) == "local":
		_show_analytics(ShotEvent.decode_list(summary.get("shot_rows", []) as Array),
				home, away, label, colors)
		return
	_reporter.fetch_shot_events(String(summary.get("game_id", "")),
			func(rows: Array) -> void:
				_show_analytics(ShotEvent.decode_rows(rows), home, away, label, colors))


func _show_analytics(events: Array[ShotEvent], home: int, away: int, label: String,
		colors: Array[Color]) -> void:
	if _analytics == null:
		# Created lazily and owned here: the career screen is reachable from the
		# main menu, where no HUD exists to provide one.
		_analytics = PostGameAnalytics.new()
		add_child(_analytics)
	_analytics.present_history(events, home, away, label, colors)


func _on_watch_pressed(path: String) -> void:
	NetworkManager.pending_replay_path = path
	GameManager.on_scene_exit()
	get_tree().change_scene_to_file(Constants.SCENE_REPLAY_VIEWER)


func _format_date(ended_at_iso: String) -> String:
	if ended_at_iso.is_empty():
		return "—"
	var no_tz: String = ended_at_iso.split("+")[0].split(".")[0].replace("T", " ")
	if no_tz.length() >= 16:
		return no_tz.substr(0, 16)
	return no_tz


# Supabase returns numerics as strings or floats depending on the column, and a
# missing key as null — these coerce whatever arrives without erroring.
static func _safe_int(value: Variant) -> int:
	match typeof(value):
		TYPE_INT:
			return value
		TYPE_FLOAT:
			return int(value)
		TYPE_STRING:
			return int(str(value).to_float())
		_:
			return 0


static func _safe_float(value: Variant) -> float:
	match typeof(value):
		TYPE_INT, TYPE_FLOAT:
			return float(value)
		TYPE_STRING:
			return str(value).to_float()
		_:
			return 0.0


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

	# The drawn region is the OFFENSIVE ZONE only, not the attacking half: shots
	# from outside the blue line are rare, so half the panel was empty neutral-zone
	# ice. Cropping to the zone is ~1.3x zoom where every cluster actually lives.
	# One metre of lead-in above the line keeps the blue line itself visible as a
	# reference edge rather than sitting exactly on the boundary.
	const _LEAD_IN_M: float = 1.0

	var _buckets: Array = []
	var _peak: float = 1.0
	var _scale: float = 1.0
	var _origin := Vector2.ZERO
	# Shots from outside the zone are counted rather than drawn — clamping them
	# to the top row would invent a hot band along the blue line.
	var _outside: int = 0

	func configure(buckets: Array) -> void:
		_buckets = buckets
		_peak = 1.0
		_outside = 0
		for b: Variant in buckets:
			var d: Dictionary = b as Dictionary
			if float(d.get("bucket_z", 0)) > _top_z():
				_outside += int(d.get("shots", 0))
				continue
			_peak = maxf(_peak, float(d.get("shots", 0)))
		queue_redraw()

	func outside_zone_shots() -> int:
		return _outside

	static func _top_z() -> float:
		return -(GameRules.BLUE_LINE_Z - _LEAD_IN_M)

	# Offensive zone (z in [-30, top_z], x in [-13, 13]) -> local pixels, goal
	# at the bottom.
	func _p(rx: float, rz: float) -> Vector2:
		return _origin + Vector2(rx * _scale, (_top_z() - rz) * _scale)

	func _draw() -> void:
		var w: float = size.x
		var h: float = size.y
		if w <= 8.0 or h <= 8.0:
			return
		var half_w: float = GameRules.RINK_HALF_WIDTH
		var depth: float = GameRules.RINK_HALF_LENGTH + _top_z()
		_scale = minf(w / (half_w * 2.0 + 1.0), h / (depth + 1.0))
		_origin = Vector2(w * 0.5, (h - depth * _scale) * 0.5)
		_draw_ice(half_w)
		_draw_buckets()
		if _buckets.is_empty():
			_draw_empty_note(w, h)

	# The zone outline carries the real rounded end boards (CORNER_RADIUS), so
	# corner shots read as being in the corner rather than in a boxed-off square.
	func _zone_outline(half_w: float) -> PackedVector2Array:
		var far_z: float = -GameRules.RINK_HALF_LENGTH
		var r: float = GameRules.CORNER_RADIUS
		var pts := PackedVector2Array()
		pts.append(_p(-half_w, _top_z()))
		pts.append(_p(half_w, _top_z()))
		pts.append(_p(half_w, far_z + r))
		var steps: int = 10
		var cx: float = half_w - r
		var cz: float = far_z + r
		for i: int in range(steps + 1):  # right corner, sweeping to the end boards
			var a: float = -PI * 0.5 * (float(i) / float(steps))
			pts.append(_p(cx + r * cos(a), cz + r * sin(a)))
		for i: int in range(steps + 1):  # left corner, back up the far side
			var a: float = -PI * 0.5 - PI * 0.5 * (float(i) / float(steps))
			pts.append(_p(-cx + r * cos(a), cz + r * sin(a)))
		pts.append(_p(-half_w, far_z + r))
		return pts

	func _draw_ice(half_w: float) -> void:
		var outline: PackedVector2Array = _zone_outline(half_w)
		draw_colored_polygon(outline, _ICE)
		var closed := outline.duplicate()
		closed.append(outline[0])
		draw_polyline(closed, _BOARDS, 1.4)
		# Blue line, goal line, and the net mouth — enough reference to read
		# where a cluster sits without drawing a full rink diagram.
		var blue_z: float = -GameRules.BLUE_LINE_Z
		draw_line(_p(-half_w, blue_z), _p(half_w, blue_z), _BLUE, 2.0)
		var goal_z: float = -GameRules.GOAL_LINE_Z
		draw_line(_p(-half_w, goal_z), _p(half_w, goal_z), _RED, 1.2)
		var nhw: float = GameRules.NET_HALF_WIDTH
		draw_line(_p(-nhw, goal_z), _p(nhw, goal_z), _GOAL, 2.4)
		# Zone faceoff circles for scale.
		for fx: float in [-6.5, 6.5]:
			draw_arc(_p(fx, -20.0), 4.5 * _scale, 0.0, TAU, 28, _RED, 0.8)
			draw_circle(_p(fx, -20.0), maxf(1.2, 0.16 * _scale), _RED)

	func _draw_buckets() -> void:
		var cell: float = _scale  # buckets are 1 m
		for b: Variant in _buckets:
			var d: Dictionary = b as Dictionary
			var shots: float = float(d.get("shots", 0))
			if shots <= 0.0:
				continue
			var bx: float = float(d.get("bucket_x", 0))
			var bz: float = float(d.get("bucket_z", 0))
			# Outside the drawn zone (or, for stale pre-normalisation rows, the
			# wrong end entirely) — counted in _outside, not drawn.
			if bz > _top_z():
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
