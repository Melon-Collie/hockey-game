extends GutTest

# ShapeDebugOverlay's render path. The overlay is a spectate-time instrument
# that cannot be exercised headless in a real match, so this drives _refresh()
# through each of its branches against a live GameManager.shape_tally: a
# runtime error in here would only surface mid-session, which is exactly when
# it is most expensive.
#
# The tally is a debug field on the GameManager autoload, so these tests mutate
# it and restore it afterwards rather than injecting a double — the overlay
# reads the autoload directly by design (no setter chain for a dev surface).

var _overlay: ShapeDebugOverlay = null
var _saved_tally: AIPossessionShapeTally = null
var _saved_brains: Array[TeamBrain] = []


func before_each() -> void:
	_saved_tally = GameManager.shape_tally
	_saved_brains = GameManager.team_brains
	GameManager.shape_tally = AIPossessionShapeTally.new()
	_overlay = ShapeDebugOverlay.new()
	add_child_autofree(_overlay)


func after_each() -> void:
	GameManager.shape_tally = _saved_tally
	GameManager.team_brains = _saved_brains


func _text() -> String:
	var rt: RichTextLabel = _overlay.get_child(0).get_child(0) as RichTextLabel
	return rt.text if rt != null else ""


func _with_brains() -> void:
	var brains: Array[TeamBrain] = [TeamBrain.new(0, {}), TeamBrain.new(1, {})]
	GameManager.team_brains = brains


func test_renders_the_no_brains_notice_on_a_client() -> void:
	GameManager.team_brains = []
	_overlay._refresh()
	assert_string_contains(_text(), "No team brains",
			"a peer without bot AI is told so rather than shown empty columns")


func test_renders_the_waiting_notice_before_any_live_play() -> void:
	_with_brains()
	_overlay._refresh()
	assert_string_contains(_text(), "Waiting for live play",
			"an unsampled tally reads as waiting, not as 0% everywhere")


func test_renders_a_populated_table() -> void:
	_with_brains()
	var t: AIPossessionShapeTally = GameManager.shape_tally
	t.accumulate(0, AIPossessionState.State.OZONE, 30.0)
	t.accumulate(0, AIPossessionState.State.NEUTRAL, 10.0)
	t.accumulate(1, AIPossessionState.State.DZONE, 25.0)
	t.accumulate(1, AIPossessionState.State.TRANS_OD, 15.0, true)
	_overlay._refresh()
	var txt: String = _text()
	assert_string_contains(txt, "[table=7]", "laid out as a 7-column table")
	assert_string_contains(txt, "OZONE", "a visited shape is listed")
	assert_string_contains(txt, "75.0%", "team 0 spent 30 of 40 s in OZONE")
	assert_false(txt.contains("BREAKOUT"),
			"an unvisited shape is not rendered as an empty row")
	assert_string_contains(txt, "DZONE suppressed",
			"the coverage-downgrade line is always carried")


func test_shapes_sort_by_the_busier_teams_share() -> void:
	_with_brains()
	var t: AIPossessionShapeTally = GameManager.shape_tally
	t.accumulate(0, AIPossessionState.State.NEUTRAL, 1.0)
	t.accumulate(0, AIPossessionState.State.OZONE, 50.0)
	_overlay._refresh()
	var txt: String = _text()
	assert_lt(txt.find("OZONE"), txt.find("NEUTRAL"),
			"the dominant shape sorts above the marginal one")


func test_a_shape_only_one_team_visited_renders_dashes_for_the_other() -> void:
	_with_brains()
	GameManager.shape_tally.accumulate(0, AIPossessionState.State.FORECHECK, 5.0)
	_overlay._refresh()
	assert_string_contains(_text(), "—",
			"the team that never entered the shape shows a dash, not a fake 0%")


func test_refresh_survives_a_null_tally() -> void:
	# Defensive: the overlay outlives a match teardown that clears the field.
	GameManager.shape_tally = null
	_overlay._refresh()
	assert_string_contains(_text(), "No team brains",
			"a null tally falls through to the notice instead of crashing")
