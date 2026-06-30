extends GutTest

# GoalieSkillProfile is a pure deterministic value bundle (sibling of
# BotSkillProfile). Tests pin the tier factories, the difficulty dispatch +
# fallback, and the invariants the goalie relies on: Hard equals the controller
# defaults (so applying it is a no-op), and Normal is strictly softer on every
# axis (laggier reads, shorter poke reach).


func test_for_difficulty_dispatches_to_tiers() -> void:
	var normal: GoalieSkillProfile = GoalieSkillProfile.for_difficulty(GoalieSkillProfile.Difficulty.NORMAL)
	var hard: GoalieSkillProfile = GoalieSkillProfile.for_difficulty(GoalieSkillProfile.Difficulty.HARD)
	assert_eq(normal.arm_reaction_delay_s, GoalieSkillProfile.normal().arm_reaction_delay_s)
	assert_eq(hard.arm_reaction_delay_s, GoalieSkillProfile.hard().arm_reaction_delay_s)


func test_unknown_difficulty_falls_back_to_hard() -> void:
	# Out-of-range index (stale pref / removed tier) must not crash — falls back
	# to the Hard ceiling.
	var profile: GoalieSkillProfile = GoalieSkillProfile.for_difficulty(99)
	assert_eq(profile.poke_radius_m, GoalieSkillProfile.hard().poke_radius_m)


func test_hard_matches_controller_defaults() -> void:
	# Hard must equal the GoalieController @export defaults so applying it is a
	# true no-op — Hard is exactly today's goalie. If a default changes, update
	# both (this test is the tripwire).
	var hard: GoalieSkillProfile = GoalieSkillProfile.hard()
	assert_eq(hard.arm_reaction_delay_s, 0.18)
	assert_eq(hard.cross_crease_react_delay_s, 0.12)
	assert_eq(hard.poke_radius_m, 0.25)
	assert_eq(hard.screen_max_extra_delay_s, 0.15)
	assert_eq(hard.move_read_max_delay_s, 0.12)


func test_normal_is_strictly_softer_than_hard_on_every_axis() -> void:
	var normal: GoalieSkillProfile = GoalieSkillProfile.normal()
	var hard: GoalieSkillProfile = GoalieSkillProfile.hard()
	assert_gt(normal.arm_reaction_delay_s, hard.arm_reaction_delay_s,
			"Normal's arms start later than Hard's")
	assert_gt(normal.cross_crease_react_delay_s, hard.cross_crease_react_delay_s,
			"Normal reads the back door later than Hard")
	assert_lt(normal.poke_radius_m, hard.poke_radius_m,
			"Normal's stick strips from a shorter range than Hard's")
	assert_gt(normal.screen_max_extra_delay_s, hard.screen_max_extra_delay_s,
			"Normal loses screened shots more than Hard")
	assert_gt(normal.move_read_max_delay_s, hard.move_read_max_delay_s,
			"Normal is punished harder for being caught moving than Hard")


func test_all_values_stay_physical() -> void:
	# No negative delays / radii on any tier.
	for profile: GoalieSkillProfile in [GoalieSkillProfile.normal(), GoalieSkillProfile.hard()]:
		assert_gt(profile.arm_reaction_delay_s, 0.0)
		assert_gt(profile.cross_crease_react_delay_s, 0.0)
		assert_gt(profile.poke_radius_m, 0.0)
		assert_gte(profile.screen_max_extra_delay_s, 0.0)
		assert_gte(profile.move_read_max_delay_s, 0.0)
