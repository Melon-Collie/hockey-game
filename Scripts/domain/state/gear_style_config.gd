class_name GearStyleConfig
extends RefCounted

# A player's gear cosmetics: a skate MODEL, a glove MODEL, a lace color, a
# stick MODEL, and a helmet FACE option. The skate/glove picks are indices
# into GearModelRegistry — whole designs that paint every zone of the piece
# (boot / collar / accent band; glove body / cuff) out of black, white and
# the team's own colors, rather than a single accent color the player tints.
# The stick pick is an index into StickModelRegistry — a fixed shaft/blade
# colorway, because real sticks ship in their maker's colors whoever you play
# for. The lace pick stays an index into the shared TapeColorRegistry palette,
# because laces are chosen apart from the skate. The face pick is a
# GearModelRegistry FACE_* option (bare / visor / cage / fishbowl) — a fixed
# look, like the stick. Cosmetic only — nothing gameplay reads it.
# Skates/gloves/laces/face and the stick model are all picked in the locker;
# all painted by SkaterUniformCoordinator.
#
# Travels the wire as one packed int (to_code/from_code) appended to the join
# and spawn payloads, like the tape code. from_code clamps every field, so a
# forged code lands on a legal look instead of being rejected.
#
# Defaults — skate model 0 (all-black boot), glove model 0 (kit-colored body
# and cuff), laces WHITE, stick model 0 (the house MITTS stick), face 0
# (bare) — render the exact look every skater wore before gear cosmetics
# existed.

# 5 bits per field, matching StickTapeConfig's palette headroom.
const _FIELD_BITS: int = 5
const _FIELD_MASK: int = (1 << _FIELD_BITS) - 1
const _LACE_SHIFT: int = _FIELD_BITS * 2
const _STICK_SHIFT: int = _FIELD_BITS * 3
const _FACE_SHIFT: int = _FIELD_BITS * 4

# Palette index of the classic lace (TapeColorRegistry WHITE).
const LACE_DEFAULT_INDEX: int = 1

# TapeColorRegistry indices migrate_colors reads by name. Local constants
# rather than registry lookups: they are the values the OLD codes were written
# with, and must not drift if the palette is ever reordered.
const _TAPE_WHITE: int = 1
const _TAPE_BLACK: int = 2

# The all-default packed code — the wire default for every payload that carries
# a gear style code.
const DEFAULT_CODE: int = LACE_DEFAULT_INDEX << _LACE_SHIFT

var skate_model: int = 0
var glove_model: int = 0
var lace_color: int = LACE_DEFAULT_INDEX
var stick_model: int = 0
var helmet_face: int = GearModelRegistry.FACE_NONE


func _init(p_skate_model: int = 0, p_glove_model: int = 0,
		p_lace_color: int = LACE_DEFAULT_INDEX, p_stick_model: int = 0,
		p_helmet_face: int = GearModelRegistry.FACE_NONE) -> void:
	skate_model = p_skate_model if GearModelRegistry.is_valid_skate(p_skate_model) else 0
	glove_model = p_glove_model if GearModelRegistry.is_valid_glove(p_glove_model) else 0
	lace_color = p_lace_color if TapeColorRegistry.is_valid(p_lace_color) \
			else LACE_DEFAULT_INDEX
	stick_model = p_stick_model if StickModelRegistry.is_valid(p_stick_model) else 0
	helmet_face = p_helmet_face if GearModelRegistry.is_valid_face(p_helmet_face) \
			else GearModelRegistry.FACE_NONE


func to_code() -> int:
	return skate_model | (glove_model << _FIELD_BITS) | (lace_color << _LACE_SHIFT) \
			| (stick_model << _STICK_SHIFT) | (helmet_face << _FACE_SHIFT)


static func from_code(code: int) -> GearStyleConfig:
	return GearStyleConfig.new(
			code & _FIELD_MASK,
			(code >> _FIELD_BITS) & _FIELD_MASK,
			(code >> _LACE_SHIFT) & _FIELD_MASK,
			(code >> _STICK_SHIFT) & _FIELD_MASK,
			(code >> _FACE_SHIFT) & _FIELD_MASK)


# Maps a pre-models gear code (skate accent color, glove accent color, laces —
# all TapeColorRegistry indices) onto the nearest model design, so a saved
# look survives the switch instead of silently reverting to stock. Skates keep
# their intent — a black pick was the stock skate, white was a white boot,
# anything else was an accent band, which is what the Team model is. Gloves
# only ever tinted the CUFF, so every pick lands on a model whose body stays
# kit-colored.
static func migrate_colors(code: int) -> GearStyleConfig:
	var skate_color: int = code & _FIELD_MASK
	var glove_color: int = (code >> _FIELD_BITS) & _FIELD_MASK
	var skate_model: int = GearModelRegistry.SKATE_TEAM
	if skate_color == _TAPE_BLACK:
		skate_model = GearModelRegistry.SKATE_BLACKOUT
	elif skate_color == _TAPE_WHITE:
		skate_model = GearModelRegistry.SKATE_WHITEOUT
	var glove_model: int = GearModelRegistry.GLOVE_CONTRAST
	if glove_color == TapeColorRegistry.TEAM_INDEX:
		glove_model = GearModelRegistry.GLOVE_TEAM
	elif glove_color == _TAPE_WHITE:
		glove_model = GearModelRegistry.GLOVE_PRO
	return GearStyleConfig.new(skate_model, glove_model,
			(code >> _LACE_SHIFT) & _FIELD_MASK)
