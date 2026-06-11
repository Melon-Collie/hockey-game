extends GutTest

# PlayerAttributes — per-player gameplay attribute levels (Speed, Agility,
# Size, Strength). Storage is four ints (1 = bad, 2 = medium, 3 = good); a
# strength/weakness helper produces the 3-2-2-1 spread for the picker UI.

const ATTR_SPEED:    int = PlayerAttributes.Attribute.SPEED
const ATTR_AGILITY:  int = PlayerAttributes.Attribute.AGILITY
const ATTR_SIZE:     int = PlayerAttributes.Attribute.SIZE
const ATTR_STRENGTH: int = PlayerAttributes.Attribute.STRENGTH


func test_all_medium_defaults() -> void:
	var a := PlayerAttributes.all_medium()
	assert_eq(a.speed,    PlayerAttributes.LEVEL_MEDIUM)
	assert_eq(a.agility,  PlayerAttributes.LEVEL_MEDIUM)
	assert_eq(a.size,     PlayerAttributes.LEVEL_MEDIUM)
	assert_eq(a.strength, PlayerAttributes.LEVEL_MEDIUM)


func test_constructor_clamps_out_of_range() -> void:
	var low  := PlayerAttributes.new(-5, 0, 0, 0)
	var high := PlayerAttributes.new(99, 99, 99, 99)
	assert_eq(low.speed,     PlayerAttributes.LEVEL_BAD)
	assert_eq(high.strength, PlayerAttributes.LEVEL_GOOD)


func test_medium_multipliers_are_one() -> void:
	var a := PlayerAttributes.all_medium()
	# Medium across every attribute must equal current shipped values, so a
	# fresh install plays identically to the pre-attributes baseline.
	assert_eq(a.multiplier_for(ATTR_SPEED),    1.0)
	assert_eq(a.multiplier_for(ATTR_AGILITY),  1.0)
	assert_eq(a.multiplier_for(ATTR_SIZE),     1.0)
	assert_eq(a.multiplier_for(ATTR_STRENGTH), 1.0)


func test_bad_multipliers_below_one() -> void:
	var a := PlayerAttributes.new(
			PlayerAttributes.LEVEL_BAD, PlayerAttributes.LEVEL_BAD,
			PlayerAttributes.LEVEL_BAD, PlayerAttributes.LEVEL_BAD)
	assert_lt(a.multiplier_for(ATTR_SPEED),    1.0)
	assert_lt(a.multiplier_for(ATTR_AGILITY),  1.0)
	assert_lt(a.multiplier_for(ATTR_SIZE),     1.0)
	assert_lt(a.multiplier_for(ATTR_STRENGTH), 1.0)


func test_good_multipliers_above_one() -> void:
	var a := PlayerAttributes.new(
			PlayerAttributes.LEVEL_GOOD, PlayerAttributes.LEVEL_GOOD,
			PlayerAttributes.LEVEL_GOOD, PlayerAttributes.LEVEL_GOOD)
	assert_gt(a.multiplier_for(ATTR_SPEED),    1.0)
	assert_gt(a.multiplier_for(ATTR_AGILITY),  1.0)
	assert_gt(a.multiplier_for(ATTR_SIZE),     1.0)
	assert_gt(a.multiplier_for(ATTR_STRENGTH), 1.0)


func test_strength_spread_widest() -> void:
	# Strength drives body-check delivery; its spread must outweigh Size's
	# weight-ratio in the check formula, so it's the widest canonical table.
	var bad := PlayerAttributes.new(
			PlayerAttributes.LEVEL_BAD, PlayerAttributes.LEVEL_BAD,
			PlayerAttributes.LEVEL_BAD, PlayerAttributes.LEVEL_BAD)
	var good := PlayerAttributes.new(
			PlayerAttributes.LEVEL_GOOD, PlayerAttributes.LEVEL_GOOD,
			PlayerAttributes.LEVEL_GOOD, PlayerAttributes.LEVEL_GOOD)
	var strength_spread: float = good.multiplier_for(ATTR_STRENGTH) - bad.multiplier_for(ATTR_STRENGTH)
	var size_spread:     float = good.multiplier_for(ATTR_SIZE)     - bad.multiplier_for(ATTR_SIZE)
	var speed_spread:    float = good.multiplier_for(ATTR_SPEED)    - bad.multiplier_for(ATTR_SPEED)
	assert_gt(strength_spread, size_spread)
	assert_gt(size_spread, speed_spread)


func test_strength_weakness_produces_three_two_two_one() -> void:
	var a := PlayerAttributes.from_strength_weakness(ATTR_SPEED, ATTR_SIZE)
	assert_eq(a.speed,    PlayerAttributes.LEVEL_GOOD)
	assert_eq(a.size,     PlayerAttributes.LEVEL_BAD)
	assert_eq(a.agility,  PlayerAttributes.LEVEL_MEDIUM)
	assert_eq(a.strength, PlayerAttributes.LEVEL_MEDIUM)


func test_strength_weakness_no_picks_yields_all_medium() -> void:
	var a := PlayerAttributes.from_strength_weakness(-1, -1)
	assert_true(a.equals(PlayerAttributes.all_medium()))


func test_strength_weakness_only_strength_pick() -> void:
	var a := PlayerAttributes.from_strength_weakness(ATTR_STRENGTH, -1)
	assert_eq(a.strength, PlayerAttributes.LEVEL_GOOD)
	assert_eq(a.speed,    PlayerAttributes.LEVEL_MEDIUM)
	assert_eq(a.agility,  PlayerAttributes.LEVEL_MEDIUM)
	assert_eq(a.size,     PlayerAttributes.LEVEL_MEDIUM)


func test_dict_roundtrip() -> void:
	var original := PlayerAttributes.new(
			PlayerAttributes.LEVEL_GOOD, PlayerAttributes.LEVEL_BAD,
			PlayerAttributes.LEVEL_MEDIUM, PlayerAttributes.LEVEL_GOOD)
	var recovered := PlayerAttributes.from_dict(original.to_dict())
	assert_true(original.equals(recovered))


func test_equals_handles_null() -> void:
	var a := PlayerAttributes.all_medium()
	assert_false(a.equals(null))


func test_level_for_each_attribute() -> void:
	var a := PlayerAttributes.new(
			PlayerAttributes.LEVEL_BAD, PlayerAttributes.LEVEL_MEDIUM,
			PlayerAttributes.LEVEL_GOOD, PlayerAttributes.LEVEL_BAD)
	assert_eq(a.level_for(ATTR_SPEED),    PlayerAttributes.LEVEL_BAD)
	assert_eq(a.level_for(ATTR_AGILITY),  PlayerAttributes.LEVEL_MEDIUM)
	assert_eq(a.level_for(ATTR_SIZE),     PlayerAttributes.LEVEL_GOOD)
	assert_eq(a.level_for(ATTR_STRENGTH), PlayerAttributes.LEVEL_BAD)


# ── is_valid_spread (host-side join validation) ──────────────────────────────

func test_valid_spread_all_medium() -> void:
	assert_true(PlayerAttributes.is_valid_spread(2, 2, 2, 2))


func test_valid_spread_strength_and_weakness() -> void:
	assert_true(PlayerAttributes.is_valid_spread(3, 2, 2, 1))


func test_valid_spread_single_pick_only() -> void:
	assert_true(PlayerAttributes.is_valid_spread(3, 2, 2, 2), "strength without weakness")
	assert_true(PlayerAttributes.is_valid_spread(2, 1, 2, 2), "weakness without strength")


func test_invalid_spread_forged_all_good() -> void:
	assert_false(PlayerAttributes.is_valid_spread(3, 3, 3, 3))


func test_invalid_spread_two_goods() -> void:
	assert_false(PlayerAttributes.is_valid_spread(3, 3, 2, 1))


func test_invalid_spread_two_bads() -> void:
	assert_false(PlayerAttributes.is_valid_spread(3, 1, 1, 2))


func test_invalid_spread_out_of_range_levels() -> void:
	assert_false(PlayerAttributes.is_valid_spread(0, 2, 2, 2))
	assert_false(PlayerAttributes.is_valid_spread(2, 2, 2, 4))
