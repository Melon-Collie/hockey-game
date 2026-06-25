class_name BotIdentityRegistry

# Loads the curated list of bot identities used when spawning AI players.
# Load order: res://data/bot_identities.json (bundled roster) →
#             empty list (bots fall back to generic "Bot N" / 80+id / slot-based handedness).
#
# Bots are host-authoritative online: only the host reads this file (via
# pick_for_slot, gated behind NetworkManager.send_bot_slot's is_host check),
# and the chosen attributes are replicated to clients through notify_bot_slot,
# spawn_remote_skater, and sync_existing_players. Clients never consult their
# own copy, so the roster can't diverge between machines. There used to be a
# user://bot_identities.json override (a relic of an abandoned "rename your
# bots" idea that predated attributes living in this file); it was removed
# because a host-edited copy could field over-budget bots that bypassed the
# is_within_budget gate human joiners pass.
#
# JSON schema:
#   {
#     "identities": [
#       { "name": "Wayne Gretzky", "number": 99, "is_left_handed": false,
#         "speed": 3, "agility": 5, "hands": 5, "size": 2, "physical": 1, "shot": 5 },
#       ...
#     ]
#   }
#
# Attribute fields are optional; missing values default to LEVEL_MEDIUM so
# older identity files keep loading. A legacy four-attribute file (with the old
# "skill"/"strength" axis) seeds both Shot and Hands from it. Out-of-range values
# are clamped via PlayerAttributes.new() so a typo in JSON doesn't crash the game.
#
# A well-formed file with zero entries is valid — the caller treats an empty
# pool as "use the old deterministic defaults".

const _RES_JSON_PATH: String = "res://data/bot_identities.json"

static var _identities: Array[Dictionary] = []
static var _loaded: bool = false


static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_try_load_from(_RES_JSON_PATH)


static func get_all() -> Array[Dictionary]:
	ensure_loaded()
	return _identities.duplicate()


# Picks an identity for a bot slot at lobby-toggle time. If the configured
# pool has an entry whose name is not in `used_names`, returns one at
# random so successive toggles in the same lobby don't duplicate. When the
# pool is empty or exhausted, returns the generic "Bot N" fallback derived
# from `slot_key` so the lobby card still has something concrete to display.
static func pick_for_slot(slot_key: int, used_names: Array[String]) -> Dictionary:
	ensure_loaded()
	var available: Array[Dictionary] = []
	for entry: Dictionary in _identities:
		if not used_names.has(entry.name):
			available.append(entry)
	if not available.is_empty():
		return available.pick_random()
	return fallback_identity(slot_key)


static func fallback_identity(slot_key: int) -> Dictionary:
	return {
		"name":           "Bot %d" % (slot_key + 1),
		"number":         80 + slot_key,
		"is_left_handed": (slot_key % 3) % 2 == 1,
		"speed":          PlayerAttributes.LEVEL_MEDIUM,
		"agility":        PlayerAttributes.LEVEL_MEDIUM,
		"hands":          PlayerAttributes.LEVEL_MEDIUM,
		"size":           PlayerAttributes.LEVEL_MEDIUM,
		"physical":       PlayerAttributes.LEVEL_MEDIUM,
		"shot":           PlayerAttributes.LEVEL_MEDIUM,
	}


static func _try_load_from(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return false
	var text: String = file.get_as_text()
	file.close()
	var data = JSON.parse_string(text)
	if not data is Dictionary or not data.has("identities"):
		push_error("BotIdentityRegistry: malformed JSON in %s" % path)
		return false
	for entry: Dictionary in data["identities"]:
		var entry_name: String = entry.get("name", "")
		if entry_name.is_empty():
			continue
		# A legacy four-attribute file carries "skill" (or the older "strength");
		# seed both Shot and Hands from it so old user:// copies still load.
		var legacy_skill: int = int(entry.get("skill", entry.get("strength", PlayerAttributes.LEVEL_MEDIUM)))
		_identities.append({
			"name":           entry_name,
			"number":         int(entry.get("number", 0)),
			"is_left_handed": bool(entry.get("is_left_handed", false)),
			"speed":          int(entry.get("speed",    PlayerAttributes.LEVEL_MEDIUM)),
			"agility":        int(entry.get("agility",  PlayerAttributes.LEVEL_MEDIUM)),
			"hands":          int(entry.get("hands",    legacy_skill)),
			"size":           int(entry.get("size",     PlayerAttributes.LEVEL_MEDIUM)),
			"physical":       int(entry.get("physical", PlayerAttributes.LEVEL_MEDIUM)),
			"shot":           int(entry.get("shot",     legacy_skill)),
		})
	return true
