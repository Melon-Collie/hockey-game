extends GutTest

# PlayerAttributes — HEIGHT-ROUTED model. A build is a free 5-step HEIGHT (H1 5'8"
# … H5 6'7") plus three TIERS (Skating / Skill / Checking, each weak/avg/strong).
# Height decides the baselines and how each tier's investment lands on the concrete
# levers (max_speed, thrust, agility, blade, shot, delivery, brace, …). Neutral is
# H3 (6'1") + all-average, where every canonical multiplier is 1.0.
#
# This test is the executable spec for the tables authored in player_attributes.gd.

const H1: int = PlayerAttributes.HEIGHT_MIN     # 5'8" (68")
const H3: int = PlayerAttributes.HEIGHT_MEDIUM  # 6'1" (73")
const H5: int = PlayerAttributes.HEIGHT_MAX     # 6'7" (79")
const WEAK: int = PlayerAttributes.TIER_WEAK
const AVG: int = PlayerAttributes.TIER_AVERAGE
const STRONG: int = PlayerAttributes.TIER_STRONG

const BASE_MAX_SPEED: float = 9.0  # GameRules.DEFAULT_SKATER_MAX_SPEED_M_S
const MS_TO_MPH: float = 2.23694


func _build(h: int, sk: int, sl: int, ch: int) -> PlayerAttributes:
	return PlayerAttributes.from_levels(h, sk, sl, ch)


# ── Neutral / structure ───────────────────────────────────────────────────────
func test_neutral_is_all_ones() -> void:
	var a := PlayerAttributes.all_average()
	assert_eq(a.height, H3)
	assert_eq(a.skating, AVG)
	# H3 + all-average must equal the shipped @export baseline everywhere.
	assert_almost_eq(a.speed_mult(), 1.0, 0.0001, "speed")
	assert_almost_eq(a.accel_mult(), 1.0, 0.0001, "accel")
	assert_almost_eq(a.agility_mult(), 1.0, 0.0001, "agility")
	assert_almost_eq(a.hands_blade_mult(), 1.0, 0.0001, "hands")
	assert_almost_eq(a.shot_power_mult(), 1.0, 0.0001, "shot")
	assert_almost_eq(a.check_delivery_mult(), 1.0, 0.0001, "delivery")
	assert_almost_eq(a.brace_mult(), 1.0, 0.0001, "brace")
	assert_almost_eq(a.mass_mult(), 1.0, 0.0001, "mass")
	assert_almost_eq(a.stamina_drain_mult(), 1.0, 0.0001, "drain")
	assert_almost_eq(a.stamina_regen_mult(), 1.0, 0.0001, "regen")


func test_scale_constants() -> void:
	# Height is stored in inches now: 5'8" .. 6'7", neutral 6'1".
	assert_eq(PlayerAttributes.HEIGHT_MIN, 68)
	assert_eq(PlayerAttributes.HEIGHT_MEDIUM, 73)
	assert_eq(PlayerAttributes.HEIGHT_MAX, 79)
	assert_eq(PlayerAttributes.TIER_WEAK, 1)
	assert_eq(PlayerAttributes.TIER_AVERAGE, 2)
	assert_eq(PlayerAttributes.TIER_STRONG, 3)


func test_constructor_clamps_and_coerces() -> void:
	var low := PlayerAttributes.new(-9, -9, -9, -9)
	var high := PlayerAttributes.new(999, 99, 99, 99)
	assert_eq(low.height, PlayerAttributes.HEIGHT_MIN)
	assert_eq(low.skating, PlayerAttributes.TIER_WEAK)
	assert_eq(high.height, PlayerAttributes.HEIGHT_MAX)
	assert_eq(high.checking, PlayerAttributes.TIER_STRONG)


func test_legacy_1to5_height_maps_to_anchor_inches() -> void:
	# A legacy 1..5 step (old prefs / bot rosters) maps onto the anchor heights.
	assert_eq(PlayerAttributes.new(1, AVG, AVG, AVG).height, 68)  # 5'8"
	assert_eq(PlayerAttributes.new(2, AVG, AVG, AVG).height, 70)  # 5'10"
	assert_eq(PlayerAttributes.new(3, AVG, AVG, AVG).height, 73)  # 6'1"
	assert_eq(PlayerAttributes.new(5, AVG, AVG, AVG).height, 79)  # 6'7"


func test_height_inches_and_label() -> void:
	assert_eq(_build(H1, AVG, AVG, AVG).height_inches(), 68)
	assert_eq(_build(70, AVG, AVG, AVG).height_inches(), 70)   # an in-between inch
	assert_eq(_build(H5, AVG, AVG, AVG).height_inches(), 79)
	assert_eq(PlayerAttributes.inches_label(73), "6'1\"")
	assert_eq(PlayerAttributes.inches_label(68), "5'8\"")


func test_continuous_height_interpolates_between_anchors() -> void:
	# 71" sits between the 70" and 73" rows; its multiplier is the lerp of the two.
	var lo := _build(70, AVG, AVG, AVG).agility_mult()
	var hi := _build(73, AVG, AVG, AVG).agility_mult()
	var mid := _build(71, AVG, AVG, AVG).agility_mult()
	assert_true(mid < lo and mid > hi, "71\" agility falls between the 70\" and 73\" rows")
	assert_almost_eq(mid, lerpf(lo, hi, 1.0 / 3.0), 0.0001, "linear between anchors")


# ── Skating: speed hump, agility slope, acceleration floor ─────────────────────
func test_speed_peaks_at_medium_height() -> void:
	# At equal (average) skating, top speed humps at medium height; small == big.
	var small := _build(H1, AVG, AVG, AVG).speed_mult()
	var med := _build(H3, AVG, AVG, AVG).speed_mult()
	var big := _build(H5, AVG, AVG, AVG).speed_mult()
	assert_true(med > small, "medium faster than small at avg skating")
	assert_true(med > big, "medium faster than big at avg skating")
	assert_almost_eq(small, big, 0.01, "small and big tie on top speed")


func test_fastest_build_is_medium_strong_skating() -> void:
	var fastest := _build(H3, STRONG, AVG, AVG).speed_mult()
	# No other (height, skating) speed cell beats medium+strong.
	for h: int in range(1, 6):
		for sk: int in [WEAK, AVG, STRONG]:
			assert_true(_build(h, sk, AVG, AVG).speed_mult() <= fastest + 0.0001,
					"H%d skating%d speed <= fastest" % [h, sk])


func test_agility_small_favored_bounded() -> void:
	# Ceiling: small strong-skating ≈ old L5 (1.11), the old "superpower", not beyond.
	assert_almost_eq(_build(H1, STRONG, AVG, AVG).agility_mult(), 1.11, 0.001)
	# Floor: big weak-skating bottoms at ~old L1 (0.90) — "feels bad but playable".
	assert_almost_eq(_build(H5, WEAK, AVG, AVG).agility_mult(), 0.90, 0.001)
	# Monotonic small→big at each fixed tier.
	assert_true(_build(H1, AVG, AVG, AVG).agility_mult() > _build(H5, AVG, AVG, AVG).agility_mult())


func test_acceleration_floored_above_agility() -> void:
	# The whole point of splitting accel off agility: a big weak-skater can still
	# push north-south. His acceleration floor sits ABOVE his agility floor.
	var bad_big := _build(H5, WEAK, AVG, AVG)
	assert_true(bad_big.accel_mult() > bad_big.agility_mult(),
			"big weak-skater accel (%.3f) > agility (%.3f)" % [bad_big.accel_mult(), bad_big.agility_mult()])
	assert_true(bad_big.accel_mult() >= 0.94, "accel floor stays ~old-L2, not L1")
	# Acceleration is small-favored at the baseline.
	assert_true(_build(H1, AVG, AVG, AVG).accel_mult() > _build(H5, AVG, AVG, AVG).accel_mult())


# ── Skill: hands small-favored, shot big-favored + NHL-anchored ────────────────
func test_hands_small_favored() -> void:
	assert_true(_build(H1, AVG, STRONG, AVG).hands_blade_mult()
			> _build(H5, AVG, STRONG, AVG).hands_blade_mult())
	# Elite dangler ceiling.
	assert_almost_eq(_build(H1, AVG, STRONG, AVG).hands_blade_mult(), 1.24, 0.001)


func test_shot_big_favored_and_nhl_anchored() -> void:
	# Big-favored at equal tier.
	assert_true(_build(H5, AVG, STRONG, AVG).shot_power_mult()
			> _build(H1, AVG, STRONG, AVG).shot_power_mult())
	# Anchor: the hardest shot in the game (6'7" strong Skill) ≈ 107 mph slapper.
	var top_slapper_ms: float = 40.0 * _build(H5, AVG, STRONG, AVG).shot_power_mult()
	assert_between(top_slapper_ms * MS_TO_MPH, 105.0, 109.0)
	# League average = neutral.
	assert_almost_eq(40.0 * _build(H3, AVG, AVG, AVG).shot_power_mult() * MS_TO_MPH, 89.5, 1.0)


func test_skill_is_a_fork_not_both() -> void:
	# One strong-Skill tier drives BOTH hands and shot per height: small = elite
	# hands + soft shot (dangler); big = bomber + clumsy hands (shooter).
	var small_skill := _build(H1, AVG, STRONG, AVG)
	var big_skill := _build(H5, AVG, STRONG, AVG)
	assert_true(small_skill.hands_blade_mult() > small_skill.shot_power_mult(), "small: hands>shot")
	assert_true(big_skill.shot_power_mult() > big_skill.hands_blade_mult(), "big: shot>hands")


# ── Checking: delivery big-favored, brace tier-dominant ────────────────────────
func test_delivery_big_favored_tier_scaled() -> void:
	# The freight train: 6'7" strong Checking is the max delivery in the game.
	var strong_big := _build(H5, AVG, AVG, STRONG).check_delivery_mult()
	assert_almost_eq(strong_big, 1.36, 0.001)
	# A big body that NEGLECTS checking hits below-average — nothing physical free.
	assert_true(_build(H5, AVG, AVG, WEAK).check_delivery_mult() < 1.0,
			"big weak-checking delivers below neutral")


func test_brace_tier_dominant_big_is_hittable() -> void:
	# Brace lower = harder to knock off the puck. A big weak-Checking build is the
	# most hittable (highest brace); a small strong-Checking build is untouchable.
	var big_weak := _build(H5, AVG, AVG, WEAK).brace_mult()
	var small_strong := _build(H1, AVG, AVG, STRONG).brace_mult()
	assert_true(big_weak > 1.0, "big weak-checking is hittable (brace %.2f)" % big_weak)
	assert_almost_eq(small_strong, 0.76, 0.001)
	# Tier moves brace more than height does (tier-dominant): the weak→strong swing
	# at fixed height exceeds the small→big swing at fixed tier.
	var tier_swing: float = _build(H3, AVG, AVG, WEAK).brace_mult() - _build(H3, AVG, AVG, STRONG).brace_mult()
	var height_swing: float = _build(H5, AVG, AVG, AVG).brace_mult() - _build(H1, AVG, AVG, AVG).brace_mult()
	assert_true(tier_swing > height_swing, "checking tier dominates height for brace")


# ── Height-only: mass minor, stamina metabolism ───────────────────────────────
func test_mass_is_minor() -> void:
	# ~1.16x heaviest-to-lightest — a small head start, not a wall.
	var ratio: float = _build(H5, AVG, AVG, AVG).mass_mult() / _build(H1, AVG, AVG, AVG).mass_mult()
	assert_between(ratio, 1.1, 1.25)


func test_stamina_metabolism_by_height() -> void:
	# Small = fast metabolism (drains AND regens faster); big = deep pool, slow refill.
	var small := _build(H1, AVG, AVG, AVG)
	var big := _build(H5, AVG, AVG, AVG)
	assert_true(small.stamina_drain_mult() > big.stamina_drain_mult(), "small drains faster")
	assert_true(small.stamina_regen_mult() > big.stamina_regen_mult(), "small recovers faster")


# ── Derived (coupled) levers ──────────────────────────────────────────────────
func test_glide_and_charge_are_inverse_of_partner() -> void:
	var a := _build(H1, STRONG, STRONG, AVG)
	assert_almost_eq(a.agility_glide_mult(), 2.0 - a.agility_mult(), 0.0001)
	assert_almost_eq(a.shot_charge_mult(), 2.0 - a.shot_power_mult(), 0.0001)


# ── Sprint ceiling (grounded 20–25 mph) ───────────────────────────────────────
func test_sprint_ceiling_speed_attributed_and_grounded() -> void:
	var fastest := _build(H3, STRONG, AVG, AVG)   # top speed build
	var slowest := _build(H5, WEAK, AVG, AVG)     # bad big skater
	assert_true(fastest.sprint_ceiling_mult() > slowest.sprint_ceiling_mult())
	# Fastest sprint tops ~25 mph (Wood/McDavid ceiling), slowest ~20 mph.
	var fast_top: float = BASE_MAX_SPEED * fastest.speed_mult() * fastest.sprint_ceiling_mult()
	var slow_top: float = BASE_MAX_SPEED * slowest.speed_mult() * slowest.sprint_ceiling_mult()
	assert_between(fast_top * MS_TO_MPH, 23.5, 25.5, "fastest sprint ≈ 25 mph")
	assert_between(slow_top * MS_TO_MPH, 19.5, 21.5, "slowest sprint ≈ 20 mph")


# ── Carry ease (Hands primary, Speed secondary) ───────────────────────────────
func test_carry_penalty_low_and_eased() -> void:
	# Neutral keeps ~96% of speed (down from the old 14% penalty).
	assert_almost_eq(_build(H3, AVG, AVG, AVG).carry_speed_mult(), 0.958, 0.01)
	# Elite hands carry near-effortlessly (hits the ~0.99 ceiling).
	assert_true(_build(H1, AVG, STRONG, AVG).carry_speed_mult() >= 0.985)
	# A fast build (no elite hands) still carries cleaner than a slow one — Speed eases it.
	assert_true(_build(H3, STRONG, AVG, AVG).carry_speed_mult()
			> _build(H5, WEAK, AVG, AVG).carry_speed_mult())


# ── Validation ────────────────────────────────────────────────────────────────
func test_legal_build_shapes() -> void:
	# One strong + one weak = legal.
	assert_true(PlayerAttributes.is_legal_build(H3, STRONG, WEAK, AVG))
	# All-average = legal.
	assert_true(PlayerAttributes.is_legal_build(H3, AVG, AVG, AVG))
	# Self-nerf (one weak, no strong) = legal.
	assert_true(PlayerAttributes.is_legal_build(H3, WEAK, AVG, AVG))
	# One strong, no weak = ILLEGAL (unearned power).
	assert_false(PlayerAttributes.is_legal_build(H3, STRONG, AVG, AVG))
	# Two strong = illegal.
	assert_false(PlayerAttributes.is_legal_build(H3, STRONG, STRONG, WEAK))
	# Out-of-range tier = illegal. (Height is never a rejection axis — it coerces.)
	assert_false(PlayerAttributes.is_legal_build(H3, 9, WEAK, AVG))
	# Any height passes — an out-of-range one coerces into [68,79], legal shape.
	assert_true(PlayerAttributes.is_legal_build(9999, STRONG, WEAK, AVG))


# ── Serialization ─────────────────────────────────────────────────────────────
func test_dict_round_trip() -> void:
	var a := _build(H5, STRONG, WEAK, AVG)
	var b := PlayerAttributes.from_dict(a.to_dict())
	assert_true(a.equals(b))
	assert_eq(b.height, H5)
	assert_eq(b.skating, STRONG)
	assert_eq(b.skill, WEAK)


func test_legacy_six_attr_migration_enforcer() -> void:
	# A legacy size-5 / physical-5 enforcer → tall, Checking-strong, Skating-weak.
	var a := PlayerAttributes.migrate_legacy(2, 1, 2, 5, 5, 4)
	assert_eq(a.height, PlayerAttributes.HEIGHT_MAX)  # size 5 -> 6'7"
	assert_eq(a.checking, STRONG)
	assert_eq(a.skating, WEAK)
	assert_true(a.is_legal())


func test_legacy_six_attr_migration_dangler() -> void:
	# A small agility-5 / hands-5 dangler → short, and its top axis is a strength.
	var a := PlayerAttributes.migrate_legacy(2, 5, 5, 2, 2, 2)
	assert_eq(a.height, 70)  # size 2 -> 5'10"
	assert_eq(a.checking, WEAK)  # physical was the clear low
	assert_true(a.is_legal())


func test_from_dict_detects_legacy_vs_native() -> void:
	# Native dict.
	var native := PlayerAttributes.from_dict({"height": 4, "skating": STRONG, "skill": WEAK, "checking": AVG})
	assert_eq(native.height, 76)  # native "4" reads as a legacy step -> 6'4"
	assert_eq(native.skating, STRONG)
	# Legacy dict (no native keys) is migrated, not read as neutral.
	var legacy := PlayerAttributes.from_dict({"speed": 2, "agility": 1, "hands": 2, "size": 5, "physical": 5, "shot": 4})
	assert_eq(legacy.height, PlayerAttributes.HEIGHT_MAX)
	assert_eq(legacy.checking, STRONG)


# ── Visual tells route to the right axis ──────────────────────────────────────
func test_visual_tells_map_to_axes() -> void:
	# Shoulders → Checking, legs → Skating, arms → Skill, torso → height.
	assert_true(_build(H3, AVG, AVG, STRONG).shoulder_bulk_mult()
			> _build(H3, AVG, AVG, WEAK).shoulder_bulk_mult(), "shoulders read Checking")
	assert_true(_build(H3, STRONG, AVG, AVG).thigh_mult()
			> _build(H3, WEAK, AVG, AVG).thigh_mult(), "legs read Skating")
	assert_true(_build(H3, AVG, STRONG, AVG).forearm_bulk_mult()
			> _build(H3, AVG, WEAK, AVG).forearm_bulk_mult(), "arms read Skill")
	assert_true(_build(H5, AVG, AVG, AVG).torso_bulk_mult()
			> _build(H1, AVG, AVG, AVG).torso_bulk_mult(), "torso reads height")
