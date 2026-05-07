extends GutTest

# LobbySlotKey — pure (team_id, slot) → int encoding for the lobby.
# Player keys: 0..(MAX_PER_TEAM*2 - 1). Spectator keys: SPECTATOR_KEY_BASE+.

func test_home_slot_zero_encodes_to_zero() -> void:
	assert_eq(LobbySlotKey.encode(0, 0), 0)

func test_home_slots_are_zero_indexed() -> void:
	assert_eq(LobbySlotKey.encode(0, 0), 0)
	assert_eq(LobbySlotKey.encode(0, 1), 1)
	assert_eq(LobbySlotKey.encode(0, 2), 2)

func test_away_slots_offset_by_max_per_team() -> void:
	assert_eq(LobbySlotKey.encode(1, 0), PlayerRules.MAX_PER_TEAM)
	assert_eq(LobbySlotKey.encode(1, 1), PlayerRules.MAX_PER_TEAM + 1)
	assert_eq(LobbySlotKey.encode(1, 2), PlayerRules.MAX_PER_TEAM + 2)

func test_spectator_keys_offset_by_base() -> void:
	assert_eq(LobbySlotKey.encode(LobbySlotKey.SPECTATOR_TEAM_ID, 0), LobbySlotKey.SPECTATOR_KEY_BASE)
	assert_eq(LobbySlotKey.encode(LobbySlotKey.SPECTATOR_TEAM_ID, 5), LobbySlotKey.SPECTATOR_KEY_BASE + 5)

func test_spectator_base_is_above_player_range() -> void:
	# Without this gap the decoders ambiguate spectator vs. player keys.
	assert_gt(LobbySlotKey.SPECTATOR_KEY_BASE, PlayerRules.MAX_PER_TEAM * 2)

func test_team_id_from_player_keys() -> void:
	for slot: int in PlayerRules.MAX_PER_TEAM:
		assert_eq(LobbySlotKey.team_id(LobbySlotKey.encode(0, slot)), 0)
		assert_eq(LobbySlotKey.team_id(LobbySlotKey.encode(1, slot)), 1)

func test_team_id_from_spectator_key() -> void:
	assert_eq(LobbySlotKey.team_id(LobbySlotKey.SPECTATOR_KEY_BASE), LobbySlotKey.SPECTATOR_TEAM_ID)
	assert_eq(LobbySlotKey.team_id(LobbySlotKey.SPECTATOR_KEY_BASE + 3), LobbySlotKey.SPECTATOR_TEAM_ID)

func test_slot_from_player_keys() -> void:
	for team_id: int in [0, 1]:
		for slot: int in PlayerRules.MAX_PER_TEAM:
			var k: int = LobbySlotKey.encode(team_id, slot)
			assert_eq(LobbySlotKey.slot(k), slot)

func test_slot_from_spectator_key() -> void:
	assert_eq(LobbySlotKey.slot(LobbySlotKey.SPECTATOR_KEY_BASE), 0)
	assert_eq(LobbySlotKey.slot(LobbySlotKey.SPECTATOR_KEY_BASE + 4), 4)

func test_is_spectator_predicate() -> void:
	assert_false(LobbySlotKey.is_spectator(LobbySlotKey.encode(0, 0)))
	assert_false(LobbySlotKey.is_spectator(LobbySlotKey.encode(1, 2)))
	assert_true(LobbySlotKey.is_spectator(LobbySlotKey.encode(LobbySlotKey.SPECTATOR_TEAM_ID, 0)))
	assert_true(LobbySlotKey.is_spectator(LobbySlotKey.encode(LobbySlotKey.SPECTATOR_TEAM_ID, 9)))

func test_round_trip_player_keys() -> void:
	for team_id: int in [0, 1]:
		for slot: int in PlayerRules.MAX_PER_TEAM:
			var k: int = LobbySlotKey.encode(team_id, slot)
			assert_eq(LobbySlotKey.team_id(k), team_id)
			assert_eq(LobbySlotKey.slot(k), slot)

func test_round_trip_spectator_keys() -> void:
	for slot: int in 6:
		var k: int = LobbySlotKey.encode(LobbySlotKey.SPECTATOR_TEAM_ID, slot)
		assert_eq(LobbySlotKey.team_id(k), LobbySlotKey.SPECTATOR_TEAM_ID)
		assert_eq(LobbySlotKey.slot(k), slot)
