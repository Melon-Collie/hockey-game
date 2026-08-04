extends GutTest

# ShotOnGoalTracker — pending-shot state machine + assist crediting.
# PlayerRegistry is constructed but its setup() is skipped; we populate
# the `_players` dict directly since only lookup methods are exercised.

var tracker: ShotOnGoalTracker
var registry: PlayerRegistry
var sm: GameStateMachine


func before_each() -> void:
	sm = GameStateMachine.new()
	registry = PlayerRegistry.new()
	tracker = ShotOnGoalTracker.new()
	tracker.setup(registry, sm)


func _add_player(peer_id: int, team_id: int, p_name: String = "P") -> PlayerRecord:
	var team := Team.new()
	team.team_id = team_id
	var record := PlayerRecord.new(peer_id, 0, false, team)
	record.player_name = p_name
	record.stats = PlayerStats.new()
	registry._players[peer_id] = record
	return record


# ── Pickup / carrier tracking ────────────────────────────────────────────────

func test_initial_state_has_no_pending_shot() -> void:
	assert_false(tracker.has_pending_shot())
	assert_eq(tracker.get_shooter_peer_id(), -1)


func test_pickup_records_carrier() -> void:
	_add_player(10, 0)
	tracker.on_pickup(10)
	assert_eq(tracker.find_scorer_on_team(0), 10)


func test_pickup_limits_to_max_recent_carriers() -> void:
	# One team-0 pickup followed by MAX_RECENT_CARRIERS opposing pickups — the
	# team-0 entry rotates out of the bounded history.
	_add_player(10, 0)
	for pid: int in range(20, 20 + ShotOnGoalTracker.MAX_RECENT_CARRIERS):
		_add_player(pid, 1)
	tracker.on_pickup(10)
	for pid: int in range(20, 20 + ShotOnGoalTracker.MAX_RECENT_CARRIERS):
		tracker.on_pickup(pid)
	assert_eq(tracker.find_scorer_on_team(0), -1,
			"10 rotated out of the %d-entry history" % ShotOnGoalTracker.MAX_RECENT_CARRIERS)


func test_pickup_dedupes_consecutive_same_peer() -> void:
	_add_player(10, 0)
	tracker.on_pickup(10)
	tracker.on_pickup(10)  # no-op dedupe
	# Credit assists on a fictitious scorer — should see no double-entry
	_add_player(11, 0, "Scorer")
	tracker.on_pickup(11)
	var assists: Array[String] = tracker.credit_assists(11)
	assert_eq(assists.size(), 1, "only 10 counts as one assist candidate")


# ── Shot timeout ──────────────────────────────────────────────────────────────

func test_shot_started_arms_pending_timer() -> void:
	_add_player(10, 0)
	tracker.on_shot_started(10)
	assert_true(tracker.has_pending_shot())
	assert_eq(tracker.get_shooter_peer_id(), 10)


func test_shot_timeout_clears_pending() -> void:
	_add_player(10, 0)
	tracker.on_shot_started(10)
	tracker.tick(ShotOnGoalTracker.SHOT_ON_GOAL_TIMEOUT + 0.01)
	assert_false(tracker.has_pending_shot())


func test_partial_tick_keeps_pending() -> void:
	_add_player(10, 0)
	tracker.on_shot_started(10)
	tracker.tick(ShotOnGoalTracker.SHOT_ON_GOAL_TIMEOUT / 2.0)
	assert_true(tracker.has_pending_shot())


func test_shot_started_with_invalid_peer_is_noop() -> void:
	tracker.on_shot_started(-1)
	assert_false(tracker.has_pending_shot())


func test_normal_shot_is_not_flagged_one_timer() -> void:
	_add_player(10, 0)
	tracker.on_shot_started(10)
	assert_false(tracker.pending_is_one_timer())


func test_one_timer_flag_set_on_release() -> void:
	_add_player(10, 0)
	tracker.on_shot_started(10, true)
	assert_true(tracker.pending_is_one_timer())


func test_one_timer_flag_cleared_with_pending() -> void:
	_add_player(10, 0)
	tracker.on_shot_started(10, true)
	tracker.clear_pending()
	assert_false(tracker.pending_is_one_timer())
	# A subsequent ordinary shot must not inherit the stale flag.
	tracker.on_shot_started(10)
	assert_false(tracker.pending_is_one_timer())


# ── Goalie save / SOG ────────────────────────────────────────────────────────

func test_goalie_touch_by_defending_team_confirms_sog() -> void:
	var shooter := _add_player(10, 0)  # attacking team
	tracker.on_shot_started(10)
	tracker.on_goalie_touch(1)  # defending team is team 1
	assert_eq(shooter.stats.shots_on_goal, 1)
	assert_eq(sm.team_shots[0], 1)
	assert_eq(sm.team_shots[1], 0)


func test_goalie_touch_own_net_does_not_count() -> void:
	var shooter := _add_player(10, 0)
	tracker.on_shot_started(10)
	tracker.on_goalie_touch(0)  # shooter is on defending team — own-goal attempt
	assert_eq(shooter.stats.shots_on_goal, 0)
	assert_eq(sm.team_shots[0], 0)


func test_goalie_touch_without_pending_is_noop() -> void:
	var shooter := _add_player(10, 0)
	tracker.on_goalie_touch(1)
	assert_eq(shooter.stats.shots_on_goal, 0)


func test_sog_counted_once_per_shot() -> void:
	var shooter := _add_player(10, 0)
	tracker.on_shot_started(10)
	tracker.on_goalie_touch(1)
	tracker.on_goal_confirmed(10)  # same shot registers a goal — should not double-count SOG
	assert_eq(shooter.stats.shots_on_goal, 1)


# ── Rebounds after a save re-arm for a second shot on goal ───────────────────

func test_rebound_reshot_after_save_counts_a_second_sog() -> void:
	# Goalie saves (SOG #1), a teammate bats the loose rebound back on net, the
	# goalie saves again — that's a distinct shot, so a second SOG lands.
	var shooter := _add_player(10, 0)
	var rebounder := _add_player(11, 0)
	tracker.on_shot_started(10)
	tracker.on_goalie_touch(1)          # save #1 → SOG to the shooter
	tracker.on_deflection(11)           # teammate re-shoots the rebound (re-arm)
	tracker.on_goalie_touch(1)          # save #2 → SOG to the rebounder
	assert_eq(shooter.stats.shots_on_goal, 1)
	assert_eq(rebounder.stats.shots_on_goal, 1)
	assert_eq(sm.team_shots[0], 2, "two distinct shots, two SOG")


func test_rebound_tap_in_goal_counts_its_own_sog() -> void:
	var shooter := _add_player(10, 0)
	var rebounder := _add_player(11, 0)
	tracker.on_shot_started(10)
	tracker.on_goalie_touch(1)          # save #1 → SOG to the shooter
	tracker.on_deflection(11)           # teammate taps the rebound (re-arm)
	tracker.on_goal_confirmed(11)       # ...and scores → SOG #2 to the rebounder
	assert_eq(shooter.stats.shots_on_goal, 1)
	assert_eq(rebounder.stats.shots_on_goal, 1)
	assert_eq(sm.team_shots[0], 2)


func test_repeated_save_on_same_rebound_stays_one_sog() -> void:
	# The goalie kicks the same puck twice with no attacking touch between —
	# one shot, one SOG (nothing re-arms it).
	var shooter := _add_player(10, 0)
	tracker.on_shot_started(10)
	tracker.on_goalie_touch(1)
	tracker.on_goalie_touch(1)
	assert_eq(shooter.stats.shots_on_goal, 1)
	assert_eq(sm.team_shots[0], 1)


func test_defender_touch_of_rebound_does_not_rearm() -> void:
	# A defender playing the loose rebound is not an attacking re-shot, so the
	# pending shot is not re-armed and no phantom second SOG lands.
	var shooter := _add_player(10, 0)
	var defender := _add_player(20, 1)
	tracker.on_shot_started(10)
	tracker.on_goalie_touch(1)
	tracker.on_deflection(20)  # opponent — different team, no re-arm
	tracker.on_goalie_touch(1)
	assert_eq(shooter.stats.shots_on_goal, 1)
	assert_eq(defender.stats.shots_on_goal, 0)
	assert_eq(sm.team_shots[0], 1)


func test_original_shooter_gets_an_assist_on_a_rebound_goal() -> void:
	# The shooter's saved shot becomes a teammate's rebound goal — the shooter is
	# the prior toucher in the chain, so they earn the assist.
	var shooter := _add_player(10, 0)
	var rebounder := _add_player(11, 0)
	tracker.on_pickup(10)          # shooter carries, then shoots
	tracker.on_shot_started(10)
	tracker.on_goalie_touch(1)     # saved
	tracker.on_deflection(11)      # teammate buries the rebound
	var assists: Array[String] = tracker.credit_assists(11)
	assert_eq(assists.size(), 1)
	assert_eq(shooter.stats.assists, 1, "the shot that caused the rebound is an assist")
	assert_eq(rebounder.stats.assists, 0)


# ── On-net gating (NHL: only a puck that would go in counts when stopped) ────

func test_goalie_touch_on_off_net_trajectory_is_not_sog() -> void:
	var shooter := _add_player(10, 0)
	tracker.on_shot_started(10)
	tracker.note_trajectory(false)  # wide shot / cross-crease pass
	tracker.on_goalie_touch(1)
	assert_eq(shooter.stats.shots_on_goal, 0)
	assert_eq(sm.team_shots[0], 0)


func test_post_hit_turns_shot_into_miss() -> void:
	var shooter := _add_player(10, 0)
	tracker.on_shot_started(10)
	tracker.on_post_hit()
	tracker.on_goalie_touch(1)  # goalie covers the ricochet
	assert_eq(shooter.stats.shots_on_goal, 0)


func test_goal_after_post_still_counts_sog() -> void:
	var shooter := _add_player(10, 0)
	tracker.on_shot_started(10)
	tracker.on_post_hit()
	tracker.on_goal_confirmed(10)  # bar-down anyway — goals credit unconditionally
	assert_eq(shooter.stats.shots_on_goal, 1)


func test_wide_shot_tipped_on_net_counts_for_tipper() -> void:
	var shooter := _add_player(10, 0)
	var tipper := _add_player(11, 0)
	tracker.on_pickup(10)
	tracker.on_shot_started(10)
	tracker.note_trajectory(false)  # wide off the blade...
	tracker.on_deflection(11)
	tracker.note_trajectory(true)   # ...redirected on net by the tip
	tracker.on_goalie_touch(1)
	assert_eq(tipper.stats.shots_on_goal, 1)
	assert_eq(shooter.stats.shots_on_goal, 0)


func test_note_trajectory_without_pending_shot_is_noop() -> void:
	tracker.note_trajectory(true)
	assert_false(tracker.has_pending_shot())


func test_block_of_off_net_release_is_not_credited() -> void:
	_add_player(10, 0)
	var blocker := _add_player(20, 1)
	tracker.on_shot_started(10)
	tracker.note_trajectory(false)  # errant shot / pass
	assert_false(tracker.on_block(20))
	assert_eq(blocker.stats.shots_blocked, 0)
	assert_true(tracker.has_pending_shot(),
			"intercepting an off-net puck is a takeaway — pending shot untouched")


func test_block_of_an_intended_pass_is_not_credited() -> void:
	# A feed at a teammate in the crease projects straight through the mouth, so
	# on-net geometry alone reads a defender stepping into it as blocking a shot.
	# It's a picked-off pass: a takeaway for the defender, no blocked shot, no
	# Corsi attempt for the passer.
	_add_player(10, 0)
	var blocker := _add_player(20, 1)
	watch_signals(tracker)
	tracker.on_shot_started(10)
	tracker.note_trajectory(true)           # genuinely on net
	tracker.note_release_intent(false)      # but thrown as a pass
	assert_false(tracker.on_block(20))
	assert_eq(blocker.stats.shots_blocked, 0)
	assert_signal_not_emitted(tracker, "shot_resolved")
	assert_true(tracker.has_pending_shot(),
			"a picked-off pass leaves the pending state for on_deflection")


# ── Tip attribution (NHL: a saved teammate tip is the TIPPER's shot) ─────────

func test_saved_teammate_tip_credits_tipper_not_shooter() -> void:
	var shooter := _add_player(10, 0)
	var tipper := _add_player(11, 0)
	tracker.on_pickup(10)
	tracker.on_shot_started(10)
	tracker.on_deflection(11)  # teammate redirects mid-flight
	tracker.on_goalie_touch(1)
	assert_eq(tipper.stats.shots_on_goal, 1, "the tip is the tipper's shot")
	assert_eq(shooter.stats.shots_on_goal, 0)
	assert_eq(sm.team_shots[0], 1)


func test_saved_defender_deflection_stays_shooters_shot() -> void:
	var shooter := _add_player(10, 0)
	var defender := _add_player(20, 1)
	tracker.on_pickup(10)
	tracker.on_shot_started(10)
	# Late graze off a defender (past the block window, so it reaches here as a
	# deflection, not a block) — NHL keeps this the original shooter's shot.
	tracker.tick(ShotOnGoalTracker.BLOCK_WINDOW + 0.1)
	tracker.on_deflection(20)
	tracker.on_goalie_touch(1)
	assert_eq(shooter.stats.shots_on_goal, 1)
	assert_eq(defender.stats.shots_on_goal, 0)


# ── Deflection keeps pending shot alive ──────────────────────────────────────

func test_deflection_keeps_pending_shot_alive() -> void:
	_add_player(10, 0)
	_add_player(11, 0)
	tracker.on_shot_started(10)
	tracker.on_deflection(11)
	assert_true(tracker.has_pending_shot())


func test_pickup_clears_pending() -> void:
	_add_player(10, 0)
	tracker.on_shot_started(10)
	tracker.on_pickup(10)
	assert_false(tracker.has_pending_shot())


# ── Assists ──────────────────────────────────────────────────────────────────

func test_credit_assists_up_to_two_same_team_carriers() -> void:
	var a1 := _add_player(10, 0, "A1")
	var a2 := _add_player(11, 0, "A2")
	var scorer := _add_player(12, 0, "Scorer")
	tracker.on_pickup(10)
	tracker.on_pickup(11)
	tracker.on_pickup(12)
	var assists: Array[String] = tracker.credit_assists(12)
	assert_eq(assists.size(), 2)
	assert_eq(assists[0], "A2")
	assert_eq(assists[1], "A1")
	assert_eq(a1.stats.assists, 1)
	assert_eq(a2.stats.assists, 1)
	assert_eq(scorer.stats.assists, 0)


func test_credit_assists_stops_at_opposing_established_possession() -> void:
	var team_assist := _add_player(10, 0, "TeamA1")
	_add_player(11, 1, "Opponent")  # opposing ESTABLISHED possession breaks chain
	var team_assist_2 := _add_player(12, 0, "TeamA2")
	var scorer := _add_player(13, 0, "Scorer")
	tracker.on_pickup(10)
	tracker.on_pickup(11)
	tracker.on_possession_established(11)  # held it / made a play — control
	tracker.on_pickup(12)
	tracker.on_pickup(13)
	var assists: Array[String] = tracker.credit_assists(13)
	assert_eq(assists.size(), 1)
	assert_eq(assists[0], "TeamA2")
	assert_eq(team_assist.stats.assists, 0, "chain stopped at opponent — no credit")
	assert_eq(team_assist_2.stats.assists, 1)
	assert_eq(scorer.stats.assists, 0)


func test_assist_survives_momentary_opposing_pickup() -> void:
	# A dangerous puck sent into traffic, briefly proximity-attached to a
	# defender who never controls it, knocked in by a teammate — the sender
	# keeps the assist because no opponent ESTABLISHED possession.
	var passer := _add_player(10, 0, "Passer")
	_add_player(20, 1, "Defender")
	var scorer := _add_player(11, 0, "Scorer")
	tracker.on_pickup(10)
	tracker.on_pickup(20)  # scramble attach — never establishes
	tracker.on_pickup(11)
	var assists: Array[String] = tracker.credit_assists(11)
	assert_eq(assists.size(), 1, "unestablished opposing touch skipped")
	assert_eq(assists[0], "Passer")
	assert_eq(passer.stats.assists, 1)


func test_assist_survives_opposing_deflection() -> void:
	# NHL: a mere opposing TOUCH (pass grazing a defender) doesn't break the
	# assist chain — only opposing possession does.
	var passer := _add_player(10, 0, "Passer")
	_add_player(20, 1, "Defender")
	var scorer := _add_player(11, 0, "Scorer")
	tracker.on_pickup(10)      # passer possesses
	tracker.on_deflection(20)  # pass deflects off a defender
	tracker.on_pickup(11)      # scorer corrals it and scores
	var assists: Array[String] = tracker.credit_assists(11)
	assert_eq(assists.size(), 1, "opposing touch skipped, passer keeps the assist")
	assert_eq(assists[0], "Passer")
	assert_eq(passer.stats.assists, 1)


func test_two_assists_survive_multiple_opposing_touches() -> void:
	var a1 := _add_player(10, 0, "A1")
	var a2 := _add_player(11, 0, "A2")
	_add_player(20, 1, "Defender")
	var scorer := _add_player(12, 0, "Scorer")
	tracker.on_pickup(10)      # A1 carries
	tracker.on_deflection(20)  # pass tips off the defender
	tracker.on_pickup(11)      # A2 carries
	tracker.on_deflection(20)  # second pass tips off the defender again
	tracker.on_pickup(12)      # scorer
	var assists: Array[String] = tracker.credit_assists(12)
	assert_eq(assists.size(), 2)
	assert_eq(assists[0], "A2")
	assert_eq(assists[1], "A1")
	assert_eq(a1.stats.assists, 1)
	assert_eq(a2.stats.assists, 1)


func test_deflection_then_established_pickup_breaks_chain() -> void:
	# The defender tips the pass, corrals it AND establishes control — the
	# collapsed history entry upgrades to possession, breaking the chain.
	var passer := _add_player(10, 0, "Passer")
	_add_player(20, 1, "Defender")
	var scorer := _add_player(11, 0, "Scorer")
	tracker.on_pickup(10)
	tracker.on_deflection(20)              # tip...
	tracker.on_pickup(20)                  # ...corral (collapses into one entry)...
	tracker.on_possession_established(20)  # ...held long enough — control
	tracker.on_pickup(11)                  # scorer steals it back and scores
	var assists: Array[String] = tracker.credit_assists(11)
	assert_eq(assists.size(), 0, "opposing possession broke the chain")
	assert_eq(passer.stats.assists, 0)
	assert_eq(scorer.stats.assists, 0)


func test_credit_assists_stops_at_scorers_own_prior_touch() -> void:
	# Sequence: scorer carries, teammate carries, scorer carries again and scores.
	# The scorer's earlier touch should stop the assist chain — no self-assist.
	var scorer := _add_player(10, 0, "Scorer")
	var _teammate := _add_player(11, 0, "Teammate")
	tracker.on_pickup(10)   # scorer first touch
	tracker.on_pickup(11)   # teammate
	tracker.on_pickup(10)   # scorer picks up again and shoots
	var assists: Array[String] = tracker.credit_assists(10)
	assert_eq(assists.size(), 1, "teammate gets the assist")
	assert_eq(assists[0], "Teammate")
	assert_eq(scorer.stats.assists, 0, "scorer must not credit themselves an assist")

func test_credit_assists_scorer_without_team_returns_empty() -> void:
	var assists: Array[String] = tracker.credit_assists(999)  # unregistered
	assert_eq(assists.size(), 0)


func test_teammate_touching_twice_earns_only_one_assist() -> void:
	# A1 carries, the pass tips off a defender (a touch, not possession), A1
	# regains it and feeds the scorer. A1 appears at two non-consecutive history
	# slots but must earn a single assist, not two.
	var a1 := _add_player(10, 0, "A1")
	_add_player(20, 1, "Defender")
	var scorer := _add_player(12, 0, "Scorer")
	tracker.on_pickup(10)      # A1 carries
	tracker.on_deflection(20)  # pass tips off a defender (unestablished touch)
	tracker.on_pickup(10)      # A1 regains — second, non-consecutive entry
	tracker.on_pickup(12)      # scorer finishes
	var assists: Array[String] = tracker.credit_assists(12)
	assert_eq(assists.size(), 1, "A1 touched twice but earns one assist")
	assert_eq(assists[0], "A1")
	assert_eq(a1.stats.assists, 1, "no double-credit for the repeat touch")
	assert_eq(scorer.stats.assists, 0)


# ── Poke-check attribution ───────────────────────────────────────────────────
# A poke-check records the poker as the most recent toucher so a puck poked
# straight off the carrier's stick into the net is credited to the poker, but
# the entry is flagged so it never earns an assist (a strip isn't a play that
# feeds the goal).

func test_poke_check_makes_poker_the_last_toucher() -> void:
	_add_player(20, 1, "Defender")
	_add_player(10, 0, "Poker")
	tracker.on_pickup(20)      # defender carries near their own net
	tracker.on_poke_check(10)  # attacker pokes it loose — straight into the net
	assert_eq(tracker.get_last_toucher(), 10,
			"a puck poked directly into the net is the poker's goal")


func test_poke_check_feeding_a_teammate_earns_the_poker_an_assist() -> void:
	# A poke that strips the carrier and goes straight to a teammate who scores
	# is a play that set up the goal — the poker gets the assist. The opposing
	# carrier they stripped (who possessed the puck) breaks the chain a step
	# further back, so credit never walks into the other team.
	var poker := _add_player(10, 0, "Poker")
	var defender := _add_player(20, 1, "Defender")
	var scorer := _add_player(11, 0, "Scorer")
	tracker.on_pickup(20)
	tracker.on_possession_established(20)  # defender actually controlled it
	tracker.on_poke_check(10)  # attacker pokes it off the defender to a teammate
	tracker.on_pickup(11)      # the teammate corrals the loose puck and scores
	var assists: Array[String] = tracker.credit_assists(11)
	assert_eq(assists.size(), 1, "a poke that feeds the scorer is an assist")
	assert_eq(assists[0], "Poker")
	assert_eq(poker.stats.assists, 1)
	assert_eq(defender.stats.assists, 0, "chain stopped at the stripped opponent")
	assert_eq(scorer.stats.assists, 0)


func test_poke_then_own_pickup_feeds_a_teammate_for_an_assist() -> void:
	# The poker strips it, corrals the loose puck themselves, then feeds a
	# teammate. Two touches by the poker collapse to one entry — still one assist.
	var poker := _add_player(10, 0, "Poker")
	_add_player(20, 1, "Defender")
	var scorer := _add_player(11, 0, "Scorer")
	tracker.on_pickup(20)      # defender carries
	tracker.on_poke_check(10)  # poke strips it
	tracker.on_pickup(10)      # poker picks it up (collapses onto the poke entry)
	tracker.on_pickup(11)      # feeds the teammate who scores
	var assists: Array[String] = tracker.credit_assists(11)
	assert_eq(assists.size(), 1)
	assert_eq(assists[0], "Poker")
	assert_eq(poker.stats.assists, 1)
	assert_eq(scorer.stats.assists, 0)


# ── One-timer attribution ────────────────────────────────────────────────────
# Mirrors the host call sequence in GameManager._host_release_one_timer:
# the passer picks up + shoots, then the receiver redirects the moving puck
# as a one-timer. on_deflection(receiver) records the shooter in the carrier
# history; without it, the passer would be returned as the last toucher and
# wrongly credited with the goal.

func test_one_timer_credits_receiver_not_passer() -> void:
	var passer := _add_player(10, 0, "Passer")
	var receiver := _add_player(11, 0, "Receiver")
	tracker.on_pickup(10)              # passer picks up
	tracker.on_shot_started(10)        # passer "shoots" (the pass)
	tracker.on_deflection(11)          # receiver redirects mid-flight
	tracker.on_shot_started(11)        # one-timer arms shooter = receiver
	assert_eq(tracker.get_last_toucher(), 11,
			"goal must be attributed to the one-timer shooter, not the passer")
	assert_eq(tracker.get_shooter_peer_id(), 11)
	var assists: Array[String] = tracker.credit_assists(11)
	assert_eq(assists.size(), 1, "passer earns the assist")
	assert_eq(assists[0], "Passer")
	assert_eq(passer.stats.assists, 1)
	assert_eq(receiver.stats.assists, 0)


# ── Shots blocked ────────────────────────────────────────────────────────────
# `on_block` is called by GameManager for both blade deflections and body
# blocks via `puck_touched_while_loose`. The differentiator that decides
# whether it's a block (credit + clear pending) vs a tip-in (continue pending)
# is the team of the toucher relative to the shooter.

func test_block_by_defender_credits_shots_blocked() -> void:
	var shooter := _add_player(10, 0)
	var blocker := _add_player(20, 1)
	tracker.on_shot_started(10)
	var credited: bool = tracker.on_block(20)
	assert_true(credited)
	assert_eq(blocker.stats.shots_blocked, 1)
	assert_eq(shooter.stats.shots_blocked, 0)
	assert_false(tracker.has_pending_shot(),
			"defender intercept ends the shot — pending state cleared")


func _last_event() -> ShotEvent:
	var params: Array = get_signal_parameters(tracker, "shot_resolved")
	return params[0] if params != null and not params.is_empty() else null


func test_block_emits_blocked_event_with_shooter() -> void:
	# Corsi/Fenwick: a credited block is a blocked attempt (Corsi yes, Fenwick no),
	# attributed to the SHOOTER (peer 10), not the blocker.
	_add_player(10, 0)
	_add_player(20, 1)
	watch_signals(tracker)
	tracker.on_shot_started(10)
	tracker.on_block(20)
	assert_signal_emitted(tracker, "shot_resolved")
	var e := _last_event()
	assert_eq(e.shooter_peer, 10)
	assert_eq(e.outcome, ShotEvent.Outcome.BLOCKED)


func test_uncredited_block_does_not_emit_event() -> void:
	# An off-net "block" is a takeaway, not a blocked shot — no Corsi event here.
	_add_player(10, 0)
	_add_player(20, 1)
	watch_signals(tracker)
	tracker.on_shot_started(10)
	tracker.note_trajectory(false)
	tracker.note_directed_at_net(false)
	tracker.on_block(20)
	assert_signal_not_emitted(tracker, "shot_resolved")


# ── Corsi/Fenwick shot-vs-pass classification (shot_resolved) ────────────────

func test_on_goal_shot_emits_saved_event() -> void:
	_add_player(10, 0)
	_add_player(99, 1)  # opposing goalie's team
	watch_signals(tracker)
	tracker.on_shot_started(10)
	tracker.on_goalie_touch(1)  # saved, on net
	assert_signal_emitted(tracker, "shot_resolved")
	var e := _last_event()
	assert_eq(e.shooter_peer, 10)
	assert_eq(e.outcome, ShotEvent.Outcome.SAVED)


func test_on_goal_shot_carries_its_xg_and_origin() -> void:
	# The xG + release position noted at release ride the resolved event.
	_add_player(10, 0)
	watch_signals(tracker)
	tracker.on_shot_started(10)
	tracker.note_xg(0.27)
	tracker.note_shot_origin(Vector3(1.5, 0.0, -20.0))
	tracker.on_goalie_touch(1)
	var e := _last_event()
	assert_almost_eq(e.xg, 0.27, 0.0001)
	assert_almost_eq(e.x, 1.5, 0.0001)
	assert_almost_eq(e.z, -20.0, 0.0001)


func test_confirmed_goal_logs_goal_outcome() -> void:
	_add_player(10, 0)
	watch_signals(tracker)
	tracker.on_shot_started(10)
	tracker.on_goal_confirmed(10)
	assert_eq(_last_event().outcome, ShotEvent.Outcome.GOAL)


func test_directed_miss_recovered_by_defender_counts() -> void:
	# Directed at net, missed wide, a defender retrieves it → a missed shot (Corsi).
	_add_player(10, 0)
	_add_player(20, 1)
	watch_signals(tracker)
	tracker.on_shot_started(10)
	tracker.note_trajectory(false)          # missed the net
	tracker.note_directed_at_net(true)      # but was aimed at it
	tracker.on_pickup(20)                   # defender recovers
	assert_signal_emitted(tracker, "shot_resolved")
	var e := _last_event()
	assert_eq(e.shooter_peer, 10)
	assert_eq(e.outcome, ShotEvent.Outcome.MISSED)


func test_directed_shot_received_by_teammate_is_a_pass() -> void:
	# A backdoor feed / saucer: directed at the goal mouth, but the teammate
	# receives it → a pass, not a shot. No shot_resolved.
	_add_player(10, 0)
	_add_player(11, 0)  # teammate at the net
	watch_signals(tracker)
	tracker.on_shot_started(10)
	tracker.note_trajectory(false)
	tracker.note_directed_at_net(true)
	tracker.on_pickup(11)                   # teammate collects it → pass
	assert_signal_not_emitted(tracker, "shot_resolved")


func test_undirected_release_recovered_is_not_a_shot() -> void:
	# A pass into space / clear: not directed at net, so recovering it is not a
	# missed shot.
	_add_player(10, 0)
	_add_player(20, 1)
	watch_signals(tracker)
	tracker.on_shot_started(10)
	tracker.note_trajectory(false)
	tracker.note_directed_at_net(false)     # aimed at a teammate / into space
	tracker.on_pickup(20)
	assert_signal_not_emitted(tracker, "shot_resolved")


func test_directed_miss_times_out_as_one_shot() -> void:
	_add_player(10, 0)
	watch_signals(tracker)
	tracker.on_shot_started(10)
	tracker.note_trajectory(false)
	tracker.note_directed_at_net(true)
	tracker.tick(ShotOnGoalTracker.SHOT_ON_GOAL_TIMEOUT + 0.1)
	assert_signal_emitted(tracker, "shot_resolved")
	assert_eq(_last_event().outcome, ShotEvent.Outcome.MISSED)
	assert_eq(get_signal_emit_count(tracker, "shot_resolved"), 1,
			"a timed-out miss counts exactly once")


func test_intended_pass_nobody_receives_is_not_a_shot() -> void:
	# The #579 case: an errant pass. It fails both of the geometric outs by
	# definition — the intended receiver never got it, and a stretch pass up the
	# middle genuinely projects at the far mouth (a 15 m/s release coasts ~230 m
	# on 0.05 friction, so reachability is real; the window is only ±2.3° wide).
	# Only the release INTENT separates it from a missed shot.
	_add_player(10, 0)
	_add_player(20, 1)
	watch_signals(tracker)
	tracker.on_shot_started(10)
	tracker.note_trajectory(false)
	tracker.note_directed_at_net(true)      # lines up with the far mouth
	tracker.note_release_intent(false)      # but it was thrown as a pass
	tracker.on_pickup(20)                   # an opponent picks it off
	assert_signal_not_emitted(tracker, "shot_resolved")


func test_intended_pass_that_times_out_is_not_a_shot() -> void:
	# Same, on the other resolution path: nobody recovers it at all.
	_add_player(10, 0)
	watch_signals(tracker)
	tracker.on_shot_started(10)
	tracker.note_trajectory(false)
	tracker.note_directed_at_net(true)
	tracker.note_release_intent(false)
	tracker.tick(ShotOnGoalTracker.SHOT_ON_GOAL_TIMEOUT + 0.1)
	assert_signal_not_emitted(tracker, "shot_resolved")


func test_intended_pass_that_goes_in_is_still_a_goal() -> void:
	# Intent gates the MISS resolution only. A feed that beats the goalie counts
	# — the puck crossed the line, whatever it was thrown as.
	_add_player(10, 0)
	watch_signals(tracker)
	tracker.on_shot_started(10)
	tracker.note_release_intent(false)
	tracker.on_goal_confirmed(10)
	assert_signal_emitted(tracker, "shot_resolved")
	assert_eq(_last_event().outcome, ShotEvent.Outcome.GOAL)


func test_intended_pass_the_goalie_stops_is_still_a_save() -> void:
	# The other half of "MISS resolution only": a pass the goalie has to stop is
	# a shot on goal by the on-net read, and on_goalie_touch never consults intent.
	_add_player(10, 0)
	watch_signals(tracker)
	tracker.on_shot_started(10)
	tracker.note_trajectory(true)
	tracker.note_release_intent(false)
	tracker.on_goalie_touch(1)
	assert_signal_emitted(tracker, "shot_resolved")
	assert_eq(_last_event().outcome, ShotEvent.Outcome.SAVED)


func test_release_intent_defaults_to_shot() -> void:
	# A caller that never notes intent must still log misses — the default
	# over-credits, matching the on-net / directed reads it sits beside.
	_add_player(10, 0)
	_add_player(20, 1)
	watch_signals(tracker)
	tracker.on_shot_started(10)
	tracker.note_directed_at_net(true)
	tracker.on_pickup(20)
	assert_signal_emitted(tracker, "shot_resolved")
	assert_eq(_last_event().outcome, ShotEvent.Outcome.MISSED)


func test_pass_intent_does_not_leak_into_the_next_shot() -> void:
	# Pending state is per-release: a pass resolving as nothing must not leave
	# the flag set for the shot that follows it.
	_add_player(10, 0)
	_add_player(20, 1)
	tracker.on_shot_started(10)
	tracker.note_directed_at_net(true)
	tracker.note_release_intent(false)
	tracker.on_pickup(20)                   # the pass dies here, no event
	watch_signals(tracker)
	tracker.on_shot_started(10)             # a real shot, intent never noted
	tracker.note_directed_at_net(true)
	tracker.on_pickup(20)
	assert_signal_emitted(tracker, "shot_resolved")
	assert_eq(_last_event().outcome, ShotEvent.Outcome.MISSED)


func test_rebound_of_a_pass_redirected_by_a_teammate_is_a_shot() -> void:
	# A saved release re-armed by an attacking teammate is that teammate
	# shooting, whatever the original release was thrown as.
	_add_player(10, 0)
	_add_player(11, 0)
	_add_player(20, 1)
	tracker.on_shot_started(10)
	tracker.note_trajectory(true)
	tracker.note_release_intent(false)
	tracker.on_goalie_touch(1)              # counted; pending stays for the rebound
	watch_signals(tracker)
	tracker.on_deflection(11)               # teammate redirects the rebound
	tracker.note_directed_at_net(true)
	tracker.on_pickup(20)                   # a defender kills it
	assert_signal_emitted(tracker, "shot_resolved")
	assert_eq(_last_event().outcome, ShotEvent.Outcome.MISSED)
	assert_eq(_last_event().shooter_peer, 11)


func test_post_hit_is_a_directed_miss() -> void:
	# A post is a miss but stays a shot attempt even after on_net flips off.
	_add_player(10, 0)
	_add_player(20, 1)
	watch_signals(tracker)
	tracker.on_shot_started(10)
	tracker.on_post_hit()                   # off net now, but directed
	tracker.on_pickup(20)
	assert_signal_emitted(tracker, "shot_resolved")
	assert_eq(_last_event().outcome, ShotEvent.Outcome.MISSED)


func test_block_by_teammate_does_not_credit() -> void:
	_add_player(10, 0)
	var teammate := _add_player(11, 0)
	tracker.on_shot_started(10)
	var credited: bool = tracker.on_block(11)
	assert_false(credited)
	assert_eq(teammate.stats.shots_blocked, 0)
	assert_true(tracker.has_pending_shot(),
			"same-team contact (tip-in attempt) doesn't end the pending shot")


func test_block_without_pending_shot_is_noop() -> void:
	var blocker := _add_player(20, 1)
	var credited: bool = tracker.on_block(20)
	assert_false(credited)
	assert_eq(blocker.stats.shots_blocked, 0)


func test_block_with_invalid_peer_is_noop() -> void:
	_add_player(10, 0)
	tracker.on_shot_started(10)
	assert_false(tracker.on_block(-1))
	assert_true(tracker.has_pending_shot())


func test_block_only_counts_inside_the_block_window() -> void:
	# A defender touch a beat after the release is a takeaway/rebound, not a
	# blocked shot. The pending shot stays alive (5 s SOG window) but the block
	# window has lapsed, so on_block no longer credits.
	var shooter := _add_player(10, 0)
	var blocker := _add_player(20, 1)
	tracker.on_shot_started(10)
	tracker.tick(ShotOnGoalTracker.BLOCK_WINDOW + 0.1)
	var credited: bool = tracker.on_block(20)
	assert_false(credited, "touch after the block window is not a blocked shot")
	assert_eq(blocker.stats.shots_blocked, 0)
	assert_eq(shooter.stats.shots_blocked, 0)
	assert_true(tracker.has_pending_shot(),
			"the shot itself is still pending for SOG — only the block window closed")


# ── Reset ────────────────────────────────────────────────────────────────────

func test_reset_all_clears_state_and_team_shots() -> void:
	var p := _add_player(10, 0)
	tracker.on_pickup(10)
	tracker.on_shot_started(10)
	tracker.on_goalie_touch(1)
	assert_eq(sm.team_shots[0], 1)
	tracker.reset_all()
	assert_eq(sm.team_shots[0], 0)
	assert_eq(sm.team_shots[1], 0)
	assert_false(tracker.has_pending_shot())
	# Recent carriers cleared — scorer lookup should miss
	assert_eq(tracker.find_scorer_on_team(0), -1)
	# Stats were not mutated by reset (registry owns stats lifecycle)
	assert_eq(p.stats.shots_on_goal, 1,
			"reset_all doesn't touch player stats — that's PlayerRegistry's job")


func test_shots_on_goal_changed_signal_fires() -> void:
	_add_player(10, 0)
	watch_signals(tracker)
	tracker.on_shot_started(10)
	tracker.on_goalie_touch(1)
	assert_signal_emitted_with_parameters(tracker, "shots_on_goal_changed", [1, 0])
