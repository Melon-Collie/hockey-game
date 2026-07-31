extends GutTest

# PlayerAttributes — v4 BODY + GEAR model (docs/attributes-v4-plan.md). A build
# is two continuous body dials — HEIGHT (inches, 5'7"..6'8") and WEIGHT (lbs,
# bounded per height by a BMI band 22.5..29.0 floored at an absolute 160 lb) —
# plus four lateral gear slots (stored, zero gameplay effect in step 1).
# Neutral is 6'1" / 201 lbs / all-balanced, where every canonical multiplier
# is 1.0.
#
# This test is the executable spec for the tables authored in
# player_attributes.gd, including the constitution guarantee: no build scales
# blade fidelity (hands) and no attribute term feeds checking (mass-emergent).

const H_MIN: int = PlayerAttributes.HEIGHT_MIN     # 5'7" (67")
const H_MED: int = PlayerAttributes.HEIGHT_MEDIUM  # 6'1" (73")
const H_MAX: int = PlayerAttributes.HEIGHT_MAX     # 6'8" (80")

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


# ── Weight band (BMI interval + absolute playable-mass floor) ─────────────────
func test_weight_band_pounds_table() -> void:
	# Spot-check the authored table: lbs = BMI·in²/703, floored at 160.
	assert_eq(PlayerAttributes.weight_min(68), 162)       # ratio floor 151 → absolute
	assert_eq(PlayerAttributes.weight_max(68), 191)
	assert_eq(PlayerAttributes.weight_neutral(70), 185)
	assert_eq(PlayerAttributes.weight_min(73), 174)
	assert_eq(PlayerAttributes.weight_neutral(73), 201)  # the NHL-average build
	assert_eq(PlayerAttributes.weight_max(73), 220)
	assert_eq(PlayerAttributes.weight_max(76), 238)
	assert_eq(PlayerAttributes.weight_min(79), 204)
	assert_eq(PlayerAttributes.weight_max(79), 257)


func test_weight_band_covers_real_tall_lean_bodies() -> void:
	# The 2026-07 recalibration's reason for existing: the old flat BMI 24.0
	# floor put the 6'4" minimum at 197 lb, which forbids real 6'4" NHL
	# defensemen. These are listed cards, not invented bodies.
	assert_true(PlayerAttributes.weight_min(76) <= 194,
			"6'4 floor (%d lb) must reach Rinzel/Dobson" % PlayerAttributes.weight_min(76))
	for card: Array in [[76, 195], [76, 194], [78, 207], [69, 162], [70, 165], [72, 175],
			[74, 185], [72, 170], [72, 172], [68, 165]]:
		var h: int = card[0]
		var w: int = card[1]
		assert_eq(_body(h, w).weight, w,
				"%d\"/%d lb is a real NHL body and must survive coercion" % [h, w])
	# …while the absolute floor still forbids a body no NHL player has ever had.
	assert_eq(_body(68, 140).weight, PlayerAttributes.MIN_PLAYABLE_LBS)


func test_band_edges_are_fitted_to_their_tails() -> void:
	# The lean side reaches every sampled body (see the card list above); the
	# heavy side accepts two exclusions, the league's two most extreme BMIs.
	assert_lt(_body(75, 238).weight, 238, "Ovechkin — accepted heavy exclusion")
	assert_lt(_body(78, 255).weight, 255, "Zadorov — accepted heavy exclusion")
	# The absolute floor IS the lightest player in the NHL — Hutson, 5'9"/162.
	assert_eq(PlayerAttributes.MIN_PLAYABLE_LBS, 162)
	assert_eq(_body(69, 162).weight, 162, "the lightest real body is buildable")
	assert_gt(_body(69, 155).weight, 155, "…and nothing under it is")
	# Neither floor may reopen the bodies that are past the tail everywhere:
	# no 6'4" player has ever been 185 lb, nor a 5'10" player 160.
	assert_gt(PlayerAttributes.weight_min(76), 185)
	assert_gt(PlayerAttributes.weight_min(70), 160)


func test_frame_t_pins_all_three_anchors_at_every_height() -> void:
	# The band is asymmetric about MEDIUM, so frame_t is piecewise. The
	# invariant that buys: min/neutral/max land on exactly 0/0.5/1 everywhere,
	# so a neutral build keeps its 1.0 multipliers at any height.
	for h: int in range(PlayerAttributes.HEIGHT_MIN, PlayerAttributes.HEIGHT_MAX + 1):
		assert_almost_eq(_body(h, PlayerAttributes.weight_min(h)).frame_t(),
				0.0, 0.0001, "lean edge at %d\"" % h)
		assert_almost_eq(_body(h, PlayerAttributes.weight_neutral(h)).frame_t(),
				0.5, 0.0001, "neutral at %d\"" % h)
		assert_almost_eq(_body(h, PlayerAttributes.weight_max(h)).frame_t(),
				1.0, 0.0001, "heavy edge at %d\"" % h)


func test_weight_for_frame_t_round_trips() -> void:
	# The picker's actual guarantee: drag the height slider away and back and
	# you land on the SAME pound. That is the pounds round-trip w → t → w, and
	# it must be exact at every height and every legal weight.
	#
	# Note this is the right way to state it — a frame-t round-trip (t → w → t)
	# cannot be exact, because weight is quantized to integer pounds. At 5'7"
	# the lean half of the band is only 9 lb wide (the absolute playable-mass
	# floor at 160 sits just under the 169 neutral), so one pound is 0.056 of
	# frame-t and half-pound rounding alone costs 0.028. Asserting pounds
	# instead of frame-t tests the invariant that matters and stays honest at
	# the squeezed heights.
	var misses: Array[String] = []
	for h: int in range(PlayerAttributes.HEIGHT_MIN, PlayerAttributes.HEIGHT_MAX + 1):
		for w: int in range(PlayerAttributes.weight_min(h), PlayerAttributes.weight_max(h) + 1):
			var back: int = PlayerAttributes.weight_for_frame_t(
					h, PlayerAttributes.frame_t_for(h, w))
			if back != w:
				misses.append("%d\"/%d lb → %d lb" % [h, w, back])
	assert_eq(misses.size(), 0, "pounds must round-trip exactly: %s" % ", ".join(misses))
	# And the frame anchors still land on the band's named rows, to the pound.
	for h: int in [67, 68, 70, 73, 76, 79, 80]:
		assert_eq(PlayerAttributes.weight_for_frame_t(h, 0.0), PlayerAttributes.weight_min(h))
		assert_eq(PlayerAttributes.weight_for_frame_t(h, 0.5), PlayerAttributes.weight_neutral(h))
		assert_eq(PlayerAttributes.weight_for_frame_t(h, 1.0), PlayerAttributes.weight_max(h))


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
	assert_eq(_body(H_MIN, 0).weight, 169)   # 5'7"
	assert_eq(_body(H_MED, 0).weight, 201)
	assert_eq(_body(H_MAX, 0).weight, 241)   # 6'8"


func test_frame_t_spans_band() -> void:
	assert_almost_eq(_body(H_MED, 174).frame_t(), 0.0, 0.01, "lean edge")
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
	# Neutral-frame builds. The piecewise frame_t pins every height's neutral to
	# exactly 0.5, so the frame term is exactly 1.0 and these are pure height.
	assert_almost_eq(_body(H_MIN, 0).agility_mult(), 1.065, 0.0001)
	assert_almost_eq(_body(H_MAX, 0).agility_mult(), 0.920, 0.0001)
	# The old end heights kept their values when the anchors moved out.
	assert_almost_eq(_body(68, 0).agility_mult(), 1.050, 0.0001, "5'8\" unchanged")
	assert_almost_eq(_body(79, 0).agility_mult(), 0.930, 0.0001, "6'7\" unchanged")
	assert_true(_body(H_MIN, 0).agility_mult() > _body(H_MED, 0).agility_mult())


func test_shot_big_favored_and_nhl_anchored() -> void:
	assert_true(_body(H_MAX, 0).shot_power_mult() > _body(H_MIN, 0).shot_power_mult())
	# League average = neutral (~89.5 mph slapper on the 40 m/s base).
	assert_almost_eq(40.0 * _body(H_MED, 0).shot_power_mult() * MS_TO_MPH, 89.5, 1.0)
	# Body-only ceiling ≈ 98.7 mph at 6'8" (the flex gear slot re-widens it further).
	assert_between(40.0 * _body(H_MAX, 0).shot_power_mult() * MS_TO_MPH, 97.5, 100.0)


func test_continuous_height_interpolates_between_anchors() -> void:
	# Uses a height-only lever (shot) so nothing on the frame axis can wobble the
	# pure-height interpolation being pinned.
	var lo := _body(70, 0).shot_power_mult()
	var hi := _body(73, 0).shot_power_mult()
	var mid := _body(71, 0).shot_power_mult()
	assert_true(mid > lo and mid < hi, "71\" shot falls between the 70\" and 73\" rows")
	assert_almost_eq(mid, lerpf(lo, hi, 1.0 / 3.0), 0.0001, "linear between anchors")


func test_extended_range_preserves_the_old_heights() -> void:
	# The end anchors moved out (5'8"→5'7", 6'7"→6'8") rather than gaining rows.
	# Every height that was playable before must keep the values it had.
	assert_eq(PlayerAttributes.HEIGHT_MIN, 67)
	assert_eq(PlayerAttributes.HEIGHT_MAX, 80)
	var expected_shot: Dictionary = {68: 0.900, 70: 0.940, 73: 1.000, 76: 1.050, 79: 1.090}
	for h: int in expected_shot:
		assert_almost_eq(_body(h, 0).shot_power_mult(), float(expected_shot[h]), 0.0005,
				"%d\" shot power unchanged" % h)
	# …and the new ends genuinely extend each curve rather than copying a neighbour.
	assert_lt(_body(67, 0).shot_power_mult(), _body(68, 0).shot_power_mult())
	assert_gt(_body(80, 0).shot_power_mult(), _body(79, 0).shot_power_mult())
	assert_gt(_body(67, 0).agility_mult(), _body(68, 0).agility_mult())
	assert_lt(_body(80, 0).agility_mult(), _body(79, 0).agility_mult())
	# The new heights' weight bands, and that they cover the bodies they exist for.
	assert_eq(PlayerAttributes.weight_max(67), 185)   # Caufield 5'7"/174 fits
	assert_eq(_body(67, 174).weight, 174)
	assert_eq(PlayerAttributes.weight_max(80), 264)   # Rempe 6'8"/261 fits
	assert_eq(_body(80, 261).weight, 261)


func test_legacy_1to5_height_maps_to_anchor_inches() -> void:
	assert_eq(PlayerAttributes.new(1).height, 68)
	assert_eq(PlayerAttributes.new(3).height, 73)
	assert_eq(PlayerAttributes.new(5).height, 79)


# ── Weight: accel fork, stamina metabolism, linear mass ───────────────────────
func test_accel_lean_favored() -> void:
	var lean := _body(H_MED, 174)
	var heavy := _body(H_MED, 220)
	assert_true(lean.accel_mult() > heavy.accel_mult(), "lean gets the first step")
	assert_almost_eq(lean.accel_mult(), 1.08, 0.001)
	assert_almost_eq(heavy.accel_mult(), 0.97, 0.001)


func test_stamina_metabolism_by_frame() -> void:
	# Lean = fast metabolism (drains AND regens faster); heavy = deep pool,
	# slow refill — the fork moved off height onto weight in v4.
	var lean := _body(H_MED, 174)
	var heavy := _body(H_MED, 220)
	assert_true(lean.stamina_drain_mult() > heavy.stamina_drain_mult(), "lean drains faster")
	assert_true(lean.stamina_regen_mult() > heavy.stamina_regen_mult(), "lean recovers faster")
	# Same frame at different heights = same metabolism (height no longer
	# enters). Band edges pin frame_t to exactly 0/1 at every height.
	assert_almost_eq(_body(H_MIN, PlayerAttributes.weight_min(H_MIN)).stamina_drain_mult(),
			_body(H_MAX, PlayerAttributes.weight_min(H_MAX)).stamina_drain_mult(),
			0.0001, "metabolism is frame, not height")


func test_mass_linear_in_displayed_weight() -> void:
	assert_almost_eq(_body(H_MED, 201).mass_mult(), 1.0, 0.0001)
	# Same pounds = same mass regardless of height — mass IS the displayed weight.
	assert_almost_eq(_body(73, 210).mass_mult(), _body(76, 210).mass_mult(), 0.0001)
	# Full spread ≈ 1.61× (257/160) — deliberately wider than v3's minor height
	# edge: with no Checking stat, mass carries the physical game. The 2026-07
	# band recalibration left this envelope intact (it dropped the lean BMI edge
	# but the absolute playable-mass floor took over below 5'11").
	var ratio: float = _body(H_MAX, PlayerAttributes.weight_max(H_MAX)).mass_mult() \
			/ _body(H_MIN, PlayerAttributes.weight_min(H_MIN)).mass_mult()
	assert_between(ratio, 1.55, 1.70)


func test_frame_interpolates_between_anchors() -> void:
	# A weight between two frame anchors lerps the frame tables continuously.
	var lo := _body(H_MED, 174).accel_mult()   # LEAN anchor (frame-t 0.0)
	var hi := _body(H_MED, 188).accel_mult()   # LIGHT anchor (frame-t 0.25)
	var mid := _body(H_MED, 181).accel_mult()
	assert_true(mid < lo and mid > hi, "181 lbs falls between the LEAN and LIGHT rows")


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
	var waterbug := _body(H_MIN, PlayerAttributes.weight_min(H_MIN))
	assert_almost_eq(tank.check_delivery_mult(), 1.0, 0.0)
	assert_almost_eq(tank.brace_mult(), 1.0, 0.0)
	assert_true(tank.mass_mult() > waterbug.mass_mult(),
			"the physical edge lives entirely in mass")


func test_agility_bites_with_weight() -> void:
	# F = mv²/r: heavy turns wide and stops long. Frame term multiplies the
	# height baseline.
	var lean := _body(H_MED, 174)
	var heavy := _body(H_MED, 220)
	assert_almost_eq(lean.agility_mult(), 1.03, 0.001, "lean agility bonus")
	assert_almost_eq(heavy.agility_mult(), 0.96, 0.001, "heavy agility tax")
	# Corner budget, re-pinned at the extended range: the worst body corner
	# (6'8"/264) sits ~0.88 and the best (5'7"/160) ~1.10 — one inch further out
	# at each end than the old 0.89/1.08, leaving the profile gear room to lean.
	assert_between(_body(H_MAX, PlayerAttributes.weight_max(H_MAX)).agility_mult(),
			0.875, 0.89, "worst corner")
	assert_between(_body(H_MIN, PlayerAttributes.weight_min(H_MIN)).agility_mult(),
			1.09, 1.11, "best corner")


func test_glide_ignores_weight_tank_still_coasts() -> void:
	# Glide derives from the HEIGHT-ONLY agility component: a heavy build turns
	# wide but must NOT bleed speed while coasting — momentum is his identity.
	var lean := _body(H_MED, 174)
	var heavy := _body(H_MED, 220)
	assert_almost_eq(lean.agility_glide_mult(), heavy.agility_glide_mult(), 0.0001,
			"weight never enters glide")
	assert_almost_eq(heavy.agility_glide_mult(), 1.0, 0.0001, "6'1\" glide is neutral")


func test_radius_widens_with_frame() -> void:
	# Hitbox tracks the silhouette: same height, heavier = wider.
	assert_true(_body(H_MED, 220).radius_mult() > _body(H_MED, 174).radius_mult())
	assert_almost_eq(_body(H_MED, 201).radius_mult(), 1.0, 0.0001, "neutral radius")


# ── Derived (coupled) levers ──────────────────────────────────────────────────
func test_glide_and_charge_are_inverse_of_partner() -> void:
	# Glide mirrors the height-only agility (weight exempt — see above): at the
	# height's neutral frame the frame term is ~1, so glide ≈ 2 − agility there.
	var a := _body(H_MIN, 0)
	assert_almost_eq(a.agility_glide_mult(), 2.0 - 1.065, 0.0001, "height-only inverse")
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
	assert_eq(a.weight, PlayerAttributes.weight_for_frame_t(79, 0.75),
			"strong Checking → SOLID frame")
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
			PlayerAttributes.weight_for_frame_t(73, 0.25))
	# Strong Skill small → short stick (dangler); big → open curve (bomber).
	assert_eq(PlayerAttributes.migrate_tiers(68, 2, 3, 1).length, PlayerAttributes.LENGTH_SHORT)
	assert_eq(PlayerAttributes.migrate_tiers(79, 1, 3, 2).curve, PlayerAttributes.CURVE_OPEN)
	# All-average tiers → the height's neutral build.
	assert_true(PlayerAttributes.migrate_tiers(73, 2, 2, 2)
			.equals(PlayerAttributes.all_average()))


func test_legacy_six_attr_migration_enforcer() -> void:
	# A legacy size-5 / physical-5 enforcer → tall, heavy frame, long stick.
	var a := PlayerAttributes.migrate_legacy(2, 1, 2, 5, 5, 4)
	# The legacy 1..5 step table is FROZEN at the v3 heights, so size 5 stays
	# 6'7" — a migrated save must not gain an inch because the range grew.
	assert_eq(a.height, 79)
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
	var lean := _body(H_MED, 174)
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
	# All four slots are live — a balanced loadout is the only zero-lean one.
	assert_true(PlayerAttributes.new(73, 201).equals(PlayerAttributes.all_average()))


# ── Skate profile: top-end ↔ burst ───────────────────────────────────────────
func test_profile_is_a_topend_burst_seesaw() -> void:
	var rocker := PlayerAttributes.new(73, 201, PlayerAttributes.PROFILE_AGILITY, 1, 1, 1)
	var flat := PlayerAttributes.new(73, 201, PlayerAttributes.PROFILE_POWER, 1, 1, 1)
	assert_gt(flat.speed_mult(), rocker.speed_mult(), "power owns the top end")
	assert_gt(rocker.accel_mult(), flat.accel_mult(), "agility owns the first step")
	assert_gt(rocker.agility_mult(), flat.agility_mult(), "agility owns the corner")
	assert_lt(flat.agility_glide_mult(), rocker.agility_glide_mult(),
			"the long flat coasts, the rocker scrubs")
	# The profile re-widens the sprint band the body plane compressed.
	assert_gt(flat.sprint_ceiling_mult(), rocker.sprint_ceiling_mult())


func test_stacked_agility_corners_budgeted() -> void:
	# Body × gear extremes, pinned at the extended range: the involuntary body
	# corners are ~0.88/~1.10, and the self-chosen extremes (heavy tank on power
	# skates / small build on rockers) push one gear lean outside them.
	var worst := PlayerAttributes.new(80, 264, PlayerAttributes.PROFILE_POWER, 1, 1, 1)
	var best := PlayerAttributes.new(67, 160, PlayerAttributes.PROFILE_AGILITY, 1, 1, 1)
	assert_between(worst.agility_mult(), 0.83, 0.85, "worst stacked corner")
	assert_between(best.agility_mult(), 1.14, 1.16, "best stacked corner")


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


func test_curve_trades_loft_ladder_and_release_for_backhand() -> void:
	var m88 := PlayerAttributes.new(73, 201, 1, PlayerAttributes.CURVE_CLOSED, 1, 1)
	var m92 := PlayerAttributes.all_average()
	var m28 := PlayerAttributes.new(73, 201, 1, PlayerAttributes.CURVE_OPEN, 1, 1)
	# The angle ladder is the elevation lever: every rung steeper on the M28,
	# flatter on the M88, all rungs under the universal launch-angle guard.
	assert_lt(m88.curve_loft_tan_high(), m92.curve_loft_tan_high(),
			"M88's toe gives the least")
	assert_lt(m92.curve_loft_tan_high(), m28.curve_loft_tan_high())
	assert_lt(m88.curve_loft_tan_low(), m92.curve_loft_tan_low())
	assert_lt(m92.curve_loft_tan_low(), m28.curve_loft_tan_low())
	assert_lt(m88.curve_loft_tan_mid(), m28.curve_loft_tan_mid())
	assert_lt(m28.curve_loft_tan_high(), ShotMechanics.MAX_LOFT_RATIO,
			"the whole ladder sits under the universal guard")
	assert_lt(m28.wrister_runway_mult(), 1.0, "M28 is the quick release (banked)")
	assert_gt(m88.curve_backhand_mult(), m28.curve_backhand_mult())
	# Backhand relief approaches but never reaches forehand parity: the
	# controller's 0.75 base coefficient stays below 1.0 under the M88.
	assert_lt(0.75 * m88.curve_backhand_mult(), 1.0, "no full-parity backhand")


func test_curve_slap_and_reception_lean_with_the_pattern() -> void:
	# The other half of the M88↔M28 seesaw: the flatter pattern sweeps a
	# squarer slapper contact and cradles a harder feed; the toe hook pays
	# both. M92 is the neutral row on every axis.
	var m88 := PlayerAttributes.new(73, 201, 1, PlayerAttributes.CURVE_CLOSED, 1, 1)
	var m92 := PlayerAttributes.all_average()
	var m28 := PlayerAttributes.new(73, 201, 1, PlayerAttributes.CURVE_OPEN, 1, 1)
	assert_gt(m88.curve_slap_mult(), 1.0, "M88 is the slapper blade")
	assert_almost_eq(m92.curve_slap_mult(), 1.0, 0.0001, "M92 slap-neutral")
	assert_lt(m28.curve_slap_mult(), 1.0, "the toe hook pays the point shot")
	assert_gt(m88.reception_ceiling_mult(), 1.0, "M88 catches the hardest feeds")
	assert_almost_eq(m92.reception_ceiling_mult(), 1.0, 0.0001, "M92 reception-neutral")
	assert_lt(m28.reception_ceiling_mult(), 1.0, "hard feeds bounce off the toe hook")
	# The leans stay leans, not identities: even the M28 receiver still soaks
	# most of the league ceiling (soft/medium passes are unaffected entirely —
	# pickup_max_speed never scales with curve).
	assert_gt(m28.reception_ceiling_mult(), 0.85, "reception lean stays gentle")


func test_stacked_runway_floor() -> void:
	# The runway-floor constraint: the fastest-release loadout (whippy + open)
	# still consumes ≥75% of the neutral runway — a max-power release always
	# emits a readable wind-up tell inside the goalie's calibrated read band.
	var quickest := PlayerAttributes.new(73, 201, 1,
			PlayerAttributes.CURVE_OPEN, PlayerAttributes.FLEX_LOW, 1)
	assert_gte(quickest.wrister_runway_mult(), 0.75, "runway floor holds")
	assert_almost_eq(PlayerAttributes.all_average().wrister_runway_mult(), 1.0, 0.0001)
