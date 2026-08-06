extends GutTest

# AdvancedStatsTracker — per-player Corsi/Fenwick attribution (analytics A1).
# PlayerRegistry is constructed but its setup() is skipped; we populate the
# `_players` dict directly since only get_record() is exercised.

var tracker: AdvancedStatsTracker
var registry: PlayerRegistry


func before_each() -> void:
	registry = PlayerRegistry.new()
	tracker = AdvancedStatsTracker.new()
	tracker.setup(registry)


func _add_player(peer_id: int, team_id: int) -> PlayerRecord:
	var team := Team.new()
	team.team_id = team_id
	var record := PlayerRecord.new(peer_id, 0, false, team)
	record.stats = PlayerStats.new()
	registry._players[peer_id] = record
	return record


func _ev(peer: int, outcome: int, xg: float) -> ShotEvent:
	return ShotEvent.make(peer, 0, Vector3.ZERO, xg, outcome,
			ShotEvent.ShotType.SHOT, true, 1, 0.0)


func test_unblocked_shot_increments_corsi_and_xg() -> void:
	var p := _add_player(10, 0)
	tracker.on_shot_resolved(_ev(10, ShotEvent.Outcome.SAVED, 0.30))
	tracker.on_shot_resolved(_ev(10, ShotEvent.Outcome.MISSED, 0.12))
	assert_eq(p.stats.shot_attempts, 2)
	assert_eq(p.stats.shot_attempts_blocked, 0)
	assert_almost_eq(p.stats.xg_for, 0.42, 0.0001)


func test_blocked_shot_increments_corsi_and_blocked_no_xg() -> void:
	# Corsi counts the attempt; the blocked subset is tracked so Fenwick =
	# shot_attempts − shot_attempts_blocked excludes it. Blocked shots carry no xG.
	var p := _add_player(10, 0)
	tracker.on_shot_resolved(_ev(10, ShotEvent.Outcome.BLOCKED, 0.20))
	assert_eq(p.stats.shot_attempts, 1)
	assert_eq(p.stats.shot_attempts_blocked, 1)
	assert_eq(p.stats.shot_attempts - p.stats.shot_attempts_blocked, 0,
			"one attempt, blocked → Fenwick 0")
	assert_almost_eq(p.stats.xg_for, 0.0, 0.0001,
			"a blocked shot's xG never reaches xGF")


func test_events_are_buffered() -> void:
	_add_player(10, 0)
	tracker.on_shot_resolved(_ev(10, ShotEvent.Outcome.GOAL, 0.4))
	tracker.on_shot_resolved(_ev(10, ShotEvent.Outcome.BLOCKED, 0.1))
	assert_eq(tracker.get_shot_events().size(), 2, "every resolved shot is logged")
	assert_eq(tracker.get_shot_events()[0].outcome, ShotEvent.Outcome.GOAL)


func test_reset_drops_the_finished_games_shots() -> void:
	# A rematch reuses this tracker (it never respawns the world). The log is
	# posted stamped with the CURRENT game_id, so carrying it forward would
	# re-upload the first game's shots under every rematch played after it.
	_add_player(10, 0)
	tracker.on_shot_resolved(_ev(10, ShotEvent.Outcome.GOAL, 0.4))
	tracker.reset()
	assert_eq(tracker.get_shot_events().size(), 0)
	tracker.on_shot_resolved(_ev(10, ShotEvent.Outcome.SAVED, 0.2))
	assert_eq(tracker.get_shot_events().size(), 1,
			"the rematch logs only its own shots")


func test_unknown_peer_still_buffers_but_no_crash() -> void:
	# A stray event for a peer with no record must not crash; it's still logged.
	tracker.on_shot_resolved(_ev(999, ShotEvent.Outcome.MISSED, 0.2))
	assert_eq(tracker.get_shot_events().size(), 1)
	pass_test("no crash on missing peer")


func test_attribution_is_per_player() -> void:
	var a := _add_player(10, 0)
	var b := _add_player(11, 0)
	tracker.on_shot_resolved(_ev(10, ShotEvent.Outcome.SAVED, 0.2))
	tracker.on_shot_resolved(_ev(10, ShotEvent.Outcome.MISSED, 0.1))
	tracker.on_shot_resolved(_ev(11, ShotEvent.Outcome.SAVED, 0.5))
	assert_eq(a.stats.shot_attempts, 2)
	assert_eq(b.stats.shot_attempts, 1)
	assert_almost_eq(a.stats.xg_for, 0.3, 0.0001)
	assert_almost_eq(b.stats.xg_for, 0.5, 0.0001)
