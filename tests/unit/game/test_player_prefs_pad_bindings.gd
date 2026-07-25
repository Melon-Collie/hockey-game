extends GutTest

# PlayerPrefs gamepad button rebinds.
# -----------------------------------
# The pad scheme reads its DISCRETE buttons straight off the controller (not
# through Godot's InputMap), so a JoyButton index is the whole binding and
# PlayerPrefs.pad_button() is the single lookup every read site funnels through:
# LocalInputGatherer._pad_held (gameplay), hud.gd (smart ping), and
# tutorial_manager (glyph prose). These tests pin the three things that break
# silently when the tables drift: full default coverage (pad_button must always
# resolve to a real button), default uniqueness (the scheme has no spare buttons,
# so a duplicate would double-fire two actions off one press), and the Options
# rebind row list mirroring the rebindable set.
#
# PlayerPrefs is the autoload (extends Node, no class_name). We instantiate the
# script directly and never add it to the tree, so _ready()/_load() never fire —
# no disk read, and pad_bindings starts empty exactly like a fresh install
# before the default fill.

const PlayerPrefsScript = preload("res://Scripts/game/player_prefs.gd")
const ControlsTabScript = preload("res://Scripts/ui/options/controls_tab.gd")


func _fresh() -> Node:
	return autofree(PlayerPrefsScript.new())


func test_every_rebindable_pad_action_has_a_default() -> void:
	for action: String in PlayerPrefsScript.PAD_REBINDABLE_ACTIONS:
		assert_true(
			PlayerPrefsScript.PAD_DEFAULT_BUTTONS.has(action),
			"PAD_DEFAULT_BUTTONS is missing a default for '%s'" % action
		)


func test_no_default_button_is_shared_by_two_actions() -> void:
	var seen: Dictionary = {}
	for action: String in PlayerPrefsScript.PAD_REBINDABLE_ACTIONS:
		var button: int = int(PlayerPrefsScript.PAD_DEFAULT_BUTTONS[action])
		assert_false(
			seen.has(button),
			"'%s' and '%s' both default to JoyButton %d" % [seen.get(button, ""), action, button]
		)
		seen[button] = action


func test_pad_button_falls_back_to_the_scheme_default() -> void:
	# pad_bindings is empty until _load()'s default fill; the accessor must still
	# resolve so a pre-fill read never lands on button -1 (never pressed).
	var prefs: Node = _fresh()
	assert_eq(prefs.pad_bindings, {}, "pad_bindings should start empty without _load()")
	for action: String in PlayerPrefsScript.PAD_REBINDABLE_ACTIONS:
		assert_eq(
			prefs.pad_button(action),
			int(PlayerPrefsScript.PAD_DEFAULT_BUTTONS[action]),
			"pad_button('%s') should fall back to its default" % action
		)


func test_pad_button_honors_a_rebind() -> void:
	var prefs: Node = _fresh()
	prefs.pad_bindings["hit"] = JOY_BUTTON_RIGHT_SHOULDER
	assert_eq(prefs.pad_button("hit"), int(JOY_BUTTON_RIGHT_SHOULDER))
	# Untouched actions keep resolving to their defaults.
	assert_eq(prefs.pad_button("brake"), int(PlayerPrefsScript.PAD_DEFAULT_BUTTONS["brake"]))


func test_pad_button_returns_minus_one_for_a_non_pad_action() -> void:
	# The sticks and analog triggers are structural to the scheme and are read
	# directly, never through pad_button; an unknown action must not resolve.
	assert_eq(_fresh().pad_button("shoot"), -1)


func test_options_pad_rows_mirror_the_rebindable_actions() -> void:
	var rows: Array[String] = []
	for row: Dictionary in ControlsTabScript._PAD_REBINDABLE:
		rows.append(String(row["action"]))
	var expected: Array[String] = []
	for action: String in PlayerPrefsScript.PAD_REBINDABLE_ACTIONS:
		expected.append(action)
	rows.sort()
	expected.sort()
	assert_eq(rows, expected, "Options pad rebind rows drifted from PAD_REBINDABLE_ACTIONS")
