class_name PlayerAttributes
extends RefCounted

# PlayerAttributes
# ----------------
# Per-skater tuning. Each player has four attributes (Speed, Agility, Size,
# Strength), each on a 3-step scale: 1=BAD, 2=MEDIUM, 3=GOOD. MEDIUM =
# baseline (multiplier 1.0 across the board), so an all-medium roster plays
# and looks identical to the shipped @export defaults.
#
# Every tuning multiplier in the attributes system lives in this file as a
# private const and is consumed via the named instance accessors below —
# never index a `_*_MULTS` table directly outside this file.
#
# To add a new "X scales Y" rule:
#   1. Add a `_FOO_MULTS: Array[float] = [BAD, MEDIUM, GOOD]` const. MEDIUM
#      should be 1.0; usually BAD < 1.0 < GOOD (or "inverted" if higher
#      attribute should yield a smaller value, like _STRENGTH_CHARGE_MULTS).
#   2. Add an accessor `func foo_mult() -> float` that returns
#      `_lookup(_FOO_MULTS, <relevant attribute field>)`.
#   3. In the consumer (SkaterController.apply_attributes or
#      SkaterAppearanceCoordinator.apply), multiply a captured base value by
#      `attrs.foo_mult()`.
#
# Why so many tables instead of one-per-attribute?  Different effects need
# different spreads:
#   - Body checks want a wide Strength spread (±25%) for hit feel
#   - Shot power wants a narrower spread (±15%) so the floor stays playable
#   - Weight is decoupled from canonical Size (±12% vs ±18%) so Strength
#     can outweigh raw mass differential in the check formula
#   - Charge speed wants Strength inverted (lower = faster, ±12%)
#   - Charge cap matches Size→arm length so all sizes fill the bar with the
#     same fraction of their ROM (±9%, same shape as HEIGHT_MULTS)
#   - Carry retention wants a small Agility spread (±4%)
# A single per-attribute table couldn't carry all those shapes.
#
# Conventions:
#   - Apply as `live = base × mult` everywhere (no division). "Inverted"
#     tables bake the inversion in: BAD > 1.0 > GOOD.
#   - Accessors are instance methods (e.g. `attrs.speed_mult()`), not
#     static — they read the relevant level field from `self`.
#
# Persistence: PlayerPrefs (local pick), BotIdentityRegistry (bot picks),
# NetworkManager peer attributes table (online roster, replicated at join).

enum Attribute { SPEED, AGILITY, SIZE, STRENGTH }

const LEVEL_BAD: int = 1
const LEVEL_MEDIUM: int = 2
const LEVEL_GOOD: int = 3
const LEVEL_MIN: int = LEVEL_BAD
const LEVEL_MAX: int = LEVEL_GOOD

# ── Tuning tables ────────────────────────────────────────────────────────────
# All multipliers indexed by (level - LEVEL_MIN): [BAD, MEDIUM, GOOD].

# Canonical gameplay (one per attribute) — the "headline" effect each
# attribute drives. Strength is widest because the body-check delivery
# spread needs to outweigh the Size-driven weight differential.
const _SPEED_MULTS:    Array[float] = [0.93, 1.00, 1.07]
const _AGILITY_MULTS:  Array[float] = [0.90, 1.00, 1.10]
const _SIZE_MULTS:     Array[float] = [0.82, 1.00, 1.18]
const _STRENGTH_MULTS: Array[float] = [0.75, 1.00, 1.25]

# Specialized gameplay — extra effects layered on top of the canonical
# multipliers above.
# HEIGHT: every "proportional to actual body height" measurement (arms,
#   stick, mesh Y-scale, hitbox height). Tighter than _SIZE_MULTS because
#   real height range is narrower than mass range.
# SIZE_WEIGHT: decoupled from canonical Size so the weight_ratio in the
#   body-check math doesn't dominate Strength. ±12% keeps Big Med ahead
#   of Small Strong in checker effectiveness while letting Small Strong
#   land essentially-baseline hits on Big Weak.
# AGILITY_CARRY: small modest boost — agile dekers retain more puck speed.
# AGILITY_GLIDE: inverted (lower = less drag during cuts). Agile skaters
#   leak less momentum through their edges — the "good edges" feel.
# STRENGTH_SHOT: narrower than canonical Strength so the shot-power floor
#   stays playable (a weak shooter's max wrister is ~33 mph vs strong at
#   ~45 mph). Wider than the old Shot attribute (±8%) so investment
#   actually matters.
# STRENGTH_CHARGE: inverted (lower = faster ramp to max power). Lets a
#   Strength-strong player threaten at close range.
# SIZE_CHARGE: matches HEIGHT (arm length, hence ROM). Compensates for the
#   blade-driven charge model — without it, smaller players couldn't fill
#   the charge bar because their ROM caps the achievable blade arc. Scaling
#   the cap proportionally to ROM keeps the "fraction of your reach used"
#   constant across sizes, so a small player and a big player both fill
#   the bar with the same relative effort.
const _HEIGHT_MULTS:          Array[float] = [0.91, 1.00, 1.09]
const _SIZE_WEIGHT_MULTS:     Array[float] = [0.88, 1.00, 1.12]
const _AGILITY_CARRY_MULTS:   Array[float] = [0.96, 1.00, 1.04]
const _AGILITY_GLIDE_MULTS:   Array[float] = [1.10, 1.00, 0.90]
const _STRENGTH_SHOT_MULTS:   Array[float] = [0.85, 1.00, 1.15]
const _STRENGTH_CHARGE_MULTS: Array[float] = [1.12, 1.00, 0.88]
const _SIZE_CHARGE_MULTS:     Array[float] = [0.91, 1.00, 1.09]

# Visual-only — drive `transform.scale` on body-chain mesh leaves and arm
# mesh radii. Wider than gameplay tables on purpose: the third-person
# hockey camera makes subtle differences hard to read, so silhouettes
# meaningfully differ between attribute extremes. Arm spread is widest
# (and asymmetric on the GOOD side) because "jacked" sells Strength at
# a glance.
const _TORSO_BULK_MULTS: Array[float] = [0.82, 1.00, 1.18]
const _HEAD_BULK_MULTS:  Array[float] = [0.92, 1.00, 1.08]
const _THIGH_MULTS:      Array[float] = [0.82, 1.00, 1.18]
const _CALF_MULTS:       Array[float] = [0.82, 1.00, 1.18]
const _ARM_BULK_MULTS:   Array[float] = [0.78, 1.00, 1.40]

# Used by multiplier_for() to look up the canonical table by Attribute enum.
const _CANONICAL_TABLES: Dictionary = {
	Attribute.SPEED:    _SPEED_MULTS,
	Attribute.AGILITY:  _AGILITY_MULTS,
	Attribute.SIZE:     _SIZE_MULTS,
	Attribute.STRENGTH: _STRENGTH_MULTS,
}

# ── State ────────────────────────────────────────────────────────────────────
var speed:    int = LEVEL_MEDIUM
var agility:  int = LEVEL_MEDIUM
var size:     int = LEVEL_MEDIUM
var strength: int = LEVEL_MEDIUM


func _init(p_speed: int = LEVEL_MEDIUM, p_agility: int = LEVEL_MEDIUM,
		p_size: int = LEVEL_MEDIUM, p_strength: int = LEVEL_MEDIUM) -> void:
	speed    = _clamp_level(p_speed)
	agility  = _clamp_level(p_agility)
	size     = _clamp_level(p_size)
	strength = _clamp_level(p_strength)


static func all_medium() -> PlayerAttributes:
	return PlayerAttributes.new()


# UX helper: strength + weakness picks → 3-2-2-1 spread. Picks are
# Attribute enum values; pass -1 (or any out-of-range int) for "no pick".
# If strength and weakness are the same attribute, weakness wins (the
# picker UI should prevent this, but be defensive).
static func from_strength_weakness(strength_pick: int, weakness_pick: int) -> PlayerAttributes:
	var levels: Array[int] = [LEVEL_MEDIUM, LEVEL_MEDIUM, LEVEL_MEDIUM, LEVEL_MEDIUM]
	if strength_pick >= 0 and strength_pick < levels.size():
		levels[strength_pick] = LEVEL_GOOD
	if weakness_pick >= 0 and weakness_pick < levels.size():
		levels[weakness_pick] = LEVEL_BAD
	return PlayerAttributes.new(levels[Attribute.SPEED], levels[Attribute.AGILITY],
			levels[Attribute.SIZE], levels[Attribute.STRENGTH])


# Whether a raw level tuple is reachable through the strength+weakness picker:
# every level in range, at most one GOOD, at most one BAD. The host validates
# joiner attributes with this — per-level clamping alone still admits forged
# spreads like 3/3/3/3 (+7% speed +10% agility +18% size +25% strength over
# everyone). Out-of-grammar spreads fall back to all_medium().
static func is_valid_spread(p_speed: int, p_agility: int, p_size: int, p_strength: int) -> bool:
	var goods: int = 0
	var bads: int = 0
	for level: int in [p_speed, p_agility, p_size, p_strength]:
		if level < LEVEL_MIN or level > LEVEL_MAX:
			return false
		if level == LEVEL_GOOD:
			goods += 1
		elif level == LEVEL_BAD:
			bads += 1
	return goods <= 1 and bads <= 1


func level_for(attr: int) -> int:
	match attr:
		Attribute.SPEED:    return speed
		Attribute.AGILITY:  return agility
		Attribute.SIZE:     return size
		Attribute.STRENGTH: return strength
	return LEVEL_MEDIUM


# ── Named multiplier accessors ───────────────────────────────────────────────
# Canonical gameplay
func speed_mult()    -> float: return _lookup(_SPEED_MULTS,    speed)
func agility_mult()  -> float: return _lookup(_AGILITY_MULTS,  agility)
func size_mult()     -> float: return _lookup(_SIZE_MULTS,     size)
func strength_mult() -> float: return _lookup(_STRENGTH_MULTS, strength)

# Specialized gameplay
func height_mult()          -> float: return _lookup(_HEIGHT_MULTS,          size)
func size_weight_mult()     -> float: return _lookup(_SIZE_WEIGHT_MULTS,     size)
func agility_carry_mult()   -> float: return _lookup(_AGILITY_CARRY_MULTS,   agility)
func agility_glide_mult()   -> float: return _lookup(_AGILITY_GLIDE_MULTS,   agility)
func strength_shot_mult()   -> float: return _lookup(_STRENGTH_SHOT_MULTS,   strength)
func strength_charge_mult() -> float: return _lookup(_STRENGTH_CHARGE_MULTS, strength)
func size_charge_mult()     -> float: return _lookup(_SIZE_CHARGE_MULTS,     size)

# Visual
func torso_bulk_mult() -> float: return _lookup(_TORSO_BULK_MULTS, size)
func head_bulk_mult()  -> float: return _lookup(_HEAD_BULK_MULTS,  size)
func thigh_mult()      -> float: return _lookup(_THIGH_MULTS,      speed)
func calf_mult()       -> float: return _lookup(_CALF_MULTS,       agility)
func arm_bulk_mult()   -> float: return _lookup(_ARM_BULK_MULTS,   strength)


# Generic accessor for the canonical-gameplay multipliers, parameterized
# by Attribute enum. Used by tests; new application code should prefer the
# named accessors above for readability at the call site.
func multiplier_for(attr: int) -> float:
	var table: Array = _CANONICAL_TABLES.get(attr, [])
	if table.is_empty():
		return 1.0
	return _lookup(table, level_for(attr))


# ── Serialization ────────────────────────────────────────────────────────────
func to_dict() -> Dictionary:
	return {"speed": speed, "agility": agility, "size": size, "strength": strength}


static func from_dict(d: Dictionary) -> PlayerAttributes:
	return PlayerAttributes.new(
			int(d.get("speed",    LEVEL_MEDIUM)),
			int(d.get("agility",  LEVEL_MEDIUM)),
			int(d.get("size",     LEVEL_MEDIUM)),
			int(d.get("strength", LEVEL_MEDIUM)))


func equals(other: PlayerAttributes) -> bool:
	if other == null:
		return false
	return speed == other.speed and agility == other.agility \
			and size == other.size and strength == other.strength


# ── Internal ─────────────────────────────────────────────────────────────────
static func _lookup(table: Array, level: int) -> float:
	return float(table[clampi(level - LEVEL_MIN, 0, table.size() - 1)])


static func _clamp_level(v: int) -> int:
	return clampi(v, LEVEL_MIN, LEVEL_MAX)
