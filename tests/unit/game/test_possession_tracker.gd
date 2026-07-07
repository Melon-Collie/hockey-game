extends GutTest

# PossessionTracker — established-possession model: a spell establishes by
# holding through PossessionRules.ESTABLISH_HOLD_S or instantly on a
# deliberate play; a spell ending in a strip/drop first was only a touch.
# PlayerRegistry is constructed but its setup() is skipped; we populate
# the `_players` dict directly since only lookup methods are exercised.

var tracker: PossessionTracker
var registry: PlayerRegistry


func before_each() -> void:
	registry = PlayerRegistry.new()
	tracker = PossessionTracker.new()
	tracker.setup(registry)


func _add_player(peer_id: int, team_id: int) -> PlayerRecord:
	var team := Team.new()
	team.team_id = team_id
	var record := PlayerRecord.new(peer_id, 0, false, team)
	record.stats = PlayerStats.new()
	registry._players[peer_id] = record
	return record


func test_holding_establishes_once() -> void:
	_add_player(10, 0)
	watch_signals(tracker)
	tracker.on_pickup(10)
	tracker.tick(PossessionRules.ESTABLISH_HOLD_S + 0.01)
	assert_signal_emitted_with_parameters(tracker, "possession_established", [10, 0])
	tracker.tick(1.0)  # keeps carrying — no re-emit for the same spell
	assert_signal_emit_count(tracker, "possession_established", 1)


func test_short_touch_lost_establishes_nothing() -> void:
	_add_player(10, 0)
	watch_signals(tracker)
	tracker.on_pickup(10)
	tracker.tick(PossessionRules.ESTABLISH_HOLD_S / 2.0)
	tracker.on_puck_lost(10)  # stripped mid-scramble
	tracker.tick(1.0)
	assert_signal_not_emitted(tracker, "possession_established")
	assert_eq(tracker.get_controlling_team(), -1)


func test_deliberate_release_establishes_instantly() -> void:
	_add_player(10, 1)
	watch_signals(tracker)
	tracker.on_pickup(10)
	tracker.on_deliberate_release(10)  # one-touch pass — proves control
	assert_signal_emitted_with_parameters(tracker, "possession_established", [10, 1])


func test_deliberate_release_by_non_carrier_is_noop() -> void:
	_add_player(10, 0)
	_add_player(11, 0)
	watch_signals(tracker)
	tracker.on_pickup(10)
	tracker.on_deliberate_release(11)  # stale/foreign event
	assert_signal_not_emitted(tracker, "possession_established")


func test_deliberate_release_after_hold_does_not_re_emit() -> void:
	_add_player(10, 0)
	watch_signals(tracker)
	tracker.on_pickup(10)
	tracker.tick(PossessionRules.ESTABLISH_HOLD_S + 0.01)  # establishes here
	tracker.on_deliberate_release(10)  # then shoots — same spell
	assert_signal_emit_count(tracker, "possession_established", 1)


func test_controlling_team_persists_through_loose_puck_and_touches() -> void:
	_add_player(10, 0)
	_add_player(20, 1)
	tracker.on_pickup(10)
	tracker.tick(PossessionRules.ESTABLISH_HOLD_S + 0.01)
	tracker.on_puck_lost(10)  # puck loose
	tracker.on_pickup(20)     # opposing scramble touch...
	tracker.on_puck_lost(20)  # ...that never establishes
	assert_eq(tracker.get_controlling_team(), 0,
			"control flips only on an opposing ESTABLISHMENT")
	assert_eq(tracker.get_controlling_peer(), 10)


func test_opposing_establishment_flips_control() -> void:
	_add_player(10, 0)
	_add_player(20, 1)
	tracker.on_pickup(10)
	tracker.tick(PossessionRules.ESTABLISH_HOLD_S + 0.01)
	tracker.on_puck_lost(10)
	tracker.on_pickup(20)
	tracker.on_deliberate_release(20)
	assert_eq(tracker.get_controlling_team(), 1)


func test_hold_timer_restarts_per_spell() -> void:
	_add_player(10, 0)
	watch_signals(tracker)
	tracker.on_pickup(10)
	tracker.tick(PossessionRules.ESTABLISH_HOLD_S * 0.9)
	tracker.on_puck_lost(10)
	tracker.on_pickup(10)  # re-collects — fresh spell, fresh timer
	tracker.tick(PossessionRules.ESTABLISH_HOLD_S * 0.9)
	assert_signal_not_emitted(tracker, "possession_established",
			"hold time must not accumulate across spells")


func test_tick_without_carrier_is_noop() -> void:
	watch_signals(tracker)
	tracker.tick(10.0)
	assert_signal_not_emitted(tracker, "possession_established")


func test_reset_clears_control_and_carrier() -> void:
	_add_player(10, 0)
	watch_signals(tracker)
	tracker.on_pickup(10)
	tracker.tick(PossessionRules.ESTABLISH_HOLD_S + 0.01)
	tracker.reset()  # whistle — faceoff starts from neutral
	assert_eq(tracker.get_controlling_team(), -1)
	assert_eq(tracker.get_controlling_peer(), -1)
	tracker.tick(PossessionRules.ESTABLISH_HOLD_S + 0.01)
	assert_signal_emit_count(tracker, "possession_established", 1,
			"reset dropped the carrier — no second establishment")
