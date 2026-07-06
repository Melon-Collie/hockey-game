extends GutTest

# PlayerPrefs attribute-build presets.
# -----------------------------------
# The player keeps up to MAX_PRESETS named builds and switches which one is
# ACTIVE; the flat attr_* fields (what get_player_attributes() and thus the
# online join handshake read) always mirror the active preset. These tests pin
# the seeding/migration, the active-index bookkeeping through add/delete, and
# the stored-array parse (which must survive a hand-corrupted / cloud-synced
# config without crashing).
#
# PlayerPrefs is the autoload (extends Node, no class_name). We instantiate the
# script directly and never add it to the tree, so _ready()/_load() never fire
# (presets start empty, no disk read) and the mutators — which are pure
# in-memory, callers persist separately — never write over real preferences.cfg.

const PlayerPrefsScript = preload("res://Scripts/game/player_prefs.gd")


func _fresh() -> Node:
	return autofree(PlayerPrefsScript.new())


func _attrs(sp: int, ag: int, ha: int, sz: int, ph: int, sh: int) -> PlayerAttributes:
	return PlayerAttributes.from_levels(sp, ag, ha, sz, ph, sh)


func _active_attrs(p: Node) -> PlayerAttributes:
	return p.get_presets()[p.get_active_preset_index()]["attrs"]


# attr_presets is typed Array[Dictionary]; a bare literal is an untyped Array and
# won't assign. Funnel entries through a typed local.
func _set_presets(p: Node, entries: Array) -> void:
	var out: Array[Dictionary] = []
	for e: Dictionary in entries:
		out.append(e)
	p.attr_presets = out


# ── _finalize_presets: seeding & sync ────────────────────────────────────────

func test_finalize_seeds_default_from_flat_when_empty() -> void:
	var p: Node = _fresh()
	p.attr_speed = 5
	p.attr_agility = 1
	p.attr_hands = 4
	p.attr_size = 2
	p.attr_physical = 3
	p.attr_shot = 3
	p._finalize_presets()
	assert_eq(p.get_presets().size(), 1, "seeds exactly one preset")
	assert_eq(p.get_active_preset_index(), 0)
	assert_eq(p.get_presets()[0]["name"], "Default")
	assert_true(_active_attrs(p).equals(_attrs(5, 1, 4, 2, 3, 3)),
			"Default preset carries the flat build verbatim")


func test_finalize_syncs_flat_from_active_when_presets_present() -> void:
	var p: Node = _fresh()
	_set_presets(p, [
		p._make_preset("A", _attrs(1, 1, 1, 1, 1, 1)),
		p._make_preset("B", _attrs(5, 4, 3, 2, 2, 2)),
	])
	p.attr_active_preset = 1
	# Flat fields deliberately stale — finalize must overwrite them from active.
	p.attr_speed = 3
	p._finalize_presets()
	assert_true(p.get_player_attributes().equals(_attrs(5, 4, 3, 2, 2, 2)),
			"flat build re-synced from the active preset")


func test_finalize_clamps_out_of_range_active_index() -> void:
	var p: Node = _fresh()
	_set_presets(p, [
		p._make_preset("A", _attrs(3, 3, 3, 3, 3, 3)),
		p._make_preset("B", _attrs(1, 1, 1, 1, 1, 1)),
	])
	p.attr_active_preset = 9
	p._finalize_presets()
	assert_eq(p.get_active_preset_index(), 1, "clamps to last valid preset")


# ── set_active_preset ────────────────────────────────────────────────────────

func test_set_active_preset_switches_flat_build() -> void:
	var p: Node = _fresh()
	_set_presets(p, [
		p._make_preset("A", _attrs(1, 1, 1, 1, 1, 1)),
		p._make_preset("B", _attrs(5, 5, 5, 1, 1, 1)),
	])
	p.attr_active_preset = 0
	p._sync_flat_from_active()
	p.set_active_preset(1)
	assert_eq(p.get_active_preset_index(), 1)
	assert_true(p.get_player_attributes().equals(_attrs(5, 5, 5, 1, 1, 1)))


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
	p.save_preset(0, _attrs(5, 1, 1, 5, 1, 5), "Sniper")
	assert_eq(p.get_presets()[0]["name"], "Sniper")
	assert_true(p.get_player_attributes().equals(_attrs(5, 1, 1, 5, 1, 5)),
			"editing the active preset updates the flat mirror")


func test_save_preset_on_inactive_does_not_touch_flat() -> void:
	var p: Node = _fresh()
	_set_presets(p, [
		p._make_preset("A", _attrs(3, 3, 3, 3, 3, 3)),
		p._make_preset("B", _attrs(1, 1, 1, 1, 1, 1)),
	])
	p.attr_active_preset = 0
	p._sync_flat_from_active()
	p.save_preset(1, _attrs(5, 5, 5, 1, 1, 1))
	assert_true(p.get_player_attributes().equals(_attrs(3, 3, 3, 3, 3, 3)),
			"editing an inactive preset leaves the active build alone")


# ── add_preset ───────────────────────────────────────────────────────────────

func test_add_preset_defaults_to_copy_of_active_build() -> void:
	var p: Node = _fresh()
	p.attr_speed = 5
	p.attr_agility = 1
	p.attr_hands = 4
	p.attr_size = 2
	p.attr_physical = 3
	p.attr_shot = 3
	p._finalize_presets()
	var idx: int = p.add_preset()
	assert_eq(idx, 1)
	assert_true(p.get_presets()[1]["attrs"].equals(_attrs(5, 1, 4, 2, 3, 3)))
	# Independent object: mutating the new preset must not bleed into the source.
	p.get_presets()[1]["attrs"].speed = 1
	assert_eq(p.get_presets()[0]["attrs"].speed, 5, "presets don't share instances")


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
		p._make_preset("A", _attrs(1, 1, 1, 1, 1, 1)),
		p._make_preset("B", _attrs(2, 2, 2, 2, 2, 2)),
		p._make_preset("C", _attrs(3, 3, 3, 3, 3, 3)),
	])
	p.attr_active_preset = 2
	p._sync_flat_from_active()
	p.delete_preset(0)
	assert_eq(p.get_active_preset_index(), 1, "active follows its preset after a lower delete")
	assert_true(p.get_player_attributes().equals(_attrs(3, 3, 3, 3, 3, 3)),
			"flat still points at the same build (C)")


func test_delete_active_last_clamps_active() -> void:
	var p: Node = _fresh()
	_set_presets(p, [
		p._make_preset("A", _attrs(1, 1, 1, 1, 1, 1)),
		p._make_preset("B", _attrs(2, 2, 2, 2, 2, 2)),
	])
	p.attr_active_preset = 1
	p._sync_flat_from_active()
	p.delete_preset(1)
	assert_eq(p.get_presets().size(), 1)
	assert_eq(p.get_active_preset_index(), 0, "clamps to the remaining preset")
	assert_true(p.get_player_attributes().equals(_attrs(1, 1, 1, 1, 1, 1)),
			"flat re-synced to the surviving preset")


# ── set_player_attributes writes through to the active preset ────────────────

func test_set_player_attributes_updates_active_preset() -> void:
	var p: Node = _fresh()
	p._finalize_presets()
	var build := _attrs(5, 5, 1, 1, 5, 1)
	p.set_player_attributes(build)
	assert_true(_active_attrs(p).equals(_attrs(5, 5, 1, 1, 5, 1)),
			"free-play edits write through to the active preset")
	# Stored copy must be independent of the argument.
	build.speed = 1
	assert_eq(_active_attrs(p).speed, 5, "active preset doesn't alias the caller's object")


# ── _parse_stored_presets ────────────────────────────────────────────────────

func test_parse_reconstructs_valid_entries() -> void:
	var p: Node = _fresh()
	var parsed: Array = p._parse_stored_presets([
		{"name": "One", "speed": 5, "agility": 1, "hands": 4, "size": 2, "physical": 3, "shot": 3},
		{"name": "Two", "speed": 1, "agility": 1, "hands": 1, "size": 1, "physical": 1, "shot": 1},
	])
	assert_eq(parsed.size(), 2)
	assert_eq(parsed[0]["name"], "One")
	assert_true(parsed[0]["attrs"].equals(_attrs(5, 1, 4, 2, 3, 3)))


func test_parse_clamps_out_of_range_levels() -> void:
	var p: Node = _fresh()
	var parsed: Array = p._parse_stored_presets([
		{"name": "Wild", "speed": 99, "agility": 0, "hands": 3, "size": 3, "physical": 3, "shot": 3},
	])
	assert_eq(parsed[0]["attrs"].speed, PlayerAttributes.LEVEL_MAX, "99 clamps to 5")
	assert_eq(parsed[0]["attrs"].agility, PlayerAttributes.LEVEL_MIN, "0 clamps to 1")


func test_parse_trims_over_budget_preset() -> void:
	# Per-level clamping bounds each axis but not the sum — a hand-edited cfg can
	# store an over-budget preset, and presets are authoritative for the flat
	# build (they sync AFTER _enforce_attr_budget ran). The parse must repair it
	# with the same deterministic trim as the flat choke point: round-robin over
	# ATTR_TRIM_ORDER, so an all-5 forgery lands on all-medium (the trim sheds one
	# point per axis per pass and stops exactly at BUDGET).
	var p: Node = _fresh()
	var parsed: Array = p._parse_stored_presets([
		{"name": "Forged", "speed": 5, "agility": 5, "hands": 5, "size": 5, "physical": 5, "shot": 5},
	])
	assert_true(parsed[0]["attrs"].equals(_attrs(3, 3, 3, 3, 3, 3)),
			"over-budget stored preset is trimmed to a legal build")


func test_parse_skips_malformed_entries() -> void:
	var p: Node = _fresh()
	var parsed: Array = p._parse_stored_presets([
		"not a dict",
		42,
		{"name": "Good", "speed": 3, "agility": 3, "hands": 3, "size": 3, "physical": 3, "shot": 3},
	])
	assert_eq(parsed.size(), 1, "non-dict entries are skipped, valid ones kept")
	assert_eq(parsed[0]["name"], "Good")


func test_parse_caps_at_max_presets() -> void:
	var p: Node = _fresh()
	var raw: Array = []
	for i: int in range(PlayerPrefsScript.MAX_PRESETS + 3):
		raw.append({"name": "P%d" % i, "speed": 3, "agility": 3, "hands": 3, "size": 3, "physical": 3, "shot": 3})
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
