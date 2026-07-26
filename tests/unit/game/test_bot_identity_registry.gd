extends GutTest

# BotIdentityRegistry — the curated AI roster loaded from
# res://data/bot_identities.json (with an optional editable user:// override).
# Bots spawn from these picks, so a malformed entry would either crash spawning
# or field an impossible body. Bots are host-authoritative online, so the
# host's roster is exactly what every machine plays against — which is why the
# loader COERCES every entry (normalize_entry → the PlayerAttributes
# constructor): under attributes v4 all axes are lateral, so validation is a
# clamp into the body bands rather than a legal-shape rejection.

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


func test_every_bundled_body_is_inside_its_band() -> void:
	# The curated roster should be authored exactly, not silently coerced: every
	# height is a real inches value and every weight sits inside that height's
	# BMI band.
	for entry: Dictionary in _bundled_entries():
		var h: int = int(entry.get("height", PlayerAttributes.HEIGHT_MEDIUM))
		assert_between(h, PlayerAttributes.HEIGHT_MIN, PlayerAttributes.HEIGHT_MAX,
				"bot '%s' height out of range" % entry.get("name", "?"))
		var w: int = int(entry.get("weight", 0))
		assert_between(w, PlayerAttributes.weight_min(h), PlayerAttributes.weight_max(h),
				"bot '%s' weight %d outside the %d\" band" % [entry.get("name", "?"), w, h])


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


func test_bodies_are_distinct() -> void:
	# Identical builds make bots feel samey on the ice. The continuous body
	# plane gives the roster plenty of room for every bot to own its
	# (height, weight, gear) card.
	var seen: Dictionary = {}
	for entry: Dictionary in _bundled_entries():
		var attrs := PlayerAttributes.from_dict(entry)
		var key: String = "%d/%d/%d%d%d%d" % [attrs.height, attrs.weight,
				attrs.profile, attrs.curve, attrs.flex, attrs.length]
		assert_false(seen.has(key),
				"bot '%s' duplicates the build %s" % [entry.get("name", "?"), key])
		seen[key] = true


# ── normalize_entry: the coercion seam for editable rosters ──────────────────

func test_normalize_keeps_an_in_band_build_intact() -> void:
	var norm: Dictionary = BotIdentityRegistry.normalize_entry({
			"name": "Sniper", "number": 9, "is_left_handed": true,
			"height": 70, "weight": 172, "curve": 2})
	assert_eq(norm.name, "Sniper")
	assert_eq(norm.number, 9)
	assert_true(norm.is_left_handed)
	assert_eq(int(norm.height), 70, "in-range height must not be altered")
	assert_eq(int(norm.weight), 172, "in-band weight must not be altered")
	assert_eq(int(norm.curve), PlayerAttributes.CURVE_OPEN)


func test_normalize_coerces_out_of_band_body() -> void:
	# The old cheat vector was an illegal tier shape; the v4 equivalent is an
	# impossible body — it clamps to the nearest legal one, keeping the identity.
	var norm: Dictionary = BotIdentityRegistry.normalize_entry({
			"name": "Tank", "number": 1, "height": 99, "weight": 500})
	assert_eq(norm.name, "Tank", "identity is preserved")
	assert_eq(int(norm.height), PlayerAttributes.HEIGHT_MAX)
	assert_eq(int(norm.weight), PlayerAttributes.weight_max(PlayerAttributes.HEIGHT_MAX))
	var stringbean: Dictionary = BotIdentityRegistry.normalize_entry({
			"name": "Bean", "height": 79, "weight": 150})
	assert_eq(int(stringbean.weight), PlayerAttributes.weight_min(79),
			"underweight clamps to the band floor")


func test_normalize_migrates_tier_era_entry() -> void:
	# A tier-era roster (height step + skating/skill/checking) migrates through
	# PlayerAttributes.migrate_tiers: strong Checking → heavier frame + long stick.
	var norm: Dictionary = BotIdentityRegistry.normalize_entry({
			"name": "OldPohl", "height": 5, "skating": 1, "skill": 2, "checking": 3})
	assert_eq(int(norm.height), 79, "legacy 1..5 step → inches")
	assert_eq(int(norm.weight), PlayerAttributes.weight_for_frame_t(79, 0.75))
	assert_eq(int(norm.length), PlayerAttributes.LENGTH_LONG)


func test_normalize_migrates_legacy_six_attribute_entry() -> void:
	# The oldest six-attribute shape still loads: a size-5 / physical-5
	# enforcer becomes tall + heavy.
	var norm: Dictionary = BotIdentityRegistry.normalize_entry({
			"name": "Legacy", "speed": 2, "agility": 1, "hands": 2, "size": 5,
			"physical": 5, "shot": 4})
	assert_eq(int(norm.height), 79, "legacy size → height")
	assert_gt(int(norm.weight), PlayerAttributes.weight_neutral(79),
			"physical-heavy legacy build → heavier than neutral")


func test_normalize_defaults_missing_attributes_to_neutral() -> void:
	# A name-only entry (the "rename your bots" shape) loads as the neutral build.
	var norm: Dictionary = BotIdentityRegistry.normalize_entry({"name": "NameOnly"})
	assert_eq(int(norm.height), PlayerAttributes.HEIGHT_MEDIUM)
	assert_eq(int(norm.weight), int(PlayerAttributes.NEUTRAL_WEIGHT_LBS))
	for slot: String in ["profile", "curve", "flex", "length"]:
		assert_eq(int(norm[slot]), PlayerAttributes.GEAR_BALANCED)


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
