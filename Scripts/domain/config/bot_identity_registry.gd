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
# The legal-shape rule is ENFORCED on load (normalize_entry → is_legal_build): a
# custom bot must spend the same one-strong-one-weak shape a human does (or all-
# average). An illegal build (a strength with no matching weakness) or an out-of-
# range value resets to all-average, so the bot keeps its identity but loses the
# illegal stats — the host can theme their roster, but can't field a super-bot.
#
# JSON schema (native height + three tiers; height 1..5 = 5'8"..6'7", each tier
# 1=weak / 2=average / 3=strong):
#   {
#     "identities": [
#       { "name": "Wayne Gretzky", "number": 99, "is_left_handed": false,
#         "height": 2, "skating": 2, "skill": 3, "checking": 1, "position": "C" },
#       ...
#     ]
#   }
#
# Fields are optional; missing values default to medium. A legacy six-attribute
# file (speed/agility/hands/size/physical/shot, or the older skill/strength axis)
# is migrated on load via PlayerAttributes.migrate_legacy, so old user:// rosters
# keep working. Illegal or out-of-range builds reset (see normalize_entry) so a
# typo in JSON neither crashes the game nor grants an unearned build.
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
		"skating":        PlayerAttributes.TIER_AVERAGE,
		"skill":          PlayerAttributes.TIER_AVERAGE,
		"checking":       PlayerAttributes.TIER_AVERAGE,
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


# Turns one raw JSON entry into a canonical identity dict: reads the native
# height + three-tier fields (migrating a legacy six-attribute entry via
# PlayerAttributes.migrate_legacy so old user:// rosters keep loading), then
# ENFORCES the legal-shape rule (one-strong-one-weak / all-average — see
# is_legal_build). An illegal or out-of-range build (the only way a custom roster
# could grant unearned power — e.g. a strength with no weakness) resets to
# all-average while keeping the bot's name/number/handedness. Extracted from
# _try_load_from so the rule is unit-testable without touching the filesystem.
static func normalize_entry(entry: Dictionary) -> Dictionary:
	var entry_name: String = entry.get("name", "")
	var height: int
	var skating: int
	var skill: int
	var checking: int
	var has_native: bool = entry.has("height") or entry.has("skating") or entry.has("checking")
	var has_legacy: bool = entry.has("speed") or entry.has("agility") or entry.has("size") \
			or entry.has("physical") or entry.has("shot") or entry.has("strength")
	if has_native or not has_legacy:
		# Native height + three-tier keys (or a name-only entry with no attributes,
		# which loads as all-average). Missing native keys default to medium.
		height   = int(entry.get("height",   PlayerAttributes.HEIGHT_MEDIUM))
		skating  = int(entry.get("skating",  PlayerAttributes.TIER_AVERAGE))
		skill    = int(entry.get("skill",    PlayerAttributes.TIER_AVERAGE))
		checking = int(entry.get("checking", PlayerAttributes.TIER_AVERAGE))
	else:
		# Legacy six-attribute (or four-attribute) roster.
		var legacy_skill: int = int(entry.get("skill", entry.get("strength", 3)))
		var migrated := PlayerAttributes.migrate_legacy(
				int(entry.get("speed", 3)), int(entry.get("agility", 3)),
				int(entry.get("hands", legacy_skill)), int(entry.get("size", 3)),
				int(entry.get("physical", 3)), int(entry.get("shot", legacy_skill)))
		height = migrated.height
		skating = migrated.skating
		skill = migrated.skill
		checking = migrated.checking
	if not PlayerAttributes.is_legal_build(height, skating, skill, checking):
		push_warning("BotIdentityRegistry: '%s' has an illegal build; resetting to all-average" % entry_name)
		height = PlayerAttributes.HEIGHT_MEDIUM
		skating = PlayerAttributes.TIER_AVERAGE
		skill = PlayerAttributes.TIER_AVERAGE
		checking = PlayerAttributes.TIER_AVERAGE
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
		"height":         height,
		"skating":        skating,
		"skill":          skill,
		"checking":       checking,
	}
