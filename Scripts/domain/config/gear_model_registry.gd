class_name GearModelRegistry
extends RefCounted

# The catalogue of skate and glove MODELS — the equipment a player picks in the
# gear workbench. A model is not a color pick: it is a fixed design that paints
# every zone of the piece at once, the way buying a real pair decides the boot,
# the ankle cuff and the accent band together. Every zone paints from the three
# slots real gear is built out of — black, white, and the wearer's team color —
# so a design reads as itself on every kit while still belonging to it.
#
# Zones are the paintable surfaces the rig already carries: a skate is
# BOOT / COLLAR / STRIPE (the band ringing the ankle collar), a glove is
# BODY / CUFF. Laces are NOT part of a model — players pick those apart from
# the skate, as they do at the rink.
#
# The catalogue is wire data: model indices travel in the packed GearStyleConfig
# code, so rows must only ever be APPENDED — reordering or removing one silently
# re-equips every player who had picked it.
#
# Index 0 of each list is the design the game shipped before models existed
# (all-black skate, kit-colored glove), so an untouched player looks unchanged.

enum Paint { BLACK, WHITE, TEAM }

# Zone order within a model row — also the left-to-right order the workbench
# draws a model's swatch strip in, outermost piece first.
const SKATE_BOOT: int = 0
const SKATE_COLLAR: int = 1
const SKATE_STRIPE: int = 2
const SKATE_ZONE_COUNT: int = 3
const GLOVE_BODY: int = 0
const GLOVE_CUFF: int = 1
const GLOVE_ZONE_COUNT: int = 2

# Synthetic-leather black and the off-white real gear is dyed in. BLACK matches
# the boot dark every skater wore before models existed, so model 0 is a
# pixel-identical skate.
const BLACK := Color(0.08, 0.08, 0.08)
const WHITE := Color(0.90, 0.90, 0.90)

# Named rows, so callers that mean a specific design (the pre-models save
# migration, tests) say which one instead of carrying a bare index.
const SKATE_BLACKOUT: int = 0
const SKATE_TEAM: int = 1
const SKATE_RETRO: int = 2
const SKATE_WHITEOUT: int = 3
const SKATE_TWO_TONE: int = 4
const SKATE_PRO: int = 5

const SKATE_NAME_KEYS: Array[StringName] = [
	&"GEAR_MODEL_BLACKOUT",
	&"GEAR_MODEL_TEAM",
	&"GEAR_MODEL_RETRO",
	&"GEAR_MODEL_WHITEOUT",
	&"GEAR_MODEL_TWO_TONE",
	&"GEAR_MODEL_PRO",
]

# (boot, collar, stripe) per model, index-aligned with SKATE_NAME_KEYS.
const _SKATE_MODELS: Array[Vector3i] = [
	Vector3i(Paint.BLACK, Paint.BLACK, Paint.BLACK),   # Blackout — the stock pro skate
	Vector3i(Paint.BLACK, Paint.BLACK, Paint.TEAM),    # Team — black boot, team band
	Vector3i(Paint.BLACK, Paint.WHITE, Paint.BLACK),   # Retro — the old white ankle cuff
	Vector3i(Paint.WHITE, Paint.WHITE, Paint.TEAM),    # Whiteout — white boot, team band
	Vector3i(Paint.WHITE, Paint.BLACK, Paint.BLACK),   # Two-Tone — white boot, black cuff
	Vector3i(Paint.BLACK, Paint.TEAM, Paint.WHITE),    # Pro — team cuff under a white band
]

const GLOVE_TEAM: int = 0
const GLOVE_PRO: int = 1
const GLOVE_BLACKOUT: int = 2
const GLOVE_CONTRAST: int = 3
const GLOVE_VINTAGE: int = 4
const GLOVE_TWO_TONE: int = 5

const GLOVE_NAME_KEYS: Array[StringName] = [
	&"GEAR_MODEL_TEAM",
	&"GEAR_MODEL_PRO",
	&"GEAR_MODEL_BLACKOUT",
	&"GEAR_MODEL_CONTRAST",
	&"GEAR_MODEL_VINTAGE",
	&"GEAR_MODEL_TWO_TONE",
]

# (body, cuff) per model, index-aligned with GLOVE_NAME_KEYS.
const _GLOVE_MODELS: Array[Vector2i] = [
	Vector2i(Paint.TEAM, Paint.TEAM),     # Team — the kit glove, cuff and all
	Vector2i(Paint.TEAM, Paint.WHITE),    # Pro — kit body, white cuff
	Vector2i(Paint.BLACK, Paint.BLACK),   # Blackout
	Vector2i(Paint.BLACK, Paint.TEAM),    # Contrast — black body, team cuff
	Vector2i(Paint.WHITE, Paint.TEAM),    # Vintage — white body, team cuff
	Vector2i(Paint.TEAM, Paint.BLACK),    # Two-Tone — kit body, black cuff
]


static func skate_count() -> int:
	return _SKATE_MODELS.size()


static func glove_count() -> int:
	return _GLOVE_MODELS.size()


static func is_valid_skate(model: int) -> bool:
	return model >= 0 and model < _SKATE_MODELS.size()


static func is_valid_glove(model: int) -> bool:
	return model >= 0 and model < _GLOVE_MODELS.size()


# The paint for one zone of a skate model. `team_color` is the team ACCENT —
# skates wear the accent where a glove wears the kit's own glove color. An
# out-of-range model (a forged wire code, a future catalogue) paints model 0,
# matching from_code's clamp rather than throwing at the paint seam.
static func skate_color(model: int, zone: int, team_color: Color) -> Color:
	var row: Vector3i = _SKATE_MODELS[model] if is_valid_skate(model) else _SKATE_MODELS[0]
	return resolve(row[zone], team_color)


# The paint for one zone of a glove model. `team_color` is the kit's GLOVE
# color, so a TEAM zone matches the jersey's gloves rather than the accent.
static func glove_color(model: int, zone: int, team_color: Color) -> Color:
	var row: Vector2i = _GLOVE_MODELS[model] if is_valid_glove(model) else _GLOVE_MODELS[0]
	return resolve(row[zone], team_color)


static func resolve(paint: int, team_color: Color) -> Color:
	match paint:
		Paint.BLACK:
			return BLACK
		Paint.WHITE:
			return WHITE
		_:
			return team_color
