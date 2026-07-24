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


func test_shot_attempt_increments_corsi() -> void:
	var p := _add_player(10, 0)
	tracker.on_shot_attempted(10)
	tracker.on_shot_attempted(10)
	assert_eq(p.stats.shot_attempts, 2)
	assert_eq(p.stats.shot_attempts_blocked, 0)


func test_blocked_attempt_increments_blocked_only() -> void:
	# Fenwick = shot_attempts − shot_attempts_blocked. A block bumps only the
	# blocked counter; Corsi is bumped separately at release.
	var p := _add_player(10, 0)
	tracker.on_shot_attempted(10)
	tracker.on_shot_blocked(10)
	assert_eq(p.stats.shot_attempts, 1)
	assert_eq(p.stats.shot_attempts_blocked, 1)
	assert_eq(p.stats.shot_attempts - p.stats.shot_attempts_blocked, 0,
			"one attempt, blocked → Fenwick 0")


func test_unknown_peer_is_a_noop() -> void:
	# A stray signal for a peer with no record must not crash.
	tracker.on_shot_attempted(999)
	tracker.on_shot_blocked(-1)
	pass_test("no crash on missing / sentinel peer")


func test_attribution_is_per_player() -> void:
	var a := _add_player(10, 0)
	var b := _add_player(11, 0)
	tracker.on_shot_attempted(10)
	tracker.on_shot_attempted(10)
	tracker.on_shot_attempted(11)
	assert_eq(a.stats.shot_attempts, 2)
	assert_eq(b.stats.shot_attempts, 1)
