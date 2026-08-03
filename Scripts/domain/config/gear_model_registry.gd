class_name GearModelRegistry
extends RefCounted

# The catalogue of skate and glove MODELS — the equipment a player picks in the
# locker — plus the helmet FACE options (visor / cage / fishbowl; see
# their own section below). A model is not a color pick: it is a fixed design
# that paints every zone of the piece at once, the way buying a real pair
# decides the boot, the ankle cuff and the accent band together.
#
# Zones paint from four SLOTS, three of which are the wearer's own kit, so a
# design reads as itself on every team while still belonging to that team:
#
#   BLACK   true black, and SKATES ONLY. Boot leather is black whoever you
#           play for, and the stealth design wants a black that no kit can
#           tint. Gloves never reach for it: a real glove is made in the
#           team's colors, and no team here has black among theirs, so a black
#           glove would belong to nobody.
#   LIGHT   the team's own white — `light` in the preset, which is CREAM for
#           some teams (Pomegranate, Plum) and pure white for the rest. It is
#           already what their away jersey is painted, so their gear matches
#           the sweater instead of out-whiting it.
#   TEAM    the primary for skates; for gloves the kit's OWN glove color, so
#           an untouched glove still matches the sweater's gloves.
#   ACCENT  the team's second color. A real kit has two and a real piece wears
#           both — team-stock gloves ship in three-color kit colorways (the
#           Canadiens' is royal / red / white). On skates this is the preset's
#           secondary; on GLOVES it is `glove_accent`, which is whichever team
#           color the glove body is not, because five of the eight presets
#           dress their gloves in the secondary already.
#
# Zones are the paintable surfaces the rig carries: a skate is QUARTER (the
# boot's heel-through-instep shell) / TOE cap / COLLAR / STRIPE (the band
# ringing the ankle collar) / HOLDER (the plastic the steel bolts into), a
# glove is BODY (the back of the hand) / FINGERS / CUFF. The steel RUNNER is
# deliberately not a zone — NOT because steel is always bare (CCM's JetSpeed
# ships STEP Blacksteel, a carbon-coated black runner, on the most-worn CCM
# skate in the league) but because it is a few millimetres of the silhouette
# below the holder's rail, and a zone every design would spend a swatch band
# on to say the same thing. Laces are not part of a model either; players pick
# those apart from the skate, as they do at the rink.
#
# The catalogue is wire data: model indices travel in the packed GearStyleConfig
# code, so rows must only ever be APPENDED — reordering or removing one silently
# re-equips every player who had picked it.
#
# Index 0 of each list is the stock design (all-black skate, kit-colored
# glove), which is what an untouched player wears. The one deliberate
# departure from the pre-models look is the blade HOLDER: it used to render
# steel along with the runner, which read as one gray lump under the boot.
# Real holders are molded plastic and essentially always white, so every row
# including Blackout wears one — which makes the stock skate a black boot on a
# white holder, the median NHL skate rather than a stealth colorway.

enum Paint { BLACK, LIGHT, TEAM, ACCENT }

# Zone order within a model row — also the left-to-right order the workbench
# draws a model's swatch strip in, outermost piece first.
const SKATE_QUARTER: int = 0
const SKATE_TOE: int = 1
const SKATE_COLLAR: int = 2
const SKATE_STRIPE: int = 3
const SKATE_HOLDER: int = 4
const SKATE_ZONE_COUNT: int = 5
const GLOVE_BODY: int = 0
const GLOVE_FINGERS: int = 1
const GLOVE_CUFF: int = 2
const GLOVE_ZONE_COUNT: int = 3

# Synthetic-leather black — the boot dark every skater wore before models
# existed. The other three slots have no constant here: they are the kit's.
const BLACK := Color(0.08, 0.08, 0.08)

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

# (quarter, toe, collar, stripe, holder) per model, index-aligned with
# SKATE_NAME_KEYS. The quarter and toe only ever take BLACK or LIGHT: a boot is
# leather, and a boot in a team's secondary would stop reading as a skate.
#
# The HOLDER is LIGHT on every row. Holders are conventionally molded white —
# black was the early default, back when it matched the boot, and white
# displaced it — and on the ice they are white essentially without exception,
# so no design gets to depart from it, not even the blackout. It stays a zone
# rather than a constant only because the rows are where a future design would
# reach for a black or team-colored holder; nothing today does.
#
# The light is the TEAM's white, so a cream-white kit gets a cream holder. A
# real holder would be the same plastic white on every player, but a design
# that belongs to the sweater beats that fidelity.
const _SKATE_MODELS: Array[Array] = [
	# Blackout — a black boot on a white holder, which is the median NHL skate.
	[Paint.BLACK, Paint.BLACK, Paint.BLACK, Paint.BLACK, Paint.LIGHT],
	# Team — black boot, the primary on the band.
	[Paint.BLACK, Paint.BLACK, Paint.BLACK, Paint.TEAM, Paint.LIGHT],
	# Retro — the classic Tacks: light toe cap and ankle over a black boot.
	[Paint.BLACK, Paint.LIGHT, Paint.LIGHT, Paint.ACCENT, Paint.LIGHT],
	# Whiteout — light through the boot with a primary band.
	[Paint.LIGHT, Paint.LIGHT, Paint.LIGHT, Paint.TEAM, Paint.LIGHT],
	# Two-Tone — the flagship silhouette (a Vapor Hyperlite reads as a light
	# quarter running into a dark toe under one bright band at the ankle).
	[Paint.LIGHT, Paint.BLACK, Paint.BLACK, Paint.ACCENT, Paint.LIGHT],
	# Pro — black boot, light toe cap, secondary band.
	[Paint.BLACK, Paint.LIGHT, Paint.BLACK, Paint.ACCENT, Paint.LIGHT],
]

const GLOVE_TEAM: int = 0
const GLOVE_PRO: int = 1
const GLOVE_CONTRAST: int = 2
const GLOVE_VINTAGE: int = 3
const GLOVE_TWO_TONE: int = 4
const GLOVE_TRICOLOR: int = 5

const GLOVE_NAME_KEYS: Array[StringName] = [
	&"GEAR_MODEL_TEAM",
	&"GEAR_MODEL_PRO",
	&"GEAR_MODEL_CONTRAST",
	&"GEAR_MODEL_VINTAGE",
	&"GEAR_MODEL_TWO_TONE",
	&"GEAR_MODEL_TRICOLOR",
]

# (body, fingers, cuff) per model, index-aligned with GLOVE_NAME_KEYS. Built
# from the kit alone — no BLACK anywhere, because a glove is made in the team's
# colors and none of these teams has black among theirs.
const _GLOVE_MODELS: Array[Array] = [
	[Paint.TEAM, Paint.TEAM, Paint.TEAM],       # Team — the kit glove, cuff and all
	[Paint.TEAM, Paint.TEAM, Paint.LIGHT],      # Pro — kit glove, white cuff roll
	[Paint.TEAM, Paint.ACCENT, Paint.ACCENT],   # Contrast — second color on fingers and cuff
	[Paint.LIGHT, Paint.TEAM, Paint.TEAM],      # Vintage — white back, kit fingers
	[Paint.ACCENT, Paint.TEAM, Paint.TEAM],     # Two-Tone — the pairing flipped
	[Paint.TEAM, Paint.ACCENT, Paint.LIGHT],    # Tri-Color — the full kit colorway
]


# ── Helmet face gear ─────────────────────────────────────────────────────────
# The face options are fixed LOOKS, not paint rows: a visor is smoked
# polycarbonate and a cage is bare steel whoever wears them, so unlike the
# model lists nothing here resolves against the kit. Same wire rules though —
# indices ride the packed GearStyleConfig code, rows are append-only, and
# index 0 (bare) is what an untouched player wears. Cosmetic only: no option
# reads or writes anything gameplay (a vision tradeoff would be a fidelity
# lever, which the attributes constitution bans).

const FACE_NONE: int = 0
const FACE_VISOR: int = 1
const FACE_CAGE: int = 2
const FACE_FISHBOWL: int = 3

const FACE_NAME_KEYS: Array[StringName] = [
	&"GEAR_FACE_NONE",
	&"GEAR_FACE_VISOR",
	&"GEAR_FACE_CAGE",
	&"GEAR_FACE_FISHBOWL",
]

# Albedo (alpha included — the shields are transparent by design) per option,
# index-aligned with FACE_NAME_KEYS. Row 0 is unused (bare = no piece) but
# keeps the tables aligned with the names.
const _FACE_COLORS: Array[Color] = [
	Color(0, 0, 0, 0),                    # FACE_NONE — no piece
	Color(0.10, 0.11, 0.13, 0.42),        # visor — smoked polycarbonate
	Color(0.13, 0.13, 0.14, 1.0),         # cage — dark welded steel
	Color(0.85, 0.92, 0.97, 0.18),        # fishbowl — near-clear full shield
]

const _FACE_ROUGHNESS: Array[float] = [
	0.0,
	0.05,   # visor gloss
	0.35,   # painted steel
	0.04,   # fishbowl gloss
]


static func face_count() -> int:
	return FACE_NAME_KEYS.size()


static func is_valid_face(option: int) -> bool:
	return option >= 0 and option < FACE_NAME_KEYS.size()


# The fixed look of one face option. A forged index reads the bare row (which
# renders nothing), matching from_code's clamp rather than throwing here.
static func face_color(option: int) -> Color:
	return _FACE_COLORS[option] if is_valid_face(option) else _FACE_COLORS[FACE_NONE]


static func face_roughness(option: int) -> float:
	return _FACE_ROUGHNESS[option] if is_valid_face(option) else 0.0


static func skate_count() -> int:
	return _SKATE_MODELS.size()


static func glove_count() -> int:
	return _GLOVE_MODELS.size()


static func is_valid_skate(model: int) -> bool:
	return model >= 0 and model < _SKATE_MODELS.size()


static func is_valid_glove(model: int) -> bool:
	return model >= 0 and model < _GLOVE_MODELS.size()


# The paint for one zone of a skate model. `team` is the kit's PRIMARY —
# skates wear the primary where a glove wears the kit's own glove color. An
# out-of-range model (a forged wire code, a future catalogue) paints model 0,
# matching from_code's clamp rather than throwing at the paint seam.
static func skate_color(model: int, zone: int, team: Color, accent: Color,
		light: Color) -> Color:
	var row: Array = _SKATE_MODELS[model] if is_valid_skate(model) else _SKATE_MODELS[0]
	return resolve(int(row[zone]), team, accent, light)


# The paint for one zone of a glove model. `team` is the kit's GLOVE color, so
# a TEAM zone matches the sweater's gloves rather than the primary.
static func glove_color(model: int, zone: int, team: Color, accent: Color,
		light: Color) -> Color:
	var row: Array = _GLOVE_MODELS[model] if is_valid_glove(model) else _GLOVE_MODELS[0]
	return resolve(int(row[zone]), team, accent, light)


static func resolve(paint: int, team: Color, accent: Color, light: Color) -> Color:
	match paint:
		Paint.BLACK:
			return BLACK
		Paint.LIGHT:
			return light
		Paint.ACCENT:
			return accent
		_:
			return team
