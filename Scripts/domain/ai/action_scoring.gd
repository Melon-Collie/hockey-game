class_name AIActionScoring

# Pure-function utility scoring for on-puck actions. Each score is a
# multiplicative composition of factors in [0, 1].
#
# Two leaf scorers (score_shoot, score_pass) plus a recursive depth-2
# score_at(pos) defined in the SM. Top-level options compete uniformly:
#
#   shoot:  score_shoot(self_pos)
#   pass:   score_at(receiver_lead) × path_clearance × time_factor
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

# Beyond this range, shots score 0 from distance alone — keeps bots
# from launching pucks at the goalie from the blue line. Quadratic
# falloff outside IDEAL_SHOT_DIST_M. Bumped from 18 → 22 to lift
# mid-range scores: the response at 10 m is 0.91 instead of 0.83, so
# clean mid-range shots score meaningfully and pass-to-receiver scores
# (which transitively include `score_shoot(receiver)`) are pulled up
# in the same band — passes to a teammate with a clear path to the
# net are now competitive with self-carry-to-slot. Raise toward 26
# if bots still refuse meaningful shots; lower toward 18 if blue-line
# shots are too common.
const SHOT_RANGE_FALLOFF_M: float = 22.0

# The slot — the spot where dist_response peaks (= 1.0). Distances
# closer to the goal score below 1.0 because driving past the slot
# means skating into the goalie's coverage; distances further away
# score below 1.0 because the shot is too long. 5 m matches the
# face-off circle hash / hard slot in real-rink geometry. Without this
# peak the dist_response is monotone in 1/dist and the carrier always
# scores a 1-m drive to the net higher than a slot stand-still shot,
# so it never actually fires — it just keeps closing distance until
# the goalie eats the puck. Raise toward 7 if bots release too far
# out; lower toward 4 if they keep crashing into the goalie.
const IDEAL_SHOT_DIST_M: float = 5.0

# Close-side falloff width. The dist_response drops symmetrically on
# both sides of IDEAL_SHOT_DIST_M, but driving inside the slot is
# only mildly worse than the slot itself (the GOALIE_ZONE penalty
# below already covers the "crashed into the goalie" case). Using a
# wider close-side width than IDEAL_SHOT_DIST_M softens the inside
# falloff so a 3 m point-blank shot loses only ~6% from distance
# instead of the ~16% the symmetric formula gave. Raise toward 12
# if point-blank shots feel under-valued; lower toward 5 (symmetric)
# if bots crash into the crease too often.
const CLOSE_FALLOFF_M: float = 8.0

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
# GOALIE_REACTION_DELAY_S references GameRules so the AI prediction
# stays in lockstep with the live goalie's `reaction_delay` @export
# default — they're the same human reflex, single source of truth.
# GOALIE_MAX_LATERAL_SPEED_MPS is currently a calibration estimate;
# the live goalie has separate t_push_speed / shuffle_speed /
# tracking_speed depending on state, so there is no clean single
# source — leave as a literal feel value for now.
const GOALIE_REACTION_DELAY_S: float = GameRules.DEFAULT_GOALIE_REACTION_DELAY_S
const GOALIE_MAX_LATERAL_SPEED_MPS: float = 5.0

# Shadow half-width used by AIShotAim.compute_open_net_aim for the
# lane-check aim point. Independent of the new coverage model — it
# just picks an aim point past the goalie for the segment check.
const GOALIE_SHADOW_HALF_M: float = 0.3

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

# Lane-clear: an opponent within this perpendicular distance of the
# puck-flight segment can intercept. Roughly stick-blade reach of a
# lane defender. Raise toward 2.0 if passes still get picked off
# mid-lane; lower toward 1.0 if bots over-reject legitimate threading
# passes.
const LANE_CLEAR_RADIUS_M: float = 1.5

# Lane-clear reaction window. A defender at fractional position `t`
# along the puck path has time `t × flight_time` to read the release
# and slide their stick into the lane. Below LANE_REACTION_DELAY_S they
# can't react in time (puck is past them before they recognize the
# play). LANE_REACTION_RAMP_S is the additional time over which the
# block strength ramps from 0 to full. Defenders right at the shooter
# (low t) get little weight; defenders mid-segment carry full weight.
# Shots (~30 m/s) and passes (~22 m/s) use this same model with
# different speeds → defenders close to shooter contribute more for
# slow passes than for fast shots.
const LANE_REACTION_DELAY_S: float = 0.15
const LANE_REACTION_RAMP_S: float = 0.10

# Speed assumptions for lane-clear reaction-window math. Approximate
# values used by score_shoot / score_pass when calling _lane_clear.
const SHOT_SPEED_M_S: float = 30.0
const PASS_SPEED_M_S: float = 22.0

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
#   dist_response     = peak-at-slot curve (1.0 at IDEAL_SHOT_DIST_M)
#   shot_angle_factor = 1 - shot_angle / (PI / 2)                      (linear)
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
		goalie_current_pos: Vector3 = Vector3.INF) -> float:
	# Hard gate: shooter past (or on) the attacking goal line can't
	# shoot in — wraparound territory, returns 0 immediately.
	var net_normal_z: float = -signf(attacking_goal.z)
	var forward: float = (shooter.z - attacking_goal.z) * net_normal_z
	if forward < 0.001:
		return 0.0

	# Distance response — bidirectional quadratic. Peaks at 1.0 at the
	# slot (IDEAL_SHOT_DIST_M) and falls off in both directions:
	# quadratic toward the goal mouth (penalises crashing into the
	# goalie's coverage) and quadratic out to SHOT_RANGE_FALLOFF_M
	# (penalises long bombs). Without the close-range falloff the
	# carrier keeps preferring "drive 1 m closer" over "shoot now," so
	# bots never release in the slot — they grind into the goalie.
	var dist: float = shooter.distance_to(attacking_goal)
	var dist_response: float
	if dist >= IDEAL_SHOT_DIST_M:
		var far_norm: float = clampf(
				(dist - IDEAL_SHOT_DIST_M) / (SHOT_RANGE_FALLOFF_M - IDEAL_SHOT_DIST_M),
				0.0, 1.0)
		dist_response = 1.0 - far_norm * far_norm
	else:
		var close_norm: float = clampf(
				(IDEAL_SHOT_DIST_M - dist) / CLOSE_FALLOFF_M,
				0.0, 1.0)
		dist_response = 1.0 - close_norm * close_norm

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
	var coverage: float = BASE_COVERAGE * squareness
	var shot_quality: float = dist_response * shot_angle_factor * (1.0 - coverage)

	# Lane clear vs the actual aim point ShotAim would pick (past the
	# goalie's shadow). Defenders close to the shooter (low t along
	# the shot path) have little reaction time and barely contribute;
	# defenders mid-line have full intercept weight. Shots travel fast
	# enough (~30 m/s) that even mid-line defenders only marginally
	# block — `_lane_clear` does the per-defender reaction-window math.
	var aim: Vector3 = AIShotAim.compute_open_net_aim(
			shooter, predicted_goalie_pos, attacking_goal.z,
			net_half_width, GOALIE_SHADOW_HALF_M)
	var lane: float = _lane_clear(shooter, aim, opponents, SHOT_SPEED_M_S)

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
		goalie_current_pos: Vector3 = Vector3.INF) -> float:
	if _is_past_goal_line(receiver, attacking_goal):
		return 0.0
	if pass_lane_blocked_by_net(shooter, receiver):
		return 0.0
	var lane: float = _lane_clear(shooter, receiver, opponents, PASS_SPEED_M_S)
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
	var receiver_shot: float = score_shoot(
			receiver, attacking_goal, predicted_goalie_pos, net_half_width, opponents,
			goalie_current_pos)
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


# Lane-clear factor in [0, 1]. Per-defender block strength composes:
#
#   perp_factor     = 1 - perp/LANE_CLEAR_RADIUS_M    (1 on line, 0 at radius)
#   reaction_factor = clamp((t × flight - REACTION) / RAMP, 0, 1)
#                                                     (0 if no time, 1 if plenty)
#   block_strength  = perp_factor × reaction_factor
#
# Lane clear = 1 - max(block_strength) across all defenders. Single-
# blocker model: the worst defender for the puck-flight defines the
# lane clearness. Taking the max instead of summing avoids
# double-counting two defenders standing next to each other.
#
# `puck_speed_m_s` should be the actual speed the puck travels along
# the segment — shots ~30 m/s, passes ~22 m/s. Faster pucks → less
# reaction time → defenders contribute less.
#
# Only counts opponents whose projection onto the segment falls between
# the endpoints (t ∈ [0, 1]).
static func _lane_clear(from: Vector3, to: Vector3, opponents: Array[Vector3],
		puck_speed_m_s: float) -> float:
	var dx: float = to.x - from.x
	var dz: float = to.z - from.z
	var line_len_sq: float = dx * dx + dz * dz
	if line_len_sq < 0.01:
		return 1.0  # degenerate (overlapping endpoints)
	var line_len: float = sqrt(line_len_sq)
	var flight_time: float = line_len / maxf(puck_speed_m_s, 1.0)
	var max_block: float = 0.0
	for p: Vector3 in opponents:
		var pdx: float = p.x - from.x
		var pdz: float = p.z - from.z
		var t: float = (pdx * dx + pdz * dz) / line_len_sq
		if t <= 0.0 or t >= 1.0:
			continue
		var time_to_defender: float = t * flight_time
		var reaction_factor: float = clampf(
				(time_to_defender - LANE_REACTION_DELAY_S) / LANE_REACTION_RAMP_S,
				0.0, 1.0)
		if reaction_factor <= 0.0:
			continue
		var closest_x: float = from.x + t * dx
		var closest_z: float = from.z + t * dz
		var perp_x: float = p.x - closest_x
		var perp_z: float = p.z - closest_z
		var perp: float = sqrt(perp_x * perp_x + perp_z * perp_z)
		if perp >= LANE_CLEAR_RADIUS_M:
			continue
		var perp_factor: float = 1.0 - perp / LANE_CLEAR_RADIUS_M
		var block: float = perp_factor * reaction_factor
		if block > max_block:
			max_block = block
	return clampf(1.0 - max_block, 0.0, 1.0)


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
	var pass_score: float = score_pass(
			carrier_pos, receiver_pos, our_net, our_goalie_pos,
			net_half_width, defenders)
	var lane: float = _lane_clear(carrier_pos, receiver_pos, defenders, PASS_SPEED_M_S)
	var positional: float = position_potential(receiver_pos, our_net, defenders)
	return maxf(pass_score, lane * positional)


# Public lane-clearance check for CARRY candidates — the bot is
# physically traveling along this segment, not firing a puck through
# it, so the reaction-window math from `_lane_clear` doesn't apply.
# A defender anywhere on the path is in the way regardless of flight
# time. Returns 1.0 if no opponent is within LANE_CLEAR_RADIUS_M of
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
	return clampf(perp / LANE_CLEAR_RADIUS_M, 0.0, 1.0)


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
static func time_to_arrive(from_pos: Vector3, dest: Vector3,
		from_velocity: Vector3) -> float:
	var dx: float = dest.x - from_pos.x
	var dz: float = dest.z - from_pos.z
	var dist: float = sqrt(dx * dx + dz * dz)
	if dist < 0.001:
		return 0.0
	var inv: float = 1.0 / dist
	var speed_along: float = from_velocity.x * dx * inv + from_velocity.z * dz * inv
	var effective: float = maxf(MIN_TRAVEL_SPEED_M_S,
			SKATER_REF_SPEED_M_S + speed_along)
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
