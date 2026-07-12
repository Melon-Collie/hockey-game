extends GutTest

# PhaseCoordinator — phase-entry dispatch + goal-scoring pipeline.
#
# The coordinator's node-side effects (puck pickup-lock, goalie reset, skater
# teleports, goal VFX, replay cinematic) need live CharacterBody3D/RigidBody3D
# actors, so those are exercised via an empty registry + null puck (the getters
# resolve to null/empty) — what's covered here is the *decision* logic: which
# signals fire per phase, the carrier/own-goal scorer attribution, the
# host-vs-client goal paths, and the client faceoff-prep guard.

var coord: PhaseCoordinator
var sm: GameStateMachine
var registry: PlayerRegistry
var tracker: ShotOnGoalTracker
var teams: Array[Team]
var _drop_calls: int
var _drop_return: int


func before_each() -> void:
	sm = GameStateMachine.new()
	registry = PlayerRegistry.new()
	tracker = ShotOnGoalTracker.new()
	tracker.setup(registry, sm)
	teams = [_make_team(0), _make_team(1)]
	_drop_calls = 0
	_drop_return = -1
	NetworkManager.is_tutorial_mode = false
	coord = PhaseCoordinator.new()
	coord.setup(
			sm, registry, teams,
			Callable(),                        # puck_getter invalid → null puck
			Callable(self, "_empty_goalies"),  # goalie_controllers_getter
			tracker,
			Callable(self, "_fake_drop"),      # puck_drop_requester
			null, null, null,                  # recorder, goal_replay_driver, codec
			null,                              # scene_tree
			false,                             # is_host
			Callable())                        # force_record_goal_frame
	watch_signals(coord)


func _make_team(team_id: int) -> Team:
	var t := Team.new()
	t.team_id = team_id
	return t


func _empty_goalies() -> Array:
	return []


func _fake_drop() -> int:
	_drop_calls += 1
	return _drop_return


func _add_player(peer_id: int, team_id: int, is_local: bool = false) -> PlayerRecord:
	var record := PlayerRecord.new(peer_id, 0, is_local, teams[team_id])
	record.stats = PlayerStats.new()
	registry._players[peer_id] = record
	return record


# ── handle_phase_entered: per-phase signal dispatch ──────────────────────────

func test_phase_entered_playing_emits_phase_changed() -> void:
	sm.current_phase = GamePhase.Phase.PLAYING
	coord.handle_phase_entered()
	assert_signal_emitted_with_parameters(coord, "phase_changed", [GamePhase.Phase.PLAYING])


func test_phase_entered_faceoff_emits_phase_changed() -> void:
	sm.current_phase = GamePhase.Phase.FACEOFF
	coord.handle_phase_entered()
	assert_signal_emitted_with_parameters(coord, "phase_changed", [GamePhase.Phase.FACEOFF])


func test_phase_entered_end_of_period_drops_puck_and_zeroes_clock() -> void:
	sm.current_phase = GamePhase.Phase.END_OF_PERIOD
	coord.handle_phase_entered()
	assert_eq(_drop_calls, 1, "end of period requests a puck drop")
	assert_signal_emitted_with_parameters(coord, "clock_updated", [0.0])
	assert_signal_emitted_with_parameters(coord, "phase_changed", [GamePhase.Phase.END_OF_PERIOD])


func test_phase_entered_game_over_emits_game_over() -> void:
	sm.current_phase = GamePhase.Phase.GAME_OVER
	coord.handle_phase_entered()
	assert_eq(_drop_calls, 1)
	assert_signal_emitted(coord, "game_over")
	assert_signal_emitted_with_parameters(coord, "clock_updated", [0.0])
	assert_signal_emitted_with_parameters(coord, "phase_changed", [GamePhase.Phase.GAME_OVER])


func test_phase_entered_faceoff_prep_syncs_period_clock_and_announces() -> void:
	sm.current_phase = GamePhase.Phase.FACEOFF_PREP
	sm.current_period = 2
	sm.time_remaining = 300.0
	coord.handle_phase_entered()
	assert_signal_emitted_with_parameters(coord, "period_synced", [2])
	assert_signal_emitted_with_parameters(coord, "clock_updated", [300.0])
	assert_signal_emitted(coord, "stats_need_sync")
	assert_signal_emitted(coord, "faceoff_positions_ready")
	assert_signal_emitted(coord, "faceoff_prep_announced")
	assert_signal_emitted_with_parameters(coord, "phase_changed", [GamePhase.Phase.FACEOFF_PREP])


# ── on_pickup: faceoff → playing transition ──────────────────────────────────

func test_on_pickup_during_faceoff_transitions_to_playing() -> void:
	sm.current_phase = GamePhase.Phase.FACEOFF
	coord.on_pickup(10)
	assert_eq(sm.current_phase, GamePhase.Phase.PLAYING)
	assert_signal_emitted_with_parameters(coord, "phase_changed", [GamePhase.Phase.PLAYING])


func test_on_pickup_outside_faceoff_is_noop() -> void:
	sm.current_phase = GamePhase.Phase.PLAYING
	coord.on_pickup(10)
	assert_signal_not_emitted(coord, "phase_changed")


# ── on_goal_scored_into: host goal pipeline ──────────────────────────────────

func test_goal_credits_carrier_and_updates_score() -> void:
	_add_player(10, 0)        # scorer on team 0
	_drop_return = 10         # puck carrier is peer 10
	sm.current_phase = GamePhase.Phase.PLAYING
	coord.on_goal_scored_into(teams[1])  # defending team 1 → scoring team 0
	assert_eq(registry._players[10].stats.goals, 1, "carrier credited the goal")
	assert_eq(sm.scores[0], 1)
	# team_slot 0 → display name "P1"; no prior carriers → no assists.
	assert_signal_emitted_with_parameters(coord, "goal_scored", [teams[0], "P1", "", ""])
	assert_signal_emitted_with_parameters(coord, "score_changed", [1, 0])
	assert_signal_emitted(coord, "goal_broadcast_needed")
	assert_signal_emitted(coord, "stats_need_sync")
	assert_eq(sm.current_phase, GamePhase.Phase.GOAL_CELEBRATION)


func test_own_goal_does_not_credit_the_own_goaler() -> void:
	_add_player(10, 1)        # carrier is on the DEFENDING team → own goal
	_drop_return = 10
	sm.current_phase = GamePhase.Phase.PLAYING
	coord.on_goal_scored_into(teams[1])  # defending 1, scoring 0
	assert_eq(registry._players[10].stats.goals, 0, "own-goaler is not credited")
	assert_eq(sm.scores[0], 1, "goal still counts for the scoring team")
	# No team-0 toucher to redirect credit to → scorer name blank.
	assert_signal_emitted_with_parameters(coord, "goal_scored", [teams[0], "", "", ""])


func test_goal_in_wrong_phase_is_ignored() -> void:
	_add_player(10, 0)
	_drop_return = 10
	sm.current_phase = GamePhase.Phase.FACEOFF  # not PLAYING
	coord.on_goal_scored_into(teams[1])
	assert_eq(_drop_calls, 1, "puck drop fires before the phase gate")
	assert_eq(sm.scores[0], 0, "no goal registered out of PLAYING")
	assert_eq(registry._players[10].stats.goals, 0)
	assert_signal_not_emitted(coord, "goal_scored")
	assert_signal_not_emitted(coord, "phase_changed")


func test_tutorial_mode_short_circuits_goal() -> void:
	NetworkManager.is_tutorial_mode = true
	_add_player(10, 0)
	_drop_return = 10
	sm.current_phase = GamePhase.Phase.PLAYING
	coord.on_goal_scored_into(teams[1])
	NetworkManager.is_tutorial_mode = false
	assert_eq(_drop_calls, 0, "tutorial returns before any side effect")
	assert_eq(sm.scores[0], 0)
	assert_signal_not_emitted(coord, "goal_scored")


# ── on_goal_received: client applies authoritative goal ──────────────────────

func test_on_goal_received_applies_score_and_emits() -> void:
	_add_player(10, 0)
	sm.current_phase = GamePhase.Phase.PLAYING
	coord.on_goal_received(0, 3, 2, "Scorer", "A1", "")
	assert_eq(sm.scores[0], 3)
	assert_eq(sm.scores[1], 2)
	assert_signal_emitted_with_parameters(coord, "goal_scored", [teams[0], "Scorer", "A1", ""])
	assert_signal_emitted_with_parameters(coord, "score_changed", [3, 2])
	assert_signal_emitted_with_parameters(coord, "phase_changed", [GamePhase.Phase.GOAL_CELEBRATION])


# ── on_faceoff_positions: client faceoff-prep entry + guard ──────────────────

func test_on_faceoff_positions_advances_phase_and_announces() -> void:
	sm.current_phase = GamePhase.Phase.GOAL_CELEBRATION
	coord.on_faceoff_positions([])
	assert_eq(sm.current_phase, GamePhase.Phase.FACEOFF_PREP)
	assert_signal_emitted_with_parameters(coord, "phase_changed", [GamePhase.Phase.FACEOFF_PREP])
	assert_signal_emitted(coord, "faceoff_prep_announced")


func test_on_faceoff_positions_when_already_in_faceoff_only_announces() -> void:
	sm.current_phase = GamePhase.Phase.FACEOFF
	coord.on_faceoff_positions([])
	assert_signal_not_emitted(coord, "phase_changed")
	assert_signal_emitted(coord, "faceoff_prep_announced")


# ── Period break → period-start bench intro ──────────────────────────────────

func test_end_of_period_emits_period_break_and_stashes_next_period() -> void:
	sm.current_period = 1
	sm.current_phase = GamePhase.Phase.END_OF_PERIOD
	coord.handle_phase_entered()
	assert_signal_emitted_with_parameters(
			coord, "period_break_started", [GameRules.END_OF_PERIOD_PAUSE])
	assert_eq(coord.period_after_break, 2, "break leads into the next period")


func test_period_break_entry_is_idempotent() -> void:
	sm.current_phase = GamePhase.Phase.END_OF_PERIOD
	coord.on_period_break_entered()
	coord.on_period_break_entered()
	assert_signal_emit_count(coord, "period_break_started", 1,
			"a duplicate phase echo must not restart the skate-off")


func test_prep_after_break_is_period_intro_with_extended_prep() -> void:
	sm.current_phase = GamePhase.Phase.END_OF_PERIOD
	coord.handle_phase_entered()
	sm.begin_faceoff_prep()  # _advance_period's prep entry (0 extra at entry)
	coord.handle_phase_entered()
	assert_true(coord.last_prep_was_period_intro)
	assert_eq(coord.last_prep_preroll, 0.0,
			"period intro rides its own signal, not the skate-in pre-roll")
	assert_almost_eq(sm.faceoff_prep_time_until_drop(),
			GameRules.FACEOFF_PREP_DURATION + GameRules.PERIOD_INTRO_DURATION, 0.001,
			"placement extends the prep window to the period-intro hold")


func test_prep_without_break_is_not_period_intro() -> void:
	sm.begin_faceoff_prep()
	coord.handle_phase_entered()
	assert_false(coord.last_prep_was_period_intro)
	assert_eq(coord.last_prep_preroll, GameRules.FACEOFF_SKATE_PREP_EXTRA,
			"a plain stoppage faceoff keeps the skate-in pre-roll")


func test_period_break_flag_is_consumed_by_one_prep() -> void:
	coord.on_period_break_entered()
	sm.begin_faceoff_prep()
	coord.handle_phase_entered()
	assert_true(coord.last_prep_was_period_intro)
	coord.handle_phase_entered()
	assert_false(coord.last_prep_was_period_intro,
			"a second placement without a new break is a normal faceoff")


func test_pregame_intro_overrides_period_break() -> void:
	var intro_coord := PhaseCoordinator.new()
	intro_coord.setup(
			sm, registry, teams,
			Callable(),
			Callable(self, "_empty_goalies"),
			tracker,
			Callable(self, "_fake_drop"),
			null, null, null,
			null,
			false,
			Callable(),
			Callable(self, "_intro_true"))
	watch_signals(intro_coord)
	intro_coord.on_period_break_entered()
	sm.begin_faceoff_prep()
	intro_coord.handle_phase_entered()
	assert_false(intro_coord.last_prep_was_period_intro,
			"a rematch reset mid-break runs the opening bench intro instead")


func _intro_true() -> bool:
	return true
