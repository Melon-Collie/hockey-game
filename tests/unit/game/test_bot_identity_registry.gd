extends GutTest

# BotIdentityRegistry — the curated AI roster loaded from
# res://data/bot_identities.json (with an optional editable user:// override).
# Bots spawn from these picks, so a malformed or over-budget entry would either
# crash spawning or hand a bot an illegal build that a human player could never
# make. Bots are host-authoritative online, so the host's roster is exactly
# what every machine plays against — which is why the loader enforces the
# point-buy budget (normalize_entry) even on a hand-edited custom file.

const _RES_JSON_PATH: String = "res://data/bot_identities.json"


# Parse the bundled file directly rather than going through the registry's
# static cache so a prior test that called ensure_loaded() can't mask a
# malformed file behind a stale parse.
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


# ── normalize_entry: the budget-enforcement seam for editable rosters ─────────

func test_normalize_keeps_a_legal_build_intact() -> void:
	# A within-budget custom bot passes through untouched.
	var norm: Dictionary = BotIdentityRegistry.normalize_entry({
			"name": "Sniper", "number": 9, "is_left_handed": true,
			"speed": 3, "agility": 3, "hands": 4, "size": 2, "physical": 1, "shot": 5})
	assert_eq(norm.name, "Sniper")
	assert_eq(norm.number, 9)
	assert_true(norm.is_left_handed)
	assert_eq(norm.shot, 5, "legal build must not be altered")
	assert_eq(norm.physical, 1)


func test_normalize_resets_over_budget_build_to_all_medium() -> void:
	# The cheat vector: a hand-edited file giving a bot maxed everything. The
	# loader resets the attributes to all-medium but keeps the identity.
	var norm: Dictionary = BotIdentityRegistry.normalize_entry({
			"name": "Cheater", "number": 1,
			"speed": 5, "agility": 5, "hands": 5, "size": 5, "physical": 5, "shot": 5})
	assert_eq(norm.name, "Cheater", "identity is preserved")
	assert_eq(norm.number, 1)
	for axis: String in ["speed", "agility", "hands", "size", "physical", "shot"]:
		assert_eq(int(norm[axis]), PlayerAttributes.LEVEL_MEDIUM,
				"over-budget '%s' should reset to medium" % axis)


func test_normalize_resets_out_of_range_build() -> void:
	# Out-of-range levels (a typo like 9) also fail is_within_budget and reset.
	var norm: Dictionary = BotIdentityRegistry.normalize_entry({
			"name": "Typo", "speed": 9, "agility": 3, "hands": 3, "size": 1, "physical": 1, "shot": 1})
	assert_eq(int(norm.speed), PlayerAttributes.LEVEL_MEDIUM)


func test_normalize_seeds_legacy_skill_into_shot_and_hands() -> void:
	# A legacy four-attribute file (old "skill" axis) seeds both offensive heirs.
	var norm: Dictionary = BotIdentityRegistry.normalize_entry({
			"name": "Legacy", "speed": 2, "agility": 2, "size": 2, "physical": 2, "skill": 4})
	assert_eq(int(norm.hands), 4, "legacy skill seeds hands")
	assert_eq(int(norm.shot), 4, "legacy skill seeds shot")


func test_normalize_defaults_missing_attributes_to_medium() -> void:
	# A name-only entry (the old "rename your bots" shape) loads as all-medium.
	var norm: Dictionary = BotIdentityRegistry.normalize_entry({"name": "NameOnly"})
	for axis: String in ["speed", "agility", "hands", "size", "physical", "shot"]:
		assert_eq(int(norm[axis]), PlayerAttributes.LEVEL_MEDIUM)


func test_every_bundled_entry_has_a_valid_position() -> void:
	# 5v5 casting: each identity declares the lineup slot it suits.
	for entry: Dictionary in _bundled_entries():
		var position: String = String(entry.get("position", ""))
		assert_true(position in PlayerRules.POSITION_NAMES,
				"bot '%s' has invalid position '%s'" % [entry.get("name", "?"), position])


func test_bundled_pool_covers_every_position() -> void:
	# A full 5v5 bot game casts 10 bots across 5 positions per team; the pool
	# needs at least two of each so pick_for_slot never runs a position dry
	# on the first team.
	var counts: Dictionary = {}
	for entry: Dictionary in _bundled_entries():
		var position: String = String(entry.get("position", ""))
		counts[position] = int(counts.get(position, 0)) + 1
	for position: String in PlayerRules.POSITION_NAMES:
		assert_gte(int(counts.get(position, 0)), 2,
				"need at least two bundled '%s' identities" % position)


func test_normalize_validates_position() -> void:
	var with_pos: Dictionary = BotIdentityRegistry.normalize_entry(
			{"name": "T", "position": "ld"})
	assert_eq(with_pos.position, "LD", "position is case-normalized")
	var junk: Dictionary = BotIdentityRegistry.normalize_entry(
			{"name": "T", "position": "GOALIE"})
	assert_eq(junk.position, "", "unknown position clears to fill-any")
	var missing: Dictionary = BotIdentityRegistry.normalize_entry({"name": "T"})
	assert_eq(missing.position, "", "missing position defaults to fill-any")


func test_pick_for_slot_prefers_matching_position() -> void:
	# Slot key 3 = home LD. With the whole pool available the pick must come
	# from the LD-tagged identities.
	var used: Array[String] = []
	for _i: int in 20:
		var picked: Dictionary = BotIdentityRegistry.pick_for_slot(3, used)
		assert_eq(picked.get("position", ""), "LD",
				"slot 3 should cast an LD archetype while any remain")
		used.clear()


func test_pick_for_slot_falls_back_when_position_pool_exhausted() -> void:
	# Consume every LD identity; the next LD pick must still return someone.
	var used: Array[String] = []
	for entry: Dictionary in BotIdentityRegistry.get_all():
		if entry.get("position", "") == "LD":
			used.append(String(entry.name))
	var picked: Dictionary = BotIdentityRegistry.pick_for_slot(3, used)
	assert_false(String(picked.get("name", "")).is_empty())
	assert_ne(picked.get("position", ""), "LD",
			"all LDs were used; fallback casts across positions")
