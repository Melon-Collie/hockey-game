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
		var name: String = TutorialRegistry.get_display_name(id)
		assert_ne(name, "",
				"tutorial '%s' has no display name" % id)


func test_unknown_id_returns_empty_steps() -> void:
	var steps: Array[int] = TutorialRegistry.get_step_ids("nope")
	assert_true(steps.is_empty(),
			"unknown tutorial id should return empty step list")


func test_basics_covers_movement_and_shot_types() -> void:
	# Pin the Basics curriculum so a refactor can't accidentally drop the
	# core skating/shooting teaching that first-launch players see.
	var steps: Array[int] = TutorialRegistry.get_step_ids(TutorialRegistry.BASICS_ID)
	assert_has(steps, TutorialRegistry.STEP_SKATE)
	assert_has(steps, TutorialRegistry.STEP_BRAKE)
	assert_has(steps, TutorialRegistry.STEP_QUICK_SHOT)
	assert_has(steps, TutorialRegistry.STEP_WRIST_SHOT)
	assert_has(steps, TutorialRegistry.STEP_SLAPSHOT)


func test_advanced_covers_defense_and_rules() -> void:
	var steps: Array[int] = TutorialRegistry.get_step_ids(TutorialRegistry.ADVANCED_ID)
	assert_has(steps, TutorialRegistry.STEP_ONE_TIMER)
	assert_has(steps, TutorialRegistry.STEP_STICKCHECK)
	assert_has(steps, TutorialRegistry.STEP_BODY_CHECK)
	assert_has(steps, TutorialRegistry.STEP_OFFSIDES)
	assert_has(steps, TutorialRegistry.STEP_ICING)


func test_basics_and_advanced_step_lists_are_disjoint() -> void:
	# Pin the split so a future edit doesn't accidentally duplicate a step
	# across both tutorials — the auto-launched Basics should never repeat
	# something the Advanced menu also teaches.
	var basics: Array[int] = TutorialRegistry.get_step_ids(TutorialRegistry.BASICS_ID)
	var advanced: Array[int] = TutorialRegistry.get_step_ids(TutorialRegistry.ADVANCED_ID)
	for step_id: int in basics:
		assert_false(advanced.has(step_id),
				"step %d is in both Basics and Advanced" % step_id)


func test_has_recognises_registered_ids() -> void:
	for id: String in TutorialRegistry.ALL_IDS:
		assert_true(TutorialRegistry.has(id),
				"has() should return true for registered id '%s'" % id)
	assert_false(TutorialRegistry.has("not_real"),
			"has() should return false for an unregistered id")
