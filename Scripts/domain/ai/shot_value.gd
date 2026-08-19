class_name AIShotValue

# THE SEAM. Everything the bots rank — carry candidates, pass receivers, off-puck
# seams, the shoot/don't gate — asks "how good is a shot from here" through
# `for_release`, so the model behind it can be replaced in this file alone. That
# narrowness is deliberate insurance: the model is knowingly an APPROXIMATION,
# adopted while the live goalie is being retuned.
#
# ── The model ────────────────────────────────────────────────────────────────
# XGBaseline's public form — a logistic in log-distance and angle — plus ONE
# feature: how far the keeper has been displaced off the square he needs.
#
#   logit = XGBaseline.logit_for_shot(...) + DISPLACEMENT_LOGIT_PER_M · deficit
#
# It literally extends the baseline's logit rather than re-deriving it, so at
# zero displacement the two are the same number by construction (asserted in
# tests/unit/ai/test_shot_value.gd). "The public model plus one feature" is a
# structural fact here, not a description.
#
# ── Why the public form is the right base ────────────────────────────────────
# The target is an NHL-quality keeper. Against one, an NHL-calibrated model is
# correct BY CONSTRUCTION — its apparent miscalibration against the current
# goalie (predicting ~0.09 where the grid measures 0.438) is a statement about
# him, not about the form. And it has the property the five-hole geometry never
# had: it is smooth and monotone, so the DIFFERENCE between two nearby spots is
# meaningful. That is the only quantity a carry beam consumes, and a surface
# built from a max over five holes with structural cliffs cannot supply it.
#
# ── Why displacement is the one feature that must be added ───────────────────
# The public form marginalises the goalie away. That is right for a season-long
# stat and fatal for a decision: two spots two metres apart score identically,
# so moving the keeper buys nothing and the argmax falls through to whatever
# tie-breakers are left. Displacement is what makes "make him move" scoreable,
# and it is measurable rather than assumed — see displacement_deficit_m.
#
# Deliberately NOT modelled: the DOWN (butterfly) state and screens. Both are
# whole-goalie states rather than body parts, so they fit this model's grain and
# drop in as further logit terms when something measures them.
#
# Pure/static and engine-free, like every other domain evaluator.

# Log-odds added per metre the keeper is displaced off his square.
#
# Provenance, to the same standard as XGBaseline's own coefficients: solved to
# reproduce a known public aggregate rather than picked. The public proxies for
# "the keeper is not set" are the rebound and cross-ice-pass (royal road)
# features, which carry roughly a 3x odds multiplier in fitted models. A keeper
# displaced by his own cover half-width (~0.85 m) is beaten to that side, which
# is the situation those features describe — so ln(3) / 0.85 ≈ 1.3 per metre.
const DISPLACEMENT_LOGIT_PER_M: float = 1.3

# Displacement stops buying anything once he is off the near post: past that
# the side is simply open, and the net's own width bounds how much more the
# geometry can give. Clamped rather than allowed to run, so a wildly displaced
# keeper reads as "beaten" and not as a certainty the finite mouth cannot
# actually deliver.
const MAX_USEFUL_DISPLACEMENT_M: float = GameRules.NET_HALF_WIDTH

# A post seal (RVH/VH) walls the NEAR half of the mouth: the keeper is already
# deployed against the post the shot has to beat, with no reaction left to
# race. Only the far half is a target.
#
# The coefficient is ln(2) and it is geometry rather than a tunable: to a first
# approximation a shot's chance scales with the target width available to it,
# so removing half the mouth halves the odds, and halved odds is exactly
# -ln(2) of logit. No fitting, nothing to tune.
#
# v1 does not distinguish VH from RVH. VH stands the near column ice-to-
# shoulder while RVH stays compressed and concedes the short-side high — so
# the true RVH penalty is smaller than a full halving. Treating both as half
# the mouth is a known over-penalty on RVH, deferred rather than guessed,
# because splitting them needs the band structure this model deliberately
# does not carry.
const POST_SEAL_LOGIT: float = -0.6931472


# THE ENTRY POINT. Probability that a shot released at `release` toward
# `attacking_goal` beats a keeper displaced `displacement_m` off his square.
# Shot type is the same enum XGBaseline takes, so a one-timer or a tip carries
# its bump here too.
static func for_release(release: Vector3, attacking_goal: Vector3,
		displacement_m: float,
		shot_type: int = ShotEvent.ShotType.SHOT,
		into_post_seal: bool = false) -> float:
	# No shot exists from on or behind the goal line — the mouth faces away, and
	# every downstream consumer relies on this being hard zero rather than a
	# small number the argmax can be lured by.
	if (release.z - attacking_goal.z) * -signf(attacking_goal.z) < 0.001:
		return 0.0
	var team_id: int = 1 if attacking_goal.z > 0.0 else 0
	var logit: float = XGBaseline.logit_for_shot(
			release.x, release.z, team_id, shot_type)
	logit += DISPLACEMENT_LOGIT_PER_M * clampf(
			displacement_m, 0.0, MAX_USEFUL_DISPLACEMENT_M)
	if into_post_seal:
		logit += POST_SEAL_LOGIT
	return XGBaseline.sigmoid(logit)


# How far the keeper will be from the square he NEEDS, at the moment the shot
# is released — the physical quantity the model's one extra feature reads.
#
#   deficit = |where he must be − where he is| − |how far he can push by then|
#
# Both halves are measured, not fitted. The demand is the arc-match square for
# the release point (AIActionScoring.goalie_arc_match_x, the same solve the
# live keeper skates); the supply is his real accel-limited T-push over the
# time he has after his reaction delay (goalie_lateral_reach). Floored at zero:
# a keeper who can comfortably get there is simply set, and there is no such
# thing as negative displacement.
#
# This is also why the model survives the goalie being retuned. It reads his
# KINEMATICS — push speed, accel ramp, reaction delay, all published in
# GameRules — and never his anatomy, which is the part under repair.
static func displacement_deficit_m(keeper_pos: Vector3,
		attacking_goal: Vector3, release: Vector3,
		time_to_release_s: float) -> float:
	var need: float = absf(AIActionScoring.goalie_arc_match_x(
			keeper_pos, attacking_goal, release) - keeper_pos.x)
	var move_time: float = maxf(
			0.0, time_to_release_s - AIActionScoring.goalie_leg_delay_s)
	return maxf(0.0, need - AIActionScoring.goalie_lateral_reach(move_time))
