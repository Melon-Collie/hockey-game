class_name AIActionScoring

# Pure-function utility scoring for on-puck actions. Each score is a
# multiplicative composition of factors in [0, 1].
#
# ── Design intent: heuristic xG ──────────────────────────────────────────────
# `score_shoot` is a hand-coded approximation of expected goals (xG) — the
# probability that a given shot becomes a goal given its geometry and the
# defensive context. It is xG-SHAPED (peak in the slot, drops with
# distance / angle / coverage / pressure / lane traffic) but NOT magnitude-
# calibrated against real-world data: a clean slot wrister scores ~0.7
# here; the real-world xG would be closer to 0.30. Treat the outputs as
# RELATIVE shot quality, not actual goal probability.
#
# Everything else cascades from xG-shape:
#   - `score_pass` = lane-clear × `score_shoot(receiver)` — a pass is
#     only valuable if the receiver has a higher-quality shot than us.
#   - `score_at(pos)` = max(`score_shoot(pos)`, carry-to-slot) — used by
#     the carrier's CARRY candidates: a position is good if it offers a
#     better future shot, OR it brings us toward a position that does.
#
# When tuning constants, ask "would this change make the shot quality
# rank ordering match a human's read of those scenarios?", not "does
# this number feel right in isolation". A learned xG model (baked grid
# from playtest data) is a future replacement for `score_shoot`.
#
# Two leaf scorers (score_shoot, score_pass) plus a recursive depth-2
# score_at(pos) defined in the SM. Top-level options compete uniformly:
#
#   shoot:  score_shoot(self_pos)
#   pass:   score_at(receiver_lead) × lane_clear × time_factor
#   carry:  score_at(candidate)     × path_clearance × time_factor
#
# score_at(pos) = max(score_shoot(pos), carry_to_slot_from_pos)
#
# No leaf-pass term inside score_at — at depth 2 we only consider the
# receiver's shot and their carry-to-slot. Stops the bot from
# evaluating chains of passes (which can run away into mutual
# back-and-forth pass loops) and bounds the recursion cleanly.
#
# No dump scoring — 3v3 doesn't reward dumps. No open-man / advance /
# receiver_pressure heuristics — the recursive score_at captures
# "what could the receiver do" with their actual options.

# An opponent within this distance counts toward "pressure" on a target.
# Tuning: raise toward 5 if bots feel oblivious to nearby defenders;
# lower toward 3 if pressure trips on too-distant marks.
const PRESSURE_RADIUS_M: float = 4.0
# How many opponents within radius == fully pressured (score multiplier 0).
# Two dead-on forward-cone opponents at full weight saturate. Raise
# toward 3 to make pressure harder to saturate (less trigger-happy);
# lower toward 1 to pressure on a single defender.
const PRESSURE_MAX_COUNT: int = 2

# Distance scaler for the dist_response curve. Beyond this distance,
# shot quality from distance alone is 0 — geometrically rooted at the
# attacking-zone span (blue line to opposing goal line). A shot from
# the attacking blue line is the longest realistic in-possession shot
# in hockey; anything from the neutral zone is a dump-in, not a shot.
# Tracks rink resizes automatically.
#
# The dist_response is monotone (closer = always better) and quadratic
# from goal: 1.0 at the goal mouth, 0.0 at SHOT_RANGE_FALLOFF_M. There
# is no "ideal distance" peak — the goalie pressure zone (below)
# penalises shots from inside the goalie's setup line, which is what
# stops bots from grinding into the crease. The shooter-position
# projection in carrier.gd (release-pos = current + velocity × charge
# lookahead) handles the in-motion case. Together those two mechanics
# replace the bidirectional peak that earlier versions had.
const SHOT_RANGE_FALLOFF_M: float = GameRules.GOAL_LINE_Z - GameRules.BLUE_LINE_Z

# Position-potential closeness ramp. position_potential is only used
# by `_score_at` when the EVALUATOR is outside SHOT_RANGE_FALLOFF_M —
# inside that range the bot is committed to a shot and uses score_shoot
# alone. So closeness only needs to give a sensible "anywhere on the
# rink toward the slot is better than further away" gradient for
# positioning bots.
#
# Closeness ramps linearly: 1.0 at the slot (peak), 0.0 at the
# goal-to-goal distance (rink length, derived from
# GameRules.GOAL_LINE_Z * 2 — about 53 m). Inside the slot it ramps
# back down to 0 at the goal mouth, so a hypothetical "carry past the
# slot" candidate scores worse than the slot itself.
#
# SLOT_RADIUS_M is the platform width — positions within this distance
# of the goal are all peak-value. Tuning: up (8 m) makes the gradient
# pull bots from further out; down (4 m) tightens the sweet spot.
const SLOT_RADIUS_M: float = 6.0

# Shot-quality coverage knobs. The two-angle model:
#   coverage   = BASE_COVERAGE × squareness
#   squareness = max(0, 1 - arc_offset / SQUARENESS_OFFSET_RAD)
# where arc_offset is |puck_arc_angle - goalie_arc_angle| at shot
# release. A squared goalie blocks BASE_COVERAGE of the visible net;
# arc_offset >= SQUARENESS_OFFSET_RAD = goalie fully exposed (open
# net). Replaces the legacy shadow-projection openness + linear
# angle-ramp pair.
#
# Tuning: BASE_COVERAGE down (e.g., 0.30) → bots take more shots vs
# squared goalies; up (0.45) → bots pass/cycle more. SQUARENESS_OFFSET
# down (e.g., 25°) → cross-seam plays score higher (goalie reads as
# "exposed" sooner); up (40°) → only severe slides expose the goalie.
const BASE_COVERAGE: float = 0.28
const SQUARENESS_OFFSET_RAD: float = 0.5235988  # deg_to_rad(30)

# Goalie position prediction. Replaces velocity-extrapolation with a
# react-then-slide model: react delay first, then move toward the
# puck-at-release X at max lateral speed.
#
# GOALIE_REACTION_DELAY_S and GOALIE_MAX_LATERAL_SPEED_MPS both
# reference GameRules so the AI prediction stays in lockstep with
# the live goalie. Lateral speed mirrors GoalieController.t_push_speed
# specifically — that's the goalie's real translation speed when
# committing to a slide (lateral_threshold = 0.3 m). NOT
# tracking_speed (the mental-target lerp speed, not body movement)
# and NOT shuffle_speed (small adjustments, not a recovery slide).
const GOALIE_REACTION_DELAY_S: float = GameRules.DEFAULT_GOALIE_REACTION_DELAY_S
const GOALIE_MAX_LATERAL_SPEED_MPS: float = GameRules.DEFAULT_GOALIE_T_PUSH_SPEED_M_S

# Shadow half-width used by AIShotAim.compute_open_net_aim for the
# lane-check aim point. Independent of the new coverage model — it
# just picks an aim point past the goalie for the segment check.
const GOALIE_SHADOW_HALF_M: float = 0.3

# ── Goalie-in-motion penalty (reward forcing the goalie to move) ──────────────
# The squareness term models the goalie's POSITION at release but not its
# degraded SAVE while still recovering. The real goalie reads the shot late when
# caught moving / unset (GoalieController + goalie_behavior_rules) — a weakness
# the position-only model misses, so the AI under-rates plays that keep the
# goalie sliding (cross-seam one-timers especially, where the goalie can't
# re-square inside the pass flight). goalie_unsettled() ramps 0→1 with how
# mid-slide / just-arrived the predicted goalie is, and score_shoot scales
# coverage down by GOALIE_MOTION_PENALTY × unsettled — so a shot that catches the
# goalie moving rates higher, exactly as it does in real play. This imports the
# goalie's EXISTING weakness into the bot's model; it does not change the goalie.
#
# Tuning: PENALTY up → bots hunt moving-goalie looks (cross-seam one-timers)
# harder; down → closer to the old position-only model (0.0 = identical).
# SETTLE_REF_S is how long the goalie must sit stopped at its target before the
# model treats it as fully re-set — longer keeps motion credit alive briefly
# after the slide, rewarding a quick follow-up.
const GOALIE_MOTION_PENALTY: float = 0.6
const GOALIE_SETTLE_REF_S: float = 0.20

# Goalie pressure zone — narrow rectangle in front of the goalie's
# CURRENT (squared-to-puck) position. Penalizes score_shoot when the
# shooter sits inside it. Models the hockey intuition that shooting
# from where the goalie is currently set up is hard; extending the
# goalie laterally with a pass, or backing off the line, creates a
# better chance.
#
# Anchored on the goalie's CURRENT position (not the predicted-at-
# release one) so a back-door receiver — off-axis from the carrier's
# lane, which is what the goalie is currently squared to — sits
# outside the zone and isn't penalized. A carrier driving on-axis
# toward net is in the same goalie's pressure line → inside zone.
#
# Half-width 1 m × depth 3.5 m: covers roughly stick-reach laterally
# and the close-shot range in depth. Slot (5 m from goal ≈ 4.35 m
# from goalie) sits just outside the depth, so slot shots aren't
# penalized; only "drove past slot" carries land in the zone.
const GOALIE_ZONE_HALF_WIDTH_M: float = 1.0
const GOALIE_ZONE_DEPTH_M: float = 3.5
const GOALIE_ZONE_MAX_PENALTY: float = 0.8

# ── Lane interception: closest-approach reachability model ───────────────────
# A fired puck (shot or pass) travels the straight segment from→to at
# `puck_speed`. A defender intercepts iff they can get a stick onto the
# puck's PATH at the moment the puck is there. We solve this per defender
# as a closest-approach problem between two moving points:
#
#   puck(τ)     = from + dir·speed·τ                 (τ ∈ [0, T], T = len/speed)
#   defender(τ) = D + V·τ                            (dead-reckoned momentum)
#   τ*          = argmin |puck(τ) − defender(τ)|     (closest approach, clamped)
#   miss        = |puck(τ*) − defender(τ*)|
#   reach(τ*)   = REACH + CLOSE_SPEED · max(0, τ* − REACTION)
#   block       = clamp((reach − miss) / REACH, 0, 1)
#
# This REPLACES the old separable `perp_factor × reaction_factor` product,
# which multiplied "how close to the line" by "how much flight time" — so a
# defender draped on the carrier (dead on the line, but low flight-time
# because they sit near the release) scored block ≈ 0, `lane_clear` read ≈ 1,
# and the pass turnover cost collapsed to zero. Posing it as reachability
# fixes that at the root: a defender already within a stick of the path
# blocks fully regardless of timing (no closing required), while a defender
# off the path must physically close the gap (CLOSE_SPEED × available time)
# before the puck passes. It is also VELOCITY-AWARE — a defender bearing down
# on the lane is dead-reckoned INTO it (higher block); one drifting away is
# credited less — which the old position-only model could not express.
#
# Faster pucks still thread better for free: a shorter flight T leaves less
# time to close, shrinking reach. All three parameters are physical, not
# feel-tuned:
#   REACH       — blade reach of a lane defender (stick length).
#   REACTION    — competitive read delay before they start closing (~2 ticks
#                 at 30 Hz; not the 0.15 s "casual" delay that let passes
#                 leak through).
#   CLOSE_SPEED — a defender's lateral adjustment pace. About half top skating
#                 speed: they pivot / crossover into the lane, they do not
#                 straight-line sprint at it.
const LANE_DEFENDER_REACH_M: float = GameRules.DEFAULT_STICK_LENGTH_M
const LANE_REACTION_DELAY_S: float = 0.08
const LANE_DEFENDER_CLOSE_SPEED_M_S: float = 0.5 * GameRules.DEFAULT_SKATER_MAX_SPEED_M_S

# A saucer pass lifts over a grounded stick but NOT a body — it's hard to
# react a blade up into a puck flying overhead, but you can't fly it
# through a torso. So in the airborne stretch of a saucer's flight a
# defender's reach collapses to their BODY radius: no stick extension, no
# closing. A defender standing dead in the lane still blocks the saucer; a
# stick-poke-range defender no longer does. Matches the skater collision-
# cylinder radius (GameRules canonical body half-width).
const LANE_DEFENDER_BODY_RADIUS_M: float = GameRules.OFFSIDE_LINE_SLACK

# Puck release speed assumptions for lane-clear reaction-window math.
# `puck.release(direction, power)` consumes `direction × power` as
# linear velocity directly (see Puck.release), so "power" IS m/s.
# Sourced from GameRules so the AI's lane reaction window matches
# the live shot mechanics. score_shoot defaults to wrister speed;
# score_pass uses pass speed (which is quick_shot_power — short
# passes in this codebase are mechanically quick-shots, long ones
# get wrister-charged for more pace — see PASS_CHARGE_SPEED_M_S /
# expected_pass_speed).
const WRISTER_SHOT_SPEED_M_S: float = GameRules.DEFAULT_WRISTER_POWER_MAX_M_S
const SLAPPER_SHOT_SPEED_M_S: float = GameRules.DEFAULT_SLAPPER_POWER_MAX_M_S
const PASS_SPEED_M_S: float = GameRules.DEFAULT_QUICK_SHOT_POWER_M_S

# Distance ramp for pass LAUNCH speed. Short feeds stay soft (snap speed) so a
# close pass isn't a rocket the receiver can't corral; longer passes ramp up for
# pace, shrinking a defender's reaction window. Continuous (smoothstep) rather
# than the old binary cliff at a single distance.
#
# Why a direct distance ramp and not friction/arrival-speed math: the puck
# sheds little speed over a pass (GameRules.PUCK_ICE_DECEL_M_S2 ≈ 1 m/s² — e.g. a
# 26 m pass loses only ~1–2 m/s), so arrival speed ≈ launch speed at realistic
# distances. Backing a launch out of a target arrival speed would therefore
# collapse to a near-constant ~snap speed and leave long passes too soft to beat
# interception. Distance is the right axis directly: a long pass can be fast
# because its longer flight gives the receiver time to square up.
const PASS_RAMP_SHORT_DISTANCE_M: float = 10.0   # ≤ this → soft snap pass
const PASS_RAMP_LONG_DISTANCE_M: float = 26.0    # ≥ this → full long-pass pace
const PASS_RAMP_LONG_SPEED_M_S: float = 20.0     # launch target for a long pass

# Reference charged-pass speed (~mid-ramp). No longer a fixed release target —
# pass speed is distance-adaptive via pass_launch_speed — but kept as a
# representative pass speed for lane/threat tests and any caller that wants a
# single "typical charged pass" number.
const PASS_CHARGE_SPEED_M_S: float = (
		GameRules.DEFAULT_WRISTER_POWER_MIN_M_S
		+ (GameRules.DEFAULT_WRISTER_POWER_MAX_M_S
				- GameRules.DEFAULT_WRISTER_POWER_MIN_M_S) * 0.5)

# Distance-adaptive pass LAUNCH speed: snap-soft for short feeds, ramping to
# PASS_RAMP_LONG_SPEED_M_S for long passes, smooth between. Clamped to max_launch
# — the passer's own max wrister (its hardest possible pass), or the league
# default for opponent threat modeling.
#
# speed_scale is the difficulty pace knob (BotSkillProfile.pass_speed_scale),
# applied AFTER the clamp so an easier bot's passes can drop below the snap floor
# — that's the point: a slower puck the human can read and pick off. Defaults to
# 1.0, so the cross-player threat model (expected_pass_speed) and all unscaled
# callers are byte-for-byte unchanged.
static func pass_launch_speed(distance: float, max_launch: float,
		speed_scale: float = 1.0) -> float:
	var t: float = smoothstep(PASS_RAMP_SHORT_DISTANCE_M, PASS_RAMP_LONG_DISTANCE_M, distance)
	var target: float = lerpf(PASS_SPEED_M_S, PASS_RAMP_LONG_SPEED_M_S, t)
	return clampf(target, PASS_SPEED_M_S, max_launch) * speed_scale

# ── Saucer pass ──────────────────────────────────────────────────────────────
# A saucer (elevated) pass lofts the puck off the ice so it flies over a
# defender's grounded stick mid-lane and settles back down near the
# receiver. The lane-interception model treats this as: defenders in the
# MID-LANE airborne window can't pick the puck off (it's over their
# blade), but defenders close to the passer (puck hasn't lofted yet) or
# close to the receiver (puck has landed) still block normally.
#
# Airborne span as a fixed DISTANCE off the passer's blade, NOT a fraction
# of the flight. A saucer is a low flip: it clears stick height for a short
# stretch, lands, and slides the rest grounded — it does not stay aloft the
# whole way (and we can't know the live loft, since the shared elevation
# mechanic aims at the goal line, not the receiver). So the puck is treated
# as airborne — clears a grounded stick, only a body blocks — only within
# this distance of the passer; past it the puck has landed and a stick
# intercepts normally. Modelling it as a distance (not a fraction) keeps
# the grounded zone honest: a defender 7 m out blocks a saucer whether the
# pass is 12 m or 25 m. Deliberately conservative.
const SAUCER_AIRBORNE_DISTANCE_M: float = 4.0

# Saucer only wins over a grounded pass when it clears the lane by at
# least this much (lane_clear delta, 0..1). Below it the loft isn't worth
# the extra flight time / reception fiddliness, so the bot stays grounded.
const SAUCER_LANE_BENEFIT_MARGIN: float = 0.20

# If the grounded lane is already this clear, never bother with a saucer —
# there's no defender worth lofting over.
const SAUCER_SKIP_WHEN_LANE_CLEAR: float = 0.85

# Minimum pass distance for a saucer. Saucers are a stretch-pass tool — lofting
# over a mid-lane defender only makes sense when there's a real lane to clear;
# short feeds stay grounded regardless of pace.
const SAUCER_MIN_DISTANCE_M: float = 10.0


# Returns the LAUNCH speed a pass from `shooter` to `receiver` will fire at —
# distance-adaptive (see pass_launch_speed): soft for short feeds, harder for
# long passes so they still arrive at a comfortable pace. Capped at the league
# default max wrister here; the passer's own scoring/execution uses its own max
# (ctx.self_wrister_shot_speed). Used by both offensive scoring (lead / lane
# math) and defensive scoring (threat_surface_pass assuming opponents play the
# same way).
static func expected_pass_speed(shooter: Vector3, receiver: Vector3) -> float:
	return pass_launch_speed(shooter.distance_to(receiver), GameRules.DEFAULT_WRISTER_POWER_MAX_M_S)


# Reference top skating speed. Single source of truth shared with
# SkaterController.max_speed via GameRules.DEFAULT_SKATER_MAX_SPEED_M_S.
# Used by time_to_arrive() for momentum-aware ETAs across every role
# behavior + chase intercept lookahead.
#
# TODO(per-player attrs): when SkaterAttributes lands, swap call
# sites for `attribute_resolver.call(peer_id).max_speed` so an
# evaluator reasoning about a fast/slow opponent uses the right
# top speed. This const becomes the league-average fallback.
const SKATER_REF_SPEED_M_S: float = GameRules.DEFAULT_SKATER_MAX_SPEED_M_S

# Approximate kinematic stopping time for a skater steering against
# their own velocity. Derived from the friction model in
# SkaterController (drag = friction + friction_drag × |v| ≈ 3.6 m/s²
# at top speed) plus reverse-thrust steering. Used by OUTLET's
# offside filter to project a candidate forward by current velocity:
# if "where I'd be in BRAKE_TIME_S given current momentum" is past
# the blue line, the candidate is rejected as effectively offside.
# Pure kinematic — the constant is "how long does momentum dominate
# steering," not a behavioral knob.
const SKATER_BRAKE_TIME_S: float = 0.3

# Floor for momentum-adverse `time_to_arrive` returns. When the
# velocity component along the destination is so negative that
# effective_speed would go non-positive, clamp at this minimum so
# reverse candidates have finite (large) ETAs rather than infinite
# decay. 1.0 m/s ≈ "I have to brake and reverse, but I'll get there
# eventually."
const MIN_TRAVEL_SPEED_M_S: float = 1.0

# Utility-AI knobs. AIRoleCarrier._pick_action re-runs every
# PICK_ACTION_PERIOD_TICKS physics ticks and treats
# CARRY as a fourth competing option scored as
#
#   carry_score = score_at(destination) × discount(time_to_destination)
#
# CARRY_DELAY_DISCOUNT_PER_SEC — per-second decay applied to a future
# action's value. 0.7 / sec gives a ~2-second half-life. Reflects
# compounding uncertainty over time: the further out an action, the
# less sure we are it'll unfold as scored, so its expected value
# decays. Applies uniformly to carry travel time and pass flight
# time. Raise toward 0.85 to make bots more patient on long-horizon
# plans; lower toward 0.55 to prioritise immediate actions over
# distant ones more aggressively.
#
# ACTION_HYSTERESIS_MARGIN — once a fire intent is set, that intent
# gets this bonus when re-scored. Prevents flicker between two
# close-scoring fire options during pre-aim. Only applies to fire
# intents (SHOOT, SLAPPER, PASS) — CARRY doesn't get a bonus, so the
# bot is free to switch to fire as soon as fire scores higher.
# Raise toward 0.10 if intent flickers visibly; lower toward 0.02 if
# intent feels too sticky.
const CARRY_DELAY_DISCOUNT_PER_SEC: float = 0.7
const ACTION_HYSTERESIS_MARGIN: float = 0.05


# Returns SHOOT score in [0, 1] using the two-angle coverage model:
#
#   shot_quality = dist_response × shot_angle_factor × (1 - coverage)
#   coverage     = BASE_COVERAGE × squareness
#   squareness   = max(0, 1 - arc_offset / SQUARENESS_OFFSET_RAD)
#
#   dist_response     = monotone quadratic from goal (1.0 at goal mouth, 0.0 at SHOT_RANGE_FALLOFF_M)
#   shot_angle_factor = 1 - (shot_angle / (PI / 2))²                   (quadratic)
#   puck_arc_angle    = atan2(shooter.x - goal.x, abs(shooter.z - goal.z))
#   goalie_arc_angle  = atan2(goalie_at_release.x - goal.x, ...)
#   arc_offset        = |puck_arc_angle - goalie_arc_angle|
#
# `predicted_goalie_pos` is the goalie's predicted position at shot
# release (use `predict_goalie_pos` to compute). The squareness term
# makes shots that catch the goalie sliding (cross-seam, late
# rotation) score above the BASE_COVERAGE penalty — automatic
# discount for "open net" plays without a separate heuristic.
#
# Final score also multiplies by lane clearance and inverse pressure
# (unchanged from prior implementation).
static func score_shoot(
		shooter: Vector3,
		attacking_goal: Vector3,
		predicted_goalie_pos: Vector3,
		net_half_width: float,
		opponents: Array[Vector3],
		goalie_current_pos: Vector3 = Vector3.INF,
		shot_speed_m_s: float = WRISTER_SHOT_SPEED_M_S,
		goalie_unsettled_factor: float = 0.0) -> float:
	# Hard gate: shooter past (or on) the attacking goal line can't
	# shoot in — wraparound territory, returns 0 immediately.
	var net_normal_z: float = -signf(attacking_goal.z)
	var forward: float = (shooter.z - attacking_goal.z) * net_normal_z
	if forward < 0.001:
		return 0.0

	# Distance response — monotone quadratic falloff from goal. 1.0 at
	# the goal mouth, 0.0 at SHOT_RANGE_FALLOFF_M (= attacking blue
	# line). The "no peak" model relies on two other mechanics to stop
	# bots from grinding into the crease:
	#   1. The goalie pressure zone penalty (further down) discounts
	#      shots from inside the goalie's setup line — that's the
	#      authoritative "too close" signal.
	#   2. The carrier scorer (carrier.gd) projects the shooter forward
	#      by velocity × charge_lookahead before scoring, so a moving
	#      bot scores its release-pos rather than current pos. This
	#      lifts in-motion-toward-slot scores naturally.
	var dist: float = shooter.distance_to(attacking_goal)
	var dist_norm: float = clampf(dist / SHOT_RANGE_FALLOFF_M, 0.0, 1.0)
	var dist_response: float = 1.0 - dist_norm * dist_norm

	# Puck arc angle: atan2 of lateral offset over forward distance.
	# Range [-PI/2, +PI/2] given the forward gate above.
	#
	# Quadratic-soften (1 - x²) instead of linear (1 - x): a human reads
	# slightly off-center as still a great shot — at 30° off-center the
	# linear curve gave 0.67, quadratic gives 0.89. Truly bad-angle
	# shots (>= 75°) still fall to ≤ 0.31 so the bot doesn't shoot
	# from the corners. Ease the curve toward `1 - 0.7 × x²` if bots
	# start firing wide-angle pucks from distance.
	var puck_arc_angle: float = atan2(shooter.x - attacking_goal.x, forward)
	var shot_angle: float = absf(puck_arc_angle)
	var arc_norm: float = clampf(shot_angle / (PI * 0.5), 0.0, 1.0)
	var shot_angle_factor: float = 1.0 - arc_norm * arc_norm

	# Goalie arc angle at release. If the goalie ended up behind their
	# own goal line (degenerate edge — shouldn't happen in normal play),
	# treat as squared at center.
	var goalie_forward: float = (predicted_goalie_pos.z - attacking_goal.z) * net_normal_z
	var goalie_arc_angle: float
	if goalie_forward < 0.001:
		goalie_arc_angle = 0.0
	else:
		goalie_arc_angle = atan2(predicted_goalie_pos.x - attacking_goal.x, goalie_forward)

	var arc_offset: float = absf(puck_arc_angle - goalie_arc_angle)
	var squareness: float = maxf(0.0, 1.0 - arc_offset / SQUARENESS_OFFSET_RAD)
	# A goalie caught mid-slide / just-arrived saves worse than a set one even at
	# the same angle (reads the shot late) — scale coverage down by how unsettled
	# it is. Default 0.0 leaves the position-only model untouched for callers that
	# don't pass it (existing tests, off-puck role scoring).
	var coverage: float = (BASE_COVERAGE * squareness
			* (1.0 - GOALIE_MOTION_PENALTY * goalie_unsettled_factor))
	var shot_quality: float = dist_response * shot_angle_factor * (1.0 - coverage)

	# Lane clear vs the actual aim point ShotAim would pick (past the
	# goalie's shadow). Defenders close to the shooter (low t along
	# the shot path) have little reaction time and barely contribute;
	# defenders mid-line have full intercept weight. Shots travel fast
	# enough (~30 m/s) that even mid-line defenders only marginally
	# block — `lane_clear` does the per-defender reaction-window math.
	var aim: Vector3 = AIShotAim.compute_open_net_aim(
			shooter, predicted_goalie_pos, attacking_goal.z,
			net_half_width, GOALIE_SHADOW_HALF_M)
	var lane: float = lane_clear(shooter, aim, opponents, shot_speed_m_s)

	# Directional pressure: only opponents in the forward cone toward
	# the attacking goal disrupt the shot. Behind/beside ones don't
	# really stop the release — the threat is bodies between us and
	# the net.
	var pressure_factor: float = 1.0 - _pressure(shooter, opponents, attacking_goal - shooter)

	# Goalie pressure zone — when the caller provides the goalie's
	# CURRENT position (squared to the puck holder), penalize shots
	# from inside the goalie's narrow forward zone. Default sentinel
	# (Vector3.INF) skips this for backward compat.
	var goalie_zone_factor: float = 1.0
	if goalie_current_pos.is_finite():
		goalie_zone_factor = 1.0 - goalie_zone_penalty(shooter, goalie_current_pos)

	return shot_quality * lane * pressure_factor * goalie_zone_factor


# Quick-shot variant of score_shoot. Identical scoring shape, two
# parameter swaps:
#   - predicted_goalie_pos = goalie_now (no charge window means the
#     goalie has zero reaction time to slide before the puck is gone)
#   - shot_speed = PASS_SPEED_M_S (quick-shot release speed)
#
# Most of the quick-shot's tactical signature falls out of the speed
# swap inside lane_clear: slower puck → more reaction time for
# defenders → lanes naturally close at longer range. There's no
# explicit distance cutoff because the lane math already prices it.
# Reward for catching a still-squared goalie comes from squareness
# being measured against the current goalie position (no slide), so
# arc_offset is small and coverage stays high — unless the bot is
# off-axis, in which case the still-squared goalie is exposed to
# them and the score goes up.
static func score_quick_shot(
		shooter: Vector3,
		attacking_goal: Vector3,
		goalie_now: Vector3,
		net_half_width: float,
		opponents: Array[Vector3]) -> float:
	return score_shoot(shooter, attacking_goal, goalie_now,
			net_half_width, opponents, goalie_now, PASS_SPEED_M_S)


# Penalty in [0, GOALIE_ZONE_MAX_PENALTY] for a shooter sitting
# inside the goalie's pressure zone — narrow rectangle anchored on
# the goalie's CURRENT position, extending toward mid-ice. 0 outside
# the zone; peaks at the goalie's own position; ramps to 0 at the
# zone edges. Callers multiply (1 - this) into score_shoot.
static func goalie_zone_penalty(shooter: Vector3,
		goalie_current_pos: Vector3) -> float:
	# Forward direction from goalie toward mid-ice (away from goal
	# line). For Team 0 defending +Z, goalie at +z, forward is -Z.
	var forward_sign: float = -signf(goalie_current_pos.z)
	var forward_component: float = (shooter.z - goalie_current_pos.z) * forward_sign
	if forward_component <= 0.0 or forward_component >= GOALIE_ZONE_DEPTH_M:
		return 0.0
	var lateral: float = absf(shooter.x - goalie_current_pos.x)
	if lateral >= GOALIE_ZONE_HALF_WIDTH_M:
		return 0.0
	var depth_factor: float = 1.0 - forward_component / GOALIE_ZONE_DEPTH_M
	var lateral_factor: float = 1.0 - lateral / GOALIE_ZONE_HALF_WIDTH_M
	return GOALIE_ZONE_MAX_PENALTY * depth_factor * lateral_factor


# Predicts the goalie's position at a future moment (shot release).
# React-then-slide model: a fixed reaction delay, then movement toward
# the ARC-MATCHING x at max lateral speed.
#
# Arc-matching: a properly squared goalie sits at the position whose
# arc angle from the goal matches the shooter's. Since the goalie sits
# much closer to the goal than the shooter, that's
#   arc_x = goalie_depth × (puck.x - goal.x) / puck_forward_from_goal
# An earlier version used puck.x directly as the slide target —
# geometrically wrong for off-axis shooters, and a source of bot-
# carry exploits because diagonal carry candidates appeared as "open
# net" plays even when a perfectly-tracking goalie would cover them.
#
# `goalie_now` is the goalie's current world position.
# `attacking_goal` is the goal the puck is aimed at; provides goal
# center and the sign for "forward."
# `release_time_s` is seconds from now until the shot fires.
# `puck_pos_at_release` is where the puck will be when fired (= the
# shooter's position for direct shots; receiver lead for passes;
# carry candidate for carry-then-shoot).
static func predict_goalie_pos(
		goalie_now: Vector3,
		attacking_goal: Vector3,
		release_time_s: float,
		puck_pos_at_release: Vector3) -> Vector3:
	var net_normal_z: float = -signf(attacking_goal.z)
	var puck_forward: float = (puck_pos_at_release.z - attacking_goal.z) * net_normal_z
	var goalie_depth: float = (goalie_now.z - attacking_goal.z) * net_normal_z
	var target_x: float
	if puck_forward < 0.001 or goalie_depth < 0.001:
		# Degenerate: puck on/behind goal line, or goalie there. Slide
		# toward puck.x as a best-effort fallback.
		target_x = puck_pos_at_release.x
	else:
		target_x = attacking_goal.x + goalie_depth * (puck_pos_at_release.x - attacking_goal.x) / puck_forward
	var move_time: float = maxf(0.0, release_time_s - GOALIE_REACTION_DELAY_S)
	var max_move: float = move_time * GOALIE_MAX_LATERAL_SPEED_MPS
	var dx: float = target_x - goalie_now.x
	var dist_to_target: float = absf(dx)
	if dist_to_target < 0.001 or max_move <= 0.0:
		return goalie_now
	if dist_to_target <= max_move:
		return Vector3(target_x, goalie_now.y, goalie_now.z)
	return Vector3(goalie_now.x + signf(dx) * max_move, goalie_now.y, goalie_now.z)


# Companion to predict_goalie_pos: how UNSETTLED [0, 1] the goalie is AT release.
#   0 = set and square (already at its arc-match target, no forced motion)
#   1 = still sliding (positionally behind) or only just arrived — reading late
# Same react-then-slide kinematics as predict_goalie_pos, so the predicted
# position and this motion estimate agree. score_shoot folds it into coverage
# (see GOALIE_MOTION_PENALTY). A fast cross-seam one-timer leaves the goalie
# mid-slide → near 1; a static shot at a set goalie → 0.
static func goalie_unsettled(
		goalie_now: Vector3,
		attacking_goal: Vector3,
		release_time_s: float,
		puck_pos_at_release: Vector3) -> float:
	var net_normal_z: float = -signf(attacking_goal.z)
	var puck_forward: float = (puck_pos_at_release.z - attacking_goal.z) * net_normal_z
	var goalie_depth: float = (goalie_now.z - attacking_goal.z) * net_normal_z
	var target_x: float
	if puck_forward < 0.001 or goalie_depth < 0.001:
		target_x = puck_pos_at_release.x
	else:
		target_x = attacking_goal.x + goalie_depth * (puck_pos_at_release.x - attacking_goal.x) / puck_forward
	var need: float = absf(target_x - goalie_now.x)
	if need < 0.001:
		return 0.0  # already squared — no forced motion, fully set
	var move_time: float = maxf(0.0, release_time_s - GOALIE_REACTION_DELAY_S)
	var max_move: float = move_time * GOALIE_MAX_LATERAL_SPEED_MPS
	if need >= max_move:
		return 1.0  # still sliding at release (or hasn't even reacted) — caught moving
	# Reached the target with time to spare; ramps back to 0 as it re-sets.
	var slide_time: float = need / GOALIE_MAX_LATERAL_SPEED_MPS
	var settled_for: float = move_time - slide_time
	return clampf(1.0 - settled_for / GOALIE_SETTLE_REF_S, 0.0, 1.0)


# Returns PASS score in [0, 1] for a specific receiver. Multiplicative:
#   - pass_lane:             1.0 if no opponent in the shooter→receiver line
#   - score_shoot(receiver): receiver's value as a shooter from where
#                            they are (geometry × shot lane × pressure).
#
# Receiver-quality terms (open-man, advancement) are gone — at top
# level the carrier evaluates each teammate via a recursive
# score_at(receiver) that captures "they could shoot or drive to
# slot." This leaf score_pass is what score_at falls back to for the
# shoot branch from a receiver position; it doesn't recurse further
# (no leaf-pass at depth 2) so the bot can't get into infinite
# pass-back-and-forth evaluation loops.
static func score_pass(
		shooter: Vector3,
		receiver: Vector3,
		attacking_goal: Vector3,
		predicted_goalie_pos: Vector3,
		net_half_width: float,
		opponents: Array[Vector3],
		goalie_current_pos: Vector3 = Vector3.INF,
		pass_speed_m_s: float = PASS_SPEED_M_S,
		goalie_unsettled_factor: float = 0.0) -> float:
	if _is_past_goal_line(receiver, attacking_goal):
		return 0.0
	if pass_lane_blocked_by_net(shooter, receiver):
		return 0.0
	# Lane-clear's reaction window scales with puck flight time, so
	# passing the actual fire speed matters: a charged pass at ~19 m/s
	# gives defenders 36% less reaction time than the quick-shot
	# default. Caller picks via expected_pass_speed(shooter, receiver)
	# when the distance gate is appropriate.
	var lane: float = lane_clear(shooter, receiver, opponents, pass_speed_m_s)
	if lane <= 0.0:
		return 0.0
	# Receiver's value as a shooter from where they are. Caller is
	# responsible for predicting the goalie at the receiver's release
	# time (flight + receiver wrister charge) — see predict_goalie_pos.
	# goalie_current_pos threads through so the goalie pressure zone
	# (anchored on the goalie's CURRENT position, squared to the
	# carrier/puck holder) applies correctly for back-door receivers:
	# they're off-axis from the carrier's lane → outside zone → no
	# penalty, preserving back-door as a strong pass option.
	# goalie_unsettled_factor lets the caller credit a feed that catches the
	# goalie mid-slide (a cross-seam one-timer to an off-axis receiver) — the
	# off-puck staging roles pass it so they prize the back-door spot. Default
	# 0.0 keeps the position-only behaviour for callers that don't (SUPPORT).
	# Receiver shot speed stays the league default (cross-player; no teammate caps).
	var receiver_shot: float = score_shoot(
			receiver, attacking_goal, predicted_goalie_pos, net_half_width, opponents,
			goalie_current_pos, WRISTER_SHOT_SPEED_M_S, goalie_unsettled_factor)
	return lane * receiver_shot


# ── Helpers ──────────────────────────────────────────────────────────────────


# True if `pos` is past the attacking goal line in the direction the
# attacking team is going (i.e. "behind the net" relative to the
# shooter). For Team 0 attacking -Z (attacking_goal.z = -26.65),
# "past" means z < -26.65; for Team 1 attacking +Z, z > +26.65.
static func _is_past_goal_line(pos: Vector3, attacking_goal: Vector3) -> bool:
	return (pos.z - attacking_goal.z) * signf(attacking_goal.z) > 0.0


# Pressure score in [0, 1] for "do nearby opponents threaten this
# target." Wraps _opponent_density with the standard PRESSURE_* radii.
# All current callers (score_shoot, score_pass receiver) pass a
# forward direction so the cube falloff applies; the Vector3.ZERO
# default is kept as a safety fallback (omnidirectional, every
# opponent in radius weighted 1.0) but isn't currently used.
static func _pressure(target: Vector3, opponents: Array[Vector3],
		forward: Vector3 = Vector3.ZERO) -> float:
	return _opponent_density(target, opponents, forward, PRESSURE_RADIUS_M, PRESSURE_MAX_COUNT)


# Generic weighted opponent density. Counts opponents within `radius`
# of `target`, normalizing the count by `max_count` so the result
# lives in [0, 1]. Per-opponent weight composes two factors:
#
#   distance_factor = 1 - dist/radius   (linear falloff to 0 at radius)
#   direction_factor = max(0, dot)^3    (cube falloff vs forward)
#   weight = distance_factor × direction_factor
#
# Distance falloff: defender at 0.5 m vs 3.5 m in the same direction
# now contribute 0.88 vs 0.13 instead of equally. Stick reach is
# ~1.5 m so the linear ramp is a reasonable physics proxy for "in
# your face vs in the area."
#
# Direction falloff (kept from prior): cube of cosine. Behind = 0,
# perpendicular = 0, 45° forward ≈ 0.35, dead front = 1.0. Matches
# the hockey intuition that defenders behind or beside the play
# don't pressure the carrier.
#
# The omnidirectional fallback (forward = ZERO) keeps distance
# falloff but skips the direction term — used when forward direction
# is degenerate (target sitting at the goal mouth, etc).
static func _opponent_density(target: Vector3, opponents: Array[Vector3],
		forward: Vector3, radius: float, max_count: int) -> float:
	var directional: bool = forward.length_squared() > 0.0001
	var fwd_x: float = 0.0
	var fwd_z: float = 0.0
	if directional:
		var fl: float = sqrt(forward.x * forward.x + forward.z * forward.z)
		if fl > 0.0001:
			fwd_x = forward.x / fl
			fwd_z = forward.z / fl
		else:
			directional = false
	var weighted: float = 0.0
	for p: Vector3 in opponents:
		var dx: float = p.x - target.x
		var dz: float = p.z - target.z
		var d: float = sqrt(dx * dx + dz * dz)
		if d >= radius:
			continue
		var dist_factor: float = 1.0 - d / radius
		if directional:
			var dot: float = 0.0 if d < 0.0001 else (dx * fwd_x + dz * fwd_z) / d
			var clamped: float = maxf(0.0, dot)
			weighted += dist_factor * clamped * clamped * clamped
		else:
			weighted += dist_factor
	return clampf(weighted / float(max_count), 0.0, 1.0)


# Unclamped closest-approach time τ* that minimises the distance between
# the fired puck and a dead-reckoned defender. `pvx/pvz` are the puck's
# velocity components (dir × speed); `vx/vz` the defender's. May be < 0
# (closest approach already behind us — defender drifting off) or
# > seg_time (closest approach only AFTER the puck reaches the receiver —
# the defender is trailing the play and never intercepts it in flight).
# Callers clamp the low end to 0 and skip the high end. Pure float math
# (no allocation) — safe per defender on the lane hot path.
static func _lane_closest_approach_t(
		fx: float, fz: float, pvx: float, pvz: float,
		px: float, pz: float, vx: float, vz: float) -> float:
	# W(τ) = (from − D) + (puck_vel − defender_vel)·τ ; minimise |W(τ)|.
	var w0x: float = fx - px
	var w0z: float = fz - pz
	var wdx: float = pvx - vx
	var wdz: float = pvz - vz
	var wd_sq: float = wdx * wdx + wdz * wdz
	if wd_sq < 0.0001:
		return 0.0  # no relative motion — closest approach is now
	return -(w0x * wdx + w0z * wdz) / wd_sq


# Miss distance: how far the puck passes from the dead-reckoned defender
# at approach time `t`. Pure float math — shared by the flat-pass and
# saucer (body-only) block calculations so the two agree on the geometry.
static func _lane_miss_at(
		fx: float, fz: float, pvx: float, pvz: float, t: float,
		px: float, pz: float, vx: float, vz: float) -> float:
	var wx: float = (fx - px) + (pvx - vx) * t
	var wz: float = (fz - pz) + (pvz - vz) * t
	return sqrt(wx * wx + wz * wz)


# Flat per-defender block strength [0, 1] at a given approach time `t`:
# reach = stick + closing they can do after the reaction delay; block is
# how far the lane penetrates that reach, normalised by a stick length
# (one full stick inside reach ⇒ certain block). Pure float math.
static func _lane_block_at(
		fx: float, fz: float, pvx: float, pvz: float, t: float,
		px: float, pz: float, vx: float, vz: float) -> float:
	var miss: float = _lane_miss_at(fx, fz, pvx, pvz, t, px, pz, vx, vz)
	var reach: float = LANE_DEFENDER_REACH_M + LANE_DEFENDER_CLOSE_SPEED_M_S \
			* maxf(0.0, t - LANE_REACTION_DELAY_S)
	return clampf((reach - miss) / LANE_DEFENDER_REACH_M, 0.0, 1.0)


# Lane-clear factor in [0, 1] for a FIRED puck (shot or pass) — the
# closest-approach reachability model (see the doc-block above the lane
# constants). Public because the carrier's pass scoring uses it directly:
# a pass is a fired puck, so it gets this model rather than the geometric
# carry-path `path_clearance`.
#
# `lane_clear = 1 − max(block) across all defenders` — single-blocker
# model: the worst defender for the puck-flight defines the clearness.
# Max (not sum) avoids double-counting two defenders side by side.
#
# `puck_speed_m_s` is the actual speed the puck travels the segment —
# shots ~30 m/s, passes ~14–20 m/s. Faster pucks leave defenders less
# time to close, so they contribute less (falls out of the geometry).
#
# `opponent_vels` is an OPTIONAL parallel array of defender velocities
# (index-matched to `opponents`). When empty (or shorter), the missing
# defenders are read as stationary — every position-only caller keeps
# working; the carrier's pass scoring passes real velocities so a
# defender bearing down on the lane is priced as the threat they are.
static func lane_clear(from: Vector3, to: Vector3, opponents: Array[Vector3],
		puck_speed_m_s: float, opponent_vels: Array[Vector3] = []) -> float:
	var dx: float = to.x - from.x
	var dz: float = to.z - from.z
	var line_len_sq: float = dx * dx + dz * dz
	if line_len_sq < 0.01:
		return 1.0  # degenerate (overlapping endpoints)
	var line_len: float = sqrt(line_len_sq)
	var speed: float = maxf(puck_speed_m_s, 1.0)
	var seg_time: float = line_len / speed
	var inv_len: float = 1.0 / line_len
	var pvx: float = dx * inv_len * speed
	var pvz: float = dz * inv_len * speed
	var vel_count: int = opponent_vels.size()
	var max_block: float = 0.0
	for i: int in opponents.size():
		var p: Vector3 = opponents[i]
		var vx: float = 0.0
		var vz: float = 0.0
		if i < vel_count:
			vx = opponent_vels[i].x
			vz = opponent_vels[i].z
		var t_raw: float = _lane_closest_approach_t(
				from.x, from.z, pvx, pvz, p.x, p.z, vx, vz)
		if t_raw > seg_time:
			continue  # trailing the play — never closest in flight
		var t: float = maxf(t_raw, 0.0)
		var block: float = _lane_block_at(
				from.x, from.z, pvx, pvz, t, p.x, p.z, vx, vz)
		if block > max_block:
			max_block = block
			if max_block >= 1.0:
				break
	return clampf(1.0 - max_block, 0.0, 1.0)


# Lane-clear for a SAUCER (elevated) pass. Same closest-approach model as
# lane_clear, except within SAUCER_AIRBORNE_DISTANCE_M of the passer the
# puck is airborne, so a defender's reach collapses to their BODY radius —
# sticks fly under it, only a body in the lane stops it (see
# LANE_DEFENDER_BODY_RADIUS_M). Past that distance the puck has landed and
# every defender blocks with full grounded stick reach.
static func lane_clear_saucer(from: Vector3, to: Vector3, opponents: Array[Vector3],
		puck_speed_m_s: float, opponent_vels: Array[Vector3] = []) -> float:
	var dx: float = to.x - from.x
	var dz: float = to.z - from.z
	var line_len_sq: float = dx * dx + dz * dz
	if line_len_sq < 0.01:
		return 1.0  # degenerate (overlapping endpoints)
	var line_len: float = sqrt(line_len_sq)
	var speed: float = maxf(puck_speed_m_s, 1.0)
	var seg_time: float = line_len / speed
	var inv_len: float = 1.0 / line_len
	var pvx: float = dx * inv_len * speed
	var pvz: float = dz * inv_len * speed
	var vel_count: int = opponent_vels.size()
	var max_block: float = 0.0
	for i: int in opponents.size():
		var p: Vector3 = opponents[i]
		var vx: float = 0.0
		var vz: float = 0.0
		if i < vel_count:
			vx = opponent_vels[i].x
			vz = opponent_vels[i].z
		var t_raw: float = _lane_closest_approach_t(
				from.x, from.z, pvx, pvz, p.x, p.z, vx, vz)
		if t_raw > seg_time:
			continue  # trailing the play — never closest in flight
		var t: float = maxf(t_raw, 0.0)
		# Horizontal distance the puck has travelled off the blade at the
		# defender's closest approach (puck rides the lane at `speed`).
		var along_dist: float = speed * t
		var block: float
		if along_dist <= SAUCER_AIRBORNE_DISTANCE_M:
			# Still airborne — the puck flies over a grounded stick, so only
			# the defender's body can block it: reach = body radius, no
			# stick, no closing.
			var miss: float = _lane_miss_at(
					from.x, from.z, pvx, pvz, t, p.x, p.z, vx, vz)
			block = clampf(
					(LANE_DEFENDER_BODY_RADIUS_M - miss) / LANE_DEFENDER_BODY_RADIUS_M,
					0.0, 1.0)
		else:
			# Puck has landed past the airborne span — full stick reach + closing.
			block = _lane_block_at(
					from.x, from.z, pvx, pvz, t, p.x, p.z, vx, vz)
		if block > max_block:
			max_block = block
	return clampf(1.0 - max_block, 0.0, 1.0)


# Should a pass over this lane be lofted (saucer) rather than fired flat?
# True when the grounded lane is contested but a saucer meaningfully
# clears it — i.e. there's a mid-lane defender the loft flies over.
# Returns false when the grounded lane is already open (nothing to loft
# over) or when the saucer doesn't beat grounded by SAUCER_LANE_BENEFIT_MARGIN
# (loft not worth the extra flight time / fiddlier reception). The caller
# gates the DISTANCE (saucers are a long-pass tool); this judges only the
# lane geometry.
static func prefers_saucer(from: Vector3, to: Vector3, opponents: Array[Vector3],
		puck_speed_m_s: float, opponent_vels: Array[Vector3] = []) -> bool:
	var grounded: float = lane_clear(from, to, opponents, puck_speed_m_s, opponent_vels)
	if grounded >= SAUCER_SKIP_WHEN_LANE_CLEAR:
		return false
	var saucer: float = lane_clear_saucer(from, to, opponents, puck_speed_m_s, opponent_vels)
	return saucer > grounded + SAUCER_LANE_BENEFIT_MARGIN


# Interceptor point for a fired-puck lane: where on the puck's path the
# strongest-blocking defender reaches it (their closest-approach point) —
# the spot the puck is most likely to be picked off. Returns Vector3.INF
# when no defender blocks the lane (i.e. lane_clear would return 1.0).
#
# This is the loss location for the carrier's pass turnover-cost term
# (turnover_cost): "if this pass is intercepted, the opponent gains the
# puck HERE." Shares the per-defender block helpers with lane_clear, so
# the two agree on which defender is worst by construction.
static func lane_loss_point(from: Vector3, to: Vector3,
		opponents: Array[Vector3], puck_speed_m_s: float,
		opponent_vels: Array[Vector3] = []) -> Vector3:
	var dx: float = to.x - from.x
	var dz: float = to.z - from.z
	var line_len_sq: float = dx * dx + dz * dz
	if line_len_sq < 0.01:
		return Vector3.INF
	var line_len: float = sqrt(line_len_sq)
	var speed: float = maxf(puck_speed_m_s, 1.0)
	var seg_time: float = line_len / speed
	var inv_len: float = 1.0 / line_len
	var pvx: float = dx * inv_len * speed
	var pvz: float = dz * inv_len * speed
	var vel_count: int = opponent_vels.size()
	var max_block: float = 0.0
	var best_point: Vector3 = Vector3.INF
	for i: int in opponents.size():
		var p: Vector3 = opponents[i]
		var vx: float = 0.0
		var vz: float = 0.0
		if i < vel_count:
			vx = opponent_vels[i].x
			vz = opponent_vels[i].z
		var t_raw: float = _lane_closest_approach_t(
				from.x, from.z, pvx, pvz, p.x, p.z, vx, vz)
		if t_raw > seg_time:
			continue  # trailing the play — never closest in flight
		var t: float = maxf(t_raw, 0.0)
		var block: float = _lane_block_at(
				from.x, from.z, pvx, pvz, t, p.x, p.z, vx, vz)
		if block > max_block:
			max_block = block
			# Puck position at the defender's closest approach = the pick spot.
			best_point = Vector3(from.x + pvx * t, 0.0, from.z + pvz * t)
	return best_point


# Position potential in [0, 1] — "value of being at this position,
# regardless of any specific shot or pass." Three multiplicative
# factors:
#
#   closeness    = 1 at slot, ramps to 0 at goal mouth (inside) and
#                  to 0 at the rink length (outside).
#   shot_angle   = 1 - shot_angle / (PI/2)          (linear, 0 at 90° wide)
#   openness     = 1 - skater_pressure (forward-cone, distance-weighted)
#
# Used by `_score_at` only when the evaluator is OUTSIDE shooting
# range — inside the range, the bot uses score_shoot alone (committed
# to a real shot evaluation). The cross-boundary case (evaluator
# outside, candidate inside) takes max(shoot, potential) so entry
# into shooting range is rewarded by the higher of the two.
#
# Behind the attacking goal line: returns 0 (no shooting potential).
static func position_potential(
		pos: Vector3,
		attacking_goal: Vector3,
		opponents: Array[Vector3]) -> float:
	var net_normal_z: float = -signf(attacking_goal.z)
	var forward: float = (pos.z - attacking_goal.z) * net_normal_z
	if forward < 0.001:
		return 0.0
	var dist: float = pos.distance_to(attacking_goal)
	# Closeness: 0 at goal, 1 at slot, 0 at goal-to-goal distance.
	# Far-norm derived from rink geometry — the gradient covers the
	# whole rink so deep-zone positions still have a forward-progress
	# signal.
	var rink_length: float = absf(GameRules.GOAL_LINE_Z) * 2.0
	var closeness: float
	if dist <= SLOT_RADIUS_M:
		closeness = clampf(dist / SLOT_RADIUS_M, 0.0, 1.0)
	else:
		closeness = clampf(
				1.0 - (dist - SLOT_RADIUS_M) / (rink_length - SLOT_RADIUS_M),
				0.0, 1.0)
	var shot_angle: float = absf(atan2(pos.x - attacking_goal.x, forward))
	var angle_factor: float = clampf(1.0 - shot_angle / (PI * 0.5), 0.0, 1.0)
	var openness: float = 1.0 - _pressure(pos, opponents, attacking_goal - pos)
	return closeness * angle_factor * openness


# "Threat surface" — the value an opp can extract from their current
# position from a defender's perspective. score_shoot returns 0 when
# the opp is outside SHOT_RANGE_FALLOFF_M; that's correct for a
# carrier choosing whether to release, but useless for a defender
# trying to position relative to a far-but-still-dangerous opp.
# Falling back to position_potential gives a non-zero gradient over
# any legal opp position, so ANCHOR/COVER pull toward the opp's
# pressure cone (reducing position_potential.openness) instead of
# sitting flat at slot when no immediate shot threat exists.
#
# Used by ANCHOR for inverse shot-threat scoring across all opps.
static func threat_surface_shoot(
		opp_pos: Vector3,
		our_net: Vector3,
		our_goalie_pos: Vector3,
		net_half_width: float,
		defenders: Array[Vector3]) -> float:
	var shoot: float = score_shoot(
			opp_pos, our_net, our_goalie_pos, net_half_width, defenders)
	var positional: float = position_potential(opp_pos, our_net, defenders)
	return maxf(shoot, positional)


# Pass-threat surface — score_pass with a positional fallback for
# the same reason as threat_surface_shoot. score_pass folds in
# lane_clear × score_shoot(receiver); when receiver_shot collapses
# to 0, the lane has no value to defend. Fallback rewards defenders
# for being in the lane (lane_clear ↓) AND for closing on the
# receiver (position_potential.openness ↓).
#
# Used by COVER for inverse pass-threat scoring across opp teammates.
static func threat_surface_pass(
		carrier_pos: Vector3,
		receiver_pos: Vector3,
		our_net: Vector3,
		our_goalie_pos: Vector3,
		net_half_width: float,
		defenders: Array[Vector3]) -> float:
	if pass_lane_blocked_by_net(carrier_pos, receiver_pos):
		return 0.0
	# Assume the opponent would fire this hypothetical pass at the
	# speed our bots would — charged wrister for long passes, quick-
	# shot otherwise. Without this, the carrier-quick-shot 14 m/s
	# default would overestimate defender reaction time on long
	# opponent passes and underestimate the threat.
	var pass_speed: float = expected_pass_speed(carrier_pos, receiver_pos)
	var pass_score: float = score_pass(
			carrier_pos, receiver_pos, our_net, our_goalie_pos,
			net_half_width, defenders, Vector3.INF, pass_speed)
	var lane: float = lane_clear(carrier_pos, receiver_pos, defenders, pass_speed)
	var positional: float = position_potential(receiver_pos, our_net, defenders)
	return maxf(pass_score, lane * positional)


# Expected turnover cost — the defensive half of the carrier's
# expected-value model. The value of having the puck (score_at / pass
# upside) is one side; this is the other: the possession value the
# OPPONENT gains if we lose the puck at `loss_point`, weighted by the
# probability of losing it.
#
#   turnover_cost = loss_prob × threat_surface_shoot(loss_point → our net)
#
# The benefit (us shooting their net) and the cost (them shooting ours)
# are scored with the SAME threat surface — score_shoot-shaped value of
# possessing the puck at a location. Because both sides share one
# (uncalibrated but consistent) surface, any miscalibration factor is
# common to both terms and cancels in the argmax: the exchange rate
# between a goal-for and a goal-against is exactly 1, so there is NO
# aversion weight. "Don't turn it over where it hurts" then falls out of
# geometry alone — threat_surface_shoot is ~0 when loss_point is far
# from / wide of our net (offensive-zone turnover) and large in front of
# it (own-zone turnover), so the cost self-localizes with no zone flag.
#
# `our_defenders` are our skaters (excluding the carrier, who just got
# beat); they reduce the opponent's threat exactly as in the defensive
# roles. Returns 0 when there's no loss location (INF) or no loss
# probability.
static func turnover_cost(
		loss_point: Vector3,
		loss_prob: float,
		our_net: Vector3,
		our_goalie_pos: Vector3,
		net_half_width: float,
		our_defenders: Array[Vector3]) -> float:
	if not loss_point.is_finite():
		return 0.0
	if loss_prob <= 0.0:
		return 0.0
	return loss_prob * threat_surface_shoot(
			loss_point, our_net, our_goalie_pos, net_half_width, our_defenders)


# Omnidirectional poke-threat penalty for CARRY destinations. Returns
# a multiplier in [CARRY_POKE_SAFETY_FLOOR, 1.0]: full safety (1.0)
# when no opponent's body is within CARRY_POKE_SAFE_RADIUS_M of the
# carrier's PUCK position, clamped to the floor when an opponent is
# inside the inner danger radius, linear ramp in between.
#
# Layered ON TOP of `score_shoot` / `position_potential`, both of
# which already penalize defenders — but those use a FORWARD-CONE
# pressure (defenders behind/beside don't matter for a shot lane).
# For possession protection, a defender at ANY angle within stick
# reach of the puck is a poke threat. This penalty captures that
# gap so carriers pick destinations that are safe to BE AT, not just
# safe to shoot from.
#
# Caller passes the projected PUCK position (carrier body + carry-arm
# offset toward attacking goal) and projected opponent body positions
# at the candidate's arrival time. Measuring opp-body → our-puck
# (rather than body-to-body) captures the asymmetry that a defender
# in FRONT of the carrier is much more dangerous than one BEHIND,
# at the same body-to-body distance — because the puck rides forward.
#
# Radii are derived from the physical poke geometry:
#   DANGER = STICK_REACH + POKE_RADIUS — opp body this close to our
#     puck and their stick CAN reach it.
#   SAFE   = DANGER + REACT_BUFFER     — a tick of skating in plus a
#     small margin; outside this the bot has time to move clear.
const CARRY_POKE_REACT_BUFFER_M: float = 0.9
const CARRY_POKE_DANGER_RADIUS_M: float = (
		GameRules.DEFAULT_STICK_LENGTH_M
		+ GameRules.DEFAULT_BLADE_LENGTH_M
		+ GameRules.POKE_RADIUS_M)
const CARRY_POKE_SAFE_RADIUS_M: float = (
		CARRY_POKE_DANGER_RADIUS_M + CARRY_POKE_REACT_BUFFER_M)
# Floor sets how much shot value can override safety. 0.35 means a
# +185%-better shot from the dangerous spot still beats a safe spot
# with equal shot quality — committed offensive plays still fire,
# defensive carry candidates still get a real penalty.
const CARRY_POKE_SAFETY_FLOOR: float = 0.35

static func carry_poke_safety(puck_pos: Vector3, projected_opponents: Array[Vector3]) -> float:
	var nearest_sq: float = INF
	for p: Vector3 in projected_opponents:
		var dx: float = p.x - puck_pos.x
		var dz: float = p.z - puck_pos.z
		var d_sq: float = dx * dx + dz * dz
		if d_sq < nearest_sq:
			nearest_sq = d_sq
	if nearest_sq == INF:
		return 1.0
	var d: float = sqrt(nearest_sq)
	if d >= CARRY_POKE_SAFE_RADIUS_M:
		return 1.0
	if d <= CARRY_POKE_DANGER_RADIUS_M:
		return CARRY_POKE_SAFETY_FLOOR
	var t: float = (d - CARRY_POKE_DANGER_RADIUS_M) / (
			CARRY_POKE_SAFE_RADIUS_M - CARRY_POKE_DANGER_RADIUS_M)
	return lerpf(CARRY_POKE_SAFETY_FLOOR, 1.0, t)


# Time-synced interception penalty for CARRY destinations. Returns a
# multiplier in [CARRY_POKE_SAFETY_FLOOR, 1.0] driven by the worst
# (closest) defender intercept across the bot's projected path to
# `candidate`. Unlike carry_poke_safety (which only checks the
# destination) and path_clearance (which checks whether a projected
# opponent STANDS on the line), this asks: as the bot skates along
# its path over [0, local_time], does any defender's projected
# position pass within poke range of the bot's position AT THE SAME
# TIME?
#
# Modeling defender CONVERGENCE on the bot's route lets _best_carry
# pick lateral candidates earlier — the body bends away from a
# closing defender before they arrive, instead of driving toward
# them and relying on the discrete deke at the last moment.
#
# Math: bot and defender both modeled as constant-velocity over
# [0, local_time]. |B(t) - D(t)|² is quadratic in t; closest
# approach has a closed form (perpendicular of relative motion).
# Clamp t* to [0, local_time] so closest-approach OUTSIDE the
# window (defender passes through after we've already arrived)
# doesn't penalize.
#
# Same radii / floor as carry_poke_safety — same poke geometry.
# Caller responsibility: `opponents_current` and `opponents_at_arrival`
# must be parallel arrays (i = same defender); a defender's velocity
# is derived as (at_arrival - current) / local_time.
#
# Edge cases:
#   - local_time ≈ 0 → bot has no path. Caller should skip (use
#     carry_poke_safety alone for stand-still candidates).
#   - |delta_vel|² ≈ 0 (defender and bot moving parallel-and-same-
#     speed) → t* clamps to 0, result is distance at t=0. Falls
#     back to "do they start in poke range?" — correct, since a
#     parallel-pace chase isn't a poke setup, it's a continuous
#     threat.
static func carry_intercept_safety(
		self_pos: Vector3,
		candidate: Vector3,
		local_time: float,
		opponents_current: Array[Vector3],
		opponents_at_arrival: Array[Vector3]) -> float:
	if local_time <= 0.0001:
		return 1.0
	var n: int = opponents_current.size()
	if n == 0 or n != opponents_at_arrival.size():
		return 1.0
	var inv_t: float = 1.0 / local_time
	var bot_vx: float = (candidate.x - self_pos.x) * inv_t
	var bot_vz: float = (candidate.z - self_pos.z) * inv_t
	var min_d: float = INF
	for i: int in n:
		var opp_now: Vector3 = opponents_current[i]
		var opp_then: Vector3 = opponents_at_arrival[i]
		var opp_vx: float = (opp_then.x - opp_now.x) * inv_t
		var opp_vz: float = (opp_then.z - opp_now.z) * inv_t
		var dp_x: float = opp_now.x - self_pos.x
		var dp_z: float = opp_now.z - self_pos.z
		var dv_x: float = opp_vx - bot_vx
		var dv_z: float = opp_vz - bot_vz
		var dv_sq: float = dv_x * dv_x + dv_z * dv_z
		var t_star: float
		if dv_sq < 0.0001:
			# Parallel-velocity case: relative motion is zero. Distance
			# is constant across the window; pick t=0.
			t_star = 0.0
		else:
			t_star = clampf(
					-(dp_x * dv_x + dp_z * dv_z) / dv_sq,
					0.0, local_time)
		var dx_at_t: float = dp_x + dv_x * t_star
		var dz_at_t: float = dp_z + dv_z * t_star
		var d: float = sqrt(dx_at_t * dx_at_t + dz_at_t * dz_at_t)
		if d < min_d:
			min_d = d
	if min_d == INF or min_d >= CARRY_POKE_SAFE_RADIUS_M:
		return 1.0
	if min_d <= CARRY_POKE_DANGER_RADIUS_M:
		return CARRY_POKE_SAFETY_FLOOR
	var ramp_t: float = (min_d - CARRY_POKE_DANGER_RADIUS_M) / (
			CARRY_POKE_SAFE_RADIUS_M - CARRY_POKE_DANGER_RADIUS_M)
	return lerpf(CARRY_POKE_SAFETY_FLOOR, 1.0, ramp_t)


# Defender reach for the CARRY-path check below — stick-blade reach plus
# a margin for the defender stepping in as the bot skates past. Distinct
# from the fired-puck lane model (which derives reach from closing time);
# a carry is a slow physical traverse, so it uses a flat poke radius.
const CARRY_PATH_CLEAR_RADIUS_M: float = 1.8

# Public lane-clearance check for CARRY candidates — the bot is
# physically traveling along this segment, not firing a puck through
# it, so the reaction-window math from `lane_clear` doesn't apply.
# A defender anywhere on the path is in the way regardless of flight
# time. Returns 1.0 if no opponent is within CARRY_PATH_CLEAR_RADIUS_M of
# the segment, ramps linearly to 0.0 as defender approaches the line.
# Caller should project opponents forward by the candidate's expected
# arrival time so the check reflects where defenders WILL BE when
# the bot gets there.
static func path_clearance(from: Vector3, to: Vector3,
		projected_opponents: Array[Vector3]) -> float:
	var dx: float = to.x - from.x
	var dz: float = to.z - from.z
	var line_len_sq: float = dx * dx + dz * dz
	if line_len_sq < 0.01:
		return 1.0
	var min_perp_sq: float = INF
	for p: Vector3 in projected_opponents:
		var pdx: float = p.x - from.x
		var pdz: float = p.z - from.z
		var t: float = (pdx * dx + pdz * dz) / line_len_sq
		if t <= 0.0 or t >= 1.0:
			continue
		var closest_x: float = from.x + t * dx
		var closest_z: float = from.z + t * dz
		var perp_x: float = p.x - closest_x
		var perp_z: float = p.z - closest_z
		var perp_sq: float = perp_x * perp_x + perp_z * perp_z
		if perp_sq < min_perp_sq:
			min_perp_sq = perp_sq
	if min_perp_sq == INF:
		return 1.0
	var perp: float = sqrt(min_perp_sq)
	return clampf(perp / CARRY_PATH_CLEAR_RADIUS_M, 0.0, 1.0)


# Momentum-aware time to arrive at `dest` from `from_pos` carrying
# `from_velocity`. effective_speed = SKATER_REF_SPEED + component of
# velocity along (from→dest); a skater already moving toward dest gets
# there faster, a skater moving away takes longer. Clamped at
# MIN_TRAVEL_SPEED_M_S so reverse-direction candidates have finite
# arrival time (slower, but not infinite).
#
# Used by AIRoleCarrier._best_carry to discount candidates the bot is
# currently moving away from, by AIController chase-intercept lookahead
# for opponent ETA estimation, and by off-puck role behaviors that
# need a momentum-aware ETA without inventing their own constants
# (e.g., SUPPORT's foot-race-home exposure check uses this for the
# threat opp's ETA back to our net).
#
# `ref_speed_m_s` is the actor's flat skating speed; it defaults to the league
# reference so cross-player callers (opponent / teammate ETA, the loose-puck
# election that must stay consistent across all bots) keep the shared baseline.
# A bot estimating ITS OWN arrival passes its attribute-scaled top speed.
static func time_to_arrive(from_pos: Vector3, dest: Vector3,
		from_velocity: Vector3, ref_speed_m_s: float = SKATER_REF_SPEED_M_S) -> float:
	var dx: float = dest.x - from_pos.x
	var dz: float = dest.z - from_pos.z
	var dist: float = sqrt(dx * dx + dz * dz)
	if dist < 0.001:
		return 0.0
	var inv: float = 1.0 / dist
	var speed_along: float = from_velocity.x * dx * inv + from_velocity.z * dz * inv
	var effective: float = maxf(MIN_TRAVEL_SPEED_M_S,
			ref_speed_m_s + speed_along)
	return dist / effective


# True iff the segment from `from` to `to` (in world XZ) intersects
# either net's footprint. Each net is the rectangle x ∈ ±NET_HALF_WIDTH,
# z ∈ [GOAL_LINE_Z, GOAL_LINE_Z + NET_DEPTH] — the goal mouth out to
# the back frame, mirrored for the other team. Used by score_pass to
# treat the net as a hard pass-lane obstruction so corner-to-corner
# OZ passes don't sail through the back of the cage and DZ passes
# don't cross the goal mouth.
static func pass_lane_blocked_by_net(from: Vector3, to: Vector3) -> bool:
	var goal_line_z: float = GameRules.GOAL_LINE_Z
	var net_half_w: float = GameRules.NET_HALF_WIDTH
	var net_depth: float = GameRules.NET_DEPTH
	# Team 0's net (positive z) spans z ∈ [goal_line_z, goal_line_z + net_depth].
	if _segment_crosses_aabb_xz(
			from.x, from.z, to.x, to.z,
			-net_half_w, net_half_w,
			goal_line_z, goal_line_z + net_depth):
		return true
	# Team 1's net (negative z) spans z ∈ [-(goal_line_z + net_depth), -goal_line_z].
	if _segment_crosses_aabb_xz(
			from.x, from.z, to.x, to.z,
			-net_half_w, net_half_w,
			-(goal_line_z + net_depth), -goal_line_z):
		return true
	return false


# Own-DZ slot danger zone. True iff the pass segment crosses the
# rectangle in front of OUR net — the high-danger area where a
# deflected/intercepted pass becomes a goal against. Asymmetric to
# `pass_lane_blocked_by_net` because passes through OPP slot are
# legitimate (backdoor / cross-crease feeds); only OWN slot is risky.
#
# Slot rect: x ∈ ±OWN_DZ_SLOT_HALF_WIDTH_M, z ∈ [own_goal_line - depth,
# own_goal_line] for own_goal_z > 0; mirrored for own_goal_z < 0.
const OWN_DZ_SLOT_HALF_WIDTH_M: float = 2.0
const OWN_DZ_SLOT_DEPTH_M: float = 5.0
static func pass_crosses_own_slot(from: Vector3, to: Vector3, own_goal_z: float) -> bool:
	var depth: float = OWN_DZ_SLOT_DEPTH_M
	var half_w: float = OWN_DZ_SLOT_HALF_WIDTH_M
	if own_goal_z > 0.0:
		# Team 0: own net at +z. Slot is in front of goal line,
		# z ∈ [own_goal_z - depth, own_goal_z].
		return _segment_crosses_aabb_xz(
				from.x, from.z, to.x, to.z,
				-half_w, half_w,
				own_goal_z - depth, own_goal_z)
	else:
		# Team 1: own net at -z. Slot z ∈ [own_goal_z, own_goal_z + depth].
		return _segment_crosses_aabb_xz(
				from.x, from.z, to.x, to.z,
				-half_w, half_w,
				own_goal_z, own_goal_z + depth)


# Liang-Barsky parametric clipping: returns true iff the segment from
# (fx, fz) to (tx, tz) intersects the axis-aligned rectangle bounded
# by [x_min, x_max] × [z_min, z_max]. Endpoint inside the rect counts
# as intersection.
static func _segment_crosses_aabb_xz(
		fx: float, fz: float, tx: float, tz: float,
		x_min: float, x_max: float, z_min: float, z_max: float) -> bool:
	var dx: float = tx - fx
	var dz: float = tz - fz
	var t_min: float = 0.0
	var t_max: float = 1.0
	# X slab.
	if absf(dx) < 0.0001:
		if fx < x_min or fx > x_max:
			return false
	else:
		var t1: float = (x_min - fx) / dx
		var t2: float = (x_max - fx) / dx
		if t1 > t2:
			var tmp: float = t1
			t1 = t2
			t2 = tmp
		t_min = maxf(t_min, t1)
		t_max = minf(t_max, t2)
		if t_min > t_max:
			return false
	# Z slab.
	if absf(dz) < 0.0001:
		if fz < z_min or fz > z_max:
			return false
	else:
		var t1: float = (z_min - fz) / dz
		var t2: float = (z_max - fz) / dz
		if t1 > t2:
			var tmp: float = t1
			t1 = t2
			t2 = tmp
		t_min = maxf(t_min, t1)
		t_max = minf(t_max, t2)
		if t_min > t_max:
			return false
	return true
