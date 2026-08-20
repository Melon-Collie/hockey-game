extends GutTest

# Every user-facing string in Scripts/ui/ reaches the player through tr(): a
# KEY,en,es row in locale/translations.csv and tr("KEY") at the display seam
# (Scripts/ui/CLAUDE.md). Nothing checked that, so the surfaces a player looks
# at most during a match — the chyron, the faceoff countdown, the toasts, the
# box score, the lobby slot grid — accumulated English literals while the menus
# around them localized.
#
# This is a ratchet in the shape of test_no_god_class_growth.gd: files that
# still hold untranslated copy are pinned at the count they had, so they cannot
# grow, and every file NOT in the table must stay at zero. When it fires it is
# saying one of three things:
#
#   grew — route the new string through tr(), or bump the entry and say why.
#   shrank — you migrated part of the file; tighten the entry to the new count
#     so the win cannot be re-spent quietly.
#   is now zero — the file graduated; delete its entry.
#
# These are Control subclasses that need a scene to stand up, so the check reads
# the source. A double-quoted literal counts as copy unless:
#
#   * it carries fewer than two letters once %-format specifiers are removed —
#     "%d:%02d", "×", "v%s" and "%dG" are chrome, not sentences;
#   * it is one identifier token containing an underscore — "smart_ping",
#     "font_color", "STAR_FIRST": an action name, a theme property, or a
#     translation key;
#   * it is the argument of a call that takes an engine identifier rather than
#     text (tr, get/has/set, the theme overrides, get_meta, load …), or it sits
#     on a tween_property / tween_method line, where the literals are NodePaths;
#   * it is a dictionary key — subscripted, or followed by ':' in a literal;
#   * it is a res:// or user:// path.
#
# The reading is deliberately blunt: source is all it has. A count carrying a
# false positive is still a valid rung — what the ratchet guarantees is that the
# number cannot rise.

const _UI_ROOT: String = "res://Scripts/ui"
const _SCRIPTS_ROOT: String = "res://Scripts"
const _CATALOGUE: String = "res://locale/translations.csv"

# Developer instrumentation rather than player-facing UI, and deliberately
# outside the catalogue — Scripts/ui/CLAUDE.md says not to "fix" these.
const _DEBUG_SURFACES: Array[String] = [
	"res://Scripts/ui/network_debug_overlay.gd",
	"res://Scripts/ui/shape_debug_overlay.gd",
]

# The backlog, written down and un-growable. Issue #607 covers the build
# screen; the rest of the menu surface is unclaimed.
const _GRANDFATHERED: Dictionary[String, int] = {
	"res://Scripts/ui/boot.gd": 7,
	"res://Scripts/ui/bug_report_dialog.gd": 10,
	"res://Scripts/ui/camera_director.gd": 4,
	"res://Scripts/ui/career_stats_screen.gd": 41,
	"res://Scripts/ui/confirm_dialog.gd": 2,
	"res://Scripts/ui/controller_glyphs.gd": 18,
	"res://Scripts/ui/controller_keyboard.gd": 5,
	"res://Scripts/ui/display_revert_dialog.gd": 3,
	"res://Scripts/ui/drill_hud.gd": 9,
	"res://Scripts/ui/loading_screen.gd": 5,
	"res://Scripts/ui/lobby_arena_backdrop.gd": 1,
	"res://Scripts/ui/lobby_manager.gd": 33,
	"res://Scripts/ui/lobby_settings_panel.gd": 11,
	"res://Scripts/ui/locker_popup.gd": 4,
	"res://Scripts/ui/menu_style.gd": 4,
	"res://Scripts/ui/options/accessibility_tab.gd": 20,
	"res://Scripts/ui/options/audio_tab.gd": 7,
	"res://Scripts/ui/options/camera_tab.gd": 5,
	"res://Scripts/ui/options/controls_tab.gd": 54,
	"res://Scripts/ui/options/gameplay_tab.gd": 23,
	"res://Scripts/ui/options/video_tab.gd": 26,
	"res://Scripts/ui/options_panel.gd": 10,
	"res://Scripts/ui/passing_drill_hud.gd": 9,
	"res://Scripts/ui/pause_menu.gd": 17,
	"res://Scripts/ui/penalty_drill_hud.gd": 8,
	"res://Scripts/ui/ping_marker.gd": 3,
	"res://Scripts/ui/play_popup.gd": 12,
	"res://Scripts/ui/player_settings_popup.gd": 21,
	"res://Scripts/ui/post_game_analytics.gd": 18,
	"res://Scripts/ui/replay_viewer_hud.gd": 13,
	"res://Scripts/ui/shot_accuracy_hud.gd": 9,
	"res://Scripts/ui/side_menu.gd": 19,
	"res://Scripts/ui/swatch_dropdown.gd": 6,
	"res://Scripts/ui/tutorial_hud.gd": 10,
	"res://Scripts/ui/tutorial_wall.gd": 1,
}

var _fmt_re: RegEx = null
var _ident_re: RegEx = null
var _engine_call_re: RegEx = null
var _tween_re: RegEx = null
var _tr_re: RegEx = null


func before_all() -> void:
	_fmt_re = RegEx.create_from_string("%[-+ #0]*[0-9*]*(\\.[0-9*]+)?[a-zA-Z%]")
	_ident_re = RegEx.create_from_string("^[A-Za-z][A-Za-z0-9]*(_[A-Za-z0-9]+)+$")
	_tween_re = RegEx.create_from_string("tween_(property|method)[ \t]*\\(")
	_engine_call_re = RegEx.create_from_string(
		"(^|[^A-Za-z0-9_])(tr|tr_key|get|set|has|erase|load|preload|get_node"
		+ "|find_child|has_node|set_meta|get_meta|has_meta|remove_meta"
		+ "|get_theme_[a-z_]+|add_theme_[a-z_]+_override|remove_theme_[a-z_]+_override"
		+ "|get_setting|set_setting|has_setting|get_value|set_value"
		+ "|begins_with|ends_with|contains|split|rsplit|trim_prefix|trim_suffix"
		+ "|pad_button|play_ui|play_world|is_action_pressed)\\($")
	_tr_re = RegEx.create_from_string("(^|[^A-Za-z0-9_])(tr|tr_key)[ \t]*\\([ \t]*&?\"([^\"]*)\"")


func test_ui_copy_goes_through_the_locale_seam() -> void:
	var scanned: Dictionary[String, bool] = {}
	for path: String in _gd_files(_UI_ROOT):
		if _DEBUG_SURFACES.has(path):
			continue
		scanned[path] = true
		var found: Array[String] = _untranslated_literals(path)
		var pinned: int = _GRANDFATHERED.get(path, 0)
		var note: String = ""
		if found.size() != pinned:
			note = " — %s. Sample: %s" % [_verdict(found.size(), pinned),
					", ".join(found.slice(0, 5))]
		assert_eq(found.size(), pinned,
			"%s: %d untranslated string(s), pinned at %d%s"
			% [path, found.size(), pinned, note])
	for path: String in _GRANDFATHERED:
		assert_true(scanned.has(path),
			("%s is pinned in _GRANDFATHERED but was not scanned — moved, renamed"
			+ " or deleted? Drop the entry.") % path)


func test_the_catalogue_is_three_columns_wide() -> void:
	# keys,en,es. A value carrying an unescaped comma shifts the row, and the
	# Spanish column silently becomes the tail of the English one.
	var rows: PackedStringArray = FileAccess.get_file_as_string(_CATALOGUE).split("\n")
	assert_eq(rows[0].strip_edges(), "keys,en,es", "catalogue header")
	var malformed: Array[String] = []
	for i: int in range(1, rows.size()):
		var row: String = rows[i].strip_edges()
		if row.is_empty() or row.contains("\""):  # a quoted value may hold commas
			continue
		if row.get_slice_count(",") != 3:
			malformed.append(row.get_slice(",", 0))
	assert_true(malformed.is_empty(),
		"rows that are not exactly keys,en,es — quote a value that holds a "
		+ "comma: " + ", ".join(malformed))


func test_every_translation_key_has_a_catalogue_row() -> void:
	var known: Dictionary[String, bool] = _catalogue_keys()
	var missing: Array[String] = []
	for path: String in _gd_files(_SCRIPTS_ROOT):
		for key: String in _tr_keys(path):
			if not known.has(key):
				missing.append("%s → %s" % [path.get_file(), key])
	assert_true(missing.is_empty(),
		"tr() called with a key that has no locale/translations.csv row (the "
		+ "label renders as the raw key): " + ", ".join(missing))


# ── Verdict wording ──────────────────────────────────────────────────────────

func _verdict(found: int, pinned: int) -> String:
	if found > pinned and pinned == 0:
		return "route it through tr() — this file is already migrated"
	if found > pinned:
		return "route the new string through tr(), or bump the entry and say why"
	if found > 0:
		return "it shrank; tighten the entry to %d" % found
	return "the file graduated; delete its entry"


# ── Source scanning ──────────────────────────────────────────────────────────

func _gd_files(root: String) -> Array[String]:
	var out: Array[String] = []
	var pending: Array[String] = [root]
	while not pending.is_empty():
		var dir_path: String = pending.pop_back()
		var dir: DirAccess = DirAccess.open(dir_path)
		if dir == null:
			continue
		dir.list_dir_begin()
		var entry: String = dir.get_next()
		while entry != "":
			var full: String = dir_path.path_join(entry)
			if dir.current_is_dir():
				pending.append(full)
			elif entry.ends_with(".gd"):
				out.append(full)
			entry = dir.get_next()
		dir.list_dir_end()
	out.sort()
	return out


# Literals that read as copy. Line continuations are folded first so a value
# split across two lines is judged as one expression.
func _untranslated_literals(path: String) -> Array[String]:
	var out: Array[String] = []
	var source: String = FileAccess.get_file_as_string(path)
	for line: String in source.replace("\\\n", " ").split("\n"):
		if line.strip_edges().begins_with("#"):
			continue
		var on_tween_line: bool = _tween_re.search(line) != null
		for literal: Dictionary in _string_literals(line):
			var text: String = literal["text"]
			if on_tween_line or text.begins_with("res://") or text.begins_with("user://"):
				continue
			if _letter_count(text) < 2:
				continue
			if _ident_re.search(text) != null:
				continue
			var before: String = line.substr(0, int(literal["col"])).strip_edges(false, true)
			if before.ends_with("&") or before.ends_with("^") or before.ends_with("["):
				continue
			if _engine_call_re.search(before) != null:
				continue
			if line.substr(int(literal["end"])).strip_edges(true, false).begins_with(":"):
				continue
			out.append(text)
	return out


func _tr_keys(path: String) -> Array[String]:
	var out: Array[String] = []
	var source: String = FileAccess.get_file_as_string(path)
	for line: String in source.split("\n"):
		if line.strip_edges().begins_with("#"):
			continue
		for m: RegExMatch in _tr_re.search_all(line):
			out.append(m.get_string(3))
	return out


# Double-quoted literals on one line, as { col, text, end }. Stops at the first
# '#' outside a literal so trailing comments are not scanned.
func _string_literals(line: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var i: int = 0
	var n: int = line.length()
	while i < n:
		if line[i] == "#":
			break
		if line[i] != "\"":
			i += 1
			continue
		var j: int = i + 1
		var body: String = ""
		while j < n:
			if line[j] == "\\":
				# The escaped character's identity never matters here, only that
				# it is one character and not a closing quote.
				body += "?"
				j += 2
				continue
			if line[j] == "\"":
				break
			body += line[j]
			j += 1
		out.append({"col": i, "text": body, "end": j + 1})
		i = j + 1
	return out


func _letter_count(text: String) -> int:
	var stripped: String = _fmt_re.sub(text, "", true)
	var count: int = 0
	for i: int in stripped.length():
		var ch: String = stripped[i]
		if (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z"):
			count += 1
	return count


func _catalogue_keys() -> Dictionary[String, bool]:
	var keys: Dictionary[String, bool] = {}
	var rows: PackedStringArray = FileAccess.get_file_as_string(_CATALOGUE).split("\n")
	for i: int in range(1, rows.size()):
		var row: String = rows[i].strip_edges()
		if row.is_empty():
			continue
		keys[row.get_slice(",", 0)] = true
	return keys
