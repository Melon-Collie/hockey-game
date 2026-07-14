extends GutTest

# DrillRegistry — the catalogue that maps each practice-drill id to its
# display name and manager script. SideMenu builds the drill rows from it and
# game_scene spawns the registered manager; if it ever returns an empty path
# or skips a registered id, the drill flow silently breaks. These tests pin
# the contract.


func test_all_ids_are_unique() -> void:
	var seen: Dictionary = {}
	for id: String in DrillRegistry.ALL_IDS:
		assert_false(seen.has(id), "drill id '%s' appears twice in ALL_IDS" % id)
		seen[id] = true


func test_each_registered_id_has_display_name_key() -> void:
	# Every registered id must map to a real translation key (not fall through
	# to the raw id), so the UI's tr() lands on a catalogued string.
	for id: String in DrillRegistry.ALL_IDS:
		var key: String = DrillRegistry.display_name_key(id)
		assert_ne(key, "", "drill '%s' has no display-name key" % id)
		assert_ne(key, id, "drill '%s' fell through to the raw id" % id)


# The manager path must point at a script that actually compiles — this is
# what game_scene instantiates, so a typo'd path or a parse error in a manager
# would otherwise only surface at launch.
func test_each_registered_manager_loads() -> void:
	for id: String in DrillRegistry.ALL_IDS:
		var path: String = DrillRegistry.get_manager_path(id)
		assert_ne(path, "", "drill '%s' has no manager path" % id)
		var script: GDScript = load(path)
		assert_not_null(script, "drill '%s' manager at %s failed to load" % [id, path])


func test_unknown_id_has_no_manager() -> void:
	assert_eq(DrillRegistry.get_manager_path("nope"), "")
	assert_false(DrillRegistry.has("nope"))


func test_registered_ids_are_known() -> void:
	for id: String in DrillRegistry.ALL_IDS:
		assert_true(DrillRegistry.has(id))


func test_current_drills_dress_their_own_net() -> void:
	# Both drills spawn their own lone goalie, so neither wants the match
	# goalie pair auto-spawned under it.
	for id: String in DrillRegistry.ALL_IDS:
		assert_false(DrillRegistry.wants_goalie_pair(id),
				"drill '%s' unexpectedly wants the goalie pair" % id)
