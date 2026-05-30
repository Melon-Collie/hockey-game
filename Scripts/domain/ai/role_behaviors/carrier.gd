class_name AIRoleCarrier
extends RefCounted

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
# Re-evaluation cadence. CARRY runs at 240 Hz; without throttling the
# scoring (10 carry candidates × per-teammate pass × opponent
# projections) would fire 240×/sec/bot. ~30 Hz is plenty — pre-aim
# convergence gates the actual transition, and humans react in 250 ms+.
const PICK_ACTION_PERIOD_TICKS: int = 8

# Pass flight clamp. A 0.6 s lead lets the bot pass to a teammate up
# to ~16 m away (PASS_SPEED_M_S × 0.6); longer leads suffer from
# stale opponent projections.
const PASS_LEAD_MAX_S: float = 0.6

# UX nudge: bots prefer feeding humans on close-call passes. Capped
# at 1.0 inside the loop so bias can't push a borderline pass above
# a clearly-better one.
const HUMAN_PASS_BIAS: float = 1.25

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
var _scratch_opponents_shoot: Array[Vector3] = []
var _scratch_opponents_pass: Array[Vector3] = []
var _scratch_opponents_path: Array[Vector3] = []
var _scratch_teammate_ids: Array[int] = []

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
			GameRules.NET_HALF_WIDTH, _scratch_opponents_shoot, goalie_now)

	# Top-level QUICK_SHOT — snap release at PASS_SPEED, no charge. The
	# goalie can't slide during a zero-charge release, so a still-squared
	# goalie that would otherwise drift wide stays in position. Off-axis
	# bots benefit (their lateral arc against a still-squared goalie is
	# open); slower puck speed naturally kills long-range attempts via
	# the existing _lane_clear math. Release position = current self_pos
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

	# Best fire option. No noise-floor threshold — CARRY competes
	# directly, so a weak fire naturally loses to any stronger carry
	# candidate (and stand-still in particular bounds fire from below
	# at score_at(self) >= score_shoot(self)).
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
	var new_intent: int
	if fire_score >= carry_score:
		new_intent = fire_intent
		if new_intent == INTENT_PASS:
			pass_target_peer_id = best_pass_peer
			# Wrister-charge for long passes — more pace, smaller defender
			# reaction window. Snap-pass for short feeds where the windup
			# commit isn't worth it.
			var receiver: SkaterNetworkState = ctx.snapshot.skater_states.get(best_pass_peer)
			pass_should_charge = (receiver != null
					and ctx.self_pos.distance_to(receiver.position) > AIActionScoring.LONG_PASS_DISTANCE_THRESHOLD_M)
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
	_scratch_opponents_shoot.clear()
	for peer_id: int in ctx.snapshot.skater_states:
		if ctx.team_id_by_peer.get(peer_id, -1) != ctx.team_id and peer_id != ctx.peer_id:
			var s: SkaterNetworkState = ctx.snapshot.skater_states[peer_id]
			_scratch_opponents.append(s.position)
			_scratch_opponents_shoot.append(AITrajectory.predict_at(
					s.position, s.velocity, SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S))


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
# defender are projected forward by that flight time before scoring.
# Top-level pass scoring under the universal model:
#
#   pass_score(receiver) = score_at(receiver_lead, projected_opps)
#                          × path_clearance(self → receiver_lead)
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
#
# HUMAN_PASS_BIAS is a UX nudge — bots prefer feeding humans on
# close-call passes.
func _compute_best_pass(ctx: RoleContext, self_facing_xz: Vector2,
		teammate_ids: Array[int], goalie_now: Vector3) -> Array:
	var snapshot: WorldSnapshot = ctx.snapshot
	var self_pos: Vector3 = ctx.self_pos
	var own_goal_dir: float = ctx.own_goal_dir
	var best_pass_peer: int = 0
	var best_pass_score: float = 0.0
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
		# Match the speed the state machine will actually fire at: long
		# passes get the charged-wrister speed, short passes the quick-
		# shot speed (see PASS_PRESSED branch on _pass_should_charge).
		# Threading the actual speed here makes the lead and opponent
		# projections match reality — without it, a 15 m pass scored
		# at 14 m/s overestimates defender presence on the line and
		# leads past the receiver, both of which depress long-pass
		# scores below where they should be.
		var dist: float = self_pos.distance_to(receiver_state.position)
		var pass_speed: float = (AIActionScoring.PASS_CHARGE_SPEED_M_S
				if dist > AIActionScoring.LONG_PASS_DISTANCE_THRESHOLD_M
				else AIActionScoring.PASS_SPEED_M_S)
		var flight_t: float = clampf(
				dist / pass_speed, 0.0, PASS_LEAD_MAX_S)
		var receiver_accel: Vector3 = ctx.acceleration_by_peer.get(peer_id, Vector3.ZERO)
		var receiver: Vector3 = _predict_receiver(receiver_state, flight_t, receiver_accel)
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
		var lane: float = AIActionScoring.path_clearance(
				self_pos, receiver, _scratch_opponents_pass)
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
		var receiver_value: float = _score_at(ctx, receiver, self_pos,
				_scratch_opponents_pass, receiver_goalie, goalie_now)
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
		# Turnover-risk discount: a contested pass out of our own half
		# is high-cost if picked off (breakout giveaway → chance against).
		# Clean lanes and offensive-half passes are unaffected; only
		# hopeful, contested own-half passes get knocked down so the bot
		# favours the safe outlet over forcing a seam.
		var turnover_safety: float = AIActionScoring.breakout_pass_safety(
				self_pos, receiver, own_goal_z, lane)
		var s: float = receiver_value * lane * time_decay * turnover_safety
		if NetworkManager.is_real_peer(peer_id):
			s = minf(s * HUMAN_PASS_BIAS, 1.0)
		if s > best_pass_score:
			best_pass_score = s
			best_pass_peer = peer_id
	return [best_pass_peer, best_pass_score]


# Receiver position prediction — velocity + acceleration
# extrapolation of the blade contact (in world space). Accel
# comes from the agent state machine's per-peer velocity-diff
# cache (RoleContext.acceleration_by_peer); callers without that
# context get a constant-velocity lead (accel defaults to ZERO).
#
# IMPORTANT: `receiver.blade_position` is in upper-body-LOCAL space —
# subtracting `receiver.position` (world) was nonsense and produced
# offsets up to 25 m, leading to passes fired at empty ice. Use
# `blade_contact_world` (host-only field, populated by
# SkaterController.get_network_state) which is the blade in world
# coordinates already.
func _predict_receiver(receiver: SkaterNetworkState, flight_t: float,
		accel: Vector3 = Vector3.ZERO) -> Vector3:
	# Predict the blade position forward by flight_t along body
	# velocity + acceleration (assumes blade moves with body — fine
	# over a 0.6 s pass window). The accel term lands a receiver
	# who's mid-turn or accelerating from rest ~0.5·|a|·t² closer to
	# where they actually arrive vs. a pure-velocity lead.
	var blade_world: Vector3 = receiver.blade_contact_world
	# Defensive fallback: if blade_contact_world isn't populated
	# (zero — shouldn't happen on host but guard anyway), fall back
	# to body position. Aim at body center is worse than aim at
	# blade, but vastly better than aim at center ice.
	if blade_world == Vector3.ZERO:
		blade_world = receiver.position
	return AITrajectory.predict_at(
			blade_world, receiver.velocity, flight_t, 6, accel)


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
		var local_time: float = AIActionScoring.time_to_arrive(self_pos, candidate, self_velocity)
		_project_opponents_to(ctx, local_time, _scratch_opponents_path)
		var lane: float = AIActionScoring.path_clearance(
				self_pos, candidate, _scratch_opponents_path)
		if lane <= 0.0:
			continue
		# Predict goalie at candidate-arrival + wrister charge.
		var cand_release_t: float = local_time + SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S
		var cand_goalie: Vector3 = _predict_goalie_at(ctx, cand_release_t, candidate)
		var dest_score: float = _score_at(ctx, candidate, self_pos,
				_scratch_opponents_path, cand_goalie, goalie_now)
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
		var s_total: float = dest_score * lane * decay * safety * intercept
		if s_total > best_score:
			best_score = s_total
			best_pos = candidate

	# Slot anchor — long-range candidate, valid from anywhere on the
	# rink. NZ bots reach the slot via this; OZ bots near the slot
	# already cover it via local polar candidates.
	var slot_time: float = AIActionScoring.time_to_arrive(self_pos, slot_pos, self_velocity)
	_project_opponents_to(ctx, slot_time, _scratch_opponents_path)
	var slot_lane: float = AIActionScoring.path_clearance(
			self_pos, slot_pos, _scratch_opponents_path)
	if slot_lane > 0.0:
		var slot_release_t: float = slot_time + SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S
		var slot_dest_goalie: Vector3 = _predict_goalie_at(
				ctx, slot_release_t, slot_pos)
		var slot_dest_score: float = _score_at(ctx, slot_pos, self_pos,
				_scratch_opponents_path, slot_dest_goalie, goalie_now)
		var slot_decay: float = pow(
				AIActionScoring.CARRY_DELAY_DISCOUNT_PER_SEC, slot_time)
		var slot_puck_pos: Vector3 = _puck_pos_at(slot_pos, attacking_goal)
		var slot_safety: float = AIActionScoring.carry_poke_safety(
				slot_puck_pos, _scratch_opponents_path)
		var slot_intercept: float = AIActionScoring.carry_intercept_safety(
				self_pos, slot_pos, slot_time,
				_scratch_opponents, _scratch_opponents_path)
		var slot_total: float = slot_dest_score * slot_lane * slot_decay * slot_safety * slot_intercept
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
	var stand_score: float = _score_at(ctx, self_pos, self_pos,
			_scratch_opponents, stand_goalie, goalie_now)
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
func _score_at(ctx: RoleContext, pos: Vector3, from_pos: Vector3,
		opps: Array[Vector3],
		predicted_goalie_pos: Vector3, goalie_now: Vector3) -> float:
	var attacking_goal: Vector3 = ctx.attacking_goal_pos
	var shoot_s: float = AIActionScoring.score_shoot(
			pos, attacking_goal, predicted_goalie_pos,
			GameRules.NET_HALF_WIDTH, opps, goalie_now)
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
			or s == _GOALIE_STATE_SLIDING:
		return true
	var range_to_goal: float = ctx.self_pos.distance_to(ctx.attacking_goal_pos)
	return range_to_goal <= ELEVATE_CLOSE_SHOT_RANGE_M and shoot_score >= ELEVATE_SCORE_GATE
