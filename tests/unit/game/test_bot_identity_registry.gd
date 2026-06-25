extends GutTest

# BotIdentityRegistry — the curated AI roster loaded from
# res://data/bot_identities.json. Bots spawn from these picks, so a malformed
# or over-budget entry would either crash spawning or hand a bot an illegal
# build that a human player could never make. These tests pin the contract on
# the BUNDLED defaults (the registry also accepts a user:// override, which is
# the player's own business and not validated here).

const _RES_JSON_PATH: String = "res://data/bot_identities.json"


# Parse the bundled file directly rather than going through the registry's
# static cache: ensure_loaded() prefers user://bot_identities.json if present,
# and we specifically want to assert the shipped defaults.
func _bundled_entries() -> Array:
	var file := FileAccess.open(_RES_JSON_PATH, FileAccess.READ)
	assert_not_null(file, "bundled %s must exist" % _RES_JSON_PATH)
	if file == null:
		return []
	var text: String = file.get_as_text()
	file.close()
	var data: Variant = JSON.parse_string(text)
	assert_true(data is Dictionary and data.has("identities"),
			"%s must be a Dictionary with an 'identities' array" % _RES_JSON_PATH)
	return (data as Dictionary).get("identities", [])


func test_bundled_file_has_a_full_roster() -> void:
	# Sanity floor: the lobby toggles through these without repeating, so a
	# healthy pool needs comfortably more than one 3v3 worth of bots.
	assert_gt(_bundled_entries().size(), 12,
			"expected a sizeable curated bot pool")


func test_every_bundled_build_is_within_budget() -> void:
	# Bots must obey the same point-buy budget as human players — no freebies.
	for entry: Dictionary in _bundled_entries():
		var legal: bool = PlayerAttributes.is_within_budget(
				int(entry.get("speed",    PlayerAttributes.LEVEL_MEDIUM)),
				int(entry.get("agility",  PlayerAttributes.LEVEL_MEDIUM)),
				int(entry.get("hands",    PlayerAttributes.LEVEL_MEDIUM)),
				int(entry.get("size",     PlayerAttributes.LEVEL_MEDIUM)),
				int(entry.get("physical", PlayerAttributes.LEVEL_MEDIUM)),
				int(entry.get("shot",     PlayerAttributes.LEVEL_MEDIUM)))
		assert_true(legal,
				"bot '%s' has an over-budget or out-of-range build" % entry.get("name", "?"))


func test_bundled_builds_spend_the_full_budget() -> void:
	# Curated archetypes should be fully-realized builds (exact spend), not
	# accidentally under-spent — that's the difference between a designed bot
	# and a typo. (Humans may under-spend; the curated roster shouldn't.)
	for entry: Dictionary in _bundled_entries():
		var spend: int = (
				int(entry.get("speed",    PlayerAttributes.LEVEL_MEDIUM))
				+ int(entry.get("agility",  PlayerAttributes.LEVEL_MEDIUM))
				+ int(entry.get("hands",    PlayerAttributes.LEVEL_MEDIUM))
				+ int(entry.get("size",     PlayerAttributes.LEVEL_MEDIUM))
				+ int(entry.get("physical", PlayerAttributes.LEVEL_MEDIUM))
				+ int(entry.get("shot",     PlayerAttributes.LEVEL_MEDIUM)))
		assert_eq(spend, PlayerAttributes.BUDGET,
				"bot '%s' should spend the full budget (%d)" % [entry.get("name", "?"), PlayerAttributes.BUDGET])


func test_names_and_numbers_are_unique() -> void:
	# pick_for_slot() dedupes by name, and jersey numbers should be distinct so
	# two bots on the ice never collide visually.
	var seen_names: Dictionary = {}
	var seen_numbers: Dictionary = {}
	for entry: Dictionary in _bundled_entries():
		var entry_name: String = entry.get("name", "")
		assert_false(seen_names.has(entry_name),
				"duplicate bot name '%s'" % entry_name)
		seen_names[entry_name] = true
		var number: int = int(entry.get("number", 0))
		assert_false(seen_numbers.has(number),
				"duplicate jersey number %d (%s)" % [number, entry_name])
		seen_numbers[number] = true


func test_stat_lines_are_distinct() -> void:
	# Identical stat spreads make bots feel samey on the ice — the migrated
	# roster had literal duplicates. Each archetype should be its own build.
	var seen: Dictionary = {}
	for entry: Dictionary in _bundled_entries():
		var key: String = "%d/%d/%d/%d/%d/%d" % [
				int(entry.get("speed",    PlayerAttributes.LEVEL_MEDIUM)),
				int(entry.get("agility",  PlayerAttributes.LEVEL_MEDIUM)),
				int(entry.get("hands",    PlayerAttributes.LEVEL_MEDIUM)),
				int(entry.get("size",     PlayerAttributes.LEVEL_MEDIUM)),
				int(entry.get("physical", PlayerAttributes.LEVEL_MEDIUM)),
				int(entry.get("shot",     PlayerAttributes.LEVEL_MEDIUM))]
		assert_false(seen.has(key),
				"bot '%s' duplicates the stat line %s" % [entry.get("name", "?"), key])
		seen[key] = true
