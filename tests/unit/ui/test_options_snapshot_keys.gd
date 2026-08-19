extends GutTest

# OptionsPanel._snapshot() records the live PlayerPrefs values when the panel
# opens — the baseline its dirty-compare and its Cancel restore both work
# against. Its keys must be the union of what every tab's read_controls()
# returns, which both files state in prose: "Keys must match the union of every
# tab's read_controls()" and, on the base class, "their union must equal
# OptionsPanel._snapshot()'s keys".
#
# Neither direction fails loudly on its own:
#
#   A key a tab returns but the snapshot omits — the setting is editable, and
#   Cancel silently keeps it. The player backs out of the options screen and the
#   change they were undoing is still applied.
#
#   A key the snapshot holds but no tab returns — the dirty-compare watches a
#   value nothing can change, so the panel can decide it is dirty over a pref
#   edited somewhere else entirely and offer to revert it.
#
# Both are one forgotten line in a tab, and this is a 48-key surface across six
# tabs, so "someone will notice" is not a plan. Parsed from source because the
# tabs are Control subclasses that need a scene to stand up.

const _PANEL: String = "res://Scripts/ui/options_panel.gd"
const _TABS_DIR: String = "res://Scripts/ui/options"


# Keys in the `{ "name": value, ... }` literal a named function returns.
func _keys_returned_by(source: String, func_name: String) -> PackedStringArray:
	var out := PackedStringArray()
	var head: int = source.find("func %s()" % func_name)
	if head < 0:
		return out
	var body: String = source.substr(head)
	var open_brace: int = body.find("{")
	var close_brace: int = body.find("\n\t}")
	if open_brace < 0 or close_brace < 0 or close_brace < open_brace:
		return out
	var re := RegEx.create_from_string('"([a-z_0-9]+)"\\s*:')
	for m: RegExMatch in re.search_all(body.substr(open_brace, close_brace - open_brace)):
		if not out.has(m.get_string(1)):
			out.append(m.get_string(1))
	return out


func _snapshot_keys() -> PackedStringArray:
	return _keys_returned_by(FileAccess.get_file_as_string(_PANEL), "_snapshot")


# Every options tab, discovered rather than listed — a seventh tab is covered the
# moment it exists, which is the case a hand-maintained list would miss.
func _tab_keys() -> Dictionary:
	var out: Dictionary = {}
	var dir: DirAccess = DirAccess.open(_TABS_DIR)
	assert_not_null(dir, "could not open %s" % _TABS_DIR)
	if dir == null:
		return out
	for file: String in dir.get_files():
		if not file.ends_with(".gd"):
			continue
		var keys: PackedStringArray = _keys_returned_by(
				FileAccess.get_file_as_string("%s/%s" % [_TABS_DIR, file]), "read_controls")
		if keys.size() > 0:
			out[file] = keys
	return out


func test_every_tab_key_is_snapshotted() -> void:
	var snap: PackedStringArray = _snapshot_keys()
	for file: String in _tab_keys():
		for key: String in _tab_keys()[file]:
			assert_true(snap.has(key),
					"%s returns `%s` but OptionsPanel._snapshot() does not record it — " % [file, key] +
					"Cancel would silently keep a change to it")


func test_every_snapshotted_key_is_owned_by_a_tab() -> void:
	var owned := PackedStringArray()
	for file: String in _tab_keys():
		for key: String in _tab_keys()[file]:
			if not owned.has(key):
				owned.append(key)
	for key: String in _snapshot_keys():
		assert_true(owned.has(key),
				"OptionsPanel._snapshot() records `%s` but no tab's read_controls() " % key +
				"returns it — the dirty-compare watches a value the panel cannot change")


func test_no_key_is_claimed_by_two_tabs() -> void:
	var seen: Dictionary = {}
	for file: String in _tab_keys():
		for key: String in _tab_keys()[file]:
			assert_false(seen.has(key),
					"`%s` is returned by both %s and %s — apply order then decides "
					% [key, seen.get(key, "?"), file] + "which tab's control wins")
			seen[key] = file


# The parsers are the only moving part; if either stops matching, both assertions
# above would pass over an empty set.
func test_parsers_still_see_both_sides() -> void:
	assert_gt(_snapshot_keys().size(), 30,
			"expected _snapshot() to record many keys — the parser may have broken")
	assert_gt(_tab_keys().size(), 3,
			"expected several options tabs with a read_controls() — parser may have broken")
	assert_true(_snapshot_keys().has("window_mode"),
			"snapshot parser must find `window_mode`")
