class_name BotIdentityRegistry

# Loads the curated list of bot identities used when spawning AI players.
# Load order: user://bot_identities.json (player's editable roster) →
#             res://data/bot_identities.json (bundled roster) →
#             empty list (bots fall back to generic "Bot N" / 80+id / slot-based handedness).
#
# Editable rosters are a feature: a host can craft their own bots — custom
# names, numbers, handedness, and attribute archetypes — by dropping a
# user://bot_identities.json next to their save. Bots are host-authoritative
# online: only the host reads this file (pick_for_slot is gated behind
# NetworkManager.send_bot_slot's is_host check), and the chosen attributes are
# replicated to clients through notify_bot_slot, spawn_remote_skater, and
# sync_existing_players. Clients never consult their own copy, so the host's
# roster is exactly what the whole lobby plays against — no divergence.
#
# Builds are COERCED on load (normalize_entry → the PlayerAttributes
# constructor): v4 axes are all lateral, so there is no legal shape to enforce —
# an out-of-range height/weight/gear value clamps to the nearest legal body
# (weight into the height's BMI band), so a typo neither crashes the game nor
# fields an impossible frame. A super-bot is unrepresentable by construction.
#
# JSON schema (attributes v4, body + gear). Height may be a raw inches value
# (68..79 = 5'8"..6'7") or a legacy 1..5 step (mapped onto the anchor heights);
# weight is lbs inside the height's band (omit for the height's neutral frame);
# gear slots are 0/1/2 with 1 = balanced (profile: 0 agility / 2 power;
# curve: 0 closed / 2 open; flex: 0 whippy / 2 stiff; length: 0 short / 2 long
# — no gameplay effect yet, cosmetic/forward-compat):
#   {
#     "identities": [
#       { "name": "Wayne Gretzky", "number": 99, "is_left_handed": false,
#         "height": 72, "weight": 185, "curve": 2, "position": "C" },
#       ...
#     ]
#   }
#
# Fields are optional; missing values default to the neutral build. A tier-era
# file (skating/skill/checking) migrates via PlayerAttributes.migrate_tiers and
# the oldest six-attribute files (speed/agility/hands/size/physical/shot) via
# migrate_legacy, so old user:// rosters keep working.
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
# random so successive toggles in the same lobby don't duplicate — preferring
# identities whose `position` matches the slot's position (a defenseman
# archetype fills the LD card), falling back to any unused identity when the
# position pool is exhausted. When the whole pool is spent, returns the
# generic "Bot N" fallback derived from `slot_key` so the lobby card still
# has something concrete to display.
static func pick_for_slot(slot_key: int, used_names: Array[String]) -> Dictionary:
	ensure_loaded()
	var slot_position: String = PlayerRules.position_name(LobbySlotKey.slot(slot_key))
	var available: Array[Dictionary] = []
	var position_matches: Array[Dictionary] = []
	for entry: Dictionary in _identities:
		if used_names.has(entry.name):
			continue
		available.append(entry)
		if not slot_position.is_empty() and entry.get("position", "") == slot_position:
			position_matches.append(entry)
	if not position_matches.is_empty():
		return position_matches.pick_random()
	if not available.is_empty():
		return available.pick_random()
	return fallback_identity(slot_key)


static func fallback_identity(slot_key: int) -> Dictionary:
	return {
		"name":           "Bot %d" % (slot_key + 1),
		"number":         80 + slot_key,
		"is_left_handed": LobbySlotKey.slot(slot_key) % 2 == 1,
		"position":       PlayerRules.position_name(LobbySlotKey.slot(slot_key)),
		"height":         PlayerAttributes.HEIGHT_MEDIUM,
		"weight":         int(PlayerAttributes.NEUTRAL_WEIGHT_LBS),
		"profile":        PlayerAttributes.GEAR_BALANCED,
		"curve":          PlayerAttributes.GEAR_BALANCED,
		"flex":           PlayerAttributes.GEAR_BALANCED,
		"length":         PlayerAttributes.GEAR_BALANCED,
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
		if String(entry.get("name", "")).is_empty():
			continue
		_identities.append(normalize_entry(entry))
	return true


# Turns one raw JSON entry into a canonical identity dict: routes the
# attribute keys through PlayerAttributes.from_dict (which handles native v4
# body+gear keys, tier-era keys via migrate_tiers, and legacy six-attribute
# keys via migrate_legacy) and takes the COERCED values back — out-of-range
# height/weight/gear lands on the nearest legal body rather than being
# rejected. Extracted from _try_load_from so the rule is unit-testable
# without touching the filesystem.
static func normalize_entry(entry: Dictionary) -> Dictionary:
	var attrs := PlayerAttributes.from_dict(entry)
	# Optional casting hint: which lineup slot this identity suits (see
	# PlayerRules.POSITION_NAMES). Unknown/missing → "" (fills any slot).
	var position: String = String(entry.get("position", "")).to_upper()
	if position not in PlayerRules.POSITION_NAMES:
		position = ""
	var out: Dictionary = attrs.to_dict()
	out["name"] = entry.get("name", "")
	out["number"] = int(entry.get("number", 0))
	out["is_left_handed"] = bool(entry.get("is_left_handed", false))
	out["position"] = position
	return out
