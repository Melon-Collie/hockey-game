extends GutTest

# The gear catalogue is wire data — model indices ride the packed
# GearStyleConfig code — and it is the only thing standing between a pick and
# what the rink paints. What is worth pinning: the tables stay index-aligned
# with their name keys AND with the zone counts the painters walk, every zone
# resolves to one of the four slots a design is built from, the boot never
# takes a team color (leather is leather), a forged model paints stock gear
# instead of crashing the paint seam, and row 0 of each list is still the
# stock design.

# A synthetic kit whose four slots are all distinguishable, so a zone landing
# on the wrong one is visible rather than plausible.
const _TEAM := Color(0.20, 0.40, 0.90)
const _ACCENT := Color(0.90, 0.30, 0.10)
const _LIGHT := Color(0.96, 0.93, 0.84)   # a CREAM white, like Plum's


func test_tables_are_index_aligned_with_their_names() -> void:
	assert_eq(GearModelRegistry.SKATE_NAME_KEYS.size(), GearModelRegistry.skate_count(),
			"every skate model is named")
	assert_eq(GearModelRegistry.GLOVE_NAME_KEYS.size(), GearModelRegistry.glove_count(),
			"every glove model is named")
	# A row short of a zone would read as a silent index error at the paint
	# seam, not as a missing color.
	for model: int in GearModelRegistry.skate_count():
		assert_eq(_skate(model, GearModelRegistry.SKATE_ZONE_COUNT - 1).a, 1.0,
				"skate model %d covers its last zone" % model)
	for model: int in GearModelRegistry.glove_count():
		assert_eq(_glove(model, GearModelRegistry.GLOVE_ZONE_COUNT - 1).a, 1.0,
				"glove model %d covers its last zone" % model)


func _skate(model: int, zone: int) -> Color:
	return GearModelRegistry.skate_color(model, zone, _TEAM, _ACCENT, _LIGHT)


func _glove(model: int, zone: int) -> Color:
	return GearModelRegistry.glove_color(model, zone, _TEAM, _ACCENT, _LIGHT)


# Blackout is black through the boot on a white holder — the median NHL skate,
# and the one deliberate change from the pre-models look, where the holder
# rendered steel along with the runner.
func test_row_zero_is_the_stock_design() -> void:
	for zone: int in [GearModelRegistry.SKATE_QUARTER, GearModelRegistry.SKATE_TOE,
			GearModelRegistry.SKATE_COLLAR, GearModelRegistry.SKATE_STRIPE]:
		assert_eq(_skate(GearModelRegistry.SKATE_BLACKOUT, zone),
				GearModelRegistry.BLACK, "the stock skate is black through the boot")
	assert_eq(_skate(GearModelRegistry.SKATE_BLACKOUT, GearModelRegistry.SKATE_HOLDER),
			_LIGHT, "even the blackout stands on a white holder")
	for zone: int in GearModelRegistry.GLOVE_ZONE_COUNT:
		assert_eq(_glove(GearModelRegistry.GLOVE_TEAM, zone),
				_TEAM, "the stock glove is kit-colored on every zone")


# A team's own white may be CREAM, and gear wears the team's rather than a
# fixed white — that is the whole point of the LIGHT slot.
func test_light_zones_wear_the_teams_own_white() -> void:
	assert_eq(_skate(GearModelRegistry.SKATE_WHITEOUT, GearModelRegistry.SKATE_QUARTER),
			_LIGHT, "a light boot is the team's white, cream included")
	assert_eq(_glove(GearModelRegistry.GLOVE_VINTAGE, GearModelRegistry.GLOVE_BODY),
			_LIGHT, "a light glove back is the team's white")


# A real kit has two colors and a real skate wears both, so the catalogue must
# actually reach for the secondary somewhere — a slot nothing uses is a slot
# that silently rots.
func test_the_catalogue_uses_both_team_colors() -> void:
	var skate_accents: int = 0
	for model: int in GearModelRegistry.skate_count():
		for zone: int in GearModelRegistry.SKATE_ZONE_COUNT:
			if _skate(model, zone) == _ACCENT:
				skate_accents += 1
	assert_gt(skate_accents, 0, "some skate design wears the team's secondary")
	var glove_accents: int = 0
	for model: int in GearModelRegistry.glove_count():
		for zone: int in GearModelRegistry.GLOVE_ZONE_COUNT:
			if _glove(model, zone) == _ACCENT:
				glove_accents += 1
	assert_gt(glove_accents, 0, "some glove design wears the team's secondary")


# A glove is made in the team's colors, and no preset here has black among
# theirs — a black glove would belong to nobody. BLACK is a skate-only slot.
func test_gloves_never_reach_for_black() -> void:
	for model: int in GearModelRegistry.glove_count():
		for zone: int in GearModelRegistry.GLOVE_ZONE_COUNT:
			assert_ne(_glove(model, zone), GearModelRegistry.BLACK,
					"glove model %d zone %d is a kit color" % [model, zone])


# A holder is molded white plastic on essentially every skate on the ice, so
# no design departs from it — including the blackout, whose boot is black to
# the collar and still stands on a white holder.
func test_every_holder_is_the_teams_white() -> void:
	for model: int in GearModelRegistry.skate_count():
		assert_eq(_skate(model, GearModelRegistry.SKATE_HOLDER), _LIGHT,
				"skate model %d wears a white holder" % model)


# The boot is leather. A quarter or toe cap in a team's secondary — which for
# several presets is a bright pink or sky blue — stops reading as a skate.
func test_the_boot_never_takes_a_team_accent() -> void:
	for model: int in GearModelRegistry.skate_count():
		for zone: int in [GearModelRegistry.SKATE_QUARTER, GearModelRegistry.SKATE_TOE]:
			var paint: Color = _skate(model, zone)
			assert_true(paint == GearModelRegistry.BLACK or paint == _LIGHT,
					"skate model %d zone %d is leather-colored" % [model, zone])


func test_every_zone_paints_a_slot_of_the_kit() -> void:
	var legal: Array[Color] = [GearModelRegistry.BLACK, _LIGHT, _TEAM, _ACCENT]
	for model: int in GearModelRegistry.skate_count():
		for zone: int in GearModelRegistry.SKATE_ZONE_COUNT:
			assert_true(_skate(model, zone) in legal,
					"skate model %d zone %d" % [model, zone])
	for model: int in GearModelRegistry.glove_count():
		for zone: int in GearModelRegistry.GLOVE_ZONE_COUNT:
			assert_true(_glove(model, zone) in legal,
					"glove model %d zone %d" % [model, zone])


# Two designs that painted every zone the same would be one design wearing two
# names, and the workbench would look broken rather than sparse.
func test_no_two_models_are_the_same_design() -> void:
	var seen: Array[String] = []
	for model: int in GearModelRegistry.skate_count():
		var key: String = ""
		for zone: int in GearModelRegistry.SKATE_ZONE_COUNT:
			key += str(_skate(model, zone))
		assert_false(key in seen, "skate model %d is a duplicate design" % model)
		seen.append(key)
	seen.clear()
	for model: int in GearModelRegistry.glove_count():
		var key: String = ""
		for zone: int in GearModelRegistry.GLOVE_ZONE_COUNT:
			key += str(_glove(model, zone))
		assert_false(key in seen, "glove model %d is a duplicate design" % model)
		seen.append(key)


# Face options are fixed looks, not paint rows — what is worth pinning is the
# wire/table alignment, that row 0 is bare (an untouched save renders exactly
# the pre-face look), and that each option keeps the transparency class its
# material factory builds from: the shields translucent, the cage solid.
func test_face_options_stay_aligned_and_keep_their_looks() -> void:
	assert_eq(GearModelRegistry.FACE_NAME_KEYS.size(), GearModelRegistry.face_count(),
			"every face option is named")
	assert_eq(GearModelRegistry.FACE_NONE, 0, "row 0 is bare")
	for option: int in [GearModelRegistry.FACE_VISOR, GearModelRegistry.FACE_FISHBOWL]:
		var a: float = GearModelRegistry.face_color(option).a
		assert_true(a > 0.0 and a < 1.0, "shield option %d is translucent" % option)
	assert_eq(GearModelRegistry.face_color(GearModelRegistry.FACE_CAGE).a, 1.0,
			"the cage is solid steel")


func test_forged_face_options_read_as_bare() -> void:
	assert_false(GearModelRegistry.is_valid_face(-1))
	assert_false(GearModelRegistry.is_valid_face(GearModelRegistry.face_count()))
	for option: int in [-1, -999, 99]:
		assert_eq(GearModelRegistry.face_color(option),
				GearModelRegistry.face_color(GearModelRegistry.FACE_NONE),
				"a forged face option carries no piece")


func test_forged_models_paint_stock_gear() -> void:
	assert_false(GearModelRegistry.is_valid_skate(-1))
	assert_false(GearModelRegistry.is_valid_glove(GearModelRegistry.glove_count()))
	for model: int in [-1, -999, 99]:
		assert_eq(_skate(model, GearModelRegistry.SKATE_QUARTER),
				GearModelRegistry.BLACK, "a forged skate model wears the stock boot")
		assert_eq(_glove(model, GearModelRegistry.GLOVE_CUFF),
				_TEAM, "a forged glove model wears the kit cuff")
