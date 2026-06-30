extends GutTest

# BotSkillProfile is a pure deterministic value bundle. Tests pin the tier
# factories, the difficulty dispatch + fallback, and the key invariants the
# rest of the system relies on: Hard reacts with no perception delay, Normal
# is strictly softer on every axis, and no profile introduces RNG.


func test_for_difficulty_dispatches_to_tiers() -> void:
	var normal: BotSkillProfile = BotSkillProfile.for_difficulty(BotSkillProfile.Difficulty.NORMAL)
	var hard: BotSkillProfile = BotSkillProfile.for_difficulty(BotSkillProfile.Difficulty.HARD)
	assert_eq(normal.carrier_reaction_delay_s, BotSkillProfile.normal().carrier_reaction_delay_s)
	assert_eq(hard.carrier_reaction_delay_s, BotSkillProfile.hard().carrier_reaction_delay_s)


func test_unknown_difficulty_falls_back_to_hard() -> void:
	# Out-of-range index (e.g. a stale pref or a future tier removed) must not
	# crash — it falls back to the Hard ceiling.
	var profile: BotSkillProfile = BotSkillProfile.for_difficulty(99)
	assert_eq(profile.mouse_max_speed_m_s, BotSkillProfile.hard().mouse_max_speed_m_s)


func test_hard_reaction_is_fast_but_not_instant() -> void:
	# Hard is "strong but human": it reacts to possession changes quickly but
	# not within a physics tick — humans can't either. Still well under Normal.
	var hard: BotSkillProfile = BotSkillProfile.hard()
	assert_gt(hard.carrier_reaction_delay_s, 0.0,
			"even Hard takes a beat to react to a discrete event")
	assert_lt(hard.carrier_reaction_delay_s, BotSkillProfile.normal().carrier_reaction_delay_s)


func test_hard_blade_is_capped_not_teleporting() -> void:
	# Even Hard no longer snaps the blade to the ideal point — that is the
	# de-robotising lever. Just below the old perfect-bot 100 m/s baseline.
	assert_lt(BotSkillProfile.hard().mouse_max_speed_m_s, 100.0)


func test_normal_is_strictly_softer_than_hard_on_every_axis() -> void:
	var normal: BotSkillProfile = BotSkillProfile.normal()
	var hard: BotSkillProfile = BotSkillProfile.hard()
	assert_gt(normal.carrier_reaction_delay_s, hard.carrier_reaction_delay_s,
			"Normal reacts to possession changes later than Hard")
	assert_lt(normal.mouse_max_speed_m_s, hard.mouse_max_speed_m_s,
			"Normal's blade slews slower than Hard's")
	assert_lt(normal.mouse_lerp_factor, hard.mouse_lerp_factor,
			"Normal's aim lags more than Hard's")
	assert_gt(normal.dispatch_period_ticks, hard.dispatch_period_ticks,
			"Normal re-decides less often than Hard")


func test_lerp_factors_stay_in_unit_range() -> void:
	for profile: BotSkillProfile in [BotSkillProfile.normal(), BotSkillProfile.hard()]:
		assert_gt(profile.mouse_lerp_factor, 0.0)
		assert_lte(profile.mouse_lerp_factor, 1.0)


func test_dispatch_period_is_at_least_one_tick() -> void:
	# A zero/negative cadence would stall the throttle (dispatch_period - 1).
	for profile: BotSkillProfile in [BotSkillProfile.normal(), BotSkillProfile.hard()]:
		assert_gte(profile.dispatch_period_ticks, 1)
