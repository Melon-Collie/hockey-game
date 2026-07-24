extends GutTest

# ControllerGlyphs.brand_for_name — the pure pad-name → brand classifier that
# drives which on-screen button labels are shown. Pure string logic, no engine
# input needed. (Live label lookup / active_brand read the connected pad and are
# exercised in-game, not here.)

const XBOX: int = ControllerGlyphs.Brand.XBOX
const PLAYSTATION: int = ControllerGlyphs.Brand.PLAYSTATION
const NINTENDO: int = ControllerGlyphs.Brand.NINTENDO


func test_playstation_names() -> void:
	for name: String in ["Sony DualSense", "PS5 Controller", "PS4 Controller",
			"DualShock 4", "Sony PlayStation(R) DualShock 4"]:
		assert_eq(ControllerGlyphs.brand_for_name(name), PLAYSTATION,
				"'%s' classifies as PlayStation" % name)


func test_nintendo_names() -> void:
	for name: String in ["Nintendo Switch Pro Controller", "Joy-Con (L)",
			"Switch Pro Controller"]:
		assert_eq(ControllerGlyphs.brand_for_name(name), NINTENDO,
				"'%s' classifies as Nintendo" % name)


func test_xbox_and_unknown_default_to_xbox() -> void:
	for name: String in ["Xbox 360 Controller", "Xbox Series Controller",
			"Steam Deck Controller", "Generic X-Box pad", "", "Totally Unknown Pad"]:
		assert_eq(ControllerGlyphs.brand_for_name(name), XBOX,
				"'%s' classifies as Xbox (the default)" % name)


func test_classification_is_case_insensitive() -> void:
	assert_eq(ControllerGlyphs.brand_for_name("sony dualsense"), PLAYSTATION,
			"lowercase PlayStation name still classifies")
	assert_eq(ControllerGlyphs.brand_for_name("NINTENDO SWITCH"), NINTENDO,
			"uppercase Nintendo name still classifies")


func test_face_button_labels_differ_by_brand() -> void:
	# The south button (JOY_BUTTON_A) is A on Xbox, Cross on PlayStation, and B on
	# a Nintendo pad (mirrored layout).
	assert_eq(ControllerGlyphs._labels_for(XBOX).get(JOY_BUTTON_A), "A",
			"south button reads A on Xbox")
	assert_eq(ControllerGlyphs._labels_for(PLAYSTATION).get(JOY_BUTTON_A), "✕",
			"south button reads Cross on PlayStation")
	assert_eq(ControllerGlyphs._labels_for(NINTENDO).get(JOY_BUTTON_A), "B",
			"south button reads B on a Nintendo pad")
