class_name AIRoleCarrier
extends RefCounted

const _PhysicsConstants: GDScript = preload("res://Scripts/game/constants.gd")

# CARRIER role behavior: the puck-carrying utility AI. Scores SHOOT
# (wrister), PASS (per teammate), and CARRY (8 polar candidates +
# slot anchor + own-half wall exits + stand-still) on equal footing every
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
# The hold-elapsed clock (see _pick_action) advances by the REAL physics ticks
# that elapsed since the previous re-eval (`_ticks_since_pick`), not a fixed
# per-call constant — decide() is called once per AI dispatch, so at lower
# difficulty tiers each call spans several physics ticks and a fixed increment
# would run the hold-decay clock several times too slow.

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

# Zone-exit "wheel" routes — two extra long-range carry candidates up
# each boards lane to just past our own blue line, generated only while
# the carrier is in its own half. The slot anchor is the only other
# long-range candidate and its path runs through center ice — exactly
# where a forecheck sets up — so without these a deep carrier whose
# middle is clogged collapses to myopic 3 m steps and the (risk-priced)
# backpass. Scored by the exact same EV pipeline as every other carry
# candidate, so a wall exit wins precisely when it's genuinely the best
# route out (classic weak-side wheel when the forecheck overplays the
# strong side). Inset matches AIRoleBreakout.WALL_INSET_M so the carry
# lane and the strong-side outlet agree on where "the wall" is; the NZ
# lead puts the destination across the blue line — a completed exit.
const CARRY_EXIT_WALL_INSET_M: float = 2.0
const CARRY_EXIT_NZ_LEAD_M: float = 3.0

# Developing-outlet hold: how far ahead (seconds) a skating
# BREAKOUT_STRONG / OUTLET teammate's route is projected when valuing
# the breakout pass they are CREATING (see _developing_outlet_feed).
# Roughly one strong-side wall sample of travel at skating speed —
# "the spot they're getting open at," not a long-horizon prophecy.
const OUTLET_DEVELOP_WINDOW_S: float = 0.7
# Below this speed the outlet isn't going anywhere — the spot it offers
# is the spot it's at, and the live pass scoring already prices that.
const OUTLET_DEVELOP_MIN_SPEED_M_S: float = 1.0

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

# Seconds we've been HOLDING the puck for a developing cross-seam (see
# _pick_action). Feeds the existing carry decay so a wait that never pays off
# self-extinguishes — the bot takes the available shot — with no fixed timeout.
var _hold_elapsed_s: float = 0.0

# The expected turnover a completing pass AVOIDS by relieving the carrier's
# CURRENT pressure — the pass-out-of-pressure value. Grounded, not a tuned
# weight: it's the same turnover_cost the carry model pays, evaluated at our
# current spot with our live strip probability (1 - puck_safety). A carry that
# dances out of a pincer only DEFERS that danger (the pincer follows, and the
# per-step model can't see the box forming); a completing pass truly resolves
# it, so we credit the pass with the loss avoided. Naturally self-scaling: ~0 in
# open ice (no strip prob) and larger deep in our own end (a giveaway there
# costs more) — every term a perception. Fed to the real-pass EV only;
# developing-feed HOLDs get 0 (under pressure the answer is release, not wait).
var _pass_relief_value: float = 0.0

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
# (LOW-loft) pass would fly over. The state machine consumes this when
# entering PASS_PRESSED to set the loft level for the release.
var pass_should_saucer: bool = false

# Set when intent commits to SHOOT. Consumed by the state machine's
# press-state handlers to drive the loft level (HIGH when true).
var shot_is_elevated: bool = false

# Cached carry destination from the most recent re-eval. Read by the
# state machine to drive steering during CARRY.
var last_carry_anchor: Vector3 = Vector3.ZERO

# ── Throttle ─────────────────────────────────────────────────────────────────
var _pick_action_cooldown: int = 0
# Physics ticks elapsed since the last _pick_action re-eval (accumulated per
# decide() call by ctx.dispatch_period_ticks), so the hold clock advances in
# real time regardless of the AI dispatch cadence. Reset when _pick_action runs.
var _ticks_since_pick: int = 0

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
	# decide() is called once per AI dispatch; each call spans this many physics
	# ticks (1 at the perfect-bot default). Draining the cooldown by the real span
	# keeps the re-eval cadence ~PICK_ACTION_PERIOD_TICKS of wall time at every
	# difficulty tier instead of stretching it by the dispatch period.
	var step_ticks: int = maxi(1, ctx.dispatch_period_ticks)
	_ticks_since_pick += step_ticks
	if _pick_action_cooldown <= 0:
		_pick_action(ctx)  # reads _ticks_since_pick for the hold-clock advance
		_pick_action_cooldown = PICK_ACTION_PERIOD_TICKS
		_ticks_since_pick = 0
	else:
		_pick_action_cooldown -= step_ticks

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
	_hold_elapsed_s = 0.0
	_pick_action_cooldown = 0
	_ticks_since_pick = 0


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
	_ticks_since_pick = 0


# ── Implementation ──────────────────────────────────────────────────────────

# Scores SHOOT (wrister), PASS (per teammate), and CARRY (all
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

	# Our current possession safety, read from the unified puck_safety model:
	# how close a defender's stick gets to the puck at our spot over the next
	# reaction window, given their motion (a closing pincer registers from its
	# velocity) and the body shield. Reused for the hold's keep-probability
	# below, and its complement (strip probability) grounds the pass-relief.
	var cur_puck_pos: Vector3 = _puck_pos_at(self_pos, attacking_goal)
	var cur_forward: Vector3 = attacking_goal - cur_puck_pos
	var current_safety: float = AIActionScoring.puck_safety(
			cur_puck_pos, cur_puck_pos, AIActionScoring.SAFETY_WINDOW_S,
			cur_forward, _scratch_opponents, _scratch_opponent_vels)
	# Pass-out-of-pressure value: the expected turnover a completing pass AVOIDS
	# by relieving this pressure — the SAME turnover_cost the carry model pays,
	# at our current spot with our live strip probability. Grounded, not a
	# weight; ~0 when safe, larger deep in our own end. See _pass_relief_value.
	var our_goalie: Vector3 = AIRoleHelpers.resolve_our_goalie_pos(ctx)
	_pass_relief_value = AIActionScoring.turnover_cost(
			cur_puck_pos, 1.0 - current_safety, ctx.defending_goal_pos,
			our_goalie, GameRules.NET_HALF_WIDTH, _scratch_our_defenders)

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

	# Top-level CARRY — best carry candidate (8 polar around the slot
	# direction + slot anchor + own-half wall exits + stand-still).
	# Each scored uniformly:
	# score_at(candidate, projected_opps) × path_clear × time_decay.
	# Time uses momentum-aware effective speed so reverse candidates
	# self-discount via longer arrival time.
	var carry_result: Array = _best_carry(ctx, goalie_now)
	var carry_score: float = carry_result[0]
	last_carry_anchor = carry_result[1]

	# Hysteresis on FIRE intents only — prevents flicker between two
	# close-scoring fire options during pre-aim. Proportional (×(1 +
	# FRAC), positive scores only — see ACTION_HYSTERESIS_MARGIN_FRAC)
	# so stickiness scales with the score's magnitude instead of
	# swamping the small-score defensive-zone regime. CARRY does NOT
	# get a hysteresis bonus: stand-still always ties with the best
	# fire option from the same position by construction
	# (score_at(self) >= score_shoot(self)), and we want fire to win
	# those ties (see tiebreak below). A CARRY hysteresis bonus would
	# push stand-still above fire on every re-eval and the bot would
	# never fire.
	if intended_action == INTENT_SHOOT and shoot_score > 0.0:
		shoot_score *= 1.0 + AIActionScoring.ACTION_HYSTERESIS_MARGIN_FRAC
	elif intended_action == INTENT_QUICK_SHOT and quick_shoot_score > 0.0:
		quick_shoot_score *= 1.0 + AIActionScoring.ACTION_HYSTERESIS_MARGIN_FRAC
	elif intended_action == INTENT_PASS and best_pass_score > 0.0:
		best_pass_score *= 1.0 + AIActionScoring.ACTION_HYSTERESIS_MARGIN_FRAC

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
	# wrister by the hysteresis fraction to be chosen, which captures
	# "only snap-shoot when the no-charge release is distinctly better
	# than charging." Margin reuse keeps the behaviour consistent with
	# the other fire-intent stickiness.
	var best_shot_score: float = shoot_score
	var best_shot_intent: int = INTENT_SHOOT
	if quick_shoot_score > shoot_score * (1.0 + AIActionScoring.ACTION_HYSTERESIS_MARGIN_FRAC):
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
	#
	# ALSO: don't START a fire while staggered. A body check knocks the
	# bot off-balance (thrust penalty on stagger_timer); winding up a
	# shot/pass through it flails the release. Hold the puck and protect
	# it until the brief stagger decays — carry still computes normally,
	# this only blocks fire from winning the compete.
	var staggered: bool = ctx.self_stagger_timer > 0.0

	# Opportunity cost of firing NOW: the value of keeping the puck for a
	# developing cross-seam one-timer a teammate is staging. Same EV currency as
	# the shot/pass — P(keep the puck) × the feed's value — decayed by how long
	# we've already held, via the SAME carry delay-discount the rest of the model
	# uses. No bonus, no threshold, no fixed timeout: it just competes in the max.
	#   - keep_prob from puck_safety → under pressure the hold is risky and
	#     loses, so the bot acts; in open ice it's ~1 and the hold can win.
	#   - decay(elapsed) → a wait that never materialises self-extinguishes (the
	#     developing value shrinks until the available shot wins).
	# When the teammate flags ready, the developing feed drops to 0 here but the
	# normal pass scoring jumps (one-timer), so PASS wins and feeds it.
	# keep_prob is our current possession safety, computed once at the top of
	# _pick_action (same read that grounds the pass-relief).
	var keep_prob: float = current_safety
	var hold_value: float = (_best_developing_feed(ctx, goalie_now)
			* keep_prob * pow(AIActionScoring.CARRY_DELAY_DISCOUNT_PER_SEC, _hold_elapsed_s))

	var new_intent: int
	# Fire only if it beats BOTH carrying and holding for the developing play.
	if fire_score >= carry_score and fire_score >= hold_value \
			and fire_score > 0.0 and not staggered:
		_hold_elapsed_s = 0.0
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
						ctx.self_pos.distance_to(receiver.position),
						ctx.self_wrister_shot_speed, ctx.pass_speed_scale)
			else:
				pass_target_speed = AIActionScoring.PASS_SPEED_M_S * ctx.pass_speed_scale
			pass_should_charge = pass_target_speed > AIActionScoring.PASS_SPEED_M_S + PASS_CHARGE_MIN_DELTA_M_S
			# Saucer it over a contested mid-lane defender (only ever true
			# for long passes — see _compute_best_pass).
			pass_should_saucer = best_pass_saucer
		elif new_intent == INTENT_SHOOT:
			shot_is_elevated = _should_elevate_shot(ctx, shoot_score)
	else:
		# Not firing. Advance the hold clock only while the developing play is the
		# reason (it out-scores plain carrying); a normal carry resets it so the
		# next genuine hold starts fresh at full value.
		if hold_value > carry_score and hold_value > 0.0:
			_hold_elapsed_s += float(_ticks_since_pick) / float(_PhysicsConstants.PHYSICS_TICK)
		else:
			_hold_elapsed_s = 0.0
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
		var pass_speed: float = AIActionScoring.pass_launch_speed(
				dist, ctx.self_wrister_shot_speed, ctx.pass_speed_scale)
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
		var rotation_time: float = _facing_rotation_time(
				self_facing_xz, self_pos, receiver)
		var s: float = _pass_ev(ctx, receiver, pass_speed, flight_t,
				receiver_release_t, flight_t + rotation_time, goalie_now,
				our_goalie, _pass_relief_value)
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


# Expected value of firing a pass from our current position to
# `receiver_spot`. Shared by the live per-teammate pass scoring
# (_compute_best_pass) and the developing-outlet hold
# (_developing_outlet_feed), so "the pass this wait is creating" and
# "the pass I can fire now" are priced identically — the hold
# self-terminates the instant the real pass matches it (fire wins ties).
#
# Benefit = P(complete) × value of us having it at the receiver, decayed
# by `delay_s` (flight + any facing rotation). P(complete) folds BOTH
# loss modes: lane interception (lane_clear) and residual execution
# miss (AIActionScoring.PASS_MISS_PROB — overled / fumbled reception on
# an otherwise clear lane).
#
# Cost = the value the OPPONENT gains from each loss mode's location:
#   - intercepted in flight → the interceptor's spot on the lane
#     (lane_loss_point), probability 1 − lane.
#   - execution miss → the puck dies past the receiver
#     (pass_miss_loss_point), probability lane × PASS_MISS_PROB.
# Same threat surface both ways, so the exchange rate is 1 (no aversion
# knob) and both costs self-localize — ~0 for offensive-zone losses,
# large for own-zone ones. This is what makes a low-upside backpass deep
# in our own end lose to skating: its benefit barely beats carrying, but
# its miss mode surrenders the ice in front of our net.
#
# Lane interception uses the reaction-window PASS model (lane_clear) on
# CURRENT defender positions, not the geometric carry-path check — a
# pass is a fired puck, so a defender near the lane reads the release
# and steps in, scaled by flight time and the actual pass speed. This
# matches how score_pass (the off-puck roles' view of the same lane)
# evaluates it, so the carrier and its receivers agree on what's
# actually threadable. Opponents are projected to flight time for the
# receiver's inner score_at (lanes/pressure when the puck arrives).
#
# Predicts the goalie at `receiver_release_t` (flight + the receiver's
# wrister charge, or flight alone for one-timer-ready receivers — the
# caller decides). The squareness term in score_shoot rewards passes
# that catch the goalie sliding cross-seam; a cross-seam feed also
# leaves the goalie mid-slide, so the receiver's shot is scored against
# that unsettled goalie. Receiver shot speed stays the league default
# (we don't carry teammates' attributes).
func _pass_ev(ctx: RoleContext, receiver_spot: Vector3, pass_speed: float,
		flight_t: float, receiver_release_t: float, delay_s: float,
		goalie_now: Vector3, our_goalie: Vector3,
		relief_value: float = 0.0) -> float:
	var self_pos: Vector3 = ctx.self_pos
	# Hard zeros: net-blocker (segment crosses a net body) and own-DZ
	# slot crossing (intercepted = goal-against).
	if AIActionScoring.pass_lane_blocked_by_net(self_pos, receiver_spot):
		return 0.0
	if AIActionScoring.pass_crosses_own_slot(
			self_pos, receiver_spot, ctx.own_goal_dir * GameRules.GOAL_LINE_Z):
		return 0.0
	var lane: float = AIActionScoring.lane_clear(
			self_pos, receiver_spot, _scratch_opponents, pass_speed,
			_scratch_opponent_vels)
	if lane <= 0.0:
		return 0.0
	_project_opponents_to(ctx, flight_t, _scratch_opponents_pass)
	var receiver_goalie: Vector3 = _predict_goalie_at(
			ctx, receiver_release_t, receiver_spot)
	var receiver_unsettled: float = _goalie_unsettled_at(
			ctx, receiver_release_t, receiver_spot)
	var receiver_value: float = _score_at(ctx, receiver_spot, self_pos,
			_scratch_opponents_pass, receiver_goalie, goalie_now,
			AIActionScoring.WRISTER_SHOT_SPEED_M_S, receiver_unsettled)
	var time_decay: float = pow(
			AIActionScoring.CARRY_DELAY_DISCOUNT_PER_SEC, delay_s)
	var completion: float = lane * (1.0 - AIActionScoring.PASS_MISS_PROB)
	var benefit: float = receiver_value * completion * time_decay
	# Pass-out-of-pressure relief: a COMPLETING pass off a pressured carrier is
	# worth the expected turnover it AVOIDS — the escape from a strip the carry
	# only defers. relief_value is that expected loss (strip prob × turnover
	# cost at our spot), already in EV currency; gated by completion so an
	# uncompleteable "escape" earns nothing, and 0 when the caller doesn't pass
	# it (developing-feed holds). See _pass_relief_value.
	benefit += relief_value * completion
	var loss_point: Vector3 = AIActionScoring.lane_loss_point(
			self_pos, receiver_spot, _scratch_opponents, pass_speed,
			_scratch_opponent_vels)
	var cost: float = AIActionScoring.turnover_cost(
			loss_point, 1.0 - lane, ctx.defending_goal_pos, our_goalie,
			GameRules.NET_HALF_WIDTH, _scratch_our_defenders)
	cost += AIActionScoring.turnover_cost(
			AIActionScoring.pass_miss_loss_point(self_pos, receiver_spot),
			lane * AIActionScoring.PASS_MISS_PROB, ctx.defending_goal_pos,
			our_goalie, GameRules.NET_HALF_WIDTH, _scratch_our_defenders)
	return benefit - cost


# Rotation time: how long the bot needs to rotate facing to point at
# `target` before the blade ROM can fire there. Within the blade ROM
# cone (BOT_BLADE_ROM_HALF_ANGLE_RAD) the bot quick-fires without
# rotating — rotation_time = 0. Past the cone, only the OVERSHOOT
# (angle minus ROM) pays rotation cost, so back-passes self-discount
# but in-cone passes feel snappy.
func _facing_rotation_time(self_facing_xz: Vector2, self_pos: Vector3,
		target: Vector3) -> float:
	var to_target_x: float = target.x - self_pos.x
	var to_target_z: float = target.z - self_pos.z
	var to_target_len: float = sqrt(
			to_target_x * to_target_x + to_target_z * to_target_z)
	if to_target_len <= 0.001:
		return 0.0
	var inv_len: float = 1.0 / to_target_len
	var cos_angle: float = clampf(
			self_facing_xz.x * to_target_x * inv_len
			+ self_facing_xz.y * to_target_z * inv_len, -1.0, 1.0)
	var angular_distance: float = acos(cos_angle)
	var overshoot: float = maxf(0.0, angular_distance - BOT_BLADE_ROM_HALF_ANGLE_RAD)
	return overshoot / BOT_FACING_ROTATION_RATE_RAD_S


# Returns [best_score, best_pos] across all carry candidates:
#   - Stand-still (current position, encodes patience)
#   - 8 polar cardinals at CARRY_SEARCH_STEP_M, oriented so "forward"
#     = direction toward slot
#   - The OZ slot anchor (long-range "drive at slot")
#   - Two zone-exit wall routes when in our own half (see CARRY_EXIT_*)
#
# Each movement candidate scored uniformly via _score_move_candidate;
# time uses momentum-aware effective speed (backward candidates
# self-discount via longer arrival).
func _best_carry(ctx: RoleContext, goalie_now: Vector3) -> Array:
	var self_pos: Vector3 = ctx.self_pos
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
		var s_total: float = _score_move_candidate(ctx, candidate, goalie_now, our_goalie)
		if s_total > best_score:
			best_score = s_total
			best_pos = candidate

	# Slot anchor — long-range candidate, valid from anywhere on the
	# rink. NZ bots reach the slot via this; OZ bots near the slot
	# already cover it via local polar candidates.
	var slot_total: float = _score_move_candidate(ctx, slot_pos, goalie_now, our_goalie)
	if slot_total > best_score:
		best_score = slot_total
		best_pos = slot_pos

	# Zone-exit wall routes — see CARRY_EXIT_* doc. Only generated in
	# our own half: an exit route is meaningless once the puck is
	# across center, and down there the slot anchor + local candidates
	# already cover the up-ice gradient.
	if own_goal_dir * self_pos.z > 0.0:
		var exit_x: float = GameRules.RINK_HALF_WIDTH - CARRY_EXIT_WALL_INSET_M
		var exit_z: float = own_goal_dir * (GameRules.BLUE_LINE_Z - CARRY_EXIT_NZ_LEAD_M)
		var exit_right := Vector3(exit_x, 0.0, exit_z)
		var exit_right_total: float = _score_move_candidate(
				ctx, exit_right, goalie_now, our_goalie)
		if exit_right_total > best_score:
			best_score = exit_right_total
			best_pos = exit_right
		var exit_left := Vector3(-exit_x, 0.0, exit_z)
		var exit_left_total: float = _score_move_candidate(
				ctx, exit_left, goalie_now, our_goalie)
		if exit_left_total > best_score:
			best_score = exit_left_total
			best_pos = exit_left

	# Stand-still last. Only wins on STRICTLY greater than the best
	# movement candidate — patience must be earned. Score uses
	# current opponents (time = 0 → no projection). Goalie predicted
	# at the wrister window from current position. Same EV shape as the
	# movement candidates: poke-safety discounts the benefit AND its
	# complement is the strip probability feeding turnover_cost.
	# Without the cost term stand-still was the only candidate that
	# didn't price losing the puck, so under a converging forechecker
	# every escape route went EV-negative while freezing stayed
	# positive — the bot planted itself at exactly the moment it
	# should skate clear. Safety is the static puck_safety read (a closing
	# defender still registers from its velocity over the reaction window).
	var stand_goalie: Vector3 = _predict_goalie_at(
			ctx, SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S, self_pos)
	var stand_unsettled: float = _goalie_unsettled_at(
			ctx, SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S, self_pos)
	var stand_score: float = _score_at(ctx, self_pos, self_pos,
			_scratch_opponents, stand_goalie, goalie_now,
			ctx.self_wrister_shot_speed, stand_unsettled)
	var stand_puck_pos: Vector3 = _puck_pos_at(self_pos, attacking_goal)
	var stand_safety: float = AIActionScoring.puck_safety(
			stand_puck_pos, stand_puck_pos, AIActionScoring.SAFETY_WINDOW_S,
			attacking_goal - stand_puck_pos,
			_scratch_opponents, _scratch_opponent_vels)
	var stand_cost: float = AIActionScoring.turnover_cost(
			stand_puck_pos, 1.0 - stand_safety, ctx.defending_goal_pos,
			our_goalie, GameRules.NET_HALF_WIDTH, _scratch_our_defenders)
	var stand_total: float = stand_score * stand_safety - stand_cost
	if stand_total > best_score:
		best_score = stand_total
		best_pos = self_pos

	return [maxf(best_score, 0.0), best_pos]


# EV of one movement carry candidate — the uniform scoring every
# non-stand-still candidate (polar step, slot anchor, wall exit) runs:
#
#   benefit − turnover_cost, where
#   benefit = score_at(candidate, projected_opps) × path_clear
#             × time_decay × safety
#
# Time uses momentum-aware effective speed, so reverse candidates
# self-discount via longer arrival. Returns -INF when the path is
# fully blocked (candidate unusable, matching the old skip).
#
# `safety` is the unified puck_safety over the PUCK's path from our current
# spot to the candidate spot across the arrival time: one closest-approach
# that captures both a defender converging on the ROUTE and one waiting at the
# DESTINATION, velocity-aware and body-shielded. (This replaces the old
# separate poke-at-destination × intercept-along-route product — same idea,
# one honest model.)
#
# Expected-value shape: benefit (offensive upside) minus the turnover cost.
# keep_prob = safety is the possession-protection probability; (1 - keep_prob)
# is the strip probability, so the loss-probability lives in exactly one place
# (no double-count with the benefit, whose safety multiplier is the "value of
# arriving with the puck" discount). Loss point = the destination puck position
# — where a converging defender would strip it. Cost self-localizes: ~0 driving
# into the OZ, large driving into our own slot.
func _score_move_candidate(ctx: RoleContext, candidate: Vector3,
		goalie_now: Vector3, our_goalie: Vector3) -> float:
	var self_pos: Vector3 = ctx.self_pos
	var local_time: float = AIActionScoring.time_to_arrive(
			self_pos, candidate, ctx.self_velocity, ctx.self_max_speed)
	_project_opponents_to(ctx, local_time, _scratch_opponents_path)
	var lane: float = AIActionScoring.path_clearance(
			self_pos, candidate, _scratch_opponents_path)
	if lane <= 0.0:
		return -INF
	# Predict goalie at candidate-arrival + wrister charge.
	var cand_release_t: float = local_time + SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S
	var cand_goalie: Vector3 = _predict_goalie_at(ctx, cand_release_t, candidate)
	var cand_unsettled: float = _goalie_unsettled_at(ctx, cand_release_t, candidate)
	var dest_score: float = _score_at(ctx, candidate, self_pos,
			_scratch_opponents_path, cand_goalie, goalie_now,
			ctx.self_wrister_shot_speed, cand_unsettled)
	var decay: float = pow(AIActionScoring.CARRY_DELAY_DISCOUNT_PER_SEC, local_time)
	var cand_puck_pos: Vector3 = _puck_pos_at(candidate, ctx.attacking_goal_pos)
	var cur_puck_pos: Vector3 = _puck_pos_at(self_pos, ctx.attacking_goal_pos)
	var safety: float = AIActionScoring.puck_safety(
			cur_puck_pos, cand_puck_pos, local_time,
			ctx.attacking_goal_pos - cand_puck_pos,
			_scratch_opponents, _scratch_opponent_vels)
	var benefit: float = dest_score * lane * decay * safety
	var keep_prob: float = safety
	var cost: float = AIActionScoring.turnover_cost(
			cand_puck_pos, 1.0 - keep_prob, ctx.defending_goal_pos,
			our_goalie, GameRules.NET_HALF_WIDTH, _scratch_our_defenders)
	return benefit - cost


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
# The potential branch pays the realization discount (see
# AIActionScoring.potential_realization_discount): potential is future
# value that still has to be skated to the slot, so it decays over that
# remaining travel exactly like every other future action. This is what
# stops stand-still (whose potential used to be undecayed) from
# strictly beating a step toward the net in open ice — the blue-line
# freeze. Applied uniformly here so carry candidates, stand-still, and
# pass receivers all price potential in the same currency.
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
	var realization: float = AIActionScoring.potential_realization_discount(
			pos, attacking_goal)
	return maxf(shoot_s, potential_s * realization)


# Value (EV) of the best DEVELOPING feed — a play a teammate is still
# creating, worth keeping the puck for. Two kinds, both self-gating
# (a teammate whose developing spot scores a poor feed gives no reason
# to hold):
#
#   - Cross-seam ONE-TIMER (FINISHER slot): a FINISHER-slotted teammate
#     in the OZ, not yet one-timer-ready, settling into its spot. We
#     score the feed to where they ARE now as a one-timer (release =
#     pass flight only, with goalie-motion): the value the feed gets
#     the instant they flag ready. Until then the normal pass scoring
#     rates them mid-windup (goalie re-squares) and under-values the
#     play; this is the reason to keep the puck and wait.
#
#   - Breakout OUTLET (BREAKOUT_STRONG / OUTLET slots): an outlet
#     skating its route toward open ice — see _developing_outlet_feed.
#     This is the reason a pressured own-zone carrier protects the puck
#     and skates instead of forcing a low-value backpass: the pass the
#     outlet is CREATING out-values everything available right now.
#
# Returns 0 if nothing is developing.
func _best_developing_feed(ctx: RoleContext, goalie_now: Vector3) -> float:
	if ctx.team_brain == null:
		return 0.0
	var self_pos: Vector3 = ctx.self_pos
	var our_goalie: Vector3 = AIRoleHelpers.resolve_our_goalie_pos(ctx)
	var self_state: SkaterNetworkState = ctx.snapshot.skater_states.get(ctx.peer_id)
	var self_facing: Vector2 = self_state.facing if self_state != null else Vector2.ZERO
	var best: float = 0.0
	for pid: int in _scratch_teammate_ids:
		var slot: int = ctx.team_brain.get_slot(pid)
		var tm: SkaterNetworkState = ctx.snapshot.skater_states.get(pid)
		if tm == null:
			continue
		var feed: float = 0.0
		if slot == AIRoleSlots.Slot.FINISHER:
			# Ghosted (offside) finisher can't receive — the live pass
			# scoring skips ghosts, so holding for one would be waiting
			# for a feed we're never allowed to make. Already-flagged —
			# the normal pass scoring feeds it; nothing to wait for. Must
			# be staging an OZ cross-seam (slot_anchor returns ZERO for
			# FINISHER, so we read the teammate's live position, not a
			# brain anchor).
			var spot: Vector3 = tm.position
			if tm.is_ghost or ctx.team_brain.is_one_timer_ready(pid) \
					or -ctx.own_goal_dir * spot.z <= GameRules.BLUE_LINE_Z:
				continue
			var dist: float = self_pos.distance_to(spot)
			var pass_speed: float = AIActionScoring.pass_launch_speed(
					dist, ctx.self_wrister_shot_speed, ctx.pass_speed_scale)
			var flight_t: float = clampf(dist / pass_speed, 0.0, PASS_LEAD_MAX_S)
			var feed_goalie: Vector3 = _predict_goalie_at(ctx, flight_t, spot)
			var feed_unsettled: float = _goalie_unsettled_at(ctx, flight_t, spot)
			_project_opponents_to(ctx, flight_t, _scratch_opponents_pass)
			feed = AIActionScoring.score_pass(
					self_pos, spot, ctx.attacking_goal_pos, feed_goalie,
					GameRules.NET_HALF_WIDTH, _scratch_opponents_pass,
					goalie_now, pass_speed, feed_unsettled)
		elif slot == AIRoleSlots.Slot.BREAKOUT_STRONG \
				or slot == AIRoleSlots.Slot.OUTLET:
			feed = _developing_outlet_feed(ctx, tm, goalie_now, our_goalie, self_facing)
		if feed > best:
			best = feed
	return best


# EV of the breakout feed a skating outlet is CREATING. The outlet's
# position is projected OUTLET_DEVELOP_WINDOW_S along its velocity —
# the spot it's getting open at — and the pass to that spot is priced
# through the SAME _pass_ev as the live pass scoring. That parity is
# the termination guarantee: as the outlet arrives, the live pass
# converges to this developing value, fire wins the tie, and the puck
# goes — the hold can't outlive the play it's waiting for (and the
# _hold_elapsed_s decay in _pick_action erodes a wait that never
# materialises).
#
# BREAKOUT_WEAK is deliberately excluded: the weak-side reverse valve
# stays goal-side of the carrier by role contract, so "waiting for it
# to develop" would mean holding for a backpass — the exact play this
# hold exists to avoid forcing. The valve is an escape hatch the live
# pass scoring prices on its own.
func _developing_outlet_feed(ctx: RoleContext, tm: SkaterNetworkState,
		goalie_now: Vector3, our_goalie: Vector3, self_facing_xz: Vector2) -> float:
	if tm.is_ghost:
		return 0.0
	var vel: Vector3 = tm.velocity
	if vel.x * vel.x + vel.z * vel.z \
			< OUTLET_DEVELOP_MIN_SPEED_M_S * OUTLET_DEVELOP_MIN_SPEED_M_S:
		return 0.0
	var spot := Vector3(
			tm.position.x + vel.x * OUTLET_DEVELOP_WINDOW_S, 0.0,
			tm.position.z + vel.z * OUTLET_DEVELOP_WINDOW_S)
	if not AIRoleHelpers.is_legal_position(spot):
		return 0.0
	var dist: float = ctx.self_pos.distance_to(spot)
	var pass_speed: float = AIActionScoring.pass_launch_speed(
			dist, ctx.self_wrister_shot_speed, ctx.pass_speed_scale)
	var flight_t: float = clampf(dist / pass_speed, 0.0, PASS_LEAD_MAX_S)
	# Breakout receivers carry on reception (no one-timer), so the goalie
	# gets flight + their wrister charge before any shot — same release
	# model the live pass scoring applies to a non-ready receiver.
	var release_t: float = flight_t + SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S
	var rotation_time: float = _facing_rotation_time(self_facing_xz, ctx.self_pos, spot)
	return _pass_ev(ctx, spot, pass_speed, flight_t, release_t,
			flight_t + rotation_time, goalie_now, our_goalie)


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
