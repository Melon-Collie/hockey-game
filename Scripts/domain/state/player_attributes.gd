class_name PlayerAttributes
extends RefCounted

# PlayerAttributes
# ----------------
# Per-skater tuning. Each player has four attributes (Speed, Agility, Size,
# Skill), each on a 5-step scale: 1=floor … 3=MEDIUM (baseline) … 5=ceiling.
# MEDIUM = baseline (multiplier 1.0 across the board), so an all-medium roster
# plays and looks identical to the shipped @export defaults.
#
# What each attribute drives (headline effects — see SkaterController.apply_attributes):
#   - Speed   → max_speed (top end). Sprint multiplies max_speed, so a faster
#               skater also gets a proportionally faster sprint for free.
#   - Agility → thrust (all-direction acceleration) + facing turn rate + brake
#               + edge glide (friction_drag inverted) + puck-carry retention.
#   - Skill   → shot power (all pools) + charge speed + max_blade_speed (how fast
#               the blade swings through the dangle arc — the "hands" lever).
#   - Size    → weight + hitbox + reach/ROM (arm + stick length) + brace. Body
#               checking is NOT a separate multiplier: a Size player hits harder
#               purely through `weight` in the weight_ratio of the check formula
#               (skater.gd). body_check_transfer stays a flat constant — scaling
#               BOTH it and weight by Size would double-count Size multiplicatively.
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
#      attribute should yield a smaller value, like _SKILL_CHARGE_MULTS).
#   2. Add an accessor `func foo_mult() -> float` returning
#      `_lookup(_FOO_MULTS, <relevant attribute field>)`.
#   3. In the consumer (SkaterController.apply_attributes or
#      SkaterAppearanceCoordinator.apply), multiply a captured base value by it.
#
# Builds are point-buy: each attribute 1..5, total spend bounded by BUDGET.
# all-medium (3/3/3/3) sums to 12; BUDGET is 13, so a valid build always has at
# least one point above baseline (you must make a choice), and maxing one stat
# to 5 forces a dip below medium somewhere. is_within_budget() uses `<= BUDGET`
# (not `==`) so legacy/fresh sub-spent builds still pass host validation; the
# picker UI enforces exact spend.
#
# Persistence: PlayerPrefs (local pick), BotIdentityRegistry (bot picks),
# NetworkManager peer attributes table (online roster, replicated at join).

enum Attribute { SPEED, AGILITY, SIZE, SKILL }

const LEVEL_MIN: int = 1
const LEVEL_MEDIUM: int = 3
const LEVEL_MAX: int = 5
# Endpoint aliases for readability at extreme-value call sites.
const LEVEL_BAD: int = LEVEL_MIN
const LEVEL_GOOD: int = LEVEL_MAX

# Point-buy budget. all-medium (3+3+3+3) = 12; BUDGET 13 grants one point above
# baseline so every committed build makes at least one choice.
const BUDGET: int = 13

# ── Tuning tables ────────────────────────────────────────────────────────────
# All multipliers indexed by (level - LEVEL_MIN): [L1, L2, MEDIUM, L4, L5].

# Canonical gameplay (one per attribute) — the "headline" effect each attribute
# drives. (Skill's canonical headline is shot power.)
const _SPEED_MULTS:      Array[float] = [0.93, 0.965, 1.00, 1.035, 1.07]
const _AGILITY_MULTS:    Array[float] = [0.90, 0.95,  1.00, 1.05,  1.10]
const _SIZE_MULTS:       Array[float] = [0.82, 0.91,  1.00, 1.09,  1.18]
const _SKILL_SHOT_MULTS: Array[float] = [0.85, 0.925, 1.00, 1.075, 1.15]

# Specialized gameplay — extra effects layered on top of the canonical ones.
# HEIGHT: every "proportional to actual body height" measurement (arms, stick,
#   mesh Y-scale, hitbox height, and reach/ROM derived from arm length). On the
#   1.78 m (5'10") baseline mesh this spans ~5'7" (L1) to ~6'5" (L5) — asymmetric
#   up, matching hockey's right-skewed height distribution and avoiding an
#   unrealistically short floor. Narrower than SIZE_WEIGHT because a bigger
#   player gains mass (3D) faster than height (1D).
# SIZE_WEIGHT: the ONLY thing that scales body-check force now — via weight_ratio
#   in skater.gd. Widened to ±18% (heaviest ≈ 1.44× the lightest) for a realistic
#   small-vs-large mass differential, which also makes checks read clearly
#   across sizes.
# AGILITY_CARRY: small boost — agile dekers retain more puck speed.
# AGILITY_GLIDE: inverted (lower = less drag during cuts) — the "good edges" feel.
# SKILL_CHARGE: inverted (lower = slower ramp to max power). High Skill threatens
#   at close range.
# SIZE_CHARGE: matches HEIGHT (arm length → ROM). Keeps the charge cap a constant
#   fraction of each player's reach so all sizes fill the bar with equal effort.
# SKILL_BLADE: max_blade_speed — how fast the blade chases the cursor through the
#   dangle arc and draws back to absorb fast passes. The "hands" lever.
const _HEIGHT_MULTS:        Array[float] = [0.955, 0.978, 1.00, 1.05,  1.10]
const _SIZE_WEIGHT_MULTS:   Array[float] = [0.82,  0.91,  1.00, 1.09,  1.18]
const _AGILITY_CARRY_MULTS: Array[float] = [0.96, 0.98,  1.00, 1.02,  1.04]
const _AGILITY_GLIDE_MULTS: Array[float] = [1.10, 1.05,  1.00, 0.95,  0.90]
const _SKILL_CHARGE_MULTS:  Array[float] = [1.12, 1.06,  1.00, 0.94,  0.88]
const _SIZE_CHARGE_MULTS:   Array[float] = [0.91, 0.955, 1.00, 1.045, 1.09]
const _SKILL_BLADE_MULTS:   Array[float] = [0.85, 0.925, 1.00, 1.075, 1.15]

# Visual-only — drive `transform.scale` on body-chain mesh leaves and arm mesh
# radii. Wider than gameplay tables on purpose: the third-person hockey camera
# makes subtle differences hard to read, so silhouettes meaningfully differ
# between attribute extremes. Arm bulk is keyed to Size (physical frame, not the
# invisible Skill stat) and is widest / asymmetric on the GOOD side for a
# "jacked" big-player silhouette.
const _TORSO_BULK_MULTS: Array[float] = [0.82, 0.91, 1.00, 1.09, 1.18]
const _HEAD_BULK_MULTS:  Array[float] = [0.92, 0.96, 1.00, 1.04, 1.08]
const _THIGH_MULTS:      Array[float] = [0.82, 0.91, 1.00, 1.09, 1.18]
const _CALF_MULTS:       Array[float] = [0.82, 0.91, 1.00, 1.09, 1.18]
const _ARM_BULK_MULTS:   Array[float] = [0.78, 0.89, 1.00, 1.20, 1.40]

# Used by multiplier_for() to look up the canonical table by Attribute enum.
const _CANONICAL_TABLES: Dictionary = {
	Attribute.SPEED:   _SPEED_MULTS,
	Attribute.AGILITY: _AGILITY_MULTS,
	Attribute.SIZE:    _SIZE_MULTS,
	Attribute.SKILL:   _SKILL_SHOT_MULTS,
}

# ── State ────────────────────────────────────────────────────────────────────
var speed:   int = LEVEL_MEDIUM
var agility: int = LEVEL_MEDIUM
var size:    int = LEVEL_MEDIUM
var skill:   int = LEVEL_MEDIUM


func _init(p_speed: int = LEVEL_MEDIUM, p_agility: int = LEVEL_MEDIUM,
		p_size: int = LEVEL_MEDIUM, p_skill: int = LEVEL_MEDIUM) -> void:
	speed   = _clamp_level(p_speed)
	agility = _clamp_level(p_agility)
	size    = _clamp_level(p_size)
	skill   = _clamp_level(p_skill)


static func all_medium() -> PlayerAttributes:
	return PlayerAttributes.new()


# Direct construction from four levels (the slider picker hands these in raw).
static func from_levels(p_speed: int, p_agility: int, p_size: int, p_skill: int) -> PlayerAttributes:
	return PlayerAttributes.new(p_speed, p_agility, p_size, p_skill)


# Whether a raw level tuple is a legal point-buy build: every level in [1,5] and
# the total spend at or under BUDGET. The host validates joiner attributes with
# this — per-level clamping alone still admits forged over-budget spreads like
# 5/5/5/5. `<=` (not `==`) so a fresh install or migrated build sitting one point
# under budget isn't force-reset to all-medium online; over-budget is the only
# thing that can grant unearned power, and that's rejected. Out-of-budget spreads
# fall back to all_medium().
static func is_within_budget(p_speed: int, p_agility: int, p_size: int, p_skill: int) -> bool:
	if not (_in_range(p_speed) and _in_range(p_agility) and _in_range(p_size) and _in_range(p_skill)):
		return false
	return p_speed + p_agility + p_size + p_skill <= BUDGET


# Total points spent across all four attributes (the picker shows this vs BUDGET).
func total_spend() -> int:
	return speed + agility + size + skill


func level_for(attr: int) -> int:
	match attr:
		Attribute.SPEED:   return speed
		Attribute.AGILITY: return agility
		Attribute.SIZE:    return size
		Attribute.SKILL:   return skill
	return LEVEL_MEDIUM


# ── Named multiplier accessors ───────────────────────────────────────────────
# Canonical gameplay
func speed_mult()      -> float: return _lookup(_SPEED_MULTS,      speed)
func agility_mult()    -> float: return _lookup(_AGILITY_MULTS,    agility)
func size_mult()       -> float: return _lookup(_SIZE_MULTS,       size)
func skill_shot_mult() -> float: return _lookup(_SKILL_SHOT_MULTS, skill)

# Specialized gameplay
func height_mult()        -> float: return _lookup(_HEIGHT_MULTS,        size)
func size_weight_mult()   -> float: return _lookup(_SIZE_WEIGHT_MULTS,   size)
func agility_carry_mult() -> float: return _lookup(_AGILITY_CARRY_MULTS, agility)
func agility_glide_mult() -> float: return _lookup(_AGILITY_GLIDE_MULTS, agility)
func skill_charge_mult()  -> float: return _lookup(_SKILL_CHARGE_MULTS,  skill)
func size_charge_mult()   -> float: return _lookup(_SIZE_CHARGE_MULTS,   size)
func skill_blade_mult()   -> float: return _lookup(_SKILL_BLADE_MULTS,   skill)

# Visual
func torso_bulk_mult() -> float: return _lookup(_TORSO_BULK_MULTS, size)
func head_bulk_mult()  -> float: return _lookup(_HEAD_BULK_MULTS,  size)
func thigh_mult()      -> float: return _lookup(_THIGH_MULTS,      speed)
func calf_mult()       -> float: return _lookup(_CALF_MULTS,       agility)
func arm_bulk_mult()   -> float: return _lookup(_ARM_BULK_MULTS,   size)


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
	return {"speed": speed, "agility": agility, "size": size, "skill": skill}


static func from_dict(d: Dictionary) -> PlayerAttributes:
	# Accept the legacy "strength" key so old persisted dicts still load.
	return PlayerAttributes.new(
			int(d.get("speed",   LEVEL_MEDIUM)),
			int(d.get("agility", LEVEL_MEDIUM)),
			int(d.get("size",    LEVEL_MEDIUM)),
			int(d.get("skill",   d.get("strength", LEVEL_MEDIUM))))


func equals(other: PlayerAttributes) -> bool:
	if other == null:
		return false
	return speed == other.speed and agility == other.agility \
			and size == other.size and skill == other.skill


# ── Internal ─────────────────────────────────────────────────────────────────
static func _in_range(level: int) -> bool:
	return level >= LEVEL_MIN and level <= LEVEL_MAX


static func _lookup(table: Array, level: int) -> float:
	return float(table[clampi(level - LEVEL_MIN, 0, table.size() - 1)])


static func _clamp_level(v: int) -> int:
	return clampi(v, LEVEL_MIN, LEVEL_MAX)
