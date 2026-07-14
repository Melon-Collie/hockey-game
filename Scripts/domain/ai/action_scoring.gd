class_name AIActionScoring

# Pure-function utility scoring for on-puck actions. Each score is a
# multiplicative composition of factors in [0, 1].
#
# ── Design intent: geometric xG ──────────────────────────────────────────────
# `score_shoot` approximates expected goals (xG) — the probability a shot beats
# the goalie given its geometry and the defensive context. It is a GEOMETRIC
# model, not a curve fit: it scores the best of the five goalie holes (the net
# each clears past the goalie's reaction-gated, height-appropriate cover — see
# the hole-model block below), then multiplies by lane clearance and forward-cone
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

# Value-map regime boundary: the attacking BLUE LINE. `_score_at` prices positions
# by real shot danger (score_shoot) once the CARRIER is in the offensive zone, and
# by position_potential (the progression value map) while the carrier is outside
# it. The two scales never have to be compared: because of offsides a bot in the
# O-zone never evaluates an out-of-zone spot (the valve prunes them), and a carrier
# outside prices EVERY candidate — including the entry target — on the position_
# potential scale. So the O-zone is pure xG's domain (goalie-aware, better than any
# positional proxy there), and it needs no establishment floor: entry is driven by
# position_potential, which already climbs from the blue line toward the slot, so an
# in-zone target out-scores staying outside on that one shared scale. The only
# in-vs-out decision is the choice to CARRY into the zone (there is no dump-and-
# chase), and it is made entirely in position_potential currency.

# Position-potential closeness ramp. position_potential is only used
# by `_score_at` while the CARRIER is OUTSIDE the offensive zone —
# once in the zone the bot prices real shot danger (score_shoot) alone.
# So closeness only needs to give a sensible "anywhere on the
# rink toward the slot is better than further away" gradient for
# positioning bots — and, since it climbs monotonically toward the slot,
# it is also what pulls a carrier across the blue line into the zone.
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

# ── Shot danger: hole-based open-net model ───────────────────────────────────
# score_shoot rates a shot by evaluating the classic goalie "holes" as separate
# targets, taking the BEST one. The score is that hole's opening; which hole it is
# decides the LOFT the bot shoots (best_shot_loft). This is pure geometry from the
# shooter's eye — distance, angle, and coverage all EMERGE (see _hole_open_angle)
# — with the goalie a body that occludes part of the net.
#
#   1,2  top corners      → HIGH loft (over the glove/blocker held up in stance)
#   3,4  bottom corners    → FLAT      (beside the pads)
#   5    five-hole         → FLAT      (between the legs — opens when he's moving)
#
# HIGH holes are ARRIVAL-HONEST: the loft is a fixed vertical launch speed, so
# whether the arc physically reaches the top band at the net is a range × pace
# fact. They're evaluated (and fired — best_shot_power_t) at the fastest pace
# whose arc still arrives above the pad-top seam, and zeroed where no
# legal power gets there — see the block at _high_band_horizontal_speed. A DOWN
# goalie concedes the top band's arm extension (the butterfly's defining
# trade); a standing set goalie's glove has the whole soft-arc flight to
# deploy, which is what actually shuts the top shelf against a set keeper.
#
# (The armpit / body-side seam is deliberately absent — it only opens when the
# goalie commits his arm elsewhere, a condition this model can't see, so a static
# seam would be a phantom target. Re-add it only with a real arm-commitment model.)
#
# The goalie FREEZES on the shot (he can't slide into it), so the only thing
# range buys him is REACTION time to extend the relevant body part to the
# placement. The reaction budget is the puck's travel time to the GOALIE'S
# BODY (t_reach — the shooter→goalie gap at the band's pace), NOT the flight
# to the goal line: the save happens where the puck crosses his reach
# envelope, which a challenging keeper puts a large fraction of the flight
# closer to the shooter. Budgeting on flight-to-net silently handed him the
# whole flight to deploy — from 4 m a top-band arc that passes him at 0.14 s
# (before his 0.18 s arm read even fires) was scored against a 0.25 s
# flight-to-net and read as glove-covered; that error is what made a set
# keeper an unbeatable wall from everywhere. Each hole reads its own height
# BAND, and the bands differ in exactly the two ways a real goalie's do — a
# wider always-covered CORE and a slower REACTION — which is what makes the
# loft choice fall out of the same geometry:
#   cover = CORE + EXT × reaction ;  reaction = clamp((t_reach − DELAY)/DEPLOY,0,1)
#   openness = the net bearing interval the hole clears past the cover's BODY-DISC
#              tangent cone (he squares to the puck, so the cover half-width faces
#              every sightline — sharp angles are walled by his depth), minus the
#              puck's clean-entry fit inset and the shooter's execution spread
# Aggressive angle-challenging (the goalie plays OUT for a longer shot) is not a
# constant — it's just where the goalie actually is, fed in as goalie_pos.
#
# The band cores/reaches are grounded, not fitted:
#  · LOW  — legs/pads. STANDING, the instant core is only the pad column
#           (LOW_CORE_STANDING_M, from the live stance anatomy); the 0.60
#           butterfly core exists only after the leg read + pads-to-floor
#           drop (GOALIE_BUTTERFLY_DROP_S — the same gate the five-hole seal
#           runs), so an in-tight low shot beats the drop exactly as it does
#           against the live keeper. A DOWN goalie is already sealed at 0.60.
#  · HIGH — glove/blocker, NARROWEST core (held up they leave the top corners)
#           but the longest reach (out to 0.85 m ≈ glove_max_x_outward) on a slow
#           ARM reaction. In tight the glove can't extend → roof it; at range it
#           gets there → top corners shut. This is the over-the-shoulder read.
# Total HIGH reach (CORE+EXT = 0.85) mirrors the live goalie's glove_max_x_outward.
# (There is no MID/armpit band: the body-side seam only opens when the goalie
# commits his arm elsewhere, a condition this model can't see, so a static seam
# would be a phantom opening — dropped until a real arm-commitment model exists.)
const HOLE_BAND_CORE: Array[float] = [0.60, 0.40]   # [LOW, HIGH] half-width, fully deployed
# Standing LOW core: the pad column a standing goalie covers with NO reaction —
# stance pad center + half a pad box, mirrored from the live goalie's stance
# anatomy (GoalieBehaviorRules). Everything between this and HOLE_BAND_CORE[LOW]
# only exists once the butterfly drop lands.
const LOW_CORE_STANDING_M: float = (
		GoalieBehaviorRules.STANDING_PAD_CENTER_X_M
		+ GoalieBehaviorRules.PAD_BOX_WIDTH_M * 0.5)
const HOLE_BAND_EXT: Array[float] = [0.15, 0.45]    # reaction-gated extension to the placement
const HOLE_BAND_LOFT: Array[int] = [                       # loft the band's hole is shot with
		ShotMechanics.ELEVATION_FLAT,   # LOW  → flat
		ShotMechanics.ELEVATION_HIGH,   # HIGH → roof it
]
const GOALIE_ARM_DEPLOY_S: float = 0.09   # reaction ramp width — time to extend to the placement.
										  # Hard baseline: HIGH-band EXT (0.45) / glove_react_max_speed
										  # (5.0) ≈ 0.09 s to cover the reaction-gated reach. The live
										  # value tracks the tier via set_goalie_profile.


# Per-band reaction delay (legs fast, arms slow) — the difficulty-synced read
# latencies (see set_goalie_profile below).
static func _band_delay(band: int) -> float:
	return goalie_arm_delay_s if band == HOLE_BAND_HIGH else goalie_leg_delay_s

# ── HIGH-band arrival honesty ─────────────────────────────────────────────────
# A HIGH hole is only a real target if the shot's arc physically ARRIVES above
# the goalie's pad column. Loft is a FIXED vertical launch speed
# (GameRules.DEFAULT_LOFT_VY_HIGH_M_S), so arrival height is pure kinematics of
# range × pace: a full-power HIGH wrister from 5 m crosses the line at belly
# height — a shot into the chest, not the top corner (exactly the "bots roof it
# into the goalie's chest" bug). The model therefore evaluates HIGH holes at
# the fastest pace whose arc still arrives at/above the band floor
# (_high_band_horizontal_speed) — the real range/charge trade a human plays —
# and zeroes them when no legal power reaches the band (point-blank, or so far
# out the arc has sagged back below it). best_shot_power_t exposes the solved
# pace so the bot fires the shot it actually scored.
#
# The band floor is the PAD-TOP SEAM (GameRules.DEFAULT_GOALIE_PAD_TOP_SEAM_M
# — the goalie's real 0.86 m pad/torso boundary, mirrored from his stance
# anatomy): below it the shot is contested by the pad column the LOW band
# models; above it by the torso + reaction-gated arms the HIGH band models.
const GRAVITY_M_S2: float = 9.8   # engine default the airborne puck falls under


# The fastest HORIZONTAL pace whose HIGH-loft arc still arrives at/above the
# band floor at `dist` — i.e. the pace the bot should shoot a top-band look at.
# Returns 0.0 when no legal wrister power puts the arrival in the band:
#   · in tight, even the min-power arc hasn't risen to the floor yet;
#   · at long range, every legal arc has fallen back below it.
static func _high_band_horizontal_speed(dist: float, shot_speed_m_s: float) -> float:
	var vy: float = GameRules.DEFAULT_LOFT_VY_HIGH_M_S
	var disc: float = vy * vy - 2.0 * GRAVITY_M_S2 * GameRules.DEFAULT_GOALIE_PAD_TOP_SEAM_M
	if disc <= 0.0:
		return 0.0  # the loft's apex sits below the band floor — no high shot exists
	var root: float = sqrt(disc)
	var t_first: float = (vy - root) / GRAVITY_M_S2   # arc rises through the floor
	var t_last: float = (vy + root) / GRAVITY_M_S2    # arc falls back through it
	if t_first <= 0.0001:
		return 0.0
	var v_h_ceiling: float = dist / t_first    # any faster arrives below the band
	var v_h_floor_geom: float = dist / t_last  # any slower has already sagged back
	var v_h_full: float = sqrt(maxf(shot_speed_m_s * shot_speed_m_s - vy * vy, 0.0))
	var v_h_min_power: float = sqrt(maxf(
			GameRules.DEFAULT_WRISTER_POWER_MIN_M_S * GameRules.DEFAULT_WRISTER_POWER_MIN_M_S
					- vy * vy,
			0.0))
	var v_h: float = minf(v_h_full, v_h_ceiling)
	if v_h < maxf(v_h_floor_geom, v_h_min_power):
		return 0.0
	return v_h


# Horizontal pace (m/s) of a shot at hole band `band` over `dist` to the net —
# HIGH holes fly at the arrival-honest solved pace (or 0.0 when the band is
# unreachable), FLAT bands at the committed full pace. The five-hole rides the
# LOW band. Divides the shooter→goalie gap for the reach budget (t_reach).
static func _band_pace(band: int, dist: float, shot_speed_m_s: float) -> float:
	if band == HOLE_BAND_HIGH:
		return _high_band_horizontal_speed(dist, shot_speed_m_s)
	return maxf(shot_speed_m_s, 1.0)


# The goalie's covered half-width (m) for a band, given the reach budget
# `t_reach` (puck's travel time to HIS body). One implementation shared by
# _hole_open_angle and _hole_aim_x so aim and score always read the same edge.
#   HIGH: stance core + the reaction-gated arm extension; a DOWN goalie's glove
#         starts at pad height, so the extension is conceded entirely (the
#         butterfly's defining trade).
#   LOW:  standing pad column, widened to the butterfly core by the drop gate
#         (leg delay + pads-to-floor time — the same gate the five-hole seal
#         runs), plus the small reaction-gated pad push. A DOWN goalie is
#         already sealed at the butterfly core.
static func _band_cover(
		band: int, t_reach: float, eff_unsettled: float, goalie_down: bool) -> float:
	var reaction: float = clampf(
			(t_reach - _band_delay(band)) / goalie_arm_deploy_s, 0.0, 1.0)
	reaction *= 1.0 - eff_unsettled
	if band == HOLE_BAND_HIGH:
		if goalie_down:
			reaction = 0.0
		return HOLE_BAND_CORE[HOLE_BAND_HIGH] + HOLE_BAND_EXT[HOLE_BAND_HIGH] * reaction
	var core: float = HOLE_BAND_CORE[HOLE_BAND_LOW]
	if not goalie_down:
		var drop: float = clampf(
				(t_reach - _band_delay(HOLE_BAND_LOW)) / goalie_butterfly_drop_s,
				0.0, 1.0)
		core = lerpf(LOW_CORE_STANDING_M, HOLE_BAND_CORE[HOLE_BAND_LOW], drop)
	return core + HOLE_BAND_EXT[HOLE_BAND_LOW] * reaction

# Loft choice prefers the LOWEST-risk shot among comparable openings: a flat shot
# is easier to execute than roofing it (you can sail a high shot over the bar). So
# best_shot_loft takes the flattest hole whose opening is within this fraction of
# the widest — only committing to a roof when the top corner is meaningfully the
# only way in. (The SCORE is still the widest opening; this only picks the loft.)
const LOFT_TIE_FRAC: float = 0.85
const HOLE_BAND_LOW: int = 0
const HOLE_BAND_HIGH: int = 1

# Hole kinds (how the opening is measured — see _hole_open_angle).
const HOLE_KIND_CORNER: int = 0   # net-relative post; opening = net cleared past the cover edge
const HOLE_KIND_FIVE: int = 1     # goalie-relative low-centre gap; opens when he's UNSETTLED

# The five holes as parallel arrays (indexed 0..4, no per-call allocation).
const HOLE_KIND: Array[int] = [
		HOLE_KIND_CORNER, HOLE_KIND_CORNER,   # 1,2 top corners
		HOLE_KIND_CORNER, HOLE_KIND_CORNER,   # 3,4 bottom corners
		HOLE_KIND_FIVE,                       # 5   five-hole
]
const HOLE_SIDE: Array[int] = [-1, 1, -1, 1, 0]   # net/goalie side; 0 = centred
const HOLE_BAND: Array[int] = [
		HOLE_BAND_HIGH, HOLE_BAND_HIGH,
		HOLE_BAND_LOW, HOLE_BAND_LOW,
		HOLE_BAND_LOW,
]
const HOLE_COUNT: int = 5

# Five-hole: a set goalie seals it; it opens as he's caught moving (the
# goalie_unsettled_factor, faded over flight — see UNSETTLE_RECOVERY_S). Modeled
# as a physical GAP between the splayed pads, so its angular size FORESHORTENS
# with range like any real target (gap / distance) — a five-hole from the point is
# a sliver, from in tight a real opening. Only a roughly head-on look can thread
# the legs (centrality falls off past FIVE_CENTER_REF_M of lateral offset).
const FIVE_GAP_M: float = 0.18
const FIVE_CENTER_REF_M: float = 1.6

# A goalie caught moving (goalie_unsettled_factor) doesn't stay caught for the
# whole shot: over a longer flight he decelerates the slide and re-squares. So the
# unsettled bonus FADES with the shot's flight time — full on a point-blank
# one-timer, gone by the time a long shot arrives. This is what stops a bot from
# rating a cross-ice shot at a mid-slide goalie as a chance: the goalie recovers
# before the puck gets there. Roughly a goalie's slide-stop + re-square time.
const UNSETTLE_RECOVERY_S: float = 0.35

# Danger gain: converts the best hole's open angle (radians) into the game's
# shot-value currency — the ONE feel scalar left. Set so a clean cross-seam
# one-timer lands ~0.7 and a gaping backdoor net saturates to 1.0.
const SHOT_DANGER_GAIN: float = 3.0

# Goalie position prediction. React-then-push: react delay first, then move
# toward the puck-at-release X — ACCELERATING onto the edge (the live keeper's
# lateral_accel ramp) up to max push speed, never snapping to it. The ramp is
# what a hard lateral cut in tight genuinely beats: over a sub-quarter-second
# release window an accelerating keeper covers centimetres where a snap-to-speed
# model covered half a metre and read every deke as tracked. The reaction delay
# and accel ramp are difficulty-synced (set_goalie_profile); the top speed is a
# const because no tier varies GoalieController.t_push_speed.
const GOALIE_MAX_LATERAL_SPEED_MPS: float = GameRules.DEFAULT_GOALIE_T_PUSH_SPEED_M_S

# Pads-to-floor time once the goalie commits the butterfly — the Hard baseline,
# mirroring GoalieController.butterfly_drop_speed (0.20 s, grounded on the
# measured pro drop velocity of 2.07 m/s — realism audit F2; the live value
# tracks the tier via set_goalie_profile below). With the legs reaction delay in
# front of it, this is how fast a STANDING goalie seals low after reading a
# release — gating both the five-hole slot and the LOW band's widening from the
# standing pad column to the butterfly core (_band_cover). Raced against the
# puck reaching HIS body (t_reach): releases inside the delay leave low fully
# open (the in-tight window), releases past delay + drop meet closed pads.
const GOALIE_BUTTERFLY_DROP_S: float = 0.20

# ── Difficulty-synced goalie read model ───────────────────────────────────────
# The scorer predicts the LIVE goalie, and the live goalie's reads vary with the
# match's GoalieSkillProfile — so the mirrored knobs are static vars, synced via
# set_goalie_profile wherever GameManager selects goalie_skill_profile. Defaults
# are the Hard/authored baselines, so unwired contexts (unit tests, threat
# surfaces) score exactly the ceiling goalie. Without the sync the bots would
# model a Hard goalie on every tier and pass up shots that genuinely beat a
# weaker one. Statics (not per-call params) because the model threads ~every
# scoring entry point; one goalie difficulty exists per match, set only at match
# config / free-play picker time — never per tick.
static var goalie_leg_delay_s: float = GameRules.DEFAULT_GOALIE_REACTION_DELAY_S
static var goalie_arm_delay_s: float = GameRules.DEFAULT_GOALIE_ARM_REACTION_DELAY_S
static var goalie_butterfly_drop_s: float = GOALIE_BUTTERFLY_DROP_S
static var goalie_lateral_accel_m_s2: float = GameRules.DEFAULT_GOALIE_LATERAL_ACCEL_M_S2
static var goalie_arm_deploy_s: float = GOALIE_ARM_DEPLOY_S


# Sync the goalie read model to the match's difficulty tier. Call with
# GoalieSkillProfile.hard() to restore the baseline (tests must restore).
static func set_goalie_profile(profile: GoalieSkillProfile) -> void:
	goalie_leg_delay_s = profile.reaction_delay_s
	goalie_arm_delay_s = profile.arm_reaction_delay_s
	goalie_butterfly_drop_s = profile.butterfly_drop_s
	goalie_lateral_accel_m_s2 = profile.lateral_accel_mps2
	# Deploy ramp = reaction-gated reach / arm speed (see GOALIE_ARM_DEPLOY_S).
	goalie_arm_deploy_s = HOLE_BAND_EXT[HOLE_BAND_HIGH] / profile.glove_react_max_speed_mps


# Lateral distance a goalie push covers in `move_time` (post-reaction), on the
# accelerate-then-cruise profile: ½·a·t² until the push reaches t_push speed,
# linear after. The inverse of _goalie_lateral_time.
static func _goalie_lateral_reach(move_time: float) -> float:
	if move_time <= 0.0:
		return 0.0
	var t_ramp: float = GOALIE_MAX_LATERAL_SPEED_MPS / goalie_lateral_accel_m_s2
	if move_time <= t_ramp:
		return 0.5 * goalie_lateral_accel_m_s2 * move_time * move_time
	return 0.5 * goalie_lateral_accel_m_s2 * t_ramp * t_ramp \
			+ GOALIE_MAX_LATERAL_SPEED_MPS * (move_time - t_ramp)


# Time a goalie push needs to cover `dist` laterally (post-reaction) — the
# inverse of _goalie_lateral_reach.
static func _goalie_lateral_time(dist: float) -> float:
	if dist <= 0.0:
		return 0.0
	var t_ramp: float = GOALIE_MAX_LATERAL_SPEED_MPS / goalie_lateral_accel_m_s2
	var ramp_dist: float = 0.5 * goalie_lateral_accel_m_s2 * t_ramp * t_ramp
	if dist <= ramp_dist:
		return sqrt(2.0 * dist / goalie_lateral_accel_m_s2)
	return t_ramp + (dist - ramp_dist) / GOALIE_MAX_LATERAL_SPEED_MPS

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
# Fraction of top skating speed a defender covers LATERALLY sliding into a lane
# (you close a passing lane sideways, not at full straight-line speed). Per-
# defender close speed is this × the defender's real max_speed (Speed).
const LANE_LATERAL_FRACTION: float = 0.5
const LANE_DEFENDER_CLOSE_SPEED_M_S: float = LANE_LATERAL_FRACTION * GameRules.DEFAULT_SKATER_MAX_SPEED_M_S

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

# Target ARRIVAL speed at the receiver — the "magnet" pace a bot aims to hit its
# teammate at. Crisp enough to beat a defender's reaction and shrink the pass's
# hang time (which the EV's time-decay penalizes), yet still catchable: reception
# judges RECEIVER-RELATIVE speed (deflects a poorly-angled blade only above
# deflect_min_speed 22 relative; a squared blade catches to 30), so 21.5 catches
# a stationary receiver at any angle, and a led receiver skating WITH the pass
# sees it slower still — only a receiver closing hard on the feed needs to square
# up. Every bot pass now aims for the SAME crisp arrival speed regardless of
# distance — the earlier
# distance-ramp made close feeds far too soft (down toward the ~11 m/s floor),
# which both looked weak and, via the longer flight time, made the EV under-value
# passing relative to holding/shooting.
# Target CLOSING speed at reception — the puck's speed in the RECEIVER'S frame
# when it arrives, which is what PuckReceptionRules judges (#373). Under that
# model's ceilings (any-angle catch ≤ deflect_min 22, squared ≤ 30), 20 sits
# comfortably under the any-angle bar, so a magnet-pace feed catches at ANY
# blade angle with margin — the documented "~20 m/s, always catch" pass. Held
# constant across distance (friction-compensated below) and, when the receiver's
# velocity is supplied, across the receiver's motion too: pass_launch_speed
# solves the world launch so the puck lands on the tape at THIS closing speed
# whether the receiver is streaking onto a lead feed or curling back to it.
const PASS_TARGET_CLOSING_M_S: float = 20.0

# Reference charged-pass speed (~mid-ramp). No longer a fixed release target —
# pass speed is distance-adaptive via pass_launch_speed — but kept as a
# representative pass speed for lane/threat tests and any caller that wants a
# single "typical charged pass" number.
const PASS_CHARGE_SPEED_M_S: float = (
		GameRules.DEFAULT_WRISTER_POWER_MIN_M_S
		+ (GameRules.DEFAULT_WRISTER_POWER_MAX_M_S
				- GameRules.DEFAULT_WRISTER_POWER_MIN_M_S) * 0.5)

# Pass LAUNCH speed backed out of the target CLOSING speed: fire hard enough that
# the puck arrives on the tape at PASS_TARGET_CLOSING_M_S in the receiver's frame
# after shedding ice friction over the pass distance.
#
# Two corrections stack:
#   1. Friction (always): v_world_arrival → v_launch = sqrt(v_arrival² + 2·a·d),
#      constant decel a = PUCK_ICE_DECEL_M_S2. Tiny (~0.5 m/s²), well under 1 m/s
#      even on a long pass.
#   2. Receiver motion (when receiver_vel/pass_dir supplied): reception judges the
#      puck's speed in the RECEIVER'S frame, so the WORLD arrival speed must be set
#      so |v_arrival·pass_dir − receiver_vel| = PASS_TARGET_CLOSING_M_S. Solving that
#      quadratic for the world arrival speed w:
#        w = (pass_dir·receiver_vel) + sqrt(max(0, closing² − |receiver_vel_⊥|²)),
#      i.e. cancel the receiver's along-pass motion (fire harder onto a streaking
#      receiver, softer to one curling back) and accept its unavoidable lateral
#      component. If the lateral speed alone exceeds the target, the discriminant
#      floors to 0 and w = the along component — the softest catchable feed
#      possible. With no receiver_vel this reduces to w = PASS_TARGET_CLOSING_M_S
#      (the static-receiver case), so distance-only callers are unchanged.
#
# Clamped to max_launch — the passer's own max wrister (its hardest possible
# pass), or the league default for opponent threat modeling.
#
# speed_scale is the difficulty pace knob (BotSkillProfile.pass_speed_scale),
# applied AFTER the clamp so an easier bot's passes drop below the magnet pace —
# that's the point: a slower puck the human can read and pick off. Defaults to
# 1.0, so the cross-player threat model (expected_pass_speed) and all unscaled
# callers see the full magnet pace.
static func pass_launch_speed(distance: float, max_launch: float,
		speed_scale: float = 1.0,
		receiver_vel: Vector3 = Vector3.ZERO,
		pass_dir: Vector3 = Vector3.ZERO) -> float:
	var world_arrival: float = PASS_TARGET_CLOSING_M_S
	if pass_dir.length_squared() > 0.0001:
		var along: float = pass_dir.dot(receiver_vel)
		var perp_sq: float = maxf(0.0, receiver_vel.length_squared() - along * along)
		var disc: float = PASS_TARGET_CLOSING_M_S * PASS_TARGET_CLOSING_M_S - perp_sq
		world_arrival = along + sqrt(maxf(0.0, disc))
		# A receiver charging the passer harder than the target could drive this
		# negative/tiny; floor at the soft-pass minimum so we still fire a real pass.
		world_arrival = maxf(world_arrival, GameRules.DEFAULT_WRISTER_POWER_MIN_M_S)
	var launch: float = sqrt(
			world_arrival * world_arrival
			+ 2.0 * GameRules.PUCK_ICE_DECEL_M_S2 * maxf(distance, 0.0))
	return clampf(launch, GameRules.DEFAULT_WRISTER_POWER_MIN_M_S, max_launch) * speed_scale

# ── Saucer pass ──────────────────────────────────────────────────────────────
# A saucer (LOW-loft) pass lofts the puck off the ice so it flies over a
# defender's grounded stick mid-lane and settles back down before the
# receiver. The whole flight profile is pure kinematics of the LOW loft's
# fixed vertical launch (GameRules.DEFAULT_LOFT_VY_LOW_M_S) under gravity —
# no shape parameters:
#
#   hang time      T_hang = 2·vy / g                       (~0.45 s)
#   over window    [t_over, t_down] where y(t) exceeds the blade plane
#                  (GameRules.PUCK_AIRBORNE_HEIGHT_M — the same on-ice/
#                  off-ice gate PuckReceptionRules.blade_can_interact uses,
#                  so "over a grounded stick" here means exactly what the
#                  live reception physics enforces)
#   airborne carry = launch speed × T_hang (no ice friction in the air)
#
# Inside the over window a defender's reach collapses to their BODY radius
# — you can't react a grounded blade up into a puck overhead, but you
# can't fly a low flip through a torso either. Outside it (just off the
# blade, or landed) a stick intercepts normally — a stick already on the
# puck at release still stuffs the flip.
#
# Because the airborne carry scales with LAUNCH SPEED, a soft flip is the
# close-quarters tool: fired at ~11 m/s an 8 m feed clears a mid-lane
# stick and still lands with runway, while the same feed at the crisp
# ~20 m/s magnet pace would arrive still airborne — and an airborne puck
# flies OVER the receiver's grounded blade (blade_can_interact), so it
# isn't a pass at all. saucer_max_launch_speed is that receivability
# bound; the carrier picks min(normal pace, that bound) and lets the EV
# compete decide if the softer, longer-hanging flip beats the flat lane.

# Grounded slide runway the saucer must land with before the receiver's
# tape: the puck has to be back on the blade plane — landed and settled
# out of its touch-down skip — for a grounded blade to play it.
const SAUCER_LANDING_RUN_M: float = 2.0

# If the grounded lane is already this clear, never bother scoring a
# saucer variant — there's no defender worth lofting over (and the flip
# carries extra execution risk for nothing).
const SAUCER_SKIP_WHEN_LANE_CLEAR: float = 0.85

# Extra execution-miss probability a saucer adds on top of PASS_MISS_PROB:
# the flip-and-land is fiddlier than a flat feed — the touch-down can skip
# or wobble off line. This is the natural margin in the grounded-vs-saucer
# EV compete: the loft only wins when the lane it clears is worth more
# than the added landing risk.
const SAUCER_EXTRA_MISS_PROB: float = 0.05


# Time a LOW-loft puck spends off the ice (launch to touch-down).
static func saucer_hang_time_s() -> float:
	return 2.0 * GameRules.DEFAULT_LOFT_VY_LOW_M_S / GRAVITY_M_S2


# Horizontal distance a saucer launched at `launch_speed` covers before
# touching back down. No ice friction while airborne, so it's linear.
static func saucer_airborne_distance_m(launch_speed: float) -> float:
	return launch_speed * saucer_hang_time_s()


# The fastest launch that still LANDS with SAUCER_LANDING_RUN_M of grounded
# slide before a receiver `distance` away — the receivability bound (an
# airborne arrival flies over the tape). Negative/tiny for very short
# feeds: below min wrister pace there is no legal saucer, the physical
# floor on saucer distance (~6.5 m at the 10 m/s soft-touch minimum).
static func saucer_max_launch_speed(distance: float) -> float:
	return (distance - SAUCER_LANDING_RUN_M) / saucer_hang_time_s()


# Returns the LAUNCH speed a pass from `shooter` to `receiver` will fire at — set
# so the puck arrives at the magnet pace (see pass_launch_speed), a hair above the
# target arrival speed to cover friction. Capped at the league default max wrister
# here; the passer's own scoring/execution uses its own max
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
#   carry_score = score_at(destination) × delay_discount(time_to_destination)
#
# ── The delay discount (see delay_discount / READ_VALIDITY_TAU_S below) ────────
# A future action (a carry that arrives in `t` s, a pass in flight, a spot whose
# shot must still be skated to) is worth less than the same value NOW, because the
# tactical read it was scored against decays over time: a defender commits, a lane
# closes, the puck situation turns. This is the survival function of a
# CONSTANT-HAZARD process — at each instant a fixed probability the read stops
# holding — so it is exactly geometric, exp(-t / τ). It is NOT a shaped curve; the
# ONLY free parameter is the hazard timescale τ = READ_VALIDITY_TAU_S, the mean
# time a read stays roughly valid. (The old per-second form pow(0.7, t) was the
# same model written the opaque way — 0.7/s is exp(-1/2.8 s), i.e. τ ≈ 2.8 s.)
#
# τ is an honest AGGREGATE, not a derived quantity: plausible physical
# decorrelation times span ~0.4 s (a defender closing a stick-width) to a
# rush-scale several seconds, so there is no single number to derive it from — it
# is the one "how much do I trust the near future" feel dial, now stated as the
# physical quantity it represents rather than a bare rate. Raise it for more
# patient play (more developing feeds / cross-ice / hold-for-the-backdoor), lower
# it for more direct, take-what's-there play. Applied uniformly to every future
# action so an on-route step trades travel time for realization decay one-for-one.
#
# Calibration caveat (from the value sweep): the unit suite guards the IMPATIENT
# edge (breakouts / developing feeds / walkouts start failing below ~0.7/s ↔
# τ ≈ 2.8 s). The PATIENT edge is pinned at the parameter level by
# test_delay_discount_bounds_patience (patience can't be cranked to "the future
# is free") — but whether a longer τ PLAYS better is a feel judgment, a playtest
# call the suite can't settle.
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
# Mean seconds a tactical read stays roughly valid (the hazard timescale above).
# τ ≈ 4.5 s ↔ a ~0.80 per-second discount — raised from the prior τ ≈ 2.8 s
# (0.70/s) toward more patient, developing-play-friendly carrying. See the sweep
# caveat above: this is the patient side, judged by feel, not by the suite.
const READ_VALIDITY_TAU_S: float = 4.5
const ACTION_HYSTERESIS_MARGIN_FRAC: float = 0.15


# Value multiplier for a play `delay_s` seconds in the future — constant-hazard
# survival, exp(-delay_s / READ_VALIDITY_TAU_S). One chokepoint for the delay
# discount (see the block above): every future-action scorer routes through here
# so the entropy model lives in exactly one place. Allocation-free.
static func delay_discount(delay_s: float) -> float:
	return exp(-maxf(delay_s, 0.0) / READ_VALIDITY_TAU_S)


# Geometric shot danger in [0, 1]: the best of the five goalie holes, seen from
# the shooter's eye, with the goalie a body that occludes part of the net.
# Distance, angle, squareness, and reaction all emerge from the geometry — no
# curves. Each hole is scored by _hole_open_angle (its opening in radians); the
# danger is the widest opening × SHOT_DANGER_GAIN. best_shot_loft returns the
# same winner's elevation class so the shot's loft matches where it's aimed.
# He FREEZES on the shot, so reaction is body-part REACH to the placement, not a
# slide; the reach is raced against the puck arriving at HIS body (t_reach), so
# range buys it and a quick in-tight release beats it — an unsettled goalie
# loses it either way.
static func open_net_danger(
		shooter: Vector3, attacking_goal: Vector3, goalie_pos: Vector3,
		net_half_width: float, shot_speed_m_s: float,
		goalie_unsettled_factor: float = 0.0,
		goalie_five_hole_m: float = -1.0, goalie_down: bool = false,
		goalie_post_seal_x: float = 0.0,
		goalie_post_seal_tall: bool = false,
		aim_spread_rad: float = 0.0) -> float:
	# Best of the holes. Pure value-type math, no allocation — safe to run
	# per carry candidate at tick rate (see _hole_open_angle). Pace is per-band
	# inside _hole_open_angle: HIGH holes fly at the arrival-honest solved pace,
	# flat bands at the committed full pace; the reach budget divides the
	# shooter→goalie gap by it.
	var best_angle: float = 0.0
	for i: int in HOLE_COUNT:
		var a: float = _hole_open_angle(i, shooter, attacking_goal, goalie_pos,
				net_half_width, shot_speed_m_s, goalie_unsettled_factor,
				goalie_five_hole_m, goalie_down,
				goalie_post_seal_x, goalie_post_seal_tall, aim_spread_rad)
		if a > best_angle:
			best_angle = a
	return clampf(best_angle * SHOT_DANGER_GAIN, 0.0, 1.0)


# The LOFT the bot should shoot with, from the same hole geometry that
# open_net_danger scores: the elevation class of the CHOSEN hole (see
# _choose_shot_hole). A slot shot whose only opening is over the shoulder returns
# HIGH; a five-hole off a caught-moving goalie returns FLAT; a body-side seam
# returns LOW. Called once when SHOOT commits, so the re-scan is free.
static func best_shot_loft(
		shooter: Vector3, attacking_goal: Vector3, goalie_pos: Vector3,
		net_half_width: float, shot_speed_m_s: float,
		goalie_unsettled_factor: float = 0.0,
		goalie_five_hole_m: float = -1.0, goalie_down: bool = false,
		goalie_post_seal_x: float = 0.0,
		goalie_post_seal_tall: bool = false,
		aim_spread_rad: float = 0.0) -> int:
	var hole: int = _choose_shot_hole(shooter, attacking_goal, goalie_pos,
			net_half_width, shot_speed_m_s, goalie_unsettled_factor,
			goalie_five_hole_m, goalie_down,
			goalie_post_seal_x, goalie_post_seal_tall, aim_spread_rad)
	if hole < 0:
		return ShotMechanics.ELEVATION_FLAT
	return HOLE_BAND_LOFT[HOLE_BAND[hole]]


# The release power fraction (0..1 over the bot's wrister band) for the CHOSEN
# hole — the third leg of the loft/aim/power triple, all from one chooser. A
# HIGH hole returns the arrival-honest pace (_high_band_horizontal_speed): the
# fastest release whose arc still ARRIVES in the top band at this range — the
# real range/charge trade behind a top-corner shot (soft flip in tight, full
# rip from range). Flat-band holes (corners past the pads, five-hole) and the
# no-hole fallback fire full power.
static func best_shot_power_t(
		shooter: Vector3, attacking_goal: Vector3, goalie_pos: Vector3,
		net_half_width: float, shot_speed_m_s: float,
		goalie_unsettled_factor: float = 0.0,
		goalie_five_hole_m: float = -1.0, goalie_down: bool = false,
		goalie_post_seal_x: float = 0.0,
		goalie_post_seal_tall: bool = false,
		aim_spread_rad: float = 0.0) -> float:
	var hole: int = _choose_shot_hole(shooter, attacking_goal, goalie_pos,
			net_half_width, shot_speed_m_s, goalie_unsettled_factor,
			goalie_five_hole_m, goalie_down,
			goalie_post_seal_x, goalie_post_seal_tall, aim_spread_rad)
	if hole < 0 or HOLE_BAND[hole] != HOLE_BAND_HIGH:
		return 1.0
	var v_h: float = _high_band_horizontal_speed(
			shooter.distance_to(attacking_goal), shot_speed_m_s)
	if v_h <= 0.0:
		return 1.0  # unreachable band can't be the chosen hole; defensive only
	var vy: float = GameRules.DEFAULT_LOFT_VY_HIGH_M_S
	var v: float = sqrt(v_h * v_h + vy * vy)
	var band: float = maxf(
			shot_speed_m_s - GameRules.DEFAULT_WRISTER_POWER_MIN_M_S, 0.001)
	return clampf((v - GameRules.DEFAULT_WRISTER_POWER_MIN_M_S) / band, 0.0, 1.0)


# The world aim POINT (on the net plane, y = 0) of the CHOSEN hole — the exact
# target the loft was picked for, so aim and loft always describe the same hole.
# The state machine locks this as the wrister aim at charge start. Falls back to
# the goal centre if the goalie leaves nothing (defensive — SHOOT only commits
# when there's an opening).
static func best_shot_aim(
		shooter: Vector3, attacking_goal: Vector3, goalie_pos: Vector3,
		net_half_width: float, shot_speed_m_s: float,
		goalie_unsettled_factor: float = 0.0,
		goalie_five_hole_m: float = -1.0, goalie_down: bool = false,
		aim_spread_rad: float = 0.0,
		goalie_post_seal_x: float = 0.0,
		goalie_post_seal_tall: bool = false) -> Vector3:
	var hole: int = _choose_shot_hole(shooter, attacking_goal, goalie_pos,
			net_half_width, shot_speed_m_s, goalie_unsettled_factor,
			goalie_five_hole_m, goalie_down,
			goalie_post_seal_x, goalie_post_seal_tall, aim_spread_rad)
	if hole < 0:
		return Vector3(attacking_goal.x, 0.0, attacking_goal.z)
	var aim_x: float = _hole_aim_x(hole, shooter, attacking_goal, goalie_pos,
			net_half_width, shot_speed_m_s, goalie_unsettled_factor, aim_spread_rad,
			goalie_down)
	return Vector3(aim_x, 0.0, attacking_goal.z)


# Picks the shot hole the bot commits to: the widest opening, then tie-broken
# toward the FLATTEST loft within LOFT_TIE_FRAC of it (bury it low if you can,
# roof it only when the top corner is the real way in), and within that flattest
# tier the widest opening. Returns the hole index, or -1 if nothing is open. One
# chooser shared by best_shot_loft and best_shot_aim so they never disagree.
static func _choose_shot_hole(
		shooter: Vector3, attacking_goal: Vector3, goalie_pos: Vector3,
		net_half_width: float, shot_speed_m_s: float, unsettled: float,
		goalie_five_hole_m: float = -1.0, goalie_down: bool = false,
		goalie_post_seal_x: float = 0.0,
		goalie_post_seal_tall: bool = false,
		aim_spread_rad: float = 0.0) -> int:
	var best_angle: float = 0.0
	for i: int in HOLE_COUNT:
		var a: float = _hole_open_angle(i, shooter, attacking_goal, goalie_pos,
				net_half_width, shot_speed_m_s, unsettled, goalie_five_hole_m, goalie_down,
				goalie_post_seal_x, goalie_post_seal_tall, aim_spread_rad)
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
				net_half_width, shot_speed_m_s, unsettled, goalie_five_hole_m, goalie_down,
				goalie_post_seal_x, goalie_post_seal_tall, aim_spread_rad)
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
# five-hole aims at the goalie's centre (between the legs). Reuses the same
# body-disc cover model and unsettled-fade as _hole_open_angle so aim and score
# agree.
static func _hole_aim_x(
		i: int, shooter: Vector3, attacking_goal: Vector3, goalie_pos: Vector3,
		net_half_width: float, shot_speed_m_s: float, unsettled: float,
		aim_spread_rad: float = 0.0, goalie_down: bool = false) -> float:
	var kind: int = HOLE_KIND[i]
	var side: int = HOLE_SIDE[i]
	var band: int = HOLE_BAND[i]
	# Same per-band pace the opening was scored with (_hole_open_angle), so
	# aim and score read the same reaction-gated cover. A chosen hole is never
	# band-unreachable (its opening would have scored 0), so the fallback to
	# full pace is belt-and-braces.
	var pace: float = _band_pace(band, shooter.distance_to(attacking_goal), shot_speed_m_s)
	if pace <= 0.0:
		pace = maxf(shot_speed_m_s, 1.0)
	var net_z: float = attacking_goal.z
	var post_lo_x: float = attacking_goal.x - net_half_width
	var post_hi_x: float = attacking_goal.x + net_half_width
	# Post clearance: the widest |x| the puck's CENTER can cross the line at
	# without clipping the pipe (post + puck radius — see
	# GameRules.NET_ENTRY_HALF_WIDTH), PLUS the shooter's own execution spread
	# projected to the net plane (aim_spread_rad × range). The bare physical
	# clamp put the puck's edge exactly TANGENT to the post edge — a knife-edge
	# any wobble turns into iron — and a noisy hand needs its wobble budgeted
	# inside the entry, so the spread lands as goals/saves/misses, not clanks.
	var entry_inset: float = GameRules.NET_POST_RADIUS \
			+ GameRules.PUCK_COLLISION_RADIUS \
			+ aim_spread_rad * shooter.distance_to(attacking_goal)
	var entry_lo_x: float = post_lo_x + entry_inset
	var entry_hi_x: float = post_hi_x - entry_inset

	if kind == HOLE_KIND_FIVE:
		return clampf(_shadow_x(shooter, goalie_pos.x, goalie_pos.z, net_z),
				entry_lo_x, entry_hi_x)

	# Corner: aim at the open segment [post ↔ cover edge] on the hole's side,
	# midpoint biased toward the post. Cover edges come from the same disc-tangent
	# body model _hole_open_angle scores with (see the doc there), projected back
	# onto the net plane so the midpoint math stays in x.
	var u: float = goalie_pos.x - shooter.x
	var net_normal_z: float = -signf(attacking_goal.z)
	var fwd: float = (shooter.z - attacking_goal.z) * net_normal_z
	var dv: float = fwd - (goalie_pos.z - attacking_goal.z) * net_normal_z
	# Same reach budget as _hole_open_angle: the puck reaches HIS body, not the
	# goal line, and the cover is the shared _band_cover read at that moment.
	var t_reach: float = sqrt(u * u + dv * dv) / pace
	var eff_unsettled: float = clampf(unsettled, 0.0, 1.0) \
			* clampf(1.0 - t_reach / UNSETTLE_RECOVERY_S, 0.0, 1.0)
	var cover: float = _band_cover(band, t_reach, eff_unsettled, goalie_down)
	var cov_lo_x: float = post_hi_x
	var cov_hi_x: float = post_lo_x
	if dv >= 0.001:
		var d: float = sqrt(u * u + dv * dv)
		if d <= cover:
			# Smothered (scored 0 anyway) — degenerate; aim the near entry edge.
			return entry_lo_x if side < 0 else entry_hi_x
		var alpha: float = atan2(u, dv)
		var beta: float = asin(clampf(cover / d, 0.0, 1.0))
		var g_lo: float = alpha - beta
		var g_hi: float = alpha + beta
		cov_lo_x = post_lo_x if g_lo <= -PI * 0.5 + 0.001 \
				else clampf(shooter.x + tan(g_lo) * fwd, post_lo_x, post_hi_x)
		cov_hi_x = post_hi_x if g_hi >= PI * 0.5 - 0.001 \
				else clampf(shooter.x + tan(g_hi) * fwd, post_lo_x, post_hi_x)
	if side < 0:
		var mid_lo: float = (post_lo_x + cov_lo_x) * 0.5
		return maxf(lerpf(mid_lo, post_lo_x, AIShotAim.DEFAULT_CORNER_BIAS), entry_lo_x)
	var mid_hi: float = (cov_hi_x + post_hi_x) * 0.5
	return minf(lerpf(mid_hi, post_hi_x, AIShotAim.DEFAULT_CORNER_BIAS), entry_hi_x)


# Projects a point (px at depth pz) onto the net plane (z = net_z) along the
# sightline from the shooter — the point's "shadow" on the net. Only the
# five-hole aim still uses this centre-point projection; the corner holes read
# the goalie's cover as a body-disc tangent cone (see _hole_open_angle), which
# is what keeps sharp angles honest.
static func _shadow_x(shooter: Vector3, px: float, pz: float, net_z: float) -> float:
	var dz: float = pz - shooter.z
	if absf(dz) < 0.000001:
		return px
	return shooter.x + (net_z - shooter.z) / dz * (px - shooter.x)


# Open angle (radians, from the shooter's eye) of hole `i` — 0 if the goalie
# covers it. Corners measure the net cleared past the reaction-gated cover edge;
# the five-hole is a central gap that opens with the goalie's unsettle. All
# openings are computed on the net plane so foreshortening is automatic.
static func _hole_open_angle(
		i: int, shooter: Vector3, attacking_goal: Vector3, goalie_pos: Vector3,
		net_half_width: float, shot_speed_m_s: float, unsettled: float,
		goalie_five_hole_m: float = -1.0, goalie_down: bool = false,
		goalie_post_seal_x: float = 0.0,
		goalie_post_seal_tall: bool = false,
		aim_spread_rad: float = 0.0) -> float:
	var net_normal_z: float = -signf(attacking_goal.z)
	var forward: float = (shooter.z - attacking_goal.z) * net_normal_z
	if forward < 0.001:
		return 0.0  # on/behind the goal line — no shot in
	var kind: int = HOLE_KIND[i]
	var side: int = HOLE_SIDE[i]
	var band: int = HOLE_BAND[i]
	# Per-band pace: HIGH holes fly at the arrival-honest solved pace (the arc
	# must physically reach the top band — see _band_pace); 0 = no legal
	# power gets there, so the hole isn't a target at all.
	var pace: float = _band_pace(band, shooter.distance_to(attacking_goal), shot_speed_m_s)
	if pace <= 0.0:
		return 0.0
	# Reach budget: the puck crosses the goalie's reach envelope at HIS body —
	# the shooter→goalie gap at the band's pace — not at the goal line. This is
	# what range genuinely buys him; in tight it's a fraction of the flight, and
	# it's why a quick release beats the same keeper a long shot can't.
	var u: float = goalie_pos.x - shooter.x
	var dv: float = forward - (goalie_pos.z - attacking_goal.z) * net_normal_z
	var t_reach: float = sqrt(u * u + dv * dv) / pace

	# A post-seal stance (VH/RVH, read off the replicated state — see
	# GoalieNetworkState.post_seal_x_sign) is a DEPLOYED wall at the post: the
	# coverage is the pose itself, already in place at release, so nothing on
	# the sealed side is reaction-gated. The between-the-legs slot is closed in
	# both families (back pad + post-sealed pad — no FIVE to thread). VH stands
	# the vertical pad + tall torso in the whole near column, ice to over the
	# shoulder: sealed-side LOW and HIGH are both gone. RVH stays compressed —
	# sealed-side LOW is gone but short-side HIGH stays measured (its
	# documented weakness). The FAR side is deliberately untouched: it's read
	# from the goalie's actual parked-at-the-post position below, which is what
	# keeps the walkout / cross-crease counter visible to the model.
	if goalie_post_seal_x != 0.0:
		if kind == HOLE_KIND_FIVE:
			return 0.0
		if float(side) == signf(goalie_post_seal_x) \
				and (goalie_post_seal_tall or HOLE_BAND[i] == HOLE_BAND_LOW):
			return 0.0
	# The goalie re-settles while the puck travels, so a caught-moving read decays
	# over the time he has before it reaches HIM (full point-blank, gone by the
	# time a long shot arrives at his body).
	var eff_unsettled: float = clampf(unsettled, 0.0, 1.0) \
			* clampf(1.0 - t_reach / UNSETTLE_RECOVERY_S, 0.0, 1.0)

	if kind == HOLE_KIND_FIVE:
		# Between-the-legs gap, foreshortened with range (gap / distance); only a
		# roughly head-on look can thread the legs (centrality). The puck has to
		# FIT here too: what scores is the gap's CLEARANCE past the puck's own
		# diameter (the same honesty the corners pay via the clean-entry inset).
		# Without it, the standing ~0.16-0.20 m slot — barely wider than the
		# 0.13 m puck — read as generous as a real corner window; with it, the
		# standing five is the razor-thin look it actually is and the live
		# five-hole is the DOWN goalie's slide leak, which genuinely opens.
		var centrality: float = clampf(
				1.0 - absf(shooter.x - goalie_pos.x) / FIVE_CENTER_REF_M, 0.0, 1.0)
		var dist: float = shooter.distance_to(attacking_goal)
		var puck_diameter: float = 2.0 * GameRules.PUCK_COLLISION_RADIUS
		# The shooter's execution spread eats the slot exactly as it eats a
		# corner window (the corners subtract it via fit_angle below): a
		# razor-thin five-hole a noisy hand can't actually thread must not
		# out-score a wider corner through the flat-loft tie-break.
		if goalie_five_hole_m >= 0.0:
			# MEASURED slot from the replicated pose (GoalieBehaviorRules.
			# five_hole_gap_m): standing it's a real ~0.20 m ice-to-pad-top slot
			# the goalie seals by DROPPING once he reads the release — legs
			# reaction delay then pads-to-floor, raced against the puck reaching
			# HIM (t_reach) — so only an in-tight release beats the drop (the
			# shot the model used to score zero). Down, the residual gap (slide
			# leak) is already the measurement and there is nothing left to
			# drop. The stick blade parked in the slot is deliberately
			# unmodeled: active-blade intent yaws it toward the puck, vacating
			# the slot exactly when the shooter is off-center.
			var gap: float = goalie_five_hole_m
			if not goalie_down:
				var seal: float = clampf(
						(t_reach - _band_delay(HOLE_BAND_LOW))
							/ goalie_butterfly_drop_s,
						0.0, 1.0)
				gap *= 1.0 - seal
			var gap_angle: float = maxf(0.0, gap - puck_diameter) / maxf(dist, 0.5)
			return maxf(0.0, gap_angle - aim_spread_rad) * centrality
		# Legacy proxy (no replicated stance in scope — threat surfaces, tests):
		# a set goalie seals it, a caught-moving one leaks it.
		var proxy_angle: float = maxf(0.0, FIVE_GAP_M - puck_diameter) / maxf(dist, 0.5)
		return maxf(0.0, proxy_angle - aim_spread_rad) * eff_unsettled * centrality

	# Band cover raced against t_reach — standing pad column widened by the
	# butterfly drop LOW, reaction-gated glove/blocker extension HIGH, with the
	# butterfly's defining trade (a DOWN goalie seals the ice and concedes the
	# top band's extension) — see _band_cover.
	var cover: float = _band_cover(band, t_reach, eff_unsettled, goalie_down)

	# Net posts and the goalie's cover, all as bearings from the shooter's eye.
	var post_lo_x: float = attacking_goal.x - net_half_width
	var post_hi_x: float = attacking_goal.x + net_half_width
	var net_lo: float = atan2(post_lo_x - shooter.x, forward)
	var net_hi: float = atan2(post_hi_x - shooter.x, forward)
	# The goalie occludes as a BODY (a disc of the band's cover radius), not a
	# paper cutout on the x-axis: he squares to the puck, so he presents the
	# band's cover half-width perpendicular to the shooter's sightline from any
	# bearing. The covered bearing interval is the disc's tangent cone. For a
	# frontal shooter this reduces to the old net-plane point projection
	# (tan β ≈ cover / depth), but from a sharp angle the body's DEPTH occludes
	# the cross-crease lane — the old zero-depth model left the far post "open"
	# from beside the net, which is where the hopeless bad-angle fires came from.
	var covb_lo: float
	var covb_hi: float
	if dv < 0.001:
		# Goalie at/behind the release plane — he covers nothing (upstream release
		# clamps keep real shooters from exploiting this; it's a degenerate read).
		covb_lo = net_hi
		covb_hi = net_lo
	else:
		var d_sq: float = u * u + dv * dv
		if d_sq <= cover * cover:
			return 0.0  # release inside the goalie's body — smothered
		var alpha: float = atan2(u, dv)
		var beta: float = asin(clampf(cover / sqrt(d_sq), 0.0, 1.0))
		covb_lo = clampf(alpha - beta, net_lo, net_hi)
		covb_hi = clampf(alpha + beta, net_lo, net_hi)

	var open_angle: float
	if side < 0:
		open_angle = maxf(0.0, minf(covb_lo, net_hi) - net_lo)   # left post → cover's left edge
	else:
		open_angle = maxf(0.0, net_hi - maxf(covb_hi, net_lo))   # cover's right edge → right post
	if open_angle <= 0.0:
		return 0.0
	# The puck has to FIT: a corner only scores by what remains after the puck's
	# clean-entry inset off the pipe — post radius + puck radius, the exact
	# GameRules.NET_ENTRY_HALF_WIDTH inset _hole_aim_x buys the aim point — PLUS
	# the shooter's own execution spread (aim_spread_rad), the same wobble budget
	# the aim point reserves. A noisier hand needs a wider window for the same
	# chance, so spread belongs in shot SELECTION, not just execution. (No extra
	# margin on the cover side: `cover` is already the goalie's MAXIMAL deployed
	# reach.) Without the inset, a fully-deployed goalie always left a few-cm
	# "sliver" open past his reach at ANY range — an opening the aim clamp can't
	# even target (it sits inside the entry inset) — and that un-hittable sliver
	# out-scored working closer: the launch-it-from-the-point bug. The inset's
	# angular size foreshortens with range like any target, so in tight it costs
	# almost nothing.
	var fit_angle: float = (GameRules.NET_POST_RADIUS + GameRules.PUCK_COLLISION_RADIUS) \
			/ maxf(shooter.distance_to(attacking_goal), 0.5) \
			+ aim_spread_rad
	return maxf(0.0, open_angle - fit_angle)


# Returns SHOOT score in [0, 1]: the geometric open-net danger × lane clearance
# × forward-cone pressure. `predicted_goalie_pos` is the goalie at shot release
# (use `predict_goalie_pos`); the hole geometry handles "too close" on its
# own. `shot_speed_m_s` sets the puck's pace (goalie reach budget) and the lane math;
# `goalie_unsettled_factor` cuts his reaction (a mid-slide goalie reads the shot
# late).
static func score_shoot(
		shooter: Vector3,
		attacking_goal: Vector3,
		predicted_goalie_pos: Vector3,
		net_half_width: float,
		opponents: Array[Vector3],
		shot_speed_m_s: float = WRISTER_SHOT_SPEED_M_S,
		goalie_unsettled_factor: float = 0.0,
		opponent_caps: Array = [],
		goalie_five_hole_m: float = -1.0,
		goalie_down: bool = false,
		goalie_post_seal_x: float = 0.0,
		goalie_post_seal_tall: bool = false,
		aim_spread_rad: float = 0.0) -> float:
	# No shot from on/behind the goal line: the mouth faces the other way, so there
	# is no straight line from a back-there release into the net. Checked BEFORE
	# the release clamp below — clamping a behind-the-net release used to teleport
	# it to a phantom point-blank spot in front of the goalie, which scored a
	# behind-the-net carrier's "shot" as a doorstep open net (the wraparound is a
	# CARRY around the post, never a direct fire from back there).
	if (shooter.z - attacking_goal.z) * -signf(attacking_goal.z) < 0.001:
		return 0.0
	# The puck can't be shot from behind the goalie — clamp the shooter to the jam
	# distance in front of him. Without this a hard drive's projected release, or a
	# carry candidate placed in the crease, reads as a phantom open net (keeper
	# modelled behind the shooter). No-op for any normal in-front shot.
	shooter = release_ahead_of_goalie(shooter, attacking_goal, predicted_goalie_pos)
	var shot_quality: float = open_net_danger(
			shooter, attacking_goal, predicted_goalie_pos, net_half_width,
			shot_speed_m_s, goalie_unsettled_factor,
			goalie_five_hole_m, goalie_down,
			goalie_post_seal_x, goalie_post_seal_tall, aim_spread_rad)
	if shot_quality <= 0.0:
		return 0.0
	# Lane clear vs the aim point ShotAim picks (past the goalie's shadow) —
	# defenders on the shot line reduce it via the reaction-window model.
	var aim: Vector3 = AIShotAim.compute_open_net_aim(
			shooter, predicted_goalie_pos, attacking_goal.z,
			net_half_width, GOALIE_SHADOW_HALF_M)
	var lane: float = lane_clear(shooter, aim, opponents, shot_speed_m_s, [], opponent_caps)
	# Forward-cone pressure: bodies between the shooter and the net screen/block
	# the release (beside/behind don't).
	var pressure_factor: float = 1.0 - _pressure(shooter, opponents, attacking_goal - shooter)
	return shot_quality * lane * pressure_factor


# ── Predicted post-seal (RVH/VH) — the ONE xG model, consistent inputs ─────────
# score_shoot is the single xG model. The only reason it gave two answers for the
# same spot was its INPUTS: the shoot-now eval reads the LIVE goalie's seal state
# (GoalieNetworkState.post_seal_x_sign) and threads it, while predictive callers
# (carry candidates, pass receivers) left the seal at its unsealed default — so a
# shot origin down at a sharp angle scored a PHANTOM far-side open net, and the
# bot would carry to that "shot" only to meet a live keeper already walled at the
# post (the "carries there, never shoots" bug). This predicts the seal a
# competent keeper WILL adopt at a spot, from the SAME geometric trigger the live
# goalie uses (GoalieBehaviorRules.is_puck_in_defensive_zone), so the predictive
# paths feed the model the same coverage the shoot-now path reads live.
#
# Mirrors GoalieController.zone_post_z / rvh_early_angle (the RVH/VH trigger):
# within this depth of the goal line AND past this bearing off the goal normal,
# the keeper is post-sealed. Deliberately narrow (2 m, 80°) — it touches only the
# wraparound/extreme-corner region, never a normal slot or mid look.
const GOALIE_SEAL_ZONE_POST_Z_M: float = 2.0
const GOALIE_SEAL_ANGLE_RAD: float = deg_to_rad(80.0)


# Predicted post-seal x-sign for a shot from `shooter`: the side (relative to goal
# center) a keeper would seal, or 0.0 for the common in-front look where no seal
# applies. Only the IN-FRONT sharp angle is sealed here (VH — tall); a release
# behind the goal line is already zeroed by score_shoot's forward guard, so it
# needs no seal. Pure float, allocation-free — safe on the per-candidate path.
static func derive_post_seal_x_sign(shooter: Vector3, attacking_goal: Vector3) -> float:
	var net_normal_z: float = -signf(attacking_goal.z)
	var forward: float = (shooter.z - attacking_goal.z) * net_normal_z
	if forward < 0.001 or forward > GOALIE_SEAL_ZONE_POST_Z_M:
		return 0.0
	var lateral: float = absf(shooter.x - attacking_goal.x)
	if atan2(lateral, maxf(forward, 0.01)) < GOALIE_SEAL_ANGLE_RAD:
		return 0.0
	return signf(shooter.x - attacking_goal.x)


# Point-blank jam distance: the closest the puck realistically gets to a set goalie
# before his body/pads stop it. A physical measurement (skate + pad depth), not a
# tuning knob — it just keeps the shooter strictly in FRONT of the keeper so the
# shadow geometry stays well-defined (a shooter coincident with the goalie is a
# degenerate projection).
const GOALIE_JAM_DISTANCE_M: float = 0.4

# A shot's release point can't sit CLOSER to the goal than the goalie: the goalie
# is a body in the way, so the puck leaves the blade in FRONT of him, never behind
# (and no nearer than the jam distance). Clamps a shooter/release so its distance
# out from the goal is at least the goalie's + the jam margin — killing the
# "shooter past the goalie → phantom open net" read, where a hard drive's projected
# release (or a carry candidate placed in the crease) overshoots the goalie's depth
# and the shot scores as if the keeper were behind the shooter. Only the goalward
# axis is clamped; lateral offset (a cut across the slot) is untouched.
#
# A release on/behind the GOAL LINE is returned unchanged: there is no shot from
# back there at all (score_shoot hard-zeros it, and every hole's forward guard
# reads 0 net). Clamping it used to invent a legal-looking point-blank release in
# front of the keeper — the phantom that had bots firing from behind the net.
static func release_ahead_of_goalie(
		release: Vector3, attacking_goal: Vector3, goalie_pos: Vector3) -> Vector3:
	var net_normal_z: float = -signf(attacking_goal.z)
	var release_fwd: float = (release.z - attacking_goal.z) * net_normal_z
	if release_fwd < 0.001:
		return release
	var goalie_fwd: float = (goalie_pos.z - attacking_goal.z) * net_normal_z
	var min_fwd: float = goalie_fwd + GOALIE_JAM_DISTANCE_M
	if release_fwd >= min_fwd:
		return release
	return Vector3(release.x, release.y, attacking_goal.z + min_fwd * net_normal_z)


# The ARC-MATCHING x a properly squared goalie sits at for a puck at
# `puck_pos`: since the goalie sits much closer to the goal than the shooter,
# arc_x = goalie_depth × (puck.x − goal.x) / puck_forward_from_goal. Shared by
# predict_goalie_pos / goalie_unsettled / goalie_squared_pos so all three agree.
static func goalie_arc_match_x(
		goalie_now: Vector3, attacking_goal: Vector3, puck_pos: Vector3) -> float:
	var net_normal_z: float = -signf(attacking_goal.z)
	var puck_forward: float = (puck_pos.z - attacking_goal.z) * net_normal_z
	var goalie_depth: float = (goalie_now.z - attacking_goal.z) * net_normal_z
	# The goalie squares along his ARC — his lateral offset can never exceed his
	# own radial distance from the goal (fully lateral = on the goal line at his
	# radius). Off the arc there is no squaring, only a keeper who abandoned the
	# cage. Unbounded, a near-goal-line puck reference exploded the arc-x toward
	# the corner boards — a phantom far-side opening that had bots firing from
	# beside the net while rounding it. Moderate angles are untouched (their
	# arc-x sits well inside the radius, wider than the posts — which is real:
	# an out-challenging goalie legitimately squares past the post line).
	var radius: float = Vector3(
			goalie_now.x - attacking_goal.x, 0.0,
			goalie_now.z - attacking_goal.z).length()
	if puck_forward < 0.001 or goalie_depth < 0.001:
		# Degenerate: puck on/behind goal line, or goalie there. Best-effort: the
		# puck's side, bounded to the arc.
		return attacking_goal.x + clampf(
				puck_pos.x - attacking_goal.x, -radius, radius)
	var arc_x: float = goalie_depth * (puck_pos.x - attacking_goal.x) / puck_forward
	return attacking_goal.x + clampf(arc_x, -radius, radius)


# The goalie SQUARED to a puck at `puck_pos` — arc-matched and set, no forced
# motion. This is the right model for a CARRY destination: the keeper tracks the
# puck continuously as the bot skates there (gradual move, not a relocation it
# reacts to from a standstill), so on arrival it is square, full stop. Using the
# react-then-slide predict_goalie_pos for a carry under-tracks the keeper —
# especially at a short release lookahead, where it is predicted to fall short of
# arc-matching a diagonal step and leak the far side, which had the bot chasing an
# ever-receding "one more cut catches him moving" shot into the crease. The
# caught-moving credit belongs to puck RELOCATIONS (shots/passes), not carries.
static func goalie_squared_pos(
		goalie_now: Vector3, attacking_goal: Vector3, puck_pos: Vector3) -> Vector3:
	return Vector3(goalie_arc_match_x(goalie_now, attacking_goal, puck_pos),
			goalie_now.y, goalie_now.z)


# Predicts the goalie's position at a future moment (shot release).
# React-then-push model: a fixed reaction delay, then movement toward
# the ARC-MATCHING x on the accelerate-onto-the-edge push profile
# (_goalie_lateral_reach — ramping at lateral_accel to t_push speed).
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
	var target_x: float = goalie_arc_match_x(goalie_now, attacking_goal, puck_pos_at_release)
	var move_time: float = maxf(0.0, release_time_s - goalie_leg_delay_s)
	var max_move: float = _goalie_lateral_reach(move_time)
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
# Same react-then-push kinematics as predict_goalie_pos (accel ramp included),
# so the predicted position and this motion estimate agree. score_shoot cuts the goalie's
# glove/blocker reaction by this fraction (a recovering goalie reads the shot
# late). A fast cross-seam one-timer leaves the goalie mid-slide → near 1; a
# static shot at a set goalie → 0.
static func goalie_unsettled(
		goalie_now: Vector3,
		attacking_goal: Vector3,
		release_time_s: float,
		puck_pos_at_release: Vector3) -> float:
	var target_x: float = goalie_arc_match_x(goalie_now, attacking_goal, puck_pos_at_release)
	var need: float = absf(target_x - goalie_now.x)
	if need < 0.001:
		return 0.0  # already squared — no forced motion, fully set
	var move_time: float = maxf(0.0, release_time_s - goalie_leg_delay_s)
	var max_move: float = _goalie_lateral_reach(move_time)
	if need >= max_move:
		return 1.0  # still sliding at release (or hasn't even reacted) — caught moving
	# Reached the target with time to spare; ramps back to 0 as it re-sets.
	var slide_time: float = _goalie_lateral_time(need)
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
	# Predicted post-seal for the receiver's spot (derive_post_seal_x_sign): a feed
	# to a sharp near-goal-line angle faces the RVH/VH wall a competent keeper
	# adopts, so this leaf reads the same sealed coverage the carrier's own
	# _score_at does — no phantom dead-angle receiver value, whether score_pass is
	# a defensive threat read or an offensive developing-feed one.
	var seal_x: float = derive_post_seal_x_sign(receiver, attacking_goal)
	var receiver_shot: float = score_shoot(
			receiver, attacking_goal, predicted_goalie_pos, net_half_width, opponents,
			WRISTER_SHOT_SPEED_M_S, goalie_unsettled_factor, [], -1.0, false,
			seal_x, seal_x != 0.0)
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
		px: float, pz: float, vx: float, vz: float,
		stick_reach: float = LANE_DEFENDER_REACH_M,
		close_speed: float = LANE_DEFENDER_CLOSE_SPEED_M_S) -> float:
	var miss: float = _lane_miss_at(fx, fz, pvx, pvz, t, px, pz, vx, vz)
	# reach = this defender's stick (Size) + how far it slides into the lane after
	# its read delay (Speed × the ~0.5 lateral factor); normalised by its own stick
	# so "one full stick inside reach ⇒ certain block" scales with the defender.
	var reach: float = stick_reach + close_speed * maxf(0.0, t - LANE_REACTION_DELAY_S)
	return clampf((reach - miss) / stick_reach, 0.0, 1.0)


# Brake-and-clog reachability block [0, 1] for one defender: the best lane point
# he can skate to and STOP on before the puck crosses it. The ballistic closest-
# approach term (_lane_block_at) lets a fast defender COAST straight through the
# lane and out the far side — past ~10 m/s of perpendicular closing he reads as
# clear, because the dead-reckon never lets him brake. But a real defender about
# to overshoot a lane he's trying to defend plants and occupies it. This asks the
# guided-interceptor question instead: given his read delay and lateral pace, can
# he reach the crossing point in time and stay? He can, so this only ever ADDS
# block — it floors the coasting term's overshoot tail without weakening any lane
# the coasting model already blocks (lane_clear takes the max of the two).
#
# Closed form: maximise block(u) = (stick + close·(u/speed − reaction) − |X(u)−D|)
# over the lane arc-coord u, where X(u) is the point u metres along the lane and
# the puck reaches it at u/speed. With a = the defender's along-lane coord and
# b = his perpendicular distance, |X(u)−D| = √((u−a)²+b²); setting d/du = 0 gives
# the interior optimum (u−a) = k·b/√(1−k²), k = close/speed. Evaluated there and
# at the perpendicular foot (u = a, robust to the reaction-delay kink), best wins.
# Pure float math, allocation-free.
static func _lane_brake_block(
		fx: float, fz: float, dirx: float, dirz: float, seg_len: float,
		speed: float, px: float, pz: float,
		stick_reach: float, close_speed: float) -> float:
	var rx: float = px - fx
	var rz: float = pz - fz
	var a: float = rx * dirx + rz * dirz             # along-lane coord of the defender
	var perp_x: float = rx - a * dirx
	var perp_z: float = rz - a * dirz
	var b: float = sqrt(perp_x * perp_x + perp_z * perp_z)   # perpendicular distance
	var k: float = close_speed / speed
	var u_opt: float = seg_len if k >= 1.0 else a + k * b / sqrt(1.0 - k * k)
	var blk_opt: float = _brake_block_at(
			clampf(u_opt, 0.0, seg_len), a, b, speed, stick_reach, close_speed)
	var blk_foot: float = _brake_block_at(
			clampf(a, 0.0, seg_len), a, b, speed, stick_reach, close_speed)
	return maxf(blk_opt, blk_foot)


# Block strength if the defender aims to occupy lane arc-coord `u` — reach at the
# puck's arrival time there, minus the distance he must cover to it. Shared by the
# two candidate points _lane_brake_block evaluates.
static func _brake_block_at(u: float, a: float, b: float, speed: float,
		stick_reach: float, close_speed: float) -> float:
	var t_x: float = u / speed
	var reach: float = stick_reach + close_speed * maxf(0.0, t_x - LANE_REACTION_DELAY_S)
	var du: float = u - a
	var gap: float = sqrt(du * du + b * b)
	return clampf((reach - gap) / stick_reach, 0.0, 1.0)


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
#
# `brake_clog` adds the guided-interceptor reachability term (_lane_brake_block)
# max'd into each defender's block, fixing the ballistic overshoot: without it a
# defender crossing the lane faster than ~10 m/s coasts through and reads as clear
# (harmful on the slower PASS puck, where that speed is reachable). Off by default
# so every existing caller — the fast SHOT lane, the off-puck/threat score_pass —
# keeps the pure ballistic behaviour; the carrier's own pass EV opts in, since a
# forechecker jumping a breakout lane is exactly the overshoot case.
static func lane_clear(from: Vector3, to: Vector3, opponents: Array[Vector3],
		puck_speed_m_s: float, opponent_vels: Array[Vector3] = [],
		opponent_caps: Array = [], brake_clog: bool = false) -> float:
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
	var dirx: float = dx * inv_len
	var dirz: float = dz * inv_len
	var vel_count: int = opponent_vels.size()
	var has_caps: bool = opponent_caps.size() == opponents.size()
	var max_block: float = 0.0
	for i: int in opponents.size():
		var p: Vector3 = opponents[i]
		var vx: float = 0.0
		var vz: float = 0.0
		if i < vel_count:
			vx = opponent_vels[i].x
			vz = opponent_vels[i].z
		# This defender's real stick reach (Size) and lateral close speed (Speed).
		var stick_reach: float = LANE_DEFENDER_REACH_M
		var close_speed: float = LANE_DEFENDER_CLOSE_SPEED_M_S
		if has_caps:
			var caps: AISkaterCaps = opponent_caps[i]
			if caps != null:
				stick_reach = caps.stick_reach
				close_speed = LANE_LATERAL_FRACTION * caps.max_speed
		# Ballistic (coasting) block — 0 for a defender whose closest approach is
		# only AFTER the puck reaches the receiver (trailing the play).
		var block: float = 0.0
		var t_raw: float = _lane_closest_approach_t(
				from.x, from.z, pvx, pvz, p.x, p.z, vx, vz)
		if t_raw <= seg_time:
			block = _lane_block_at(from.x, from.z, pvx, pvz, maxf(t_raw, 0.0),
					p.x, p.z, vx, vz, stick_reach, close_speed)
		# Guided-interceptor floor: he can brake and clog a reachable crossing
		# instead of coasting through it (only ADDS block; see _lane_brake_block).
		if brake_clog:
			var brake_block: float = _lane_brake_block(
					from.x, from.z, dirx, dirz, line_len, speed,
					p.x, p.z, stick_reach, close_speed)
			if brake_block > block:
				block = brake_block
		if block > max_block:
			max_block = block
			if max_block >= 1.0:
				break
	return clampf(1.0 - max_block, 0.0, 1.0)


# Lane-clear for a SAUCER (LOW-loft) pass fired at `puck_speed_m_s`. Same
# closest-approach model as lane_clear, except while the puck is above the
# blade plane — the kinematic over window [t_over, t_down] of the LOW
# loft's fixed vertical launch (see the saucer doc-block) — a defender's
# reach collapses to their BODY radius: sticks fly under it, only a body
# in the lane stops it (LANE_DEFENDER_BODY_RADIUS_M). Before the window
# (puck still rising off the blade) and after it (landed) a stick
# intercepts with full grounded reach + closing, per-defender caps
# included — so a stick already on the puck at release still stuffs the
# flip, and a defender past the touch-down point plays it like any flat
# pass. Because the window is TIME-fixed, a softer launch shortens the
# airborne carry — the close-quarters soft flip falls out of the same
# geometry.
static func lane_clear_saucer(from: Vector3, to: Vector3, opponents: Array[Vector3],
		puck_speed_m_s: float, opponent_vels: Array[Vector3] = [],
		opponent_caps: Array = []) -> float:
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
	var has_caps: bool = opponent_caps.size() == opponents.size()
	# Over window: y(t) = vy·t − ½·g·t² above the blade plane between the
	# two roots. vy (2.2) comfortably clears the ~5 cm plane, so the
	# discriminant is always positive; the maxf is belt-and-suspenders.
	var vy: float = GameRules.DEFAULT_LOFT_VY_LOW_M_S
	var root: float = sqrt(maxf(0.0,
			vy * vy - 2.0 * GRAVITY_M_S2 * GameRules.PUCK_AIRBORNE_HEIGHT_M))
	var t_over: float = (vy - root) / GRAVITY_M_S2
	var t_down: float = (vy + root) / GRAVITY_M_S2
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
		var block: float
		if t >= t_over and t <= t_down:
			# Puck is above the blade plane — flies over a grounded stick,
			# so only the defender's body can block it: reach = body
			# radius, no stick, no closing.
			var miss: float = _lane_miss_at(
					from.x, from.z, pvx, pvz, t, p.x, p.z, vx, vz)
			block = clampf(
					(LANE_DEFENDER_BODY_RADIUS_M - miss) / LANE_DEFENDER_BODY_RADIUS_M,
					0.0, 1.0)
		else:
			# On/near the ice (rising off the blade, or landed) — full
			# stick reach + closing, at this defender's real caps.
			var stick_reach: float = LANE_DEFENDER_REACH_M
			var close_speed: float = LANE_DEFENDER_CLOSE_SPEED_M_S
			if has_caps:
				var caps: AISkaterCaps = opponent_caps[i]
				if caps != null:
					stick_reach = caps.stick_reach
					close_speed = LANE_LATERAL_FRACTION * caps.max_speed
			block = _lane_block_at(
					from.x, from.z, pvx, pvz, t, p.x, p.z, vx, vz, stick_reach, close_speed)
		if block > max_block:
			max_block = block
	return clampf(1.0 - max_block, 0.0, 1.0)


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
#   angle_factor = the goal mouth's projected width from this bearing
#                  (cos of the angle off the goal normal = forward/dist);
#                  1 head-on, 0 along the goal line — real foreshortening.
#   openness     = 1 - skater_pressure (forward-cone, distance-weighted)
#
# Used by `_score_at` only when the evaluator is OUTSIDE shooting
# range — inside the range, the bot uses score_shoot alone (committed
# to a real shot evaluation). The cross-boundary case (evaluator
# outside, candidate inside) takes max(shoot, potential) so entry
# into shooting range is rewarded by the higher of the two.
#
# Behind the attacking goal line: returns 0 (no shooting potential).
# True when `pos` is on the attacking side of the attacking blue line — the
# offensive zone. The value-map regime boundary (see POSSESSION_BASELINE):
# `_score_at` prices in-zone positions by shot danger and out-of-zone positions by
# position_potential, and a carrier already in the zone won't carry or pass back
# out of it. Sign-folded so it works for either attacking direction.
# `buffer` demands the position sit that much DEEPER than the line — the
# carrier's blue-line keep-out bands (retreat / reception) use it so "in the
# zone" can mean "in the zone with margin for the stick's reach".
static func in_offensive_zone(pos: Vector3, attacking_goal: Vector3,
		buffer: float = 0.0) -> bool:
	return pos.z * signf(attacking_goal.z) > GameRules.BLUE_LINE_Z + buffer


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
	# Angle quality = the goal mouth's PROJECTED width from this bearing. A goal
	# viewed off its face-normal presents cos(θ) of its width (a door seen at an
	# angle), and cos(θ) = forward / horizontal_distance — the real foreshortening,
	# not a hand-picked taper. 1 head-on, → 0 along the goal line. Same projection
	# geometry the hole-based shot model reasons in.
	var lateral: float = pos.x - attacking_goal.x
	var horiz_dist: float = sqrt(forward * forward + lateral * lateral)
	var angle_factor: float = forward / horiz_dist
	var openness: float = 1.0 - _pressure(pos, opponents, attacking_goal - pos)
	return closeness * angle_factor * openness


# Realization discount for position_potential when it prices a CARRY /
# receiver destination in the carrier's expected-value compete: potential
# is FUTURE value — its promise (a real shot) is only cashed by skating
# from `pos` to the slot — so it must pay the same delay_discount that
# every other future action in the model pays, over that remaining travel time.
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
	return delay_discount(travel_dist / SKATER_REF_SPEED_M_S)


# ── Dumping ───────────────────────────────────────────────────────────────────
# Dumping is a deliberate LAST-RESORT giveaway at a SAFE location, in two spots:
#   - DZ clear: pinned in our own end with no play, rim it out to the neutral zone.
#   - NZ dump-and-chase: past centre (so it isn't icing) but contained before the
#     blue line with no outlet, flip it into the offensive corner and race for it.
# It never needs an "if no options" gate — its EV rides the same turnover_cost the
# rest of the model uses (≈0 for a giveaway in the offensive end, large in front of
# our net), so it only wins when every real play (carry/pass/shoot) prices worse
# than conceding at the dump spot. The pieces below are the grounded terms the
# carrier assembles into that EV (see _best_dump).

# Corner depth from the goal line for a dump-in target (a corner retrieval, not a
# behind-the-net wrap). Distance a stride's head-start turns a 50/50 loose-puck
# race into a near-sure recovery — a physical contest band, not a tuning curve.
const DUMP_CORNER_DEPTH_M: float = 3.0
const DUMP_RINK_INSET_M: float = 0.5
const CHASE_CONTEST_MARGIN_M: float = 2.0


# True when `pos` is on the attacking side of centre ice (z = 0) — past the red
# line, where a dump-in to the offensive zone can't be icing.
static func past_center_toward_attack(pos: Vector3, attacking_goal: Vector3) -> bool:
	return pos.z * signf(attacking_goal.z) > 0.0


# How far UP-ICE of the carrier the DZ clear aims along the strong-side wall when
# that beats centre ice: one full neutral zone of depth (blue line to blue line).
# An aim DIRECTION, not a settle point — the rim fires toward it and keeps
# running the boards.
const DUMP_CLEAR_AHEAD_M: float = 2.0 * GameRules.BLUE_LINE_Z


# DZ clear target: the strong-side boards (the side the carrier is on), at
# whichever is FARTHER up-ice of centre ice and one neutral zone ahead of the
# carrier. From deep in our end that's the classic centre-ice rim (unchanged);
# for a carrier just inside the blue line the fixed z=0 point degenerated — the
# "clear" banged the wall basically sideways, gaining nothing — so the target
# extends up-ice to keep the clear a genuine forward diagonal from anywhere.
# `up_ice_dir` is the direction OUT of our end (-own_goal_dir).
static func dump_clear_target(carrier_pos: Vector3, up_ice_dir: float) -> Vector3:
	var side: float = signf(carrier_pos.x)
	if side == 0.0:
		side = 1.0
	# Depth measured into OUR half (positive = our side of centre). Centre ice is
	# 0; one NZ ahead of the carrier may land past centre (negative) — take the
	# farther up-ice of the two.
	var own_side_depth: float = -up_ice_dir * carrier_pos.z
	var target_depth: float = minf(0.0, own_side_depth - DUMP_CLEAR_AHEAD_M)
	return Vector3(
			side * (GameRules.RINK_HALF_WIDTH - DUMP_RINK_INSET_M),
			0.0,
			-up_ice_dir * target_depth)


# Dump-in target: the FAR offensive corner (opposite the carrier's side), near the
# goal line — forces the defence to turn and retrieve with their back to the play.
static func dump_in_target(carrier_pos: Vector3, attacking_goal: Vector3) -> Vector3:
	var far_side: float = -signf(carrier_pos.x)
	if far_side == 0.0:
		far_side = 1.0
	var goal_dir: float = signf(attacking_goal.z)
	return Vector3(
			far_side * (GameRules.RINK_HALF_WIDTH - DUMP_RINK_INSET_M),
			0.0,
			attacking_goal.z - goal_dir * DUMP_CORNER_DEPTH_M)


# Probability our team wins the race to a dumped puck: a distance race to the dump
# `target` between our nearest chaser and their nearest, with a contest band around
# a tie (CHASE_CONTEST_MARGIN_M — a stride's head-start). 1.0 uncontested, 0.0 if
# we have no chaser. This is what makes a dump-in worth it ONLY when the chase is
# winnable — outnumbered in a 3v3, it self-suppresses.
static func chase_recovery(
		target: Vector3,
		our_chasers: Array[Vector3],
		opp_chasers: Array[Vector3]) -> float:
	if our_chasers.is_empty():
		return 0.0
	var our_dist: float = INF
	for p: Vector3 in our_chasers:
		our_dist = minf(our_dist, p.distance_to(target))
	if opp_chasers.is_empty():
		return 1.0
	var opp_dist: float = INF
	for p: Vector3 in opp_chasers:
		opp_dist = minf(opp_dist, p.distance_to(target))
	return clampf(0.5 + (opp_dist - our_dist) / (2.0 * CHASE_CONTEST_MARGIN_M), 0.0, 1.0)


# "Threat surface" — the value an opp can extract from their current
# position from a defender's perspective. score_shoot fades to ~0 as the
# opp gets far from our net (the hole geometry foreshortens); that's fine
# for a carrier choosing whether to release, but useless for a defender
# trying to position relative to a far-but-still-dangerous opp.
# Falling back to position_potential gives a non-zero gradient over
# any legal opp position, so the MARK defenders pull toward the opp's
# pressure cone (reducing position_potential.openness) instead of
# sitting flat at slot when no immediate shot threat exists.
#
# Used by MARK's recovery fallback for inverse shot-threat scoring across all opps.
# How far from the net mouth the goalie still counts as HOME for the
# threat-surface shot skip below — the crease depth plus a stride. Beyond it
# (pulled, or out playing the puck) the direct-shot branch must be computed
# from anywhere on the rink.
const THREAT_GOALIE_HOME_M: float = 3.0

static func threat_surface_shoot(
		opp_pos: Vector3,
		our_net: Vector3,
		our_goalie_pos: Vector3,
		net_half_width: float,
		defenders: Array[Vector3]) -> float:
	var positional: float = position_potential(opp_pos, our_net, defenders)
	# Hot-path skip, not a shaping choice: with the goalie HOME, a direct shot
	# from outside the attacking zone is dead by score_shoot's own coverage
	# math (the arrival-honest race hands any beyond-the-blue-line look to a
	# keeper who is square long before the puck arrives), so the max() below
	# is always the positional branch there — don't pay the hole geometry to
	# find ~0. This runs per carry candidate (turnover pricing) and per marked
	# opponent, at ~30 Hz; the skip covers most of the rink. A displaced /
	# pulled goalie voids the proof (an empty net scores from centre ice), so
	# it computes fully.
	if not in_offensive_zone(opp_pos, our_net) \
			and our_goalie_pos.distance_to(our_net) < THREAT_GOALIE_HOME_M:
		return positional
	# Predicted post-seal for the opponent's spot: a dead-angle look at OUR net is
	# walled by our keeper's RVH/VH the same way the offensive read models it, so
	# the defensive threat matches the real coverage (no phantom sharp-angle threat
	# our defenders would over-respect).
	var seal_x: float = derive_post_seal_x_sign(opp_pos, our_net)
	var shoot: float = score_shoot(
			opp_pos, our_net, our_goalie_pos, net_half_width, defenders,
			WRISTER_SHOT_SPEED_M_S, 0.0, [], -1.0, false, seal_x, seal_x != 0.0)
	return maxf(shoot, positional)


# Pass-threat surface — score_pass with a positional fallback for
# the same reason as threat_surface_shoot. score_pass folds in
# lane_clear × score_shoot(receiver); when receiver_shot collapses
# to 0, the lane has no value to defend. Fallback rewards defenders
# for being in the lane (lane_clear ↓) AND for closing on the
# receiver (position_potential.openness ↓).
#
# Used by PRESSURE / FORECHECK for inverse pass-threat scoring across opp teammates.
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
# NOT a flat rate — pass_miss_prob() DERIVES it (the flat constant was a magic
# number in an evaluator, exactly what the shot window model avoids). Two
# grounded parts:
#   · The bot solves its LAUNCH so the puck ARRIVES catchable (at
#     PASS_TARGET_CLOSING_M_S, under the any-angle reception ceiling), so
#     reception DIFFICULTY (closing speed vs blade angle) is designed OUT of its
#     own passes — it never fires a feed that arrives as a knock-down. The
#     residual is therefore hand + luck, not the catch.
#   · PASS_MISS_BASE_PROB — an irreducible floor (a bounce, a skate, ice
#     chatter; no pass is 100%), plus HAND execution: the release-direction error
#     (BotSkillProfile.pass_aim_error_rad) projected to the tape over the pass
#     distance, which misses when that lateral spread exceeds the receiver's
#     catch envelope (its Hands handle reach). Same uniform-error model the shot
#     window uses.
# So miss now scales with the passer's Hands-tier AND the pass length — a Hard
# bot's short feed sits at the base, an Easy bot's cross-ice stretch is genuinely
# risky — instead of one flat rate for every pass at every tier, and the
# backpass suppression survives via the base floor (even a perfect short feed
# keeps a small DZ miss cost). OVERSHOOT is the physical "how far past the
# receiver does a missed pass die" scale, not a knob.
const PASS_MISS_BASE_PROB: float = 0.04
const PASS_MISS_OVERSHOOT_M: float = 3.0


# Per-pass execution-miss probability (see the block above). `aim_error_rad` is
# the passer's release-direction error — 0 for the perfect baseline and the
# cross-player threat model (we don't know another player's hand), collapsing to
# the base floor. `catch_radius` is how far off the tape the receiver can still
# corral the feed (its Hands handle reach). Uniform-error model: the base floor
# compounded with the fraction of the ±(aim_error × distance) lateral spread that
# lands outside the catch envelope.
static func pass_miss_prob(distance: float, aim_error_rad: float,
		catch_radius: float = EVADE_CARRY_HANDLE_M) -> float:
	var spread: float = maxf(aim_error_rad, 0.0) * maxf(distance, 0.0)
	var execution: float = 0.0
	if spread > 0.0001:
		execution = clampf(
				(spread - catch_radius) / spread, 0.0, 1.0)
	return clampf(
			1.0 - (1.0 - PASS_MISS_BASE_PROB) * (1.0 - execution), 0.0, 1.0)


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


# ── Reachable-set evasion (pursuit-evasion possession safety) ────────────────
# Whether a defender threatens the puck is not "how close is he" but "can he get
# a stick to it given his MOMENTUM and reaction." Each skater is a bounded-accel
# body: over a short horizon its body rides its velocity to (pos + vel·T) and can
# deviate from that line by at most ½·A·(T−reaction)² (a double integrator's
# reachable set), with the stick reaching further. So a defender's stick can
# touch anywhere within (maneuver + stick) of his MOMENTUM-projected position.
#
# This is what the old proximity model (puck_safety) can't see: a hard charger's
# disk rides downrange to where you WERE, leaving the space he vacated wide open
# (beat him by letting him overshoot); a contained/jockeying defender's disk stays
# on you (real containment); a stick on the puck stays a strip threat. The carrier
# evades by placing the puck in his own handling envelope at a point outside every
# defender disk — the SEAM. Two seam reads share one sampler: the max-clearance
# seam (best_evade_point) is the honest "can I keep the puck at all" safety read,
# and the objective-DIRECTED seam (best_evade_point_toward) is the playmaking one
# — the safe sample with the most progress toward the carry objective, so the
# deke goes PAST the man toward the spot the carrier wants, and doubles as a
# carry candidate. prefers_brake_check prices the third maneuver (stop dead, let
# a committed checker's reach fly past) in the same clearance currency.
#
# The BOARDS bound the seam search, not the clearance itself: a wall doesn't
# strip the puck (a carrier 0.3 m off the boards with no defender in reach is
# perfectly safe), it removes ESCAPE OPTIONS — the puck can't be handled through
# it. So the seam samplers intersect the handling envelope with the playing
# surface (off-surface samples are rejected), and the wall-pincer humans
# actually use emerges: pinned against the boards, half the envelope is illegal,
# the best legal seam runs along the wall, and its clearance from the sealing
# defender is honestly small.
const MANEUVER_ACCEL_M_S2: float = GameRules.DEFAULT_SKATER_THRUST_M_S2
const EVADE_HORIZON_S: float = 0.40    # a deke/cut's length — the evasion look-ahead
const EVADE_REACTION_S: float = 0.15   # a defender reads a cut before he can redirect to it
const EVADE_STICK_REACH_M: float = (   # how far a defender's stick touches from his body
		GameRules.DEFAULT_STICK_LENGTH_M + GameRules.DEFAULT_BLADE_LENGTH_M)
# A full stick of clear room reads as fully safe; inside the reach reads as 0.
const EVADE_SAFE_MARGIN_M: float = EVADE_STICK_REACH_M
# Envelope sampling for the seam search (rings × angles). Coarse is fine — the
# seam is a broad region, not a point.
const EVADE_SAMPLE_RINGS: Array[float] = [0.4, 0.8, 1.0]
const EVADE_SAMPLE_ANGLES: int = 12
# A strip needs the blade ON the puck, so a sample sitting exactly at the edge
# of a defender's best-case reach (clearance 0) is escapable in the model's own
# terms — but the model reacts only once (the reaction gate), while a real
# defender re-reads continuously. One blade-length of air is the physical slop
# that survives that re-read: the puck stays a blade off his best-case touch.
# Samples at or above this clearance are treated as genuinely SAFE by the
# objective-directed seam (progress may be preferred among them); below it,
# clearance itself is the only currency.
const EVADE_SAFE_CLEAR_MIN_M: float = GameRules.DEFAULT_BLADE_LENGTH_M


# Gap (metres) from a puck point to the nearest board. Negative outside the
# playing surface — the seam samplers reject those samples (the handling
# envelope intersected with the rink; see the boards note above). Uses the
# INNER extents (the surface the puck actually lives on, inside kickplate lip
# + wall half-thickness).
static func board_gap_m(point: Vector3) -> float:
	return minf(GameRules.INNER_HALF_WIDTH - absf(point.x),
			GameRules.INNER_HALF_LENGTH - absf(point.z))


# Clearance (metres) of a puck point from every defender's reachable stick at
# `time` — >0 means no defender can reach it (that much room), <0 means covered.
# Pure float math, no allocation. Defenders are momentum-projected; the maneuver
# term is reaction-gated (they must read the puck's move before redirecting).
static func reach_clearance(
		puck_point: Vector3, time: float,
		opponents: Array[Vector3], opponent_vels: Array[Vector3],
		opponent_caps: Array = [], maneuver_time: float = -1.0) -> float:
	var n: int = opponents.size()
	if n == 0 or opponent_vels.size() != n:
		return EVADE_SAFE_MARGIN_M   # nothing to evade — fully clear
	# The body rides its momentum over `time` (proj below); the STICK additionally
	# maneuvers off that line over `maneuver_time`, reaction-gated. They default to
	# equal (the carry/hold reads) and differ only for the PASS-RECEPTION read: a
	# defender's body converges over the whole pass flight (`time`), but his final
	# stick adjustment onto the catch is the short reception window
	# (EVADE_HORIZON_S). Using the full flight for the maneuver term too would
	# balloon the reach far past a real stick lunge and double-count the in-flight
	# interception the lane model already prices.
	if maneuver_time < 0.0:
		maneuver_time = time
	# maneuver = t_factor × accel: how far a defender redirects its stick off its
	# momentum line, reaction-gated. Per-opponent when caps are supplied —
	# a defender's Agility (max_accel) sets how far it can lunge, its Size
	# (blade_span) how far its stick touches. Empty caps → league constants for all
	# (every non-attribute caller), reproducing the prior single-reach behaviour.
	var t_factor: float = 0.5 * pow(maxf(0.0, maneuver_time - EVADE_REACTION_S), 2.0)
	var has_caps: bool = opponent_caps.size() == n
	var default_reach: float = t_factor * MANEUVER_ACCEL_M_S2 + EVADE_STICK_REACH_M
	var worst: float = INF
	for i: int in n:
		var proj_x: float = opponents[i].x + opponent_vels[i].x * time
		var proj_z: float = opponents[i].z + opponent_vels[i].z * time
		var reach: float = default_reach
		if has_caps:
			var caps: AISkaterCaps = opponent_caps[i]
			if caps != null:
				reach = t_factor * caps.max_accel + caps.blade_span
		var dx: float = puck_point.x - proj_x
		var dz: float = puck_point.z - proj_z
		var clear: float = sqrt(dx * dx + dz * dz) - reach
		if clear < worst:
			worst = clear
	return worst


# Map clearance (metres) to a [0, 1] possession safety: 0 inside a defender's
# reach, ramping to 1 at a full stick of clear room. Deliberately LINEAR: it is
# the pessimistic half of a compensating pair with reach_clearance's optimistic
# BEST-CASE defender reach — a logistic CDF (grounded as reach uncertainty) was
# tried and broke 8 tests, all toward over-confidence under pressure (tight spots
# reading safe, forced drives, no cycling), confirming the linearity isn't
# independently miscalibrated. A truly honest version would make reach_clearance
# nominal (not best-case) AND use the CDF as a pair; that's a broad recalibration
# of the most-used AI primitive, not a map swap.
static func clearance_to_safety(clearance: float) -> float:
	return clampf(clearance / EVADE_SAFE_MARGIN_M, 0.0, 1.0)


# Base puck-protect reach: how far a carrier holds the puck off his body while
# handling. Hands scales it (a better handler protects it further out / threads a
# tighter seam) — callers pass the scaled value; this is the league default.
const EVADE_CARRY_HANDLE_M: float = 0.9


# Worst reachable clearance along a carry from→to reached at `arrival_time`.
# Samples the mid-point and the destination (each at its own time, defenders
# momentum-projected) and returns the tightest — so a carry that ends in a seam
# but threads a defender mid-route is still penalised. from == to gives the
# static hold read (is this spot clear over the window).
static func carry_clearance(from: Vector3, to: Vector3, arrival_time: float,
		opponents: Array[Vector3], opponent_vels: Array[Vector3],
		opponent_caps: Array = []) -> float:
	var c_mid: float = reach_clearance(
			from.lerp(to, 0.5), arrival_time * 0.5, opponents, opponent_vels, opponent_caps)
	var c_end: float = reach_clearance(to, arrival_time, opponents, opponent_vels, opponent_caps)
	return minf(c_mid, c_end)


# WHERE a carry gets stripped, if it does: the EARLIEST covered point on the path.
# The turnover cost of a carry is priced HERE, not at the destination — a strip
# surrenders the puck where you were caught, in the traffic you were skating
# through, not the safe spot you were headed for. Chronological, not tightest: the
# reach balloons with time (maneuver ∝ time²), so a far destination reads as
# "more covered", but a puck stripped mid-route never reaches it — the mid-point
# strip happens first. Mirrors lane_loss_point for passes; from == to is a stand.
static func carry_strip_point(from: Vector3, to: Vector3, arrival_time: float,
		opponents: Array[Vector3], opponent_vels: Array[Vector3],
		opponent_caps: Array = []) -> Vector3:
	var mid: Vector3 = from.lerp(to, 0.5)
	var c_mid: float = reach_clearance(mid, arrival_time * 0.5, opponents, opponent_vels, opponent_caps)
	if c_mid < 0.0:
		return mid   # covered mid-route — stripped there, before the destination
	var c_end: float = reach_clearance(to, arrival_time, opponents, opponent_vels, opponent_caps)
	if c_end < 0.0:
		return to    # clear mid-route, covered at the destination
	# Neither covered (a low strip probability anyway): the tighter of the two.
	return mid if c_mid <= c_end else to


# The carrier's best evasion target — the point in his handling envelope (where he
# can put/protect the puck over EVADE_HORIZON_S) with the most clearance from
# every defender: the SEAM. `handle_reach` is how far he holds the puck off his
# body (Hands-scaled), so a better handler threads a tighter seam. Returned as a
# world point (y = 0); this max-clearance seam is the carrier's honest
# evadability read (reach_clearance at this point = "can I keep the puck at
# all"). Value-type math; allocation-free.
static func best_evade_point(
		carrier_pos: Vector3, carrier_vel: Vector3,
		opponents: Array[Vector3], opponent_vels: Array[Vector3],
		handle_reach: float, opponent_caps: Array = []) -> Vector3:
	var env: float = 0.5 * MANEUVER_ACCEL_M_S2 * EVADE_HORIZON_S * EVADE_HORIZON_S \
			+ handle_reach
	return _best_clear_point(
			carrier_pos.x + carrier_vel.x * EVADE_HORIZON_S,
			carrier_pos.z + carrier_vel.z * EVADE_HORIZON_S,
			env, opponents, opponent_vels, opponent_caps)


# The OBJECTIVE-DIRECTED seam: where to put the puck to get PAST the pressure
# toward the spot the carrier actually wants (`objective` — the live carry
# anchor). The pure max-clearance seam above answers "where is the puck safest,"
# which is survival, not playmaking — steered by it alone, a carrier is herded
# wherever the ice happens to be emptiest (usually sideways or backwards) and
# never tries to beat his man. This variant is lexicographic in the same
# grounded currencies: among envelope samples that are genuinely SAFE (outside
# every defender's momentum-reach by EVADE_SAFE_CLEAR_MIN_M — see that const),
# take the one with the most PROGRESS toward the objective; only when no safe
# sample exists does it fall back to pure max clearance (nothing to attack —
# survive first). A defender overplaying one side thus gets beaten to the other
# side ON THE WAY FORWARD, and a committed charger's vacated lane is taken as a
# cut PAST him, not a retreat into open ice.
static func best_evade_point_toward(
		carrier_pos: Vector3, carrier_vel: Vector3, objective: Vector3,
		opponents: Array[Vector3], opponent_vels: Array[Vector3],
		handle_reach: float, opponent_caps: Array = []) -> Vector3:
	var env: float = 0.5 * MANEUVER_ACCEL_M_S2 * EVADE_HORIZON_S * EVADE_HORIZON_S \
			+ handle_reach
	return _best_clear_point(
			carrier_pos.x + carrier_vel.x * EVADE_HORIZON_S,
			carrier_pos.z + carrier_vel.z * EVADE_HORIZON_S,
			env, opponents, opponent_vels, opponent_caps, objective)


# WHERE ON THE BLADE to hold the puck under pressure: the point in the carrier's
# handling envelope ALONE (no body-maneuver term — the body keeps doing whatever
# steering wants; this is pure stick work) with the most clearance from every
# defender's momentum-reach. Returned as an OFFSET from the body (y = 0), so the
# consumer re-applies it to the live body position every tick — pull the puck back
# to the protected hip when the presented forward spot is covered, and the body
# becomes the shield. The envelope is intersected with the playing surface, so
# the protected side is never through a wall (the escape runs along the boards).
static func best_handle_protect_point(
		carrier_pos: Vector3, carrier_vel: Vector3,
		opponents: Array[Vector3], opponent_vels: Array[Vector3],
		handle_reach: float, opponent_caps: Array = []) -> Vector3:
	var proj_x: float = carrier_pos.x + carrier_vel.x * EVADE_HORIZON_S
	var proj_z: float = carrier_pos.z + carrier_vel.z * EVADE_HORIZON_S
	var best: Vector3 = _best_clear_point(
			proj_x, proj_z, handle_reach, opponents, opponent_vels, opponent_caps)
	return Vector3(best.x - proj_x, 0.0, best.z - proj_z)


# Shared seam sampler: the max-clearance point over the disk of radius `env`
# around the (already projected) center, evaluated at the evasion horizon.
# Coarse rings × angles are fine — the seam is a broad region, not a point.
# The disk is intersected with the playing surface (off-surface samples are
# rejected — the puck can't be handled through a wall), which is what makes a
# wall-pinned carrier's best seam run ALONG the boards and read honestly tight;
# the projected center stays as the fallback even off-surface (the containment
# backstop owns that degenerate case, not the seam search).
#
# With a finite `objective`, the sweep is objective-directed (see
# best_evade_point_toward): among samples clearing EVADE_SAFE_CLEAR_MIN_M the
# one closest to the objective wins; the max-clearance point remains the
# fallback when no sample is safe.
static func _best_clear_point(proj_x: float, proj_z: float, env: float,
		opponents: Array[Vector3], opponent_vels: Array[Vector3],
		opponent_caps: Array = [], objective: Vector3 = Vector3.INF) -> Vector3:
	var directed: bool = objective.is_finite()
	var best: Vector3 = Vector3(proj_x, 0.0, proj_z)
	var best_clear: float = reach_clearance(best, EVADE_HORIZON_S, opponents, opponent_vels, opponent_caps)
	var best_safe: Vector3 = Vector3.INF
	var best_safe_progress: float = INF   # distance to objective; smaller = more progress
	if directed and best_clear >= EVADE_SAFE_CLEAR_MIN_M:
		best_safe = best
		best_safe_progress = Vector2(objective.x - best.x, objective.z - best.z).length()
	for ring: float in EVADE_SAMPLE_RINGS:
		var radius: float = env * ring
		for k: int in EVADE_SAMPLE_ANGLES:
			var ang: float = TAU * float(k) / float(EVADE_SAMPLE_ANGLES)
			var p := Vector3(proj_x + cos(ang) * radius, 0.0, proj_z + sin(ang) * radius)
			if board_gap_m(p) < 0.0:
				continue
			var c: float = reach_clearance(p, EVADE_HORIZON_S, opponents, opponent_vels, opponent_caps)
			if c > best_clear:
				best_clear = c
				best = p
			if directed and c >= EVADE_SAFE_CLEAR_MIN_M:
				var progress: float = Vector2(objective.x - p.x, objective.z - p.z).length()
				if progress < best_safe_progress:
					best_safe_progress = progress
					best_safe = p
	if directed and best_safe.is_finite():
		return best_safe
	return best


# ── Brake check (the committed stop that lets the checker fly by) ────────────
# A brake check is the third answer to pressure, next to the cut and the
# shield: kill all speed so the defender's momentum carries his reach PAST the
# puck, then re-accelerate into the lane he vacated. It is exactly the
# reachable-set model run against a DIFFERENT own-body plan: braked, the puck
# ends at the physical stop point instead of riding downrange to where his poke
# is timed. Worth it only when that braked hold reads meaningfully clearer than
# the cut (killing momentum is a real cost the cut doesn't pay), which is the
# compare `prefers_brake_check` runs.

# How hard the real brake key decelerates the body — same value as
# AISteering.ARRIVAL_BRAKE_DECEL_M_S2 (kept as a local const so the dependency
# between the two domain classes stays one-directional: steering reads the
# evasion consts here, never the reverse).
const BRAKE_DECEL_M_S2: float = 10.0

# The braked-hold read must itself be genuinely safe — the same blade-of-air
# standard the directed seam applies — AND beat the cut by a real margin.
# The margin is tactical, not evaluated: braking surrenders all momentum
# (re-acceleration to top speed takes ~a second), so a marginally clearer stop
# isn't worth planting your feet for. Roughly one more blade of air.
const BRAKE_CHECK_MARGIN_M: float = GameRules.DEFAULT_BLADE_LENGTH_M


# Where the puck comes to rest if the carrier slams the brake NOW: the current
# spot plus the physical stopping distance v²/(2·decel) along the velocity.
static func brake_stop_point(puck_pos: Vector3, carrier_vel: Vector3) -> Vector3:
	var v_xz := Vector2(carrier_vel.x, carrier_vel.z)
	var speed: float = v_xz.length()
	if speed < 0.001:
		return puck_pos
	var stop_dist: float = speed * speed / (2.0 * BRAKE_DECEL_M_S2)
	var inv: float = stop_dist / speed
	return Vector3(puck_pos.x + v_xz.x * inv, 0.0, puck_pos.z + v_xz.y * inv)


# Should the carrier answer this pressure with a brake check instead of the cut
# toward `cut_seam`? Both maneuvers are priced by the same reachable
# carry_clearance over the evasion horizon — the brake as the short braking
# path to the physical stop point (a defender sweeping through it mid-stop is
# caught by the mid-route sample), the cut as the carry to the seam. TRUE iff
# the braked hold is genuinely safe (≥ the blade-of-air floor) and clears the
# cut by BRAKE_CHECK_MARGIN_M. A jockeying defender pacing the carrier stays on
# him through a brake (his projected reach never leaves), so this self-selects
# for genuinely committed pressure — the only kind a brake check beats.
static func prefers_brake_check(
		puck_pos: Vector3, carrier_vel: Vector3, cut_seam: Vector3,
		opponents: Array[Vector3], opponent_vels: Array[Vector3],
		opponent_caps: Array = []) -> bool:
	var stop: Vector3 = brake_stop_point(puck_pos, carrier_vel)
	var brake_clear: float = carry_clearance(
			puck_pos, stop, EVADE_HORIZON_S, opponents, opponent_vels, opponent_caps)
	if brake_clear < EVADE_SAFE_CLEAR_MIN_M:
		return false
	var cut_clear: float = carry_clearance(
			puck_pos, cut_seam, EVADE_HORIZON_S, opponents, opponent_vels, opponent_caps)
	return brake_clear > cut_clear + BRAKE_CHECK_MARGIN_M


# ── Fake-then-cut deke (manufacturing the opening) ───────────────────────────
# The seam cut and the brake check only EXPLOIT commitment a defender makes on
# his own — a patient jockey who never commits leaves no clearance to cut into
# and the duel stalemates. A real deke MANUFACTURES the commitment: sell one
# side, the defender must match it (gap control), and matching loads him with
# lateral momentum + displacement his reaction then can't unwind before the
# cut passes his plane on the other side.
#
# The whole read is the existing reachable-set model run against the
# defender's POST-BITE state: during the fake he reads for EVADE_REACTION_S,
# then accelerates toward the fake at his real max_accel (per-build caps); at
# the cut his reach starts from that shifted, wrong-way-moving state and is
# reaction-gated AGAIN before he can redirect. GO iff the cut-side point is
# covered NOW (nothing to cut into — otherwise the plain seam owns it) but
# clear of everyone AFTER the bite by the blade-of-air standard. Grounded and
# self-calibrating: an agile defender bites harder — you CAN deke the good
# defender — while a sluggish one barely moves (but him you simply beat).
#
# Durations are the shared contract between this eval and the state machine's
# committed execution (gesture geometry, like the wind-up spans): the fake
# must comfortably exceed the defender's read time or there is nothing to
# bite on; the cut is a single explosive redirect.
const DEKE_FAKE_S: float = 0.3
const DEKE_CUT_S: float = 0.2


# Which side to cut past `deked_idx` after faking the other way: +1 / -1 as
# the sign on `perp` (caller supplies the axis frame: `axis` = unit puck →
# defender-projected line, `perp` = its left-hand perpendicular — the caller
# re-derives the fake/cut directions from the same frame, so eval and
# execution agree by construction). 0 = no manufactured opening (already
# beatable, or the bite doesn't buy enough). Pure float math, no allocation.
static func deke_cut_side(
		puck_pos: Vector3, carrier_vel: Vector3, handle_reach: float,
		axis: Vector3, perp: Vector3, deked_idx: int,
		opponents: Array[Vector3], opponent_vels: Array[Vector3],
		opponent_caps: Array = []) -> int:
	var t_total: float = DEKE_FAKE_S + DEKE_CUT_S
	# The deked man's real build (league defaults when caps are absent).
	var d_pos: Vector3 = opponents[deked_idx]
	var d_vel: Vector3 = opponent_vels[deked_idx]
	var d_accel: float = MANEUVER_ACCEL_M_S2
	var d_span: float = EVADE_STICK_REACH_M
	if opponent_caps.size() == opponents.size():
		var caps: AISkaterCaps = opponent_caps[deked_idx]
		if caps != null:
			d_accel = caps.max_accel
			d_span = caps.blade_span
	# Where the cut can put the puck: the ballistic ride plus the CUT phase's
	# own handling envelope (the fake spends the earlier effort selling the
	# other way, so only the cut leg's maneuver counts — conservative).
	var cut_env: float = 0.5 * MANEUVER_ACCEL_M_S2 * DEKE_CUT_S * DEKE_CUT_S + handle_reach
	var ride: Vector3 = carrier_vel * t_total
	# Post-fake bite: he reads for EVADE_REACTION_S, then matches the fake.
	var t_bite: float = maxf(0.0, DEKE_FAKE_S - EVADE_REACTION_S)
	var bite_v: float = d_accel * t_bite
	var bite_disp: float = 0.5 * d_accel * t_bite * t_bite
	# His redirect budget during the cut, reaction-gated afresh (he must read
	# the cut before unwinding the bite).
	var cut_maneuver: float = 0.5 * d_accel \
			* pow(maxf(0.0, DEKE_CUT_S - EVADE_REACTION_S), 2.0)
	var best_side: int = 0
	var best_post: float = -INF
	for side_i: int in [-1, 1]:
		var s: float = float(side_i)
		var cut_dir: Vector3 = axis + perp * s
		var cut_len: float = cut_dir.length()
		if cut_len < 0.001:
			continue
		var p: Vector3 = puck_pos + ride + cut_dir * (cut_env / cut_len)
		if board_gap_m(p) < 0.0:
			continue
		# NOW: everyone as-is over the whole window — is the cut side already
		# takeable? Then there is nothing to manufacture (the seam owns it).
		var clear_now: float = reach_clearance(
				p, t_total, opponents, opponent_vels, opponent_caps)
		if clear_now >= EVADE_SAFE_CLEAR_MIN_M:
			continue
		# POST-BITE: the deked man starts the cut displaced toward the fake
		# (−perp·s) and moving that way; everyone else unchanged.
		var fake_dir: Vector3 = perp * (-s)
		var pos1: Vector3 = d_pos + d_vel * DEKE_FAKE_S + fake_dir * bite_disp
		var vel1: Vector3 = d_vel + fake_dir * bite_v
		var proj: Vector3 = pos1 + vel1 * DEKE_CUT_S
		var clear_deked: float = Vector2(p.x - proj.x, p.z - proj.z).length() \
				- (cut_maneuver + d_span)
		var clear_post: float = clear_deked
		# The rest of the defense still plays over the whole window.
		for i: int in opponents.size():
			if i == deked_idx:
				continue
			var other_pos: Vector3 = opponents[i]
			var other_vel: Vector3 = opponent_vels[i]
			var reach: float = 0.5 * MANEUVER_ACCEL_M_S2 \
					* pow(maxf(0.0, t_total - EVADE_REACTION_S), 2.0) + EVADE_STICK_REACH_M
			if opponent_caps.size() == opponents.size():
				var ocaps: AISkaterCaps = opponent_caps[i]
				if ocaps != null:
					reach = 0.5 * ocaps.max_accel \
							* pow(maxf(0.0, t_total - EVADE_REACTION_S), 2.0) + ocaps.blade_span
			var ox: float = p.x - (other_pos.x + other_vel.x * t_total)
			var oz: float = p.z - (other_pos.z + other_vel.z * t_total)
			clear_post = minf(clear_post, sqrt(ox * ox + oz * oz) - reach)
		if clear_post >= EVADE_SAFE_CLEAR_MIN_M and clear_post > best_post:
			best_post = clear_post
			best_side = side_i
	return best_side


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
# either net's PHYSICAL footprint. The blocking rectangle is the net at its
# widest — the back-frame trapezoid half-width (NET_BACK_HALF_WIDTH, wider than
# the goal mouth's post span) — inflated by the puck's own radius on every side,
# since the puck is a disc whose EDGE clanks the frame, not a point. Matching
# GameRules.is_over_net_footprint's widest-span reading. This was previously the
# post half-width with no inflation, which is why feeds from below the goal line
# aimed across the slot read "clear" and rang off the OUTSIDE of the cage: the
# lane threaded the 0.915 post line but not the 1.02 (+ puck radius) back frame.
# Used by score_pass / the carrier pass EV / the live fired aim to treat the net
# as a hard pass-lane obstruction.
static func pass_lane_blocked_by_net(from: Vector3, to: Vector3) -> bool:
	var goal_line_z: float = GameRules.GOAL_LINE_Z - GameRules.PUCK_COLLISION_RADIUS
	var net_half_w: float = GameRules.NET_BACK_HALF_WIDTH + GameRules.PUCK_COLLISION_RADIUS
	var net_back_z: float = GameRules.GOAL_LINE_Z + GameRules.NET_DEPTH \
			+ GameRules.PUCK_COLLISION_RADIUS
	# Team 0's net (positive z).
	if _segment_crosses_aabb_xz(
			from.x, from.z, to.x, to.z,
			-net_half_w, net_half_w,
			goal_line_z, net_back_z):
		return true
	# Team 1's net (negative z), mirrored.
	if _segment_crosses_aabb_xz(
			from.x, from.z, to.x, to.z,
			-net_half_w, net_half_w,
			-net_back_z, -goal_line_z):
		return true
	return false


# ── The net as a CARRY / BLADE obstacle ──────────────────────────────────────
# The cage is a solid frame in the middle of the behind-the-net game, and the
# carry model has to see it the same way the body steering already does
# (AISteering._net_detour rounds the post). Two consumers:
#   - carry_path_blocked_by_net — a carried traverse (body + puck) cannot pass
#     through the cage, so a carry candidate whose straight route crosses it
#     is unreachable as priced (the post-walkout candidates are the legal
#     routes out from behind the line; see AIRoleCarrier._best_carry).
#   - net_safe_blade_target — the carry cursor must never ask the blade IK to
#     reach THROUGH the frame: stick-on-net contact dislodges the carried
#     puck (the behind-the-net giveaway), so a crossing chord is swung to the
#     tangent bearing around the nearer post — the blade-level mirror of the
#     body's net detour.
# Margins are physical half-widths of the thing traversing: a carried body +
# puck for the path, a blade length of standoff for the cursor (same standard
# as the boards clamp).
const CARRY_NET_CLEAR_MARGIN_M: float = 0.5
const BLADE_NET_CLEAR_MARGIN_M: float = GameRules.DEFAULT_BLADE_LENGTH_M


# True iff a carried traverse from → to would pass through either cage
# (frame AABB inflated by the carry margin). From-inside counts as blocked —
# the slab test's t_min = 0 is inside the box — which is correct: a body
# standing against the mesh can't carry through it.
static func carry_path_blocked_by_net(from: Vector3, to: Vector3) -> bool:
	var hw: float = GameRules.NET_BACK_HALF_WIDTH + CARRY_NET_CLEAR_MARGIN_M
	var z_front: float = GameRules.GOAL_LINE_Z - CARRY_NET_CLEAR_MARGIN_M
	var z_back: float = GameRules.GOAL_LINE_Z + GameRules.NET_DEPTH + CARRY_NET_CLEAR_MARGIN_M
	if _segment_crosses_aabb_xz(from.x, from.z, to.x, to.z, -hw, hw, z_front, z_back):
		return true
	return _segment_crosses_aabb_xz(from.x, from.z, to.x, to.z, -hw, hw, -z_back, -z_front)


# Redirect a blade-aim target whose chord from `from` crosses a net frame:
# rotate the aim to the frame's tangent bearing around the nearer post (the
# occluded bearing interval is bounded by the inflated frame's corner
# bearings; the chord crosses, so the original bearing lies inside it — clamp
# to the nearer edge plus a small step of daylight). Distance from `from` is
# preserved, y is flattened (blade targets live on the ice plane). A
# non-crossing target returns unchanged. Degenerate case — `from` itself
# inside the inflated frame region (pinned against the mesh): no tangent
# exists, so slide the aim laterally toward the nearer post-side exit.
static func net_safe_blade_target(from: Vector3, target: Vector3) -> Vector3:
	var hw: float = GameRules.NET_BACK_HALF_WIDTH + BLADE_NET_CLEAR_MARGIN_M
	var z_front: float = GameRules.GOAL_LINE_Z - BLADE_NET_CLEAR_MARGIN_M
	var z_back: float = GameRules.GOAL_LINE_Z + GameRules.NET_DEPTH + BLADE_NET_CLEAR_MARGIN_M
	var box_z0: float
	var box_z1: float
	if _segment_crosses_aabb_xz(from.x, from.z, target.x, target.z, -hw, hw, z_front, z_back):
		box_z0 = z_front
		box_z1 = z_back
	elif _segment_crosses_aabb_xz(from.x, from.z, target.x, target.z, -hw, hw, -z_back, -z_front):
		box_z0 = -z_back
		box_z1 = -z_front
	else:
		return target
	var to_target := Vector2(target.x - from.x, target.z - from.z)
	var dist: float = to_target.length()
	if dist < 0.001:
		return target
	if from.x > -hw and from.x < hw and from.z > box_z0 and from.z < box_z1:
		var side: float = signf(from.x) if from.x != 0.0 else 1.0
		return Vector3(from.x + side * dist, 0.0, from.z)
	var target_ang: float = atan2(to_target.x, to_target.y)
	var min_rel: float = INF
	var max_rel: float = -INF
	for corner_x: float in [-hw, hw]:
		for corner_z: float in [box_z0, box_z1]:
			var rel: float = wrapf(
					atan2(corner_x - from.x, corner_z - from.z) - target_ang, -PI, PI)
			min_rel = minf(min_rel, rel)
			max_rel = maxf(max_rel, rel)
	# The chord crosses, so 0 ∈ [min_rel, max_rel]. Swing to the nearer edge,
	# plus a small step of daylight past the corner.
	var swing: float = min_rel if -min_rel <= max_rel else max_rel
	var out_ang: float = target_ang + swing + signf(swing) * 0.05
	return Vector3(from.x + sin(out_ang) * dist, 0.0, from.z + cos(out_ang) * dist)


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
