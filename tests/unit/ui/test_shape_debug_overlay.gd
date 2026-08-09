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
var _saved_armed: bool = false


func before_each() -> void:
	_saved_tally = GameManager.shape_tally
	_saved_brains = GameManager.team_brains
	_saved_armed = GameManager.shape_tally_armed
	GameManager.shape_tally = AIPossessionShapeTally.new()
	GameManager.shape_tally_armed = false
	_overlay = ShapeDebugOverlay.new()
	add_child_autofree(_overlay)


func after_each() -> void:
	GameManager.shape_tally = _saved_tally
	GameManager.team_brains = _saved_brains
	GameManager.shape_tally_armed = _saved_armed


func _press(keycode: int) -> void:
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.pressed = true
	_overlay._unhandled_input(ev)


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
	t.accumulate(1, AIPossessionState.State.TRANS_DEFENSE, 15.0, true)
	_overlay._refresh()
	var txt: String = _text()
	assert_string_contains(txt, "[table=7]", "laid out as a 7-column table")
	assert_string_contains(txt, "OZONE", "a visited shape is listed")
	assert_string_contains(txt, "75.0%", "team 0 spent 30 of 40 s in OZONE")
	assert_false(txt.contains("BREAKOUT"),
			"an unvisited shape is not rendered as an empty row")
	assert_string_contains(txt, "DZONE suppressed",
			"the coverage-downgrade line is always carried")
	assert_lt(txt.find("DZONE suppressed"), txt.find("[table=7]"),
			"the summary numbers render ABOVE the table — fit_content "
			+ "under-measures a [table], so anything after one can be clipped")


func test_churn_lines_render_above_the_table() -> void:
	_with_brains()
	var t: AIPossessionShapeTally = GameManager.shape_tally
	for _i: int in 3:
		t.accumulate(0, AIPossessionState.State.DZONE, 0.9)
		t.accumulate(0, AIPossessionState.State.BREAKOUT, 0.5)
	_overlay._refresh()
	var txt: String = _text()
	assert_string_contains(txt, "HOME churn",
			"the transition read-out is rendered")
	assert_string_contains(txt, "DZONE\u2192BREAKOUT 3",
			"the oscillating pair is named with its count")
	assert_lt(txt.find("HOME churn"), txt.find("[table=7]"),
			"churn sits above the table so it cannot be clipped")


func test_shapes_sort_by_the_busier_teams_share() -> void:
	_with_brains()
	var t: AIPossessionShapeTally = GameManager.shape_tally
	t.accumulate(0, AIPossessionState.State.NEUTRAL, 1.0)
	t.accumulate(0, AIPossessionState.State.OZONE, 50.0)
	_overlay._refresh()
	var txt: String = _text()
	# Anchored at the table: shape names also appear in the churn lines above
	# it, so a whole-string search measures those instead of the row order.
	var tbl: int = txt.find("[table=7]")
	assert_gt(tbl, -1, "the table is present to search within")
	assert_lt(txt.find("OZONE", tbl), txt.find("NEUTRAL", tbl),
			"the dominant shape's ROW sorts above the marginal one")


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


# ── Arming the host-side sampling ────────────────────────────────────────────
# The tallies tick at 120 Hz per team off the host's physics step, so they stay
# off until somebody asks to measure a match (GameManager.shape_tally_armed).

func test_opening_the_panel_arms_the_sampling() -> void:
	assert_false(GameManager.shape_tally_armed,
			"an unopened overlay leaves the host tick alone")
	_press(KEY_F6)
	assert_true(GameManager.shape_tally_armed,
			"the first F6 press turns the sampling on")


func test_closing_the_panel_leaves_the_sampling_armed() -> void:
	# Deliberate latch, not a mirror of visibility: pausing the sampling mid-run
	# would punch a hole in the denominator and skew every share reported after.
	_press(KEY_F6)
	_press(KEY_F6)
	assert_false(_overlay._showing, "the panel closed")
	assert_true(GameManager.shape_tally_armed,
			"but the tally keeps sampling — a gap would corrupt the shares")


# ── Live breakout episodes ───────────────────────────────────────────────────

func test_renders_the_breakout_outcome_block() -> void:
	_with_brains()
	GameManager.shape_tally.accumulate(0, AIPossessionState.State.DZONE, 5.0)
	var eps := AIBreakoutEpisodeTracker.new()
	var prev: AIBreakoutEpisodeTracker = GameManager.breakout_episodes
	GameManager.breakout_episodes = eps
	var deep: float = GameRules.BLUE_LINE_Z + 6.0
	for _i: int in 20:
		eps.tick(0, GameRules.GOAL_LINE_Z, Vector3(0, 0, deep), 0, 1.0 / 120.0)
	eps.tick(0, GameRules.GOAL_LINE_Z,
			Vector3(0, 0, GameRules.BLUE_LINE_Z - 2.0), 0, 1.0 / 120.0)
	_overlay._refresh()
	var txt: String = _text()
	GameManager.breakout_episodes = prev
	assert_string_contains(txt, "HOME breakouts",
			"the live breakout block is rendered")
	assert_string_contains(txt, "clean-exit 1",
			"and carries the harness's own outcome labels")
	assert_lt(txt.find("HOME breakouts"), txt.find("[table=7]"),
			"above the table, so it cannot be clipped")
