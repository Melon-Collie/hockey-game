class_name GearStyleConfig
extends RefCounted

# A player's gear cosmetics: skate stripe, glove stripe, and lace colors,
# each an index into the shared TapeColorRegistry palette. The picks paint
# accents, not whole pieces — the skate color goes on the band ringing the
# boot collar (the boot stays dark), the glove color on the wrist cuff rings
# (the hands stay kit-colored), and the lace color on the instep lace rungs.
# Cosmetic only — nothing gameplay reads it. Picked in the gear workbench and
# painted by SkaterUniformCoordinator.
#
# Travels the wire as one packed int (to_code/from_code) appended to the join
# and spawn payloads, like the tape code. from_code clamps every field, so a
# forged code lands on a legal look instead of being rejected.
#
# The TEAM sentinel resolves per slot at paint time: TEAM gloves take the
# kit's glove color (uniform.gloves), TEAM skates and laces take the team
# accent. Defaults — skates BLACK (a dark band on the dark boot), gloves TEAM
# (a kit-colored cuff on kit gloves), laces WHITE (the classic lace) — render
# the exact look every skater wore before gear cosmetics existed.

# 5 bits per color index, matching StickTapeConfig's palette headroom.
const _COLOR_BITS: int = 5
const _COLOR_MASK: int = (1 << _COLOR_BITS) - 1
const _LACE_SHIFT: int = _COLOR_BITS * 2

# Palette index of the classic dark boot band (TapeColorRegistry BLACK).
const SKATE_DEFAULT_INDEX: int = 2
# Palette index of the classic lace (TapeColorRegistry WHITE).
const LACE_DEFAULT_INDEX: int = 1

# The all-default packed code (skates BLACK, gloves TEAM, laces WHITE) — the
# wire default for every payload that carries a gear style code.
const DEFAULT_CODE: int = SKATE_DEFAULT_INDEX | (LACE_DEFAULT_INDEX << _LACE_SHIFT)

var skate_color: int = SKATE_DEFAULT_INDEX
var glove_color: int = TapeColorRegistry.TEAM_INDEX
var lace_color: int = LACE_DEFAULT_INDEX


func _init(p_skate_color: int = SKATE_DEFAULT_INDEX,
		p_glove_color: int = TapeColorRegistry.TEAM_INDEX,
		p_lace_color: int = LACE_DEFAULT_INDEX) -> void:
	skate_color = p_skate_color if TapeColorRegistry.is_valid(p_skate_color) \
			else SKATE_DEFAULT_INDEX
	glove_color = p_glove_color if TapeColorRegistry.is_valid(p_glove_color) \
			else TapeColorRegistry.TEAM_INDEX
	lace_color = p_lace_color if TapeColorRegistry.is_valid(p_lace_color) \
			else LACE_DEFAULT_INDEX


func to_code() -> int:
	return skate_color | (glove_color << _COLOR_BITS) | (lace_color << _LACE_SHIFT)


static func from_code(code: int) -> GearStyleConfig:
	return GearStyleConfig.new(
			code & _COLOR_MASK,
			(code >> _COLOR_BITS) & _COLOR_MASK,
			(code >> _LACE_SHIFT) & _COLOR_MASK)
