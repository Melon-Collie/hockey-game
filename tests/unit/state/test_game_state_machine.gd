extends GutTest

# GameStateMachine — the domain-layer FSM. Tests cover phase transitions,
# scoring, player registry, icing + ghost computation, and remote sync.

var sm: GameStateMachine

func before_each() -> void:
	sm = GameStateMachine.new()

# ── Phase transitions ────────────────────────────────────────────────────────

func test_initial_phase_is_playing() -> void:
	assert_eq(sm.current_phase, GamePhase.Phase.PLAYING)

func test_goal_transitions_to_goal_celebration() -> void:
	var scorer: int = sm.on_goal_scored(1)
	assert_eq(scorer, 0)
	assert_eq(sm.current_phase, GamePhase.Phase.GOAL_CELEBRATION,
			"goals first enter the celebration beat — replay phase comes after")
	assert_eq(sm.scores[0], 1)
	assert_eq(sm.scores[1], 0)

func test_goal_ignored_during_non_playing_phase() -> void:
	sm.on_goal_scored(1)   # → GOAL_CELEBRATION, score 1-0
	var result: int = sm.on_goal_scored(1)
	assert_eq(result, -1, "second goal during GOAL_CELEBRATION should be ignored")
	assert_eq(sm.scores[0], 1, "score unchanged")

func test_goal_phases_expire_to_faceoff_prep() -> void:
	sm.on_goal_scored(1)
	# GOAL_CELEBRATION → GOAL_SCORED → FACEOFF_PREP (two phase transitions)
	var changed_to_replay: bool = sm.tick(GameRules.GOAL_CELEBRATION_DURATION + 0.01)
	assert_true(changed_to_replay)
	assert_eq(sm.current_phase, GamePhase.Phase.GOAL_SCORED)
	var changed_to_faceoff: bool = sm.tick(GameRules.GOAL_PAUSE_DURATION + 0.01)
	assert_true(changed_to_faceoff)
	assert_eq(sm.current_phase, GamePhase.Phase.FACEOFF_PREP)

func test_partial_tick_does_not_transition() -> void:
	sm.on_goal_scored(1)
	var changed: bool = sm.tick(GameRules.GOAL_CELEBRATION_DURATION / 2)
	assert_false(changed)
	assert_eq(sm.current_phase, GamePhase.Phase.GOAL_CELEBRATION)

func test_faceoff_prep_expires_to_faceoff() -> void:
	sm.begin_faceoff_prep()
	sm.tick(GameRules.FACEOFF_PREP_DURATION + 0.01)
	assert_eq(sm.current_phase, GamePhase.Phase.FACEOFF)

func test_puck_pickup_during_faceoff_resumes_playing() -> void:
	sm.begin_faceoff_prep()
	sm.tick(GameRules.FACEOFF_PREP_DURATION + 0.01)  # → FACEOFF
	var resumed: bool = sm.on_faceoff_puck_picked_up()
	assert_true(resumed)
	assert_eq(sm.current_phase, GamePhase.Phase.PLAYING)

func test_puck_pickup_outside_faceoff_noop() -> void:
	var resumed: bool = sm.on_faceoff_puck_picked_up()  # still PLAYING
	assert_false(resumed)
	assert_eq(sm.current_phase, GamePhase.Phase.PLAYING)

func test_faceoff_timeout_resumes_playing() -> void:
	sm.begin_faceoff_prep()
	sm.tick(GameRules.FACEOFF_PREP_DURATION + 0.01)  # → FACEOFF
	sm.tick(GameRules.FACEOFF_TIMEOUT + 0.01)
	assert_eq(sm.current_phase, GamePhase.Phase.PLAYING)

func test_full_cycle_playing_to_playing() -> void:
	sm.on_goal_scored(1)                                    # → GOAL_CELEBRATION
	sm.tick(GameRules.GOAL_CELEBRATION_DURATION + 0.01)    # → GOAL_SCORED
	sm.tick(GameRules.GOAL_PAUSE_DURATION + 0.01)          # → FACEOFF_PREP
	sm.tick(GameRules.FACEOFF_PREP_DURATION + 0.01)        # → FACEOFF
	sm.on_faceoff_puck_picked_up()                          # → PLAYING
	assert_eq(sm.current_phase, GamePhase.Phase.PLAYING)

func test_tick_during_playing_returns_false() -> void:
	assert_false(sm.tick(1.0))
	assert_eq(sm.current_phase, GamePhase.Phase.PLAYING)

# ── Movement locking ─────────────────────────────────────────────────────────

func test_movement_unlocked_during_goal_celebration() -> void:
	# The post-goal celebration beat keeps movement live so players can react;
	# only the GOAL_SCORED replay phase that follows is movement-locked.
	sm.on_goal_scored(1)
	assert_eq(sm.current_phase, GamePhase.Phase.GOAL_CELEBRATION)
	assert_false(sm.is_movement_locked(), "celebration beat allows movement")

func test_movement_locked_during_goal_scored_replay() -> void:
	sm.on_goal_scored(1)                                  # → GOAL_CELEBRATION
	sm.tick(GameRules.GOAL_CELEBRATION_DURATION + 0.01)  # → GOAL_SCORED
	assert_eq(sm.current_phase, GamePhase.Phase.GOAL_SCORED)
	assert_true(sm.is_movement_locked())

func test_movement_unlocked_during_faceoff() -> void:
	sm.begin_faceoff_prep()
	sm.tick(GameRules.FACEOFF_PREP_DURATION + 0.01)
	assert_false(sm.is_movement_locked())

# ── Player registry ──────────────────────────────────────────────────────────

func test_host_registration_takes_team_slot_0() -> void:
	var r: Dictionary = sm.register_host(1)
	assert_eq(r.team_slot, 0)
	assert_true(r.team_id == 0 or r.team_id == 1)

func test_first_connected_peer_fills_opposite_team() -> void:
	# After host claims one team, the first connected peer balances to the other.
	var host: Dictionary = sm.register_host(1)
	var peer: Dictionary = sm.on_player_connected(100)
	assert_ne(peer.team_id, host.team_id, "second player should balance to the other team")
	assert_eq(peer.team_slot, 0, "first slot on the newly-filled team")

func test_third_connection_leaves_teams_within_one_of_each_other() -> void:
	sm.register_host(1)
	sm.on_player_connected(100)
	sm.on_player_connected(200)
	# Third player lands on a tied matchup (1-1), so team is random; the balance
	# invariant is that no team ever trails by more than one.
	var diff: int = absi(sm.count_players_on_team(0) - sm.count_players_on_team(1))
	assert_lte(diff, 1, "teams stay within 1 player of each other")

func test_disconnected_player_removed() -> void:
	sm.register_host(1)
	sm.on_player_connected(100)
	sm.on_player_disconnected(100)
	assert_false(sm.players.has(100))
	assert_true(sm.players.has(1))

# ── Icing ────────────────────────────────────────────────────────────────────
# Icing detection only runs in NHL rule mode; tests force it explicitly.

func test_icing_triggered_by_loose_puck_past_goal_line() -> void:
	sm.rule_set = GameRules.RuleSet.NHL
	sm.notify_puck_carried(0, 5.0)
	sm.check_icing_for_loose_puck(-30.0)
	assert_eq(sm.icing_team_id, 0)

func test_icing_expires_after_timer() -> void:
	sm.rule_set = GameRules.RuleSet.NHL
	sm.notify_puck_carried(0, 5.0)
	sm.check_icing_for_loose_puck(-30.0)
	assert_eq(sm.icing_team_id, 0)
	sm.tick(GameRules.ICING_GHOST_DURATION + 0.01)
	assert_eq(sm.icing_team_id, -1)

func test_icing_cleared_by_opponent_pickup() -> void:
	sm.rule_set = GameRules.RuleSet.NHL
	sm.notify_puck_carried(0, 5.0)
	sm.check_icing_for_loose_puck(-30.0)
	assert_eq(sm.icing_team_id, 0)
	sm.notify_puck_carried(1, -10.0)  # team 1 picks up
	assert_eq(sm.icing_team_id, -1)

func test_icing_not_cleared_by_offending_team_pickup() -> void:
	sm.rule_set = GameRules.RuleSet.NHL
	sm.notify_puck_carried(0, 5.0)
	sm.check_icing_for_loose_puck(-30.0)
	assert_eq(sm.icing_team_id, 0)
	sm.notify_puck_carried(0, -10.0)  # offending team picks up — should NOT clear
	assert_eq(sm.icing_team_id, 0, "icing must not clear when offending team picks up puck")

func test_icing_not_triggered_during_dead_puck_phase() -> void:
	sm.rule_set = GameRules.RuleSet.NHL
	sm.on_goal_scored(1)  # → GOAL_CELEBRATION (still not PLAYING — icing path returns early)
	sm.notify_puck_carried(0, 5.0)
	sm.check_icing_for_loose_puck(-30.0)
	assert_eq(sm.icing_team_id, -1, "icing only detects during PLAYING")

func test_icing_not_triggered_from_attacking_half() -> void:
	sm.rule_set = GameRules.RuleSet.NHL
	sm.notify_puck_carried(0, -5.0)  # already past center
	sm.check_icing_for_loose_puck(-30.0)
	assert_eq(sm.icing_team_id, -1)

func test_arcade_mode_skips_icing_detection() -> void:
	sm.rule_set = GameRules.RuleSet.ARCADE
	sm.notify_puck_carried(0, 5.0)
	sm.check_icing_for_loose_puck(-30.0)
	assert_eq(sm.icing_team_id, -1, "ARCADE must not detect icing")

func test_off_mode_skips_icing_detection() -> void:
	sm.rule_set = GameRules.RuleSet.OFF
	sm.notify_puck_carried(0, 5.0)
	sm.check_icing_for_loose_puck(-30.0)
	assert_eq(sm.icing_team_id, -1, "OFF must not detect icing")

# ── NHL icing → pending faceoff ──────────────────────────────────────────────

func test_icing_sets_pending_faceoff_dot_in_nhl() -> void:
	sm.rule_set = GameRules.RuleSet.NHL
	sm.notify_puck_carried(0, 5.0, 4.0)  # released from +X side
	sm.check_icing_for_loose_puck(-30.0)
	assert_eq(sm.consume_pending_faceoff(), GameStateMachine.FaceoffReason.ICING)
	# Offender (team 0) defends +Z; carrier was on +X side → dot at (+X, +Z).
	assert_eq(sm.pending_faceoff_dot,
			Vector2(GameRules.END_ZONE_FACEOFF_DOT_X, GameRules.ICING_FACEOFF_DOT_Z))

func test_icing_pending_dot_mirrors_carrier_side_team_1() -> void:
	sm.rule_set = GameRules.RuleSet.NHL
	sm.notify_puck_carried(1, -5.0, -4.0)  # team 1 released from -X side
	sm.check_icing_for_loose_puck(30.0)
	assert_eq(sm.consume_pending_faceoff(), GameStateMachine.FaceoffReason.ICING)
	# Team 1 defends -Z; -X side carrier → dot at (-X, -Z).
	assert_eq(sm.pending_faceoff_dot,
			Vector2(-GameRules.END_ZONE_FACEOFF_DOT_X, -GameRules.ICING_FACEOFF_DOT_Z))

func test_consume_pending_faceoff_clears_state() -> void:
	sm.rule_set = GameRules.RuleSet.NHL
	sm.notify_puck_carried(0, 5.0, 4.0)
	sm.check_icing_for_loose_puck(-30.0)
	assert_eq(sm.consume_pending_faceoff(), GameStateMachine.FaceoffReason.ICING)
	assert_eq(sm.consume_pending_faceoff(), GameStateMachine.FaceoffReason.NONE,
			"second consume in the same stoppage must return NONE")

# ── NHL delayed offside ──────────────────────────────────────────────────────

func test_nhl_offside_does_not_ghost_player() -> void:
	sm.rule_set = GameRules.RuleSet.NHL
	sm.register_remote_assigned_player(1, 0, 0)  # team 0
	var ghosts: Dictionary = sm.compute_ghost_state(
		{1: Vector3(0, 1, -10)},  # in attacking zone, puck in neutral
		-1, Vector3(0, 0, 0))
	assert_false(ghosts[1], "NHL must not ghost for offside — delayed system handles it")

func test_arcade_offside_still_ghosts() -> void:
	sm.rule_set = GameRules.RuleSet.ARCADE
	sm.register_remote_assigned_player(1, 0, 0)
	var ghosts: Dictionary = sm.compute_ghost_state(
		{1: Vector3(0, 1, -10)}, -1, Vector3(0, 0, 0))
	assert_true(ghosts[1], "ARCADE keeps the per-player offside ghost")

func test_delayed_offside_idle_when_puck_still_in_neutral() -> void:
	sm.rule_set = GameRules.RuleSet.NHL
	sm.register_remote_assigned_player(1, 0, 0)
	sm.update_delayed_offside(
		{1: Vector3(0, 1, -10)}, Vector3(0, 0, 0), -1)
	assert_eq(sm.delayed_offside_team_id, -1,
			"attacker tracked, but no whistle trigger until puck enters zone")

func test_delayed_offside_activates_when_puck_enters_zone() -> void:
	sm.rule_set = GameRules.RuleSet.NHL
	sm.register_remote_assigned_player(1, 0, 0)
	sm.update_delayed_offside(
		{1: Vector3(0, 1, -10)}, Vector3(0, 0, 0), -1)
	# Puck enters the attacking zone — delayed offside flips on
	sm.update_delayed_offside(
		{1: Vector3(0, 1, -10)}, Vector3(0, 0, -10), -1)
	assert_eq(sm.delayed_offside_team_id, 0)

func test_delayed_offside_clears_when_attacker_tags_up() -> void:
	sm.rule_set = GameRules.RuleSet.NHL
	sm.register_remote_assigned_player(1, 0, 0)
	# Set up: attacker enters zone ahead of puck, then puck follows in.
	sm.update_delayed_offside({1: Vector3(0, 1, -10)}, Vector3(0, 0, 0), -1)
	sm.update_delayed_offside({1: Vector3(0, 1, -10)}, Vector3(0, 0, -10), -1)
	assert_eq(sm.delayed_offside_team_id, 0)
	# Player skates back across the blue line
	sm.update_delayed_offside({1: Vector3(0, 1, 0)}, Vector3(0, 0, -10), -1)
	assert_eq(sm.delayed_offside_team_id, -1, "tag-up clears delayed offside")

func test_delayed_offside_clears_when_defenders_clear_puck() -> void:
	sm.rule_set = GameRules.RuleSet.NHL
	sm.register_remote_assigned_player(1, 0, 0)
	sm.update_delayed_offside({1: Vector3(0, 1, -10)}, Vector3(0, 0, 0), -1)
	sm.update_delayed_offside({1: Vector3(0, 1, -10)}, Vector3(0, 0, -10), -1)
	assert_eq(sm.delayed_offside_team_id, 0)
	# Puck exits the attacking zone (defenders cleared)
	sm.update_delayed_offside({1: Vector3(0, 1, -10)}, Vector3(0, 0, 0), -1)
	assert_eq(sm.delayed_offside_team_id, -1,
			"defenders clearing the zone waves off the delayed offside")

func test_offside_touch_triggers_pending_faceoff() -> void:
	sm.rule_set = GameRules.RuleSet.NHL
	sm.register_remote_assigned_player(1, 0, 0)  # team 0 attacker
	sm.update_delayed_offside({1: Vector3(2, 1, -10)}, Vector3(2, 0, 0), -1)
	sm.update_delayed_offside({1: Vector3(2, 1, -10)}, Vector3(2, 0, -10), -1)
	assert_eq(sm.delayed_offside_team_id, 0)
	# Offending-team touch → whistle
	sm.notify_puck_touch(1)
	assert_eq(sm.consume_pending_faceoff(), GameStateMachine.FaceoffReason.OFFSIDE)
	# Faceoff goes to the NZ dot flanking the -Z blue line (team 0 attacked
	# -Z), on the +X side (puck at x=2).
	assert_eq(sm.pending_faceoff_dot,
			Vector2(GameRules.END_ZONE_FACEOFF_DOT_X, -GameRules.NEUTRAL_ZONE_FACEOFF_DOT_Z))
	assert_eq(sm.delayed_offside_team_id, -1, "whistle clears delayed offside")

func test_offside_touch_by_defender_does_not_whistle() -> void:
	sm.rule_set = GameRules.RuleSet.NHL
	sm.register_remote_assigned_player(1, 0, 0)    # offside attacker (team 0)
	sm.register_remote_assigned_player(100, 0, 1)  # defender (team 1)
	# Attacker enters zone before puck; defender is also in their defensive
	# zone (so they're not flagged offside themselves — different team).
	sm.update_delayed_offside(
		{1: Vector3(0, 1, -10), 100: Vector3(0, 1, -10)},
		Vector3(0, 0, 0), -1)
	sm.update_delayed_offside(
		{1: Vector3(0, 1, -10), 100: Vector3(0, 1, -10)},
		Vector3(0, 0, -10), -1)
	assert_eq(sm.delayed_offside_team_id, 0)
	sm.notify_puck_touch(100)  # defender touches the puck — defenders clearing
	assert_eq(sm.consume_pending_faceoff(), GameStateMachine.FaceoffReason.NONE)

func test_arcade_does_not_track_delayed_offside() -> void:
	sm.rule_set = GameRules.RuleSet.ARCADE
	sm.register_remote_assigned_player(1, 0, 0)
	sm.update_delayed_offside({1: Vector3(0, 1, -10)}, Vector3(0, 0, 0), -1)
	sm.update_delayed_offside({1: Vector3(0, 1, -10)}, Vector3(0, 0, -10), -1)
	assert_eq(sm.delayed_offside_team_id, -1,
			"ARCADE uses per-player ghost only — no delayed offside tracking")

# ── Hybrid icing race ────────────────────────────────────────────────────────

func test_icing_waved_off_when_icing_team_closer() -> void:
	sm.rule_set = GameRules.RuleSet.NHL
	sm.register_remote_assigned_player(1, 0, 0)   # peer 1 → team 0
	sm.register_remote_assigned_player(100, 0, 1) # peer 100 → team 1
	sm.notify_puck_carried(0, 5.0)
	# Dot at z = -ICING_FACEOFF_DOT_Z (for team 0 icing toward -Z).
	# Peer 1 (team 0, icing team) at z = -25 → closer to dot
	# Peer 100 (team 1, defending) at z = 0 → farther from dot
	sm.check_icing_for_loose_puck(-30.0, {1: Vector3(0, 1, -25.0), 100: Vector3(0, 1, 0.0)})
	assert_eq(sm.icing_team_id, -1, "icing team closer → waved off")

func test_icing_confirmed_when_defending_team_closer() -> void:
	sm.rule_set = GameRules.RuleSet.NHL
	sm.register_remote_assigned_player(1, 0, 0)
	sm.register_remote_assigned_player(100, 0, 1)
	sm.notify_puck_carried(0, 5.0)
	# Dot at z = -ICING_FACEOFF_DOT_Z (for team 0 icing toward -Z).
	# Peer 1 at z = 5 is on the wrong side of centre; peer 100 at z = -24 is
	# right by the dot.
	sm.check_icing_for_loose_puck(-30.0, {1: Vector3(0, 1, 5.0), 100: Vector3(0, 1, -24.0)})
	assert_eq(sm.icing_team_id, 0, "defending team closer → icing confirmed")

func test_icing_confirmed_when_defending_team_slightly_closer() -> void:
	sm.rule_set = GameRules.RuleSet.NHL
	sm.register_remote_assigned_player(1, 0, 0)
	sm.register_remote_assigned_player(100, 0, 1)
	sm.notify_puck_carried(0, 5.0)
	# Dot at z = -ICING_FACEOFF_DOT_Z (for team 0 icing toward -Z).
	# Peer 100 at z = -20 sits a hair past the dot; peer 1 at centre is far.
	sm.check_icing_for_loose_puck(-30.0, {1: Vector3(0, 1, 0.0), 100: Vector3(0, 1, -20.0)})
	assert_eq(sm.icing_team_id, 0, "defending team slightly closer → icing confirmed")

func test_icing_waved_off_team1_symmetric() -> void:
	sm.rule_set = GameRules.RuleSet.NHL
	sm.register_remote_assigned_player(1, 0, 0)   # team 0
	sm.register_remote_assigned_player(100, 0, 1) # team 1
	sm.register_remote_assigned_player(200, 1, 0) # team 0
	sm.notify_puck_carried(1, -5.0)
	# Dot at z = +ICING_FACEOFF_DOT_Z (for team 1 icing toward +Z). Peer 100 is
	# close to the dot; peer 1 is back at centre.
	sm.check_icing_for_loose_puck(30.0, {1: Vector3(0, 1, 0.0), 100: Vector3(0, 1, 25.0)})
	assert_eq(sm.icing_team_id, -1, "team 1 icing, waved off — attacker closer")

# ── Ghost computation ────────────────────────────────────────────────────────

func test_ghost_empty_when_no_players() -> void:
	var ghosts: Dictionary = sm.compute_ghost_state({}, -1, Vector3.ZERO)
	assert_eq(ghosts.size(), 0)

func test_offside_skater_ghosted_during_play() -> void:
	sm.register_remote_assigned_player(1, 0, 0)  # team 0
	var ghosts: Dictionary = sm.compute_ghost_state(
		{1: Vector3(0, 1, -10)},  # team 0 attacking zone
		-1, Vector3(0, 0, 0))     # puck in neutral
	assert_true(ghosts[1])

func test_carrier_not_ghosted_by_offside() -> void:
	sm.register_remote_assigned_player(1, 0, 0)
	var ghosts: Dictionary = sm.compute_ghost_state(
		{1: Vector3(0, 1, -10)},
		1,                          # peer 1 is the carrier
		Vector3(0, 0, 0))
	assert_false(ghosts[1])

func test_icing_team_all_ghosted() -> void:
	sm.rule_set = GameRules.RuleSet.NHL
	sm.register_remote_assigned_player(1, 0, 0)  # team 0
	sm.notify_puck_carried(0, 5.0)
	sm.check_icing_for_loose_puck(-30.0)
	var ghosts: Dictionary = sm.compute_ghost_state(
		{1: Vector3(0, 1, 0)},      # position that wouldn't be offside
		-1, Vector3.ZERO)
	assert_true(ghosts[1])

func test_off_mode_disables_offside_ghost() -> void:
	sm.rule_set = GameRules.RuleSet.OFF
	sm.register_remote_assigned_player(1, 0, 0)  # team 0
	# Position that would be offside under ARCADE
	var ghosts: Dictionary = sm.compute_ghost_state(
		{1: Vector3(0, 1, -10)}, -1, Vector3(0, 0, 0))
	assert_false(ghosts[1], "OFF must not ghost for offside")

func test_no_ghosts_during_dead_puck_phase() -> void:
	sm.register_remote_assigned_player(1, 0, 0)
	sm.on_goal_scored(1)  # → GOAL_CELEBRATION (also not PLAYING — ghosts cleared)
	var ghosts: Dictionary = sm.compute_ghost_state(
		{1: Vector3(0, 1, -10)},    # would be offside during play
		-1, Vector3(0, 0, 0))
	assert_false(ghosts[1])

func test_offside_ghost_persists_after_puck_enters_zone() -> void:
	sm.register_remote_assigned_player(1, 0, 0)  # team 0
	# Player in zone before puck — ghosted
	sm.compute_ghost_state({1: Vector3(0, 1, -10)}, -1, Vector3(0, 0, 0))
	# Puck now also in zone — ghost must persist until player tags up
	var ghosts: Dictionary = sm.compute_ghost_state(
		{1: Vector3(0, 1, -10)}, -1, Vector3(0, 0, -10))
	assert_true(ghosts[1], "offside ghost must persist after puck enters zone")

func test_offside_cleared_by_tagging_up() -> void:
	sm.register_remote_assigned_player(1, 0, 0)  # team 0
	# Ghost the player
	sm.compute_ghost_state({1: Vector3(0, 1, -10)}, -1, Vector3(0, 0, 0))
	# Player retreats past blue line
	var ghosts: Dictionary = sm.compute_ghost_state(
		{1: Vector3(0, 1, 0)}, -1, Vector3(0, 0, 0))
	assert_false(ghosts[1], "offside ghost must clear once player tags up at blue line")

# ── Reset ────────────────────────────────────────────────────────────────────

func test_reset_scores_zeros_both_teams() -> void:
	sm.on_goal_scored(1)   # score 1-0
	sm.reset_scores()
	assert_eq(sm.scores[0], 0)
	assert_eq(sm.scores[1], 0)

func test_begin_faceoff_prep_clears_icing() -> void:
	sm.rule_set = GameRules.RuleSet.NHL
	sm.notify_puck_carried(0, 5.0)
	sm.check_icing_for_loose_puck(-30.0)
	assert_eq(sm.icing_team_id, 0)
	sm.begin_faceoff_prep()
	assert_eq(sm.icing_team_id, -1)
	assert_eq(sm.current_phase, GamePhase.Phase.FACEOFF_PREP)

# ── Remote state application ────────────────────────────────────────────────

func test_apply_remote_state_updates_scores_and_phase() -> void:
	var changed: bool = sm.apply_remote_state(3, 2, GamePhase.Phase.FACEOFF, 1, 200.0)
	assert_true(changed)
	assert_eq(sm.scores[0], 3)
	assert_eq(sm.scores[1], 2)
	assert_eq(sm.current_phase, GamePhase.Phase.FACEOFF)

func test_apply_remote_state_returns_false_if_phase_unchanged() -> void:
	sm.apply_remote_state(0, 0, GamePhase.Phase.PLAYING, 1, 240.0)
	var changed: bool = sm.apply_remote_state(1, 0, GamePhase.Phase.PLAYING, 1, 239.0)
	assert_false(changed, "same phase even though scores changed")

func test_apply_remote_goal_sets_phase_and_scores() -> void:
	sm.apply_remote_goal(0, 1, 0)
	assert_eq(sm.scores[0], 1)
	assert_eq(sm.last_scoring_team_id, 0)
	# Clients enter GOAL_CELEBRATION on the goal RPC; host's WS will later
	# carry them on to GOAL_SCORED when the replay should start.
	assert_eq(sm.current_phase, GamePhase.Phase.GOAL_CELEBRATION)

func test_apply_remote_faceoff_prep_advances_from_celebration() -> void:
	sm.apply_remote_goal(0, 1, 0)  # client sits in GOAL_CELEBRATION during replay
	var changed: bool = sm.apply_remote_faceoff_prep()
	assert_true(changed)
	assert_eq(sm.current_phase, GamePhase.Phase.FACEOFF_PREP)

func test_apply_remote_faceoff_prep_noop_when_already_in_prep() -> void:
	sm.apply_remote_faceoff_prep()
	var changed: bool = sm.apply_remote_faceoff_prep()
	assert_false(changed)
	assert_eq(sm.current_phase, GamePhase.Phase.FACEOFF_PREP)

func test_apply_remote_faceoff_prep_does_not_regress_from_faceoff() -> void:
	# A very-late reliable faceoff RPC must not pull a client that WS already
	# advanced to FACEOFF back into the prep countdown.
	sm.apply_remote_state(0, 0, GamePhase.Phase.FACEOFF, 1, 200.0)
	var changed: bool = sm.apply_remote_faceoff_prep()
	assert_false(changed)
	assert_eq(sm.current_phase, GamePhase.Phase.FACEOFF)

# ── Faceoff positions ───────────────────────────────────────────────────────

func test_faceoff_positions_per_player_slot() -> void:
	var host_assignment: Dictionary = sm.register_host(1)
	var peer_assignment: Dictionary = sm.on_player_connected(100)
	var positions: Dictionary = sm.get_faceoff_positions()
	assert_eq(positions.size(), 2)
	assert_eq(positions[1],
			PlayerRules.faceoff_position(host_assignment.team_id, host_assignment.team_slot))
	assert_eq(positions[100],
			PlayerRules.faceoff_position(peer_assignment.team_id, peer_assignment.team_slot))

func test_active_faceoff_dot_defaults_to_center() -> void:
	assert_eq(sm.active_faceoff_dot, GameRules.CENTER_ICE_DOT)

func test_begin_faceoff_prep_stores_dot() -> void:
	var dot := Vector2(6.5, -22.1)
	sm.begin_faceoff_prep(dot)
	assert_eq(sm.active_faceoff_dot, dot)

func test_advance_post_goal_resets_dot_to_center() -> void:
	sm.active_faceoff_dot = Vector2(6.5, 22.1)
	sm.on_goal_scored(1)                                  # → GOAL_CELEBRATION
	sm.tick(GameRules.GOAL_CELEBRATION_DURATION + 0.01)  # → GOAL_SCORED
	sm.advance_post_goal()                                # → FACEOFF_PREP
	assert_eq(sm.active_faceoff_dot, GameRules.CENTER_ICE_DOT)

func test_period_advance_resets_dot_to_center() -> void:
	sm.active_faceoff_dot = Vector2(-6.5, 22.1)
	sm.tick(GameRules.PERIOD_DURATION + 0.01)        # → END_OF_PERIOD
	sm.tick(GameRules.END_OF_PERIOD_PAUSE + 0.01)    # → FACEOFF_PREP
	assert_eq(sm.active_faceoff_dot, GameRules.CENTER_ICE_DOT)

func test_get_faceoff_positions_uses_active_dot() -> void:
	sm.register_host(1)
	var dot := Vector2(6.5, 22.1)
	sm.begin_faceoff_prep(dot)
	var positions: Dictionary = sm.get_faceoff_positions()
	var slot: Dictionary = sm.players[1]
	assert_eq(positions[1],
			PlayerRules.faceoff_position(slot.team_id, slot.team_slot, dot))

# ── Period / clock ───────────────────────────────────────────────────────────

func test_period_clock_expires_to_end_of_period() -> void:
	var changed: bool = sm.tick(GameRules.PERIOD_DURATION + 0.01)
	assert_true(changed)
	assert_eq(sm.current_phase, GamePhase.Phase.END_OF_PERIOD)
	assert_eq(sm.current_period, 1, "period should not have advanced yet")
	assert_eq(sm.time_remaining, 0.0)

func test_period_clock_expires_on_last_period_to_game_over() -> void:
	sm.current_period = GameRules.NUM_PERIODS
	sm.on_goal_scored(1)  # make score 1-0 so it's not tied
	sm.current_phase = GamePhase.Phase.PLAYING
	sm.time_remaining = GameRules.PERIOD_DURATION
	sm.tick(GameRules.PERIOD_DURATION + 0.01)
	assert_eq(sm.current_phase, GamePhase.Phase.GAME_OVER)

func test_period_clock_expires_on_last_period_tied_goes_to_ot() -> void:
	sm.current_period = GameRules.NUM_PERIODS
	sm.tick(GameRules.PERIOD_DURATION + 0.01)
	assert_eq(sm.current_phase, GamePhase.Phase.END_OF_PERIOD if GameRules.OT_ENABLED else GamePhase.Phase.GAME_OVER)

func test_advance_period_increments_period_and_resets_clock() -> void:
	# Expire current period → END_OF_PERIOD
	sm.tick(GameRules.PERIOD_DURATION + 0.01)
	assert_eq(sm.current_phase, GamePhase.Phase.END_OF_PERIOD)
	# Wait out the end-of-period pause → FACEOFF_PREP (period 2)
	sm.tick(GameRules.END_OF_PERIOD_PAUSE + 0.01)
	assert_eq(sm.current_phase, GamePhase.Phase.FACEOFF_PREP)
	assert_eq(sm.current_period, 2)
	assert_eq(sm.time_remaining, GameRules.PERIOD_DURATION)

func test_game_over_locks_phase_permanently() -> void:
	sm.current_period = GameRules.NUM_PERIODS
	sm.on_goal_scored(1)  # make score 1-0 so it ends rather than going to OT
	sm.current_phase = GamePhase.Phase.PLAYING
	sm.time_remaining = GameRules.PERIOD_DURATION
	sm.tick(GameRules.PERIOD_DURATION + 0.01)
	assert_eq(sm.current_phase, GamePhase.Phase.GAME_OVER)
	var changed: bool = sm.tick(999.0)
	assert_false(changed, "GAME_OVER should not tick out")
	assert_eq(sm.current_phase, GamePhase.Phase.GAME_OVER)

func test_reset_all_zeros_scores_and_resets_period() -> void:
	sm.on_goal_scored(1)   # score 1-0
	sm.current_period = 2
	sm.time_remaining = 60.0
	sm.reset_all()
	assert_eq(sm.scores[0], 0)
	assert_eq(sm.scores[1], 0)
	assert_eq(sm.current_period, 1)
	assert_eq(sm.time_remaining, GameRules.PERIOD_DURATION)

func test_clock_does_not_tick_during_dead_puck_phase() -> void:
	sm.on_goal_scored(1)  # → GOAL_CELEBRATION
	var time_before: float = sm.time_remaining
	# Tick through GOAL_CELEBRATION (one transition per tick — leftover delta is
	# discarded by _set_phase, so we need separate ticks per phase to drain
	# the goal-pause window).
	sm.tick(GameRules.GOAL_CELEBRATION_DURATION + 0.01)  # → GOAL_SCORED
	sm.tick(GameRules.GOAL_PAUSE_DURATION + 0.01)        # → FACEOFF_PREP
	assert_eq(sm.time_remaining, time_before, "clock must not tick during dead-puck phases")
