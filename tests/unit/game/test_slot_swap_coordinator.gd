extends GutTest

# SlotSwapCoordinator — request-side validation and confirmation packaging.
# apply_confirmed_swap() teleports skaters + re-colors meshes via live nodes,
# so only request_swap() is covered here.

var coord: SlotSwapCoordinator
var registry: PlayerRegistry
var sm: GameStateMachine
var teams: Array[Team]


func before_each() -> void:
	sm = GameStateMachine.new()
	registry = PlayerRegistry.new()
	teams = []
	for tid: int in [0, 1]:
		var t := Team.new()
		t.team_id = tid
		teams.append(t)
	coord = SlotSwapCoordinator.new()
	coord.setup(registry, sm, teams)


# Registers a player in both the state machine (domain roster) and the
# registry (runtime roster) so slot-swap validation finds both entries.
func _add_player(peer_id: int, team_id: int, team_slot: int) -> PlayerRecord:
	sm.register_remote_assigned_player(peer_id, team_slot, team_id)
	var record := PlayerRecord.new(peer_id, team_slot, false, teams[team_id])
	var colors: Dictionary = TeamColorRegistry.get_colors(teams[team_id].color_slot, team_id)
	record.jersey_color = colors.jersey
	record.helmet_color = colors.helmet
	record.pants_color  = colors.pants
	registry._players[peer_id] = record
	return record


# ── Validation ───────────────────────────────────────────────────────────────

func test_request_cross_team_swap_regenerates_colors() -> void:
	_add_player(10, 0, 0)
	var result: Dictionary = coord.request_swap(10, 1, 0, null)
	assert_false(result.is_empty())
	assert_eq(result.old_team_id, 0)
	assert_eq(result.new_team_id, 1)
	assert_eq(result.new_slot, 0)
	# Cross-team: colors should match team 1's palette from the registry
	var expected: Dictionary = TeamColorRegistry.get_colors(teams[1].color_slot, 1)
	assert_eq(result.jersey, expected.jersey)
	assert_eq(result.helmet, expected.helmet)
	assert_eq(result.pants,  expected.pants)


func test_request_same_team_swap_keeps_original_colors() -> void:
	var record := _add_player(10, 0, 0)
	var result: Dictionary = coord.request_swap(10, 0, 1, null)
	assert_false(result.is_empty())
	assert_eq(result.jersey, record.jersey_color)
	assert_eq(result.helmet, record.helmet_color)
	assert_eq(result.pants,  record.pants_color)


func test_request_occupied_slot_is_rejected() -> void:
	_add_player(10, 0, 0)
	_add_player(11, 1, 2)
	var result: Dictionary = coord.request_swap(10, 1, 2, null)
	assert_true(result.is_empty(), "swapping into an occupied slot returns {}")


func test_request_invalid_team_id_rejected() -> void:
	_add_player(10, 0, 0)
	assert_true(coord.request_swap(10, -1, 0, null).is_empty())
	assert_true(coord.request_swap(10, 2, 0, null).is_empty())


func test_request_invalid_slot_rejected() -> void:
	_add_player(10, 0, 0)
	assert_true(coord.request_swap(10, 0, -1, null).is_empty())
	assert_true(coord.request_swap(10, 0, 99, null).is_empty())


func test_request_same_position_is_noop() -> void:
	_add_player(10, 0, 1)
	var result: Dictionary = coord.request_swap(10, 0, 1, null)
	assert_true(result.is_empty())


func test_request_unregistered_peer_rejected() -> void:
	var result: Dictionary = coord.request_swap(999, 0, 0, null)
	assert_true(result.is_empty())


# ── Side effects ─────────────────────────────────────────────────────────────
# Note: the carrier-drop signal fires on `record.skater == puck_carrier`.
# Exercising that branch in isolation requires a real Skater node, so the
# carrier-swap-while-holding-puck behaviour is covered by the in-editor smoke
# test listed in the refactor plan rather than a unit test.

func test_non_carrier_swap_does_not_emit_drop_signal() -> void:
	_add_player(10, 0, 0)
	watch_signals(coord)
	coord.request_swap(10, 1, 0, null)
	assert_signal_emit_count(coord, "carrier_swap_needs_drop", 0)
