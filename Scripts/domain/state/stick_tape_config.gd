class_name StickTapeConfig
extends RefCounted

# A player's tape job: blade wrap color + coverage, and butt-end knob color.
# Cosmetic only — nothing gameplay reads it. Today it is authored by the
# player-settings picker; the seam is deliberately author-agnostic so a future
# taping flow (or gear presets) can produce one the same way.
#
# Travels the wire as one packed int (to_code/from_code) appended to the join
# and spawn payloads, like the attribute gear ints. from_code clamps every
# field, so a forged code lands on a legal tape job instead of being rejected.

# Coverage presets, heel→toe spans in blade-length fractions (span_range).
# WIRE VALUES — append only. HEEL_TO_MID sits at 0 so the all-default config
# packs to code 0: a payload that omits the field (an older entry, a bot)
# decodes to exactly the pre-customization look.
enum Span { HEEL_TO_MID, TOE, MID, FULL, NONE }

# u ranges per span (x = start, y = end; u: 0 = heel, 1 = toe). Spans that
# include the heel start slightly negative so the tape's heel cap sits proud
# of the blade's own heel cap instead of z-fighting it coplanar.
const _HEEL_OVERHANG: float = -0.02
const _SPAN_RANGES: Array[Vector2] = [
	Vector2(_HEEL_OVERHANG, 0.62),  # HEEL_TO_MID — the long-time house look
	Vector2(0.55, 1.0),             # TOE
	Vector2(0.22, 0.72),            # MID — the classic middle patch
	Vector2(_HEEL_OVERHANG, 1.0),   # FULL
	Vector2(0.0, 0.0),              # NONE — no band at all
]

# The all-default packed code (blade TEAM, span HEEL_TO_MID, knob TEAM) — the
# wire default for every payload that carries a tape code.
const DEFAULT_CODE: int = 0

# Code packing: 5 bits per color index (palette growth headroom), 3 bits span.
const _COLOR_BITS: int = 5
const _COLOR_MASK: int = (1 << _COLOR_BITS) - 1
const _SPAN_MASK: int = 0x7

var blade_color: int = TapeColorRegistry.TEAM_INDEX
var span: int = Span.HEEL_TO_MID
var knob_color: int = TapeColorRegistry.TEAM_INDEX


func _init(p_blade_color: int = TapeColorRegistry.TEAM_INDEX,
		p_span: int = Span.HEEL_TO_MID,
		p_knob_color: int = TapeColorRegistry.TEAM_INDEX) -> void:
	blade_color = _clamp_color(p_blade_color)
	span = clampi(p_span, 0, Span.size() - 1)
	knob_color = _clamp_color(p_knob_color)


static func _clamp_color(index: int) -> int:
	return index if TapeColorRegistry.is_valid(index) else TapeColorRegistry.TEAM_INDEX


func has_blade_tape() -> bool:
	return span != Span.NONE


# Heel→toe u range of the wrap for this span (meaningless for NONE — gate on
# has_blade_tape first).
func span_range() -> Vector2:
	return _SPAN_RANGES[span]


func to_code() -> int:
	return blade_color | (span << _COLOR_BITS) \
			| (knob_color << (_COLOR_BITS + 3))


static func from_code(code: int) -> StickTapeConfig:
	return StickTapeConfig.new(
			code & _COLOR_MASK,
			(code >> _COLOR_BITS) & _SPAN_MASK,
			(code >> (_COLOR_BITS + 3)) & _COLOR_MASK)
