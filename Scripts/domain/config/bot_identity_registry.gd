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
# Budget is ENFORCED on load (normalize_entry → is_within_budget): a custom bot
# can't be handed more than the point-buy budget a human player gets. An
# over-budget or out-of-range build resets to all-medium (a legal exact-budget
# build), so the bot keeps its identity but loses the illegal stats — the host
# can theme their roster, but can't field a 5/5/5/5/5/5 super-bot.
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
# are clamped and over-budget builds reset (see normalize_entry) so a typo in
# JSON neither crashes the game nor grants an illegal build.
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
		if String(entry.get("name", "")).is_empty():
			continue
		_identities.append(normalize_entry(entry))
	return true


# Turns one raw JSON entry into a canonical identity dict: applies the legacy
# four-attribute seed, defaults missing fields to LEVEL_MEDIUM, and ENFORCES the
# point-buy budget. An over-budget or out-of-range attribute spread (the only
# way a custom roster could grant unearned power) resets all six attributes to
# all-medium — a legal exact-budget build — while keeping the bot's
# name/number/handedness. Extracted from _try_load_from so the budget rule is
# unit-testable without touching the filesystem.
static func normalize_entry(entry: Dictionary) -> Dictionary:
	var entry_name: String = entry.get("name", "")
	# A legacy four-attribute file carries "skill" (or the older "strength");
	# seed both Shot and Hands from it so old user:// copies still load.
	var legacy_skill: int = int(entry.get("skill", entry.get("strength", PlayerAttributes.LEVEL_MEDIUM)))
	var speed: int    = int(entry.get("speed",    PlayerAttributes.LEVEL_MEDIUM))
	var agility: int  = int(entry.get("agility",  PlayerAttributes.LEVEL_MEDIUM))
	var hands: int    = int(entry.get("hands",    legacy_skill))
	var size: int     = int(entry.get("size",     PlayerAttributes.LEVEL_MEDIUM))
	var physical: int = int(entry.get("physical", PlayerAttributes.LEVEL_MEDIUM))
	var shot: int     = int(entry.get("shot",     legacy_skill))
	if not PlayerAttributes.is_within_budget(speed, agility, hands, size, physical, shot):
		push_warning("BotIdentityRegistry: '%s' has an over-budget build; resetting to all-medium" % entry_name)
		speed = PlayerAttributes.LEVEL_MEDIUM
		agility = PlayerAttributes.LEVEL_MEDIUM
		hands = PlayerAttributes.LEVEL_MEDIUM
		size = PlayerAttributes.LEVEL_MEDIUM
		physical = PlayerAttributes.LEVEL_MEDIUM
		shot = PlayerAttributes.LEVEL_MEDIUM
	# Optional casting hint: which lineup slot this identity suits (see
	# PlayerRules.POSITION_NAMES). Unknown/missing → "" (fills any slot).
	var position: String = String(entry.get("position", "")).to_upper()
	if position not in PlayerRules.POSITION_NAMES:
		position = ""
	return {
		"name":           entry_name,
		"number":         int(entry.get("number", 0)),
		"is_left_handed": bool(entry.get("is_left_handed", false)),
		"position":       position,
		"speed":          speed,
		"agility":        agility,
		"hands":          hands,
		"size":           size,
		"physical":       physical,
		"shot":           shot,
	}
