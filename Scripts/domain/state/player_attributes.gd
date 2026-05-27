class_name PlayerAttributes
extends RefCounted

# Per-player gameplay attribute levels — Speed, Agility, Size, Shot.
# Storage is always four discrete levels (1 = bad, 2 = medium, 3 = good).
# The UX layer can expose these however it likes (strength/weakness picks,
# free allocation, etc.) — only the four levels persist.
#
# `multiplier_for(attr)` looks up the gameplay-tuning multiplier consumers
# (SkaterController, Skater body-check fields) apply to their base values.

enum Attribute { SPEED, AGILITY, SIZE, SHOT }

const LEVEL_BAD: int = 1
const LEVEL_MEDIUM: int = 2
const LEVEL_GOOD: int = 3
const LEVEL_MIN: int = LEVEL_BAD
const LEVEL_MAX: int = LEVEL_GOOD

# Multiplier curve per attribute. Indexed [level - LEVEL_MIN]. Different
# attributes get different spreads — Size has the widest range because real
# hockey mass differences are large; Speed/Shot stay tighter so floor/ceiling
# values remain playable.
const _MULTIPLIERS: Dictionary = {
	Attribute.SPEED:   [0.93, 1.00, 1.07],
	Attribute.AGILITY: [0.90, 1.00, 1.10],
	Attribute.SIZE:    [0.82, 1.00, 1.18],
	Attribute.SHOT:    [0.92, 1.00, 1.08],
}

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


func multiplier_for(attr: int) -> float:
	var table: Array = _MULTIPLIERS.get(attr, [])
	if table.is_empty():
		return 1.0
	var idx: int = clampi(level_for(attr) - LEVEL_MIN, 0, table.size() - 1)
	return float(table[idx])


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


static func _clamp_level(v: int) -> int:
	return clampi(v, LEVEL_MIN, LEVEL_MAX)
