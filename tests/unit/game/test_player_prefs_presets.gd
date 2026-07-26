extends GutTest

# PlayerPrefs attribute-build presets.
# -----------------------------------
# The player keeps up to MAX_PRESETS named builds and switches which one is
# ACTIVE; the flat attr_* fields (what get_player_attributes() and thus the
# online join handshake read) always mirror the active preset. A build is the
# v4 body+gear model: HEIGHT in inches (a legacy 1..5 step coerces onto the
# anchor heights, e.g. 5 → 79"), WEIGHT in lbs (clamped to the height's BMI
# band; 0 → the height's neutral frame), and four gear slots. These tests pin
# the seeding/sync, the active-index bookkeeping through add/delete, and the
# stored-array parse (which must survive a hand-corrupted / cloud-synced config
# without crashing, and must migrate tier-era and six-attribute presets).
#
# PlayerPrefs is the autoload (extends Node, no class_name). We instantiate the
# script directly and never add it to the tree, so _ready()/_load() never fire
# (presets start empty, no disk read) and the mutators — which are pure
# in-memory, callers persist separately — never write over real preferences.cfg.

const PlayerPrefsScript = preload("res://Scripts/game/player_prefs.gd")


func _fresh() -> Node:
	return autofree(PlayerPrefsScript.new())


func _attrs(h: int, w: int) -> PlayerAttributes:
	return PlayerAttributes.from_levels(h, w)


func _active_attrs(p: Node) -> PlayerAttributes:
	return p.get_presets()[p.get_active_preset_index()]["attrs"]


# attr_presets is typed Array[Dictionary]; a bare literal is an untyped Array and
# won't assign. Funnel entries through a typed local.
func _set_presets(p: Node, entries: Array) -> void:
	var out: Array[Dictionary] = []
	for e: Dictionary in entries:
		out.append(e)
	p.attr_presets = out


func _set_flat(p: Node, h: int, w: int) -> void:
	p.attr_height = h
	p.attr_weight = w
	p.attr_profile = PlayerAttributes.GEAR_BALANCED
	p.attr_curve = PlayerAttributes.GEAR_BALANCED
	p.attr_flex = PlayerAttributes.GEAR_BALANCED
	p.attr_length = PlayerAttributes.GEAR_BALANCED


# ── _finalize_presets: seeding & sync ────────────────────────────────────────

func test_finalize_seeds_default_from_flat_when_empty() -> void:
	var p: Node = _fresh()
	_set_flat(p, 79, 250)
	p._finalize_presets()
	assert_eq(p.get_presets().size(), 1, "seeds exactly one preset")
	assert_eq(p.get_active_preset_index(), 0)
	assert_eq(p.get_presets()[0]["name"], "Default")
	assert_true(_active_attrs(p).equals(_attrs(79, 250)),
			"Default preset carries the flat build verbatim")


func test_finalize_syncs_flat_from_active_when_presets_present() -> void:
	var p: Node = _fresh()
	_set_presets(p, [
		p._make_preset("A", _attrs(68, 162)),
		p._make_preset("B", _attrs(79, 250)),
	])
	p.attr_active_preset = 1
	# Flat fields deliberately stale — finalize must overwrite them from active.
	p.attr_height = 73
	p._finalize_presets()
	assert_true(p.get_player_attributes().equals(_attrs(79, 250)),
			"flat build re-synced from the active preset")


func test_finalize_clamps_out_of_range_active_index() -> void:
	var p: Node = _fresh()
	_set_presets(p, [
		p._make_preset("A", _attrs(73, 201)),
		p._make_preset("B", _attrs(68, 162)),
	])
	p.attr_active_preset = 9
	p._finalize_presets()
	assert_eq(p.get_active_preset_index(), 1, "clamps to last valid preset")


# ── set_active_preset ────────────────────────────────────────────────────────

func test_set_active_preset_switches_flat_build() -> void:
	var p: Node = _fresh()
	_set_presets(p, [
		p._make_preset("A", _attrs(68, 162)),
		p._make_preset("B", _attrs(79, 250)),
	])
	p.attr_active_preset = 0
	p._sync_flat_from_active()
	p.set_active_preset(1)
	assert_eq(p.get_active_preset_index(), 1)
	assert_true(p.get_player_attributes().equals(_attrs(79, 250)))


func test_set_active_preset_ignores_invalid_index() -> void:
	var p: Node = _fresh()
	p._finalize_presets()  # one Default preset, active 0
	p.set_active_preset(7)
	assert_eq(p.get_active_preset_index(), 0, "out-of-range index is a no-op")
	p.set_active_preset(-1)
	assert_eq(p.get_active_preset_index(), 0)


# ── save_preset ──────────────────────────────────────────────────────────────

func test_save_preset_overwrites_active_and_syncs_flat() -> void:
	var p: Node = _fresh()
	p._finalize_presets()
	p.save_preset(0, _attrs(76, 210), "Sniper")
	assert_eq(p.get_presets()[0]["name"], "Sniper")
	assert_true(p.get_player_attributes().equals(_attrs(76, 210)),
			"editing the active preset updates the flat mirror")


func test_save_preset_on_inactive_does_not_touch_flat() -> void:
	var p: Node = _fresh()
	_set_presets(p, [
		p._make_preset("A", _attrs(73, 201)),
		p._make_preset("B", _attrs(68, 162)),
	])
	p.attr_active_preset = 0
	p._sync_flat_from_active()
	p.save_preset(1, _attrs(79, 250))
	assert_true(p.get_player_attributes().equals(_attrs(73, 201)),
			"editing an inactive preset leaves the active build alone")


# ── add_preset ───────────────────────────────────────────────────────────────

func test_add_preset_defaults_to_copy_of_active_build() -> void:
	var p: Node = _fresh()
	_set_flat(p, 79, 250)
	p._finalize_presets()
	var idx: int = p.add_preset()
	assert_eq(idx, 1)
	assert_true(p.get_presets()[1]["attrs"].equals(_attrs(79, 250)))
	# Independent object: mutating the new preset must not bleed into the source.
	p.get_presets()[1]["attrs"].height = 68
	assert_eq(p.get_presets()[0]["attrs"].height, 79, "presets don't share instances")


func test_add_preset_uses_sequential_default_name() -> void:
	var p: Node = _fresh()
	p._finalize_presets()
	p.add_preset()
	assert_eq(p.get_presets()[1]["name"], "Build 2")


func test_add_preset_returns_negative_one_at_cap() -> void:
	var p: Node = _fresh()
	p._finalize_presets()
	while p.get_presets().size() < PlayerPrefsScript.MAX_PRESETS:
		assert_gt(p.add_preset(), 0, "adds succeed below the cap")
	assert_eq(p.get_presets().size(), PlayerPrefsScript.MAX_PRESETS)
	assert_eq(p.add_preset(), -1, "adding past MAX_PRESETS is rejected")


# ── delete_preset ────────────────────────────────────────────────────────────

func test_delete_last_preset_is_rejected() -> void:
	var p: Node = _fresh()
	p._finalize_presets()
	p.delete_preset(0)
	assert_eq(p.get_presets().size(), 1, "the last surviving preset can't be deleted")


func test_delete_before_active_shifts_active_down() -> void:
	var p: Node = _fresh()
	_set_presets(p, [
		p._make_preset("A", _attrs(68, 162)),
		p._make_preset("B", _attrs(70, 185)),
		p._make_preset("C", _attrs(73, 214)),
	])
	p.attr_active_preset = 2
	p._sync_flat_from_active()
	p.delete_preset(0)
	assert_eq(p.get_active_preset_index(), 1, "active follows its preset after a lower delete")
	assert_true(p.get_player_attributes().equals(_attrs(73, 214)),
			"flat still points at the same build (C)")


func test_delete_active_last_clamps_active() -> void:
	var p: Node = _fresh()
	_set_presets(p, [
		p._make_preset("A", _attrs(68, 162)),
		p._make_preset("B", _attrs(70, 185)),
	])
	p.attr_active_preset = 1
	p._sync_flat_from_active()
	p.delete_preset(1)
	assert_eq(p.get_presets().size(), 1)
	assert_eq(p.get_active_preset_index(), 0, "clamps to the remaining preset")
	assert_true(p.get_player_attributes().equals(_attrs(68, 162)),
			"flat re-synced to the surviving preset")


# ── set_player_attributes writes through to the active preset ────────────────

func test_set_player_attributes_updates_active_preset() -> void:
	var p: Node = _fresh()
	p._finalize_presets()
	var build := _attrs(79, 250)
	p.set_player_attributes(build)
	assert_true(_active_attrs(p).equals(_attrs(79, 250)),
			"free-play edits write through to the active preset")
	# Stored copy must be independent of the argument.
	build.height = 68
	assert_eq(_active_attrs(p).height, 79, "active preset doesn't alias the caller's object")


# ── _parse_stored_presets ────────────────────────────────────────────────────

func test_parse_reconstructs_valid_entries() -> void:
	var p: Node = _fresh()
	var parsed: Array = p._parse_stored_presets([
		{"name": "One", "height": 79, "weight": 250, "profile": 2, "curve": 1,
				"flex": 1, "length": 2},
		{"name": "Two", "height": 68, "weight": 162},
	])
	assert_eq(parsed.size(), 2)
	assert_eq(parsed[0]["name"], "One")
	assert_eq(parsed[0]["attrs"].weight, 250)
	assert_eq(parsed[0]["attrs"].length, PlayerAttributes.LENGTH_LONG)
	assert_true(parsed[1]["attrs"].equals(_attrs(68, 162)))


func test_parse_coerces_out_of_band_body() -> void:
	var p: Node = _fresh()
	var parsed: Array = p._parse_stored_presets([
		{"name": "Wild", "height": 99, "weight": 500},
	])
	assert_eq(parsed[0]["attrs"].height, PlayerAttributes.HEIGHT_MAX, "99 clamps to 6'7\"")
	assert_eq(parsed[0]["attrs"].weight,
			PlayerAttributes.weight_max(PlayerAttributes.HEIGHT_MAX),
			"500 lbs clamps to the band ceiling")


func test_parse_migrates_tier_era_preset() -> void:
	# A v4-era stored preset (height + skating/skill/checking tiers) migrates
	# through PlayerAttributes.migrate_tiers instead of being dropped.
	var p: Node = _fresh()
	var parsed: Array = p._parse_stored_presets([
		{"name": "OldTiers", "height": 5, "skating": 1, "skill": 2, "checking": 3},
	])
	assert_eq(parsed.size(), 1)
	assert_eq(parsed[0]["attrs"].height, 79)
	assert_eq(parsed[0]["attrs"].weight, PlayerAttributes.weight_for_frame_t(79, 0.75),
			"strong Checking → SOLID frame")
	assert_eq(parsed[0]["attrs"].length, PlayerAttributes.LENGTH_LONG)


func test_parse_migrates_legacy_six_attribute_preset() -> void:
	# A pre-v4 stored preset (old six-attribute keys) is migrated, not dropped.
	var p: Node = _fresh()
	var parsed: Array = p._parse_stored_presets([
		{"name": "Legacy", "speed": 2, "agility": 1, "hands": 2, "size": 5,
				"physical": 5, "shot": 4},
	])
	assert_eq(parsed.size(), 1)
	assert_eq(parsed[0]["attrs"].height, 79, "legacy size → height")
	assert_gt(parsed[0]["attrs"].weight, PlayerAttributes.weight_neutral(79),
			"physical-heavy legacy build → heavier than neutral")


func test_parse_skips_malformed_entries() -> void:
	var p: Node = _fresh()
	var parsed: Array = p._parse_stored_presets([
		"not a dict",
		42,
		{"name": "Good", "height": 73, "weight": 201},
	])
	assert_eq(parsed.size(), 1, "non-dict entries are skipped, valid ones kept")
	assert_eq(parsed[0]["name"], "Good")


func test_parse_caps_at_max_presets() -> void:
	var p: Node = _fresh()
	var raw: Array = []
	for i: int in range(PlayerPrefsScript.MAX_PRESETS + 3):
		raw.append({"name": "P%d" % i, "height": 73, "weight": 201})
	var parsed: Array = p._parse_stored_presets(raw)
	assert_eq(parsed.size(), PlayerPrefsScript.MAX_PRESETS, "excess presets are dropped")


func test_parse_non_array_returns_empty() -> void:
	var p: Node = _fresh()
	assert_eq(p._parse_stored_presets("garbage").size(), 0)
	assert_eq(p._parse_stored_presets({}).size(), 0)


# ── name sanitization ────────────────────────────────────────────────────────

func test_sanitize_name_trims_and_defaults_empty() -> void:
	var p: Node = _fresh()
	assert_eq(p._sanitize_preset_name("  Wheels  "), "Wheels")
	assert_eq(p._sanitize_preset_name("   "), "Default", "blank name falls back to Default")


func test_sanitize_name_truncates_to_max_len() -> void:
	var p: Node = _fresh()
	var long_name: String = "X".repeat(40)
	assert_eq(p._sanitize_preset_name(long_name).length(), PlayerPrefsScript.PRESET_NAME_MAX_LEN)
