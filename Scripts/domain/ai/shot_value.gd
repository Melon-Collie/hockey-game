class_name AIShotValue

# THE SEAM. One function the whole decision layer asks "how good is a shot from
# here", and one function that answers it. Everything the bots rank — carry
# candidates, pass receivers, off-puck seams, the shoot/don't gate — goes
# through `for_release`, so replacing the model behind it is a one-line change
# rather than surgery across a dozen call sites with eighteen positional
# arguments each.
#
# That narrowness is the point and it is deliberate insurance: this model is
# knowingly an APPROXIMATION, adopted while the live goalie is being retuned.
# When he settles we re-measure, and either it holds or it is swapped. Neither
# outcome should cost more than editing this file.
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
# Deliberately NOT modelled yet, in rough order of how much I expect them to
# matter: the DOWN (butterfly) state, the RVH/VH post seal, and screens. All
# three are whole-goalie states rather than body parts, so they fit this
# model's grain and can be added as further logit terms. They are out of v1
# because the point of v1 is to find out whether the simple thing suffices.
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


# THE ENTRY POINT. Probability that a shot released at `release` toward
# `attacking_goal` beats a keeper displaced `displacement_m` off his square.
# Shot type is the same enum XGBaseline takes, so a one-timer or a tip carries
# its bump here too.
static func for_release(release: Vector3, attacking_goal: Vector3,
		displacement_m: float,
		shot_type: int = ShotEvent.ShotType.SHOT) -> float:
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
