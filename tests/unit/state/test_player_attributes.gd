extends GutTest

# PlayerAttributes — per-player gameplay attribute levels (Speed, Agility,
# Hands, Size, Physical, Shot). Storage is six ints on a 1..5 scale (3 = medium
# = baseline). Builds are point-buy, bounded by BUDGET; the slider picker hands
# levels in raw via from_levels(), and the host validates joiners with
# is_within_budget(). Constructor / from_levels order is the Attribute enum
# order: Speed, Agility, Hands, Size, Physical, Shot.

const ATTR_SPEED:    int = PlayerAttributes.Attribute.SPEED
const ATTR_AGILITY:  int = PlayerAttributes.Attribute.AGILITY
const ATTR_HANDS:    int = PlayerAttributes.Attribute.HANDS
const ATTR_SIZE:     int = PlayerAttributes.Attribute.SIZE
const ATTR_PHYSICAL: int = PlayerAttributes.Attribute.PHYSICAL
const ATTR_SHOT:     int = PlayerAttributes.Attribute.SHOT


func test_all_medium_defaults() -> void:
	var a := PlayerAttributes.all_medium()
	assert_eq(a.speed,    PlayerAttributes.LEVEL_MEDIUM)
	assert_eq(a.agility,  PlayerAttributes.LEVEL_MEDIUM)
	assert_eq(a.hands,    PlayerAttributes.LEVEL_MEDIUM)
	assert_eq(a.size,     PlayerAttributes.LEVEL_MEDIUM)
	assert_eq(a.physical, PlayerAttributes.LEVEL_MEDIUM)
	assert_eq(a.shot,     PlayerAttributes.LEVEL_MEDIUM)


func test_scale_is_one_to_five() -> void:
	assert_eq(PlayerAttributes.LEVEL_MIN,    1)
	assert_eq(PlayerAttributes.LEVEL_MEDIUM, 3)
	assert_eq(PlayerAttributes.LEVEL_MAX,    5)


func test_constructor_clamps_out_of_range() -> void:
	var low  := PlayerAttributes.new(-5, 0, 0, 0, 0, 0)
	var high := PlayerAttributes.new(99, 99, 99, 99, 99, 99)
	assert_eq(low.speed, PlayerAttributes.LEVEL_MIN)
	assert_eq(high.shot, PlayerAttributes.LEVEL_MAX)


func test_medium_multipliers_are_one() -> void:
	var a := PlayerAttributes.all_medium()
	# Medium across every attribute must equal current shipped values, so a
	# fresh install plays identically to the pre-attributes baseline.
	assert_eq(a.multiplier_for(ATTR_SPEED),    1.0)
	assert_eq(a.multiplier_for(ATTR_AGILITY),  1.0)
	assert_eq(a.multiplier_for(ATTR_HANDS),    1.0)
	assert_eq(a.multiplier_for(ATTR_SIZE),     1.0)
	assert_eq(a.multiplier_for(ATTR_PHYSICAL), 1.0)
	assert_eq(a.multiplier_for(ATTR_SHOT),     1.0)


func test_endpoints_preserved_from_three_step_scale() -> void:
	# The 5-step tables keep the old 3-step endpoints: new level 5 == old "good",
	# new level 1 == old "bad". Spot-check Speed (±7%) and Shot power (±15%).
	var lo := _uniform(PlayerAttributes.LEVEL_MIN)
	var hi := _uniform(PlayerAttributes.LEVEL_MAX)
	assert_almost_eq(lo.speed_mult(),      0.93, 0.0001)
	assert_almost_eq(hi.speed_mult(),      1.07, 0.0001)
	assert_almost_eq(lo.shot_power_mult(), 0.85, 0.0001)
	assert_almost_eq(hi.shot_power_mult(), 1.15, 0.0001)


func test_intermediate_steps_monotonic() -> void:
	var prev: float = -1.0
	for level: int in range(PlayerAttributes.LEVEL_MIN, PlayerAttributes.LEVEL_MAX + 1):
		var a := PlayerAttributes.new(level, 2, 2, 2, 2, 2)
		assert_gt(a.speed_mult(), prev, "speed_mult must strictly increase with level")
		prev = a.speed_mult()


func test_min_multipliers_below_one() -> void:
	var a := _uniform(PlayerAttributes.LEVEL_MIN)
	assert_lt(a.multiplier_for(ATTR_SPEED),    1.0)
	assert_lt(a.multiplier_for(ATTR_AGILITY),  1.0)
	assert_lt(a.multiplier_for(ATTR_HANDS),    1.0)
	assert_lt(a.multiplier_for(ATTR_SIZE),     1.0)
	assert_lt(a.multiplier_for(ATTR_PHYSICAL), 1.0)
	assert_lt(a.multiplier_for(ATTR_SHOT),     1.0)


func test_max_multipliers_above_one() -> void:
	var a := _uniform(PlayerAttributes.LEVEL_MAX)
	assert_gt(a.multiplier_for(ATTR_SPEED),    1.0)
	assert_gt(a.multiplier_for(ATTR_AGILITY),  1.0)
	assert_gt(a.multiplier_for(ATTR_HANDS),    1.0)
	assert_gt(a.multiplier_for(ATTR_SIZE),     1.0)
	assert_gt(a.multiplier_for(ATTR_PHYSICAL), 1.0)
	assert_gt(a.multiplier_for(ATTR_SHOT),     1.0)


func test_canonical_spreads_physical_widest_speed_narrowest() -> void:
	var lo := _uniform(PlayerAttributes.LEVEL_MIN)
	var hi := _uniform(PlayerAttributes.LEVEL_MAX)
	var speed_spread: float    = hi.multiplier_for(ATTR_SPEED)    - lo.multiplier_for(ATTR_SPEED)
	var shot_spread: float     = hi.multiplier_for(ATTR_SHOT)     - lo.multiplier_for(ATTR_SHOT)
	var size_spread: float     = hi.multiplier_for(ATTR_SIZE)     - lo.multiplier_for(ATTR_SIZE)
	var physical_spread: float = hi.multiplier_for(ATTR_PHYSICAL) - lo.multiplier_for(ATTR_PHYSICAL)
	assert_gt(physical_spread, size_spread, "Physical (body-check) spread should be widest")
	assert_gt(size_spread, shot_spread, "Size spread wider than Shot")
	assert_gt(shot_spread, speed_spread, "Speed spread should be narrowest")


func test_hands_blade_mult_scales() -> void:
	var lo := PlayerAttributes.new(2, 2, PlayerAttributes.LEVEL_MIN, 2, 2, 2)
	var med := PlayerAttributes.all_medium()
	var hi := PlayerAttributes.new(2, 2, PlayerAttributes.LEVEL_MAX, 2, 2, 2)
	assert_lt(lo.hands_blade_mult(), 1.0)
	assert_eq(med.hands_blade_mult(), 1.0)
	assert_gt(hi.hands_blade_mult(), 1.0)


func test_hands_carry_widened_to_ten_percent() -> void:
	# Carry retention moved from Agility (trivial ±4%) to Hands and was widened to
	# a felt ±10% — "carries it like it's not even there".
	var lo := PlayerAttributes.new(2, 2, PlayerAttributes.LEVEL_MIN, 2, 2, 2)
	var hi := PlayerAttributes.new(2, 2, PlayerAttributes.LEVEL_MAX, 2, 2, 2)
	assert_almost_eq(lo.hands_carry_mult(), 0.90, 0.0001)
	assert_almost_eq(hi.hands_carry_mult(), 1.10, 0.0001)


func test_hands_backhand_scales_and_stays_under_forehand() -> void:
	# Hands un-penalizes the backhand, but a backhand must never beat a forehand:
	# with a base coefficient of 0.75, the L5 multiplier must stay below 1/0.75.
	var lo := PlayerAttributes.new(2, 2, PlayerAttributes.LEVEL_MIN, 2, 2, 2)
	var med := PlayerAttributes.all_medium()
	var hi := PlayerAttributes.new(2, 2, PlayerAttributes.LEVEL_MAX, 2, 2, 2)
	assert_lt(lo.hands_backhand_mult(), 1.0)
	assert_eq(med.hands_backhand_mult(), 1.0)
	assert_gt(hi.hands_backhand_mult(), 1.0)
	assert_lt(hi.hands_backhand_mult(), 1.0 / 0.75,
			"L5 backhand must not lift the 0.75 base coefficient to/above a forehand")


func test_shot_wrister_charge_wider_than_slapper_charge() -> void:
	# Both inverted (higher Shot = less effort), but the wrister drag-distance
	# spread is wider than the slapper wind-up spread.
	var lo := PlayerAttributes.new(2, 2, 2, 2, 2, PlayerAttributes.LEVEL_MIN)
	var hi := PlayerAttributes.new(2, 2, 2, 2, 2, PlayerAttributes.LEVEL_MAX)
	assert_gt(lo.shot_wrister_charge_mult(), hi.shot_wrister_charge_mult(), "wrister charge effort is inverted")
	var wrister_spread: float = lo.shot_wrister_charge_mult() - hi.shot_wrister_charge_mult()
	var slapper_spread: float = lo.shot_charge_mult() - hi.shot_charge_mult()
	assert_gt(wrister_spread, slapper_spread, "wrister charge effort spread wider than slapper")


func test_shot_charge_is_inverted() -> void:
	# Higher Shot = faster charge ramp = smaller multiplier (quick release).
	var lo := PlayerAttributes.new(2, 2, 2, 2, 2, PlayerAttributes.LEVEL_MIN)
	var hi := PlayerAttributes.new(2, 2, 2, 2, 2, PlayerAttributes.LEVEL_MAX)
	assert_gt(lo.shot_charge_mult(), hi.shot_charge_mult())


func test_physical_check_scales() -> void:
	var lo := PlayerAttributes.new(2, 2, 2, 2, PlayerAttributes.LEVEL_MIN, 2)
	var med := PlayerAttributes.all_medium()
	var hi := PlayerAttributes.new(2, 2, 2, 2, PlayerAttributes.LEVEL_MAX, 2)
	assert_lt(lo.physical_check_mult(), 1.0)
	assert_eq(med.physical_check_mult(), 1.0)
	assert_gt(hi.physical_check_mult(), 1.0)


func test_physical_brace_is_inverted() -> void:
	# Brace resistance is a coefficient on incoming transfer — lower = harder to
	# put down. Higher Physical yields the smaller (better) value.
	var lo := PlayerAttributes.new(2, 2, 2, 2, PlayerAttributes.LEVEL_MIN, 2)
	var hi := PlayerAttributes.new(2, 2, 2, 2, PlayerAttributes.LEVEL_MAX, 2)
	assert_gt(lo.physical_brace_mult(), hi.physical_brace_mult())


func test_physical_stamina_scales() -> void:
	var lo := PlayerAttributes.new(2, 2, 2, 2, PlayerAttributes.LEVEL_MIN, 2)
	var med := PlayerAttributes.all_medium()
	var hi := PlayerAttributes.new(2, 2, 2, 2, PlayerAttributes.LEVEL_MAX, 2)
	assert_lt(lo.physical_stamina_mult(), 1.0)
	assert_eq(med.physical_stamina_mult(), 1.0)
	assert_gt(hi.physical_stamina_mult(), 1.0)


func test_height_identity_at_level_two() -> void:
	# Medium-Size is intentionally 6'0" (taller than the 1.78 m / 5'10" mesh), so
	# the height multiplier's 1.0 identity sits at level 2 (mesh-native height),
	# not level 3 — a documented exception to the medium=1.0 convention.
	var lvl2 := PlayerAttributes.new(2, 2, 2, 2, 2, 2)
	assert_almost_eq(lvl2.height_mult(), 1.0, 0.0001)
	assert_gt(PlayerAttributes.all_medium().height_mult(), 1.0, "medium Size is 6'0\", taller than the mesh")


func test_size_charge_tracks_height() -> void:
	# Charge cap must stay a constant fraction of reach/ROM, so size_charge_mult
	# is coupled 1:1 to height_mult. Lock it so the two can't silently drift.
	for level: int in range(PlayerAttributes.LEVEL_MIN, PlayerAttributes.LEVEL_MAX + 1):
		var a := PlayerAttributes.new(2, 2, 2, level, 2, 2)
		assert_almost_eq(a.size_charge_mult(), a.height_mult(), 0.0001,
				"size_charge must equal height at level %d" % level)


func test_stick_len_identity_at_level_two() -> void:
	var lvl2 := PlayerAttributes.new(2, 2, 2, 2, 2, 2)
	assert_almost_eq(lvl2.stick_len_mult(), 1.0, 0.0001)
	assert_gt(PlayerAttributes.all_medium().stick_len_mult(), 1.0, "medium Size is 6'0\"")


func test_stick_len_gentler_than_height() -> void:
	for level: int in range(PlayerAttributes.LEVEL_MIN, PlayerAttributes.LEVEL_MAX + 1):
		var a := PlayerAttributes.new(2, 2, 2, level, 2, 2)
		var stick_dev: float = absf(a.stick_len_mult() - 1.0)
		var height_dev: float = absf(a.height_mult() - 1.0)
		assert_lte(stick_dev, height_dev,
				"stick deviation must not exceed height deviation at level %d" % level)
		if height_dev > 0.0001:
			assert_gt(stick_dev, 0.0, "stick should still vary with size at level %d" % level)
			assert_gt((a.stick_len_mult() - 1.0) * (a.height_mult() - 1.0), 0.0,
					"stick and height must move together at level %d" % level)


func test_forearm_bulk_keyed_to_hands() -> void:
	# Forearms are Hands' visual tell (the "hands" stat reads as thick forearms),
	# independent of physical frame (Size). A small high-Hands dangler has thick
	# forearms; a big low-Hands build has thin ones.
	var big_clumsy := PlayerAttributes.new(2, 2, PlayerAttributes.LEVEL_MIN, PlayerAttributes.LEVEL_MAX, 2, 2)
	var small_handsy := PlayerAttributes.new(2, 2, PlayerAttributes.LEVEL_MAX, PlayerAttributes.LEVEL_MIN, 2, 2)
	assert_lt(big_clumsy.forearm_bulk_mult(), 1.0)
	assert_gt(small_handsy.forearm_bulk_mult(), 1.0)


func test_upper_arm_bulk_keyed_to_shot() -> void:
	# Upper arms (biceps/triceps) are Shot's visual tell — the shooter's arms —
	# and are independent of Hands (forearms) so the two read separately.
	var soft_shot := PlayerAttributes.new(2, 2, 2, 2, 2, PlayerAttributes.LEVEL_MIN)
	var big_shot := PlayerAttributes.new(2, 2, 2, 2, 2, PlayerAttributes.LEVEL_MAX)
	assert_lt(soft_shot.upper_arm_bulk_mult(), 1.0)
	assert_gt(big_shot.upper_arm_bulk_mult(), 1.0)


func test_shoulder_bulk_keyed_to_physical_not_size() -> void:
	# Shoulders/yoke are Physical's visual tell, independent of Size. A small
	# grinder reads broad-shouldered; a big finesse build reads narrow.
	var small_strong := PlayerAttributes.new(2, 2, 2, PlayerAttributes.LEVEL_MIN, PlayerAttributes.LEVEL_MAX, 2)
	var big_soft := PlayerAttributes.new(2, 2, 2, PlayerAttributes.LEVEL_MAX, PlayerAttributes.LEVEL_MIN, 2)
	assert_gt(small_strong.shoulder_bulk_mult(), 1.0)
	assert_lt(big_soft.shoulder_bulk_mult(), 1.0)


# ── from_levels / point-buy ──────────────────────────────────────────────────

func test_from_levels_direct() -> void:
	var a := PlayerAttributes.from_levels(5, 3, 3, 2, 1, 4)
	assert_eq(a.speed,    5)
	assert_eq(a.agility,  3)
	assert_eq(a.hands,    3)
	assert_eq(a.size,     2)
	assert_eq(a.physical, 1)
	assert_eq(a.shot,     4)


func test_total_spend() -> void:
	assert_eq(PlayerAttributes.all_medium().total_spend(), 18)
	assert_eq(PlayerAttributes.from_levels(5, 3, 3, 2, 1, 4).total_spend(), 18)


# ── is_within_budget (host-side join validation) ─────────────────────────────

func test_budget_constant() -> void:
	assert_eq(PlayerAttributes.BUDGET, 18)


func test_within_budget_all_medium() -> void:
	# all-medium (3×6 = 18) is exactly the budget — the legal all-rounder.
	assert_true(PlayerAttributes.is_within_budget(3, 3, 3, 3, 3, 3))


func test_within_budget_exact_spend() -> void:
	assert_true(PlayerAttributes.is_within_budget(5, 3, 3, 3, 3, 1), "max one, dip another")
	assert_true(PlayerAttributes.is_within_budget(5, 5, 2, 2, 2, 2), "double spike, double dip")
	assert_true(PlayerAttributes.is_within_budget(1, 1, 5, 1, 5, 5), "triple max, triple floor")


func test_within_budget_underspent_ok() -> void:
	# Self-nerf (under budget) is harmless and allowed; only over-budget cheats.
	assert_true(PlayerAttributes.is_within_budget(1, 1, 1, 1, 1, 1))


func test_over_budget_rejected() -> void:
	assert_false(PlayerAttributes.is_within_budget(5, 5, 5, 5, 5, 5), "30 points")
	assert_false(PlayerAttributes.is_within_budget(4, 4, 4, 4, 4, 4), "24 points")
	assert_false(PlayerAttributes.is_within_budget(5, 4, 3, 3, 2, 2), "19 points, one over")


func test_out_of_range_rejected() -> void:
	assert_false(PlayerAttributes.is_within_budget(0, 3, 3, 3, 3, 3))
	assert_false(PlayerAttributes.is_within_budget(3, 3, 3, 3, 3, 6))


# ── serialization ────────────────────────────────────────────────────────────

func test_dict_roundtrip() -> void:
	var original := PlayerAttributes.from_levels(5, 1, 3, 4, 2, 3)
	var recovered := PlayerAttributes.from_dict(original.to_dict())
	assert_true(original.equals(recovered))


func test_to_dict_uses_six_keys() -> void:
	var d := PlayerAttributes.from_levels(2, 2, 4, 2, 2, 5).to_dict()
	assert_true(d.has("hands") and d.has("physical") and d.has("shot"))
	assert_eq(int(d["hands"]), 4)
	assert_eq(int(d["shot"]), 5)
	assert_false(d.has("skill"))
	assert_false(d.has("strength"))


func test_from_dict_splits_legacy_skill_into_hands_and_shot() -> void:
	# A four-attribute dict (old "skill" axis) seeds both offensive heirs.
	var legacy := {"speed": 3, "agility": 3, "size": 3, "skill": 5}
	var a := PlayerAttributes.from_dict(legacy)
	assert_eq(a.hands, 5)
	assert_eq(a.shot, 5)
	assert_eq(a.physical, PlayerAttributes.LEVEL_MEDIUM, "physical defaults to medium")


func test_from_dict_accepts_legacy_strength_key() -> void:
	var legacy := {"speed": 3, "agility": 3, "size": 3, "strength": 4}
	var a := PlayerAttributes.from_dict(legacy)
	assert_eq(a.shot, 4)
	assert_eq(a.hands, 4)


func test_equals_handles_null() -> void:
	assert_false(PlayerAttributes.all_medium().equals(null))


func test_level_for_each_attribute() -> void:
	var a := PlayerAttributes.from_levels(1, 2, 3, 4, 5, 1)
	assert_eq(a.level_for(ATTR_SPEED),    1)
	assert_eq(a.level_for(ATTR_AGILITY),  2)
	assert_eq(a.level_for(ATTR_HANDS),    3)
	assert_eq(a.level_for(ATTR_SIZE),     4)
	assert_eq(a.level_for(ATTR_PHYSICAL), 5)
	assert_eq(a.level_for(ATTR_SHOT),     1)


func _uniform(level: int) -> PlayerAttributes:
	return PlayerAttributes.new(level, level, level, level, level, level)
