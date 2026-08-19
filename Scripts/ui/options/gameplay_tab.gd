class_name OptionsGameplayTab
extends OptionsTab

# Gameplay tab — general/gameplay toggles, plus the file-export "Customization"
# section and the data-sharing "Privacy" section.

var _locale_btn: OptionButton = null
var _attack_up_check: CheckButton = null
var _self_beacon_mode_btn: OptionButton = null
var _freeplay_goalie_btn: OptionButton = null
var _share_stats_check: CheckButton = null
var _export_status_label: Label = null
var _bot_export_status_label: Label = null

func _build_content() -> void:
	add_child(_section_header("General"))

	# UI language. Index 0 is "System default" (empty stored code → follow the OS
	# language); items 1.. are the shipped locales, each named in itself. Takes
	# effect on Apply; freshly-built UI picks it up on next open — see
	# LocaleManager / PlayerPrefs.apply_locale.
	_locale_btn = OptionButton.new()
	_locale_btn.custom_minimum_size = Vector2(160, 40)
	_locale_btn.add_theme_font_size_override("font_size", 15)
	_locale_btn.add_item("System default")
	for entry: Dictionary in LocaleManager.SUPPORTED:
		_locale_btn.add_item(entry["native_name"])
	_locale_btn.selected = 0 if PlayerPrefs.locale == "" \
		else LocaleManager.index_of(PlayerPrefs.locale) + 1
	SoundManager.wire_button(_locale_btn)
	_locale_btn.item_selected.connect(func(_i: int) -> void: _notify_changed())
	add_child(_field_row("Language", _locale_btn))

	add_child(_section_spacer())
	add_child(_section_header("Gameplay"))

	_attack_up_check = CheckButton.new()
	_attack_up_check.set_pressed_no_signal(PlayerPrefs.attack_up)
	SoundManager.wire_button(_attack_up_check)
	_attack_up_check.toggled.connect(func(_p: bool) -> void: _notify_changed())
	add_child(_field_row("Always Attack Up", _attack_up_check))

	_self_beacon_mode_btn = OptionButton.new()
	_self_beacon_mode_btn.custom_minimum_size = Vector2(160, 40)
	_self_beacon_mode_btn.add_theme_font_size_override("font_size", 15)
	for i: int in PlayerPrefs.BEACON_MODE_LABELS.size():
		_self_beacon_mode_btn.add_item(PlayerPrefs.BEACON_MODE_LABELS[i], i)
	_self_beacon_mode_btn.selected = PlayerPrefs.self_beacon_mode
	_self_beacon_mode_btn.item_selected.connect(func(_i: int) -> void: _notify_changed())
	add_child(_field_row("Self Marker", _self_beacon_mode_btn))

	# Free-play goalie difficulty — a personal-sandbox knob, separate from the
	# hosted/lobby goalie setting (which lives in the lobby settings panel).
	# Applies live to the running free-play goalies on Apply (no match reload).
	_freeplay_goalie_btn = OptionButton.new()
	_freeplay_goalie_btn.custom_minimum_size = Vector2(160, 40)
	_freeplay_goalie_btn.add_theme_font_size_override("font_size", 15)
	for i: int in PlayerPrefs.GOALIE_DIFFICULTY_LABELS.size():
		_freeplay_goalie_btn.add_item(PlayerPrefs.GOALIE_DIFFICULTY_LABELS[i], i)
	_freeplay_goalie_btn.selected = PlayerPrefs.freeplay_goalie_difficulty
	SoundManager.wire_button(_freeplay_goalie_btn)
	_freeplay_goalie_btn.item_selected.connect(func(_i: int) -> void: _notify_changed())
	add_child(_field_row("Free Play Goalie", _freeplay_goalie_btn))

	add_child(_section_spacer())
	add_child(_section_header("Customization"))

	var export_btn := _make_button("Export Colors File...")
	export_btn.custom_minimum_size = Vector2(260, 40)
	export_btn.add_theme_font_size_override("font_size", 16)
	export_btn.pressed.connect(_on_export_colors_pressed)
	add_child(_field_row("Custom palette", export_btn))

	_export_status_label = _make_status_label()
	add_child(_export_status_label)

	var bots_hint := Label.new()
	bots_hint.add_theme_font_size_override("font_size", 12)
	bots_hint.add_theme_color_override("font_color", _MUTED)
	bots_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bots_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	bots_hint.text = "Edit AI bot names, numbers, and attributes. As host, your roster is used for the whole lobby. Builds over the point-buy budget reset to medium."
	add_child(bots_hint)

	var bots_export_btn := _make_button("Export Bots File...")
	bots_export_btn.custom_minimum_size = Vector2(260, 40)
	bots_export_btn.add_theme_font_size_override("font_size", 16)
	bots_export_btn.pressed.connect(_on_export_bots_pressed)
	add_child(_field_row("Custom bots", bots_export_btn))

	_bot_export_status_label = _make_status_label()
	add_child(_bot_export_status_label)

	add_child(_section_spacer())
	add_child(_section_header("Privacy"))

	_share_stats_check = CheckButton.new()
	_share_stats_check.set_pressed_no_signal(PlayerPrefs.share_gameplay_stats)
	SoundManager.wire_button(_share_stats_check)
	_share_stats_check.toggled.connect(func(_p: bool) -> void: _notify_changed())
	add_child(_field_row("Share Gameplay Stats", _share_stats_check))

	var stats_notice := Label.new()
	stats_notice.text = "Uploads match results so you can track your career. " \
		+ "With this off, the Career menu and replay playback are unavailable — " \
		+ "both are built from your uploaded games."
	stats_notice.add_theme_font_size_override("font_size", 12)
	stats_notice.add_theme_color_override("font_color", _MUTED)
	stats_notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stats_notice.custom_minimum_size = Vector2(380, 0)
	add_child(stats_notice)

# The two export status labels share the same style.
func _make_status_label() -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", _MUTED)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(0, 0)
	return l

func _on_export_colors_pressed() -> void:
	_export_user_file("res://data/team_colors.json", "user://team_colors.json", _export_status_label)

func _on_export_bots_pressed() -> void:
	_export_user_file("res://data/bot_identities.json", "user://bot_identities.json", _bot_export_status_label)

# Copies a bundled res:// data file to its editable user:// counterpart and
# reports the absolute path (via the given status label) so the player can find
# and edit it. Shared by the Team Colors and Bot Roster export buttons.
func _export_user_file(src_path: String, dst_path: String, status_label: Label) -> void:
	var src_file := FileAccess.open(src_path, FileAccess.READ)
	if src_file == null:
		status_label.add_theme_color_override("font_color", Color(0.9, 0.3, 0.3, 1.0))
		status_label.text = "Error: bundled file not found."
		return
	var content: String = src_file.get_as_text()
	src_file.close()
	var existed: bool = FileAccess.file_exists(dst_path)
	var dst_file := FileAccess.open(dst_path, FileAccess.WRITE)
	if dst_file == null:
		status_label.add_theme_color_override("font_color", Color(0.9, 0.3, 0.3, 1.0))
		status_label.text = "Error: could not write to user data folder."
		return
	dst_file.store_string(content)
	dst_file.close()
	var global_path: String = ProjectSettings.globalize_path(dst_path)
	status_label.add_theme_color_override("font_color", _DIM)
	# Both rosters are read once and cached for the process lifetime (the
	# registries' static `_loaded` guard), so an edit only takes effect on the
	# next launch — tell the player so they don't think their changes were lost.
	status_label.text = "%s:\n%s\nEdit it, then restart the game to apply your changes." % [
			"Overwrote" if existed else "Saved", global_path]

# Stored-code form of the language dropdown: "" for "System default" (index 0),
# else the shipped locale's code.
func _selected_locale() -> String:
	if _locale_btn.selected <= 0:
		return ""
	return LocaleManager.SUPPORTED[_locale_btn.selected - 1]["code"]

func read_controls() -> Dictionary:
	return {
		"attack_up": _attack_up_check.button_pressed,
		"self_beacon_mode": _self_beacon_mode_btn.selected,
		"freeplay_goalie_difficulty": _freeplay_goalie_btn.selected,
		"locale": _selected_locale(),
		"share_gameplay_stats": _share_stats_check.button_pressed,
	}

# The language dropdown is deliberately NOT reverted here: Cancel/Defaults leave
# the visible language selection as the player set it, and the pref itself only
# ever changes on Apply. `locale` is absent from OptionsPanel._defaults() for the
# same reason.
func apply_values(v: Dictionary) -> void:
	_attack_up_check.set_pressed_no_signal(v.attack_up)
	_self_beacon_mode_btn.selected = v.self_beacon_mode
	_freeplay_goalie_btn.selected = v.freeplay_goalie_difficulty
	_share_stats_check.set_pressed_no_signal(v.share_gameplay_stats)
