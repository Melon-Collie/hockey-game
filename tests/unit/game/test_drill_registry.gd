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


# The other three steps in CLAUDE.md's "New practice drill" row, which are prose
# and each fail quietly: a manager that doesn't inherit the loop re-implements
# it (and gets one part subtly wrong), and a display-name key with no CSV row
# renders as the raw key on the menu button.

func test_every_manager_extends_the_shared_loop() -> void:
	for id: String in DrillRegistry.ALL_IDS:
		var script: GDScript = load(DrillRegistry.get_manager_path(id))
		var base: Script = script.get_base_script() if script != null else null
		assert_not_null(base, "drill '%s' extends Node directly" % id)
		if base == null:
			continue
		assert_eq(base.resource_path, "res://Scripts/game/drill_loop.gd",
				"drill '%s' must extend DrillLoop — the stage machine, the result " % id +
				"hold, the puck staging and the retry/exit handlers are all there, and " +
				"a drill that re-implements them re-decides them")


# The state DrillLoop owns. A manager re-declaring any of it shadows the base
# (which GDScript allows and gdlint cannot see), so the base's own methods would
# read one copy while the drill wrote the other.
func test_no_manager_redeclares_the_shared_loop_state() -> void:
	var owned: PackedStringArray = ["_stage", "_result_timer", "_session", "_hud",
			"_puck", "_skater", "_local_record", "_local_controller",
			"RESULT_HOLD", "PICKUP_LOCK_S", "ICE_Y", "STAGE_PUCK_AHEAD",
			"ATTACK_DIR_Z", "FACE_NET", "REST_SPEED", "STALL_GRACE_S", "RELEASE_GRACE_S"]
	var lines_scanned: int = 0
	for id: String in DrillRegistry.ALL_IDS:
		var src: String = FileAccess.get_file_as_string(DrillRegistry.get_manager_path(id))
		lines_scanned += src.split("\n").size()
		for line: String in src.split("\n"):
			for name: String in owned:
				# The trailing separator keeps `_stage` from matching `_stage_wall`.
				for decl: String in ["var %s", "const %s", "var _%s", "const _%s"]:
					var head: String = decl % name
					if not line.begins_with(head):
						continue
					var after: String = line.substr(head.length(), 1)
					if after == ":" or after == " " or after == "=" or after == "":
						fail_test("drill '%s' re-declares `%s`, which DrillLoop owns — " % [id, name] +
								"the base would then drive a different copy than the drill reads")
	assert_gt(lines_scanned, 300, "expected to have read the drill managers")


func test_every_display_name_key_has_a_translation_row() -> void:
	var csv: String = FileAccess.get_file_as_string("res://locale/translations.csv")
	assert_false(csv.is_empty(), "could not read locale/translations.csv")
	for id: String in DrillRegistry.ALL_IDS:
		assert_true(csv.contains("\n%s," % DrillRegistry.display_name_key(id)),
				"drill '%s' has no row in locale/translations.csv — the Drills menu " % id +
				"would show the raw key")
