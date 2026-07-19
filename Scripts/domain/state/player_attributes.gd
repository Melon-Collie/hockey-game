class_name PlayerAttributes
extends RefCounted

# PlayerAttributes
# ----------------
# Per-skater tuning built on a HEIGHT-ROUTED model. A build is:
#
#   • HEIGHT — a free CONTINUOUS archetype dial in inches (every inch 5'8"..6'7"),
#     NOT point-buy. The gameplay tables are authored at 5 anchor heights and any
#     height in between interpolates. Height decides reach, the speed/agility/shot/
#     hands BASELINES, and how much an attribute investment pays off on each lever.
#     It is the axis that makes the same "strong Skating" mean elite agility on a
#     small frame and top speed on a big one.
#   • THREE ATTRIBUTES — Skating, Skill, Checking — each a TIER (weak / average /
#     strong). A legal build spends exactly one STRONG and one WEAK with the third
#     AVERAGE (all-average is legal but flavorless). No point budget — the strong
#     ⇄ weak swap IS the budget, so the shape is self-balancing.
#
# Neutral reference is H3 (6'1") + all-average: every gameplay multiplier is 1.0
# there, so an all-average 6'1" build plays and looks identical to the shipped
# @export defaults (base max_speed 9.0 m/s, wrister 33 / slapper 40 m/s, etc.).
#
# WHAT EACH ATTRIBUTE ROUTES TO (height decides the base + how the tier scales it):
#   Skating → Speed (max_speed, hump peaks at medium height)
#           + Acceleration (thrust/forward burst, small-favored, floored ABOVE
#             agility so a big weak-skater can still push north-south)
#           + Agility (turn / brake / edge glide / lateral, small-favored, floors
#             at ~old-L1 for a big weak-skater — the one lever his weakness bites).
#   Skill   → Hands (blade speed, carry, backhand — small-favored)
#           + Shot (charged power ceiling + slapper wind-up — big-favored; the
#             shot spread is the wider one, anchored to real NHL speeds).
#   Checking→ Delivery (body_check_transfer/strip — big-favored) + Brace/resist
#             (tier-DOMINANT with only a mild height tilt — a big frame is a
#             head start, not a substitute; a big weak-Checking build is genuinely
#             hittable, an elusive small strong-Checking build is untouchable).
#
# HEIGHT-ONLY levers (no attribute routing):
#   • reach / mesh scale / stick length — length is length.
#   • mass — a MINOR height edge (~1.16x heaviest-to-lightest). Deliberately
#     small: physical battles are decided by Checking, not by standing tall.
#     [PLACEHOLDER SEAM] mass is a height-only lever today; when Checking is
#     reworked, giving mass a Checking gain is purely additive — see mass_mult().
#   • stamina — small = fast metabolism (shallower pool, quick recovery), big =
#     slow metabolism (deep pool, slow recovery). Modeled as drain + regen scales.
#
# SPRINT & CARRY (grounded in NHL EDGE tracking: top bursts live in a tight
# 20–25 mph / 9.0–11.1 m/s band; the record is ~24.8 mph):
#   • The sprint CEILING is Speed-attributed (sprint_ceiling_mult), NOT the flat
#     multiplier it used to be. Cruise stays uniform; separation lives in the
#     sprint gear a real burner has and a plodder doesn't. A fast build tops ~25
#     mph, a poor skater ~20 — no more free gear for slow skaters.
#   • The carry speed penalty is small and Hands+Speed-eased (carry_speed_mult):
#     an elite dangler OR an elite skater carries at ~98% ("effortless"). The real
#     cost of carrying-at-speed is the 1.6x sprint stamina drain (StaminaRules),
#     not an intrinsic slowdown — so a fast carrier CAN separate, but only in a
#     time-limited burst.
#
# All tuning tables live in this file as private consts, consumed via the named
# accessors below — never index a `_*` table directly outside this file.
#
# Grounded-model note: the 5×3 gameplay tables ARE the resolved base×gain values
# (authored directly so they read as physical quantities — an agility multiplier
# a small player really has, an NHL shot speed). Levers with a natural coupling
# (edge glide vs agility, wind-up vs shot power) are DERIVED from their partner
# rather than tabled separately (see the inverted accessors) so they can't drift.
#
# To add a new "height/attribute X scales Y" rule:
#   1. Add a table: `_FOO: Array` — a 5×3 grid ([height][tier]) if an attribute
#      drives it, a 5-vec if height-only, or a 3-vec if tier-only (visual tells).
#   2. Add an accessor `func foo_mult() -> float` returning `_ht/_h/_t(_FOO, ...)`.
#   3. Multiply a captured base in SkaterController.apply_attributes /
#      SkaterAppearanceCoordinator.apply.
#
# Persistence: PlayerPrefs (local pick, migrated from the legacy 6-attr scale),
# BotIdentityRegistry (bot picks), NetworkManager peer table (replicated at join).

enum Attribute { SKATING, SKILL, CHECKING }

# Height is stored in INCHES and is a free CONTINUOUS dial: every inch from 5'8"
# (68) to 6'7" (79) is playable. The gameplay tables are authored at 5 anchor
# heights (ANCHOR_INCHES); any height in between linearly interpolates the two
# adjacent rows (see _anchor / _h / _ht). Neutral (all-multipliers-1.0) is 6'1".
const HEIGHT_MIN: int = 68     # 5'8"
const HEIGHT_MEDIUM: int = 73  # 6'1"  (neutral)
const HEIGHT_MAX: int = 79     # 6'7"

# The 5 table rows sit at these heights (inches). 5'10" (row 1) is the mesh-native
# anchor where the reach/height multiplier is exactly 1.0. A build's height may
# land anywhere in [68, 79]; the lookups interpolate between the bracketing rows.
const ANCHOR_INCHES: Array[int] = [68, 70, 73, 76, 79]  # 5'8", 5'10", 6'1", 6'4", 6'7"

# Attribute tiers. tier_delta = tier - TIER_AVERAGE → {-1, 0, +1}.
const TIER_WEAK: int = 1
const TIER_AVERAGE: int = 2
const TIER_STRONG: int = 3

# ── Gameplay tables — 5 rows (H1..H5) × 3 cols (WEAK, AVERAGE, STRONG) ─────────
# Each cell is the resolved multiplier on the shipped @export baseline. H3/AVERAGE
# is 1.0 for every canonical lever. See the header for the design behind each tilt.

# SKATING → Speed (max_speed). Hump: top speed peaks at medium height, small=big
# at baseline. Fastest build in the game is H3 strong (1.06 → ~25 mph sprinting).
const _SPEED: Array = [
	[0.955, 0.990, 1.020],  # H1 5'8"
	[0.960, 0.995, 1.040],  # H2 5'10"
	[0.965, 1.000, 1.060],  # H3 6'1"  (neutral + peak)
	[0.960, 0.995, 1.050],  # H4 6'4"
	[0.955, 0.990, 1.030],  # H5 6'7"
]

# SKATING → Acceleration (thrust / forward burst). Small-favored (quick first
# steps), floored ABOVE agility: a big weak-skater sits ~old-L2 here, so he can
# still drive north-south — his weakness bites in the turn, not the burst.
const _ACCEL: Array = [
	[1.020, 1.080, 1.120],  # H1
	[0.990, 1.040, 1.080],  # H2
	[0.960, 1.000, 1.040],  # H3
	[0.950, 0.980, 1.020],  # H4
	[0.945, 0.970, 1.000],  # H5
]

# SKATING → Agility (turn rate / brake / facing / lateral quickness). Small-favored,
# the widest small edge. Floors at ~old-L1 (0.90) for a big weak-skater ("feels
# bad but playable"), ceilings at ~old-L5 (1.11) for a small strong-skater (the
# old superpower is now the ceiling, not lapped).
const _AGILITY: Array = [
	[1.000, 1.050, 1.110],  # H1
	[0.970, 1.020, 1.070],  # H2
	[0.950, 1.000, 1.040],  # H3
	[0.920, 0.960, 1.000],  # H4
	[0.900, 0.930, 0.970],  # H5
]

# SKILL → Hands (blade speed; carry & backhand track this). Small-favored. Drives
# the dangle/pass-absorb lever. H5 weak floored at 0.85 (= old-L1, still playable).
const _HANDS: Array = [
	[1.020, 1.120, 1.240],  # H1
	[0.980, 1.060, 1.160],  # H2
	[0.920, 1.000, 1.090],  # H3
	[0.870, 0.940, 1.020],  # H4
	[0.850, 0.880, 0.950],  # H5
]

# SKILL → Shot power (charged wrister/slapper ceiling; wind-up tracks inversely).
# Big-favored, the WIDER Skill spread. Anchored to NHL: H5 strong 1.20 → 48 m/s
# slapper ≈ 107 mph (Chara/Weber); H3 avg 1.00 → league; H1 weak 0.85 → 76 mph.
const _SHOT: Array = [
	[0.850, 0.900, 0.980],  # H1
	[0.870, 0.940, 1.030],  # H2
	[0.900, 1.000, 1.110],  # H3
	[0.930, 1.050, 1.160],  # H4
	[0.950, 1.090, 1.200],  # H5
]

# CHECKING → Delivery (body_check_transfer, and the puck-strip impulse derived
# from it). Height baseline compressed; the tall-favored payoff lives in the
# tier gain, so a big body that neglects Checking hits ~below-average and must
# invest to become the freight train. Compounds with the (minor) mass edge.
const _DELIVERY: Array = [
	[0.820, 0.900, 1.000],  # H1
	[0.850, 0.950, 1.070],  # H2
	[0.880, 1.000, 1.160],  # H3
	[0.910, 1.060, 1.260],  # H4
	[0.940, 1.100, 1.360],  # H5
]

# CHECKING → Brace / resist (how hard to knock off the puck; LOWER = better).
# Tier-DOMINANT (weak→strong is the big mover), mild height tilt (small braces a
# touch better at equal tier — elusiveness vs the big man's anchoring). A big
# weak-Checking build (1.14) is very hittable; a small strong one (0.76) is
# untouchable. This is the axis flagged for the upcoming Checking rework.
const _BRACE: Array = [
	[1.060, 0.900, 0.760],  # H1
	[1.080, 0.940, 0.800],  # H2
	[1.100, 1.000, 0.860],  # H3
	[1.120, 1.040, 0.900],  # H4
	[1.140, 1.080, 0.940],  # H5
]

# ── Height-only tables — 5 values (H1..H5) ────────────────────────────────────

# Mass (minor — ~1.16x heaviest-to-lightest). Physical battles are Checking-decided;
# height is a small head start, not a wall. [PLACEHOLDER — see header/mass_mult.]
const _MASS: Array[float] = [0.94, 0.97, 1.00, 1.05, 1.09]

# Hitbox cylinder radius — frame width, modest with height.
const _RADIUS: Array[float] = [0.95, 0.975, 1.00, 1.05, 1.10]

# Body height (mesh Y-scale, arm/ROM length, hand heights). Mesh-native 5'10" is
# H2, so the 1.0 identity sits at H2 (NOT the H3 gameplay neutral). Values are the
# real height / 1.78 m: 5'8" .971, 5'10" 1.000, 6'1" 1.043, 6'4" 1.086, 6'7" 1.129.
const _HEIGHT: Array[float] = [0.971, 1.000, 1.043, 1.086, 1.129]

# Stick length — equipment, not anatomy, so ~0.65x the height deviation from the
# mesh-native H2. A small player keeps a near-full-size stick. Shares H2-identity.
const _STICK_LEN: Array[float] = [0.981, 1.000, 1.028, 1.056, 1.084]

# Stamina drain scale (sprint DURATION / pool depth). Small = fast metabolism =
# higher drain (shallower effective pool); big = deep pool = drains slower.
const _STAMINA_DRAIN: Array[float] = [1.15, 1.07, 1.00, 0.92, 0.85]

# Stamina regen scale (RECOVERY). Small tops up fast; big recovers slowly. The
# pair: small = short but repeatable bursts, big = one long drive then a slow refill.
const _STAMINA_REGEN: Array[float] = [1.25, 1.12, 1.00, 0.90, 0.82]

# ── Visual-only tables ────────────────────────────────────────────────────────
# Silhouette tells so builds read on the third-person camera. With four axes the
# tells map: HEIGHT → overall scale + torso/head bulk; SKATING → legs (thigh/calf);
# SKILL → arms (forearm/upper-arm); CHECKING → shoulders/yoke. Torso/head are
# height-indexed (5); the tier tells are tier-indexed (3: WEAK, AVERAGE, STRONG).
const _TORSO_BULK: Array[float]     = [0.90, 0.96, 1.00, 1.07, 1.14]  # height
const _HEAD_BULK: Array[float]      = [0.95, 0.98, 1.00, 1.03, 1.06]  # height
const _SHOULDER_BULK: Array[float]  = [0.88, 1.00, 1.18]              # Checking tier
const _THIGH: Array[float]          = [0.86, 1.00, 1.16]              # Skating tier
const _CALF: Array[float]           = [0.86, 1.00, 1.16]              # Skating tier
const _FOREARM_BULK: Array[float]   = [0.84, 1.00, 1.22]              # Skill tier
const _UPPER_ARM_BULK: Array[float] = [0.84, 1.00, 1.22]             # Skill tier

# ── Sprint / carry constants (grounded model) ─────────────────────────────────
# Speed-sub-lever span, used to normalize sprint ceiling + carry ease. min = the
# slowest cell in _SPEED, max = the fastest.
const _SPEED_MULT_MIN: float = 0.955
const _SPEED_MULT_MAX: float = 1.060
# Hands-sub-lever span (for carry ease). min = _HANDS floor, max = _HANDS ceiling.
const _HANDS_MULT_MIN: float = 0.850
const _HANDS_MULT_MAX: float = 1.240
# Sprint top-speed multiplier, interpolated across the Speed span. Anchored so the
# fastest build sprints to ~25 mph (11.1 m/s) and the slowest to ~20 mph (9.0 m/s)
# off the 9.0 m/s base — replaces the old flat 1.18 that handed everyone a gear.
const SPRINT_CEIL_MIN: float = 1.07
const SPRINT_CEIL_MAX: float = 1.164
# Carry speed = how much of your speed survives carrying (higher = less penalty).
# Base ~8% penalty, eased by Hands (primary) + Speed (secondary) toward ~1%.
const CARRY_BASE: float = 0.92
const CARRY_HANDS_GAIN: float = 0.07
const CARRY_SPEED_GAIN: float = 0.025
const CARRY_FLOOR: float = 0.85
const CARRY_CEIL: float = 0.99

# ── State ─────────────────────────────────────────────────────────────────────
var height: int = HEIGHT_MEDIUM
var skating: int = TIER_AVERAGE
var skill: int = TIER_AVERAGE
var checking: int = TIER_AVERAGE


func _init(p_height: int = HEIGHT_MEDIUM, p_skating: int = TIER_AVERAGE,
		p_skill: int = TIER_AVERAGE, p_checking: int = TIER_AVERAGE) -> void:
	height = coerce_height(p_height)
	skating = _clamp_tier(p_skating)
	skill = _clamp_tier(p_skill)
	checking = _clamp_tier(p_checking)


static func all_average() -> PlayerAttributes:
	return PlayerAttributes.new()


# Direct construction from raw levels (picker hands these in: height 1..5, tiers 1..3).
static func from_levels(p_height: int, p_skating: int, p_skill: int,
		p_checking: int) -> PlayerAttributes:
	return PlayerAttributes.new(p_height, p_skating, p_skill, p_checking)


# ── Validation ────────────────────────────────────────────────────────────────
# A legal build: height in [1,5], every tier in [1,3], and the shape spends no
# more strengths than weaknesses (strong_count <= weak_count). That admits the
# canonical one-strong-one-weak, all-average, and self-nerfs — and rejects the
# only thing that grants unearned power (a strength with no matching weakness,
# e.g. one strong + two average). The host validates joiners with this; the
# picker UI enforces the exact one-up-one-down shape.
static func is_legal_build(_p_height: int, p_skating: int, p_skill: int,
		p_checking: int) -> bool:
	# Height is a free lateral dial that always coerces into range
	# (coerce_height), so it's never a rejection axis — only the tier SHAPE is
	# validated: every tier in [1,3] and no more strengths than weaknesses.
	for t: int in [p_skating, p_skill, p_checking]:
		if t < TIER_WEAK or t > TIER_STRONG:
			return false
	var strong: int = 0
	var weak: int = 0
	for t: int in [p_skating, p_skill, p_checking]:
		if t == TIER_STRONG:
			strong += 1
		elif t == TIER_WEAK:
			weak += 1
	return strong <= weak


# Whether THIS instance is a legal build.
func is_legal() -> bool:
	return is_legal_build(height, skating, skill, checking)


func tier_for(attr: int) -> int:
	match attr:
		Attribute.SKATING:  return skating
		Attribute.SKILL:    return skill
		Attribute.CHECKING: return checking
	return TIER_AVERAGE


func height_inches() -> int:
	return height


func height_label() -> String:
	return inches_label(height)


# Format an inches value as feet'inches" (e.g. 73 → 6'1").
static func inches_label(inches: int) -> String:
	return "%d'%d\"" % [inches / 12, inches % 12]


# ── Named multiplier accessors ────────────────────────────────────────────────
# Skating
func speed_mult() -> float:        return _ht(_SPEED, height, skating)
func accel_mult() -> float:        return _ht(_ACCEL, height, skating)
func agility_mult() -> float:      return _ht(_AGILITY, height, skating)
# Edge glide is the inverse of agility (lower drag = better edges) — derived so it
# can't drift from the agility number it mirrors. Agility 1.11 → glide 0.89.
func agility_glide_mult() -> float: return 2.0 - agility_mult()

# Skill
func hands_blade_mult() -> float:    return _ht(_HANDS, height, skill)
# Backhand tracks the Hands lever (the controller's 0.75 base coeff keeps it below
# a forehand). Distinct accessor so the intent reads at the call site.
func hands_backhand_mult() -> float: return _ht(_HANDS, height, skill)
func shot_power_mult() -> float:     return _ht(_SHOT, height, skill)
# Slapper wind-up is the inverse of shot power (harder shooter threatens sooner).
func shot_charge_mult() -> float:    return 2.0 - shot_power_mult()

# Checking
func check_delivery_mult() -> float: return _ht(_DELIVERY, height, checking)
func brace_mult() -> float:          return _ht(_BRACE, height, checking)

# Height-only
func mass_mult() -> float:          return _h(_MASS, height)
func radius_mult() -> float:        return _h(_RADIUS, height)
func height_mult() -> float:        return _h(_HEIGHT, height)
func stick_len_mult() -> float:     return _h(_STICK_LEN, height)
func stamina_drain_mult() -> float: return _h(_STAMINA_DRAIN, height)
func stamina_regen_mult() -> float: return _h(_STAMINA_REGEN, height)

# Sprint ceiling — Speed-attributed, grounded to the 20–25 mph burst band.
func sprint_ceiling_mult() -> float:
	var n: float = clampf((speed_mult() - _SPEED_MULT_MIN)
			/ (_SPEED_MULT_MAX - _SPEED_MULT_MIN), 0.0, 1.0)
	return lerpf(SPRINT_CEIL_MIN, SPRINT_CEIL_MAX, n)

# Carry speed retention — eased by Hands (primary) + Speed (secondary), so an
# elite dangler OR an elite skater carries near-effortlessly. Higher = less penalty.
func carry_speed_mult() -> float:
	var hn: float = clampf((hands_blade_mult() - _HANDS_MULT_MIN)
			/ (_HANDS_MULT_MAX - _HANDS_MULT_MIN), 0.0, 1.0)
	var sn: float = clampf((speed_mult() - _SPEED_MULT_MIN)
			/ (_SPEED_MULT_MAX - _SPEED_MULT_MIN), 0.0, 1.0)
	return clampf(CARRY_BASE + hn * CARRY_HANDS_GAIN + sn * CARRY_SPEED_GAIN,
			CARRY_FLOOR, CARRY_CEIL)

# Visual
func torso_bulk_mult() -> float:     return _h(_TORSO_BULK, height)
func head_bulk_mult() -> float:      return _h(_HEAD_BULK, height)
func shoulder_bulk_mult() -> float:  return _t(_SHOULDER_BULK, checking)
func thigh_mult() -> float:          return _t(_THIGH, skating)
func calf_mult() -> float:           return _t(_CALF, skating)
func forearm_bulk_mult() -> float:   return _t(_FOREARM_BULK, skill)
func upper_arm_bulk_mult() -> float: return _t(_UPPER_ARM_BULK, skill)


# ── Serialization ─────────────────────────────────────────────────────────────
func to_dict() -> Dictionary:
	return {"height": height, "skating": skating, "skill": skill, "checking": checking}


# Rebuilds from a dict. Native keys (height/skating/skill/checking) win; a legacy
# six-attribute dict (speed/agility/hands/size/physical/shot, or the older
# skill/strength variants) is migrated via _migrate_legacy so old prefs and bot
# rosters keep loading. Missing native keys default to neutral.
static func from_dict(d: Dictionary) -> PlayerAttributes:
	if d.has("height") or d.has("skating") or d.has("checking"):
		return PlayerAttributes.new(
				int(d.get("height", HEIGHT_MEDIUM)),
				int(d.get("skating", TIER_AVERAGE)),
				int(d.get("skill", TIER_AVERAGE)),
				int(d.get("checking", TIER_AVERAGE)))
	# Legacy six-attribute (or four-attribute) dict.
	var legacy_skill: int = int(d.get("skill", d.get("strength", 3)))
	return migrate_legacy(
			int(d.get("speed", 3)), int(d.get("agility", 3)),
			int(d.get("hands", legacy_skill)), int(d.get("size", 3)),
			int(d.get("physical", 3)), int(d.get("shot", legacy_skill)))


# Maps a legacy 1..5 six-attribute build to the height + three-tier model. Height
# comes straight from the old Size axis (both 1..5). The three new attributes rank
# by a composite of their old heirs (Skating←speed+agility, Skill←hands+shot,
# Checking←physical), and the ranking assigns exactly one STRONG (highest), one
# WEAK (lowest), one AVERAGE (middle) — always a legal shape. Deterministic ties.
static func migrate_legacy(speed: int, agility: int, hands: int, size: int,
		physical: int, shot: int) -> PlayerAttributes:
	# Old Size was a 1..5 step; map it onto the anchor heights (coerce_height
	# accepts a 1..5 step and returns the matching inches).
	var new_height: int = coerce_height(size)
	# Composite scores on a common ~2..10 scale (physical doubled to match the sums).
	var scores: Array = [
		{"attr": Attribute.SKATING,  "score": speed + agility},
		{"attr": Attribute.SKILL,    "score": hands + shot},
		{"attr": Attribute.CHECKING, "score": physical * 2},
	]
	# Sort descending by score; stable tie-break by the enum order already in the
	# array (SKATING > SKILL > CHECKING) via a secondary index key.
	for i: int in scores.size():
		scores[i]["idx"] = i
	scores.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["score"] != b["score"]:
			return a["score"] > b["score"]
		return a["idx"] < b["idx"])
	var tiers: Dictionary = {}
	tiers[scores[0]["attr"]] = TIER_STRONG
	tiers[scores[1]["attr"]] = TIER_AVERAGE
	tiers[scores[2]["attr"]] = TIER_WEAK
	return PlayerAttributes.new(new_height,
			tiers[Attribute.SKATING], tiers[Attribute.SKILL], tiers[Attribute.CHECKING])


func equals(other: PlayerAttributes) -> bool:
	if other == null:
		return false
	return height == other.height and skating == other.skating \
			and skill == other.skill and checking == other.checking


# ── Internal ──────────────────────────────────────────────────────────────────
# Bracketing anchor rows for a height in inches: [lo_row, hi_row, t] where the
# interpolated value is lerp(row[lo], row[hi], t). A height on an anchor gives
# lo == hi (t = 0); the ends clamp.
static func _anchor(inches: int) -> Array:
	var h: int = clampi(inches, HEIGHT_MIN, HEIGHT_MAX)
	for i: int in range(ANCHOR_INCHES.size() - 1):
		if h <= ANCHOR_INCHES[i + 1]:
			var span: float = float(ANCHOR_INCHES[i + 1] - ANCHOR_INCHES[i])
			var t: float = 0.0 if span <= 0.0 else float(h - ANCHOR_INCHES[i]) / span
			return [i, i + 1, t]
	var last: int = ANCHOR_INCHES.size() - 1
	return [last, last, 0.0]


# 5×3 lookup interpolated by height: pick the tier column in the two bracketing
# rows and lerp between them.
static func _ht(table: Array, inches: int, tier: int) -> float:
	var a: Array = _anchor(inches)
	var lo_row: Array = table[a[0]]
	var hi_row: Array = table[a[1]]
	var tc: int = clampi(tier - TIER_WEAK, 0, lo_row.size() - 1)
	return lerpf(float(lo_row[tc]), float(hi_row[tc]), a[2])


# 5-vec lookup interpolated by height.
static func _h(table: Array, inches: int) -> float:
	var a: Array = _anchor(inches)
	return lerpf(float(table[a[0]]), float(table[a[1]]), a[2])


# 3-vec lookup by tier (discrete — tiers don't interpolate).
static func _t(table: Array, tier: int) -> float:
	return float(table[clampi(tier - TIER_WEAK, 0, table.size() - 1)])


# Accept a legacy 1..5 step (maps onto the anchor heights) OR a raw inches value.
# No real hockey height falls in 6..67, so the split is unambiguous; this keeps
# old prefs/bot/step values working without a version bump.
static func coerce_height(v: int) -> int:
	if v <= ANCHOR_INCHES.size():
		return ANCHOR_INCHES[clampi(v, 1, ANCHOR_INCHES.size()) - 1]
	return clampi(v, HEIGHT_MIN, HEIGHT_MAX)


static func _clamp_tier(v: int) -> int:
	return clampi(v, TIER_WEAK, TIER_STRONG)
