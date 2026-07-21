class_name PlayerAttributes
extends RefCounted

# PlayerAttributes
# ----------------
# Per-skater build on the v4 BODY + GEAR model (docs/attributes-v4-plan.md).
# A build is:
#
#   • HEIGHT — a free CONTINUOUS dial in inches (every inch 5'8"..6'7"). Tables
#     are authored at 5 anchor heights and interpolate. Height decides reach,
#     the speed↔agility baseline fork (speed hump peaks at 6'1", agility
#     small-favored) and the shot-power baseline (big-favored).
#   • WEIGHT — a free CONTINUOUS dial in pounds, bounded per height by ONE
#     authored BMI band (24.0 LEAN .. 29.0 HEAVY, neutral 26.5): a single
#     interval generates a plausible pounds range at every inch, so implausible
#     bodies (6'6"/160) are unrepresentable by construction. Weight decides
#     mass (linearly — mass IS the physical/checking system now), the
#     accel↔momentum fork (lean = first-step burst; momentum is mass-emergent),
#     an agility bite (F = mv²/r — heavy turns wide and stops long, the
#     counterweight that makes the dial a real seesaw; glide is exempt so the
#     tank still coasts), hitbox width (tracks the visual frame bulk) and the
#     stamina metabolism fork (lean = shallow pool / fast regen).
#   • GEAR — four discrete slots (skate profile, blade curve, stick flex,
#     stick length), three options each, all LATERAL (no net power).
#     **Slot status: STICK LENGTH is live (leans stick_len_mult — reach and
#     the blade-cap lever derivation follow); profile / curve / flex are
#     stored, replicated and validated but have ZERO gameplay effect until
#     their landing stages.**
#
# There is NO power economy: no tiers, no strong/weak shape, no legality
# beyond range coercion. Body dials are lateral; gear is lateral; validation
# is a clamp (coerce_height / coerce_weight / gear clamps), never a rejection.
#
# THE CONSTITUTION (see the plan doc §1) — categories a lever may scale:
#   outputs (body physics) and geometry (reach/lever/workspace) — fair game;
#   FIDELITY (how faithfully the blade tracks the cursor) — never. There is
#   deliberately no hands table of any kind: hands_blade_mult() is 1.0 for
#   every build. Hands differentiation arrives as lever GEOMETRY (stick
#   length → tip speed vs inertia) in a later stage, never as a multiplier.
#
# Neutral reference is 6'1" / 201 lbs / all-balanced gear: every gameplay
# multiplier is 1.0 there, so a neutral build plays and looks identical to
# the shipped @export defaults. (201 lbs = BMI 26.5 at 73" — the real
# NHL-average frame.)
#
# All tuning tables live in this file as private consts, consumed via the
# named accessors below — never index a `_*` table outside this file.
#
# To add a new "height/weight X scales Y" rule:
#   1. Add a table: `_FOO_H: Array[float]` (5-vec, height anchors) or
#      `_FOO_F: Array[float]` (5-vec, frame anchors lean→heavy).
#   2. Add an accessor `func foo_mult() -> float` returning `_h(...)`/`_f(...)`.
#   3. Multiply a captured base in SkaterController.apply_attributes /
#      SkaterAppearanceCoordinator.apply.
#
# Persistence: PlayerPrefs (attr_scale_version 5; older saves migrate via
# migrate_tiers / migrate_legacy), BotIdentityRegistry (bot picks),
# NetworkManager peer table (6 ints replicated at join, PROTOCOL v36).

# Height is stored in INCHES and is a free CONTINUOUS dial: every inch from
# 5'8" (68) to 6'7" (79) is playable. Tables are authored at 5 anchor heights
# (ANCHOR_INCHES); heights in between linearly interpolate the adjacent rows.
const HEIGHT_MIN: int = 68     # 5'8"
const HEIGHT_MEDIUM: int = 73  # 6'1"  (neutral)
const HEIGHT_MAX: int = 79     # 6'7"

# The 5 height table rows sit at these heights (inches). 5'10" (row 1) is the
# mesh-native anchor where the reach/height multiplier is exactly 1.0.
const ANCHOR_INCHES: Array[int] = [68, 70, 73, 76, 79]  # 5'8"..6'7"

# ── Weight band (single BMI interval — see plan doc §3.2) ─────────────────────
# One authored band generates the per-height pounds range: lbs = BMI·in²/703.
# Anchors are equally spaced (1.25 BMI) so frame interpolation is uniform.
# Calibration namechecks: neutral = 6'1"/201 (NHL-average build); McDavid
# (6'1"/194) lean-mid; DeBrincat (5'8"/180) ≈ SOLID; Ovechkin (6'3"/238) =
# 6'4"-HEAVY exactly; Tage Thompson (6'6"/218) ≈ tall-LEAN.
const BMI_LEAN: float = 24.0
const BMI_MEDIUM: float = 26.5   # neutral frame
const BMI_HEAVY: float = 29.0
const BMI_ANCHOR_STEP: float = 1.25  # anchor spacing: 24.0 .. 29.0 in 5 rows

# Neutral mass reference (lbs): BMI 26.5 at 73" → round(26.5·73²/703) = 201.
# mass_mult is LINEAR in displayed weight — deliberately wider than v3's
# minor height edge (0.79..1.28, a 1.63× spread): with no Checking stat, mass
# is the physical system, feeding delivery and brace through the collision
# resolver's reduced-mass math. Escape hatch if too swingy: compress with an
# exponent ((lbs/201)^p, p ≤ 1) — physics gives the shape, playtest the
# magnitude.
const NEUTRAL_WEIGHT_LBS: float = 201.0

# ── Gear slots (step 1: stored + replicated, ZERO gameplay effect) ───────────
# Every slot is 0/1/2 with 1 = the balanced/neutral option. Options are
# discrete and chunky by design (the loft-level pattern) — never sliders.
const GEAR_BALANCED: int = 1

const PROFILE_AGILITY: int = 0   # +accel / first step / cornering, −top speed
const PROFILE_BALANCED: int = 1
const PROFILE_POWER: int = 2     # +top speed / glide, −agility

const CURVE_CLOSED: int = 0      # hardest to elevate, best backhand
const CURVE_BALANCED: int = 1
const CURVE_OPEN: int = 2        # easier elevation (FLAT/LOW), quick release, worst backhand

const FLEX_LOW: int = 0          # whippy: −power ceiling, shortest runway/wind-up
const FLEX_MEDIUM: int = 1
const FLEX_HIGH: int = 2         # stiff: +power ceiling, longest runway/wind-up

const LENGTH_SHORT: int = 0      # −reach, snappiest reversal, finest close control
const LENGTH_STANDARD: int = 1
const LENGTH_LONG: int = 2       # +reach / tip speed / contest momentum, +inertia

# ── Gameplay tables — height-indexed (5 rows at ANCHOR_INCHES) ────────────────
# Values are the v3 average-tier column: the v4 body plane is authored around
# the old no-strength-no-weakness builds, so a v4 body reproduces the exact
# behavior a v3 all-average build of the same height had. Gear (later stages)
# re-widens the spread laterally.

# Speed baseline (max_speed). The hump: top speed peaks at medium height.
const _SPEED_H: Array[float] = [0.990, 0.995, 1.000, 0.995, 0.990]

# Agility baseline (turn rate / brake / facing / lateral). Small-favored.
const _AGILITY_H: Array[float] = [1.050, 1.020, 1.000, 0.960, 0.930]

# Shot-power baseline (charged wrister/slapper ceiling). Big-favored — the
# leverage a long frame loads into a shot. Wind-up derives inversely.
const _SHOT_H: Array[float] = [0.900, 0.940, 1.000, 1.050, 1.090]

# Hitbox cylinder radius — frame width. Height sets the skeleton's breadth…
const _RADIUS: Array[float] = [0.95, 0.975, 1.00, 1.05, 1.10]
# …and the frame widens it (a heavy body IS wider — matches the visual frame
# bulk, so the hitbox tracks the silhouette): bigger poke target and net-front
# screen for the heavy build, slimmer profile for the lean one.
const _RADIUS_F: Array[float] = [0.96, 0.98, 1.00, 1.03, 1.06]

# Body height (mesh Y-scale, arm/ROM length, hand heights). Mesh-native 5'10"
# is row 1, so the 1.0 identity sits there (NOT the 6'1" gameplay neutral).
const _HEIGHT: Array[float] = [0.971, 1.000, 1.043, 1.086, 1.129]

# Stick length — equipment, ~0.65× the height deviation from mesh-native 5'10".
# Height sets the BAND CENTER (real sticks are cut to the body)…
const _STICK_LEN: Array[float] = [0.981, 1.000, 1.028, 1.056, 1.084]
# …and the LENGTH gear slot leans it — THE FIRST LIVE GEAR SLOT. A lean on
# your height's stick, not an absolute pick, so max-height + LONG can't stack
# reach beyond the tuned corner. Symmetric ±4% to start (whether LONG should
# lean more conservatively than SHORT is an open tuning call — reach is the
# closest thing the game has to raw power, but the lever-derived inertia and
# tip-speed tradeoffs are what price it honestly). Everything downstream of
# stick_len_mult follows automatically: stick/blade mesh, poke + claim reach,
# blade-cap lever derivation, wrister full-stroke rescale.
const _LENGTH_LEAN: Array[float] = [0.960, 1.000, 1.040]  # SHORT / STANDARD / LONG

# ── Gear-lean tables — 3-vec, indexed by the slot option (0/1/2) ─────────────
# STICK FLEX — power ↔ release, a true seesaw: stiff loads a bigger shot but
# pays a slower load (longer slapper wind-up AND longer wrister runway);
# whippy is the snap release at a softer ceiling. NOTE the charge lean goes
# WITH the power lean, deliberately breaking from the height coupling
# (2 − power, where a harder shooter also threatens sooner — a double
# benefit the v3 tier price policed): a lateral slot must trade, never
# stack. Real-hockey sign convention: high flex number = stiffer.
const _FLEX_SHOT_LEAN: Array[float] = [0.94, 1.00, 1.06]    # whippy / medium / stiff
const _FLEX_CHARGE_LEAN: Array[float] = [0.92, 1.00, 1.10]  # wind-up time, with power
const _FLEX_RUNWAY_LEAN: Array[float] = [0.90, 1.00, 1.12]  # wrister full-stroke travel

# BLADE CURVE — elevation & release ↔ backhand. OPEN steepens the LOW loft
# (the saucer / mid-net money tip) and shortens the wrister runway (quick
# release) but deepens the backhand penalty; CLOSED is the honest-both-ways
# blade — best backhand, hardest to elevate. THE CROSSBAR CONSTRAINT: the
# HIGH loft's apex ceiling (puck top ~5 cm under the bar) is pinned for
# every curve — open never touches loft_vertical_speed_high; it reaches the
# same ceiling on a steeper LOW arc instead. Backhand relief approaches but
# never reaches forehand parity (0.75 base × 1.08 = 0.81).
const _CURVE_LOFT_LOW_LEAN: Array[float] = [0.90, 1.00, 1.12]  # closed / balanced / open
const _CURVE_RUNWAY_LEAN: Array[float] = [1.00, 1.00, 0.90]
const _CURVE_BACKHAND_LEAN: Array[float] = [1.08, 1.00, 0.92]

# ── Gameplay tables — frame-indexed (5 rows lean→heavy at the BMI anchors) ────

# Acceleration (thrust / forward burst). Lean = first-step quickness; heavy
# trades the first step for mass-emergent momentum (no separate table — the
# collision/inertia math already carries it).
const _ACCEL_F: Array[float] = [1.080, 1.040, 1.000, 0.980, 0.970]

# Agility (turn / brake / facing) frame term — multiplies the height baseline.
# Grounded in F = mv²/r: at fixed leg strength more mass means a wider arc and
# a longer stop. This is the counterweight that makes the weight dial a real
# seesaw (mass 1.28 is a big buy; without this its only tax was mild accel).
# CORNER BUDGET (body-only): best 5'8"-lean 1.05·1.03 ≈ 1.08, worst 6'7"-heavy
# 0.93·0.96 ≈ 0.89 — pinned just under the v3 "feels bad but playable" floor;
# the skate-profile gear lean stacks on top later, so re-check the stacked
# corners when that slot lands. Deliberately NOT applied to edge glide — see
# agility_glide_mult.
const _AGILITY_F: Array[float] = [1.030, 1.015, 1.000, 0.980, 0.960]

# Stamina drain scale (sprint DURATION / pool depth). Lean = fast metabolism =
# higher drain; heavy = deep pool = drains slower.
const _STAMINA_DRAIN_F: Array[float] = [1.15, 1.07, 1.00, 0.92, 0.85]

# Stamina regen scale (RECOVERY). Lean tops up fast; heavy recovers slowly.
# The pair: lean = short repeatable bursts, heavy = one long drive, slow refill.
const _STAMINA_REGEN_F: Array[float] = [1.25, 1.12, 1.00, 0.90, 0.82]

# ── Visual-only tables ────────────────────────────────────────────────────────
# Silhouette = body (v4): height drives overall scale + torso/head; frame
# drives uniform limb/shoulder bulk (replacing the v3 per-tier limb tells).
# Gear reads from the rendered equipment itself, not the body.
const _TORSO_BULK: Array[float] = [0.90, 0.96, 1.00, 1.07, 1.14]  # height
const _HEAD_BULK: Array[float] = [0.95, 0.98, 1.00, 1.03, 1.06]   # height
const _FRAME_BULK: Array[float] = [0.90, 0.95, 1.00, 1.07, 1.14]  # frame lean→heavy

# ── Sprint / carry constants ──────────────────────────────────────────────────
# The normalization span is the FULL v3 speed-lever span (weak-small .. strong-
# medium), retained so v4 body-only builds land on the same sprint ceilings
# their v3 all-average counterparts had (neutral identity at every height).
# Body-only speed occupies the middle of the span; the skate-profile gear slot
# re-widens it laterally in a later stage.
const _SPEED_MULT_MIN: float = 0.955
const _SPEED_MULT_MAX: float = 1.060
# Sprint top-speed multiplier, interpolated across the speed span — grounded
# to the NHL EDGE 20–25 mph burst band.
const SPRINT_CEIL_MIN: float = 1.07
const SPRINT_CEIL_MAX: float = 1.164
# Carry speed = how much of your speed survives carrying (higher = less
# penalty). v3 eased this by Hands (primary) + Speed; v4 has no hands lever
# (constitution), so the v3 neutral hands contribution is folded into the
# base — CARRY_BASE = 0.92 + 0.07·(0.15/0.39), exactly the v3 H3-average
# value — leaving Speed as the only easing term.
const CARRY_BASE: float = 0.92 + 0.07 * (0.15 / 0.39)
const CARRY_SPEED_GAIN: float = 0.025
const CARRY_FLOOR: float = 0.85
const CARRY_CEIL: float = 0.99

# ── State ─────────────────────────────────────────────────────────────────────
var height: int = HEIGHT_MEDIUM
var weight: int = int(NEUTRAL_WEIGHT_LBS)
var profile: int = GEAR_BALANCED
var curve: int = GEAR_BALANCED
var flex: int = GEAR_BALANCED
var length: int = GEAR_BALANCED


func _init(p_height: int = HEIGHT_MEDIUM, p_weight: int = 0,
		p_profile: int = GEAR_BALANCED, p_curve: int = GEAR_BALANCED,
		p_flex: int = GEAR_BALANCED, p_length: int = GEAR_BALANCED) -> void:
	height = coerce_height(p_height)
	weight = coerce_weight(height, p_weight)
	profile = _clamp_gear(p_profile)
	curve = _clamp_gear(p_curve)
	flex = _clamp_gear(p_flex)
	length = _clamp_gear(p_length)


# The neutral build (6'1"/201, all-balanced). Name kept from the tier era —
# every "give me a default build" call site reads it.
static func all_average() -> PlayerAttributes:
	return PlayerAttributes.new()


# Direct construction from raw levels in canonical wire order:
# [height_in, weight_lbs, profile, curve, flex, length].
static func from_levels(p_height: int, p_weight: int,
		p_profile: int = GEAR_BALANCED, p_curve: int = GEAR_BALANCED,
		p_flex: int = GEAR_BALANCED, p_length: int = GEAR_BALANCED) -> PlayerAttributes:
	return PlayerAttributes.new(p_height, p_weight, p_profile, p_curve, p_flex, p_length)


# ── Weight band helpers ───────────────────────────────────────────────────────
# Displayed pounds for a BMI at a height: lbs = BMI·in²/703 (the BMI formula
# inverted). All band math routes through here so the interval stays single-
# sourced.
static func weight_for_bmi(inches: int, bmi: float) -> int:
	var h: int = clampi(inches, HEIGHT_MIN, HEIGHT_MAX)
	return int(roundf(bmi * float(h * h) / 703.0))


static func weight_min(inches: int) -> int:
	return weight_for_bmi(inches, BMI_LEAN)


static func weight_max(inches: int) -> int:
	return weight_for_bmi(inches, BMI_HEAVY)


static func weight_neutral(inches: int) -> int:
	return weight_for_bmi(inches, BMI_MEDIUM)


# Clamp a pounds value into the height's band. Zero/negative means "no stored
# weight" (a pre-v5 save or a defaulted wire arg) and coerces to the height's
# neutral frame, so legacy identities keep their silhouette.
static func coerce_weight(inches: int, lbs: int) -> int:
	if lbs <= 0:
		return weight_neutral(inches)
	return clampi(lbs, weight_min(inches), weight_max(inches))


# Frame position 0..1 across the band (0 = LEAN, 0.5 = MEDIUM, 1 = HEAVY) —
# the height-independent "how heavy for my frame" quantity the frame tables
# index by, and what the picker preserves when the height slider moves.
# Measured in the INTEGER pounds band the player actually sees (not raw BMI):
# the band edges land exactly on 0/1 and the neutral 73"/201 lands exactly on
# 0.5, so the rounded display weight can't nudge a neutral build off the 1.0
# multipliers (raw BMI of 201 lbs is 26.515, a ~0.3% lerp leak).
func frame_t() -> float:
	var lo: float = float(weight_min(height))
	var hi: float = float(weight_max(height))
	return clampf((float(weight) - lo) / maxf(hi - lo, 1.0), 0.0, 1.0)


func height_inches() -> int:
	return height


func height_label() -> String:
	return inches_label(height)


func weight_label() -> String:
	return "%d lbs" % weight


# Format an inches value as feet'inches" (e.g. 73 → 6'1").
static func inches_label(inches: int) -> String:
	return "%d'%d\"" % [inches / 12, inches % 12]


# ── Named multiplier accessors ────────────────────────────────────────────────
# Body — height
func speed_mult() -> float:   return _h(_SPEED_H, height)
# Agility = height baseline × frame term (F = mv²/r — mass widens the arc and
# lengthens the stop). Feeds turn / brake / facing / lateral quickness.
func agility_mult() -> float: return _h(_AGILITY_H, height) * _f(_AGILITY_F)
# Edge glide is the inverse of the HEIGHT-ONLY agility component — deliberately
# NOT the full agility_mult: routing the frame term in would make a heavy build
# bleed speed while coasting, the opposite of the momentum identity the
# accel↔momentum fork promises (the tank turns wide but coasts like his mass
# says he should). Derived so it can't drift from the height number it mirrors.
func agility_glide_mult() -> float: return 2.0 - _h(_AGILITY_H, height)
# Shot ceiling = height baseline × flex lean (stiff loads more).
func shot_power_mult() -> float:    return _h(_SHOT_H, height) * _FLEX_SHOT_LEAN[flex]
# Slapper wind-up: the HEIGHT part keeps the inherited inverse coupling
# (2 − power — a big frame's harder shot also threatens sooner); the FLEX
# part goes WITH the power lean (stiff = slower load) so the gear slot is a
# lateral trade, not a stacked buff. See the _FLEX_CHARGE_LEAN doc.
func shot_charge_mult() -> float:
	return (2.0 - _h(_SHOT_H, height)) * _FLEX_CHARGE_LEAN[flex]

# Body — frame
func accel_mult() -> float:         return _f(_ACCEL_F)
func stamina_drain_mult() -> float: return _f(_STAMINA_DRAIN_F)
func stamina_regen_mult() -> float: return _f(_STAMINA_REGEN_F)
# Mass is linear in displayed weight — see NEUTRAL_WEIGHT_LBS.
func mass_mult() -> float:          return float(weight) / NEUTRAL_WEIGHT_LBS

# Hands — CONSTITUTION: no fidelity scaling, ever. The blade tracks every
# player's cursor identically; hands differentiation arrives as lever geometry
# (stick length → tip speed vs inertia) in a later stage. Accessors kept so
# apply_attributes stays table-agnostic.
func hands_blade_mult() -> float:    return 1.0
func hands_backhand_mult() -> float: return 1.0

# Checking — body-emergent: mass (above) feeds delivery and brace through the
# collision resolver's reduced-mass math; there is no attribute term. Accessors
# kept at neutral so apply_attributes stays table-agnostic.
func check_delivery_mult() -> float: return 1.0
func brace_mult() -> float:          return 1.0

# Geometry
# Hitbox radius = skeleton breadth (height) × frame width (weight) — tracks
# the visual silhouette.
func radius_mult() -> float:    return _h(_RADIUS, height) * _f(_RADIUS_F)
func height_mult() -> float:    return _h(_HEIGHT, height)
# Height band center × the length gear lean (see _LENGTH_LEAN; `length` is
# constructor-clamped to 0..2, so the direct index is safe).
func stick_len_mult() -> float: return _h(_STICK_LEN, height) * _LENGTH_LEAN[length]

# ── Gear-lean accessors (flex + curve) ───────────────────────────────────────
# Wrister runway: fraction of the full-stroke travel this loadout needs for a
# max-power release ("max power with less real estate consumed"). Flex and
# curve stack; the floor across the stacked extremes (0.90 × 0.90 = 0.81) is
# the runway-floor constraint — a max-power release must still emit a
# readable wind-up tell (pinned by the calibration test).
func wrister_runway_mult() -> float:
	return _FLEX_RUNWAY_LEAN[flex] * _CURVE_RUNWAY_LEAN[curve]

# Backhand coefficient lean — the one place backhand varies (technique is the
# human; hands_backhand_mult stays 1.0 by constitution — this is the BLADE's
# shape, not the player's skill).
func curve_backhand_mult() -> float: return _CURVE_BACKHAND_LEAN[curve]

# LOW-loft vertical launch lean (the saucer / money-tip elevation). HIGH is
# deliberately not an accessor — the crossbar ceiling is pinned for every
# curve by construction.
func curve_loft_low_mult() -> float: return _CURVE_LOFT_LOW_LEAN[curve]


# Sprint ceiling — speed-normalized, grounded to the 20–25 mph burst band.
func sprint_ceiling_mult() -> float:
	var n: float = clampf((speed_mult() - _SPEED_MULT_MIN)
			/ (_SPEED_MULT_MAX - _SPEED_MULT_MIN), 0.0, 1.0)
	return lerpf(SPRINT_CEIL_MIN, SPRINT_CEIL_MAX, n)


# Carry speed retention — speed-eased (see CARRY_BASE for where the v3 hands
# term went). Higher = less penalty.
func carry_speed_mult() -> float:
	var sn: float = clampf((speed_mult() - _SPEED_MULT_MIN)
			/ (_SPEED_MULT_MAX - _SPEED_MULT_MIN), 0.0, 1.0)
	return clampf(CARRY_BASE + sn * CARRY_SPEED_GAIN, CARRY_FLOOR, CARRY_CEIL)


# Visual
func torso_bulk_mult() -> float: return _h(_TORSO_BULK, height) * _f(_FRAME_BULK)
func head_bulk_mult() -> float:  return _h(_HEAD_BULK, height)
func shoulder_bulk_mult() -> float:  return _f(_FRAME_BULK)
func thigh_mult() -> float:          return _f(_FRAME_BULK)
func calf_mult() -> float:           return _f(_FRAME_BULK)
func forearm_bulk_mult() -> float:   return _f(_FRAME_BULK)
func upper_arm_bulk_mult() -> float: return _f(_FRAME_BULK)


# ── Serialization ─────────────────────────────────────────────────────────────
func to_dict() -> Dictionary:
	return {
		"height": height, "weight": weight,
		"profile": profile, "curve": curve, "flex": flex, "length": length,
	}


# Rebuilds from a dict. Native v5 keys win; a v4 three-tier dict
# (height/skating/skill/checking) migrates via migrate_tiers; the oldest
# six-attribute dicts (speed/agility/hands/size/physical/shot, or the earlier
# skill/strength variants) migrate via migrate_legacy. Missing native keys
# default to neutral.
static func from_dict(d: Dictionary) -> PlayerAttributes:
	if d.has("weight") or d.has("profile"):
		return PlayerAttributes.new(
				int(d.get("height", HEIGHT_MEDIUM)),
				int(d.get("weight", 0)),
				int(d.get("profile", GEAR_BALANCED)),
				int(d.get("curve", GEAR_BALANCED)),
				int(d.get("flex", GEAR_BALANCED)),
				int(d.get("length", GEAR_BALANCED)))
	if d.has("skating") or d.has("checking"):
		return migrate_tiers(
				int(d.get("height", HEIGHT_MEDIUM)),
				int(d.get("skating", 2)), int(d.get("skill", 2)),
				int(d.get("checking", 2)))
	if d.has("speed") or d.has("agility") or d.has("size") or d.has("physical") \
			or d.has("shot") or d.has("strength"):
		# Legacy six-attribute (or four-attribute) dict.
		var legacy_skill: int = int(d.get("skill", d.get("strength", 3)))
		return migrate_legacy(
				int(d.get("speed", 3)), int(d.get("agility", 3)),
				int(d.get("hands", legacy_skill)), int(d.get("size", 3)),
				int(d.get("physical", 3)), int(d.get("shot", legacy_skill)))
	# No attribute keys at all (a name-only or height-only entry): neutral
	# frame at the given height — never the legacy migration's default shape.
	return PlayerAttributes.new(int(d.get("height", HEIGHT_MEDIUM)))


# Maps a v4 height + three-tier build (tiers 1=weak/2=average/3=strong) onto
# the body+gear model. Deterministic and documented (plan doc §9):
#   height   — carries over (coerce_height accepts 1..5 steps or inches).
#   weight   — frame anchor by the Checking tier: weak→LIGHT, avg→MEDIUM,
#              strong→SOLID (the physical identity lives in mass now).
#   profile  — strong Skating leans the skate profile the way height leaned
#              the tier: POWER at/above 6'1", AGILITY below.
#   curve    — strong Skill on a big frame was the bomber → OPEN.
#   length   — strong Checking ran the defenseman's stick → LONG; strong
#              Skill on a small frame was the dangler → SHORT.
#   flex     — always MEDIUM (no tier expressed release speed).
# Gear has no gameplay effect in step 1, so this mapping only shapes what the
# picker shows a migrated player — they lose nothing by re-picking.
static func migrate_tiers(p_height: int, skating: int, skill: int,
		checking: int) -> PlayerAttributes:
	var h: int = coerce_height(p_height)
	var frame_bmi: float = BMI_MEDIUM
	if checking >= 3:
		frame_bmi = BMI_MEDIUM + BMI_ANCHOR_STEP
	elif checking <= 1:
		frame_bmi = BMI_MEDIUM - BMI_ANCHOR_STEP
	var p_profile: int = GEAR_BALANCED
	if skating >= 3:
		p_profile = PROFILE_POWER if h >= HEIGHT_MEDIUM else PROFILE_AGILITY
	var p_curve: int = CURVE_OPEN if skill >= 3 and h >= HEIGHT_MEDIUM else GEAR_BALANCED
	var p_length: int = GEAR_BALANCED
	if checking >= 3:
		p_length = LENGTH_LONG
	elif skill >= 3 and h < HEIGHT_MEDIUM:
		p_length = LENGTH_SHORT
	return PlayerAttributes.new(h, weight_for_bmi(h, frame_bmi),
			p_profile, p_curve, GEAR_BALANCED, p_length)


# Maps a legacy 1..5 six-attribute build to the body+gear model, through the
# same tier composite the v3→v4 migration used (Skating←speed+agility,
# Skill←hands+shot, Checking←physical; highest→strong, lowest→weak, stable
# ties by that order), then migrate_tiers. Height comes from the old Size axis.
static func migrate_legacy(speed: int, agility: int, hands: int, size: int,
		physical: int, shot: int) -> PlayerAttributes:
	var scores: Array = [
		{"idx": 0, "score": speed + agility},   # Skating
		{"idx": 1, "score": hands + shot},      # Skill
		{"idx": 2, "score": physical * 2},      # Checking
	]
	scores.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["score"] != b["score"]:
			return a["score"] > b["score"]
		return a["idx"] < b["idx"])
	var tiers: Array[int] = [2, 2, 2]
	tiers[scores[0]["idx"]] = 3
	tiers[scores[2]["idx"]] = 1
	return migrate_tiers(coerce_height(size), tiers[0], tiers[1], tiers[2])


func equals(other: PlayerAttributes) -> bool:
	if other == null:
		return false
	return height == other.height and weight == other.weight \
			and profile == other.profile and curve == other.curve \
			and flex == other.flex and length == other.length


# ── Internal ──────────────────────────────────────────────────────────────────
# Bracketing anchor rows for a height in inches: [lo_row, hi_row, t] where the
# interpolated value is lerp(row[lo], row[hi], t).
static func _anchor(inches: int) -> Array:
	var h: int = clampi(inches, HEIGHT_MIN, HEIGHT_MAX)
	for i: int in range(ANCHOR_INCHES.size() - 1):
		if h <= ANCHOR_INCHES[i + 1]:
			var span: float = float(ANCHOR_INCHES[i + 1] - ANCHOR_INCHES[i])
			var t: float = 0.0 if span <= 0.0 else float(h - ANCHOR_INCHES[i]) / span
			return [i, i + 1, t]
	var last: int = ANCHOR_INCHES.size() - 1
	return [last, last, 0.0]


# 5-vec lookup interpolated by height.
static func _h(table: Array[float], inches: int) -> float:
	var a: Array = _anchor(inches)
	return lerpf(table[a[0]], table[a[1]], a[2])


# 5-vec lookup interpolated by frame position (BMI anchors are equally spaced,
# so frame_t maps linearly onto the row axis).
func _f(table: Array[float]) -> float:
	var pos: float = frame_t() * float(table.size() - 1)
	var lo: int = clampi(int(floorf(pos)), 0, table.size() - 2)
	return lerpf(table[lo], table[lo + 1], pos - float(lo))


# Accept a legacy 1..5 step (maps onto the anchor heights) OR a raw inches
# value. No real hockey height falls in 6..67, so the split is unambiguous.
static func coerce_height(v: int) -> int:
	if v <= ANCHOR_INCHES.size():
		return ANCHOR_INCHES[clampi(v, 1, ANCHOR_INCHES.size()) - 1]
	return clampi(v, HEIGHT_MIN, HEIGHT_MAX)


static func _clamp_gear(v: int) -> int:
	return clampi(v, 0, 2)
