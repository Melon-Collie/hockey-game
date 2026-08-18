extends GutTest

# Guards the claim made in two places at once:
#
#   goalie_skill_profile.gd — "Hard == the GoalieController @export defaults
#                              verbatim. Keep these in sync with the controller
#                              so applying Hard is a true no-op."
#   goalie_controller.gd    — "Null = Hard, i.e. the authored @export defaults
#                              unchanged — so tutorial / replay / single-goalie
#                              spawns that don't pass one behave exactly as before."
#
# Both were false. `read_lag` was authored at 0.13 while hard() passed 0.05, so a
# goalie spawned without a profile read a wind-up 2.6× staler than the Hard tier
# it was supposed to be identical to — on the one knob GoalieSkillProfile itself
# calls "the term that decides whether LATERAL deception pays", and at a value
# outside the 0–0.10 responsive band that file documents. Nothing caught it because
# an eighteen-float positional constructor has no names to compare and a comment
# cannot fail.
#
# The test is the claim, stated literally: snapshot the authored defaults, apply
# Hard, assert nothing moved. It needs no per-field list of expected values, so it
# cannot drift out of date the way the comments did — a new knob added to
# _apply_skill_profile is covered the moment it is wired.

const _MIRRORED_EXPORTS: Array[StringName] = [
	&"arm_reaction_delay", &"cross_crease_react_delay", &"goalie_poke_radius",
	&"screen_max_extra_delay", &"move_read_scramble_delay", &"depth_aggressive",
	&"depth_base", &"glove_react_max_speed", &"blocker_react_max_speed",
	&"pad_toe_out_butterfly_deg", &"lateral_accel", &"puck_play_go_margin",
	&"reaction_delay", &"prearmed_reaction_delay", &"read_lag",
	&"read_converge_time", &"butterfly_drop_speed", &"five_hole_base",
]

const _CTRL: GDScript = preload("res://Scripts/controllers/goalie_controller.gd")


func _authored_default(name: StringName) -> float:
	return float(_CTRL.get_property_default_value(name))


func test_applying_hard_leaves_every_authored_default_untouched() -> void:
	var ctrl: GoalieController = autofree(GoalieController.new())
	ctrl.apply_skill_profile(GoalieSkillProfile.hard())
	for name: StringName in _MIRRORED_EXPORTS:
		assert_almost_eq(float(ctrl.get(name)), _authored_default(name), 1e-9,
				"applying Hard must not move `%s` — Hard IS the authored default" % name)


# The list above has to stay complete or the guard quietly shrinks. Every export
# _apply_skill_profile writes is a field the profile owns, so the count is the
# contract: if someone wires a nineteenth knob, this fails until it is listed.
func test_mirrored_export_list_covers_every_field_the_profile_writes() -> void:
	var src: String = FileAccess.get_file_as_string(
			"res://Scripts/controllers/goalie_controller.gd")
	var body: String = src.get_slice("func _apply_skill_profile(", 1).get_slice("\n\n", 0)
	var written: int = 0
	for line: String in body.split("\n"):
		var trimmed: String = line.strip_edges()
		if trimmed.is_empty() or trimmed.begins_with("#") or not trimmed.contains("= profile."):
			continue
		written += 1
		var field := StringName(trimmed.get_slice(" =", 0).strip_edges())
		assert_true(_MIRRORED_EXPORTS.has(field),
				"_apply_skill_profile writes `%s` — add it to _MIRRORED_EXPORTS" % field)
	assert_eq(written, _MIRRORED_EXPORTS.size(),
			"_MIRRORED_EXPORTS must list exactly the fields _apply_skill_profile writes")


# The tiers are a ladder on the knobs that admit one, and Hard is the sharp end.
# Pinned because the ladder is what makes a tier mean anything: a Normal that reads
# faster than Hard is not "a different feel", it is a mislabelled tier.
func test_read_lag_ladder_is_monotonic_across_tiers() -> void:
	var hard: float = GoalieSkillProfile.hard().read_lag_s
	var normal: float = GoalieSkillProfile.normal().read_lag_s
	var easy: float = GoalieSkillProfile.easy().read_lag_s
	assert_lt(hard, normal, "Hard must read fresher than Normal")
	assert_lt(normal, easy, "Normal must read fresher than Easy")
	# GoalieSkillProfile documents the measured responsive band as roughly 0–0.10 s;
	# past it the goalie is already fully committed to the wrong read and more
	# staleness buys the shooter nothing. A tier authored above the band is
	# indistinguishable from one at it, which is how 0.13 hid for as long as it did.
	assert_lte(hard, 0.10, "Hard's read lag must sit inside the documented 0–0.10 s band")
	assert_lte(normal, 0.10, "Normal's read lag must sit inside the documented 0–0.10 s band")
