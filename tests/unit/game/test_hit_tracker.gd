extends GutTest

# HitTracker — cross-team hit validation and stat crediting.
# PlayerRegistry is constructed but its setup() is skipped; we populate
# the `_players` dict directly since only lookup methods are exercised.

var tracker: HitTracker
var registry: PlayerRegistry


func before_each() -> void:
	registry = PlayerRegistry.new()
	tracker = HitTracker.new()
	tracker.setup(registry)


func _add_player(peer_id: int, team_id: int) -> PlayerRecord:
	var team := Team.new()
	team.team_id = team_id
	var record := PlayerRecord.new(peer_id, 0, false, team)
	record.stats = PlayerStats.new()
	registry._players[peer_id] = record
	return record


# ── Hit crediting ────────────────────────────────────────────────────────────

func test_hit_on_opponent_credits_hitter() -> void:
	var hitter := _add_player(1, 0)
	_add_player(2, 1)
	tracker.on_hit(1, 2, 1)  # team 0 hits team 1
	assert_eq(hitter.stats.hits, 1)

func test_hit_on_teammate_does_not_credit() -> void:
	var hitter := _add_player(1, 0)
	_add_player(2, 0)
	tracker.on_hit(1, 2, 0)  # team 0 hits team 0
	assert_eq(hitter.stats.hits, 0)

func test_hit_emits_signal_on_valid_hit() -> void:
	_add_player(1, 0)
	watch_signals(tracker)
	tracker.on_hit(1, 2, 1)
	assert_signal_emitted(tracker, "hit_credited")

func test_hit_does_not_emit_signal_on_teammate_hit() -> void:
	_add_player(1, 0)
	watch_signals(tracker)
	tracker.on_hit(1, 2, 0)
	assert_signal_not_emitted(tracker, "hit_credited")

func test_hit_unknown_hitter_does_nothing() -> void:
	watch_signals(tracker)
	tracker.on_hit(999, 2, 1)  # unregistered peer
	assert_signal_not_emitted(tracker, "hit_credited")


# ── Impact broadcast payload (Lever A) ───────────────────────────────────────

func test_hit_credited_carries_victim_force_and_dir() -> void:
	_add_player(1, 0)
	watch_signals(tracker)
	var dir := Vector3(0.0, 0.0, 1.0)
	tracker.on_hit(1, 2, 1, 7.5, dir)
	assert_signal_emitted_with_parameters(tracker, "hit_credited", [2, 7.5, dir])

func test_hit_credited_payload_suppressed_within_cooldown() -> void:
	# The per-pair dedup gates the broadcast payload too — a sustained grind emits
	# at most one impact per cooldown, which is the cadence the broadcast wants.
	_add_player(1, 0)
	watch_signals(tracker)
	tracker.on_hit(1, 2, 1, 7.5, Vector3.FORWARD)
	tracker.on_hit(1, 2, 1, 9.0, Vector3.FORWARD)  # same pair, within cooldown
	assert_signal_emit_count(tracker, "hit_credited", 1)
