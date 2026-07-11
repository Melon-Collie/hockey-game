class_name ReplayBrowser extends Control

# Local replay browser: lists the .mreplay files on THIS machine and launches the
# viewer. Reads everything from disk (ReplayFileIndex.list + ReplayFileReader.
# read_meta) — no Supabase, no online, and crucially no `share_gameplay_stats`
# gate. Watching a replay file you already own is a local action; it has nothing
# to do with whether you upload career stats. (The Career screen's Recent Games
# tab stays the cross-machine history view, backed by Supabase.)
#
# Pure-code UI in the CareerStatsScreen mould (scrim + centered panel + scroll),
# so SideMenu instantiates it with .new() and calls open().

var _status: Label = null
var _list_vbox: VBoxContainer = null


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
	title.text = "Replays"
	MenuStyle.apply_heading(title)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)

	var close_btn: Button = MenuStyle.close_button()
	close_btn.pressed.connect(hide)
	header.add_child(close_btn)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 13)
	_status.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	vbox.add_child(_status)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0.0, 460.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	_list_vbox = VBoxContainer.new()
	_list_vbox.add_theme_constant_override("separation", 10)
	_list_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list_vbox)

	hide()


func open() -> void:
	show()
	_refresh()


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed(&"ui_cancel"):
		hide()
		get_viewport().set_input_as_handled()


func _refresh() -> void:
	for child: Node in _list_vbox.get_children():
		child.queue_free()
	var paths: Array[String] = ReplayFileIndex.list()
	if paths.is_empty():
		_status.text = "No replays on this machine yet. Play an online game to record one."
		_status.visible = true
		return
	_status.visible = false
	for path: String in paths:
		var meta: Dictionary = ReplayFileReader.read_meta(path)
		if not bool(meta.get("ok", false)):
			continue  # unreadable / wrong-version file — skip silently
		_list_vbox.add_child(_build_card(path, meta))


# One card per replay: date + score headline, per-team box score, Watch button.
func _build_card(path: String, meta: Dictionary) -> Control:
	var header: Dictionary = meta.get("header", {})
	var footer: Dictionary = meta.get("footer", {})
	var truncated: bool = bool(meta.get("truncated", false))

	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", MenuStyle.panel(4, 12))
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	card.add_child(vbox)

	vbox.add_child(_build_headline(header, footer, truncated))

	# peer_id -> display name, from the header roster.
	var names: Dictionary = {}
	for r_var: Variant in (header.get("roster", []) as Array):
		var r: Dictionary = r_var as Dictionary
		names[_to_int(r.get("peer_id", 0))] = str(r.get("player_name", "Player"))

	var players: Array = footer.get("players", []) as Array
	if not players.is_empty():
		var sep := HSeparator.new()
		sep.add_theme_color_override("color", MenuStyle.TEXT_SEP)
		vbox.add_child(sep)
		var home: Array = []
		var away: Array = []
		for p_var: Variant in players:
			var p: Dictionary = p_var as Dictionary
			if _to_int(p.get("team_id", 0)) == 0:
				home.append(p)
			else:
				away.append(p)
		if not home.is_empty():
			vbox.add_child(_build_player_table(home, names, "HOME"))
		if not away.is_empty():
			vbox.add_child(_build_player_table(away, names, "AWAY"))

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


func _build_headline(header: Dictionary, footer: Dictionary, truncated: bool) -> Control:
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)

	var when: int = _to_int(footer.get("ended_at", header.get("started_at", 0)))
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
		score.text = "%d — %d" % [_to_int(footer.get("final_score_home", 0)),
				_to_int(footer.get("final_score_away", 0))]
		score.add_theme_color_override("font_color", MenuStyle.TEAL_HOVER)
	score.add_theme_font_size_override("font_size", 18)
	hbox.add_child(score)

	return hbox


func _build_player_table(players: Array, names: Dictionary, side_label: String) -> Control:
	var grid := GridContainer.new()
	grid.columns = 6
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 2)

	for h: String in PackedStringArray([side_label, "G", "A", "SOG", "Hits", "Blk"]):
		grid.add_child(_cell(h, true))

	for p_var: Variant in players:
		var p: Dictionary = p_var as Dictionary
		grid.add_child(_cell(str(names.get(_to_int(p.get("peer_id", 0)), "Player"))))
		grid.add_child(_cell(str(_to_int(p.get("goals", 0)))))
		grid.add_child(_cell(str(_to_int(p.get("assists", 0)))))
		grid.add_child(_cell(str(_to_int(p.get("shots_on_goal", 0)))))
		grid.add_child(_cell(str(_to_int(p.get("hits", 0)))))
		grid.add_child(_cell(str(_to_int(p.get("shots_blocked", 0)))))

	return grid


func _cell(text: String, is_header: bool = false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 11 if is_header else 12)
	l.add_theme_color_override("font_color",
			MenuStyle.TEXT_DIM if is_header else MenuStyle.TEXT_BODY)
	return l


func _on_watch_pressed(path: String) -> void:
	NetworkManager.pending_replay_path = path
	GameManager.on_scene_exit()
	get_tree().change_scene_to_file(Constants.SCENE_REPLAY_VIEWER)


# JSON numbers decode as int or float; normalize. Mirrors CareerStatsScreen._safe_int.
static func _to_int(v: Variant, default: int = 0) -> int:
	if v is int:
		return v
	if v is float:
		return int(v)
	return default
