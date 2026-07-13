extends GutTest

# TutorialRegistry — the catalogue that decides which steps run for each
# tutorial id. The manager and SideMenu both iterate this registry; if it
# ever returns an empty list or skips a registered id, the tutorial flow
# silently breaks. These tests pin the contract.


func test_all_ids_are_unique() -> void:
	var seen: Dictionary = {}
	for id: String in TutorialRegistry.ALL_IDS:
		assert_false(seen.has(id), "tutorial id '%s' appears twice in ALL_IDS" % id)
		seen[id] = true


func test_each_registered_id_has_steps() -> void:
	for id: String in TutorialRegistry.ALL_IDS:
		var steps: Array[int] = TutorialRegistry.get_step_ids(id)
		assert_false(steps.is_empty(),
				"tutorial '%s' has no steps registered" % id)


func test_each_registered_id_has_display_name() -> void:
	for id: String in TutorialRegistry.ALL_IDS:
		var display_name: String = TutorialRegistry.get_display_name(id)
		assert_ne(display_name, "",
				"tutorial '%s' has no display name" % id)


func test_unknown_id_returns_empty_steps() -> void:
	var steps: Array[int] = TutorialRegistry.get_step_ids("nope")
	assert_true(steps.is_empty(),
			"unknown tutorial id should return empty step list")


func test_movement_covers_the_skating_fundamentals() -> void:
	# Pin the Movement curriculum so a refactor can't accidentally drop the
	# core skating teaching that first-launch players see.
	var steps: Array[int] = TutorialRegistry.get_step_ids(TutorialRegistry.MOVEMENT_ID)
	assert_has(steps, TutorialRegistry.STEP_SKATE)
	assert_has(steps, TutorialRegistry.STEP_SPRINT)
	assert_has(steps, TutorialRegistry.STEP_STAMINA)
	assert_has(steps, TutorialRegistry.STEP_BRAKE)


func test_stick_basics_covers_the_q_gestures() -> void:
	# Stick Basics must run BEFORE Defense in ALL_IDS: the stick-lift step
	# reuses the deflect button and blade-lift mechanic taught here.
	var steps: Array[int] = TutorialRegistry.get_step_ids(TutorialRegistry.STICK_ID)
	assert_has(steps, TutorialRegistry.STEP_STICKHANDLE)
	assert_has(steps, TutorialRegistry.STEP_DEFLECT)
	assert_has(steps, TutorialRegistry.STEP_BLADE_LIFT)
	assert_has(steps, TutorialRegistry.STEP_DROP_PUCK)
	assert_true(TutorialRegistry.ALL_IDS.find(TutorialRegistry.STICK_ID)
			< TutorialRegistry.ALL_IDS.find(TutorialRegistry.DEFENSE_ID),
			"stick basics must precede defense (stick lift builds on blade lift)")


func test_shooting_covers_the_drill_sequence() -> void:
	# Pin the Shooting curriculum so a refactor can't drop a drill.
	var steps: Array[int] = TutorialRegistry.get_step_ids(TutorialRegistry.SHOOTING_ID)
	assert_has(steps, TutorialRegistry.STEP_SHOOT_WRIST)
	assert_has(steps, TutorialRegistry.STEP_SHOOT_BACKHAND)
	assert_has(steps, TutorialRegistry.STEP_SHOOT_TARGETS)
	assert_has(steps, TutorialRegistry.STEP_SHOOT_SLAP)
	assert_has(steps, TutorialRegistry.STEP_ONE_TIMER)
	assert_has(steps, TutorialRegistry.STEP_SHOOT_FINISH)
	assert_true(steps.find(TutorialRegistry.STEP_SHOOT_BACKHAND)
			> steps.find(TutorialRegistry.STEP_SHOOT_WRIST),
			"the backhand drill builds on the wrister — it must come after it")


func test_passing_covers_pass_types_and_reception() -> void:
	var steps: Array[int] = TutorialRegistry.get_step_ids(TutorialRegistry.PASSING_ID)
	assert_has(steps, TutorialRegistry.STEP_QUICK_PASS)
	assert_has(steps, TutorialRegistry.STEP_TOUCH_PASS)
	assert_has(steps, TutorialRegistry.STEP_SAUCER_PASS)
	assert_has(steps, TutorialRegistry.STEP_RECEIVE)


func test_defense_covers_checks_and_blocks() -> void:
	var steps: Array[int] = TutorialRegistry.get_step_ids(TutorialRegistry.DEFENSE_ID)
	assert_has(steps, TutorialRegistry.STEP_STICKCHECK)
	assert_has(steps, TutorialRegistry.STEP_BODY_CHECK)
	assert_has(steps, TutorialRegistry.STEP_STICK_LIFT)
	assert_has(steps, TutorialRegistry.STEP_SHOT_BLOCK)


func test_rules_covers_offsides() -> void:
	var steps: Array[int] = TutorialRegistry.get_step_ids(TutorialRegistry.RULES_ID)
	assert_has(steps, TutorialRegistry.STEP_OFFSIDES)


func test_only_defense_and_rules_auto_spawn_the_goalie_pair() -> void:
	# Movement/Stick/Passing teach on open ice; Shooting spawns its own single
	# goalie on demand; Defense and Rules want the normal live AI pair.
	for id: String in TutorialRegistry.ALL_IDS:
		var expect_pair: bool = (id == TutorialRegistry.DEFENSE_ID
				or id == TutorialRegistry.RULES_ID)
		assert_eq(TutorialRegistry.wants_goalies(id), expect_pair,
				"wants_goalies('%s') should be %s" % [id, expect_pair])


func test_step_lists_are_disjoint_across_modules() -> void:
	# Pin the split so a future edit doesn't accidentally duplicate a step
	# across modules — each course teaches its own distinct set.
	var seen: Dictionary = {}
	for id: String in TutorialRegistry.ALL_IDS:
		for step_id: int in TutorialRegistry.get_step_ids(id):
			assert_false(seen.has(step_id),
					"step %d appears in more than one module" % step_id)
			seen[step_id] = true


func test_has_recognises_registered_ids() -> void:
	for id: String in TutorialRegistry.ALL_IDS:
		assert_true(TutorialRegistry.has(id),
				"has() should return true for registered id '%s'" % id)
	assert_false(TutorialRegistry.has("not_real"),
			"has() should return false for an unregistered id")


func test_get_next_id_returns_successor_in_order() -> void:
	# The completion modal uses this to offer "Next: <name>" after the
	# player finishes a tutorial. Pinning the contract: every id except
	# the last has a non-empty successor; the last has "".
	for i: int in TutorialRegistry.ALL_IDS.size():
		var id: String = TutorialRegistry.ALL_IDS[i]
		var next: String = TutorialRegistry.get_next_id(id)
		if i + 1 < TutorialRegistry.ALL_IDS.size():
			assert_eq(next, TutorialRegistry.ALL_IDS[i + 1],
					"next id after '%s' should be the following ALL_IDS entry" % id)
		else:
			assert_eq(next, "",
					"last tutorial '%s' should have no successor" % id)


func test_get_next_id_returns_empty_for_unknown() -> void:
	assert_eq(TutorialRegistry.get_next_id("nope"), "",
			"unknown id should produce no successor")
