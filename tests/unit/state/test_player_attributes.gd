extends GutTest

# PlayerAttributes — v4 BODY + GEAR model (docs/attributes-v4-plan.md). A build
# is two continuous body dials — HEIGHT (inches, 5'8"..6'7") and WEIGHT (lbs,
# bounded per height by one BMI band 24.0..29.0) — plus four lateral gear slots
# (stored, zero gameplay effect in step 1). Neutral is 6'1" / 201 lbs /
# all-balanced, where every canonical multiplier is 1.0.
#
# This test is the executable spec for the tables authored in
# player_attributes.gd, including the constitution guarantee: no build scales
# blade fidelity (hands) and no attribute term feeds checking (mass-emergent).

const H_MIN: int = PlayerAttributes.HEIGHT_MIN     # 5'8" (68")
const H_MED: int = PlayerAttributes.HEIGHT_MEDIUM  # 6'1" (73")
const H_MAX: int = PlayerAttributes.HEIGHT_MAX     # 6'7" (79")

const BASE_MAX_SPEED: float = 9.0  # GameRules.DEFAULT_SKATER_MAX_SPEED_M_S
const MS_TO_MPH: float = 2.23694


func _body(h: int, w: int) -> PlayerAttributes:
	return PlayerAttributes.from_levels(h, w)


# ── Neutral identity ──────────────────────────────────────────────────────────
func test_neutral_is_all_ones() -> void:
	var a := PlayerAttributes.all_average()
	assert_eq(a.height, H_MED)
	assert_eq(a.weight, 201)
	assert_eq(a.profile, PlayerAttributes.GEAR_BALANCED)
	# 6'1"/201/balanced must equal the shipped @export baseline everywhere.
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
	assert_almost_eq(a.torso_bulk_mult(), 1.0, 0.0001, "torso")


func test_neutral_matches_v3_average_derived_levers() -> void:
	# The v4 body plane is authored around the v3 average-tier rows, so the
	# derived levers must land where a v3 all-average 6'1" landed.
	var a := PlayerAttributes.all_average()
	assert_almost_eq(a.agility_glide_mult(), 1.0, 0.0001, "glide")
	assert_almost_eq(a.shot_charge_mult(), 1.0, 0.0001, "charge")
	assert_almost_eq(a.carry_speed_mult(), 0.9576, 0.001, "carry (v3 H3-average value)")


# ── Weight band (single BMI interval) ─────────────────────────────────────────
func test_weight_band_pounds_table() -> void:
	# Spot-check the authored table: lbs = BMI·in²/703.
	assert_eq(PlayerAttributes.weight_min(68), 158)
	assert_eq(PlayerAttributes.weight_max(68), 191)
	assert_eq(PlayerAttributes.weight_neutral(70), 185)
	assert_eq(PlayerAttributes.weight_min(73), 182)
	assert_eq(PlayerAttributes.weight_neutral(73), 201)  # the NHL-average build
	assert_eq(PlayerAttributes.weight_max(73), 220)
	assert_eq(PlayerAttributes.weight_max(76), 238)      # Ovechkin's card
	assert_eq(PlayerAttributes.weight_min(79), 213)
	assert_eq(PlayerAttributes.weight_max(79), 257)


func test_implausible_bodies_unrepresentable() -> void:
	# 6'6"/160 (BMI ~18.5) coerces up to the band floor — by construction, not rule.
	var beanpole := _body(78, 160)
	assert_true(beanpole.weight >= PlayerAttributes.weight_min(78),
			"underweight clamps to band floor (%d)" % beanpole.weight)
	# 5'8"/240 clamps down to the band ceiling.
	assert_eq(_body(68, 240).weight, 191)


func test_zero_weight_coerces_to_neutral_frame() -> void:
	# A pre-v5 save / defaulted wire arg (weight 0) lands on the height's
	# neutral frame, keeping legacy identities' silhouettes.
	assert_eq(_body(H_MIN, 0).weight, 174)
	assert_eq(_body(H_MED, 0).weight, 201)
	assert_eq(_body(H_MAX, 0).weight, 235)


func test_frame_t_spans_band() -> void:
	assert_almost_eq(_body(H_MED, 182).frame_t(), 0.0, 0.01, "lean edge")
	assert_almost_eq(_body(H_MED, 201).frame_t(), 0.5, 0.01, "neutral mid")
	assert_almost_eq(_body(H_MED, 220).frame_t(), 1.0, 0.01, "heavy edge")


# ── Height: speed hump, agility slope, shot baseline ──────────────────────────
func test_speed_peaks_at_medium_height() -> void:
	var small := _body(H_MIN, 0).speed_mult()
	var med := _body(H_MED, 0).speed_mult()
	var big := _body(H_MAX, 0).speed_mult()
	assert_true(med > small, "medium faster than small")
	assert_true(med > big, "medium faster than big")
	assert_almost_eq(small, big, 0.01, "small and big tie on top speed")


func test_agility_small_favored() -> void:
	# Neutral-frame builds (tolerance covers the integer-band rounding at 68",
	# where the neutral 174 lbs sits at frame_t 0.485, a ~0.1% frame term).
	assert_almost_eq(_body(H_MIN, 0).agility_mult(), 1.05, 0.002)
	assert_almost_eq(_body(H_MAX, 0).agility_mult(), 0.93, 0.002)
	assert_true(_body(H_MIN, 0).agility_mult() > _body(H_MED, 0).agility_mult())


func test_shot_big_favored_and_nhl_anchored() -> void:
	assert_true(_body(H_MAX, 0).shot_power_mult() > _body(H_MIN, 0).shot_power_mult())
	# League average = neutral (~89.5 mph slapper on the 40 m/s base).
	assert_almost_eq(40.0 * _body(H_MED, 0).shot_power_mult() * MS_TO_MPH, 89.5, 1.0)
	# Body-only ceiling ≈ 97.5 mph (the flex gear stage re-widens the top end).
	assert_between(40.0 * _body(H_MAX, 0).shot_power_mult() * MS_TO_MPH, 96.0, 99.0)


func test_continuous_height_interpolates_between_anchors() -> void:
	# Uses a height-only lever (shot) so the per-height integer-band rounding of
	# the neutral frame can't wobble the pure-height interpolation being pinned.
	var lo := _body(70, 0).shot_power_mult()
	var hi := _body(73, 0).shot_power_mult()
	var mid := _body(71, 0).shot_power_mult()
	assert_true(mid > lo and mid < hi, "71\" shot falls between the 70\" and 73\" rows")
	assert_almost_eq(mid, lerpf(lo, hi, 1.0 / 3.0), 0.0001, "linear between anchors")


func test_legacy_1to5_height_maps_to_anchor_inches() -> void:
	assert_eq(PlayerAttributes.new(1).height, 68)
	assert_eq(PlayerAttributes.new(3).height, 73)
	assert_eq(PlayerAttributes.new(5).height, 79)


# ── Weight: accel fork, stamina metabolism, linear mass ───────────────────────
func test_accel_lean_favored() -> void:
	var lean := _body(H_MED, 182)
	var heavy := _body(H_MED, 220)
	assert_true(lean.accel_mult() > heavy.accel_mult(), "lean gets the first step")
	assert_almost_eq(lean.accel_mult(), 1.08, 0.001)
	assert_almost_eq(heavy.accel_mult(), 0.97, 0.001)


func test_stamina_metabolism_by_frame() -> void:
	# Lean = fast metabolism (drains AND regens faster); heavy = deep pool,
	# slow refill — the fork moved off height onto weight in v4.
	var lean := _body(H_MED, 182)
	var heavy := _body(H_MED, 220)
	assert_true(lean.stamina_drain_mult() > heavy.stamina_drain_mult(), "lean drains faster")
	assert_true(lean.stamina_regen_mult() > heavy.stamina_regen_mult(), "lean recovers faster")
	# Same frame at different heights = same metabolism (height no longer
	# enters). Band edges pin frame_t to exactly 0/1 at every height.
	assert_almost_eq(_body(H_MIN, 158).stamina_drain_mult(),
			_body(H_MAX, 213).stamina_drain_mult(), 0.0001, "metabolism is frame, not height")


func test_mass_linear_in_displayed_weight() -> void:
	assert_almost_eq(_body(H_MED, 201).mass_mult(), 1.0, 0.0001)
	# Same pounds = same mass regardless of height — mass IS the displayed weight.
	assert_almost_eq(_body(73, 210).mass_mult(), _body(76, 210).mass_mult(), 0.0001)
	# Full spread ≈ 1.63× (257/158) — deliberately wider than v3's minor height
	# edge: with no Checking stat, mass carries the physical game.
	var ratio: float = _body(H_MAX, 257).mass_mult() / _body(H_MIN, 158).mass_mult()
	assert_between(ratio, 1.55, 1.70)


func test_frame_interpolates_between_anchors() -> void:
	# A weight between two frame anchors lerps the frame tables continuously.
	var lo := _body(H_MED, 182).accel_mult()   # LEAN anchor
	var hi := _body(H_MED, 191).accel_mult()   # LIGHT anchor (BMI 25.25)
	var mid := _body(H_MED, 186).accel_mult()
	assert_true(mid < lo and mid > hi, "186 lbs falls between the LEAN and LIGHT rows")


# ── The constitution: no fidelity scaling, checking is mass-emergent ──────────
func test_hands_never_scaled_by_any_build() -> void:
	# "Your hands are you": the blade tracks every build's cursor identically.
	for h: int in [H_MIN, 71, H_MED, 77, H_MAX]:
		for w: int in [0, PlayerAttributes.weight_min(h), PlayerAttributes.weight_max(h)]:
			var a := _body(h, w)
			assert_almost_eq(a.hands_blade_mult(), 1.0, 0.0, "hands flat at %d\"/%d" % [h, w])
			assert_almost_eq(a.hands_backhand_mult(), 1.0, 0.0, "backhand flat")


func test_checking_accessors_neutral_mass_carries_it() -> void:
	# Delivery/brace have no attribute term — the collision resolver reads mass.
	var tank := _body(H_MAX, 257)
	var waterbug := _body(H_MIN, 158)
	assert_almost_eq(tank.check_delivery_mult(), 1.0, 0.0)
	assert_almost_eq(tank.brace_mult(), 1.0, 0.0)
	assert_true(tank.mass_mult() > waterbug.mass_mult(),
			"the physical edge lives entirely in mass")


func test_agility_bites_with_weight() -> void:
	# F = mv²/r: heavy turns wide and stops long. Frame term multiplies the
	# height baseline.
	var lean := _body(H_MED, 182)
	var heavy := _body(H_MED, 220)
	assert_almost_eq(lean.agility_mult(), 1.03, 0.001, "lean agility bonus")
	assert_almost_eq(heavy.agility_mult(), 0.96, 0.001, "heavy agility tax")
	# Corner budget: the worst body corner (6'7"/257) stays at/above ~0.89 —
	# just under the v3 "feels bad but playable" floor; the best (5'8"/158)
	# stays under the old 1.11 ceiling, leaving the profile gear room to lean.
	assert_between(_body(H_MAX, 257).agility_mult(), 0.885, 0.90, "worst corner")
	assert_between(_body(H_MIN, 158).agility_mult(), 1.07, 1.10, "best corner")


func test_glide_ignores_weight_tank_still_coasts() -> void:
	# Glide derives from the HEIGHT-ONLY agility component: a heavy build turns
	# wide but must NOT bleed speed while coasting — momentum is his identity.
	var lean := _body(H_MED, 182)
	var heavy := _body(H_MED, 220)
	assert_almost_eq(lean.agility_glide_mult(), heavy.agility_glide_mult(), 0.0001,
			"weight never enters glide")
	assert_almost_eq(heavy.agility_glide_mult(), 1.0, 0.0001, "6'1\" glide is neutral")


func test_radius_widens_with_frame() -> void:
	# Hitbox tracks the silhouette: same height, heavier = wider.
	assert_true(_body(H_MED, 220).radius_mult() > _body(H_MED, 182).radius_mult())
	assert_almost_eq(_body(H_MED, 201).radius_mult(), 1.0, 0.0001, "neutral radius")


# ── Derived (coupled) levers ──────────────────────────────────────────────────
func test_glide_and_charge_are_inverse_of_partner() -> void:
	# Glide mirrors the height-only agility (weight exempt — see above): at the
	# height's neutral frame the frame term is ~1, so glide ≈ 2 − agility there.
	var a := _body(H_MIN, 0)
	assert_almost_eq(a.agility_glide_mult(), 2.0 - 1.05, 0.0001, "height-only inverse")
	assert_almost_eq(a.shot_charge_mult(), 2.0 - a.shot_power_mult(), 0.0001)


# ── Sprint ceiling (compressed pre-gear band) ────────────────────────────────
func test_sprint_ceiling_bounded_pre_gear() -> void:
	# Body-only speed occupies the middle of the v3 span, so every build's
	# sprint lands in a tight ~22 mph band until the skate-profile gear slot
	# re-widens it. The medium-height hump still gets the best gear.
	var med := _body(H_MED, 0)
	var small := _body(H_MIN, 0)
	assert_true(med.sprint_ceiling_mult() > small.sprint_ceiling_mult())
	for h: int in [H_MIN, H_MED, H_MAX]:
		var a := _body(h, 0)
		var top_mph: float = BASE_MAX_SPEED * a.speed_mult() * a.sprint_ceiling_mult() * MS_TO_MPH
		assert_between(top_mph, 21.0, 23.0, "body-only sprint band at %d\"" % h)


# ── Gear slots (step 1: stored + coerced, no gameplay effect) ────────────────
func test_gear_defaults_balanced_and_clamps() -> void:
	var a := PlayerAttributes.new(H_MED, 201, -3, 99, 2, 0)
	assert_eq(a.profile, 0, "out-of-range gear clamps low")
	assert_eq(a.curve, 2, "out-of-range gear clamps high")
	assert_eq(a.flex, PlayerAttributes.FLEX_HIGH)
	assert_eq(a.length, PlayerAttributes.LENGTH_SHORT)
	assert_eq(PlayerAttributes.all_average().curve, PlayerAttributes.GEAR_BALANCED)


func test_equals_includes_gear() -> void:
	var a := PlayerAttributes.new(H_MED, 201, 1, 1, 1, 1)
	var b := PlayerAttributes.new(H_MED, 201, 1, 1, 1, 2)
	assert_false(a.equals(b), "length differs")
	assert_true(a.equals(PlayerAttributes.new(H_MED, 201)))


# ── Serialization & migration ─────────────────────────────────────────────────
func test_dict_round_trip() -> void:
	var a := PlayerAttributes.new(76, 228, 2, 0, 1, 2)
	var b := PlayerAttributes.from_dict(a.to_dict())
	assert_true(a.equals(b))
	assert_eq(b.weight, 228)
	assert_eq(b.profile, 2)


func test_from_dict_tier_era_migrates() -> void:
	# A v4 tier dict (Pohl's old card: 6'7", weak Skating, strong Checking) →
	# heavy frame + long stick, height carried.
	var a := PlayerAttributes.from_dict(
			{"height": 5, "skating": 1, "skill": 2, "checking": 3})
	assert_eq(a.height, 79)
	assert_eq(a.weight, PlayerAttributes.weight_for_bmi(79, 27.75), "strong Checking → SOLID frame")
	assert_eq(a.length, PlayerAttributes.LENGTH_LONG)


func test_from_dict_name_only_is_neutral() -> void:
	# No attribute keys at all → the height's neutral frame, never the legacy
	# migration's default shape.
	var a := PlayerAttributes.from_dict({"name": "Bot 1"})
	assert_true(a.equals(PlayerAttributes.all_average()))
	var tall := PlayerAttributes.from_dict({"height": 79})
	assert_eq(tall.weight, 235)
	assert_eq(tall.profile, PlayerAttributes.GEAR_BALANCED)


func test_migrate_tiers_mapping() -> void:
	# Strong Skating below 6'1" → agility profile; at/above → power profile.
	assert_eq(PlayerAttributes.migrate_tiers(68, 3, 2, 1).profile, PlayerAttributes.PROFILE_AGILITY)
	assert_eq(PlayerAttributes.migrate_tiers(76, 3, 2, 1).profile, PlayerAttributes.PROFILE_POWER)
	# Weak Checking → LIGHT frame.
	assert_eq(PlayerAttributes.migrate_tiers(73, 3, 2, 1).weight,
			PlayerAttributes.weight_for_bmi(73, 25.25))
	# Strong Skill small → short stick (dangler); big → open curve (bomber).
	assert_eq(PlayerAttributes.migrate_tiers(68, 2, 3, 1).length, PlayerAttributes.LENGTH_SHORT)
	assert_eq(PlayerAttributes.migrate_tiers(79, 1, 3, 2).curve, PlayerAttributes.CURVE_OPEN)
	# All-average tiers → the height's neutral build.
	assert_true(PlayerAttributes.migrate_tiers(73, 2, 2, 2)
			.equals(PlayerAttributes.all_average()))


func test_legacy_six_attr_migration_enforcer() -> void:
	# A legacy size-5 / physical-5 enforcer → tall, heavy frame, long stick.
	var a := PlayerAttributes.migrate_legacy(2, 1, 2, 5, 5, 4)
	assert_eq(a.height, H_MAX)  # size 5 -> 6'7"
	assert_true(a.weight > PlayerAttributes.weight_neutral(H_MAX), "checking-strong → heavier")
	assert_eq(a.length, PlayerAttributes.LENGTH_LONG)


func test_legacy_six_attr_migration_dangler() -> void:
	# A small agility-5 / hands-5 dangler → short, light frame.
	var a := PlayerAttributes.migrate_legacy(2, 5, 5, 2, 2, 2)
	assert_eq(a.height, 70)  # size 2 -> 5'10"
	assert_true(a.weight < PlayerAttributes.weight_neutral(70), "checking-weak → leaner")


# ── Visual tells ──────────────────────────────────────────────────────────────
func test_visual_tells_map_to_body() -> void:
	# Silhouette = body: frame drives uniform bulk, height drives torso/scale.
	var heavy := _body(H_MED, 220)
	var lean := _body(H_MED, 182)
	assert_true(heavy.shoulder_bulk_mult() > lean.shoulder_bulk_mult(), "shoulders read frame")
	assert_true(heavy.thigh_mult() > lean.thigh_mult(), "legs read frame")
	assert_true(heavy.forearm_bulk_mult() > lean.forearm_bulk_mult(), "arms read frame")
	assert_true(heavy.torso_bulk_mult() > lean.torso_bulk_mult(), "torso reads frame")
	assert_true(_body(H_MAX, 235).torso_bulk_mult() > _body(H_MIN, 174).torso_bulk_mult(),
			"torso reads height too")


func test_labels() -> void:
	assert_eq(PlayerAttributes.inches_label(73), "6'1\"")
	assert_eq(_body(H_MED, 201).weight_label(), "201 lbs")


# ── Stick length: the first live gear slot ────────────────────────────────────
func test_stick_length_lean() -> void:
	# A lean on the height's cut (never an absolute pick): ±4% around the
	# height band center, so max-height + LONG can't stack absolute reach
	# beyond the tuned corner.
	var std := PlayerAttributes.all_average()
	var short := PlayerAttributes.new(73, 201, 1, 1, 1, PlayerAttributes.LENGTH_SHORT)
	var long := PlayerAttributes.new(73, 201, 1, 1, 1, PlayerAttributes.LENGTH_LONG)
	assert_almost_eq(std.stick_len_mult(), 1.028, 0.0001, "STANDARD = the height's cut")
	assert_almost_eq(short.stick_len_mult(), 1.028 * 0.96, 0.0001)
	assert_almost_eq(long.stick_len_mult(), 1.028 * 1.04, 0.0001)
	# The one remaining stub: skate profile reads into nothing yet.
	var profiled := PlayerAttributes.new(73, 201, 2, 1, 1, 1)
	assert_true(profiled.speed_mult() == std.speed_mult()
			and profiled.agility_mult() == std.agility_mult()
			and profiled.accel_mult() == std.accel_mult(),
			"profile has zero gameplay effect until its stage")


# ── Flex + curve: the shot gear slots ────────────────────────────────────────
func test_flex_is_a_power_release_seesaw() -> void:
	# Stiff loads a bigger shot but pays a slower load — the charge lean goes
	# WITH the power lean (a lateral trade), unlike the height coupling where
	# a harder shot also threatens sooner.
	var whippy := PlayerAttributes.new(73, 201, 1, 1, PlayerAttributes.FLEX_LOW, 1)
	var stiff := PlayerAttributes.new(73, 201, 1, 1, PlayerAttributes.FLEX_HIGH, 1)
	assert_lt(whippy.shot_power_mult(), stiff.shot_power_mult(), "stiff shoots harder")
	assert_lt(whippy.shot_charge_mult(), stiff.shot_charge_mult(), "stiff loads slower")
	assert_lt(whippy.wrister_runway_mult(), stiff.wrister_runway_mult(),
			"whippy needs less runway for max power")
	# Height keeps its inherited inverse coupling underneath.
	var tall := PlayerAttributes.new(79, 235)
	assert_lt(tall.shot_charge_mult(), 1.0, "big frame still threatens sooner at medium flex")


func test_curve_trades_elevation_and_release_for_backhand() -> void:
	var closed := PlayerAttributes.new(73, 201, 1, PlayerAttributes.CURVE_CLOSED, 1, 1)
	var open := PlayerAttributes.new(73, 201, 1, PlayerAttributes.CURVE_OPEN, 1, 1)
	assert_gt(open.curve_loft_low_mult(), 1.0, "open elevates the LOW loft easier")
	assert_lt(closed.curve_loft_low_mult(), 1.0, "closed is hardest to elevate")
	assert_lt(open.wrister_runway_mult(), 1.0, "open is the quick release")
	assert_gt(closed.curve_backhand_mult(), open.curve_backhand_mult())
	# Backhand relief approaches but never reaches forehand parity: the
	# controller's 0.75 base coefficient stays below 1.0 under CLOSED.
	assert_lt(0.75 * closed.curve_backhand_mult(), 1.0, "no full-parity backhand")


func test_stacked_runway_floor() -> void:
	# The runway-floor constraint: the fastest-release loadout (whippy + open)
	# still consumes ≥75% of the neutral runway — a max-power release always
	# emits a readable wind-up tell inside the goalie's calibrated read band.
	var quickest := PlayerAttributes.new(73, 201, 1,
			PlayerAttributes.CURVE_OPEN, PlayerAttributes.FLEX_LOW, 1)
	assert_gte(quickest.wrister_runway_mult(), 0.75, "runway floor holds")
	assert_almost_eq(PlayerAttributes.all_average().wrister_runway_mult(), 1.0, 0.0001)
