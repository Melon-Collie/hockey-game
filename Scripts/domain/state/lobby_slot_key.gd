class_name LobbySlotKey

# Encodes a (team_id, slot) pair into a single int key for the lobby's
# slot dictionary. Players use keys 0..(MAX_PER_TEAM*2 - 1) where
# team_id = key / 3 and slot = key % 3. Spectators use keys
# SPECTATOR_KEY_BASE..(SPECTATOR_KEY_BASE + MAX_SPECTATORS - 1) so they
# never collide with the player range.

const SPECTATOR_KEY_BASE: int = 100


static func encode(team_id: int, slot: int) -> int:
	if team_id == GameRules.SPECTATOR_TEAM_ID:
		return SPECTATOR_KEY_BASE + slot
	return team_id * PlayerRules.MAX_PER_TEAM + slot


static func team_id(key: int) -> int:
	if key >= SPECTATOR_KEY_BASE:
		return GameRules.SPECTATOR_TEAM_ID
	return 1 if key >= PlayerRules.MAX_PER_TEAM else 0


static func slot(key: int) -> int:
	if key >= SPECTATOR_KEY_BASE:
		return key - SPECTATOR_KEY_BASE
	return key % PlayerRules.MAX_PER_TEAM


static func is_spectator(key: int) -> bool:
	return key >= SPECTATOR_KEY_BASE
