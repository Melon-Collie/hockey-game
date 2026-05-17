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


# Returns up to `count` identities, shuffled, with no repeats. Returns fewer
# (or zero) entries when the configured list has fewer than `count` items;
# the caller fills the rest with generic defaults.
static func pick_random(count: int) -> Array[Dictionary]:
	ensure_loaded()
	var pool: Array[Dictionary] = _identities.duplicate()
	pool.shuffle()
	if pool.size() > count:
		pool.resize(count)
	return pool


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
