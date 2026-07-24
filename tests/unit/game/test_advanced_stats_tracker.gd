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


func test_unblocked_shot_increments_corsi_only() -> void:
	var p := _add_player(10, 0)
	tracker.on_shot_counted(10, false)
	tracker.on_shot_counted(10, false)
	assert_eq(p.stats.shot_attempts, 2)
	assert_eq(p.stats.shot_attempts_blocked, 0)


func test_blocked_shot_increments_corsi_and_blocked() -> void:
	# Corsi counts the attempt; the blocked subset is tracked so Fenwick =
	# shot_attempts − shot_attempts_blocked excludes it.
	var p := _add_player(10, 0)
	tracker.on_shot_counted(10, true)
	assert_eq(p.stats.shot_attempts, 1)
	assert_eq(p.stats.shot_attempts_blocked, 1)
	assert_eq(p.stats.shot_attempts - p.stats.shot_attempts_blocked, 0,
			"one attempt, blocked → Fenwick 0")


func test_unknown_peer_is_a_noop() -> void:
	# A stray signal for a peer with no record must not crash.
	tracker.on_shot_counted(999, false)
	tracker.on_shot_counted(-1, true)
	pass_test("no crash on missing / sentinel peer")


func test_attribution_is_per_player() -> void:
	var a := _add_player(10, 0)
	var b := _add_player(11, 0)
	tracker.on_shot_counted(10, false)
	tracker.on_shot_counted(10, false)
	tracker.on_shot_counted(11, false)
	assert_eq(a.stats.shot_attempts, 2)
	assert_eq(b.stats.shot_attempts, 1)
