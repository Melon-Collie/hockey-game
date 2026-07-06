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


func test_credit_assists_stops_at_opposing_possession() -> void:
	var team_assist := _add_player(10, 0, "TeamA1")
	_add_player(11, 1, "Opponent")          # opposing PICKUP interrupts chain
	var team_assist_2 := _add_player(12, 0, "TeamA2")
	var scorer := _add_player(13, 0, "Scorer")
	tracker.on_pickup(10)
	tracker.on_pickup(11)
	tracker.on_pickup(12)
	tracker.on_pickup(13)
	var assists: Array[String] = tracker.credit_assists(13)
	assert_eq(assists.size(), 1)
	assert_eq(assists[0], "TeamA2")
	assert_eq(team_assist.stats.assists, 0, "chain stopped at opponent — no credit")
	assert_eq(team_assist_2.stats.assists, 1)
	assert_eq(scorer.stats.assists, 0)


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


func test_deflection_then_pickup_upgrades_to_possession_and_breaks_chain() -> void:
	# The defender tips the pass AND then corrals it — the collapsed history
	# entry upgrades to possession, which breaks the assist chain.
	var passer := _add_player(10, 0, "Passer")
	_add_player(20, 1, "Defender")
	var scorer := _add_player(11, 0, "Scorer")
	tracker.on_pickup(10)
	tracker.on_deflection(20)  # tip...
	tracker.on_pickup(20)      # ...then full possession (collapses into one entry)
	tracker.on_pickup(11)      # scorer steals it back and scores
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
