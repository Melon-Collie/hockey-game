extends GutTest

# The bots score their shots against a MODEL of the goalie, not the goalie. When
# the two disagree the bots aim at a net that isn't there — and nothing fails,
# because both halves are individually consistent. Every shot decision in the
# game is quietly wrong and the only symptom is that the bots look bad.
#
# Two contracts hold them together, and both were prose:
#
#   1. The AUTHORED defaults must agree. AIActionScoring's static vars start at
#      the same values GoalieController's @exports do, so a fresh scene with no
#      profile applied has the bots modelling the goalie they face.
#   2. set_goalie_profile must carry EVERY tiered knob the model reads. A knob
#      added to GoalieSkillProfile and wired into the controller but not into
#      the sync leaves the bots scoring against the Hard goalie while an Easy
#      one is in the net.
#
# The area docs now state this (Scripts/domain/ai/CLAUDE.md, "the skater AI's
# goalie model is a MIRROR, not a second tier"); this is what makes it hold.

const _GAME_RULES: String = "res://Scripts/domain/config/game_rules.gd"

var _goalie_src: String = ""


func before_all() -> void:
	_goalie_src = FileAccess.get_file_as_string("res://Scripts/controllers/goalie_controller.gd")


# `var name: T = <literal>` at column 0 -> the literal, as a float. Accepts an
# `@export` prefix too: the goalie's tunables are plain fields now (a scene
# overrode none of them), but the parser should not care which a knob is.
func _export_default(name: String) -> float:
	var re := RegEx.create_from_string(
			"(?m)^(?:@export(?:_[a-z_]+)?(?:\\([^)]*\\))? )?var %s\\s*:\\s*float\\s*=\\s*([^\\n#]+)" % name)
	var m: RegExMatch = re.search(_goalie_src)
	assert_not_null(m, "no float field named `%s` in goalie_controller.gd" % name)
	if m == null:
		return NAN
	var expr: String = m.get_string(1).strip_edges()
	# The defaults that matter are either a literal or a GameRules constant.
	# Resolved through the script's own constant map — `GameRules.get(name)` is a
	# non-static call and GameRules is never instanced.
	if expr.begins_with("GameRules."):
		var consts: Dictionary = (load(_GAME_RULES) as GDScript).get_script_constant_map()
		var key: String = expr.substr("GameRules.".length())
		assert_true(consts.has(key), "GameRules has no constant `%s`" % key)
		return float(consts.get(key, NAN))
	return float(expr)


func test_authored_defaults_agree_before_any_profile_is_applied() -> void:
	# GoalieSkillProfile.hard() is the controller's authored default by
	# construction, so applying it must not move the model.
	AIActionScoring.set_goalie_profile(GoalieSkillProfile.hard())
	assert_almost_eq(AIActionScoring.goalie_leg_delay_s, _export_default("reaction_delay"), 1e-6,
			"the bots' leg-reaction delay must be the goalie's own")
	assert_almost_eq(AIActionScoring.goalie_arm_delay_s, _export_default("arm_reaction_delay"), 1e-6,
			"the bots' arm-reaction delay must be the goalie's own")
	assert_almost_eq(AIActionScoring.goalie_butterfly_drop_s,
			_export_default("butterfly_drop_speed"), 1e-6,
			"the bots' drop time must be the goalie's own — it decides whether a low " +
			"shot is still open when the puck arrives")
	assert_almost_eq(AIActionScoring.goalie_lateral_accel_m_s2,
			_export_default("lateral_accel"), 1e-6,
			"the bots' lateral accel must be the goalie's own — it decides whether a " +
			"cross-crease look is reachable")
	assert_almost_eq(AIActionScoring._planning_ceiling, _export_default("depth_aggressive"), 1e-6,
			"the bots' challenge-depth ceiling must be the goalie's own")


func test_the_arm_deploy_ramp_derives_from_the_goalies_own_reach_and_speed() -> void:
	AIActionScoring.set_goalie_profile(GoalieSkillProfile.hard())
	var reach: float = AIActionScoring.HOLE_BAND_EXT[AIActionScoring.HOLE_BAND_HIGH]
	assert_almost_eq(AIActionScoring.goalie_arm_deploy_s,
			reach / _export_default("glove_react_max_speed"), 1e-6,
			"the deploy ramp is the high-band reach divided by the glove's real speed, " +
			"not an authored number — a faster glove must shrink it")


# A lower tier has to actually move the model, or the ladder is decoration.
func test_an_easier_tier_moves_every_axis_the_bots_read() -> void:
	AIActionScoring.set_goalie_profile(GoalieSkillProfile.hard())
	var hard := {
		"leg": AIActionScoring.goalie_leg_delay_s,
		"arm": AIActionScoring.goalie_arm_delay_s,
		"drop": AIActionScoring.goalie_butterfly_drop_s,
		"accel": AIActionScoring.goalie_lateral_accel_m_s2,
		"deploy": AIActionScoring.goalie_arm_deploy_s,
		"depth": AIActionScoring._planning_ceiling,
	}
	AIActionScoring.set_goalie_profile(GoalieSkillProfile.easy())
	assert_gt(AIActionScoring.goalie_leg_delay_s, hard.leg, "Easy reads later with the legs")
	assert_gt(AIActionScoring.goalie_arm_delay_s, hard.arm, "and later with the arms")
	assert_gt(AIActionScoring.goalie_butterfly_drop_s, hard.drop, "and drops slower")
	assert_lt(AIActionScoring.goalie_lateral_accel_m_s2, hard.accel, "and pushes across slower")
	assert_gt(AIActionScoring.goalie_arm_deploy_s, hard.deploy, "and deploys the glove slower")
	assert_lt(AIActionScoring._planning_ceiling, hard.depth, "and sits deeper in his net")
	AIActionScoring.set_goalie_profile(GoalieSkillProfile.hard())


# The one that catches the real mistake: a knob added to the profile and wired
# into the controller, but never into the sync. Every profile field that names a
# quantity the shot model reads must appear in set_goalie_profile's body.
func test_every_mirrored_profile_field_is_carried_by_the_sync() -> void:
	var src: String = FileAccess.get_file_as_string(
			"res://Scripts/domain/ai/action_scoring.gd")
	var head: int = src.find("static func set_goalie_profile(")
	assert_gt(head, 0, "set_goalie_profile must exist — it is the whole seam")
	var body: String = src.substr(head, src.find("\n\n\n", head) - head)
	for field: String in ["reaction_delay_s", "arm_reaction_delay_s", "butterfly_drop_s",
			"lateral_accel_mps2", "glove_react_max_speed_mps", "depth_aggressive_m",
			"depth_base_m"]:
		assert_true(body.contains("profile.%s" % field),
				"set_goalie_profile does not read `profile.%s`, which the shot model " % field +
				"depends on — the bots would go on scoring against the Hard goalie " +
				"while facing a lower tier")


# Guards the guard: the export parser is the only moving part above, and if it
# stopped matching every assertion would compare NAN against NAN.
func test_the_export_parser_still_reads_the_controller() -> void:
	assert_gt(_export_default("reaction_delay"), 0.0, "parsed a real reaction delay")
	assert_gt(_export_default("glove_react_max_speed"), 0.0, "parsed a real glove speed")
	assert_gt(_export_default("depth_aggressive"), 0.0, "parsed a real challenge depth")
