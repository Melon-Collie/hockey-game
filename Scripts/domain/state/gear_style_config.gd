class_name GearStyleConfig
extends RefCounted

# A player's gear cosmetics: skate boot color and glove color, each an index
# into the shared TapeColorRegistry palette. Cosmetic only — nothing gameplay
# reads it. Picked in the player screen's Equipment section and painted by
# SkaterUniformCoordinator.
#
# Travels the wire as one packed int (to_code/from_code) appended to the join
# and spawn payloads, like the tape code. from_code clamps every field, so a
# forged code lands on a legal look instead of being rejected.
#
# The TEAM sentinel resolves per slot at paint time: TEAM gloves take the
# kit's glove color (uniform.gloves — the pre-customization look), TEAM
# skates take the team accent. Defaults — skates BLACK, gloves TEAM — pack to
# the look every skater wore before gear cosmetics existed.

# 5 bits per color index, matching StickTapeConfig's palette headroom.
const _COLOR_BITS: int = 5
const _COLOR_MASK: int = (1 << _COLOR_BITS) - 1

# Palette index of the classic dark boot (TapeColorRegistry BLACK).
const SKATE_DEFAULT_INDEX: int = 2

# The all-default packed code (skates BLACK, gloves TEAM) — the wire default
# for every payload that carries a gear style code.
const DEFAULT_CODE: int = SKATE_DEFAULT_INDEX

var skate_color: int = SKATE_DEFAULT_INDEX
var glove_color: int = TapeColorRegistry.TEAM_INDEX


func _init(p_skate_color: int = SKATE_DEFAULT_INDEX,
		p_glove_color: int = TapeColorRegistry.TEAM_INDEX) -> void:
	skate_color = p_skate_color if TapeColorRegistry.is_valid(p_skate_color) \
			else SKATE_DEFAULT_INDEX
	glove_color = p_glove_color if TapeColorRegistry.is_valid(p_glove_color) \
			else TapeColorRegistry.TEAM_INDEX


func to_code() -> int:
	return skate_color | (glove_color << _COLOR_BITS)


static func from_code(code: int) -> GearStyleConfig:
	return GearStyleConfig.new(
			code & _COLOR_MASK,
			(code >> _COLOR_BITS) & _COLOR_MASK)
