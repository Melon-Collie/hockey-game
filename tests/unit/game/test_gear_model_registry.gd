extends GutTest

# The gear catalogue is wire data — model indices ride the packed
# GearStyleConfig code — and it is the only thing standing between a pick and
# what the rink paints. What is worth pinning: the tables stay index-aligned
# with their name keys AND with the zone counts the painters walk, every zone
# resolves to one of the three slots a real design is built from, a forged
# model paints stock gear instead of crashing the paint seam, and row 0 of
# each list is still the stock design.


func test_tables_are_index_aligned_with_their_names() -> void:
	assert_eq(GearModelRegistry.SKATE_NAME_KEYS.size(), GearModelRegistry.skate_count(),
			"every skate model is named")
	assert_eq(GearModelRegistry.GLOVE_NAME_KEYS.size(), GearModelRegistry.glove_count(),
			"every glove model is named")
	# A row short of a zone would read as a silent index error at the paint
	# seam, not as a missing color.
	for model: int in GearModelRegistry.skate_count():
		assert_eq(GearModelRegistry.skate_color(model,
				GearModelRegistry.SKATE_ZONE_COUNT - 1, Color.RED).a, 1.0,
				"skate model %d covers its last zone" % model)
	for model: int in GearModelRegistry.glove_count():
		assert_eq(GearModelRegistry.glove_color(model,
				GearModelRegistry.GLOVE_ZONE_COUNT - 1, Color.RED).a, 1.0,
				"glove model %d covers its last zone" % model)


# Blackout is black on every zone including the holder — which is the one
# deliberate change from the pre-models look, where the holder rendered steel.
func test_row_zero_is_the_stock_design() -> void:
	var accent := Color(0.2, 0.4, 0.9)
	var kit_gloves := Color(0.7, 0.1, 0.1)
	for zone: int in GearModelRegistry.SKATE_ZONE_COUNT:
		assert_eq(GearModelRegistry.skate_color(GearModelRegistry.SKATE_BLACKOUT, zone, accent),
				GearModelRegistry.BLACK, "the stock skate is black on every zone")
	for zone: int in GearModelRegistry.GLOVE_ZONE_COUNT:
		assert_eq(GearModelRegistry.glove_color(GearModelRegistry.GLOVE_TEAM, zone, kit_gloves),
				kit_gloves, "the stock glove is kit-colored on every zone")


func test_every_zone_paints_black_white_or_the_team() -> void:
	var accent := Color(0.2, 0.4, 0.9)
	var legal: Array[Color] = [GearModelRegistry.BLACK, GearModelRegistry.WHITE, accent]
	for model: int in GearModelRegistry.skate_count():
		for zone: int in GearModelRegistry.SKATE_ZONE_COUNT:
			assert_true(GearModelRegistry.skate_color(model, zone, accent) in legal,
					"skate model %d zone %d" % [model, zone])
	for model: int in GearModelRegistry.glove_count():
		for zone: int in GearModelRegistry.GLOVE_ZONE_COUNT:
			assert_true(GearModelRegistry.glove_color(model, zone, accent) in legal,
					"glove model %d zone %d" % [model, zone])


# Two designs that painted every zone the same would be one design wearing two
# names, and the workbench would look broken rather than sparse.
func test_no_two_models_are_the_same_design() -> void:
	var accent := Color(0.2, 0.4, 0.9)
	var seen: Array[String] = []
	for model: int in GearModelRegistry.skate_count():
		var key: String = ""
		for zone: int in GearModelRegistry.SKATE_ZONE_COUNT:
			key += str(GearModelRegistry.skate_color(model, zone, accent))
		assert_false(key in seen, "skate model %d is a duplicate design" % model)
		seen.append(key)
	seen.clear()
	for model: int in GearModelRegistry.glove_count():
		var key: String = ""
		for zone: int in GearModelRegistry.GLOVE_ZONE_COUNT:
			key += str(GearModelRegistry.glove_color(model, zone, accent))
		assert_false(key in seen, "glove model %d is a duplicate design" % model)
		seen.append(key)


func test_forged_models_paint_stock_gear() -> void:
	var accent := Color(0.2, 0.4, 0.9)
	assert_false(GearModelRegistry.is_valid_skate(-1))
	assert_false(GearModelRegistry.is_valid_glove(GearModelRegistry.glove_count()))
	for model: int in [-1, -999, 99]:
		assert_eq(GearModelRegistry.skate_color(model, GearModelRegistry.SKATE_QUARTER, accent),
				GearModelRegistry.BLACK, "a forged skate model wears the stock boot")
		assert_eq(GearModelRegistry.glove_color(model, GearModelRegistry.GLOVE_CUFF, accent),
				accent, "a forged glove model wears the kit cuff")
