extends GutTest

# GoalieSkillProfile is a pure deterministic value bundle (sibling of
# BotSkillProfile). Tests pin the tier factories, the difficulty dispatch +
# fallback, and the invariants the goalie relies on: Hard equals the controller
# defaults (so applying it is a no-op), and the ladder is strictly monotonic
# (Easy softer than Normal softer than Hard) on every axis — laggier reads,
# shorter poke reach, deeper positioning, slower arms, flatter rebounds.


func test_for_difficulty_dispatches_to_tiers() -> void:
	var easy: GoalieSkillProfile = GoalieSkillProfile.for_difficulty(GoalieSkillProfile.Difficulty.EASY)
	var normal: GoalieSkillProfile = GoalieSkillProfile.for_difficulty(GoalieSkillProfile.Difficulty.NORMAL)
	var hard: GoalieSkillProfile = GoalieSkillProfile.for_difficulty(GoalieSkillProfile.Difficulty.HARD)
	assert_eq(easy.arm_reaction_delay_s, GoalieSkillProfile.easy().arm_reaction_delay_s)
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
	assert_eq(hard.depth_aggressive_m, 1.2)
	assert_eq(hard.depth_base_m, 0.6)
	assert_eq(hard.glove_react_max_speed_mps, 2.0)
	assert_eq(hard.blocker_react_max_speed_mps, 2.0)
	assert_eq(hard.pad_toe_out_butterfly_deg, 18.0)
	assert_eq(hard.lateral_accel_mps2, 14.0)


func test_normal_is_strictly_softer_than_hard_on_every_axis() -> void:
	_assert_strictly_softer(GoalieSkillProfile.normal(), GoalieSkillProfile.hard(), "Normal", "Hard")


func test_easy_is_strictly_softer_than_normal_on_every_axis() -> void:
	_assert_strictly_softer(GoalieSkillProfile.easy(), GoalieSkillProfile.normal(), "Easy", "Normal")


# Shared monotonicity check: `softer` must be weaker than `tougher` on every axis,
# in the correct direction for each knob.
func _assert_strictly_softer(softer: GoalieSkillProfile, tougher: GoalieSkillProfile,
		soft_name: String, tough_name: String) -> void:
	# Higher = laggier read = softer.
	assert_gt(softer.arm_reaction_delay_s, tougher.arm_reaction_delay_s,
			"%s's arms start later than %s's" % [soft_name, tough_name])
	assert_gt(softer.cross_crease_react_delay_s, tougher.cross_crease_react_delay_s,
			"%s reads the back door later than %s" % [soft_name, tough_name])
	assert_gt(softer.screen_max_extra_delay_s, tougher.screen_max_extra_delay_s,
			"%s loses screened shots more than %s" % [soft_name, tough_name])
	assert_gt(softer.move_read_max_delay_s, tougher.move_read_max_delay_s,
			"%s is punished harder for being caught moving than %s" % [soft_name, tough_name])
	# Lower = weaker = softer.
	assert_lt(softer.poke_radius_m, tougher.poke_radius_m,
			"%s's stick strips from a shorter range than %s's" % [soft_name, tough_name])
	assert_lt(softer.depth_aggressive_m, tougher.depth_aggressive_m,
			"%s sits deeper (gives up more angle) than %s" % [soft_name, tough_name])
	assert_lt(softer.depth_base_m, tougher.depth_base_m,
			"%s sits deeper at mid-range than %s" % [soft_name, tough_name])
	assert_lt(softer.glove_react_max_speed_mps, tougher.glove_react_max_speed_mps,
			"%s's glove reaches slower than %s's" % [soft_name, tough_name])
	assert_lt(softer.blocker_react_max_speed_mps, tougher.blocker_react_max_speed_mps,
			"%s's blocker reaches slower than %s's" % [soft_name, tough_name])
	assert_lt(softer.pad_toe_out_butterfly_deg, tougher.pad_toe_out_butterfly_deg,
			"%s steers rebounds worse (flatter pads) than %s" % [soft_name, tough_name])
	assert_lt(softer.lateral_accel_mps2, tougher.lateral_accel_mps2,
			"%s ramps into lateral pushes slower than %s" % [soft_name, tough_name])


func test_all_values_stay_physical() -> void:
	# No negative / non-positive delays, radii, depths, speeds on any tier.
	for profile: GoalieSkillProfile in [GoalieSkillProfile.easy(), GoalieSkillProfile.normal(), GoalieSkillProfile.hard()]:
		assert_gt(profile.arm_reaction_delay_s, 0.0)
		assert_gt(profile.cross_crease_react_delay_s, 0.0)
		assert_gt(profile.poke_radius_m, 0.0)
		assert_gte(profile.screen_max_extra_delay_s, 0.0)
		assert_gte(profile.move_read_max_delay_s, 0.0)
		assert_gt(profile.depth_aggressive_m, 0.0)
		assert_gt(profile.depth_base_m, 0.0)
		assert_gt(profile.glove_react_max_speed_mps, 0.0)
		assert_gt(profile.blocker_react_max_speed_mps, 0.0)
		assert_gte(profile.pad_toe_out_butterfly_deg, 0.0)
		assert_gt(profile.lateral_accel_mps2, 0.0)
