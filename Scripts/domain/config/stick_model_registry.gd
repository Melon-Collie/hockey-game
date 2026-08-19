class_name StickModelRegistry
extends RefCounted

# The catalogue of stick MODELS — whole shaft/blade colorways, the way a real
# stick is bought as one design. Unlike the skate and glove catalogue
# (GearModelRegistry), rows are FIXED colors rather than team-slot paints:
# a real stick ships in its maker's colorway whoever you play for, and the
# player's color already rides the tape job.
#
# Every row past the house Stealth is inspired by a recognizable real-world
# stick without naming it (same convention as the M88/M92/M28 blade patterns
# for P88/P92/P28): Redline reads as a Vapor's red kick zone, Volt as a
# Ribcor's acid graphic, Split as an Alpha's grey upper over a black lower,
# Whiteout as the custom all-white pro look, Woodie as a varnished-ash wood
# stick.
#
# A model paints: the shaft base, the brand wordmark, up to two BANDS (color
# spans along the shaft, in real metres from an anchor end — the same
# object-space metric placement the wordmark uses, so a blade-anchored kick
# zone stays pinned at the blade whatever the build's cut length), and
# optionally the blade (base + carbon-weave pair, for wood). StickStyle turns
# a row into the shader materials; the tape job and grip wrap always paint
# over a band.
#
# The catalogue is wire data: the model index travels in the packed
# GearStyleConfig code, so rows must only ever be APPENDED — reordering or
# removing one silently re-equips every player who had picked it. Index 0 is
# the house MITTS stick — the stock look an untouched player carries.

const ANCHOR_BUTT: int = 0
const ANCHOR_BLADE: int = 1

const STICK_STEALTH: int = 0
const STICK_REDLINE: int = 1
const STICK_VOLT: int = 2
const STICK_SPLIT: int = 3
const STICK_WHITEOUT: int = 4
const STICK_WOODIE: int = 5

const NAME_KEYS: Array[StringName] = [
	&"STICK_MODEL_STEALTH",
	&"STICK_MODEL_REDLINE",
	&"STICK_MODEL_VOLT",
	&"STICK_MODEL_SPLIT",
	&"STICK_MODEL_WHITEOUT",
	&"STICK_MODEL_WOODIE",
]

# The classic composite finish (kept off the team palette — modern sticks are
# near-black) and the matte black a bare blade shows under its weave. Named so
# rows and the goalie/ghost paths share one value.
const SHAFT_CLASSIC := Color(0.06, 0.06, 0.07)
const BLADE_CLASSIC := Color(0.05, 0.05, 0.05)

# Row fields: `shaft` + `brand` always; `bands` is up to two
# {color, from_m, to_m, anchor} spans (from < to, metres from the anchor end);
# `blade` is {base, weave_a, weave_b} and only present when the model departs
# from the carbon look. Index-aligned with NAME_KEYS.
const _MODELS: Array[Dictionary] = [
	# Stealth — the house MITTS stick: near-black composite, white wordmark.
	{
		"shaft": SHAFT_CLASSIC,
		"brand": Color(1.0, 1.0, 1.0),
	},
	# Redline — black shaft with a red kick zone flooding up from the blade.
	{
		"shaft": SHAFT_CLASSIC,
		"brand": Color(0.72, 0.08, 0.12),
		"bands": [
			{"color": Color(0.72, 0.08, 0.12), "from_m": 0.0, "to_m": 0.50,
					"anchor": ANCHOR_BLADE},
		],
	},
	# Volt — black shaft, acid-green graphic block low on the shaft (the heel
	# stays black so the hosel reads apart from the graphic).
	{
		"shaft": SHAFT_CLASSIC,
		"brand": Color(0.45, 0.82, 0.10),
		"bands": [
			{"color": Color(0.45, 0.82, 0.10), "from_m": 0.12, "to_m": 0.55,
					"anchor": ANCHOR_BLADE},
		],
	},
	# Split — grey upper half over a black lower, one orange seam ring. The
	# wordmark sits inside the grey zone, so it goes black to keep reading.
	{
		"shaft": SHAFT_CLASSIC,
		"brand": Color(0.05, 0.05, 0.05),
		"bands": [
			{"color": Color(0.60, 0.61, 0.63), "from_m": 0.0, "to_m": 0.78,
					"anchor": ANCHOR_BUTT},
			{"color": Color(0.93, 0.42, 0.05), "from_m": 0.44, "to_m": 0.52,
					"anchor": ANCHOR_BLADE},
		],
	},
	# Whiteout — the custom all-white pro look, wordmark flipped to black.
	{
		"shaft": Color(0.90, 0.90, 0.88),
		"brand": Color(0.07, 0.07, 0.08),
	},
	# Woodie — varnished ash, burnt-in dark wordmark, and the one blade
	# departure: wood tones instead of carbon weave.
	{
		"shaft": Color(0.50, 0.34, 0.16),
		"brand": Color(0.15, 0.09, 0.04),
		"blade": {
			"base": Color(0.45, 0.31, 0.15),
			"weave_a": Color(0.47, 0.32, 0.15),
			"weave_b": Color(0.41, 0.27, 0.12),
		},
	},
]


static func count() -> int:
	return _MODELS.size()


static func is_valid(model: int) -> bool:
	return model >= 0 and model < _MODELS.size()


# An out-of-range model (a forged wire code, a future catalogue) reads as the
# house stick, matching GearStyleConfig.from_code's clamp rather than throwing
# at the paint seam.
static func _row(model: int) -> Dictionary:
	return _MODELS[model] if is_valid(model) else _MODELS[STICK_STEALTH]


static func shaft_color(model: int) -> Color:
	return _row(model)["shaft"]


static func brand_color(model: int) -> Color:
	return _row(model)["brand"]


# Up to two {color, from_m, to_m, anchor} spans; empty for a plain shaft.
static func bands(model: int) -> Array:
	return _row(model).get("bands", [])


static func has_blade_override(model: int) -> bool:
	return _row(model).has("blade")


# The matte color a bare blade shows (ghost stand-ins, under-weave).
static func blade_base_color(model: int) -> Color:
	var row: Dictionary = _row(model)
	return row["blade"]["base"] if row.has("blade") else BLADE_CLASSIC


# The blade's checker pair; the carbon defaults unless the row overrides.
static func blade_weave_colors(model: int) -> Array[Color]:
	var row: Dictionary = _row(model)
	if row.has("blade"):
		return [row["blade"]["weave_a"], row["blade"]["weave_b"]]
	return []


# The colors a UI swatch strip shows for one model: shaft, then each band,
# then the wordmark — the parts of the design that read at chip size.
static func swatch_colors(model: int) -> Array[Color]:
	var colors: Array[Color] = [shaft_color(model)]
	for band: Dictionary in bands(model):
		colors.append(band["color"])
	colors.append(brand_color(model))
	return colors
