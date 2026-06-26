class_name AIRoleCarrier
extends RefCounted

const _PhysicsConstants: GDScript = preload("res://Scripts/game/constants.gd")

# CARRIER role behavior: the puck-carrying utility AI. Scores SHOOT
# (wrister), PASS (per teammate), and CARRY (8 polar candidates +
# slot anchor + stand-still) on equal footing every
# PICK_ACTION_PERIOD_TICKS ticks. Hysteresis on the current intent
# prevents flicker between close-scoring fire options during pre-aim;
# CARRY does NOT get a hysteresis bonus (stand-still ties with the
# best fire option from the same position by construction, and we
# want fire to win those ties).
#
# This module is stateful — it owns hysteresis state, scratch
# buffers, and the cooldown counter. SkaterAgentStateMachine creates
# one instance per agent in setup() and calls decide(ctx) every
# CARRY-state tick. Mirror fields the state machine reads after
# decide():
#   - intended_action  (INTENT_*)
#   - last_carry_anchor
#   - pass_target_peer_id
#   - shot_is_elevated
#   - debug_*
#
# The state machine translates intended_action back into its own
# State enum for steering / pre-aim / press transitions.

# ── Intent enum ──────────────────────────────────────────────────────────────
# Local mirror of the relevant State values from
# SkaterAgentStateMachine. Ints rather than the State enum keep this
# file decoupled from the state machine for unit testing.
const INTENT_CARRY: int = 0
const INTENT_SHOOT: int = 1
const INTENT_PASS: int = 3
const INTENT_QUICK_SHOT: int = 4

# ── Scoring constants ────────────────────────────────────────────────────────
# Re-evaluation cadence. CARRY runs every physics tick; without throttling the
# scoring (10 carry candidates × per-teammate pass × opponent
# projections) would fire every tick per bot. ~30 Hz is plenty — pre-aim
# convergence gates the actual transition, and humans react in 250 ms+.
const PICK_ACTION_PERIOD_TICKS: int = _PhysicsConstants.PHYSICS_TICK / 30   # ~30 Hz re-eval

# Pass flight clamp. A 0.6 s lead lets the bot pass to a teammate up
# to ~16 m away (PASS_SPEED_M_S × 0.6); longer leads suffer from
# stale opponent projections.
const PASS_LEAD_MAX_S: float = 0.6

# A pass only wrister-charges when its adaptive launch target exceeds the snap
# floor (PASS_SPEED_M_S) by at least this much; nearer the floor the windup buys
# too little pace to justify the commit, so the bot quick-releases instead.
const PASS_CHARGE_MIN_DELTA_M_S: float = 1.0

# Quick-shot blade ROM cone: passes within this half-angle of facing
# don't pay rotation cost (blade can fire from current facing).
# Outside the cone, only the OVERSHOOT (angle - ROM) costs time.
const BOT_BLADE_ROM_HALF_ANGLE_RAD: float = PI * 0.5

# Facing rotation rate used to convert overshoot angle into rotation
# time during pass scoring.
const BOT_FACING_ROTATION_RATE_RAD_S: float = 6.0

# Carry candidate generation: 8 polar cardinals at this radius +
# slot anchor + stand-still.
const CARRY_SEARCH_STEP_M: float = 3.0
# Carry candidates are clamped inside the goal-line buffer and the
# rink-X inset — both defined on AIRoleHelpers (single source).

# Elevation gate constants. Reactive: goalie already down → top
# corners exposed. Proactive: close shot with a clean lane → pick
# the corner over the goalie's glove/blocker rather than dribbling
# along the ice. Cleared by the next decision tick.
const ELEVATE_CLOSE_SHOT_RANGE_M: float = 12.0
const ELEVATE_SCORE_GATE: float = 0.4

# GoalieController.State values — duplicated here to avoid a
# domain → controller import. Keep in sync with that enum.
const _GOALIE_STATE_BUTTERFLY: int = 1
const _GOALIE_STATE_RECOVERING: int = 2
const _GOALIE_STATE_SLIDING: int = 6
const _GOALIE_STATE_COILING: int = 7

# Pre-baked rotations for the 8 polar cardinal carry candidates.
const _POLAR_ANGLES: Array[float] = [
		0.0, PI * 0.25, PI * 0.5, PI * 0.75,
		PI, -PI * 0.75, -PI * 0.5, -PI * 0.25,
]


# ── Persistent decision state ────────────────────────────────────────────────
# What the carrier currently wants to do. CARRY = no fire intent;
# fire intents persist across cooldown ticks so pre-aim keeps
# driving toward the chosen action.
var intended_action: int = INTENT_CARRY

# Set when intent commits to PASS. Consumed by the state machine
# when transitioning into PASS_PRESSED. -1 = no current pass target.
var pass_target_peer_id: int = -1

# Set alongside pass_target_peer_id when the chosen PASS is far enough
# that the carrier wrister-charges instead of quick-releasing. The
# state machine consumes this when entering PASS_PRESSED to branch
# between one-tick fire and ~250 ms wrister charge.
var pass_should_charge: bool = false

# Distance-adaptive LAUNCH speed for the chosen PASS (AIActionScoring.
# pass_launch_speed): soft for short feeds, harder for long ones so they all
# arrive at a comfortable pace. The state machine maps this to the wrister
# charge fraction it winds up to, and leads the pass at this speed.
var pass_target_speed: float = AIActionScoring.PASS_SPEED_M_S

# Set alongside pass_target_peer_id when the chosen PASS is a long
# feed whose lane is contested by a mid-lane defender that a saucer
# (elevated) pass would fly over. The state machine consumes this when
# entering PASS_PRESSED to toggle elevation on for the release.
var pass_should_saucer: bool = false

# Set when intent commits to SHOOT. Consumed by the state machine's
# press-state handlers to drive elevation.
var shot_is_elevated: bool = false

# Cached carry destination from the most recent re-eval. Read by the
# state machine to drive steering during CARRY.
var last_carry_anchor: Vector3 = Vector3.ZERO

# ── Throttle ─────────────────────────────────────────────────────────────────
var _pick_action_cooldown: int = 0

# ── Scratch buffers (reused across ticks, refilled per call) ────────────────
var _scratch_opponents: Array[Vector3] = []
# Velocities index-matched to _scratch_opponents, so the fired-puck lane
# model can dead-reckon a defender bearing down on a passing lane.
var _scratch_opponent_vels: Array[Vector3] = []
var _scratch_opponents_shoot: Array[Vector3] = []
var _scratch_opponents_pass: Array[Vector3] = []
var _scratch_opponents_path: Array[Vector3] = []
var _scratch_teammate_ids: Array[int] = []
# Our skaters excluding the carrier — the defenders that reduce the
# opponent's threat in the turnover-cost term (the carrier just got
# beat, so they don't count). Rebuilt once per _pick_action.
var _scratch_our_defenders: Array[Vector3] = []

# ── Debug readout ────────────────────────────────────────────────────────────
# Populated every re-eval; the state machine forwards these to its
# own debug_* fields for AIController / floating label.
var debug_shoot_score: float = 0.0
var debug_quick_shot_score: float = 0.0
var debug_pass_score: float = 0.0
var debug_pass_peer_id: int = 0
var debug_carry_score: float = 0.0
var debug_carry_pos: Vector3 = Vector3.ZERO


# ── Public API ───────────────────────────────────────────────────────────────

# Top-level entry. Throttled at PICK_ACTION_PERIOD_TICKS. Mutates
# own state; the state machine reads `intended_action`,
# `pass_target_peer_id`, `shot_is_elevated`, `last_carry_anchor`,
# and the debug_* fields after this returns.
#
# Returns a RoleDecision shaped like the off-puck role behaviors:
#   - target_position = last_carry_anchor (winning carry candidate)
#   - shoot_intent / pass_intent flags reflect the
#     current persistent intent (so the state machine can read these
#     uniformly across roles in future phases).
func decide(ctx: RoleContext) -> RoleDecision:
	if _pick_action_cooldown <= 0:
		_pick_action(ctx)
		_pick_action_cooldown = PICK_ACTION_PERIOD_TICKS
	else:
		_pick_action_cooldown -= 1

	var d := RoleDecision.new()
	d.target_position = last_carry_anchor
	match intended_action:
		INTENT_SHOOT:
			d.shoot_intent = true
		INTENT_PASS:
			d.pass_intent = true
			d.pass_target_peer_id = pass_target_peer_id
		INTENT_QUICK_SHOT:
			d.quick_shot_intent = true
	return d


# Clear all carrier state. Called by the state machine when leaving
# CARRY for OFF_PUCK / CHASE_PUCK (puck lost). Forces a fresh re-eval
# next time the bot enters CARRY.
func reset() -> void:
	intended_action = INTENT_CARRY
	pass_target_peer_id = -1
	pass_should_charge = false
	pass_target_speed = AIActionScoring.PASS_SPEED_M_S
	pass_should_saucer = false
	shot_is_elevated = false
	last_carry_anchor = Vector3.ZERO
	_pick_action_cooldown = 0


# Clear just the persistent intent (not last_carry_anchor / debug).
# Called by the state machine when committing to a press state, so
# the next CARRY entry starts with no stale intent and re-evaluates
# from scratch.
func clear_intent() -> void:
	intended_action = INTENT_CARRY
	pass_target_peer_id = -1
	pass_should_charge = false
	pass_target_speed = AIActionScoring.PASS_SPEED_M_S
	pass_should_saucer = false
	_pick_action_cooldown = 0


# ── Implementation ──────────────────────────────────────────────────────────

# Scores SHOOT (wrister), PASS (per teammate), and CARRY (10
# candidates) on equal footing. Hysteresis on fire intents only —
# carry does not get a hysteresis bonus (stand-still ties with the
# best fire from the same position by construction). FIRE WINS TIES;
# CARRY only beats fire on STRICTLY better future-action value.
# Mutates pass_target_peer_id when PASS wins, shot_is_elevated when
# SHOOT wins, last_carry_anchor + intended_action always.
func _pick_action(ctx: RoleContext) -> void:
	var snapshot: WorldSnapshot = ctx.snapshot
	var self_pos: Vector3 = ctx.self_pos
	var attacking_goal: Vector3 = ctx.attacking_goal_pos

	_build_action_opponents_lists(ctx)

	# Teammate ids — used by every score_at evaluation (top + inner).
	# Reused scratch buffer; receivers only read from it.
	_scratch_teammate_ids.clear()
	for peer_id: int in snapshot.skater_states:
		if peer_id == ctx.peer_id:
			continue
		if ctx.team_id_by_peer.get(peer_id, -1) == ctx.team_id:
			_scratch_teammate_ids.append(peer_id)

	# Projected RELEASE position for SHOOT scoring. The wrister charge
	# window means the puck actually leaves the blade ~0.25s after
	# the SHOOT intent commits; a bot rushing into the slot should
	# be scoring the spot they'll release from, not the spot they're
	# at now. This also lets the bot start the wind-up early — the
	# score that wins is for the future spot, and by the time the
	# charge completes, the bot has skated into it.
	var self_velocity: Vector3 = ctx.self_velocity
	var horizontal_velocity: Vector3 = Vector3(self_velocity.x, 0.0, self_velocity.z)
	var wrister_release_pos: Vector3 = (
			self_pos + horizontal_velocity * SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S)

	# Goalie prediction at the wrister release time. Pass-receiver and
	# carry-candidate cases get their own predictions inside
	# _compute_best_pass / _best_carry. Predicted with the release-pos
	# puck X so the goalie's slide target matches where the shot
	# actually leaves the blade.
	var wrister_goalie: Vector3 = _predict_goalie_at(
			ctx, SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S, wrister_release_pos)
	var wrister_unsettled: float = _goalie_unsettled_at(
			ctx, SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S, wrister_release_pos)
	# Goalie's CURRENT position (squared to whoever currently holds the
	# puck — that's us as the carrier). Threaded into score_shoot /
	# score_pass so the goalie pressure zone penalises shots from
	# inside the goalie's current set-up line. Back-door receivers
	# (off-axis from this position) pass through unpenalised. Anchored
	# on current self_pos rather than release_pos because that's the
	# goalie's actual current setup line.
	var goalie_now: Vector3 = _goalie_now(ctx)

	# Top-level SHOOT.
	var shoot_score: float = AIActionScoring.score_shoot(
			wrister_release_pos, attacking_goal, wrister_goalie,
			GameRules.NET_HALF_WIDTH, _scratch_opponents_shoot, goalie_now,
			ctx.self_wrister_shot_speed, wrister_unsettled)

	# Top-level QUICK_SHOT — snap release at PASS_SPEED, no charge. The
	# goalie can't slide during a zero-charge release, so a still-squared
	# goalie that would otherwise drift wide stays in position. Off-axis
	# bots benefit (their lateral arc against a still-squared goalie is
	# open); slower puck speed naturally kills long-range attempts via
	# the existing lane_clear math. Release position = current self_pos
	# (no charge motion). Opponents at current positions (no projection).
	var quick_shoot_score: float = AIActionScoring.score_quick_shot(
			self_pos, attacking_goal, goalie_now,
			GameRules.NET_HALF_WIDTH, _scratch_opponents)

	# Top-level PASS — per teammate, score_at(receiver_lead) × lane × time.
	var self_state: SkaterNetworkState = snapshot.skater_states[ctx.peer_id]
	var best_pass: Array = _compute_best_pass(
			ctx, self_state.facing, _scratch_teammate_ids, goalie_now)
	var best_pass_peer: int = best_pass[0]
	var best_pass_score: float = best_pass[1]
	var best_pass_saucer: bool = best_pass[2]

	# Top-level CARRY — best of 10 candidates (8 polar around the slot
	# direction + slot anchor + stand-still). Each scored uniformly:
	# score_at(candidate, projected_opps) × path_clear × time_decay.
	# Time uses momentum-aware effective speed so reverse candidates
	# self-discount via longer arrival time.
	var carry_result: Array = _best_carry(ctx, goalie_now)
	var carry_score: float = carry_result[0]
	last_carry_anchor = carry_result[1]

	# Hysteresis on FIRE intents only — prevents flicker between two
	# close-scoring fire options during pre-aim. CARRY does NOT get a
	# hysteresis bonus: stand-still always ties with the best fire
	# option from the same position by construction (score_at(self) >=
	# score_shoot(self)), and we want fire to win those ties (see
	# tiebreak below). A CARRY hysteresis bonus would push stand-still
	# above fire on every re-eval and the bot would never fire.
	if intended_action == INTENT_SHOOT:
		shoot_score += AIActionScoring.ACTION_HYSTERESIS_MARGIN
	elif intended_action == INTENT_QUICK_SHOT:
		quick_shoot_score += AIActionScoring.ACTION_HYSTERESIS_MARGIN
	elif intended_action == INTENT_PASS:
		best_pass_score += AIActionScoring.ACTION_HYSTERESIS_MARGIN

	# Debug snapshot of the per-tick scores for the floating label.
	# State machine forwards these to its own debug_* fields; AIController
	# polls and refreshes only when content changes.
	debug_shoot_score = shoot_score
	debug_quick_shot_score = quick_shoot_score
	debug_pass_score = best_pass_score
	debug_pass_peer_id = best_pass_peer
	debug_carry_score = carry_score
	debug_carry_pos = last_carry_anchor

	# Pick the better shot type first. Wrister wins ties — the
	# higher-power option is the default. Quick-shot has to beat
	# wrister by ACTION_HYSTERESIS_MARGIN to be chosen, which
	# captures "only snap-shoot when the no-charge release is
	# distinctly better than charging." Margin reuse keeps the
	# behaviour consistent with the other fire-intent stickiness.
	var best_shot_score: float = shoot_score
	var best_shot_intent: int = INTENT_SHOOT
	if quick_shoot_score > shoot_score + AIActionScoring.ACTION_HYSTERESIS_MARGIN:
		best_shot_score = quick_shoot_score
		best_shot_intent = INTENT_QUICK_SHOT

	# Best fire option. No noise-floor threshold against CARRY — a weak
	# fire loses to any stronger carry candidate on its own (and
	# stand-still bounds fire from below at score_at(self) >=
	# score_shoot(self)). The one hard floor is the positive-value gate
	# in the fire-vs-carry compete below: a ZERO fire can't win, so the
	# puck is never given away for nothing.
	var fire_score: float = best_shot_score
	var fire_intent: int = best_shot_intent
	if best_pass_score > fire_score:
		fire_score = best_pass_score
		fire_intent = INTENT_PASS

	# Compete fire vs carry. FIRE WINS TIES — when a fire option scores
	# the same as the best carry candidate (typically stand-still,
	# which equals the best fire option by construction at the same
	# position), we want to fire. The only case where carry should
	# beat fire is when a movement candidate has a STRICTLY better
	# future-action value, which means there's a real reason to keep
	# moving instead of firing now.
	#
	# EXCEPT: fire must have POSITIVE value to win. Firing surrenders the
	# puck (shot up-ice, or a pass); holding/carrying retains it and its
	# optionality. So a zero-value fire must not beat a zero-value hold —
	# otherwise a carrier swarmed deep in its own zone (shoot = 0 out of
	# range, pass = 0 all lanes covered, carry collapsing toward 0) flings
	# a worthless shot away on the 0-0 tie. The threshold is exactly 0,
	# not a tunable: "you need SOME expected value to justify giving up
	# possession." In the offensive zone a real shot scores well above 0
	# and still wins ties, so no behavior change there.
	var new_intent: int
	if fire_score >= carry_score and fire_score > 0.0:
		new_intent = fire_intent
		if new_intent == INTENT_PASS:
			pass_target_peer_id = best_pass_peer
			# Distance-adaptive launch speed: soft for short feeds, harder for
			# long ones so they still arrive at a comfortable pace (capped at
			# this bot's own max wrister). Wrister-charge only when the target
			# is meaningfully above the snap floor; otherwise quick-release.
			var receiver: SkaterNetworkState = ctx.snapshot.skater_states.get(best_pass_peer)
			if receiver != null:
				pass_target_speed = AIActionScoring.pass_launch_speed(
						ctx.self_pos.distance_to(receiver.position), ctx.self_wrister_shot_speed)
			else:
				pass_target_speed = AIActionScoring.PASS_SPEED_M_S
			pass_should_charge = pass_target_speed > AIActionScoring.PASS_SPEED_M_S + PASS_CHARGE_MIN_DELTA_M_S
			# Saucer it over a contested mid-lane defender (only ever true
			# for long passes — see _compute_best_pass).
			pass_should_saucer = best_pass_saucer
		elif new_intent == INTENT_SHOOT:
			shot_is_elevated = _should_elevate_shot(ctx, shoot_score)
	else:
		new_intent = INTENT_CARRY

	intended_action = new_intent


# Populates the scratch lists used by _pick_action's scoring:
# - _scratch_opponents: current opponent positions, for dump scoring.
# - _scratch_opponents_shoot: positions predicted forward by the
#   wrister-charge window, for wrister scoring.
# Pass scoring uses a third per-receiver list (_scratch_opponents_pass)
# rebuilt inside `_compute_best_pass` because the lookahead varies per
# teammate.
func _build_action_opponents_lists(ctx: RoleContext) -> void:
	_scratch_opponents.clear()
	_scratch_opponent_vels.clear()
	_scratch_opponents_shoot.clear()
	_scratch_our_defenders.clear()
	for peer_id: int in ctx.snapshot.skater_states:
		if peer_id == ctx.peer_id:
			continue
		var s: SkaterNetworkState = ctx.snapshot.skater_states[peer_id]
		if ctx.team_id_by_peer.get(peer_id, -1) != ctx.team_id:
			_scratch_opponents.append(s.position)
			_scratch_opponent_vels.append(s.velocity)
			_scratch_opponents_shoot.append(AITrajectory.predict_at(
					s.position, s.velocity, SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S))
		else:
			# Our teammate — a defender for the turnover-cost term.
			_scratch_our_defenders.append(s.position)


# Refills `out_buf` with each opponent's position projected forward
# by `time_s`. Used by carry-candidate scoring (per-candidate arrival
# time) and pass scoring (per-receiver flight time) — same buffer is
# reused, refilled before each scoring call.
func _project_opponents_to(ctx: RoleContext, time_s: float,
		out_buf: Array[Vector3]) -> void:
	out_buf.clear()
	for peer_id: int in ctx.snapshot.skater_states:
		if ctx.team_id_by_peer.get(peer_id, -1) != ctx.team_id and peer_id != ctx.peer_id:
			var s: SkaterNetworkState = ctx.snapshot.skater_states[peer_id]
			out_buf.append(AITrajectory.predict_at(s.position, s.velocity, time_s))


# Loops every legal pass target and returns [best_pid, best_score]. A
# pass takes 0.5–1.1 s of flight time, so the receiver and every
# defender are projected forward by that flight time for the receiver's
# inner score_at (pressure when the puck arrives). The lane-interception
# term uses the reaction-window pass model on CURRENT defender positions
# instead, since lane_clear models defenders closing over the flight.
# Top-level pass scoring under the universal model:
#
#   pass_score(receiver) = score_at(receiver_lead, projected_opps)
#                          × lane_clear(self → receiver_lead, pass_speed)
#                          × pow(decay, pass_flight_time)
#
# score_at recursively considers what the receiver could do (shoot,
# pass to others, carry to slot) — replaces the old receiver_quality
# bundle with a real future-action eval.
#
# Filters:
#   - Skip ghosted teammates (puck passes through them).
#   - Skip receivers predicted past our own goal line (own-goal risk).
#   - Carrier in OZ → receiver must also be in OZ (offside protection).
#   - Skip blade-ROM-unreachable receivers (quick-shot can't fire
#     backward; without this filter the bot would pick a behind-me
#     pass and the blade would clamp to ROM edge — puck dribbles
#     forward into nothing).
#   - Hard zero for net-blocker (segment crosses net body) and
#     own-DZ slot crossing (intercepted = goal-against).
func _compute_best_pass(ctx: RoleContext, self_facing_xz: Vector2,
		teammate_ids: Array[int], goalie_now: Vector3) -> Array:
	var snapshot: WorldSnapshot = ctx.snapshot
	var self_pos: Vector3 = ctx.self_pos
	var own_goal_dir: float = ctx.own_goal_dir
	var best_pass_peer: int = 0
	var best_pass_score: float = 0.0
	# Whether the winning pass should be lofted (saucer) over a contested
	# mid-lane defender. Tracked alongside best_pass_score so it reflects
	# the pass that actually wins, not the last one evaluated.
	var best_pass_saucer: bool = false
	# Our goalie + defenders feed the turnover-cost term: how much an
	# interception would help the opponent, dampened by our coverage.
	var our_goalie: Vector3 = AIRoleHelpers.resolve_our_goalie_pos(ctx)
	var carrier_in_oz: bool = -own_goal_dir * self_pos.z > GameRules.BLUE_LINE_Z
	var own_goal_z: float = own_goal_dir * GameRules.GOAL_LINE_Z
	for peer_id: int in teammate_ids:
		var receiver_state: SkaterNetworkState = snapshot.skater_states[peer_id]
		if receiver_state.is_ghost:
			continue
		if carrier_in_oz:
			var receiver_in_oz: bool = -own_goal_dir * receiver_state.position.z > GameRules.BLUE_LINE_Z
			if not receiver_in_oz:
				continue
		# Match the speed the state machine will actually fire at: the
		# distance-adaptive launch speed (capped at this bot's own max
		# wrister). Threading the actual speed here makes the lead and
		# opponent projections match reality — without it, a 15 m pass
		# scored at 14 m/s overestimates defender presence on the line and
		# leads past the receiver, both of which depress long-pass scores
		# below where they should be.
		var dist: float = self_pos.distance_to(receiver_state.position)
		var pass_speed: float = AIActionScoring.pass_launch_speed(dist, ctx.self_wrister_shot_speed)
		var receiver_accel: Vector3 = ctx.acceleration_by_peer.get(peer_id, Vector3.ZERO)
		# Intercept-aware lead, shared with the state machine's firing aim.
		# flight_t is the SOLVED time (refined against the predicted
		# intercept), used downstream for opponent/goalie projection and
		# the time-decay term.
		var lead: Array = AIPassLead.lead(
				self_pos, receiver_state, receiver_accel, pass_speed, PASS_LEAD_MAX_S)
		var receiver: Vector3 = lead[0]
		var flight_t: float = lead[1]
		if own_goal_dir * receiver.z > GameRules.GOAL_LINE_Z:
			continue
		if AIActionScoring.pass_lane_blocked_by_net(self_pos, receiver):
			continue
		if AIActionScoring.pass_crosses_own_slot(self_pos, receiver, own_goal_z):
			continue
		# Project opponents to flight time for both the puck-lane check
		# and the receiver's inner score_at (lanes/pressure on receiver
		# at the time they receive the puck).
		_project_opponents_to(ctx, flight_t, _scratch_opponents_pass)
		# Lane interception uses the reaction-window PASS model
		# (lane_clear) on CURRENT defender positions, not the geometric
		# carry-path check — a pass is a fired puck, so a defender near
		# the lane reads the release and steps in, scaled by flight time
		# and the actual pass speed. This matches how score_pass (the
		# off-puck roles' view of the same lane) evaluates it, so the
		# carrier and its receivers agree on what's actually threadable.
		var lane: float = AIActionScoring.lane_clear(
				self_pos, receiver, _scratch_opponents, pass_speed,
				_scratch_opponent_vels)
		if lane <= 0.0:
			continue
		# Predict goalie at the time the receiver fires: pass flight time
		# plus their wrister charge. The squareness term in score_shoot
		# rewards passes that catch the goalie sliding cross-seam — this
		# is where most of that benefit lands.
		#
		# One-timer-ready receivers fire on contact (no wrister windup),
		# so the goalie can't slide during a charge. Pass `flight_t`
		# alone for the release time → predicted goalie has only had
		# the pass flight to react, not the additional wrister charge.
		# Catching a still-set goalie via a back-door feed becomes a
		# high-square open-net read.
		var receiver_is_one_timer: bool = (ctx.team_brain != null
				and ctx.team_brain.is_one_timer_ready(peer_id))
		var receiver_release_t: float = flight_t
		if not receiver_is_one_timer:
			receiver_release_t += SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S
		var receiver_goalie: Vector3 = _predict_goalie_at(
				ctx, receiver_release_t, receiver)
		# A cross-seam feed (esp. a one-timer, release = flight_t only) leaves the
		# goalie mid-slide — score the receiver's shot against that unsettled
		# goalie so the play that actually beats it rates higher. Receiver shot
		# speed stays the league default (we don't carry teammates' attributes).
		var receiver_unsettled: float = _goalie_unsettled_at(
				ctx, receiver_release_t, receiver)
		var receiver_value: float = _score_at(ctx, receiver, self_pos,
				_scratch_opponents_pass, receiver_goalie, goalie_now,
				AIActionScoring.WRISTER_SHOT_SPEED_M_S, receiver_unsettled)
		# Rotation time: how long does the bot need to rotate facing to
		# point at the receiver before the blade ROM can fire there?
		# Within blade ROM cone (BOT_BLADE_ROM_HALF_ANGLE_RAD), the bot
		# quick-fires without rotating — rotation_time = 0. Past the
		# cone, only the OVERSHOOT (angle minus ROM) pays rotation cost,
		# so back-passes self-discount but in-cone passes feel snappy.
		var to_receiver_x: float = receiver.x - self_pos.x
		var to_receiver_z: float = receiver.z - self_pos.z
		var to_receiver_len: float = sqrt(to_receiver_x * to_receiver_x + to_receiver_z * to_receiver_z)
		var rotation_time: float = 0.0
		if to_receiver_len > 0.001:
			var inv_len: float = 1.0 / to_receiver_len
			var cos_angle: float = clampf(
					self_facing_xz.x * to_receiver_x * inv_len
					+ self_facing_xz.y * to_receiver_z * inv_len, -1.0, 1.0)
			var angular_distance: float = acos(cos_angle)
			var overshoot: float = maxf(0.0, angular_distance - BOT_BLADE_ROM_HALF_ANGLE_RAD)
			rotation_time = overshoot / BOT_FACING_ROTATION_RATE_RAD_S
		var time_decay: float = pow(
				AIActionScoring.CARRY_DELAY_DISCOUNT_PER_SEC,
				flight_t + rotation_time)
		# Expected-value model. Benefit = P(complete) × value of us
		# having it at the receiver. Cost = P(intercepted) × value the
		# OPPONENT gains from the steal location (turnover_cost). Same
		# threat surface both ways, so the exchange rate is 1 (no aversion
		# knob); the cost self-localizes — ~0 for offensive-zone
		# turnovers, large for own-zone ones. Loss point is the
		# interceptor's spot on the lane.
		var benefit: float = receiver_value * lane * time_decay
		var loss_point: Vector3 = AIActionScoring.lane_loss_point(
				self_pos, receiver, _scratch_opponents, pass_speed,
				_scratch_opponent_vels)
		var cost: float = AIActionScoring.turnover_cost(
				loss_point, 1.0 - lane, ctx.defending_goal_pos, our_goalie,
				GameRules.NET_HALF_WIDTH, _scratch_our_defenders)
		var s: float = benefit - cost
		if s > best_pass_score:
			best_pass_score = s
			best_pass_peer = peer_id
			# Loft this feed only if it's a long pass (saucers are a
			# stretch-pass tool) AND a mid-lane defender is in the way that
			# the saucer flies over. Reuses the current-position opponents
			# the grounded lane was scored against, so the two agree on the
			# geometry.
			best_pass_saucer = (
					dist > AIActionScoring.SAUCER_MIN_DISTANCE_M
					and AIActionScoring.prefers_saucer(
							self_pos, receiver, _scratch_opponents, pass_speed,
							_scratch_opponent_vels))
	return [best_pass_peer, best_pass_score, best_pass_saucer]


# Returns [best_score, best_pos] across all 10 carry candidates:
#   - Stand-still (current position, encodes patience)
#   - 8 polar cardinals at CARRY_SEARCH_STEP_M, oriented so "forward"
#     = direction toward slot
#   - The OZ slot anchor (long-range "drive at slot")
#
# Each candidate scored uniformly:
#   score = score_at(candidate, projected_opps) × path_clear × time_decay
# where time uses momentum-aware effective speed (backward candidates
# self-discount via longer arrival).
func _best_carry(ctx: RoleContext, goalie_now: Vector3) -> Array:
	var self_pos: Vector3 = ctx.self_pos
	var self_velocity: Vector3 = ctx.self_velocity
	var attacking_goal: Vector3 = ctx.attacking_goal_pos
	var own_goal_dir: float = ctx.own_goal_dir
	# Our goalie feeds the turnover-cost term (how much a strip helps the
	# opponent, dampened by our net coverage). Resolved once for all
	# carry candidates. _scratch_our_defenders is already built by
	# _build_action_opponents_lists earlier in _pick_action.
	var our_goalie: Vector3 = AIRoleHelpers.resolve_our_goalie_pos(ctx)
	var slot_pos: Vector3 = _slot_anchor(own_goal_dir)
	# Polar forward direction: toward slot. Fallback to attacking-goal
	# axis when degenerate (bot exactly at slot).
	var to_slot_x: float = slot_pos.x - self_pos.x
	var to_slot_z: float = slot_pos.z - self_pos.z
	var to_slot_len_sq: float = to_slot_x * to_slot_x + to_slot_z * to_slot_z
	var fwd_x: float
	var fwd_z: float
	if to_slot_len_sq < 0.001:
		fwd_x = 0.0
		fwd_z = -own_goal_dir
	else:
		var inv: float = 1.0 / sqrt(to_slot_len_sq)
		fwd_x = to_slot_x * inv
		fwd_z = to_slot_z * inv

	# Score the 8 polar cardinals + slot anchor first; stand-still is
	# scored last and only wins if STRICTLY greater than the best
	# movement candidate. By construction stand-still ties with the
	# best fire option from the same position (score_at(self) is a
	# max that includes shoot/carry-to-slot from self), and the slot
	# anchor's score equals stand-still's carry-to-slot branch when
	# that branch dominates — so stand-still ties with carry candidates
	# almost as often as it ties with fire. Resolving carry ties toward
	# movement keeps the bot from dawdling when slot-drive is the play.
	var best_pos: Vector3 = self_pos
	var best_score: float = -INF

	# 8 polar cardinals at CARRY_SEARCH_STEP_M. Forward = toward slot;
	# rotate by 0°, 45°, ..., 315° to span all directions.
	for angle: float in _POLAR_ANGLES:
		var c: float = cos(angle)
		var s_a: float = sin(angle)
		var dir_x: float = fwd_x * c - fwd_z * s_a
		var dir_z: float = fwd_x * s_a + fwd_z * c
		var candidate := Vector3(
				self_pos.x + dir_x * CARRY_SEARCH_STEP_M, 0.0,
				self_pos.z + dir_z * CARRY_SEARCH_STEP_M)
		if absf(candidate.z) > absf(attacking_goal.z) - AIRoleHelpers.GOAL_LINE_BUFFER_M:
			continue
		if absf(candidate.x) > GameRules.RINK_HALF_WIDTH - AIRoleHelpers.RINK_INSET_M:
			continue
		var local_time: float = AIActionScoring.time_to_arrive(
				self_pos, candidate, self_velocity, ctx.self_max_speed)
		_project_opponents_to(ctx, local_time, _scratch_opponents_path)
		var lane: float = AIActionScoring.path_clearance(
				self_pos, candidate, _scratch_opponents_path)
		if lane <= 0.0:
			continue
		# Predict goalie at candidate-arrival + wrister charge.
		var cand_release_t: float = local_time + SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S
		var cand_goalie: Vector3 = _predict_goalie_at(ctx, cand_release_t, candidate)
		var cand_unsettled: float = _goalie_unsettled_at(ctx, cand_release_t, candidate)
		var dest_score: float = _score_at(ctx, candidate, self_pos,
				_scratch_opponents_path, cand_goalie, goalie_now,
				ctx.self_wrister_shot_speed, cand_unsettled)
		var decay: float = pow(AIActionScoring.CARRY_DELAY_DISCOUNT_PER_SEC, local_time)
		# Omnidirectional poke-safety penalty — score_at uses a forward-
		# cone pressure (right for shooting), but for possession we also
		# discount destinations whose PUCK position has a defender close
		# by from any angle. See AIActionScoring.carry_poke_safety.
		var cand_puck_pos: Vector3 = _puck_pos_at(candidate, attacking_goal)
		var safety: float = AIActionScoring.carry_poke_safety(
				cand_puck_pos, _scratch_opponents_path)
		# Time-synced interception penalty — discount candidates whose
		# path lets a defender converge to poke range during transit.
		# Pairs with carry_poke_safety: that one penalizes the
		# destination, this one penalizes the route to it. Together
		# they bias the bot toward lateral candidates earlier, so the
		# discrete poke-evade cut becomes the finish on an existing
		# curve rather than a sudden veer.
		var intercept: float = AIActionScoring.carry_intercept_safety(
				self_pos, candidate, local_time,
				_scratch_opponents, _scratch_opponents_path)
		# Expected-value: benefit (offensive upside, kept byte-identical
		# to the prior all-multiplicative score) minus the turnover cost.
		# keep_prob = safety × intercept is the possession-protection
		# probability; (1 - keep_prob) is the strip probability, so the
		# loss-probability lives in exactly one place (no double-count
		# with the benefit, which keeps its safety/intercept multipliers
		# as the "value of arriving with the puck" discount). Loss point
		# = the destination puck position — where a converging defender
		# would strip it. Cost self-localizes: ~0 driving into the OZ,
		# large driving into our own slot.
		var benefit: float = dest_score * lane * decay * safety * intercept
		var keep_prob: float = safety * intercept
		var cost: float = AIActionScoring.turnover_cost(
				cand_puck_pos, 1.0 - keep_prob, ctx.defending_goal_pos,
				our_goalie, GameRules.NET_HALF_WIDTH, _scratch_our_defenders)
		var s_total: float = benefit - cost
		if s_total > best_score:
			best_score = s_total
			best_pos = candidate

	# Slot anchor — long-range candidate, valid from anywhere on the
	# rink. NZ bots reach the slot via this; OZ bots near the slot
	# already cover it via local polar candidates.
	var slot_time: float = AIActionScoring.time_to_arrive(
			self_pos, slot_pos, self_velocity, ctx.self_max_speed)
	_project_opponents_to(ctx, slot_time, _scratch_opponents_path)
	var slot_lane: float = AIActionScoring.path_clearance(
			self_pos, slot_pos, _scratch_opponents_path)
	if slot_lane > 0.0:
		var slot_release_t: float = slot_time + SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S
		var slot_dest_goalie: Vector3 = _predict_goalie_at(
				ctx, slot_release_t, slot_pos)
		var slot_unsettled: float = _goalie_unsettled_at(ctx, slot_release_t, slot_pos)
		var slot_dest_score: float = _score_at(ctx, slot_pos, self_pos,
				_scratch_opponents_path, slot_dest_goalie, goalie_now,
				ctx.self_wrister_shot_speed, slot_unsettled)
		var slot_decay: float = pow(
				AIActionScoring.CARRY_DELAY_DISCOUNT_PER_SEC, slot_time)
		var slot_puck_pos: Vector3 = _puck_pos_at(slot_pos, attacking_goal)
		var slot_safety: float = AIActionScoring.carry_poke_safety(
				slot_puck_pos, _scratch_opponents_path)
		var slot_intercept: float = AIActionScoring.carry_intercept_safety(
				self_pos, slot_pos, slot_time,
				_scratch_opponents, _scratch_opponents_path)
		# EV: same benefit − turnover_cost shape as the polar candidates.
		var slot_benefit: float = slot_dest_score * slot_lane * slot_decay * slot_safety * slot_intercept
		var slot_keep_prob: float = slot_safety * slot_intercept
		var slot_cost: float = AIActionScoring.turnover_cost(
				slot_puck_pos, 1.0 - slot_keep_prob, ctx.defending_goal_pos,
				our_goalie, GameRules.NET_HALF_WIDTH, _scratch_our_defenders)
		var slot_total: float = slot_benefit - slot_cost
		if slot_total > best_score:
			best_score = slot_total
			best_pos = slot_pos

	# Stand-still last. Only wins on STRICTLY greater than the best
	# movement candidate — patience must be earned. Score uses
	# current opponents (time = 0 → no projection). Goalie predicted
	# at the wrister window from current position. Poke-safety applied
	# here too: if we're standing still in poke range of a defender,
	# the bot should prefer to skate clear.
	var stand_goalie: Vector3 = _predict_goalie_at(
			ctx, SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S, self_pos)
	var stand_unsettled: float = _goalie_unsettled_at(
			ctx, SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S, self_pos)
	var stand_score: float = _score_at(ctx, self_pos, self_pos,
			_scratch_opponents, stand_goalie, goalie_now,
			ctx.self_wrister_shot_speed, stand_unsettled)
	var stand_puck_pos: Vector3 = _puck_pos_at(self_pos, attacking_goal)
	var stand_safety: float = AIActionScoring.carry_poke_safety(
			stand_puck_pos, _scratch_opponents)
	stand_score *= stand_safety
	if stand_score > best_score:
		best_score = stand_score
		best_pos = self_pos

	return [maxf(best_score, 0.0), best_pos]


# Position-value scorer at `pos`, evaluated from `from_pos`.
#
#   from inside shot range:  score_shoot(pos) only
#   from outside shot range: max(score_shoot(pos), position_potential(pos))
#
# Rationale: once the evaluator is in shooting range it's committed
# to finding a shot — only real shot value counts, so the bot drives
# toward the slot rather than bailing out to a "high potential"
# spot that doesn't actually score goals. Outside the range, the
# bot is positioning, and potential drives the gradient toward
# entering shooting range. The cross-boundary case (from outside,
# to inside) uses max so entry is naturally rewarded.
#
# `opps` should already be projected to the time the actor will be
# at `pos` (caller's responsibility — score_pass does this for
# receivers, _best_carry does it for carry candidates).
# `shot_speed_m_s` is the SHOOTER's charged-shot speed. Carry/stand candidates
# evaluate THIS bot's future shot, so they pass its attribute-scaled speed; the
# receiver eval (score from a teammate's spot) keeps the default since we don't
# carry teammates' attributes — same cross-player boundary as elsewhere.
func _score_at(ctx: RoleContext, pos: Vector3, from_pos: Vector3,
		opps: Array[Vector3],
		predicted_goalie_pos: Vector3, goalie_now: Vector3,
		shot_speed_m_s: float = AIActionScoring.WRISTER_SHOT_SPEED_M_S,
		goalie_unsettled_factor: float = 0.0) -> float:
	var attacking_goal: Vector3 = ctx.attacking_goal_pos
	var shoot_s: float = AIActionScoring.score_shoot(
			pos, attacking_goal, predicted_goalie_pos,
			GameRules.NET_HALF_WIDTH, opps, goalie_now, shot_speed_m_s,
			goalie_unsettled_factor)
	var from_dist: float = from_pos.distance_to(attacking_goal)
	if from_dist <= AIActionScoring.SHOT_RANGE_FALLOFF_M:
		return shoot_s
	var potential_s: float = AIActionScoring.position_potential(
			pos, attacking_goal, opps)
	return maxf(shoot_s, potential_s)


# Approximate puck-rest position when the carrier is at `body_pos`.
# The puck rides ~CARRY_BLADE_AIM_FORWARD_M in front of the body in
# the attacking-goal direction (see SkaterAgentStateMachine._carry_mouse_aim
# — the carry mouse aims at this point and the blade IK puts the puck
# there). Used by poke-safety scoring so the omnidirectional threat
# penalty measures opp-body → our-puck (the real poke geometry), not
# opp-body → our-body. Degenerate case (body_pos == attacking_goal,
# excluded by goal-line buffer in candidate gen) falls back to body
# position to avoid NaN.
func _puck_pos_at(body_pos: Vector3, attacking_goal: Vector3) -> Vector3:
	var to_goal: Vector3 = attacking_goal - body_pos
	to_goal.y = 0.0
	var len_sq: float = to_goal.x * to_goal.x + to_goal.z * to_goal.z
	if len_sq < 0.0001:
		return body_pos
	var inv: float = 1.0 / sqrt(len_sq)
	return body_pos + to_goal * (inv * SkaterAgentStateMachine.CARRY_BLADE_AIM_FORWARD_M)


# OZ slot anchor — recursion terminator and a permanent carry
# candidate. Slot depth from goal line is fixed.
func _slot_anchor(own_goal_dir: float) -> Vector3:
	var slot_z: float = -own_goal_dir * (GameRules.GOAL_LINE_Z - GameRules.SLOT_DIST_M)
	return Vector3(0.0, 0.0, slot_z)


# Returns the opposing goalie's CURRENT world position. Used as input
# to AIActionScoring.predict_goalie_pos. Falls back to the attacking
# goal when goalie state isn't buffered yet (first-frame edge case).
func _goalie_now(ctx: RoleContext) -> Vector3:
	var opp_goalie: GoalieNetworkState = ctx.snapshot.goalie_states.get(1 - ctx.team_id)
	if opp_goalie == null:
		return ctx.attacking_goal_pos
	return Vector3(opp_goalie.position_x, 0.0, opp_goalie.position_z)


# Wraps AIActionScoring.predict_goalie_pos for the common case where
# the puck-at-release is the position we're scoring a shot from.
# `release_time_s` is the time from now until the bot fires (e.g.,
# wrister charge time + any path/flight time before the fire).
func _predict_goalie_at(ctx: RoleContext, release_time_s: float,
		puck_pos_at_release: Vector3) -> Vector3:
	return AIActionScoring.predict_goalie_pos(
			_goalie_now(ctx), ctx.attacking_goal_pos,
			release_time_s, puck_pos_at_release)


# Companion to _predict_goalie_at: how unsettled [0,1] the goalie is at that same
# release, threaded into score_shoot so a shot catching the goalie mid-slide
# (cross-seam one-timer) rates higher than the same shot at a set goalie.
func _goalie_unsettled_at(ctx: RoleContext, release_time_s: float,
		puck_pos_at_release: Vector3) -> float:
	return AIActionScoring.goalie_unsettled(
			_goalie_now(ctx), ctx.attacking_goal_pos,
			release_time_s, puck_pos_at_release)


# Decides whether to elevate the upcoming shot. Reactive: goalie
# already down → top corners exposed. Proactive: close shot with a
# clean lane (high score) → pick the corner over the goalie's
# glove/blocker rather than dribbling along the ice.
func _should_elevate_shot(ctx: RoleContext, shoot_score: float) -> bool:
	var opp_team_id: int = 1 - ctx.team_id
	var opp_goalie: GoalieNetworkState = ctx.snapshot.goalie_states.get(opp_team_id)
	if opp_goalie == null:
		return false
	var s: int = opp_goalie.state_enum
	if s == _GOALIE_STATE_BUTTERFLY \
			or s == _GOALIE_STATE_RECOVERING \
			or s == _GOALIE_STATE_SLIDING \
			or s == _GOALIE_STATE_COILING:
		return true
	var range_to_goal: float = ctx.self_pos.distance_to(ctx.attacking_goal_pos)
	return range_to_goal <= ELEVATE_CLOSE_SHOT_RANGE_M and shoot_score >= ELEVATE_SCORE_GATE
