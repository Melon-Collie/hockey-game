extends GutTest

# A .mreplay describes each skater twice — once in the file header's initial
# roster, once in the mid-game `player_joined` event — and the viewer spawns
# from either through the same path. These pin the two ends of that contract:
# what GameManager writes into an entry, and what ReplayViewer reads back out.

# Preloaded rather than reached through the autoload so the statics are called
# on the script, not on an instance.
const GAME_MANAGER: GDScript = preload("res://Scripts/game/game_manager.gd")
const REPLAY_VIEWER: GDScript = preload("res://Scripts/game/replay_viewer.gd")


func _record_with_look(tape: int, gear: int, skin: int) -> PlayerRecord:
	var team := Team.new()
	team.team_id = 1
	var record := PlayerRecord.new(7, 2, false, team)
	record.player_name = "Yzerman"
	record.jersey_number = 19
	record.tape_code = tape
	record.skin_tone = skin
	record.gear_style_code = gear
	return record


# The look the player actually wore has to reach the file, or the viewer can
# only ever dress them in the stock kit.
func test_roster_entry_carries_the_players_cosmetics() -> void:
	var tape: int = StickTapeConfig.new(TapeColorRegistry.TEAM_INDEX,
			StickTapeConfig.Span.FULL, 1, StickTapeConfig.KnobStyle.CANDY_CANE).to_code()
	var gear: int = GearStyleConfig.new(GearModelRegistry.SKATE_WHITEOUT,
			GearModelRegistry.GLOVE_TEAM, 2, 0, GearModelRegistry.FACE_CAGE).to_code()
	var entry: Dictionary = GAME_MANAGER.replay_roster_entry(
			_record_with_look(tape, gear, 4))

	assert_eq(int(entry.tape_code), tape)
	assert_eq(int(entry.gear_style_code), gear)
	assert_eq(int(entry.skin_tone), 4)
	# The identity fields the viewer already relied on must survive the shared
	# builder both call sites now go through.
	assert_eq(int(entry.peer_id), 7)
	assert_eq(str(entry.player_name), "Yzerman")
	assert_eq(int(entry.jersey_number), 19)
	assert_eq(int(entry.team_id), 1)
	assert_eq(int(entry.team_slot), 2)
	assert_true(entry.has("build"), "build must still ride along")


# Everything in the entry has to survive JSON — the header is stringified whole
# and the join event is written as a JSON payload.
func test_entry_survives_json_round_trip() -> void:
	var gear: int = GearStyleConfig.new(GearModelRegistry.SKATE_BLACKOUT,
			GearModelRegistry.GLOVE_PRO, 3, 0, GearModelRegistry.FACE_VISOR).to_code()
	var entry: Dictionary = GAME_MANAGER.replay_roster_entry(
			_record_with_look(StickTapeConfig.DEFAULT_CODE, gear, 5))
	var decoded: Variant = JSON.parse_string(JSON.stringify(entry))
	assert_true(decoded is Dictionary, "entry must be JSON-serialisable")

	var look: Dictionary = REPLAY_VIEWER.cosmetics_from_entry(decoded as Dictionary)
	assert_eq((look.gear as GearStyleConfig).to_code(), gear)
	assert_eq(int(look.skin), 5)


func test_cosmetics_decode_to_the_recorded_look() -> void:
	var tape := StickTapeConfig.new(3, StickTapeConfig.Span.MID_TO_TOE, 2,
			StickTapeConfig.KnobStyle.FULL)
	var gear := GearStyleConfig.new(GearModelRegistry.SKATE_TEAM,
			GearModelRegistry.GLOVE_CONTRAST, 4, 0, GearModelRegistry.FACE_FISHBOWL)
	var look: Dictionary = REPLAY_VIEWER.cosmetics_from_entry({
		"tape_code": tape.to_code(),
		"gear_style_code": gear.to_code(),
		"skin_tone": 1,
	})

	var out_tape: StickTapeConfig = look.tape
	assert_eq(out_tape.blade_color, tape.blade_color)
	assert_eq(out_tape.span, tape.span)
	assert_eq(out_tape.knob_color, tape.knob_color)
	assert_eq(out_tape.knob_style, tape.knob_style)
	var out_gear: GearStyleConfig = look.gear
	assert_eq(out_gear.skate_model, gear.skate_model)
	assert_eq(out_gear.glove_model, gear.glove_model)
	assert_eq(out_gear.lace_color, gear.lace_color)
	assert_eq(out_gear.helmet_face, gear.helmet_face)
	assert_eq(int(look.skin), 1)


# A .mreplay recorded before cosmetics were written into the header carries none
# of these fields; it must still play, dressed in the stock kit.
func test_legacy_entry_without_cosmetics_falls_back_to_the_stock_look() -> void:
	var look: Dictionary = REPLAY_VIEWER.cosmetics_from_entry({
		"peer_id": 3, "player_name": "Old", "team_id": 0,
	})
	assert_eq((look.tape as StickTapeConfig).to_code(), StickTapeConfig.DEFAULT_CODE)
	assert_eq((look.gear as GearStyleConfig).to_code(), GearStyleConfig.DEFAULT_CODE)
	assert_eq(int(look.skin), SkinToneRegistry.DEFAULT_INDEX)


# The file is untrusted input: a hand-edited entry must land on a legal look
# rather than an out-of-range model index or palette lookup crash.
func test_out_of_range_and_wrong_typed_fields_are_coerced() -> void:
	var look: Dictionary = REPLAY_VIEWER.cosmetics_from_entry({
		"tape_code": 0x7FFFFFFF,
		"gear_style_code": 0x7FFFFFFF,
		"skin_tone": 999,
	})
	var tape: StickTapeConfig = look.tape
	assert_between(tape.span, 0, StickTapeConfig.Span.size() - 1)
	assert_true(TapeColorRegistry.is_valid(tape.blade_color))
	assert_true(TapeColorRegistry.is_valid(tape.knob_color))
	var gear: GearStyleConfig = look.gear
	assert_true(GearModelRegistry.is_valid_skate(gear.skate_model))
	assert_true(GearModelRegistry.is_valid_glove(gear.glove_model))
	assert_true(GearModelRegistry.is_valid_face(gear.helmet_face))
	assert_between(int(look.skin), 0, SkinToneRegistry.TONES.size() - 1)

	var junk: Dictionary = REPLAY_VIEWER.cosmetics_from_entry({
		"tape_code": "not a number", "gear_style_code": [], "skin_tone": null,
	})
	assert_eq((junk.tape as StickTapeConfig).to_code(), StickTapeConfig.DEFAULT_CODE)
	assert_eq((junk.gear as GearStyleConfig).to_code(), GearStyleConfig.DEFAULT_CODE)
	assert_eq(int(junk.skin), SkinToneRegistry.DEFAULT_INDEX)
