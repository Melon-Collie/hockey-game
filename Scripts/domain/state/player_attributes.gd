class_name PlayerAttributes
extends RefCounted

# PlayerAttributes
# ----------------
# Per-skater tuning. Each player has four attributes (Speed, Agility, Size,
# Shot), each on a 3-step scale: 1=BAD, 2=MEDIUM, 3=GOOD. MEDIUM = baseline
# (multiplier 1.0 across the board), so an all-medium roster plays and looks
# identical to the shipped @export defaults.
#
# Every tuning multiplier in the attributes system lives in this file as a
# private const and is consumed via the named instance accessors below —
# never index a `_*_MULTS` table directly outside this file.
#
# To add a new "X scales Y" rule:
#   1. Add a `_FOO_MULTS: Array[float] = [BAD, MEDIUM, GOOD]` const. MEDIUM
#      should be 1.0; usually BAD < 1.0 < GOOD (or "inverted" if higher
#      attribute should yield a smaller value, like _SHOT_CHARGE_MULTS).
#   2. Add an accessor `func foo_mult() -> float` that returns
#      `_lookup(_FOO_MULTS, <relevant attribute field>)`.
#   3. In the consumer (SkaterController.apply_attributes or
#      SkaterAppearanceCoordinator.apply), multiply a captured base value by
#      `attrs.foo_mult()`.
#
# Why so many tables instead of one-per-attribute?  Different effects need
# different spreads:
#   - Body checks want a wide Size spread (×0.82 / 1.18) for hit feel
#   - Arm bulk wants an asymmetric Shot spread (×0.78 / 1.40) for "jacked"
#   - Charge speed wants Shot inverted (lower = faster, ×1.12 / 0.88)
#   - Carry retention wants a small Agility spread (×0.96 / 1.04)
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

enum Attribute { SPEED, AGILITY, SIZE, SHOT }

const LEVEL_BAD: int = 1
const LEVEL_MEDIUM: int = 2
const LEVEL_GOOD: int = 3
const LEVEL_MIN: int = LEVEL_BAD
const LEVEL_MAX: int = LEVEL_GOOD

# ── Tuning tables ────────────────────────────────────────────────────────────
# All multipliers indexed by (level - LEVEL_MIN): [BAD, MEDIUM, GOOD].

# Canonical gameplay (one per attribute) — applied to most stats by the
# matching controller fields. Size is widest because real-hockey mass
# differences are large; Speed/Shot stay tight so floor/ceiling values
# remain playable.
const _SPEED_MULTS:   Array[float] = [0.93, 1.00, 1.07]
const _AGILITY_MULTS: Array[float] = [0.90, 1.00, 1.10]
const _SIZE_MULTS:    Array[float] = [0.82, 1.00, 1.18]
const _SHOT_MULTS:    Array[float] = [0.92, 1.00, 1.08]

# Specialized gameplay — extra effects layered on top of the canonical
# multipliers above.
# HEIGHT: every "proportional to actual body height" measurement (arms,
#   stick, mesh Y-scale, hitbox height). Tighter than _SIZE_MULTS because
#   real height range is narrower than mass range.
# SHOT_CHARGE: inverted (lower = faster ramp to max power). Wider than the
#   power spread so shooters meaningfully threaten at close range.
# AGILITY_CARRY: small modest boost — agile dekers retain more puck speed.
# AGILITY_GLIDE: inverted (lower = less drag during cuts). Agile skaters
#   leak less momentum through their edges, so they carry more speed out
#   of turns and crossovers — the "good edges" feel.
const _HEIGHT_MULTS:        Array[float] = [0.91, 1.00, 1.09]
const _SHOT_CHARGE_MULTS:   Array[float] = [1.12, 1.00, 0.88]
const _AGILITY_CARRY_MULTS: Array[float] = [0.96, 1.00, 1.04]
const _AGILITY_GLIDE_MULTS: Array[float] = [1.10, 1.00, 0.90]

# Visual-only — drive `transform.scale` on body-chain mesh leaves and arm
# mesh radii. Wider than gameplay tables on purpose: the third-person
# hockey camera makes subtle differences hard to read, so silhouettes
# meaningfully differ between attribute extremes. Arm spread is the widest
# (and asymmetric on the GOOD side) because "jacked" sells Shot at a glance.
const _TORSO_BULK_MULTS: Array[float] = [0.82, 1.00, 1.18]
const _HEAD_BULK_MULTS:  Array[float] = [0.92, 1.00, 1.08]
const _THIGH_MULTS:      Array[float] = [0.82, 1.00, 1.18]
const _CALF_MULTS:       Array[float] = [0.82, 1.00, 1.18]
const _ARM_BULK_MULTS:   Array[float] = [0.78, 1.00, 1.40]

# Used by multiplier_for() to look up the canonical table by Attribute enum.
const _CANONICAL_TABLES: Dictionary = {
	Attribute.SPEED:   _SPEED_MULTS,
	Attribute.AGILITY: _AGILITY_MULTS,
	Attribute.SIZE:    _SIZE_MULTS,
	Attribute.SHOT:    _SHOT_MULTS,
}

# ── State ────────────────────────────────────────────────────────────────────
var speed:   int = LEVEL_MEDIUM
var agility: int = LEVEL_MEDIUM
var size:    int = LEVEL_MEDIUM
var shot:    int = LEVEL_MEDIUM


func _init(p_speed: int = LEVEL_MEDIUM, p_agility: int = LEVEL_MEDIUM,
		p_size: int = LEVEL_MEDIUM, p_shot: int = LEVEL_MEDIUM) -> void:
	speed   = _clamp_level(p_speed)
	agility = _clamp_level(p_agility)
	size    = _clamp_level(p_size)
	shot    = _clamp_level(p_shot)


static func all_medium() -> PlayerAttributes:
	return PlayerAttributes.new()


# UX helper: strength + weakness picks → 3-2-2-1 spread. Picks are
# Attribute enum values; pass -1 (or any out-of-range int) for "no pick".
# If strength and weakness are the same attribute, weakness wins (the
# picker UI should prevent this, but be defensive).
static func from_strength_weakness(strength: int, weakness: int) -> PlayerAttributes:
	var levels: Array[int] = [LEVEL_MEDIUM, LEVEL_MEDIUM, LEVEL_MEDIUM, LEVEL_MEDIUM]
	if strength >= 0 and strength < levels.size():
		levels[strength] = LEVEL_GOOD
	if weakness >= 0 and weakness < levels.size():
		levels[weakness] = LEVEL_BAD
	return PlayerAttributes.new(levels[Attribute.SPEED], levels[Attribute.AGILITY],
			levels[Attribute.SIZE], levels[Attribute.SHOT])


func level_for(attr: int) -> int:
	match attr:
		Attribute.SPEED:   return speed
		Attribute.AGILITY: return agility
		Attribute.SIZE:    return size
		Attribute.SHOT:    return shot
	return LEVEL_MEDIUM


# ── Named multiplier accessors ───────────────────────────────────────────────
# Canonical gameplay
func speed_mult()   -> float: return _lookup(_SPEED_MULTS,   speed)
func agility_mult() -> float: return _lookup(_AGILITY_MULTS, agility)
func size_mult()    -> float: return _lookup(_SIZE_MULTS,    size)
func shot_mult()    -> float: return _lookup(_SHOT_MULTS,    shot)

# Specialized gameplay
func height_mult()        -> float: return _lookup(_HEIGHT_MULTS,        size)
func shot_charge_mult()   -> float: return _lookup(_SHOT_CHARGE_MULTS,   shot)
func agility_carry_mult() -> float: return _lookup(_AGILITY_CARRY_MULTS, agility)
func agility_glide_mult() -> float: return _lookup(_AGILITY_GLIDE_MULTS, agility)

# Visual
func torso_bulk_mult() -> float: return _lookup(_TORSO_BULK_MULTS, size)
func head_bulk_mult()  -> float: return _lookup(_HEAD_BULK_MULTS,  size)
func thigh_mult()      -> float: return _lookup(_THIGH_MULTS,      speed)
func calf_mult()       -> float: return _lookup(_CALF_MULTS,       agility)
func arm_bulk_mult()   -> float: return _lookup(_ARM_BULK_MULTS,   shot)


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
	return {"speed": speed, "agility": agility, "size": size, "shot": shot}


static func from_dict(d: Dictionary) -> PlayerAttributes:
	return PlayerAttributes.new(
			int(d.get("speed", LEVEL_MEDIUM)),
			int(d.get("agility", LEVEL_MEDIUM)),
			int(d.get("size", LEVEL_MEDIUM)),
			int(d.get("shot", LEVEL_MEDIUM)))


func equals(other: PlayerAttributes) -> bool:
	if other == null:
		return false
	return speed == other.speed and agility == other.agility \
			and size == other.size and shot == other.shot


# ── Internal ─────────────────────────────────────────────────────────────────
static func _lookup(table: Array, level: int) -> float:
	return float(table[clampi(level - LEVEL_MIN, 0, table.size() - 1)])


static func _clamp_level(v: int) -> int:
	return clampi(v, LEVEL_MIN, LEVEL_MAX)
