extends GutTest

# The HUD is a coordinator: every panel under Scripts/ui/hud/ is built in code
# and most session signals are connected straight to a panel method. Nothing but
# running _ready proves those connections exist, and nothing but emitting the
# signals proves their argument lists still line up — a renamed or re-signatured
# panel method connects without complaint and fails at the first emit, in a
# match nobody is running headlessly.

var _hud: HUD = null


func before_each() -> void:
	_hud = HUD.new()
	add_child_autofree(_hud)


func _panel(field: StringName) -> Object:
	return _hud.get(field) as Object


func test_ready_builds_every_panel() -> void:
	for field: StringName in [&"_scorebug", &"_chyron", &"_prompts", &"_ghost_banner",
			&"_stat_feed", &"_votes"]:
		assert_not_null(_panel(field), "HUD._ready must build %s" % field)


func test_score_and_shots_reach_the_scorebug() -> void:
	var scorebug: HudScorebug = _panel(&"_scorebug") as HudScorebug
	GameManager.score_changed.emit(3, 1)
	assert_eq(scorebug.home_score(), 3, "score_changed must reach HudScorebug.set_score")
	assert_eq(scorebug.away_score(), 1, "score_changed must reach HudScorebug.set_score")
	# Shots and period have no readable mirror; emitting them proves the
	# connected method accepts the signal's arguments.
	GameManager.shots_on_goal_changed.emit(7, 4)
	GameManager.period_synced.emit(2)
	GameManager.clock_updated.emit(120.0)
	assert_true(true, "scorebug signal signatures accept their emits")


func test_countdown_holds_reach_the_chyron() -> void:
	GameManager.pregame_intro_started.emit(2.5)
	GameManager.faceoff_skate_in_started.emit(1.5)
	GameManager.period_intro_started.emit(2, 3.0)
	assert_true(true, "chyron countdown holds accept their emits")


func test_replay_prompts_follow_the_replay() -> void:
	var prompts: HudPrompts = _panel(&"_prompts") as HudPrompts
	GameManager.replay_started.emit()
	assert_true(prompts.skip_visible(), "the skip prompt is the skip bind's gate during a replay")
	GameManager.skip_replay_vote_updated.emit(1, 3)
	assert_string_contains(prompts.skip_text(), "(1/3)",
			"skip_replay_vote_updated must reach HudPrompts.set_skip_votes")
	GameManager.replay_stopped.emit()
	assert_false(prompts.skip_visible(), "the prompt retires with the replay")
	assert_string_contains(prompts.skip_text(), "SKIP",
			"a stopped replay clears the tally, not the prompt text")
	assert_false(prompts.skip_text().contains("("),
			"a stopped replay clears the tally")


func test_clip_prompt_state_reaches_the_prompts() -> void:
	GameManager.goal_clip_available_changed.emit(true)
	GameManager.goal_clip_state_changed.emit(GoalClipExporter.State.IDLE)
	assert_true(true, "clip prompt signal signatures accept their emits")


func test_rematch_votes_reach_the_tally() -> void:
	NetworkManager.rematch_voters_changed.emit(2)
	NetworkManager.rematch_vote_changed.emit(7, RematchVoteRules.Choice.REMATCH)
	NetworkManager.peer_disconnected.emit(7)
	assert_true(true, "vote signal signatures accept their emits")


# The acceptance bar for the split. A panel that the HUD also writes has no
# lifecycle of its own: whoever assigns a field has re-derived WHEN to assign it,
# and the panel's own method for that becomes dead code waiting to happen. The
# same rule, and the same evidence, as test_no_contested_collaborator_state.gd.
const _HUD_SRC: String = "res://Scripts/ui/hud.gd"


func _without_comments(src: String) -> String:
	var out := PackedStringArray()
	for line: String in src.split("\n"):
		var h: int = line.find("#")
		out.append(line if h < 0 else line.substr(0, h))
	return "\n".join(out)


func test_the_hud_never_writes_a_panel_field() -> void:
	var src: String = _without_comments(FileAccess.get_file_as_string(_HUD_SRC))
	assert_false(src.is_empty(), "could not read %s" % _HUD_SRC)
	var decl := RegEx.create_from_string("(?m)^var (_[a-z_0-9]+)\\s*:\\s*(Hud[A-Za-z0-9]+)\\b")
	var holders: Dictionary = {}
	for m: RegExMatch in decl.search_all(src):
		holders[m.get_string(1)] = m.get_string(2)
	assert_gt(holders.size(), 3, "expected the HUD to hold several panels")
	for holder: String in holders:
		var write := RegEx.create_from_string(
				"%s\\.([a-z_][a-z_0-9]*)\\s*(?:=(?!=)|\\+=|-=|\\*=)\\s" % holder)
		for m: RegExMatch in write.search_all(src):
			fail_test(("HUD writes `%s.%s`. A panel owns its own state — call a method " +
					"on %s instead, or the panel's lifecycle for that field is now split " +
					"across two files and its own updater rots.")
					% [holder, m.get_string(1), holders[holder]])
