class_name PlayerAttributes
extends RefCounted

# PlayerAttributes
# ----------------
# Per-skater tuning. Each player has SIX attributes (Speed, Agility, Hands,
# Size, Physical, Shot), each on a 5-step scale: 1=floor … 3=MEDIUM (baseline)
# … 5=ceiling. MEDIUM = baseline (multiplier 1.0 across the board), so an
# all-medium roster plays and looks identical to the shipped @export defaults.
#
# What each attribute drives (headline effects — see SkaterController.apply_attributes):
#   - Speed    → max_speed (top end). Sprint multiplies max_speed, so a faster
#                skater also gets a proportionally faster sprint for free.
#   - Agility  → thrust (all-direction acceleration) + facing turn rate + brake
#                + edge glide (friction_drag inverted).
#   - Hands    → max_blade_speed (the dangle/pass-absorb "hands" lever) +
#                puck-carry speed (how little the puck slows you while carrying)
#                + backhand shot power (un-penalizes the backhand — the in-tight
#                finishing move that distinguishes the dangler from the sniper).
#   - Size     → weight + hitbox + reach/ROM (arm + stick length) + charge-reach
#                coupling. Resists checks through MASS (the weight_ratio in the
#                check formula, skater.gd): a big player is hard to MOVE.
#   - Physical → body_check_transfer (how hard you DELIVER a hit) +
#                body_check_brace_resistance (hard to PUT DOWN — the active brace)
#                + stamina on TWO curves: a gentle drain scale (sprint duration)
#                and a STEEP, asymmetric regen scale (recovery). Low Physical
#                sprints nearly as long but recovers brutally slowly — a full bar
#                takes ~9 s (≈4.5 s to the sprint-unlock) vs ~3 s for high. The
#                grinder / motor stat: deliver hits, absorb hits, outlast everyone.
#   - Shot     → the CHARGED-shot power ceiling (wrister max + both slapper pools)
#                plus wrister charge EFFORT (inverted + widened — low Shot must
#                drag far to fill the bar, high Shot fills it fast). The quick /
#                uncharged snap stays BASELINE for everyone because it doubles as
#                pass speed, so Shot is "what a charge buys you and how fast you
#                can charge it," not snap power. The sniper lever.
#
# Two pairs intentionally co-own one outcome on DIFFERENT axes, so they compose
# rather than double-count:
#   • Body checks: Size via mass (weight in the ratio), Physical via the
#     transfer/brace coefficients. "Big = hard to move, strong = hard to put
#     down." Scaling BOTH weight and transfer by one stat would double-count it;
#     splitting across Size and Physical does not.
#   • Offense: Shot is raw power + release (the sniper), Hands is puck control +
#     the backhand finish (the dangler). A backhand shot reads both — base power
#     (Shot) × backhand coefficient (Hands).
#
# Scale: the 5-step tables keep the OLD 3-step endpoints (old level 3 == new
# level 5, old level 1 == new level 1) and interpolate the two new in-between
# steps, with level 3 pinned to 1.0. So widening the scale changed granularity,
# not range.
#
# Every tuning multiplier in the attributes system lives in this file as a
# private const and is consumed via the named instance accessors below —
# never index a `_*_MULTS` table directly outside this file.
#
# To add a new "X scales Y" rule:
#   1. Add a `_FOO_MULTS: Array[float] = [L1, L2, MEDIUM, L4, L5]` const. MEDIUM
#      (index 2) should be 1.0; usually L1 < 1.0 < L5 (or "inverted" if a higher
#      attribute should yield a smaller value, like _SHOT_CHARGE_MULTS).
#      (Exception: _HEIGHT_MULTS / _STICK_LEN_MULTS put their 1.0 at L2 — the
#      mesh-native 5'10" — because medium-Size height is intentionally 6'0".)
#   2. Add an accessor `func foo_mult() -> float` returning
#      `_lookup(_FOO_MULTS, <relevant attribute field>)`.
#   3. In the consumer (SkaterController.apply_attributes or
#      SkaterAppearanceCoordinator.apply), multiply a captured base value by it.
#
# Builds are point-buy: each attribute 1..5, total spend bounded by BUDGET.
# all-medium (3×6) sums to 18; BUDGET is 18, so an all-medium all-rounder is
# legal but unspectacular — any spike to 5 forces a dip to 1 somewhere.
# is_within_budget() uses `<= BUDGET` (not `==`) so legacy/fresh sub-spent
# builds still pass host validation; the picker UI enforces exact spend.
#
# Persistence: PlayerPrefs (local pick), BotIdentityRegistry (bot picks),
# NetworkManager peer attributes table (online roster, replicated at join).

enum Attribute { SPEED, AGILITY, HANDS, SIZE, PHYSICAL, SHOT }

const LEVEL_MIN: int = 1
const LEVEL_MEDIUM: int = 3
const LEVEL_MAX: int = 5
# Endpoint aliases for readability at extreme-value call sites.
const LEVEL_BAD: int = LEVEL_MIN
const LEVEL_GOOD: int = LEVEL_MAX

# Point-buy budget. all-medium (3×6) = 18; BUDGET 18 lets an all-rounder exist
# but makes every spike to 5 cost a dip to 1 somewhere.
const BUDGET: int = 18

# ── Tuning tables ────────────────────────────────────────────────────────────
# All multipliers indexed by (level - LEVEL_MIN): [L1, L2, MEDIUM, L4, L5].

# Canonical gameplay (one per attribute) — the "headline" effect each attribute
# drives. (Hands' canonical headline is blade speed; Physical's is check force;
# Shot's is the charged-shot power ceiling — the quick/uncharged snap stays
# baseline because it doubles as pass speed.)
# PHYSICAL_CHECK is the WIDEST canonical spread (+/-36%) on purpose: Physical is
# the dedicated "how hard you DELIVER a hit" lever, so it has to read clearly at
# both ends. A maxed enforcer hits like a freight train (L5 1.36, and a
# Size5+Physical5 build delivers ~1.6x baseline, ~2x against a small victim),
# while a low-Physical player barely registers a check — at L1 (0.64) a
# moderate-speed hit falls under the stagger threshold entirely, so they bump
# people rather than rock them. Size still contributes delivery through mass
# (weight_ratio), but Physical is the stat that says "I hit people."
# SHOT_POWER (+/-18%) is anchored to real NHL shot speeds against the GameRules
# base maxes (wrister 33 m/s, slapper 40 m/s = a league-average L3 shooter):
#   L5 → wrister ~38.9 m/s (~87 mph) and slapper ~47.2 m/s (~106 mph) — an
#        elite, top-of-the-league release (Ovechkin wrister / Weber slapper);
#   L1 → ~27.4 / ~33.2 m/s (61 / 74 mph) — a weak-for-pro shot that still
#        stings. The hierarchy stays honest across builds: a maxed sniper's
#        wrister (38.9) beats a min-Shot slapper (33.2) but never a same-level
#        slapper.
const _SPEED_MULTS:          Array[float] = [0.93, 0.965, 1.00, 1.035, 1.07]
const _AGILITY_MULTS:        Array[float] = [0.90, 0.95,  1.00, 1.05,  1.10]
const _HANDS_BLADE_MULTS:    Array[float] = [0.85, 0.925, 1.00, 1.125, 1.25]
const _SIZE_MULTS:           Array[float] = [0.82, 0.91,  1.00, 1.09,  1.18]
const _PHYSICAL_CHECK_MULTS: Array[float] = [0.64, 0.82,  1.00, 1.18,  1.36]
const _SHOT_POWER_MULTS:     Array[float] = [0.83, 0.91,  1.00, 1.09,  1.18]

# Specialized gameplay — extra effects layered on top of the canonical ones.
# HEIGHT: every "proportional to actual body height" measurement (arms, the
#   mesh skeleton scaled about the ice plane — roots, leg pivot chain, part
#   positions, mesh Y-scale — hand heights, and reach/ROM derived from arm
#   length; the physics hitbox HEIGHT deliberately stays constant). Heights
#   on the 1.78 m (5'10") mesh: L1 5'7", L2 5'10", L3 6'0", L4 6'3", L5 6'5" —
#   a deliberately tall, modern-NHL-skewed league. NOTE the exception to the
#   medium=1.0 convention: because medium-Size is 6'0", the 1.0 identity (the
#   mesh-native 5'10") sits at L2, not L3. Narrower than SIZE_WEIGHT because a
#   bigger player gains mass (3D) faster than height (1D).
# STICK_LEN: the stick is equipment, not anatomy, so it scales on a GENTLER curve
#   than HEIGHT (~0.65× the height deviation, a ~9.5% L1→L5 spread vs HEIGHT's
#   ~15%). Real played stick lengths track height only loosely — fitment is
#   chin-height but heavily preference/role-driven — so a small player runs a
#   near-full-size stick rather than a tiny one. Total blade reach is still
#   arm-driven ROM + stick (see top_hand_ik.gd FAR regime), and ROM stays on the
#   full anatomical HEIGHT curve, so taller players still reach furthest; only the
#   stick's contribution is eased. Shares HEIGHT's L2-identity exception.
# SIZE_WEIGHT: Size's contribution to body checks — via weight_ratio in
#   skater.gd. Widened to ±18% (heaviest ≈ 1.44× the lightest) for a realistic
#   small-vs-large mass differential, which makes both delivered and received
#   checks read clearly across sizes. (Physical adds the transfer/brace coefficients
#   on top — see _PHYSICAL_CHECK_MULTS / _PHYSICAL_BRACE_MULTS.)
# HANDS_CARRY: how little the puck slows you while carrying (widened from the old
#   trivial ±4% to ±10% now that it's a headline Hands lever — "carries it like
#   it's not even there").
# HANDS_BACKHAND: scales the backhand power coefficient UP toward 1.0 (a great
#   backhand barely drops off; a poor one is a wet noodle). The base coefficient
#   is 0.75, so L5 (×1.24 → 0.93) stays safely below a forehand — a backhand
#   never beats the forehand it's penalizing.
# AGILITY_GLIDE: inverted (lower = less drag during cuts) — the "good edges" feel.
# SHOT_CHARGE: inverted (lower = slower ramp). The SLAPPER wind-up time. High Shot
#   threatens at close range with a quick release.
# PHYSICAL_BRACE: inverted (lower = better resistance) — Physical is the active
#   brace that keeps you on your feet / on the puck through contact. Replaces the
#   old Size-driven brace; Size now resists only through mass (weight_ratio).
# PHYSICAL_DRAIN: inverted (lower = slower drain) — sprint DURATION. Gentle spread
#   so every build gets a usable burst (free sprint ~1.9 s at L1 → ~2.6 s at L5).
# PHYSICAL_REGEN: stamina recovery rate (multiplied in). STEEP on the low end and
#   asymmetric — medium/high refill near the shipped rate, but a low-Physical
#   player who gases out is punished hard: a full bar runs ~9 s at L1 (≈4.5 s to
#   the 0.5 sprint-unlock) vs ~3 s at L5. High barely beats medium; the spread is
#   all downside for neglecting the stat. Kept separate from DRAIN so recovery can
#   be brutal without also shortening the sprint itself.
const _HEIGHT_MULTS:          Array[float] = [0.957, 1.000, 1.029, 1.071, 1.100]
const _STICK_LEN_MULTS:       Array[float] = [0.972, 1.000, 1.019, 1.046, 1.065]
const _SIZE_WEIGHT_MULTS:     Array[float] = [0.82,  0.91,  1.00, 1.09,  1.18]
const _HANDS_CARRY_MULTS:     Array[float] = [0.90,  0.95,  1.00, 1.05,  1.10]
const _HANDS_BACKHAND_MULTS:  Array[float] = [0.85,  0.93,  1.00, 1.12,  1.24]
const _AGILITY_GLIDE_MULTS:   Array[float] = [1.10,  1.05,  1.00, 0.95,  0.90]
const _SHOT_CHARGE_MULTS:     Array[float] = [1.12,  1.06,  1.00, 0.94,  0.88]
const _PHYSICAL_BRACE_MULTS:  Array[float] = [1.18,  1.09,  1.00, 0.91,  0.82]
const _PHYSICAL_DRAIN_MULTS:  Array[float] = [0.85,  0.925, 1.00, 1.075, 1.15]
const _PHYSICAL_REGEN_MULTS:  Array[float] = [0.45,  0.70,  1.00, 1.15,  1.30]

# Visual-only — drive `transform.scale` on body-chain mesh leaves and arm mesh
# radii. Wider than gameplay tables on purpose: the third-person hockey camera
# makes subtle differences hard to read, so silhouettes meaningfully differ
# between attribute extremes. Each attribute owns one visual tell, split down the
# arm so all six read: torso/head → Size, shoulders/yoke → Physical, thigh →
# Speed, calf → Agility, FOREARM → Hands (the "hands" stat reads as thick
# forearms — a high-Hands dangler), UPPER ARM → Shot (the shooter's biceps/
# triceps). Arm bulk is widest / asymmetric on the GOOD side for a "jacked" look.
const _TORSO_BULK_MULTS:     Array[float] = [0.82, 0.91, 1.00, 1.09, 1.18]
const _HEAD_BULK_MULTS:      Array[float] = [0.92, 0.96, 1.00, 1.04, 1.08]
const _SHOULDER_BULK_MULTS:  Array[float] = [0.85, 0.92, 1.00, 1.10, 1.20]
const _THIGH_MULTS:          Array[float] = [0.82, 0.91, 1.00, 1.09, 1.18]
const _CALF_MULTS:           Array[float] = [0.82, 0.91, 1.00, 1.09, 1.18]
const _FOREARM_BULK_MULTS:   Array[float] = [0.78, 0.89, 1.00, 1.20, 1.40]
const _UPPER_ARM_BULK_MULTS: Array[float] = [0.80, 0.90, 1.00, 1.18, 1.36]

# Used by multiplier_for() to look up the canonical table by Attribute enum.
const _CANONICAL_TABLES: Dictionary = {
	Attribute.SPEED:    _SPEED_MULTS,
	Attribute.AGILITY:  _AGILITY_MULTS,
	Attribute.HANDS:    _HANDS_BLADE_MULTS,
	Attribute.SIZE:     _SIZE_MULTS,
	Attribute.PHYSICAL: _PHYSICAL_CHECK_MULTS,
	Attribute.SHOT:     _SHOT_POWER_MULTS,
}

# ── State ────────────────────────────────────────────────────────────────────
var speed:    int = LEVEL_MEDIUM
var agility:  int = LEVEL_MEDIUM
var hands:    int = LEVEL_MEDIUM
var size:     int = LEVEL_MEDIUM
var physical: int = LEVEL_MEDIUM
var shot:     int = LEVEL_MEDIUM


func _init(p_speed: int = LEVEL_MEDIUM, p_agility: int = LEVEL_MEDIUM,
		p_hands: int = LEVEL_MEDIUM, p_size: int = LEVEL_MEDIUM,
		p_physical: int = LEVEL_MEDIUM, p_shot: int = LEVEL_MEDIUM) -> void:
	speed    = _clamp_level(p_speed)
	agility  = _clamp_level(p_agility)
	hands    = _clamp_level(p_hands)
	size     = _clamp_level(p_size)
	physical = _clamp_level(p_physical)
	shot     = _clamp_level(p_shot)


static func all_medium() -> PlayerAttributes:
	return PlayerAttributes.new()


# Direct construction from six levels (the slider picker hands these in raw, in
# Attribute enum order: Speed, Agility, Hands, Size, Physical, Shot).
static func from_levels(p_speed: int, p_agility: int, p_hands: int,
		p_size: int, p_physical: int, p_shot: int) -> PlayerAttributes:
	return PlayerAttributes.new(p_speed, p_agility, p_hands, p_size, p_physical, p_shot)


# Whether a raw level tuple is a legal point-buy build: every level in [1,5] and
# the total spend at or under BUDGET. The host validates joiner attributes with
# this — per-level clamping alone still admits forged over-budget spreads like
# 5/5/5/5/5/5. `<=` (not `==`) so a fresh install or migrated build sitting under
# budget isn't force-reset to all-medium online; over-budget is the only thing
# that can grant unearned power, and that's rejected. Out-of-budget spreads fall
# back to all_medium().
static func is_within_budget(p_speed: int, p_agility: int, p_hands: int,
		p_size: int, p_physical: int, p_shot: int) -> bool:
	if not (_in_range(p_speed) and _in_range(p_agility) and _in_range(p_hands)
			and _in_range(p_size) and _in_range(p_physical) and _in_range(p_shot)):
		return false
	return p_speed + p_agility + p_hands + p_size + p_physical + p_shot <= BUDGET


# Total points spent across all six attributes (the picker shows this vs BUDGET).
func total_spend() -> int:
	return speed + agility + hands + size + physical + shot


# Deterministically reduce a six-level build to within BUDGET by shedding one
# point at a time from the axes in `trim_order` (indices into the Attribute enum:
# 0 Speed, 1 Agility, 2 Hands, 3 Size, 4 Physical, 5 Shot), cycling through the
# order and stopping the instant the total is at or under BUDGET. Round-robin
# (one point per axis per pass) spreads the loss so a high all-rounder trims
# evenly rather than gutting one axis; leading `trim_order` entries floor soonest,
# so pass the non-identity axes first. Per-level values are clamped into range
# first, and it ALWAYS terminates — every axis floors at LEVEL_MIN and
# 6×LEVEL_MIN = 6 ≤ BUDGET. Used by prefs migration + hand-edit / corrupt-cfg
# repair so an over-budget spread (a legacy 4→6 split that seeds two new axes, or
# a forged cfg) becomes a legal build instead of granting unearned power.
static func trimmed_to_budget(p_speed: int, p_agility: int, p_hands: int,
		p_size: int, p_physical: int, p_shot: int,
		trim_order: PackedInt32Array) -> PlayerAttributes:
	var levels: PackedInt32Array = [
		clampi(p_speed, LEVEL_MIN, LEVEL_MAX), clampi(p_agility, LEVEL_MIN, LEVEL_MAX),
		clampi(p_hands, LEVEL_MIN, LEVEL_MAX), clampi(p_size, LEVEL_MIN, LEVEL_MAX),
		clampi(p_physical, LEVEL_MIN, LEVEL_MAX), clampi(p_shot, LEVEL_MIN, LEVEL_MAX),
	]
	var guard: int = 0
	while _sum_levels(levels) > BUDGET and guard < 256:
		guard += 1
		var reduced: bool = false
		for idx: int in trim_order:
			if idx >= 0 and idx < levels.size() and levels[idx] > LEVEL_MIN:
				levels[idx] -= 1
				reduced = true
				if _sum_levels(levels) <= BUDGET:
					break
		if not reduced:
			break  # every axis in trim_order already at the floor
	return PlayerAttributes.new(levels[0], levels[1], levels[2], levels[3], levels[4], levels[5])


static func _sum_levels(levels: PackedInt32Array) -> int:
	var total: int = 0
	for v: int in levels:
		total += v
	return total


func level_for(attr: int) -> int:
	match attr:
		Attribute.SPEED:    return speed
		Attribute.AGILITY:  return agility
		Attribute.HANDS:    return hands
		Attribute.SIZE:     return size
		Attribute.PHYSICAL: return physical
		Attribute.SHOT:     return shot
	return LEVEL_MEDIUM


# ── Named multiplier accessors ───────────────────────────────────────────────
# Canonical gameplay
func speed_mult()       -> float: return _lookup(_SPEED_MULTS,          speed)
func agility_mult()     -> float: return _lookup(_AGILITY_MULTS,        agility)
func hands_blade_mult() -> float: return _lookup(_HANDS_BLADE_MULTS,    hands)
func size_mult()        -> float: return _lookup(_SIZE_MULTS,           size)
func physical_check_mult() -> float: return _lookup(_PHYSICAL_CHECK_MULTS, physical)
func shot_power_mult()  -> float: return _lookup(_SHOT_POWER_MULTS,     shot)

# Specialized gameplay
func height_mult()         -> float: return _lookup(_HEIGHT_MULTS,         size)
func stick_len_mult()      -> float: return _lookup(_STICK_LEN_MULTS,      size)
func size_weight_mult()    -> float: return _lookup(_SIZE_WEIGHT_MULTS,    size)
func hands_carry_mult()    -> float: return _lookup(_HANDS_CARRY_MULTS,    hands)
func hands_backhand_mult() -> float: return _lookup(_HANDS_BACKHAND_MULTS, hands)
func agility_glide_mult()  -> float: return _lookup(_AGILITY_GLIDE_MULTS,  agility)
func shot_charge_mult()    -> float: return _lookup(_SHOT_CHARGE_MULTS,    shot)
func physical_brace_mult() -> float: return _lookup(_PHYSICAL_BRACE_MULTS, physical)
func physical_drain_mult() -> float: return _lookup(_PHYSICAL_DRAIN_MULTS, physical)
func physical_regen_mult() -> float: return _lookup(_PHYSICAL_REGEN_MULTS, physical)

# Visual
func torso_bulk_mult()     -> float: return _lookup(_TORSO_BULK_MULTS,     size)
func head_bulk_mult()      -> float: return _lookup(_HEAD_BULK_MULTS,      size)
func shoulder_bulk_mult()  -> float: return _lookup(_SHOULDER_BULK_MULTS,  physical)
func thigh_mult()          -> float: return _lookup(_THIGH_MULTS,          speed)
func calf_mult()           -> float: return _lookup(_CALF_MULTS,           agility)
func forearm_bulk_mult()   -> float: return _lookup(_FOREARM_BULK_MULTS,   hands)
func upper_arm_bulk_mult() -> float: return _lookup(_UPPER_ARM_BULK_MULTS, shot)


# Generic accessor for the canonical-gameplay multipliers, parameterized by
# Attribute enum. Used by tests; new application code should prefer the named
# accessors above for readability at the call site.
func multiplier_for(attr: int) -> float:
	var table: Array = _CANONICAL_TABLES.get(attr, [])
	if table.is_empty():
		return 1.0
	return _lookup(table, level_for(attr))


# ── Serialization ────────────────────────────────────────────────────────────
func to_dict() -> Dictionary:
	return {"speed": speed, "agility": agility, "hands": hands,
			"size": size, "physical": physical, "shot": shot}


static func from_dict(d: Dictionary) -> PlayerAttributes:
	# New keys win; for a legacy four-attribute dict the old "skill" (or the even
	# older "strength") axis seeds BOTH offensive heirs — Shot and Hands — since
	# old Skill governed shot power AND blade speed. Missing axes default medium.
	var legacy_skill: int = int(d.get("skill", d.get("strength", LEVEL_MEDIUM)))
	return PlayerAttributes.new(
			int(d.get("speed",    LEVEL_MEDIUM)),
			int(d.get("agility",  LEVEL_MEDIUM)),
			int(d.get("hands",    legacy_skill)),
			int(d.get("size",     LEVEL_MEDIUM)),
			int(d.get("physical", LEVEL_MEDIUM)),
			int(d.get("shot",     legacy_skill)))


func equals(other: PlayerAttributes) -> bool:
	if other == null:
		return false
	return speed == other.speed and agility == other.agility \
			and hands == other.hands and size == other.size \
			and physical == other.physical and shot == other.shot


# ── Internal ─────────────────────────────────────────────────────────────────
static func _in_range(level: int) -> bool:
	return level >= LEVEL_MIN and level <= LEVEL_MAX


static func _lookup(table: Array, level: int) -> float:
	return float(table[clampi(level - LEVEL_MIN, 0, table.size() - 1)])


static func _clamp_level(v: int) -> int:
	return clampi(v, LEVEL_MIN, LEVEL_MAX)
