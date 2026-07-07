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

func test_time_until_drop_counts_down_during_prep() -> void:
	sm.begin_faceoff_prep()
	assert_almost_eq(sm.faceoff_prep_time_until_drop(), GameRules.FACEOFF_PREP_DURATION, 0.001,
			"full prep duration remains at the start")
	sm.tick(0.5)
	assert_almost_eq(sm.faceoff_prep_time_until_drop(), GameRules.FACEOFF_PREP_DURATION - 0.5, 0.001)

func test_time_until_drop_includes_opening_extension() -> void:
	sm.begin_faceoff_prep(GameRules.CENTER_ICE_DOT, GameRules.PREGAME_INTRO_DURATION)
	assert_almost_eq(sm.faceoff_prep_time_until_drop(),
			GameRules.FACEOFF_PREP_DURATION + GameRules.PREGAME_INTRO_DURATION, 0.001,
			"opening prep counts the intro window toward the drop")

func test_time_until_drop_zero_outside_prep() -> void:
	assert_eq(sm.faceoff_prep_time_until_drop(), 0.0, "PLAYING has no pending drop")
	sm.begin_faceoff_prep()
	sm.tick(GameRules.FACEOFF_PREP_DURATION + 0.01)  # → FACEOFF
	assert_eq(sm.faceoff_prep_time_until_drop(), 0.0, "no pending drop once the puck is live")

func test_extended_prep_holds_past_normal_duration() -> void:
	sm.begin_faceoff_prep(GameRules.CENTER_ICE_DOT, GameRules.PREGAME_INTRO_DURATION)
	sm.tick(GameRules.FACEOFF_PREP_DURATION + 0.01)
	assert_eq(sm.current_phase, GamePhase.Phase.FACEOFF_PREP,
			"opening prep holds through the intro window")
	sm.tick(GameRules.PREGAME_INTRO_DURATION)
	assert_eq(sm.current_phase, GamePhase.Phase.FACEOFF)

func test_prep_extension_is_one_shot() -> void:
	sm.begin_faceoff_prep(GameRules.CENTER_ICE_DOT, GameRules.PREGAME_INTRO_DURATION)
	sm.tick(GameRules.FACEOFF_PREP_DURATION + GameRules.PREGAME_INTRO_DURATION + 0.01)
	assert_eq(sm.current_phase, GamePhase.Phase.FACEOFF)
	# The next prep (a mid-game stoppage) runs at the normal duration.
	sm.begin_faceoff_prep()
	sm.tick(GameRules.FACEOFF_PREP_DURATION + 0.01)
	assert_eq(sm.current_phase, GamePhase.Phase.FACEOFF,
			"extension must not leak into later preps")

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

func test_faceoff_puck_touch_ends_faceoff_so_goal_counts() -> void:
	# P2-2: a possession-less faceoff play (deflect / one-timer / contested draw)
	# must end the faceoff — otherwise on_goal_scored (PLAYING-gated) voids the goal.
	sm.begin_faceoff_prep()
	sm.tick(GameRules.FACEOFF_PREP_DURATION + 0.01)  # → FACEOFF
	assert_eq(sm.current_phase, GamePhase.Phase.FACEOFF)
	# A goal during FACEOFF would be voided...
	assert_eq(sm.on_goal_scored(1), -1, "goal is voided while still in FACEOFF")
	# ...but a puck touch first makes it live.
	var resumed: bool = sm.on_faceoff_puck_touched()
	assert_true(resumed)
	assert_eq(sm.current_phase, GamePhase.Phase.PLAYING)
	assert_ne(sm.on_goal_scored(1), -1, "goal now counts after the touch ended the faceoff")

func test_faceoff_puck_touch_outside_faceoff_noop() -> void:
	assert_false(sm.on_faceoff_puck_touched())  # still PLAYING
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

# ── Slot reservation (reconnect support) ─────────────────────────────────────

func test_reserved_slot_counts_toward_team_total() -> void:
	# Reserving a slot keeps the team "full" for balance/roster purposes so a
	# dropped player's spot isn't backfilled — the team plays short-handed.
	sm.reserve_slot(0, 1)
	assert_eq(sm.count_players_on_team(0), 1, "reserved slot counts as occupied")
	assert_eq(sm.count_players_on_team(1), 0)

func test_reserved_slot_skipped_by_auto_assign() -> void:
	# Host on one team; reserve slot 0 of the other. A fresh joiner must NOT take
	# the reserved slot — it lands on the next free slot of that team instead.
	var host: Dictionary = sm.register_host(1)
	var other_team: int = 1 - host.team_id
	sm.reserve_slot(other_team, 0)
	# Force the next joiner onto the reserved team by filling slots so balance
	# sends them there; simplest: directly check _first_available_slot skips it.
	var slot: int = sm._first_available_slot(other_team)
	assert_ne(slot, 0, "reserved slot 0 must not be offered to a new joiner")

func test_release_reserved_frees_the_slot() -> void:
	sm.reserve_slot(0, 2)
	assert_true(sm.is_slot_reserved(0, 2))
	sm.release_reserved(0, 2)
	assert_false(sm.is_slot_reserved(0, 2))
	assert_eq(sm.count_players_on_team(0), 0, "released slot no longer counts")

func test_reserve_slot_is_idempotent() -> void:
	sm.reserve_slot(0, 1)
	sm.reserve_slot(0, 1)
	assert_eq(sm.reserved_slots.size(), 1, "re-reserving the same slot is a no-op")

func test_reconnect_into_reserved_slot_round_trip() -> void:
	# A reconnecting peer releases the reservation then re-registers into the same
	# slot — the canonical restore path GameManager drives.
	var host: Dictionary = sm.register_host(1)
	var other_team: int = 1 - host.team_id
	sm.reserve_slot(other_team, 0)
	# Restore: free the hold, register the returning peer into the held slot.
	sm.release_reserved(other_team, 0)
	sm.register_remote_assigned_player(999, 0, other_team)
	assert_true(sm.players.has(999))
	assert_eq(sm.players[999].team_id, other_team)
	assert_eq(sm.players[999].team_slot, 0)
	assert_eq(sm.reserved_slots.size(), 0)

func test_reset_all_clears_reservations() -> void:
	sm.reserve_slot(0, 1)
	sm.reset_all()
	assert_eq(sm.reserved_slots.size(), 0, "a fresh match starts with no held slots")

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

# ── Skater-skater contact also ends a delayed offside ────────────────────────
# Rule 83.3 ends the delay not just on a puck touch but also when an
# offending-team player "forces the defending puck carrier further back" or
# "is about to make physical contact" with them — both linesman judgment
# calls. notify_offside_contact collapses them into one deterministic
# trigger: any contact between the two teams while the delay is active.

func test_offside_contact_whistles_when_offending_team_involved() -> void:
	sm.rule_set = GameRules.RuleSet.NHL
	sm.register_remote_assigned_player(1, 0, 0)    # offside attacker (team 0)
	sm.register_remote_assigned_player(100, 0, 1)  # defender (team 1)
	sm.update_delayed_offside({1: Vector3(0, 1, -10)}, Vector3(0, 0, 0), -1)
	sm.update_delayed_offside({1: Vector3(0, 1, -10)}, Vector3(0, 0, -10), -1)
	assert_eq(sm.delayed_offside_team_id, 0)
	sm.notify_offside_contact(1, 100)  # attacker checks (or is checked by) the defender
	assert_eq(sm.consume_pending_faceoff(), GameStateMachine.FaceoffReason.OFFSIDE)
	assert_eq(sm.delayed_offside_team_id, -1, "contact whistle clears the delayed offside")

func test_offside_contact_direction_does_not_matter() -> void:
	# Same as above but with the peer args swapped — which peer "hit" which
	# doesn't matter, only that the two teams made contact.
	sm.rule_set = GameRules.RuleSet.NHL
	sm.register_remote_assigned_player(1, 0, 0)
	sm.register_remote_assigned_player(100, 0, 1)
	sm.update_delayed_offside({1: Vector3(0, 1, -10)}, Vector3(0, 0, 0), -1)
	sm.update_delayed_offside({1: Vector3(0, 1, -10)}, Vector3(0, 0, -10), -1)
	sm.notify_offside_contact(100, 1)
	assert_eq(sm.consume_pending_faceoff(), GameStateMachine.FaceoffReason.OFFSIDE)

func test_offside_contact_between_teammates_does_not_whistle() -> void:
	sm.rule_set = GameRules.RuleSet.NHL
	sm.register_remote_assigned_player(1, 0, 0)   # offside attacker (team 0)
	sm.register_remote_assigned_player(2, 1, 0)   # teammate (team 0)
	sm.update_delayed_offside({1: Vector3(0, 1, -10)}, Vector3(0, 0, 0), -1)
	sm.update_delayed_offside({1: Vector3(0, 1, -10)}, Vector3(0, 0, -10), -1)
	assert_eq(sm.delayed_offside_team_id, 0)
	sm.notify_offside_contact(1, 2)  # accidental bump between teammates
	assert_eq(sm.consume_pending_faceoff(), GameStateMachine.FaceoffReason.NONE,
			"contact between teammates must never whistle")
	assert_eq(sm.delayed_offside_team_id, 0, "no active delayed offside must be cleared by it either")

func test_offside_contact_without_active_delayed_offside_is_noop() -> void:
	sm.rule_set = GameRules.RuleSet.NHL
	sm.register_remote_assigned_player(1, 0, 0)
	sm.register_remote_assigned_player(100, 0, 1)
	sm.notify_offside_contact(1, 100)
	assert_eq(sm.consume_pending_faceoff(), GameStateMachine.FaceoffReason.NONE)

func test_offside_contact_ignored_outside_nhl() -> void:
	sm.rule_set = GameRules.RuleSet.ARCADE
	sm.register_remote_assigned_player(1, 0, 0)
	sm.register_remote_assigned_player(100, 0, 1)
	sm.notify_offside_contact(1, 100)
	assert_eq(sm.consume_pending_faceoff(), GameStateMachine.FaceoffReason.NONE,
			"ARCADE's offside is a ghost, not a whistle — contact has nothing to end")

# ── Defending-team possession voids the delayed offside ──────────────────────
# Real NHL rule: a delayed off-side is voided not only when the puck fully
# clears the zone, but also the instant the DEFENDING team ESTABLISHES
# possession and control of the puck — even while it's still deep in the
# zone. The previously offside attacker becomes fully onside without ever
# physically tagging up. A mere touch/deflection/blocked shot does NOT
# establish "possession and control" (see test_offside_touch_by_defender_does_not_whistle,
# which only proves a defender's touch doesn't whistle — not that the
# violation is voided); only PossessionTracker's ESTABLISHED signal — the
# same "control" standard used for stat attribution, not a raw pickup — does.

func test_defending_possession_voids_delayed_offside_even_if_attacker_never_tags_up() -> void:
	sm.rule_set = GameRules.RuleSet.NHL
	sm.register_remote_assigned_player(1, 0, 0)  # offside attacker (team 0), stays deep throughout
	sm.update_delayed_offside({1: Vector3(0, 1, -10)}, Vector3(0, 0, 0), -1)
	sm.update_delayed_offside({1: Vector3(0, 1, -10)}, Vector3(0, 0, -10), -1)
	assert_eq(sm.delayed_offside_team_id, 0, "delayed offside active once the puck enters the zone")

	# Team 1 (defending) ESTABLISHES possession, still deep in the zone (not
	# cleared out) — real hockey voids the whole delayed off-side right here.
	sm.notify_possession_established(1, -10.0)
	assert_eq(sm.delayed_offside_team_id, -1,
			"defending team's established possession voids the delayed offside")

	# The still-un-tagged attacker (peer 1) can now legally touch the puck.
	sm.notify_puck_touch(1)
	assert_eq(sm.consume_pending_faceoff(), GameStateMachine.FaceoffReason.NONE,
			"previously offside attacker no longer whistles after the void")

	# Re-running update_delayed_offside with the attacker still parked and the
	# puck still deep confirms the peer itself was cleared, not just the
	# team-level flag — otherwise stale membership would silently re-flag it.
	sm.update_delayed_offside({1: Vector3(0, 1, -10)}, Vector3(0, 0, -10), -1)
	assert_eq(sm.delayed_offside_team_id, -1,
			"cleared peer must not be silently re-flagged while the puck stays in the zone")

func test_own_team_possession_does_not_void_delayed_offside() -> void:
	sm.rule_set = GameRules.RuleSet.NHL
	sm.register_remote_assigned_player(1, 0, 0)  # offside attacker (team 0)
	sm.update_delayed_offside({1: Vector3(0, 1, -10)}, Vector3(0, 0, 0), -1)
	sm.update_delayed_offside({1: Vector3(0, 1, -10)}, Vector3(0, 0, -10), -1)
	assert_eq(sm.delayed_offside_team_id, 0)

	# A team-0 teammate establishing possession (still the offending team)
	# must NOT void it — only the defending team's possession does.
	sm.notify_possession_established(0, -10.0)
	assert_eq(sm.delayed_offside_team_id, 0,
			"the offending team's own possession does not void the delayed offside")

func test_mere_touch_does_not_void_delayed_offside() -> void:
	# A bare puck.carrier assignment (notify_puck_carried) — a scramble touch
	# that hasn't been ESTABLISHED — must NOT void it; only
	# notify_possession_established (fired after PossessionRules.ESTABLISH_HOLD_S
	# or a deliberate play) does. Guards against reverting to the looser
	# "any carry" check this used to run on.
	sm.rule_set = GameRules.RuleSet.NHL
	sm.register_remote_assigned_player(1, 0, 0)  # offside attacker (team 0)
	sm.update_delayed_offside({1: Vector3(0, 1, -10)}, Vector3(0, 0, 0), -1)
	sm.update_delayed_offside({1: Vector3(0, 1, -10)}, Vector3(0, 0, -10), -1)
	assert_eq(sm.delayed_offside_team_id, 0)

	sm.notify_puck_carried(1, -10.0, 0.0)  # team 1 merely carries — not established
	assert_eq(sm.delayed_offside_team_id, 0,
			"a bare carry must not void the delayed offside — only established possession does")

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

# ARCADE's instant ghost is meant to emulate the same NHL delayed-offside
# rule, it just never produces a stoppage — so the same defending-possession
# void applies to it, not just NHL's pending whistle state (see the
# equivalent test_defending_possession_voids_delayed_offside_* tests above).

func test_defending_possession_voids_arcade_ghost_even_without_tagging_up() -> void:
	sm.register_remote_assigned_player(1, 0, 0)  # team 0, offside attacker
	var ghosts: Dictionary = sm.compute_ghost_state(
		{1: Vector3(0, 1, -10)}, -1, Vector3(0, 0, 0))  # team 0 attacking zone, puck in neutral
	assert_true(ghosts[1], "offside ghost applied")

	# Team 1 (defending) ESTABLISHES possession, still deep in the zone (not
	# cleared out) — voids the ghost even though peer 1 never retreated.
	sm.notify_possession_established(1, -10.0)
	var ghosts_after: Dictionary = sm.compute_ghost_state(
		{1: Vector3(0, 1, -10)}, -1, Vector3(0, 0, -10))
	assert_false(ghosts_after[1],
			"defending team's established possession voids the ARCADE ghost outright")

func test_own_team_possession_does_not_void_arcade_ghost() -> void:
	sm.register_remote_assigned_player(1, 0, 0)  # team 0, offside attacker
	sm.compute_ghost_state({1: Vector3(0, 1, -10)}, -1, Vector3(0, 0, 0))

	# A team-0 teammate establishing possession (still the offending team)
	# must NOT void it — only the defending team's possession does.
	sm.notify_possession_established(0, -10.0)
	var ghosts: Dictionary = sm.compute_ghost_state(
		{1: Vector3(0, 1, -10)}, -1, Vector3(0, 0, -10))
	assert_true(ghosts[1], "the offending team's own possession does not void the ghost")

func test_mere_carry_does_not_void_arcade_ghost() -> void:
	# A bare puck.carrier assignment must not void it — only ESTABLISHED
	# possession does (see test_mere_touch_does_not_void_delayed_offside).
	sm.register_remote_assigned_player(1, 0, 0)  # team 0, offside attacker
	sm.compute_ghost_state({1: Vector3(0, 1, -10)}, -1, Vector3(0, 0, 0))
	sm.notify_puck_carried(1, -10.0, 0.0)  # team 1 merely carries — not established
	var ghosts: Dictionary = sm.compute_ghost_state(
		{1: Vector3(0, 1, -10)}, -1, Vector3(0, 0, -10))
	assert_true(ghosts[1], "a bare carry must not void the ghost — only established possession does")

func test_icing_does_not_ghost_the_team() -> void:
	# P2-7: icing is a whistle-and-faceoff rule, NOT a team ghost. Even with an
	# active icing_team_id, compute_ghost_state must not ghost the offending team —
	# in the real game begin_faceoff_prep clears icing_team_id in the same tick, so
	# the old team-wide ghost never applied. This asserts the corrected behavior.
	sm.rule_set = GameRules.RuleSet.NHL
	sm.register_remote_assigned_player(1, 0, 0)  # team 0
	sm.notify_puck_carried(0, 5.0)
	sm.check_icing_for_loose_puck(-30.0)
	assert_eq(sm.icing_team_id, 0, "icing is still detected (drives the whistle + faceoff)")
	var ghosts: Dictionary = sm.compute_ghost_state(
		{1: Vector3(0, 1, 0)},      # position that wouldn't be offside
		-1, Vector3.ZERO)
	assert_false(ghosts[1], "icing does not ghost the offending team")

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

# ── Crease protection (anti-camp / goalie interference) ──────────────────────
# Team 0 defends the +Z goal (crease centered at z = +GOAL_LINE_Z). A point at
# z = 25.5 sits inside that crease; z = 20.0 is in the same end but outside the
# paint. Both are in team 0's own zone, so neither is offside — isolating crease.

func test_crease_camp_ghosts_after_dwell() -> void:
	sm.register_remote_assigned_player(1, 0, 0)  # team 0
	var ghosts: Dictionary = sm.compute_ghost_state(
		{1: Vector3(0, 1, 25.5)}, -1, Vector3.ZERO,
		GameRules.CREASE_DWELL_DURATION)
	assert_true(ghosts[1], "lingering in the crease past the dwell window ghosts the skater")

func test_crease_brief_entry_not_ghosted() -> void:
	sm.register_remote_assigned_player(1, 0, 0)
	var ghosts: Dictionary = sm.compute_ghost_state(
		{1: Vector3(0, 1, 25.5)}, -1, Vector3.ZERO, 0.1)
	assert_false(ghosts[1], "a brief net drive through the crease must not ghost")

func test_crease_dwell_accumulates_across_ticks() -> void:
	sm.register_remote_assigned_player(1, 0, 0)
	var half: float = GameRules.CREASE_DWELL_DURATION * 0.6  # two ticks crosses the threshold
	var first: Dictionary = sm.compute_ghost_state(
		{1: Vector3(0, 1, 25.5)}, -1, Vector3.ZERO, half)
	assert_false(first[1], "below the dwell threshold after one tick")
	var second: Dictionary = sm.compute_ghost_state(
		{1: Vector3(0, 1, 25.5)}, -1, Vector3.ZERO, half)
	assert_true(second[1], "dwell accumulates across ticks and crosses the threshold")

func test_crease_ghost_clears_on_exit() -> void:
	sm.register_remote_assigned_player(1, 0, 0)
	sm.compute_ghost_state(
		{1: Vector3(0, 1, 25.5)}, -1, Vector3.ZERO, GameRules.CREASE_DWELL_DURATION)
	# Skater leaves the paint (still in own end, not offside) — un-ghosts.
	var ghosts: Dictionary = sm.compute_ghost_state(
		{1: Vector3(0, 1, 20.0)}, -1, Vector3.ZERO, 0.1)
	assert_false(ghosts[1], "leaving the crease clears the ghost and resets the dwell")

func test_crease_carrier_is_exempt() -> void:
	sm.register_remote_assigned_player(1, 0, 0)
	var ghosts: Dictionary = sm.compute_ghost_state(
		{1: Vector3(0, 1, 25.5)}, 1, Vector3.ZERO,  # peer 1 carries the puck
		GameRules.CREASE_DWELL_DURATION)
	assert_false(ghosts[1],
			"the puck carrier is exempt — net drives / wraparounds don't draw crease interference")

func test_crease_protection_off_in_off_preset() -> void:
	sm.rule_set = GameRules.RuleSet.OFF
	sm.register_remote_assigned_player(1, 0, 0)
	var ghosts: Dictionary = sm.compute_ghost_state(
		{1: Vector3(0, 1, 25.5)}, -1, Vector3.ZERO, GameRules.CREASE_DWELL_DURATION)
	assert_false(ghosts[1], "OFF disables crease protection")

func test_crease_protection_off_in_nhl() -> void:
	# Not a real NHL rule (goaltender interference is contact-based, and
	# screening without contact is legal) — dropped from the NHL preset.
	sm.rule_set = GameRules.RuleSet.NHL
	sm.register_remote_assigned_player(1, 0, 0)
	var ghosts: Dictionary = sm.compute_ghost_state(
		{1: Vector3(0, 1, 25.5)}, -1, Vector3.ZERO, GameRules.CREASE_DWELL_DURATION)
	assert_false(ghosts[1], "NHL has no dwell-based crease protection")

func test_crease_no_ghost_during_dead_puck_phase() -> void:
	sm.register_remote_assigned_player(1, 0, 0)
	sm.on_goal_scored(1)  # → GOAL_CELEBRATION (not active play — ghosts cleared)
	var ghosts: Dictionary = sm.compute_ghost_state(
		{1: Vector3(0, 1, 25.5)}, -1, Vector3.ZERO, GameRules.CREASE_DWELL_DURATION)
	assert_false(ghosts[1], "no crease ghost while the puck is dead")

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


func test_swap_into_reserved_slot_is_rejected() -> void:
	# P2-5: a slot held for a reconnecting player is invisible to the occupancy
	# scan (no live player there), so try_swap_slot must consult is_slot_reserved —
	# otherwise a teammate swaps in and the reconnect double-books the slot.
	sm.register_remote_assigned_player(1, 0, 0)   # peer 1 on team 0 slot 0
	sm.reserve_slot(0, 1)                          # slot 1 held for a dropped player
	var result: Dictionary = sm.try_swap_slot(1, 0, 1)  # try to swap into the reserved slot
	assert_true(result.is_empty(), "swap into a reserved slot is rejected")
	assert_eq(sm.players[1].team_slot, 0, "peer stays in its original slot")

func test_swap_into_free_slot_still_works() -> void:
	# Regression guard: the reserved check must not block ordinary swaps.
	sm.register_remote_assigned_player(1, 0, 0)
	var result: Dictionary = sm.try_swap_slot(1, 0, 2)  # slot 2 is free + unreserved
	assert_false(result.is_empty(), "swap into a free unreserved slot succeeds")
	assert_eq(sm.players[1].team_slot, 2)
