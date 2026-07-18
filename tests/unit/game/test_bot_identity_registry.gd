extends GutTest

# BotIdentityRegistry — the curated AI roster loaded from
# res://data/bot_identities.json (with an optional editable user:// override).
# Bots spawn from these picks, so a malformed or illegal entry would either
# crash spawning or hand a bot a build a human player could never make. Bots are
# host-authoritative online, so the host's roster is exactly what every machine
# plays against — which is why the loader enforces the legal-shape rule
# (normalize_entry → is_legal_build) even on a hand-edited custom file.

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


func _entry_levels(entry: Dictionary) -> Array:
	return [
		int(entry.get("height",   PlayerAttributes.HEIGHT_MEDIUM)),
		int(entry.get("skating",  PlayerAttributes.TIER_AVERAGE)),
		int(entry.get("skill",    PlayerAttributes.TIER_AVERAGE)),
		int(entry.get("checking", PlayerAttributes.TIER_AVERAGE)),
	]


func test_every_bundled_build_is_legal() -> void:
	# Bots must obey the same legal-shape rule as human players — no freebies.
	for entry: Dictionary in _bundled_entries():
		var lv: Array = _entry_levels(entry)
		assert_true(PlayerAttributes.is_legal_build(lv[0], lv[1], lv[2], lv[3]),
				"bot '%s' has an illegal or out-of-range build" % entry.get("name", "?"))


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
	# Identical builds make bots feel samey on the ice. Under the height + tier
	# model the space is smaller (5 heights × 7 shapes = 35), but the curated
	# roster should still give each bot its own (height, shape).
	var seen: Dictionary = {}
	for entry: Dictionary in _bundled_entries():
		var lv: Array = _entry_levels(entry)
		var key: String = "%d/%d/%d/%d" % [lv[0], lv[1], lv[2], lv[3]]
		assert_false(seen.has(key),
				"bot '%s' duplicates the build %s" % [entry.get("name", "?"), key])
		seen[key] = true


# ── normalize_entry: the budget-enforcement seam for editable rosters ─────────

func test_normalize_keeps_a_legal_build_intact() -> void:
	# A legal (one-strong-one-weak) custom bot passes through untouched.
	var norm: Dictionary = BotIdentityRegistry.normalize_entry({
			"name": "Sniper", "number": 9, "is_left_handed": true,
			"height": 2, "skating": 2, "skill": 3, "checking": 1})
	assert_eq(norm.name, "Sniper")
	assert_eq(norm.number, 9)
	assert_true(norm.is_left_handed)
	assert_eq(norm.height, 2, "legal build must not be altered")
	assert_eq(norm.skill, PlayerAttributes.TIER_STRONG)
	assert_eq(norm.checking, PlayerAttributes.TIER_WEAK)


func test_normalize_resets_illegal_build_to_all_average() -> void:
	# The cheat vector: a hand-edited file giving a bot two strengths and no
	# weakness. The loader resets the tiers to all-average but keeps the identity.
	var norm: Dictionary = BotIdentityRegistry.normalize_entry({
			"name": "Cheater", "number": 1,
			"height": 5, "skating": 3, "skill": 3, "checking": 3})
	assert_eq(norm.name, "Cheater", "identity is preserved")
	assert_eq(norm.number, 1)
	assert_eq(int(norm.skating), PlayerAttributes.TIER_AVERAGE)
	assert_eq(int(norm.skill), PlayerAttributes.TIER_AVERAGE)
	assert_eq(int(norm.checking), PlayerAttributes.TIER_AVERAGE)


func test_normalize_resets_out_of_range_build() -> void:
	# Out-of-range levels (a typo like height 9) also fail is_legal_build and reset.
	var norm: Dictionary = BotIdentityRegistry.normalize_entry({
			"name": "Typo", "height": 9, "skating": 3, "skill": 2, "checking": 1})
	assert_eq(int(norm.height), PlayerAttributes.HEIGHT_MEDIUM)


func test_normalize_migrates_legacy_six_attribute_entry() -> void:
	# A legacy six-attribute file is migrated: a size-5 / physical-5 enforcer
	# becomes tall + Checking-strong.
	var norm: Dictionary = BotIdentityRegistry.normalize_entry({
			"name": "Legacy", "speed": 2, "agility": 1, "hands": 2, "size": 5, "physical": 5, "shot": 4})
	assert_eq(int(norm.height), 5, "legacy size → height")
	assert_eq(int(norm.checking), PlayerAttributes.TIER_STRONG, "physical → Checking strong")


func test_normalize_defaults_missing_attributes_to_average() -> void:
	# A name-only entry (the "rename your bots" shape) loads as all-average.
	var norm: Dictionary = BotIdentityRegistry.normalize_entry({"name": "NameOnly"})
	assert_eq(int(norm.height), PlayerAttributes.HEIGHT_MEDIUM)
	for axis: String in ["skating", "skill", "checking"]:
		assert_eq(int(norm[axis]), PlayerAttributes.TIER_AVERAGE)


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
