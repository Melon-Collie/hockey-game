extends GutTest

# BotSkillProfile is a pure deterministic value bundle. Tests pin the tier
# factories, the difficulty dispatch + fallback, and the key invariants the
# rest of the system relies on: Hard reacts with a light human touch, the tiers
# form a strictly-softening ladder (Hard → Normal → Easy) on every axis, and no
# profile introduces RNG.


func test_for_difficulty_dispatches_to_tiers() -> void:
	var easy: BotSkillProfile = BotSkillProfile.for_difficulty(BotSkillProfile.Difficulty.EASY)
	var normal: BotSkillProfile = BotSkillProfile.for_difficulty(BotSkillProfile.Difficulty.NORMAL)
	var hard: BotSkillProfile = BotSkillProfile.for_difficulty(BotSkillProfile.Difficulty.HARD)
	assert_eq(easy.carrier_reaction_delay_s, BotSkillProfile.easy().carrier_reaction_delay_s)
	assert_eq(normal.carrier_reaction_delay_s, BotSkillProfile.normal().carrier_reaction_delay_s)
	assert_eq(hard.carrier_reaction_delay_s, BotSkillProfile.hard().carrier_reaction_delay_s)


func test_unknown_difficulty_falls_back_to_hard() -> void:
	# Out-of-range index (e.g. a stale pref or a future tier removed) must not
	# crash — it falls back to the Hard ceiling.
	var profile: BotSkillProfile = BotSkillProfile.for_difficulty(99)
	assert_eq(profile.carrier_reaction_delay_s, BotSkillProfile.hard().carrier_reaction_delay_s)


func test_hard_reaction_is_fast_but_not_instant() -> void:
	# Hard is "strong but human": it reacts to possession changes quickly but
	# not within a physics tick — humans can't either. Still well under Normal.
	var hard: BotSkillProfile = BotSkillProfile.hard()
	assert_gt(hard.carrier_reaction_delay_s, 0.0,
			"even Hard takes a beat to react to a discrete event")
	assert_lt(hard.carrier_reaction_delay_s, BotSkillProfile.normal().carrier_reaction_delay_s)


func test_tiers_form_a_strictly_softening_ladder_on_every_axis() -> void:
	# Easy softer than Normal softer than Hard on all four knobs — the property
	# every consumer relies on (a tier is never harder than the one above it).
	var easy: BotSkillProfile = BotSkillProfile.easy()
	var normal: BotSkillProfile = BotSkillProfile.normal()
	var hard: BotSkillProfile = BotSkillProfile.hard()
	# Reaction delay: later is softer.
	assert_gt(normal.carrier_reaction_delay_s, hard.carrier_reaction_delay_s,
			"Normal reacts to possession changes later than Hard")
	assert_gt(easy.carrier_reaction_delay_s, normal.carrier_reaction_delay_s,
			"Easy reacts to possession changes later than Normal")
	# (Aim slew is no longer a profile knob — it's the bot's real Hands blade
	# speed — and the old second-stage cursor lerp is gone entirely.)
	# Dispatch cadence: more ticks re-decides less often.
	assert_gt(normal.dispatch_period_ticks, hard.dispatch_period_ticks,
			"Normal re-decides less often than Hard")
	assert_gt(easy.dispatch_period_ticks, normal.dispatch_period_ticks,
			"Easy re-decides less often than Normal")
	# Shot aim error: bigger sprays the finish wider (the scoring dial).
	assert_gt(normal.shot_aim_error_rad, hard.shot_aim_error_rad,
			"Normal's shots miss their spot more than Hard's")
	assert_gt(easy.shot_aim_error_rad, normal.shot_aim_error_rad,
			"Easy's shots miss their spot more than Normal's")
	# Pass aim error: softens too, but see the shot-vs-pass split test below.
	assert_gt(normal.pass_aim_error_rad, hard.pass_aim_error_rad,
			"Normal's passes err more than Hard's")
	assert_gt(easy.pass_aim_error_rad, normal.pass_aim_error_rad,
			"Easy's passes err more than Normal's")
	# Release timing: a slower tier's hand is later off the intended tick.
	assert_gt(normal.shot_timing_error_s, hard.shot_timing_error_s,
			"Normal's release timing is sloppier than Hard's")
	assert_gt(easy.shot_timing_error_s, normal.shot_timing_error_s,
			"Easy's release timing is sloppier than Normal's")
	# Settle beat: longer holds the release later after a fresh possession.
	assert_gt(normal.carry_settle_delay_s, hard.carry_settle_delay_s,
			"Normal settles the puck before playing it, Hard doesn't")
	assert_gt(easy.carry_settle_delay_s, normal.carry_settle_delay_s,
			"Easy settles the puck longer than Normal")
	# Pace — pursuit standoff: bigger sags further off the carrier (more time).
	assert_gt(normal.pursuit_standoff_m, hard.pursuit_standoff_m,
			"Normal sags further off the carrier than Hard")
	assert_gt(easy.pursuit_standoff_m, normal.pursuit_standoff_m,
			"Easy sags further off the carrier than Normal")
	# Pace — pass speed: RETIRED at 1.0 for every tier. Scaling below 1.0
	# under-delivered the solved receiver-relative arrival and passes died
	# short of the tape (missed passes, not softer ones).
	assert_eq(normal.pass_speed_scale, 1.0,
			"Normal launches passes at the full solved pace")
	assert_eq(easy.pass_speed_scale, 1.0,
			"Easy launches passes at the full solved pace")
	# Pace — check aggression: lower hunts fewer body checks.
	assert_lt(normal.check_aggression, hard.check_aggression,
			"Normal hunts fewer checks than Hard")
	assert_lt(easy.check_aggression, normal.check_aggression,
			"Easy hunts fewer checks than Normal")
	# Pace — defensive anticipation: lower sits further behind the play.
	assert_lt(normal.defensive_anticipation_scale, hard.defensive_anticipation_scale,
			"Normal anticipates the play less than Hard")
	assert_lt(easy.defensive_anticipation_scale, normal.defensive_anticipation_scale,
			"Easy anticipates the play less than Normal")


func test_easy_never_hunts_body_checks() -> void:
	# Easy's floor: check_aggression 0.0 is the sentinel for "pure containment,
	# never commit a hit" (evaluate_body_check short-circuits on <= 0.0).
	assert_eq(BotSkillProfile.easy().check_aggression, 0.0,
			"Easy never hunts body checks")


func test_hard_pace_knobs_are_the_no_op_baseline() -> void:
	# Hard must be EXACTLY today's pace by construction: zero extra standoff, full
	# pass speed, full hit-hunting, full anticipation — so the pace levers are a
	# pure softening for the lower tiers and carry zero regression risk on the
	# ceiling.
	var hard: BotSkillProfile = BotSkillProfile.hard()
	assert_eq(hard.pursuit_standoff_m, 0.0, "Hard adds no pursuit standoff")
	assert_eq(hard.pass_speed_scale, 1.0, "Hard moves the puck at full pace")
	assert_eq(hard.check_aggression, 1.0, "Hard hunts checks as today")
	assert_eq(hard.defensive_anticipation_scale, 1.0, "Hard anticipates as today")
	# Same for the finish knobs: no settle beat and the pre-split flat error on
	# both release types, so Hard is byte-identical to the pre-knob bot.
	assert_eq(hard.carry_settle_delay_s, 0.0, "Hard releases the tick the compete fires")
	assert_eq(hard.shot_aim_error_rad, hard.pass_aim_error_rad,
			"Hard keeps the pre-split flat error on both release types")
	# Hard's humanisers are small but real — the whole point of the retune is
	# that even the ceiling tier is no longer tick-and-corner perfect.
	assert_gt(hard.shot_timing_error_s, 0.0,
			"even Hard's release is not tick-perfect")


func test_cognition_gates_close_down_the_tiers() -> void:
	# Hard and Normal are the SAME PLAYER separated only by continuous tuning:
	# every cognition gate matches between them (a tier gap that reads as
	# "sharper", never "knows moves the other doesn't"). Easy is the behaviour
	# floor where the gates close.
	var hard: BotSkillProfile = BotSkillProfile.hard()
	var normal: BotSkillProfile = BotSkillProfile.normal()
	assert_eq(normal.reads_goalie_motion, hard.reads_goalie_motion,
			"Normal reads the moving goalie exactly as Hard does")
	assert_eq(normal.holds_for_developing_feeds, hard.holds_for_developing_feeds,
			"Normal holds for developing plays exactly as Hard does")
	assert_eq(normal.angles_the_chase, hard.angles_the_chase,
			"Normal angles its chase exactly as Hard does")
	assert_eq(normal.plays_rush_pass_lanes, hard.plays_rush_pass_lanes,
			"Normal plays odd-man pass lanes exactly as Hard does")
	assert_eq(normal.protects_the_puck, hard.protects_the_puck,
			"Normal shields the puck exactly as Hard does")
	assert_eq(normal.reads_receiver_commitment, hard.reads_receiver_commitment,
			"Normal reads receiver commitment exactly as Hard does")
	assert_true(hard.reads_goalie_motion, "the shared ceiling is the full hockey IQ")
	assert_true(hard.reads_receiver_commitment,
			"the shared ceiling reads receiver commitment")
	var easy: BotSkillProfile = BotSkillProfile.easy()
	assert_false(easy.reads_goalie_motion, "Easy is goalie-motion blind")
	assert_false(easy.holds_for_developing_feeds, "Easy plays only what exists now")
	assert_false(easy.angles_the_chase, "Easy chases in a straight line")
	assert_false(easy.reads_receiver_commitment,
			"Easy is commitment-blind — it chucks feeds at turning players")


func test_pass_error_never_exceeds_shot_error() -> void:
	# The split's whole point: completed passes are fun to play against, every
	# shot going in is not — so a tier may never spray its passes harder than
	# its shots.
	for profile: BotSkillProfile in [BotSkillProfile.easy(), BotSkillProfile.normal(), BotSkillProfile.hard()]:
		assert_lte(profile.pass_aim_error_rad, profile.shot_aim_error_rad,
				"pass aim error stays at or below shot aim error at every tier")


func test_dispatch_period_is_at_least_one_tick() -> void:
	# A zero/negative cadence would stall the throttle (dispatch_period - 1).
	for profile: BotSkillProfile in [BotSkillProfile.easy(), BotSkillProfile.normal(), BotSkillProfile.hard()]:
		assert_gte(profile.dispatch_period_ticks, 1)


func test_puck_protection_is_tiered() -> void:
	# Shielding the puck with the body is a taught fundamental: Hard and Normal
	# protect (blade to the seam under pressure, seam-directed deke); Easy
	# carries naively presented in front so a newcomer's poke-check works.
	assert_true(BotSkillProfile.hard().protects_the_puck,
			"Hard shields the puck with its body")
	assert_true(BotSkillProfile.normal().protects_the_puck,
			"Normal shields the puck — a youth-hockey fundamental")
	assert_false(BotSkillProfile.easy().protects_the_puck,
			"Easy concedes the pickpocket by design")


func test_rush_pass_lane_read_is_tiered() -> void:
	# Playing the pass on an odd-man rush is youth-hockey fundamentals: Hard
	# and Normal read it; Easy retreats on the carrier line so a newcomer's
	# cross-crease 2-on-1 feed connects.
	assert_true(BotSkillProfile.hard().plays_rush_pass_lanes,
			"Hard plays the pass on odd-man rushes")
	assert_true(BotSkillProfile.normal().plays_rush_pass_lanes,
			"Normal plays the pass on odd-man rushes")
	assert_false(BotSkillProfile.easy().plays_rush_pass_lanes,
			"Easy concedes the odd-man feed by design")
