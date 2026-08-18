extends GutTest

# PlayerPrefs keyboard/mouse rebinds.
# -----------------------------------
# Three tables have to agree for a rebind to survive a restart, and they are
# maintained by hand: the Options grid's row list, REBINDABLE_ACTIONS (which
# save/_load/the defaults snapshot all iterate), and the project InputMap.
# apply_bindings() walks the `bindings` dictionary instead of the constant, so a
# missing entry in REBINDABLE_ACTIONS still applies for the session and is only
# dropped on exit — silent by construction, and how smart_ping went unpersisted.
# These tests pin the agreement rather than any one action.
#
# PlayerPrefs is the autoload (extends Node, no class_name). We instantiate the
# script directly and never add it to the tree, so _ready() never fires and the
# disk read is ours to drive.

const PlayerPrefsScript = preload("res://Scripts/game/player_prefs.gd")
const ControlsTabScript = preload("res://Scripts/ui/options/controls_tab.gd")

const TEST_CONFIG: String = "user://test_player_prefs_bindings.cfg"

# save()/_load() resolve the config path through _get_save_path(), so overriding
# it round-trips the real persistence code without touching the player's own
# user://preferences.cfg — GUT shares the editor's user:// directory. The literal
# repeats TEST_CONFIG because an inner class cannot see the outer script's consts.
class RedirectedPrefs extends PlayerPrefsScript:
	func _get_save_path() -> String:
		return "user://test_player_prefs_bindings.cfg"


var _saved_input_map: Dictionary = {}


func before_each() -> void:
	# _load() ends in apply_bindings(), which rewrites the live InputMap. Snapshot
	# every rebindable action so a round-trip can't leak a bind into later tests.
	_saved_input_map.clear()
	var touched: Array[String] = []
	for action: String in PlayerPrefsScript.REBINDABLE_ACTIONS:
		touched.append(action)
	# The grid too, not just the constant: the tests below deliberately bind
	# actions the constant may have drifted away from, and those still land in
	# the InputMap via apply_bindings().
	for row: Dictionary in ControlsTabScript._REBINDABLE_ACTIONS:
		touched.append(String(row["action"]))
	for action: String in touched:
		if InputMap.has_action(action):
			_saved_input_map[action] = InputMap.action_get_events(action)


func after_each() -> void:
	for action: String in _saved_input_map:
		InputMap.action_erase_events(action)
		for ev: InputEvent in _saved_input_map[action]:
			InputMap.action_add_event(action, ev)
	DirAccess.remove_absolute(TEST_CONFIG)


func _fresh() -> Node:
	return autofree(RedirectedPrefs.new())


func test_options_rows_mirror_the_rebindable_actions() -> void:
	# The drift guard. A row present here but absent from REBINDABLE_ACTIONS
	# rebinds for the session and is silently lost on exit.
	var rows: Array[String] = []
	for row: Dictionary in ControlsTabScript._REBINDABLE_ACTIONS:
		rows.append(String(row["action"]))
	var expected: Array[String] = []
	for action: String in PlayerPrefsScript.REBINDABLE_ACTIONS:
		expected.append(action)
	rows.sort()
	expected.sort()
	assert_eq(rows, expected, "Options rebind rows drifted from REBINDABLE_ACTIONS")


func test_every_rebindable_action_exists_in_the_input_map() -> void:
	# The defaults snapshot and the post-load default fill both read the InputMap,
	# so an action missing there has no default to reset to.
	for action: String in PlayerPrefsScript.REBINDABLE_ACTIONS:
		assert_true(
			InputMap.has_action(action),
			"'%s' is rebindable but has no InputMap action" % action
		)


func test_every_rebind_offered_by_the_options_grid_survives_a_save_and_load() -> void:
	# The end-to-end contract, and the one that would have caught smart_ping:
	# driven off the Options grid rather than REBINDABLE_ACTIONS, so an action the
	# UI offers but the persistence loops skip fails here instead of shipping. Run
	# over the whole grid — a per-action test only ever catches the action it names.
	var writer: Node = _fresh()
	var written: Dictionary = {}
	var code: int = KEY_F1
	for row: Dictionary in ControlsTabScript._REBINDABLE_ACTIONS:
		var action: String = String(row["action"])
		writer.bindings[action] = {"type": "key", "physical_keycode": code}
		written[action] = code
		code += 1
	writer.save()

	var reader: Node = _fresh()
	reader._load()
	for action: String in written:
		var got: Dictionary = reader.bindings.get(action, {})
		assert_eq(
			int(got.get("physical_keycode", -1)),
			int(written[action]),
			"'%s' is rebindable in Options but did not survive save + load" % action
		)


func test_a_mouse_rebind_survives_a_save_and_load() -> void:
	# The other binding type: save() branches on it, and elevation_up/_down ship
	# bound to mouse buttons.
	var writer: Node = _fresh()
	writer.bindings["shoot"] = {"type": "mouse", "button_index": MOUSE_BUTTON_MIDDLE}
	writer.save()

	var reader: Node = _fresh()
	reader._load()
	var got: Dictionary = reader.bindings.get("shoot", {})
	assert_eq(String(got.get("type", "")), "mouse", "shoot lost its mouse binding type")
	assert_eq(int(got.get("button_index", -1)), int(MOUSE_BUTTON_MIDDLE))


func test_load_snapshots_a_default_for_every_action_the_grid_offers() -> void:
	# Reset to Defaults hands default_bindings to the Options tab; an action
	# missing from the snapshot is dropped from _pending_bindings rather than
	# reset, and apply_bindings() never erases a key that isn't there — so the
	# custom bind stays in force while its row reads as unbound. Driven off the
	# grid for the same reason as the round-trip above.
	var prefs: Node = _fresh()
	prefs._load()
	for row: Dictionary in ControlsTabScript._REBINDABLE_ACTIONS:
		var action: String = String(row["action"])
		assert_true(
			prefs.default_bindings.has(action),
			"Reset to Defaults has no default for '%s'" % action
		)
