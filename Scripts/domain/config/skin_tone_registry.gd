class_name SkinToneRegistry
extends RefCounted

# The skin-tone palette. Part of a player's identity next to name / number /
# handedness: PlayerPrefs stores it, the edit-player popup picks it, and the
# join/spawn wire carries it — always as an INDEX into this table, never a
# raw color, so the wire coerces cleanly (clamp_index) and the save stays
# valid if the palette is retuned. Bots may set "skin" in bot_identities.json;
# without one they draw a stable tone from their name hash (PlayerRegistry).
#
# Six steps light→deep on a warm ramp (cool-shifted skin reads corpse-like
# under the rink's already-cool light). Referenced by index everywhere, so
# ORDER IS SAVE FORMAT — append new tones, never reorder.
const TONES: Array[Color] = [
	Color(0.98, 0.84, 0.72),
	Color(0.93, 0.75, 0.60),
	Color(0.84, 0.63, 0.47),
	Color(0.66, 0.46, 0.32),
	Color(0.47, 0.31, 0.21),
	Color(0.30, 0.20, 0.14),
]
const DEFAULT_INDEX: int = 2


static func clamp_index(index: int) -> int:
	return clampi(index, 0, TONES.size() - 1)


static func color_for(index: int) -> Color:
	return TONES[clamp_index(index)]
