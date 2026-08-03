extends GutTest

# GearStyleConfig is wire data (the packed code rides the join and spawn
# payloads), so the invariants worth pinning are the wire ones: every legal
# pick round-trips through the code exactly, garbage coerces to a legal look
# instead of being trusted, the default code decodes to the pre-customization
# kit (stock black skates, kit-colored gloves), and a save written before
# models existed lands on a design rather than on stock gear.


func test_default_decodes_to_the_kit_look() -> void:
	var config := GearStyleConfig.new()
	assert_eq(config.to_code(), GearStyleConfig.DEFAULT_CODE, "untouched look packs to default")
	assert_eq(config.skate_model, GearModelRegistry.SKATE_BLACKOUT, "skates default all-black")
	assert_eq(config.glove_model, GearModelRegistry.GLOVE_TEAM, "gloves default to the kit")
	assert_eq(config.lace_color, GearStyleConfig.LACE_DEFAULT_INDEX, "laces default white")
	assert_eq(config.stick_model, StickModelRegistry.STICK_STEALTH,
			"the stick defaults to the house model")
	assert_eq(config.helmet_face, GearModelRegistry.FACE_NONE, "the face defaults bare")


func test_every_legal_pick_round_trips() -> void:
	for skate: int in GearModelRegistry.skate_count():
		for glove: int in GearModelRegistry.glove_count():
			for lace: int in TapeColorRegistry.count():
				for stick: int in StickModelRegistry.count():
					for face: int in GearModelRegistry.face_count():
						var config := GearStyleConfig.new(skate, glove, lace, stick, face)
						var back: GearStyleConfig = GearStyleConfig.from_code(config.to_code())
						assert_eq(back.skate_model, skate)
						assert_eq(back.glove_model, glove)
						assert_eq(back.lace_color, lace)
						assert_eq(back.stick_model, stick)
						assert_eq(back.helmet_face, face)


func test_garbage_codes_coerce_to_legal_looks() -> void:
	for code: int in [-1, -999, 1 << 20, 0x7FFFFFFF]:
		var config: GearStyleConfig = GearStyleConfig.from_code(code)
		assert_true(GearModelRegistry.is_valid_skate(config.skate_model), "skate model legal")
		assert_true(GearModelRegistry.is_valid_glove(config.glove_model), "glove model legal")
		assert_true(TapeColorRegistry.is_valid(config.lace_color), "lace color legal")
		assert_true(StickModelRegistry.is_valid(config.stick_model), "stick model legal")
		assert_true(GearModelRegistry.is_valid_face(config.helmet_face), "face option legal")
		# And the coerced look re-packs stably (idempotent coercion).
		var code2: int = config.to_code()
		assert_eq(GearStyleConfig.from_code(code2).to_code(), code2)


# The pre-models code packed TapeColorRegistry accent picks in the two low
# fields (skate 5 bits, glove 5 bits, laces unchanged in the high field).
func _legacy_code(skate_color: int, glove_color: int, lace_color: int) -> int:
	return skate_color | (glove_color << 5) | (lace_color << 10)


func test_migration_keeps_the_stock_look_stock() -> void:
	# The old default: BLACK skate accent, TEAM gloves, WHITE laces.
	var migrated: GearStyleConfig = GearStyleConfig.migrate_colors(
			_legacy_code(2, TapeColorRegistry.TEAM_INDEX, 1))
	assert_eq(migrated.to_code(), GearStyleConfig.DEFAULT_CODE,
			"an untouched pre-models save is still the stock kit")
	assert_eq(migrated.stick_model, StickModelRegistry.STICK_STEALTH,
			"a pre-stick-models save carries the house stick")


func test_migration_maps_picks_onto_designs() -> void:
	# A white boot stays white; a colored accent becomes the team-band design.
	assert_eq(GearStyleConfig.migrate_colors(_legacy_code(1, 0, 1)).skate_model,
			GearModelRegistry.SKATE_WHITEOUT, "white skates -> Whiteout")
	assert_eq(GearStyleConfig.migrate_colors(_legacy_code(3, 0, 1)).skate_model,
			GearModelRegistry.SKATE_TEAM, "a colored accent -> Team")
	# Gloves only ever tinted the cuff, so every mapping keeps a kit-colored body.
	# There is no black glove to land on any more, so a black pick becomes the
	# design whose cuff takes the team's other color.
	assert_eq(GearStyleConfig.migrate_colors(_legacy_code(2, 1, 1)).glove_model,
			GearModelRegistry.GLOVE_PRO, "white cuffs -> Pro")
	assert_eq(GearStyleConfig.migrate_colors(_legacy_code(2, 2, 1)).glove_model,
			GearModelRegistry.GLOVE_CONTRAST, "black cuffs -> Contrast")
	assert_eq(GearStyleConfig.migrate_colors(_legacy_code(2, 5, 1)).glove_model,
			GearModelRegistry.GLOVE_CONTRAST, "a colored cuff -> Contrast")
	for body: int in [GearModelRegistry.GLOVE_TEAM, GearModelRegistry.GLOVE_PRO,
			GearModelRegistry.GLOVE_CONTRAST]:
		assert_eq(GearModelRegistry.glove_color(body, GearModelRegistry.GLOVE_BODY,
				Color.RED, Color.GREEN, Color.BLUE), Color.RED,
				"migrated gloves keep a kit-colored body")


func test_migration_preserves_laces_and_lands_legal() -> void:
	for lace: int in TapeColorRegistry.count():
		var migrated: GearStyleConfig = GearStyleConfig.migrate_colors(
				_legacy_code(4, 7, lace))
		assert_eq(migrated.lace_color, lace, "laces are unchanged by the migration")
	# Garbage in the old fields still lands on a legal design.
	var junk: GearStyleConfig = GearStyleConfig.migrate_colors(0x7FFFFFFF)
	assert_true(GearModelRegistry.is_valid_skate(junk.skate_model), "skate model legal")
	assert_true(GearModelRegistry.is_valid_glove(junk.glove_model), "glove model legal")
