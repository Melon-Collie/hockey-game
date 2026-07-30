extends GutTest

# GearStyleConfig is wire data (the packed code rides the join and spawn
# payloads), so the invariants worth pinning are the wire ones: every legal
# pick round-trips through the code exactly, garbage coerces to a legal look
# instead of being trusted, and the default code decodes to the
# pre-customization kit (black skates, team gloves).


func test_default_decodes_to_the_kit_look() -> void:
	var config := GearStyleConfig.new()
	assert_eq(config.to_code(), GearStyleConfig.DEFAULT_CODE, "untouched look packs to default")
	assert_eq(config.skate_color, GearStyleConfig.SKATE_DEFAULT_INDEX, "skates default black")
	assert_eq(config.glove_color, TapeColorRegistry.TEAM_INDEX, "gloves default to the kit")
	assert_eq(config.lace_color, GearStyleConfig.LACE_DEFAULT_INDEX, "laces default white")


func test_every_legal_pick_round_trips() -> void:
	for skate: int in TapeColorRegistry.count():
		for glove: int in TapeColorRegistry.count():
			for lace: int in TapeColorRegistry.count():
				var config := GearStyleConfig.new(skate, glove, lace)
				var back: GearStyleConfig = GearStyleConfig.from_code(config.to_code())
				assert_eq(back.skate_color, skate)
				assert_eq(back.glove_color, glove)
				assert_eq(back.lace_color, lace)


func test_garbage_codes_coerce_to_legal_looks() -> void:
	for code: int in [-1, -999, 1 << 20, 0x7FFFFFFF]:
		var config: GearStyleConfig = GearStyleConfig.from_code(code)
		assert_true(TapeColorRegistry.is_valid(config.skate_color), "skate color legal")
		assert_true(TapeColorRegistry.is_valid(config.glove_color), "glove color legal")
		assert_true(TapeColorRegistry.is_valid(config.lace_color), "lace color legal")
		# And the coerced look re-packs stably (idempotent coercion).
		var code2: int = config.to_code()
		assert_eq(GearStyleConfig.from_code(code2).to_code(), code2)
