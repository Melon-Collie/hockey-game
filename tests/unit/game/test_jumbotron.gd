extends GutTest

# Jumbotron actor — the invariants that keep it invisible to gameplay and
# cheap: every visual part on the dedicated render layer, GameCamera masking
# that layer out, the screen viewport never in an every-frame update mode,
# and the mode selection reacting to game signals (attract until the first
# one, lobby lock winning over everything).


func _make() -> Jumbotron:
	var jumbo: Jumbotron = Jumbotron.new()
	add_child_autofree(jumbo)
	return jumbo


func test_all_visuals_on_jumbotron_layer() -> void:
	var jumbo: Jumbotron = _make()
	var visual_count: int = 0
	var stack: Array[Node] = [jumbo]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		stack.append_array(node.get_children())
		if node is VisualInstance3D:
			visual_count += 1
			assert_eq((node as VisualInstance3D).layers, Jumbotron.RENDER_LAYER_MASK,
					"%s must render only on the jumbotron layer" % node.name)
	# Housing + column + 2 bands + 4 screens.
	assert_eq(visual_count, 8, "unexpected visual part count")


func test_game_camera_masks_jumbotron_layer() -> void:
	var cam: GameCamera = GameCamera.new()
	add_child_autofree(cam)
	assert_eq(cam.cull_mask & Jumbotron.RENDER_LAYER_MASK, 0,
			"gameplay camera must never render the jumbotron layer")


func test_pov_camera_masks_jumbotron_layer() -> void:
	# The spectator POV cam reproduces the top-down gameplay framing, so the
	# center-hung board would sit between it and the play exactly like the
	# gameplay camera — it must mask the layer the same way.
	var cam: PovCamera = PovCamera.new()
	add_child_autofree(cam)
	assert_eq(cam.cull_mask & Jumbotron.RENDER_LAYER_MASK, 0,
			"POV camera must never render the jumbotron layer")


func test_screen_viewport_never_updates_every_frame() -> void:
	var jumbo: Jumbotron = _make()
	var viewport: SubViewport = jumbo.find_child("ScreenViewport", false, false)
	assert_not_null(viewport)
	assert_true(viewport.disable_3d, "screen is a 2D UI; 3D must be off")
	assert_ne(viewport.render_target_update_mode, SubViewport.UPDATE_ALWAYS,
			"screen must re-render on content changes only")


func test_attract_until_first_game_signal() -> void:
	var jumbo: Jumbotron = _make()
	assert_eq(jumbo.current_mode(), JumbotronRules.Mode.ATTRACT)
	jumbo._on_clock_updated(240.0)
	assert_eq(jumbo.current_mode(), JumbotronRules.Mode.LIVE)


func test_phase_drives_mode() -> void:
	var jumbo: Jumbotron = _make()
	jumbo._on_phase_changed(GamePhase.Phase.GOAL_CELEBRATION)
	assert_eq(jumbo.current_mode(), JumbotronRules.Mode.GOAL)
	jumbo._on_phase_changed(GamePhase.Phase.END_OF_PERIOD)
	assert_eq(jumbo.current_mode(), JumbotronRules.Mode.BREAK)
	jumbo._on_phase_changed(GamePhase.Phase.GAME_OVER)
	assert_eq(jumbo.current_mode(), JumbotronRules.Mode.FINAL)
	jumbo._on_phase_changed(GamePhase.Phase.PLAYING)
	assert_eq(jumbo.current_mode(), JumbotronRules.Mode.LIVE)


func test_lobby_attract_lock_wins() -> void:
	var jumbo: Jumbotron = _make()
	jumbo.lock_attract()
	jumbo._on_phase_changed(GamePhase.Phase.PLAYING)
	jumbo._on_score_changed(2, 1)
	assert_eq(jumbo.current_mode(), JumbotronRules.Mode.ATTRACT,
			"the lobby backdrop's lock must win over stray game signals")


func test_replay_feed_drives_board() -> void:
	# The offline ReplayViewer pushes recorded game state instead of live
	# signals — the push must flip the board off attract and land the score /
	# clock / period / phase-selected page in one pass.
	var jumbo: Jumbotron = _make()
	assert_eq(jumbo.current_mode(), JumbotronRules.Mode.ATTRACT)
	jumbo.apply_replay_game_state({
		"score0": 3, "score1": 2, "phase": GamePhase.Phase.PLAYING,
		"period": 2, "time_remaining": 95.0,
	})
	assert_eq(jumbo.current_mode(), JumbotronRules.Mode.LIVE)
	assert_eq(jumbo._live_score_home.text, "3")
	assert_eq(jumbo._live_score_away.text, "2")
	assert_eq(jumbo._live_clock.text, "1:35")
	assert_eq(jumbo._live_period.text, "2ND")
	jumbo.apply_replay_game_state({
		"score0": 3, "score1": 3, "phase": GamePhase.Phase.GOAL_CELEBRATION,
		"period": 2, "time_remaining": 80.0,
	})
	assert_eq(jumbo.current_mode(), JumbotronRules.Mode.GOAL)


func test_replay_goal_event_fills_goal_page() -> void:
	var jumbo: Jumbotron = _make()
	var home: Color = Color(0.9, 0.1, 0.1)
	var away: Color = Color(0.1, 0.2, 0.9)
	jumbo.set_team_colors(home, Color.WHITE, away, Color.WHITE)
	jumbo.show_goal("Replay Scorer", 1)
	assert_eq(jumbo._goal_color, away)
	assert_eq(jumbo._goal_scorer_lbl.text, "Replay Scorer")


func test_goal_flash_uses_scoring_team_color() -> void:
	var jumbo: Jumbotron = _make()
	var home: Color = Color(0.9, 0.1, 0.1)
	var away: Color = Color(0.1, 0.2, 0.9)
	jumbo.set_team_colors(home, Color.WHITE, away, Color.WHITE)
	var team: Team = Team.new()
	team.team_id = 1
	jumbo._on_goal_scored(team, "Testy McTestface", "", "")
	assert_eq(jumbo._goal_color, away)
	assert_eq(jumbo._goal_scorer_lbl.text, "Testy McTestface")
