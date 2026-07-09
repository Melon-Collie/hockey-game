class_name AIActionScoring

# Pure-function utility scoring for on-puck actions. Each score is a
# multiplicative composition of factors in [0, 1].
#
# ── Design intent: geometric xG ──────────────────────────────────────────────
# `score_shoot` approximates expected goals (xG) — the probability a shot beats
# the goalie given its geometry and the defensive context. It is a GEOMETRIC
# model, not a curve fit: it scores the best of the seven goalie holes (the net
# each clears past the goalie's reaction-gated, height-appropriate cover — see
# the seven-hole block below), then multiplies by lane clearance and forward-cone
# pressure. Distance, angle, and coverage all EMERGE from that geometry; there
# are no hand-tuned distance/angle curves. It is xG-SHAPED (peak in the slot,
# fades with range/angle) but NOT magnitude-calibrated: treat the outputs as
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

# Shot-range regime boundary — NOT a scoring falloff. The seven-hole geometry
# (open_net_danger) already handles distance on its own: a far shot foreshortens
# the net and the goalie's glove has flight time to reach the corners, so danger
# fades to ~0 with range without any distance curve. This constant only marks the
# in/out-of-range REGIME switch for `_score_at`: inside it the bot commits to a
# real shot (score_shoot alone); outside it the bot prices the position via
# position_potential instead. Geometrically rooted at the attacking-zone span
# (blue line to opposing goal line) — a shot from the attacking blue line is the
# longest realistic in-possession shot; anything from the neutral zone is a
# dump-in, not a shot. Tracks rink resizes automatically.
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

# ── Shot danger: seven-hole open-net model ───────────────────────────────────
# score_shoot rates a shot by evaluating the seven classic goalie "holes" as
# separate targets, taking the BEST one. The score is that hole's opening; which
# hole it is decides the LOFT the bot shoots (best_shot_loft). This is pure
# geometry from the shooter's eye — distance, angle, and coverage all EMERGE
# (see _hole_open_angle) — with the goalie a body that occludes part of the net.
#
#   1,2  top corners      → HIGH loft (over the glove/blocker held up in stance)
#   3,4  bottom corners    → FLAT      (beside the pads)
#   5    five-hole         → FLAT      (between the legs — opens when he's moving)
#   6,7  armpits           → LOW loft  (the body-side seam under a raised arm)
#
# The goalie FREEZES on the shot (he can't slide into it), so the only thing
# range buys him is REACTION time to extend the relevant body part to the
# placement. Each hole reads its own height BAND, and the bands differ in exactly
# the two ways a real goalie's do — a wider always-covered CORE and a slower
# REACTION — which is what makes the loft choice fall out of the same geometry:
#   cover = CORE + EXT × reaction ;  reaction = clamp((flight − DELAY)/DEPLOY,0,1)
#   openness = the net the hole clears past the goalie's cover, projected onto
#              the net plane (shadow) so foreshortening at sharp angles is honest
# Aggressive angle-challenging (the goalie plays OUT for a longer shot) is not a
# constant — it's just where the goalie actually is, fed in as goalie_pos.
#
# The band cores/reaches are grounded, not fitted:
#  · LOW  — legs/pads, WIDEST core (a set butterfly seals low) + small push,
#           fast LEG reaction. Low corners open only past the pad, or off a slide.
#  · HIGH — glove/blocker, NARROWEST core (held up they leave the top corners)
#           but the longest reach (out to 0.85 m ≈ glove_max_x_outward) on a slow
#           ARM reaction. In tight the glove can't extend → roof it; at range it
#           gets there → top corners shut. This is the over-the-shoulder read.
#  · MID  — torso/armpit seam, between the two.
# Total HIGH reach (CORE+EXT = 0.85) mirrors the live goalie's glove_max_x_outward.
const HOLE_BAND_CORE: Array[float] = [0.60, 0.50, 0.40]   # [LOW, MID, HIGH] half-width, always covered
const HOLE_BAND_EXT: Array[float] = [0.15, 0.20, 0.45]    # reaction-gated extension to the placement
const HOLE_BAND_DELAY: Array[float] = [                    # per-band reaction delay (legs fast, arms slow)
		GameRules.DEFAULT_GOALIE_REACTION_DELAY_S,        # LOW  — legs, 0.13
		0.15,                                             # MID  — torso, between legs and arms
		GameRules.DEFAULT_GOALIE_ARM_REACTION_DELAY_S,    # HIGH — glove/blocker, 0.18
]
const HOLE_BAND_LOFT: Array[int] = [                       # loft the band's hole is shot with
		ShotMechanics.ELEVATION_FLAT,   # LOW  → flat
		ShotMechanics.ELEVATION_LOW,    # MID  → medium (saucer height, under a raised arm)
		ShotMechanics.ELEVATION_HIGH,   # HIGH → roof it
]
const GOALIE_ARM_DEPLOY_S: float = 0.20   # reaction ramp width — time to extend to the placement

# Loft choice prefers the LOWEST-risk shot among comparable openings: a flat shot
# is easier to execute than roofing it (you can sail a high shot over the bar). So
# best_shot_loft takes the flattest hole whose opening is within this fraction of
# the widest — only committing to a roof when the top corner is meaningfully the
# only way in. (The SCORE is still the widest opening; this only picks the loft.)
const LOFT_TIE_FRAC: float = 0.85
const HOLE_BAND_LOW: int = 0
const HOLE_BAND_MID: int = 1
const HOLE_BAND_HIGH: int = 2

# Hole kinds (how the opening is measured — see _hole_open_angle).
const HOLE_KIND_CORNER: int = 0   # net-relative post; opening = net cleared past the cover edge
const HOLE_KIND_FIVE: int = 1     # goalie-relative low-centre gap; opens when he's UNSETTLED
const HOLE_KIND_ARMPIT: int = 2   # goalie-relative body-side seam; MID band, capped narrow

# The seven holes as parallel arrays (indexed 0..6, no per-call allocation).
const HOLE_KIND: Array[int] = [
		HOLE_KIND_CORNER, HOLE_KIND_CORNER,   # 1,2 top corners
		HOLE_KIND_CORNER, HOLE_KIND_CORNER,   # 3,4 bottom corners
		HOLE_KIND_FIVE,                       # 5   five-hole
		HOLE_KIND_ARMPIT, HOLE_KIND_ARMPIT,   # 6,7 armpits
]
const HOLE_SIDE: Array[int] = [-1, 1, -1, 1, 0, -1, 1]   # net/goalie side; 0 = centred
const HOLE_BAND: Array[int] = [
		HOLE_BAND_HIGH, HOLE_BAND_HIGH,
		HOLE_BAND_LOW, HOLE_BAND_LOW,
		HOLE_BAND_LOW,
		HOLE_BAND_MID, HOLE_BAND_MID,
]
const HOLE_COUNT: int = 7

# The body-side seam sits this far off the goalie's centre (just outside the
# torso). The armpit is the medium-loft option that opens in tight when the arm
# hasn't filled the seam; capped narrow so it never out-scores a real corner.
const ARMPIT_OFFSET_M: float = 0.58

# Five-hole: a set goalie seals it (FIVE_BASE ≈ 0), it opens as he's caught
# moving (the goalie_unsettled_factor). FIVE_MAX_ANGLE is the opening (radians) a
# fully-splayed goalie leaks between the legs; only counts on a roughly head-on
# look (centrality falls off past FIVE_CENTER_REF metres of lateral offset — you
# can't thread the legs from the wall).
const FIVE_BASE: float = 0.0
const FIVE_MAX_ANGLE: float = 0.14
const FIVE_CENTER_REF_M: float = 1.6

# Danger gain: converts the best hole's open angle (radians) into the game's
# shot-value currency — the ONE feel scalar left. Set so a clean cross-seam
# one-timer lands ~0.7 and a gaping backdoor net saturates to 1.0.
const SHOT_DANGER_GAIN: float = 3.0

# Goalie position prediction. React-then-slide: react delay first, then move
# toward the puck-at-release X at max lateral speed. GOALIE_REACTION_DELAY_S and
# GOALIE_MAX_LATERAL_SPEED_MPS reference GameRules so the prediction stays in
# lockstep with the live goalie (lateral speed = GoalieController.t_push_speed).
const GOALIE_REACTION_DELAY_S: float = GameRules.DEFAULT_GOALIE_REACTION_DELAY_S
const GOALIE_MAX_LATERAL_SPEED_MPS: float = GameRules.DEFAULT_GOALIE_T_PUSH_SPEED_M_S

# Shadow half-width used by AIShotAim.compute_open_net_aim for the lane-check
# aim point — picks a point past the goalie for the lane segment check.
const GOALIE_SHADOW_HALF_M: float = 0.3

# goalie_unsettled() settle reference: how long the goalie must sit stopped at
# its target before the model treats it as fully re-set. A recovering goalie
# reads the shot late, so score_shoot cuts his glove/blocker reaction by the
# unsettled fraction (he can't deploy the arms in time) — an off-angle
# one-timer that leaves him mid-slide beats him more.
const GOALIE_SETTLE_REF_S: float = 0.20

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
# whole way. (LOW loft launches at a fixed vertical speed, so the true
# airborne carry is hang time × pass speed ≈ 6 m at quick-shot power; this
# constant sits deliberately under that.) So the puck is treated
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
# ACTION_HYSTERESIS_MARGIN_FRAC — once a fire intent is set, that
# intent's (positive) score is scaled by (1 + this) when re-scored: a
# challenger must beat the committed intent by 15%, not by a flat
# margin. Prevents flicker between two close-scoring fire options
# during pre-aim. PROPORTIONAL rather than additive because utility
# scores span ~0.02 (deep-DZ escape reads) to ~0.7 (slot chances): the
# old flat +0.05 was ~10% of a typical OZ score but could exceed the
# ENTIRE gap between options in the defensive zone, making stale
# intents disproportionately sticky exactly where scores are small.
# Matches the proportional pattern already used by
# AIThreatAssignment.HYSTERESIS_MARGIN_FRAC. Applied only to POSITIVE
# scores — a committed intent that has decayed to worthless (or
# negative EV) earns no stickiness. Only applies to fire intents
# (SHOOT, QUICK_SHOT, PASS) — CARRY doesn't get a bonus, so the bot is
# free to switch to fire as soon as fire scores higher. Raise toward
# 0.30 if intent flickers visibly; lower toward 0.05 if intent feels
# too sticky.
const CARRY_DELAY_DISCOUNT_PER_SEC: float = 0.7
const ACTION_HYSTERESIS_MARGIN_FRAC: float = 0.15


# Geometric shot danger in [0, 1]: the best of the seven goalie holes, seen from
# the shooter's eye, with the goalie a body that occludes part of the net.
# Distance, angle, squareness, and reaction all emerge from the geometry — no
# curves. Each hole is scored by _hole_open_angle (its opening in radians); the
# danger is the widest opening × SHOT_DANGER_GAIN. best_shot_loft returns the
# same winner's elevation class so the shot's loft matches where it's aimed.
# He FREEZES on the shot, so reaction is body-part REACH to the placement, not a
# slide; a longer flight buys the reach, an unsettled goalie loses it.
static func open_net_danger(
		shooter: Vector3, attacking_goal: Vector3, goalie_pos: Vector3,
		net_half_width: float, shot_speed_m_s: float,
		goalie_unsettled_factor: float = 0.0) -> float:
	var flight: float = shooter.distance_to(attacking_goal) / maxf(shot_speed_m_s, 1.0)
	# Best of the seven holes. Pure value-type math, no allocation — safe to run
	# per carry candidate at tick rate (see _hole_open_angle).
	var best_angle: float = 0.0
	for i: int in HOLE_COUNT:
		var a: float = _hole_open_angle(i, shooter, attacking_goal, goalie_pos,
				net_half_width, flight, goalie_unsettled_factor)
		if a > best_angle:
			best_angle = a
	return clampf(best_angle * SHOT_DANGER_GAIN, 0.0, 1.0)


# The LOFT the bot should shoot with, from the same seven-hole geometry that
# open_net_danger scores: the elevation class of the CHOSEN hole (see
# _choose_shot_hole). A slot shot whose only opening is over the shoulder returns
# HIGH; a five-hole off a caught-moving goalie returns FLAT; a body-side seam
# returns LOW. Called once when SHOOT commits, so the re-scan is free.
static func best_shot_loft(
		shooter: Vector3, attacking_goal: Vector3, goalie_pos: Vector3,
		net_half_width: float, shot_speed_m_s: float,
		goalie_unsettled_factor: float = 0.0) -> int:
	var flight: float = shooter.distance_to(attacking_goal) / maxf(shot_speed_m_s, 1.0)
	var hole: int = _choose_shot_hole(shooter, attacking_goal, goalie_pos,
			net_half_width, flight, goalie_unsettled_factor)
	if hole < 0:
		return ShotMechanics.ELEVATION_FLAT
	return HOLE_BAND_LOFT[HOLE_BAND[hole]]


# The world aim POINT (on the net plane, y = 0) of the CHOSEN hole — the exact
# target the loft was picked for, so aim and loft always describe the same hole.
# The state machine locks this as the wrister aim at charge start. Falls back to
# the goal centre if the goalie leaves nothing (defensive — SHOOT only commits
# when there's an opening).
static func best_shot_aim(
		shooter: Vector3, attacking_goal: Vector3, goalie_pos: Vector3,
		net_half_width: float, shot_speed_m_s: float,
		goalie_unsettled_factor: float = 0.0) -> Vector3:
	var flight: float = shooter.distance_to(attacking_goal) / maxf(shot_speed_m_s, 1.0)
	var hole: int = _choose_shot_hole(shooter, attacking_goal, goalie_pos,
			net_half_width, flight, goalie_unsettled_factor)
	if hole < 0:
		return Vector3(attacking_goal.x, 0.0, attacking_goal.z)
	var aim_x: float = _hole_aim_x(hole, shooter, attacking_goal, goalie_pos,
			net_half_width, flight, goalie_unsettled_factor)
	return Vector3(aim_x, 0.0, attacking_goal.z)


# Picks the shot hole the bot commits to: the widest opening, then tie-broken
# toward the FLATTEST loft within LOFT_TIE_FRAC of it (bury it low if you can,
# roof it only when the top corner is the real way in), and within that flattest
# tier the widest opening. Returns the hole index, or -1 if nothing is open. One
# chooser shared by best_shot_loft and best_shot_aim so they never disagree.
static func _choose_shot_hole(
		shooter: Vector3, attacking_goal: Vector3, goalie_pos: Vector3,
		net_half_width: float, flight: float, unsettled: float) -> int:
	var best_angle: float = 0.0
	for i: int in HOLE_COUNT:
		var a: float = _hole_open_angle(i, shooter, attacking_goal, goalie_pos,
				net_half_width, flight, unsettled)
		if a > best_angle:
			best_angle = a
	if best_angle <= 0.0:
		return -1
	var threshold: float = best_angle * LOFT_TIE_FRAC
	var chosen: int = -1
	var chosen_loft: int = ShotMechanics.ELEVATION_HIGH + 1
	var chosen_angle: float = 0.0
	for i: int in HOLE_COUNT:
		var a: float = _hole_open_angle(i, shooter, attacking_goal, goalie_pos,
				net_half_width, flight, unsettled)
		if a < threshold:
			continue
		var band_loft: int = HOLE_BAND_LOFT[HOLE_BAND[i]]
		if band_loft < chosen_loft or (band_loft == chosen_loft and a > chosen_angle):
			chosen_loft = band_loft
			chosen_angle = a
			chosen = i
	return chosen


# The net-plane aim x for a chosen hole. Corners aim at the open segment's
# midpoint biased toward the post (matching AIShotAim's tuned corner bias); the
# five-hole aims at the goalie's centre (between the legs); an armpit aims at the
# body-side seam. Reuses the same shadow projection as _hole_open_angle.
static func _hole_aim_x(
		i: int, shooter: Vector3, attacking_goal: Vector3, goalie_pos: Vector3,
		net_half_width: float, flight: float, unsettled: float) -> float:
	var kind: int = HOLE_KIND[i]
	var side: int = HOLE_SIDE[i]
	var net_z: float = attacking_goal.z
	var post_lo_x: float = attacking_goal.x - net_half_width
	var post_hi_x: float = attacking_goal.x + net_half_width

	if kind == HOLE_KIND_FIVE:
		return clampf(_shadow_x(shooter, goalie_pos.x, goalie_pos.z, net_z),
				post_lo_x, post_hi_x)
	if kind == HOLE_KIND_ARMPIT:
		return clampf(
				_shadow_x(shooter, goalie_pos.x + side * ARMPIT_OFFSET_M,
						goalie_pos.z, net_z),
				post_lo_x, post_hi_x)

	# Corner: aim at the open segment [post ↔ cover edge] on the hole's side,
	# midpoint biased toward the post.
	var band: int = HOLE_BAND[i]
	var reaction: float = clampf(
			(flight - HOLE_BAND_DELAY[band]) / GOALIE_ARM_DEPLOY_S, 0.0, 1.0)
	reaction *= 1.0 - clampf(unsettled, 0.0, 1.0)
	var cover: float = HOLE_BAND_CORE[band] + HOLE_BAND_EXT[band] * reaction
	if side < 0:
		var cov_lo_x: float = clampf(
				_shadow_x(shooter, goalie_pos.x - cover, goalie_pos.z, net_z),
				post_lo_x, post_hi_x)
		var mid_lo: float = (post_lo_x + cov_lo_x) * 0.5
		return lerpf(mid_lo, post_lo_x, AIShotAim.DEFAULT_CORNER_BIAS)
	var cov_hi_x: float = clampf(
			_shadow_x(shooter, goalie_pos.x + cover, goalie_pos.z, net_z),
			post_lo_x, post_hi_x)
	var mid_hi: float = (cov_hi_x + post_hi_x) * 0.5
	return lerpf(mid_hi, post_hi_x, AIShotAim.DEFAULT_CORNER_BIAS)


# Projects a point (px at depth pz) onto the net plane (z = net_z) along the
# sightline from the shooter — the point's "shadow" on the net. Working every
# opening on the net plane in one frame is what keeps the geometry honest at
# sharp angles: a wide-angle shooter foreshortens the net AND stretches the
# goalie's shadow across it, both of which shrink the real opening.
static func _shadow_x(shooter: Vector3, px: float, pz: float, net_z: float) -> float:
	var dz: float = pz - shooter.z
	if absf(dz) < 0.000001:
		return px
	return shooter.x + (net_z - shooter.z) / dz * (px - shooter.x)


# Open angle (radians, from the shooter's eye) of hole `i` — 0 if the goalie
# covers it. Corners measure the net cleared past the reaction-gated cover edge;
# the five-hole is a central gap that opens with the goalie's unsettle; armpits
# are a narrow body-side seam. All openings are computed on the net plane so
# foreshortening is automatic.
static func _hole_open_angle(
		i: int, shooter: Vector3, attacking_goal: Vector3, goalie_pos: Vector3,
		net_half_width: float, flight: float, unsettled: float) -> float:
	var net_normal_z: float = -signf(attacking_goal.z)
	var forward: float = (shooter.z - attacking_goal.z) * net_normal_z
	if forward < 0.001:
		return 0.0  # on/behind the goal line — no shot in
	var kind: int = HOLE_KIND[i]
	var side: int = HOLE_SIDE[i]

	if kind == HOLE_KIND_FIVE:
		# Between-the-legs gap: a set goalie seals it, a caught-moving one leaks
		# it. Only a roughly head-on look can thread the legs.
		var centrality: float = clampf(
				1.0 - absf(shooter.x - goalie_pos.x) / FIVE_CENTER_REF_M, 0.0, 1.0)
		return FIVE_MAX_ANGLE * clampf(FIVE_BASE + unsettled, 0.0, 1.0) * centrality

	var band: int = HOLE_BAND[i]
	var reaction: float = clampf(
			(flight - HOLE_BAND_DELAY[band]) / GOALIE_ARM_DEPLOY_S, 0.0, 1.0)
	reaction *= 1.0 - clampf(unsettled, 0.0, 1.0)
	var cover: float = HOLE_BAND_CORE[band] + HOLE_BAND_EXT[band] * reaction

	# Net posts and the goalie's cover edges, all as bearings on the net plane.
	var net_z: float = attacking_goal.z
	var post_lo_x: float = attacking_goal.x - net_half_width
	var post_hi_x: float = attacking_goal.x + net_half_width
	var net_lo: float = atan2(post_lo_x - shooter.x, forward)
	var net_hi: float = atan2(post_hi_x - shooter.x, forward)
	var cov_lo_x: float = clampf(
			_shadow_x(shooter, goalie_pos.x - cover, goalie_pos.z, net_z),
			post_lo_x, post_hi_x)
	var cov_hi_x: float = clampf(
			_shadow_x(shooter, goalie_pos.x + cover, goalie_pos.z, net_z),
			post_lo_x, post_hi_x)
	var covb_lo: float = atan2(cov_lo_x - shooter.x, forward)
	var covb_hi: float = atan2(cov_hi_x - shooter.x, forward)

	var openv: float
	if side < 0:
		openv = maxf(0.0, minf(covb_lo, net_hi) - net_lo)     # left post → cover's left edge
	else:
		openv = maxf(0.0, net_hi - maxf(covb_hi, net_lo))     # cover's right edge → right post

	if kind == HOLE_KIND_ARMPIT:
		# Cap to the seam between the body core edge and the armpit target, so the
		# body-side hole stays a narrow medium-loft option, not a stand-in corner.
		var seam_x: float = clampf(
				_shadow_x(shooter, goalie_pos.x + side * ARMPIT_OFFSET_M,
						goalie_pos.z, net_z),
				post_lo_x, post_hi_x)
		var seam_b: float = atan2(seam_x - shooter.x, forward)
		var edge_b: float = covb_hi if side > 0 else covb_lo
		openv = minf(openv, absf(seam_b - edge_b))
	return openv


# Returns SHOOT score in [0, 1]: the geometric open-net danger × lane clearance
# × forward-cone pressure. `predicted_goalie_pos` is the goalie at shot release
# (use `predict_goalie_pos`); the seven-hole geometry handles "too close" on its
# own. `shot_speed_m_s` sets the flight time (goalie reaction) and the lane math;
# `goalie_unsettled_factor` cuts his reaction (a mid-slide goalie reads the shot
# late).
static func score_shoot(
		shooter: Vector3,
		attacking_goal: Vector3,
		predicted_goalie_pos: Vector3,
		net_half_width: float,
		opponents: Array[Vector3],
		shot_speed_m_s: float = WRISTER_SHOT_SPEED_M_S,
		goalie_unsettled_factor: float = 0.0) -> float:
	var shot_quality: float = open_net_danger(
			shooter, attacking_goal, predicted_goalie_pos, net_half_width,
			shot_speed_m_s, goalie_unsettled_factor)
	if shot_quality <= 0.0:
		return 0.0
	# Lane clear vs the aim point ShotAim picks (past the goalie's shadow) —
	# defenders on the shot line reduce it via the reaction-window model.
	var aim: Vector3 = AIShotAim.compute_open_net_aim(
			shooter, predicted_goalie_pos, attacking_goal.z,
			net_half_width, GOALIE_SHADOW_HALF_M)
	var lane: float = lane_clear(shooter, aim, opponents, shot_speed_m_s)
	# Forward-cone pressure: bodies between the shooter and the net screen/block
	# the release (beside/behind don't).
	var pressure_factor: float = 1.0 - _pressure(shooter, opponents, attacking_goal - shooter)
	return shot_quality * lane * pressure_factor


# Quick-shot variant of score_shoot. Two parameter swaps:
#   - predicted_goalie_pos = goalie_now (no charge window → the goalie hasn't
#     slid; the geometry sees him where he actually is, still squared to the
#     carrier, so an off-axis quick shot finds open net past him)
#   - shot_speed = PASS_SPEED_M_S (quick-shot release speed → shorter flight
#     gives the goalie even less glove/blocker reaction; slower puck also
#     closes lanes at range via lane_clear)
static func score_quick_shot(
		shooter: Vector3,
		attacking_goal: Vector3,
		goalie_now: Vector3,
		net_half_width: float,
		opponents: Array[Vector3]) -> float:
	return score_shoot(shooter, attacking_goal, goalie_now,
			net_half_width, opponents, PASS_SPEED_M_S)


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
# position and this motion estimate agree. score_shoot cuts the goalie's
# glove/blocker reaction by this fraction (a recovering goalie reads the shot
# late). A fast cross-seam one-timer leaves the goalie mid-slide → near 1; a
# static shot at a set goalie → 0.
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
	# goalie_unsettled_factor lets the caller credit a feed that catches the
	# goalie mid-slide (a cross-seam one-timer to an off-axis receiver) — the
	# off-puck staging roles pass it so they prize the back-door spot. Default
	# 0.0 keeps the position-only behaviour for callers that don't (SUPPORT).
	# Receiver shot speed stays the league default (cross-player; no teammate caps).
	var receiver_shot: float = score_shoot(
			receiver, attacking_goal, predicted_goalie_pos, net_half_width, opponents,
			WRISTER_SHOT_SPEED_M_S, goalie_unsettled_factor)
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


# Realization discount for position_potential when it prices a CARRY /
# receiver destination in the carrier's expected-value compete: potential
# is FUTURE value — its promise (a real shot) is only cashed by skating
# from `pos` to the slot — so it must pay the same per-second delay
# discount (CARRY_DELAY_DISCOUNT_PER_SEC) that every other future action
# in the model pays, over that remaining travel time.
#
# Without this, the carrier's stand-still candidate held its potential
# UNDECAYED while every movement candidate paid decay over its travel
# time; outside shooting range the potential gradient (~3%/m) is
# shallower than that decay (~4%/m at rest), so standing still strictly
# beat stepping toward the net and an open carrier PLANTED at the blue
# line ("hesitant to take space that's clearly theirs"). With the
# discount, an on-route step trades travel decay for realization decay
# one-for-one (triangle equality), the decays cancel, and the compete
# reduces to the pure positional gradient — open ice ahead always wins.
#
# Travel time is measured to the slot platform edge (SLOT_RADIUS_M — the
# ring where potential's promise becomes a real shot) at the league
# reference speed (cross-player boundary: receivers use it too).
static func potential_realization_discount(pos: Vector3,
		attacking_goal: Vector3) -> float:
	var travel_dist: float = maxf(0.0, pos.distance_to(attacking_goal) - SLOT_RADIUS_M)
	return pow(CARRY_DELAY_DISCOUNT_PER_SEC, travel_dist / SKATER_REF_SPEED_M_S)


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
			net_half_width, defenders, pass_speed)
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


# ── Pass execution risk ──────────────────────────────────────────────────────
# Even a clear-lane pass isn't a sure thing: leads run long, receptions
# fumble off an unsquared blade, a bouncing puck skips the tape. The lane
# model prices INTERCEPTION only, so before this constant existed a 5 m
# clear-lane backpass deep in our own zone scored as risk-free — and since
# fire wins ties against carry, bots eagerly dumped the puck backward for
# near-zero gain, and the occasional real-world miss surrendered all the
# ice behind them. PASS_MISS_PROB is the residual chance a lane-clear pass
# still fails on execution; the puck ends up loose PAST the receiver
# (overled / through the blade), PASS_MISS_OVERSHOOT_M beyond them along
# the pass line. Feeding that loss point to turnover_cost makes the risk
# self-localize exactly like interception risk does: an OZ miss costs ~0
# (loose puck in their end), a DZ backpass miss prices the opponent's
# chance in front of our net. No zone flag, no backpass heuristic — the
# geometry does it.
#
# Tuning: PROB up → bots demand more upside before passing anywhere the
# loss would hurt (fewer own-zone touch-passes); down → closer to the old
# interception-only model (0.0 = identical). OVERSHOOT is the physical
# "how far past the receiver does a missed pass die" scale, not a knob.
const PASS_MISS_PROB: float = 0.1
const PASS_MISS_OVERSHOOT_M: float = 3.0


# Loss point for the execution-miss mode of a pass: the puck sails past
# the receiver and dies PASS_MISS_OVERSHOOT_M beyond them on the pass
# line. Degenerate (overlapping endpoints) falls back to the receiver.
static func pass_miss_loss_point(from: Vector3, receiver: Vector3) -> Vector3:
	var dx: float = receiver.x - from.x
	var dz: float = receiver.z - from.z
	var len_sq: float = dx * dx + dz * dz
	if len_sq < 0.0001:
		return receiver
	var inv: float = PASS_MISS_OVERSHOOT_M / sqrt(len_sq)
	return Vector3(receiver.x + dx * inv, 0.0, receiver.z + dz * inv)


# ── Possession safety (poke-threat) — physical constants ─────────────────────
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
# How far a BEHIND defender must reach around the carrier's body to touch the
# puck — a physical body-width added to their effective distance. A poke from
# the defensive side is screened by the carrier, so a backside checker reads as
# less of a threat than one in front (a discount, not a wall). Grounded in body
# geometry, not a tuned weight.
const BODY_SHIELD_M: float = 0.7
# Reaction window (s) for reading the safety of a STATIC puck spot (a hold, or
# a carry DESTINATION): how far ahead we look for a closing defender to reach
# poke range. Long enough that a converging pincer registers before it arrives,
# short enough that a distant skater isn't a threat yet. A MOVING carry read
# passes the arrival time instead.
const SAFETY_WINDOW_S: float = 0.5


# Maps a defender's closest-approach distance to the puck (already body-shield
# adjusted) to a safety multiplier: FLOOR at/inside the danger radius (stick
# CAN reach), 1.0 at/outside the safe radius (time to move clear), linear in
# between. One definition shared by every safety read.
static func reach_to_safety(reach_dist: float) -> float:
	if reach_dist >= CARRY_POKE_SAFE_RADIUS_M:
		return 1.0
	if reach_dist <= CARRY_POKE_DANGER_RADIUS_M:
		return CARRY_POKE_SAFETY_FLOOR
	var t: float = (reach_dist - CARRY_POKE_DANGER_RADIUS_M) / (
			CARRY_POKE_SAFE_RADIUS_M - CARRY_POKE_DANGER_RADIUS_M)
	return lerpf(CARRY_POKE_SAFETY_FLOOR, 1.0, t)


# Unified possession-safety model: how safe the puck is over a short window,
# given where the defenders are AND where they're going. Replaces the old
# split of carry_poke_safety (a static snapshot at a spot) and
# carry_intercept_safety (convergence along a path) with ONE closest-approach:
#
#   puck(t) = lerp(puck_from, puck_to, t / window)      t in [0, window]
#   def(t)  = opp + opp_vel * t                         (dead-reckoned)
#   miss    = min over t of |def(t) - puck(t)|          (closest approach)
#
# A STATIC read (hold / carry destination) passes puck_from == puck_to with a
# reaction window (SAFETY_WINDOW_S); a MOVING read (carry candidate) passes the
# puck's start and end with the arrival time. Either way it's the defenders'
# VELOCITY that surfaces a closing pincer — the bot "sees it coming" from the
# motion, with no separate look-ahead term.
#
# `forward` is the direction the puck is carried (toward the attacking goal). A
# defender reaching the puck from BEHIND that line is screened by the carrier's
# body (BODY_SHIELD_M added to its effective distance), so a backside checker
# reads as less of a poke threat than one in front — the physical front/behind
# asymmetry, modelled directly. Pass Vector3.ZERO to disable the shield.
#
# Returns the WORST (min) per-defender safety in [FLOOR, 1.0]; 1.0 when there
# are no defenders. `opponents` and `opponent_vels` must be parallel arrays.
static func puck_safety(
		puck_from: Vector3, puck_to: Vector3, window_s: float,
		forward: Vector3,
		opponents: Array[Vector3], opponent_vels: Array[Vector3]) -> float:
	var n: int = opponents.size()
	if n == 0 or opponent_vels.size() != n:
		return 1.0
	var w: float = maxf(window_s, 0.0001)
	var inv_w: float = 1.0 / w
	var puck_vx: float = (puck_to.x - puck_from.x) * inv_w
	var puck_vz: float = (puck_to.z - puck_from.z) * inv_w
	var fwd_x: float = 0.0
	var fwd_z: float = 0.0
	var f_len: float = sqrt(forward.x * forward.x + forward.z * forward.z)
	if f_len > 0.0001:
		fwd_x = forward.x / f_len
		fwd_z = forward.z / f_len
	var worst: float = 1.0
	for i: int in n:
		var opp: Vector3 = opponents[i]
		var vel: Vector3 = opponent_vels[i]
		var dp_x: float = opp.x - puck_from.x
		var dp_z: float = opp.z - puck_from.z
		var dv_x: float = vel.x - puck_vx
		var dv_z: float = vel.z - puck_vz
		var dv_sq: float = dv_x * dv_x + dv_z * dv_z
		var t_star: float
		if dv_sq < 0.0001:
			t_star = 0.0  # parallel motion: distance constant, sample t=0
		else:
			t_star = clampf(-(dp_x * dv_x + dp_z * dv_z) / dv_sq, 0.0, w)
		# Relative position (def - puck) at closest approach.
		var mx: float = dp_x + dv_x * t_star
		var mz: float = dp_z + dv_z * t_star
		var miss: float = sqrt(mx * mx + mz * mz)
		# Body shield: a defender on the DEFENSIVE side of the puck (miss vector
		# opposite forward) reaches past the carrier — add effective distance
		# scaled by how directly behind it is.
		if miss > 0.0001 and (fwd_x != 0.0 or fwd_z != 0.0):
			var behind: float = -(mx * fwd_x + mz * fwd_z) / miss
			if behind > 0.0:
				miss += BODY_SHIELD_M * behind
		var s: float = reach_to_safety(miss)
		if s < worst:
			worst = s
	return worst



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
