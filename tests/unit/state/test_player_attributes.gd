extends GutTest

# PlayerAttributes — per-player gameplay attribute levels (Speed, Agility,
# Size, Skill). Storage is four ints on a 1..5 scale (3 = medium = baseline).
# Builds are point-buy, bounded by BUDGET; the slider picker hands levels in raw
# via from_levels(), and the host validates joiners with is_within_budget().

const ATTR_SPEED:   int = PlayerAttributes.Attribute.SPEED
const ATTR_AGILITY: int = PlayerAttributes.Attribute.AGILITY
const ATTR_SIZE:    int = PlayerAttributes.Attribute.SIZE
const ATTR_SKILL:   int = PlayerAttributes.Attribute.SKILL


func test_all_medium_defaults() -> void:
	var a := PlayerAttributes.all_medium()
	assert_eq(a.speed,   PlayerAttributes.LEVEL_MEDIUM)
	assert_eq(a.agility, PlayerAttributes.LEVEL_MEDIUM)
	assert_eq(a.size,    PlayerAttributes.LEVEL_MEDIUM)
	assert_eq(a.skill,   PlayerAttributes.LEVEL_MEDIUM)


func test_scale_is_one_to_five() -> void:
	assert_eq(PlayerAttributes.LEVEL_MIN,    1)
	assert_eq(PlayerAttributes.LEVEL_MEDIUM, 3)
	assert_eq(PlayerAttributes.LEVEL_MAX,    5)


func test_constructor_clamps_out_of_range() -> void:
	var low  := PlayerAttributes.new(-5, 0, 0, 0)
	var high := PlayerAttributes.new(99, 99, 99, 99)
	assert_eq(low.speed,  PlayerAttributes.LEVEL_MIN)
	assert_eq(high.skill, PlayerAttributes.LEVEL_MAX)


func test_medium_multipliers_are_one() -> void:
	var a := PlayerAttributes.all_medium()
	# Medium across every attribute must equal current shipped values, so a
	# fresh install plays identically to the pre-attributes baseline.
	assert_eq(a.multiplier_for(ATTR_SPEED),   1.0)
	assert_eq(a.multiplier_for(ATTR_AGILITY), 1.0)
	assert_eq(a.multiplier_for(ATTR_SIZE),    1.0)
	assert_eq(a.multiplier_for(ATTR_SKILL),   1.0)


func test_endpoints_preserved_from_three_step_scale() -> void:
	# The 5-step tables keep the old 3-step endpoints: new level 5 == old "good",
	# new level 1 == old "bad". Spot-check Speed (±7%) and Skill shot (±15%).
	var lo := PlayerAttributes.new(PlayerAttributes.LEVEL_MIN, PlayerAttributes.LEVEL_MIN,
			PlayerAttributes.LEVEL_MIN, PlayerAttributes.LEVEL_MIN)
	var hi := PlayerAttributes.new(PlayerAttributes.LEVEL_MAX, PlayerAttributes.LEVEL_MAX,
			PlayerAttributes.LEVEL_MAX, PlayerAttributes.LEVEL_MAX)
	assert_almost_eq(lo.speed_mult(),      0.93, 0.0001)
	assert_almost_eq(hi.speed_mult(),      1.07, 0.0001)
	assert_almost_eq(lo.skill_shot_mult(), 0.85, 0.0001)
	assert_almost_eq(hi.skill_shot_mult(), 1.15, 0.0001)


func test_intermediate_steps_monotonic() -> void:
	var prev: float = -1.0
	for level: int in range(PlayerAttributes.LEVEL_MIN, PlayerAttributes.LEVEL_MAX + 1):
		var a := PlayerAttributes.new(level, PlayerAttributes.LEVEL_MEDIUM,
				PlayerAttributes.LEVEL_MEDIUM, PlayerAttributes.LEVEL_MEDIUM)
		assert_gt(a.speed_mult(), prev, "speed_mult must strictly increase with level")
		prev = a.speed_mult()


func test_min_multipliers_below_one() -> void:
	var a := PlayerAttributes.new(PlayerAttributes.LEVEL_MIN, PlayerAttributes.LEVEL_MIN,
			PlayerAttributes.LEVEL_MIN, PlayerAttributes.LEVEL_MIN)
	assert_lt(a.multiplier_for(ATTR_SPEED),   1.0)
	assert_lt(a.multiplier_for(ATTR_AGILITY), 1.0)
	assert_lt(a.multiplier_for(ATTR_SIZE),    1.0)
	assert_lt(a.multiplier_for(ATTR_SKILL),   1.0)


func test_max_multipliers_above_one() -> void:
	var a := PlayerAttributes.new(PlayerAttributes.LEVEL_MAX, PlayerAttributes.LEVEL_MAX,
			PlayerAttributes.LEVEL_MAX, PlayerAttributes.LEVEL_MAX)
	assert_gt(a.multiplier_for(ATTR_SPEED),   1.0)
	assert_gt(a.multiplier_for(ATTR_AGILITY), 1.0)
	assert_gt(a.multiplier_for(ATTR_SIZE),    1.0)
	assert_gt(a.multiplier_for(ATTR_SKILL),   1.0)


func test_canonical_spreads_size_widest_speed_narrowest() -> void:
	var lo := PlayerAttributes.new(PlayerAttributes.LEVEL_MIN, PlayerAttributes.LEVEL_MIN,
			PlayerAttributes.LEVEL_MIN, PlayerAttributes.LEVEL_MIN)
	var hi := PlayerAttributes.new(PlayerAttributes.LEVEL_MAX, PlayerAttributes.LEVEL_MAX,
			PlayerAttributes.LEVEL_MAX, PlayerAttributes.LEVEL_MAX)
	var size_spread:  float = hi.multiplier_for(ATTR_SIZE)  - lo.multiplier_for(ATTR_SIZE)
	var skill_spread: float = hi.multiplier_for(ATTR_SKILL) - lo.multiplier_for(ATTR_SKILL)
	var speed_spread: float = hi.multiplier_for(ATTR_SPEED) - lo.multiplier_for(ATTR_SPEED)
	assert_gt(size_spread, skill_spread, "Size spread should be widest")
	assert_gt(skill_spread, speed_spread, "Speed spread should be narrowest")


func test_skill_blade_mult_scales() -> void:
	var lo := PlayerAttributes.new(2, 2, 2, PlayerAttributes.LEVEL_MIN)
	var med := PlayerAttributes.all_medium()
	var hi := PlayerAttributes.new(2, 2, 2, PlayerAttributes.LEVEL_MAX)
	assert_lt(lo.skill_blade_mult(), 1.0)
	assert_eq(med.skill_blade_mult(), 1.0)
	assert_gt(hi.skill_blade_mult(), 1.0)


func test_skill_charge_is_inverted() -> void:
	# Higher Skill = faster charge ramp = smaller multiplier.
	var lo := PlayerAttributes.new(2, 2, 2, PlayerAttributes.LEVEL_MIN)
	var hi := PlayerAttributes.new(2, 2, 2, PlayerAttributes.LEVEL_MAX)
	assert_gt(lo.skill_charge_mult(), hi.skill_charge_mult())


func test_height_identity_at_level_two() -> void:
	# Medium-Size is intentionally 6'0" (taller than the 1.78 m / 5'10" mesh), so
	# the height multiplier's 1.0 identity sits at level 2 (mesh-native height),
	# not level 3 — a documented exception to the medium=1.0 convention.
	var lvl2 := PlayerAttributes.new(2, 2, 2, 2)
	assert_almost_eq(lvl2.height_mult(), 1.0, 0.0001)
	assert_gt(PlayerAttributes.all_medium().height_mult(), 1.0, "medium Size is 6'0\", taller than the mesh")


func test_size_charge_tracks_height() -> void:
	# Charge cap must stay a constant fraction of reach/ROM, so size_charge_mult
	# is coupled 1:1 to height_mult. Lock it so the two can't silently drift.
	for level: int in range(PlayerAttributes.LEVEL_MIN, PlayerAttributes.LEVEL_MAX + 1):
		var a := PlayerAttributes.new(2, 2, level, 2)
		assert_almost_eq(a.size_charge_mult(), a.height_mult(), 0.0001,
				"size_charge must equal height at level %d" % level)


func test_stick_len_identity_at_level_two() -> void:
	# Stick shares height's L2-identity exception (its 1.0 sits at the mesh-native
	# 5'10", level 2), so medium-Size runs a slightly-longer-than-mesh stick.
	var lvl2 := PlayerAttributes.new(2, 2, 2, 2)
	assert_almost_eq(lvl2.stick_len_mult(), 1.0, 0.0001)
	assert_gt(PlayerAttributes.all_medium().stick_len_mult(), 1.0, "medium Size is 6'0\"")


func test_stick_len_gentler_than_height() -> void:
	# The stick is equipment, not anatomy, so it scales on a gentler curve than
	# height — every level's deviation from 1.0 is smaller than height's, and the
	# two stay on the same side of 1.0 (no inversion). Arms/ROM keep full height.
	for level: int in range(PlayerAttributes.LEVEL_MIN, PlayerAttributes.LEVEL_MAX + 1):
		var a := PlayerAttributes.new(2, 2, level, 2)
		var stick_dev: float = absf(a.stick_len_mult() - 1.0)
		var height_dev: float = absf(a.height_mult() - 1.0)
		assert_lte(stick_dev, height_dev,
				"stick deviation must not exceed height deviation at level %d" % level)
		if height_dev > 0.0001:
			assert_gt(stick_dev, 0.0,
					"stick should still vary with size at level %d" % level)
			# Same side of 1.0 as height (a taller player never gets a shorter stick).
			assert_gt((a.stick_len_mult() - 1.0) * (a.height_mult() - 1.0), 0.0,
					"stick and height must move together at level %d" % level)


func test_arm_bulk_keyed_to_size_not_skill() -> void:
	# The "jacked" silhouette follows physical frame (Size), not the invisible
	# Skill stat. A high-Size / low-Skill build should still have thick arms.
	var big_unskilled := PlayerAttributes.new(2, 2, PlayerAttributes.LEVEL_MAX, PlayerAttributes.LEVEL_MIN)
	var small_skilled := PlayerAttributes.new(2, 2, PlayerAttributes.LEVEL_MIN, PlayerAttributes.LEVEL_MAX)
	assert_gt(big_unskilled.arm_bulk_mult(), 1.0)
	assert_lt(small_skilled.arm_bulk_mult(), 1.0)


# ── from_levels / point-buy ──────────────────────────────────────────────────

func test_from_levels_direct() -> void:
	var a := PlayerAttributes.from_levels(5, 3, 3, 2)
	assert_eq(a.speed,   5)
	assert_eq(a.agility, 3)
	assert_eq(a.size,    3)
	assert_eq(a.skill,   2)


func test_total_spend() -> void:
	assert_eq(PlayerAttributes.all_medium().total_spend(), 12)
	assert_eq(PlayerAttributes.from_levels(5, 3, 3, 2).total_spend(), 13)


# ── is_within_budget (host-side join validation) ─────────────────────────────

func test_budget_constant() -> void:
	assert_eq(PlayerAttributes.BUDGET, 13)


func test_within_budget_all_medium() -> void:
	# 12 (under budget) — fresh/migrated builds must still pass, not get reset.
	assert_true(PlayerAttributes.is_within_budget(3, 3, 3, 3))


func test_within_budget_exact_spend() -> void:
	assert_true(PlayerAttributes.is_within_budget(4, 3, 3, 3), "one point above baseline")
	assert_true(PlayerAttributes.is_within_budget(5, 3, 3, 2), "max one stat, dip another")
	assert_true(PlayerAttributes.is_within_budget(5, 5, 2, 1), "double strength, double dip")


func test_within_budget_underspent_ok() -> void:
	# Self-nerf (under budget) is harmless and allowed; only over-budget cheats.
	assert_true(PlayerAttributes.is_within_budget(1, 1, 1, 1))


func test_over_budget_rejected() -> void:
	assert_false(PlayerAttributes.is_within_budget(5, 5, 5, 5), "20 points")
	assert_false(PlayerAttributes.is_within_budget(4, 4, 4, 4), "16 points")
	assert_false(PlayerAttributes.is_within_budget(5, 4, 3, 2), "14 points")


func test_out_of_range_rejected() -> void:
	assert_false(PlayerAttributes.is_within_budget(0, 3, 3, 3))
	assert_false(PlayerAttributes.is_within_budget(3, 3, 3, 6))


# ── serialization ────────────────────────────────────────────────────────────

func test_dict_roundtrip() -> void:
	var original := PlayerAttributes.from_levels(5, 1, 3, 4)
	var recovered := PlayerAttributes.from_dict(original.to_dict())
	assert_true(original.equals(recovered))


func test_to_dict_uses_skill_key() -> void:
	var d := PlayerAttributes.from_levels(2, 2, 2, 4).to_dict()
	assert_true(d.has("skill"))
	assert_eq(int(d["skill"]), 4)
	assert_false(d.has("strength"))


func test_from_dict_accepts_legacy_strength_key() -> void:
	var legacy := {"speed": 3, "agility": 3, "size": 3, "strength": 5}
	var a := PlayerAttributes.from_dict(legacy)
	assert_eq(a.skill, 5)


func test_equals_handles_null() -> void:
	assert_false(PlayerAttributes.all_medium().equals(null))


func test_level_for_each_attribute() -> void:
	var a := PlayerAttributes.from_levels(1, 3, 5, 2)
	assert_eq(a.level_for(ATTR_SPEED),   1)
	assert_eq(a.level_for(ATTR_AGILITY), 3)
	assert_eq(a.level_for(ATTR_SIZE),    5)
	assert_eq(a.level_for(ATTR_SKILL),   2)
