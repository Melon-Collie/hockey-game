extends GutTest

# The stick catalogue is wire data — the model index rides the packed
# GearStyleConfig code — and rows are fixed colorways rather than team-slot
# paints. Worth pinning: the table stays index-aligned with its name keys,
# row 0 is still the house MITTS stick (the pre-models look, bit for bit),
# every band is a well-formed span that fits a shader slot and the shortest
# cut, a forged index reads as the house stick instead of crashing the paint
# seam, and no two rows are the same design wearing two names.

# The flex shader carries two band slots; a third band would silently not
# render, so the catalogue must never author one.
const _SHADER_BAND_SLOTS: int = 2
# Bands are placed in metres from an anchor end, so a span must end within
# the shortest cut's shaft (a 5'7" short-stick build renders ≈1.1 m) or the
# design silently loses its band on small builds.
const _SHORTEST_SHAFT_M: float = 1.0


func test_table_is_index_aligned_with_its_names() -> void:
	assert_eq(StickModelRegistry.NAME_KEYS.size(), StickModelRegistry.count(),
			"every stick model is named")


func test_row_zero_is_the_house_stick() -> void:
	var stealth: int = StickModelRegistry.STICK_STEALTH
	assert_eq(StickModelRegistry.shaft_color(stealth), StickModelRegistry.SHAFT_CLASSIC,
			"the stock shaft is the near-black composite")
	assert_eq(StickModelRegistry.brand_color(stealth), Color(1.0, 1.0, 1.0),
			"the stock wordmark is white")
	assert_eq(StickModelRegistry.bands(stealth).size(), 0, "the stock shaft has no bands")
	assert_false(StickModelRegistry.has_blade_override(stealth),
			"the stock blade is the carbon weave")
	assert_eq(StickModelRegistry.blade_base_color(stealth), StickModelRegistry.BLADE_CLASSIC,
			"the stock bare blade is matte black")


func test_every_band_is_a_well_formed_span() -> void:
	for model: int in StickModelRegistry.count():
		var bands: Array = StickModelRegistry.bands(model)
		assert_true(bands.size() <= _SHADER_BAND_SLOTS,
				"model %d fits the shader's band slots" % model)
		for band: Dictionary in bands:
			assert_lt(float(band["from_m"]), float(band["to_m"]),
					"model %d band runs from before to" % model)
			assert_gte(float(band["from_m"]), 0.0, "model %d band starts on the shaft" % model)
			assert_lte(float(band["to_m"]), _SHORTEST_SHAFT_M,
					"model %d band fits the shortest cut" % model)
			assert_true(int(band["anchor"]) in [StickModelRegistry.ANCHOR_BUTT,
					StickModelRegistry.ANCHOR_BLADE], "model %d band anchor is an end" % model)
			assert_eq((band["color"] as Color).a, 1.0, "model %d band paint is opaque" % model)


func test_blade_overrides_come_as_a_weave_pair() -> void:
	for model: int in StickModelRegistry.count():
		var weave: Array[Color] = StickModelRegistry.blade_weave_colors(model)
		if StickModelRegistry.has_blade_override(model):
			assert_eq(weave.size(), 2, "model %d overrides both checker colors" % model)
		else:
			assert_eq(weave.size(), 0, "model %d keeps the carbon defaults" % model)


func test_swatches_lead_with_the_shaft() -> void:
	for model: int in StickModelRegistry.count():
		var swatch: Array[Color] = StickModelRegistry.swatch_colors(model)
		assert_gt(swatch.size(), 1, "model %d has a readable swatch strip" % model)
		assert_eq(swatch[0], StickModelRegistry.shaft_color(model),
				"model %d swatch leads with the shaft" % model)


func test_no_two_models_are_the_same_design() -> void:
	var seen: Array[String] = []
	for model: int in StickModelRegistry.count():
		var key: String = "%s %s %s %s" % [StickModelRegistry.shaft_color(model),
				StickModelRegistry.brand_color(model), StickModelRegistry.bands(model),
				StickModelRegistry.blade_weave_colors(model)]
		assert_false(key in seen, "stick model %d is a duplicate design" % model)
		seen.append(key)


func test_forged_models_read_as_the_house_stick() -> void:
	assert_false(StickModelRegistry.is_valid(-1))
	assert_false(StickModelRegistry.is_valid(StickModelRegistry.count()))
	for model: int in [-1, -999, 99]:
		assert_eq(StickModelRegistry.shaft_color(model), StickModelRegistry.SHAFT_CLASSIC,
				"a forged model carries the house shaft")
		assert_eq(StickModelRegistry.bands(model).size(), 0,
				"a forged model paints no bands")
		assert_eq(StickModelRegistry.blade_base_color(model),
				StickModelRegistry.BLADE_CLASSIC, "a forged model's blade is stock")
