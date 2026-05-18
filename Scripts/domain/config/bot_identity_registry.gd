class_name BotIdentityRegistry

# Loads the curated list of bot identities used when spawning AI players.
# Load order: user://bot_identities.json (player's editable copy) →
#             res://data/bot_identities.json (bundled defaults) →
#             empty list (bots fall back to generic "Bot N" / 80+id / slot-based handedness).
#
# JSON schema:
#   {
#     "identities": [
#       { "name": "Wayne Gretzky", "number": 99, "is_left_handed": false },
#       ...
#     ]
#   }
#
# A well-formed file with zero entries is valid — the caller treats an empty
# pool as "use the old deterministic defaults".

const _USER_JSON_PATH: String = "user://bot_identities.json"
const _RES_JSON_PATH:  String = "res://data/bot_identities.json"

static var _identities: Array[Dictionary] = []
static var _loaded: bool = false


static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	for path: String in [_USER_JSON_PATH, _RES_JSON_PATH]:
		if _try_load_from(path):
			return


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
		_identities.append({
			"name":           entry_name,
			"number":         int(entry.get("number", 0)),
			"is_left_handed": bool(entry.get("is_left_handed", false)),
		})
	return true
