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
#   - shot_loft_level
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
# Last-resort DUMP — fire the puck to a location (no receiver). The state machine
# maps it onto a PASS_PRESSED release aimed at `dump_target`.
const INTENT_DUMP: int = 5

# Least fire value (shot/pass EV) worth giving up possession for — the noise floor
# below which "firing" is really a giveaway, so the bot keeps the puck instead.
# A tactical floor, not an evaluation curve: it exists because the geometric shot
# model has no range cliff (a hopeless long shot leaves a tiny residual rather
# than exactly 0). A real in-range shot scores far above it.
const FIRE_MIN_VALUE: float = 0.02

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

# Receiver drive-in credit (see _receiver_drive_in_value): the MAX distance an open
# pass receiver is credited with carrying toward the net (the actual reach is the
# clear extent of that path — a defender strips it early), and the closest to the net
# that drive is allowed to end (don't credit a drive into the crease / the goalie).
# The max is a horizon cap — long enough to carry a NZ/DZ outlet with a clear lane
# into the zone — kept finite because opponent projections go stale over a long carry.
# Feel tunables ("how far a wide-open man is trusted to skate it"), not an evaluation
# curve; the value at the reached spot is still the goalie-aware / potential read.
const RECEIVER_DRIVE_MAX_M: float = 12.0
const RECEIVER_DRIVE_MIN_NET_DIST_M: float = 3.0

# Forward-pressure discount on the CARRY (see _carrier_forward_clearance). The model
# prices the IMMEDIATE strip (a defender right on the puck) but not the IMPENDING
# contest — a defender sitting in the carrier's path to the objective it will have to
# beat to advance. So a lightly-pressured carrier reads its own (sidestep) carry as
# clean and grinds forward instead of moving the puck to an unimpeded teammate. This
# discounts the carry by how contested the path AHEAD is, so an impeded carrier
# prefers a clean outlet even at the cost of some real estate — the pass-first read.
# HORIZON is how far ahead the contest is felt; MIN_SCALE is the most a fully-blocked
# path discounts the carry (never to zero — a pressured carrier with no outlet still
# carries). Feel tunables (how pass-first / risk-averse), not an evaluation curve —
# the clearance itself is the grounded reachable-set read. Applied ONLY to the
# fire-vs-carry compete, never to the honest raw carry the dump is judged against.
const FORWARD_PRESSURE_HORIZON_M: float = 9.0
const FORWARD_PRESSURE_MIN_SCALE: float = 0.55

# (Blade reach cone + facing turn rate now come from the bot's real caps —
# RoleContext.self_reach_cone_half_angle / self_facing_turn_rate — so an aim
# anywhere inside the true ±157° reach cone fires with no body turn, and only the
# narrow back wedge pays, at the bot's Agility-scaled turn rate. See
# _facing_rotation_time.)

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

# Set when intent commits to PASS. Consumed by the state machine
# when transitioning into PASS_PRESSED. -1 = no current pass target.
var pass_target_peer_id: int = -1

# Set alongside pass_target_peer_id when the chosen PASS is far enough
# that the carrier wrister-charges instead of quick-releasing. The
# state machine consumes this when entering PASS_PRESSED to branch
# between one-tick fire and ~250 ms wrister charge.
var pass_should_charge: bool = false

# LAUNCH speed for the chosen PASS (AIActionScoring.pass_launch_speed): set so
# the puck arrives on the teammate's tape at the magnet pace, friction-compensated
# by distance. The state machine maps this to the wrister charge fraction it winds
# up to, and leads the pass at this speed.
var pass_target_speed: float = AIActionScoring.PASS_SPEED_M_S

# Set alongside pass_target_peer_id when the chosen PASS is a long
# feed whose lane is contested by a mid-lane defender that a saucer
# (LOW-loft) pass would fly over. The state machine consumes this when
# entering PASS_PRESSED to set the loft level for the release.
var pass_should_saucer: bool = false

# Set when intent commits to SHOOT: the loft (ShotMechanics.ELEVATION_*) of the
# best goalie hole the shot is aimed at — top corner → HIGH, armpit → LOW,
# bottom corner / five-hole → FLAT (see AIActionScoring.best_shot_loft).
# Consumed by the state machine's press-state handlers to drive the release loft.
var shot_loft_level: int = ShotMechanics.ELEVATION_FLAT

# Set alongside shot_loft_level: the world aim POINT of that same best hole (on
# the net plane), so the state machine aims the wrister exactly at the hole the
# loft was chosen for. INF until a SHOOT commit picks one.
var shot_aim_point: Vector3 = Vector3.INF

# Cached carry destination from the most recent re-eval. Read by the
# state machine to drive steering during CARRY.
var last_carry_anchor: Vector3 = Vector3.ZERO

# Set when intent commits to DUMP: the world spot to fire the puck at (no
# receiver), and whether it's a soft flip (dump-and-chase into the OZ corner) vs a
# hard rim (clearing our own zone). Read by the state machine's dump release.
var dump_target: Vector3 = Vector3.INF
var dump_is_soft: bool = false

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
# AISkaterCaps index-matched to _scratch_opponents (entries may be null), so the
# reachable-set model reads each defender's real Agility/Size reach. Filled
# alongside the positions in _build_action_opponents_lists.
var _scratch_opponent_caps: Array[AISkaterCaps] = []
var _scratch_opponents_shoot: Array[Vector3] = []
var _scratch_opponents_pass: Array[Vector3] = []
var _scratch_opponents_path: Array[Vector3] = []
var _scratch_teammate_ids: Array[int] = []
# Our skaters excluding the carrier — the defenders that reduce the
# opponent's threat in the turnover-cost term (the carrier just got
# beat, so they don't count). Rebuilt once per _pick_action.
var _scratch_our_defenders: Array[Vector3] = []
# Our chasers for a dump race: our defenders plus ourselves (we dump and chase).
# Rebuilt inside _best_dump.
var _scratch_our_chasers: Array[Vector3] = []

# ── Debug readout ────────────────────────────────────────────────────────────
# Populated every re-eval; the state machine forwards these to its
# own debug_* fields for AIController / floating label.
var debug_shoot_score: float = 0.0
var debug_pass_score: float = 0.0
var debug_pass_peer_id: int = 0
var debug_carry_score: float = 0.0
var debug_carry_pos: Vector3 = Vector3.ZERO
var debug_dump_score: float = 0.0


# ── Public API ───────────────────────────────────────────────────────────────

# Top-level entry. Throttled at PICK_ACTION_PERIOD_TICKS. Mutates
# own state; the state machine reads `intended_action`,
# `pass_target_peer_id`, `shot_loft_level`, `last_carry_anchor`,
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
	shot_loft_level = ShotMechanics.ELEVATION_FLAT
	shot_aim_point = Vector3.INF
	last_carry_anchor = Vector3.ZERO
	dump_target = Vector3.INF
	dump_is_soft = false
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
	dump_target = Vector3.INF
	dump_is_soft = false
	_pick_action_cooldown = 0
	_ticks_since_pick = 0


# ── Implementation ──────────────────────────────────────────────────────────

# Scores SHOOT (wrister), PASS (per teammate), and CARRY (all
# candidates) on equal footing. Hysteresis on fire intents only —
# carry does not get a hysteresis bonus (stand-still ties with the
# best fire from the same position by construction). FIRE WINS TIES;
# CARRY only beats fire on STRICTLY better future-action value.
# Mutates pass_target_peer_id when PASS wins, shot_loft_level when
# SHOOT wins, last_carry_anchor + intended_action always.
func _pick_action(ctx: RoleContext) -> void:
	var snapshot: WorldSnapshot = ctx.snapshot
	var self_pos: Vector3 = ctx.self_pos
	var attacking_goal: Vector3 = ctx.attacking_goal_pos

	_build_action_opponents_lists(ctx)

	# Our current possession safety, from the reachable-set evasion model: can we
	# retain the puck against the defenders' momentum-reach? We read it as our
	# EVADABILITY — the clearance at the best seam we could handle the puck into —
	# so pressure we can dance out of (a committed charger) doesn't read as danger,
	# while a stick actually on the puck does. Feeds the hold's keep-probability.
	var cur_puck_pos: Vector3 = _puck_pos_at(self_pos, attacking_goal)
	var evade_seam: Vector3 = AIActionScoring.best_evade_point(
			cur_puck_pos, ctx.self_velocity, _scratch_opponents, _scratch_opponent_vels,
			ctx.self_handle_reach, _scratch_opponent_caps)
	var current_safety: float = AIActionScoring.clearance_to_safety(
			AIActionScoring.reach_clearance(evade_seam, AIActionScoring.EVADE_HORIZON_S,
					_scratch_opponents, _scratch_opponent_vels, _scratch_opponent_caps))
	var our_goalie: Vector3 = AIRoleHelpers.resolve_our_goalie_pos(ctx)

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
	# Goalie's CURRENT position (squared to whoever currently holds the puck —
	# that's us as the carrier). This is where the goalie actually is, used to
	# clamp the wrister release, since the goalie is a body the release can't cross.
	var goalie_now: Vector3 = _goalie_now(ctx)
	# The shot originates where the PUCK is — the carried puck rides the blade, up
	# to a stick's reach from the body — so the release ref is the puck's current
	# spot led by our body velocity, not the body center. At range the offset is
	# noise; in tight it's the difference between measuring the net from your
	# chest and from the puck (closer, and shifted to the forehand side — a real
	# angle change around the goalie). The goalie, by contrast, squares to the
	# PUCK through distance-scaled smoothing (the quiet-eye tracking lag), which
	# absorbs blade jitter — his square target rides the carrier's body line,
	# not the dangle — so the stale-square ref below stays on self_pos:
	# shot-from-the-puck against square-to-the-smoothed-track is a physical
	# asymmetry the model should see.
	var puck_now: Vector3 = self_pos
	if ctx.snapshot.puck_state != null:
		puck_now = Vector3(
				ctx.snapshot.puck_state.position.x, 0.0,
				ctx.snapshot.puck_state.position.z)
	var wrister_release_pos: Vector3 = AIActionScoring.release_ahead_of_goalie(
			puck_now + horizontal_velocity * SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S,
			attacking_goal, goalie_now)

	# Goalie SQUARED to the release position — the keeper has tracked us (the current
	# puck-holder) the whole way, so a shot from where we already are does NOT catch
	# him moving by relocation. This is the SAME model the carry candidates use
	# (goalie_squared_pos): the caught-moving credit for puck RELOCATION belongs to
	# passes / one-timers (see _compute_best_pass's unsettled arg). The react-then-
	# slide predict_goalie_pos here left the keeper a step behind the shooter's angle,
	# which read as an open near side and drove wide-angle/long-range over-fires.
	# …but "square" means square to what he has READ: he tracks our angle with his
	# real reaction delay AND keeps re-squaring while the shot flies, so his cover
	# at puck-arrival trails the release angle only by what the FLIGHT leaves of
	# his delay (goalie_stale_square_ref). Static or slow, or any flight longer
	# than his read delay, the ref coincides with the release — the wide-angle /
	# mid-range over-fire fix stands, and driving at 8+ m out no longer reads as
	# free. Driving laterally IN TIGHT (flight under his delay), the trailing
	# cover leaves the drive side genuinely open — the real window. Unsettled
	# stays 0: the lag IS the caught-moving effect, expressed positionally.
	var wrister_flight_s: float = wrister_release_pos.distance_to(attacking_goal) \
			/ maxf(ctx.self_wrister_shot_speed, 1.0)
	var goalie_square_ref: Vector3 = AIActionScoring.goalie_stale_square_ref(
			self_pos, horizontal_velocity,
			SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S, wrister_flight_s)
	var wrister_goalie: Vector3 = AIActionScoring.goalie_squared_pos(
			goalie_now, attacking_goal, goalie_square_ref)
	var wrister_unsettled: float = 0.0
	# The five-hole as it physically exists RIGHT NOW, from the replicated pose:
	# standing = the real ~0.20 m slot between the pads (sealable by dropping —
	# the model gates on flight vs the drop), down = the residual slide leak.
	var wrister_five_hole: float = -1.0
	var wrister_goalie_down: bool = false
	var wrister_seal_x: float = 0.0
	var wrister_seal_tall: bool = false
	var opp_goalie_state: GoalieNetworkState = ctx.snapshot.goalie_states.get(1 - ctx.team_id)
	if opp_goalie_state != null:
		wrister_goalie_down = opp_goalie_state.is_down()
		wrister_five_hole = GoalieBehaviorRules.five_hole_gap_m(
				wrister_goalie_down, opp_goalie_state.five_hole_openness)
		# Post-seal stance (VH/RVH): the goalie is committed to a post and the
		# pose IS the coverage — see the seal model in _hole_open_angle. A
		# committed post stance also does not re-square: he holds the post
		# while the sharp-angle threat lasts (the state we read is refreshed
		# every tick), so score the shot against where he's actually parked,
		# not a hypothetical arc-squared keeper — the squared model both
		# invents coverage he'd need to leave the post to provide AND hides
		# the far-side opening his commitment concedes.
		wrister_seal_x = opp_goalie_state.post_seal_x_sign(attacking_goal.z)
		wrister_seal_tall = opp_goalie_state.is_post_seal_tall()
		if wrister_seal_x != 0.0:
			wrister_goalie = goalie_now

	# Top-level SHOOT. _scratch_opponent_caps is index-matched to _scratch_opponents
	# (and thus to _scratch_opponents_shoot, built in the same order), so a lane
	# defender's real Size/Speed reach prices the shot lane.
	var shoot_score: float = AIActionScoring.score_shoot(
			wrister_release_pos, attacking_goal, wrister_goalie,
			GameRules.NET_HALF_WIDTH, _scratch_opponents_shoot,
			ctx.self_wrister_shot_speed, wrister_unsettled, _scratch_opponent_caps,
			wrister_five_hole, wrister_goalie_down,
			wrister_seal_x, wrister_seal_tall)

	# Top-level PASS — per teammate, score_at(receiver_lead) × lane × time.
	var self_state: SkaterNetworkState = snapshot.skater_states[ctx.peer_id]
	var best_pass: Array = _compute_best_pass(
			ctx, self_state.facing, _scratch_teammate_ids)
	var best_pass_peer: int = best_pass[0]
	var best_pass_score: float = best_pass[1]
	var best_pass_saucer: bool = best_pass[2]

	# Top-level CARRY — best carry candidate (8 polar around the slot
	# direction + slot anchor + own-half wall exits + stand-still).
	# Each scored uniformly:
	# score_at(candidate, projected_opps) × path_clear × time_decay.
	# Time uses momentum-aware effective speed so reverse candidates
	# self-discount via longer arrival time.
	var carry_result: Array = _best_carry(ctx)
	var carry_score: float = carry_result[0]
	last_carry_anchor = carry_result[1]
	var raw_carry_score: float = carry_result[2]
	# Pass-first under pressure: discount the carry by how contested the path AHEAD is,
	# so a lightly-impeded carrier moves the puck to an unimpeded teammate rather than
	# grinding forward (even giving up some real estate). Only the fire-vs-carry
	# compete sees this — the dump still judges against the honest raw carry.
	carry_score *= lerpf(FORWARD_PRESSURE_MIN_SCALE, 1.0, _carrier_forward_clearance(ctx))
	# …but judge SELF by the same currency a pass receiver gets: _pass_ev credits
	# a receiver with the best shot he can REACH by driving in (drive-in credit).
	# Without the mirror, two equally-covered wingers at the blue line each rated
	# the OTHER man's future above their own present — my carry paid the forward-
	# pressure discount while his drive-in didn't — and the puck ping-ponged
	# along the line (an offside factory) instead of ever entering the zone. The
	# same formula on MY OWN spot floors the carry: a symmetric mate can never
	# out-score me by proxy, so the pass only wins when he is GENUINELY more
	# open, and a free entry gets taken by the man who already has the puck.
	carry_score = maxf(carry_score, _receiver_drive_in_value(
			ctx, self_pos, ctx.self_wrister_shot_speed,
			ctx.caps_by_peer.get(ctx.peer_id)))

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
	elif intended_action == INTENT_PASS and best_pass_score > 0.0:
		best_pass_score *= 1.0 + AIActionScoring.ACTION_HYSTERESIS_MARGIN_FRAC

	# Debug snapshot of the per-tick scores for the floating label.
	# State machine forwards these to its own debug_* fields; AIController
	# polls and refreshes only when content changes.
	debug_shoot_score = shoot_score
	debug_pass_score = best_pass_score
	debug_pass_peer_id = best_pass_peer
	debug_carry_score = carry_score
	debug_carry_pos = last_carry_anchor

	# The wrister is the only shot type — a paced release covers everything from a
	# soft in-tight roof to a full-power rip (see #363), so the separate no-charge
	# quick snap was retired (the fast ~125 ms wrister out-scores it even into a set
	# goalie point-blank).
	var best_shot_score: float = shoot_score
	var best_shot_intent: int = INTENT_SHOOT

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
	# EXCEPT: fire must clear a NOISE FLOOR to win. Firing surrenders the puck
	# (shot up-ice, or a pass); holding/carrying retains it and its optionality. So
	# a near-worthless fire must not beat a collapsing hold — a carrier swarmed deep
	# in its own zone (pass = 0 all lanes covered, carry collapsing toward 0) must
	# skate clear, not fling a hopeless shot away. This used to be a hard `> 0`:
	# score_shoot returned exactly 0 out of range. The geometric shot model has no
	# range cliff — a 47 m shot leaves a ~0.002 residual — so the gate is now a
	# small tactical floor (FIRE_MIN_VALUE), the least shot value worth giving up
	# possession for. A real in-range shot scores well above it and still wins ties.
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
	#   - keep_prob from the reachable evadability → under pressure we can't dance
	#     out of, the hold is risky and loses; in open ice it's ~1 and can win.
	#   - decay(elapsed) → a wait that never materialises self-extinguishes (the
	#     developing value shrinks until the available shot wins).
	# When the teammate flags ready, the developing feed drops to 0 here but the
	# normal pass scoring jumps (one-timer), so PASS wins and feeds it.
	# keep_prob is our current possession safety, computed once at the top of
	# _pick_action — the hold only holds its value while we can actually keep it.
	var keep_prob: float = current_safety
	var hold_value: float = (_best_developing_feed(ctx)
			* keep_prob * pow(AIActionScoring.CARRY_DELAY_DISCOUNT_PER_SEC, _hold_elapsed_s))

	# Last-resort DUMP (zone-gated; -INF where none applies). It competes against the
	# RAW (honest, strip-point-priced) carry — see _best_dump.
	var dump_result: Array = _best_dump(ctx, our_goalie)
	var dump_score: float = dump_result[0]
	debug_dump_score = dump_score

	var new_intent: int
	# Fire only if it beats BOTH carrying and holding for the developing play.
	if fire_score >= carry_score and fire_score >= hold_value \
			and fire_score > FIRE_MIN_VALUE and not staggered:
		_hold_elapsed_s = 0.0
		new_intent = fire_intent
		if new_intent == INTENT_PASS:
			pass_target_peer_id = best_pass_peer
			# Every pass is a paced wrister now (the #363 pure-mouse-speed model
			# makes release pace reliable, so there's no reason to keep the fixed-
			# power quick snap): distance-adaptive launch speed — a genuinely soft
			# touch for a close feed, harder (still catchable) for a long one — all
			# from the one charged release, capped at this bot's own max wrister.
			var receiver: SkaterNetworkState = ctx.snapshot.skater_states.get(best_pass_peer)
			if receiver != null:
				# Receiver-relative launch: fire so the puck lands on the tape at
				# the magnet CLOSING speed in the receiver's frame (#373) — harder
				# onto a streaking receiver, softer to one curling back — not a
				# fixed world speed that arrives hot or soft depending on his motion.
				# Distance and direction from the PUCK (the real release point).
				var to_receiver: Vector3 = receiver.position - puck_now
				to_receiver.y = 0.0
				var pass_dir: Vector3 = to_receiver.normalized()
				pass_target_speed = AIActionScoring.pass_launch_speed(
						puck_now.distance_to(receiver.position),
						ctx.self_wrister_shot_speed, ctx.pass_speed_scale,
						receiver.velocity, pass_dir)
			else:
				pass_target_speed = AIActionScoring.PASS_SPEED_M_S * ctx.pass_speed_scale
			pass_should_charge = true
			# Saucer it over a contested mid-lane defender (only ever true
			# for long passes — see _compute_best_pass).
			pass_should_saucer = best_pass_saucer
		elif new_intent == INTENT_SHOOT:
			# Loft AND aim from the same seven-hole geometry score_shoot used — the
			# chosen hole's elevation and net-plane target, scored at the projected
			# release. Roofs a set goalie (top-corner window), stays flat on a
			# five-hole / low corner, and aims exactly at that hole.
			shot_loft_level = AIActionScoring.best_shot_loft(
					wrister_release_pos, attacking_goal, wrister_goalie,
					GameRules.NET_HALF_WIDTH, ctx.self_wrister_shot_speed,
					wrister_unsettled, wrister_five_hole, wrister_goalie_down,
					wrister_seal_x, wrister_seal_tall)
			shot_aim_point = AIActionScoring.best_shot_aim(
					wrister_release_pos, attacking_goal, wrister_goalie,
					GameRules.NET_HALF_WIDTH, ctx.self_wrister_shot_speed,
					wrister_unsettled, wrister_five_hole, wrister_goalie_down,
					ctx.self_aim_spread_rad,
					wrister_seal_x, wrister_seal_tall)
	elif dump_score > raw_carry_score and not staggered:
		# Last resort: even the best carry is doomed in a bad spot (raw carry, honestly
		# priced, below the safe giveaway). Clear our zone, or dump-and-chase.
		_hold_elapsed_s = 0.0
		new_intent = INTENT_DUMP
		dump_target = dump_result[1]
		dump_is_soft = dump_result[2]
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
	_scratch_opponent_caps.clear()
	_scratch_opponents_shoot.clear()
	_scratch_our_defenders.clear()
	for peer_id: int in ctx.snapshot.skater_states:
		if peer_id == ctx.peer_id:
			continue
		var s: SkaterNetworkState = ctx.snapshot.skater_states[peer_id]
		if ctx.team_id_by_peer.get(peer_id, -1) != ctx.team_id:
			_scratch_opponents.append(s.position)
			_scratch_opponent_vels.append(s.velocity)
			_scratch_opponent_caps.append(ctx.caps_by_peer.get(peer_id))
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
		teammate_ids: Array[int]) -> Array:
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
	var attacking_goal: Vector3 = ctx.attacking_goal_pos
	# One-way valve: a carrier already in the offensive zone won't pass the puck
	# back out of it (mirrors the carry-side exclusion in _score_move_candidate).
	var carrier_in_oz: bool = AIActionScoring.in_offensive_zone(self_pos, attacking_goal)
	var pass_origin: Vector3 = _pass_origin(ctx)
	for peer_id: int in teammate_ids:
		var receiver_state: SkaterNetworkState = snapshot.skater_states[peer_id]
		if receiver_state.is_ghost:
			continue
		if carrier_in_oz and not AIActionScoring.in_offensive_zone(
				receiver_state.position, attacking_goal):
			continue
		# Match the speed the state machine will actually fire at: the
		# distance-adaptive launch speed (capped at this bot's own max
		# wrister). Threading the actual speed here makes the lead and
		# opponent projections match reality — without it, a 15 m pass
		# scored at 14 m/s overestimates defender presence on the line and
		# leads past the receiver, both of which depress long-pass scores
		# below where they should be.
		var dist: float = pass_origin.distance_to(receiver_state.position)
		var pass_speed: float = AIActionScoring.pass_launch_speed(
				dist, ctx.self_wrister_shot_speed, ctx.pass_speed_scale)
		var receiver_accel: Vector3 = ctx.acceleration_by_peer.get(peer_id, Vector3.ZERO)
		# Intercept-aware lead, shared with the state machine's firing aim.
		# flight_t is the SOLVED time (refined against the predicted
		# intercept), used downstream for opponent/goalie projection and
		# the time-decay term. The receiver's real build (Speed/Agility) bounds
		# how far it can actually get to — a fast, agile receiver is led further.
		var receiver_caps: AISkaterCaps = ctx.caps_by_peer.get(peer_id)
		var lead: Array = AIPassLead.lead(
				pass_origin, receiver_state, receiver_accel, pass_speed, PASS_LEAD_MAX_S, receiver_caps)
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
				self_facing_xz, self_pos, receiver,
				ctx.self_reach_cone_half_angle, ctx.self_facing_turn_rate)
		var s: float = _pass_ev(ctx, receiver, pass_speed, flight_t,
				receiver_release_t, flight_t + rotation_time, our_goalie, receiver_caps)
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
# caller decides). A cross-seam feed leaves the goalie mid-slide, so the
# receiver's shot is scored against that unsettled goalie (the seven-hole
# geometry opens up when he's caught moving). Receiver shot speed stays the
# league default (we don't carry teammates' attributes).
func _pass_ev(ctx: RoleContext, receiver_spot: Vector3, pass_speed: float,
		flight_t: float, receiver_release_t: float, delay_s: float,
		our_goalie: Vector3, receiver_caps: AISkaterCaps = null) -> float:
	var self_pos: Vector3 = ctx.self_pos
	# The pass flies from the PUCK (the blade), not the body — judge the lane
	# the puck actually travels. From behind the net the two differ by up to a
	# stick's reach, which is exactly where "clear from the chest, clanks the
	# frame from the blade" lived. (self_pos stays the carrier-body reference for
	# the receiver scoring / loss-point terms below.)
	var origin: Vector3 = _pass_origin(ctx)
	# Hard zeros: net-blocker (segment crosses a net body) and own-DZ
	# slot crossing (intercepted = goal-against).
	if AIActionScoring.pass_lane_blocked_by_net(origin, receiver_spot):
		return 0.0
	if AIActionScoring.pass_crosses_own_slot(
			origin, receiver_spot, ctx.own_goal_dir * GameRules.GOAL_LINE_Z):
		return 0.0
	var lane: float = AIActionScoring.lane_clear(
			origin, receiver_spot, _scratch_opponents, pass_speed,
			_scratch_opponent_vels, _scratch_opponent_caps)
	if lane <= 0.0:
		return 0.0
	_project_opponents_to(ctx, flight_t, _scratch_opponents_pass)
	var receiver_goalie: Vector3 = _predict_goalie_at(
			ctx, receiver_release_t, receiver_spot)
	var receiver_unsettled: float = _goalie_unsettled_at(
			ctx, receiver_release_t, receiver_spot)
	# Score the receiver's shot at ITS real release speed (Shot) — a high-Shot
	# teammate one-times harder, beating the goalie more, so it's a better feed.
	var receiver_shot_speed: float = receiver_caps.wrister_shot_speed if receiver_caps != null \
			else AIActionScoring.WRISTER_SHOT_SPEED_M_S
	var receiver_value: float = _score_at(ctx, receiver_spot, self_pos,
			_scratch_opponents_pass, receiver_goalie,
			receiver_shot_speed, receiver_unsettled)
	# An OPEN receiver isn't limited to a one-timer from where they catch it — they
	# can carry into a better look, exactly like the carrier's own best_carry. In the
	# offensive zone the plain score_at above is shot-ONLY (xG's domain), so a
	# wide-open man in a modest spot (e.g. a 6.6 m dead-slot look the set goalie
	# covers) is under-valued and loses to the carrier's own speculative drive. Credit
	# the best shot the receiver can REACH with a short drive toward the net, gated by
	# an open lane (they must actually be able to get there) and time-discounted — so a
	# wide-open teammate correctly out-scores forcing a carry through a defender.
	# _score_at already prices "drive to slot" via position_potential OUTSIDE the zone,
	# so this only bites in the OZ where that's switched off. (Re-projects
	# _scratch_opponents_pass, now free — the instant value above already consumed it.)
	receiver_value = maxf(receiver_value, _receiver_drive_in_value(
			ctx, receiver_spot, receiver_shot_speed, receiver_caps))
	# The receiver pays the SAME forward-pressure toll the carrier's own score
	# does: his value is what he can do with the puck from HIS spot, and a mate
	# whose netward path is just as clogged as ours is not an upgrade. Without
	# the mirror, two equally-covered wingers at the blue line each rated the
	# other man's future above their own discounted present, and the puck
	# ping-ponged along the line (an offside factory) instead of entering the
	# zone. Symmetric coverage → symmetric discount → the man ALREADY holding
	# the puck keeps it; the pass wins only when the mate is genuinely clearer.
	var receiver_speed: float = receiver_caps.max_speed if receiver_caps != null 			else AIActionScoring.SKATER_REF_SPEED_M_S
	receiver_value *= lerpf(FORWARD_PRESSURE_MIN_SCALE, 1.0,
			_forward_clearance_at(ctx, receiver_spot, receiver_speed))
	var time_decay: float = pow(
			AIActionScoring.CARRY_DELAY_DISCOUNT_PER_SEC, delay_s)
	var completion: float = lane * (1.0 - AIActionScoring.PASS_MISS_PROB)
	# Clean per-action EV: prob(complete) × value(teammate has puck at receiver)
	# minus the turnover cost if it's intercepted or missed. The pressure the
	# carrier is under is priced by the CARRY/HOLD alternatives' own strip cost
	# (they lose value under pressure) — the pass wins when it out-EVs them, with
	# no separate "escape" bonus (that double-counted the pressure).
	var benefit: float = receiver_value * completion * time_decay
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
# `target` before the blade can fire there. The blade reaches anywhere inside
# the reach cone (`cone_half_angle` = ROM + torso twist, ~157° — the exact IK
# gate the pose coordinator enforces), so a shot/pass to ANY in-cone target
# fires from the current facing with NO body turn (rotation_time = 0). Only aims
# in the narrow back wedge past the cone pay, and then only for the OVERSHOOT
# (angle minus cone), rotated at this bot's real Agility-scaled turn rate.
func _facing_rotation_time(self_facing_xz: Vector2, self_pos: Vector3,
		target: Vector3, cone_half_angle: float, turn_rate: float) -> float:
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
	var overshoot: float = maxf(0.0, angular_distance - cone_half_angle)
	return overshoot / maxf(turn_rate, 0.001)


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
func _best_carry(ctx: RoleContext) -> Array:
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
		var s_total: float = _score_move_candidate(ctx, candidate, our_goalie)
		if s_total > best_score:
			best_score = s_total
			best_pos = candidate

	# Slot anchor — long-range candidate, valid from anywhere on the
	# rink. NZ bots reach the slot via this; OZ bots near the slot
	# already cover it via local polar candidates.
	var slot_total: float = _score_move_candidate(ctx, slot_pos, our_goalie)
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
				ctx, exit_right, our_goalie)
		if exit_right_total > best_score:
			best_score = exit_right_total
			best_pos = exit_right
		var exit_left := Vector3(-exit_x, 0.0, exit_z)
		var exit_left_total: float = _score_move_candidate(
				ctx, exit_left, our_goalie)
		if exit_left_total > best_score:
			best_score = exit_left_total
			best_pos = exit_left

	# Evasion seam — the reachable-set escape (best_evade_point): the spot in our
	# handling envelope with the most clearance from the defenders' momentum-reach.
	# Adding it as a carry candidate is what turns the safety model into PLAYMAKING
	# — the bot cuts into the space a committed defender vacates instead of only
	# surviving pressure. Scored like any candidate, so it only wins when the space
	# it opens is actually worth carrying to.
	var seam: Vector3 = AIActionScoring.best_evade_point(
			self_pos, ctx.self_velocity, _scratch_opponents, _scratch_opponent_vels,
			ctx.self_handle_reach, _scratch_opponent_caps)
	var seam_total: float = _score_move_candidate(ctx, seam, our_goalie)
	if seam_total > best_score:
		best_score = seam_total
		best_pos = seam

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
	# should skate clear. Safety is the static reachable-clearance read (a closing
	# defender still registers from its momentum over the reaction window).
	var stand_goalie: Vector3 = _predict_goalie_at(
			ctx, SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S, self_pos)
	var stand_unsettled: float = _goalie_unsettled_at(
			ctx, SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S, self_pos)
	var stand_score: float = _score_at(ctx, self_pos, self_pos,
			_scratch_opponents, stand_goalie,
			ctx.self_wrister_shot_speed, stand_unsettled)
	var stand_puck_pos: Vector3 = _puck_pos_at(self_pos, attacking_goal)
	var stand_safety: float = AIActionScoring.clearance_to_safety(
			AIActionScoring.carry_clearance(stand_puck_pos, stand_puck_pos,
					AIActionScoring.EVADE_HORIZON_S,
					_scratch_opponents, _scratch_opponent_vels, _scratch_opponent_caps))
	var stand_cost: float = AIActionScoring.turnover_cost(
			stand_puck_pos, 1.0 - stand_safety, ctx.defending_goal_pos,
			our_goalie, GameRules.NET_HALF_WIDTH, _scratch_our_defenders)
	var stand_total: float = stand_score * stand_safety - stand_cost
	if stand_total > best_score:
		best_score = stand_total
		best_pos = self_pos

	# [floored, best_pos, RAW]. Floored is the "keep the puck" floor for the fire
	# compete; raw keeps the honest sign for the dump's expected-keep (a pinned
	# carry that will be stripped must read negative, not clamped to 0).
	return [maxf(best_score, 0.0), best_pos, best_score]


# Last-resort DUMP, zone-gated. Returns [dump_value, target, is_soft]; -INF when no
# dump applies here (own-side neutral zone, or already in the OZ):
#   - In our own DZ → clear out to the neutral-zone strong-side boards (hard rim).
#   - Past centre (non-icing) but short of the blue line → dump-and-chase into the
#     far offensive corner (soft flip), when the chase is winnable.
#
# dump_value (absolute, same currency as carry) = gain − concede:
#   - concede = turnover_cost(target, 1−recovery), the danger handed over at the safe
#     dump spot (≈0 deep in their end, small at centre). recovery is the race to the
#     dumped puck, so a dump self-suppresses when the chase isn't winnable.
#   - gain = offensive upside, dump-in ONLY: recovery × position_potential(corner) ×
#     chase_decay (winning the zone). A clear gains nothing, so its value is just
#     −concede, a small negative.
# It competes against the RAW carry — now honest, since carry candidates price their
# strip at the tight point ON the route (carry_strip_point), so a doomed carry reads
# honestly negative and an escapable one positive. The dump wins exactly when even
# the best carry is worse than conceding at a safe spot: a last resort, no threshold.
func _best_dump(ctx: RoleContext, our_goalie: Vector3) -> Array:
	var self_pos: Vector3 = ctx.self_pos
	var attacking_goal: Vector3 = ctx.attacking_goal_pos
	var defending_goal: Vector3 = ctx.defending_goal_pos
	var target: Vector3
	var is_soft: bool
	if AIActionScoring.in_offensive_zone(self_pos, defending_goal):
		target = AIActionScoring.dump_clear_target(self_pos, -ctx.own_goal_dir)
		is_soft = false
	elif AIActionScoring.past_center_toward_attack(self_pos, attacking_goal) \
			and not AIActionScoring.in_offensive_zone(self_pos, attacking_goal):
		target = AIActionScoring.dump_in_target(self_pos, attacking_goal)
		is_soft = true
	else:
		return [-INF, Vector3.INF, false]

	# Our chasers = teammates + ourselves; theirs = the opponents already gathered.
	_scratch_our_chasers.clear()
	for d: Vector3 in _scratch_our_defenders:
		_scratch_our_chasers.append(d)
	_scratch_our_chasers.append(self_pos)
	var recovery: float = AIActionScoring.chase_recovery(
			target, _scratch_our_chasers, _scratch_opponents)
	var concede: float = AIActionScoring.turnover_cost(
			target, 1.0 - recovery, defending_goal, our_goalie,
			GameRules.NET_HALF_WIDTH, _scratch_our_defenders)
	var gain: float = 0.0
	if is_soft:
		var nearest_our: float = INF
		for c: Vector3 in _scratch_our_chasers:
			nearest_our = minf(nearest_our, c.distance_to(target))
		# Dump-and-CHASE: we race the dumped puck at our own top speed (Speed) —
		# a faster chaser reaches it sooner, so the decay bites less.
		var chase_decay: float = pow(AIActionScoring.CARRY_DELAY_DISCOUNT_PER_SEC,
				nearest_our / maxf(ctx.self_max_speed, 0.001))
		var value: float = AIActionScoring.position_potential(
				target, attacking_goal, _scratch_opponents)
		gain = recovery * value * chase_decay
	return [gain - concede, target, is_soft]


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
# `safety` is the reachable carry_clearance over the PUCK's path from our current
# spot to the candidate spot across the arrival time: the tightest point where a
# defender's momentum-reach could get a stick to it, capturing both a defender
# converging on the ROUTE and one waiting at the DESTINATION. A committed charger
# whose momentum carries him past reads as clear; a stick on the line does not.
#
# Expected-value shape: benefit (offensive upside) minus the turnover cost.
# keep_prob = safety is the possession-protection probability; (1 - keep_prob)
# is the strip probability, so the loss-probability lives in exactly one place
# (no double-count with the benefit, whose safety multiplier is the "value of
# arriving with the puck" discount). Loss point = the EARLIEST covered point on the
# route (carry_strip_point) — where the strip actually happens — NOT the
# destination: a carry that ends in open ice but threads our own slot must pay the
# slot's turnover cost. Cost self-localizes: ~0 driving into the OZ, large when the
# route drags the puck through our own slot.
func _score_move_candidate(ctx: RoleContext, candidate: Vector3,
		our_goalie: Vector3) -> float:
	var self_pos: Vector3 = ctx.self_pos
	# One-way valve: once the puck is in the offensive zone, don't carry it back
	# out. Establishing the zone is worth keeping — a carry that surrenders it (a
	# retreat past the blue line) is pruned so it can never win. Stand-still (self,
	# in-zone) never trips this, so the candidate set is never empty. Mirrors the
	# receiver-side exclusion in _compute_best_pass.
	if AIActionScoring.in_offensive_zone(self_pos, ctx.attacking_goal_pos) \
			and not AIActionScoring.in_offensive_zone(candidate, ctx.attacking_goal_pos):
		return -INF
	var local_time: float = AIActionScoring.time_to_arrive(
			self_pos, candidate, ctx.self_velocity, ctx.self_max_speed)
	_project_opponents_to(ctx, local_time, _scratch_opponents_path)
	var lane: float = AIActionScoring.path_clearance(
			self_pos, candidate, _scratch_opponents_path)
	if lane <= 0.0:
		return -INF
	# Score the candidate against a SQUARED goalie — arc-matched and set. The keeper
	# tracks the puck continuously as the bot skates the candidate (a gradual move,
	# not a relocation it reacts to from a standstill), so on arrival it is square:
	# both the predicted position AND the "caught moving" unsettled bonus (0.0)
	# reflect that. Using the react-then-slide predict_goalie_pos here under-tracked
	# the keeper — it fell short of arc-matching a diagonal step and leaked the far
	# side, so the bot chased an ever-receding "one more cut catches him moving" shot
	# into the crease instead of firing. The caught-moving credit is a puck-
	# RELOCATION effect (a pass / one-timer that outruns the keeper's tracking — see
	# score_pass's unsettled arg), never a carry the goalie reads the whole way. The
	# real shot (shoot-now, scored above) still captures any genuine goalie lag.
	var cand_goalie: Vector3 = AIActionScoring.goalie_squared_pos(
			_goalie_now(ctx), ctx.attacking_goal_pos, candidate)
	var dest_score: float = _score_at(ctx, candidate, self_pos,
			_scratch_opponents_path, cand_goalie,
			ctx.self_wrister_shot_speed, 0.0)
	var decay: float = pow(AIActionScoring.CARRY_DELAY_DISCOUNT_PER_SEC, local_time)
	var cand_puck_pos: Vector3 = _puck_pos_at(candidate, ctx.attacking_goal_pos)
	var cur_puck_pos: Vector3 = _puck_pos_at(self_pos, ctx.attacking_goal_pos)
	var safety: float = AIActionScoring.clearance_to_safety(
			AIActionScoring.carry_clearance(cur_puck_pos, cand_puck_pos, local_time,
					_scratch_opponents, _scratch_opponent_vels, _scratch_opponent_caps))
	var benefit: float = dest_score * lane * decay * safety
	var keep_prob: float = safety
	# Price the loss where the strip actually happens — the earliest covered point on
	# the route — not the (often safe) destination. A candidate that ends in open ice
	# but threads a defender through our own slot must pay the slot's turnover cost,
	# not the destination's. This is what keeps a doomed carry honestly negative.
	var strip_point: Vector3 = AIActionScoring.carry_strip_point(
			cur_puck_pos, cand_puck_pos, local_time,
			_scratch_opponents, _scratch_opponent_vels, _scratch_opponent_caps)
	var cost: float = AIActionScoring.turnover_cost(
			strip_point, 1.0 - keep_prob, ctx.defending_goal_pos,
			our_goalie, GameRules.NET_HALF_WIDTH, _scratch_our_defenders)
	return benefit - cost


# Position-value scorer at `pos`, evaluated from the carrier at `from_pos`.
#
#   carrier in the offensive zone:  score_shoot(pos) only
#   carrier outside the zone:        max(score_shoot(pos), position_potential(pos))
#
# The regime is gated on the CARRIER (from_pos), not on `pos`. This is the whole
# trick that lets the two value scales coexist without a bridging floor: a carrier
# already in the zone reads real, goalie-aware shot danger for every (in-zone,
# valve-guaranteed) candidate — the O-zone is xG's domain, a strictly better read
# than any positional proxy, and it drives the bot to the slot rather than a
# "high-potential" spot that doesn't score. A carrier OUTSIDE prices every
# candidate — including an entry target across the blue line — on the position_
# potential scale, whose closeness gradient climbs toward the slot, so driving into
# the zone out-scores staying out. Because of offsides the two never need to be
# compared: the only in-vs-out choice is the carry into the zone, made entirely in
# potential currency. The max with score_shoot lets a genuinely open entry look
# (a breakaway) still register its shot value on the way in.
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
		predicted_goalie_pos: Vector3,
		shot_speed_m_s: float = AIActionScoring.WRISTER_SHOT_SPEED_M_S,
		goalie_unsettled_factor: float = 0.0) -> float:
	var attacking_goal: Vector3 = ctx.attacking_goal_pos
	# All the carrier's opponent arrays (path / pass / stand projections) are built
	# in the same snapshot order as _scratch_opponent_caps, so the defenders in the
	# shot lane are priced at their real Size/Speed reach. (lane_clear falls back to
	# league defaults if a count ever mismatches, so this is safe regardless.)
	var shoot_s: float = AIActionScoring.score_shoot(
			pos, attacking_goal, predicted_goalie_pos,
			GameRules.NET_HALF_WIDTH, opps, shot_speed_m_s,
			goalie_unsettled_factor, _scratch_opponent_caps)
	if AIActionScoring.in_offensive_zone(from_pos, attacking_goal):
		return shoot_s
	var potential_s: float = AIActionScoring.position_potential(
			pos, attacking_goal, opps)
	var realization: float = AIActionScoring.potential_realization_discount(
			pos, attacking_goal)
	return maxf(shoot_s, potential_s * realization)


# The value of an open pass receiver DRIVING IN: the best value they can reach by
# carrying toward the net, not just a one-timer / potential from where they catch it.
# Models "a wide-open man walks into a better chance" (OZ) and "an ahead man with a
# clear path skates it into the zone" (NZ/DZ) — both of which the score_at above
# omits (OZ is shot-only; a static receiver isn't credited for advancing).
#
# The reach is the REACHABLE SET, not a fixed step: the receiver carries toward the
# net up to RECEIVER_DRIVE_MAX_M, but only as far as the path stays clear — a defender
# in the way strips it early (carry_strip_point), a very clear lane lets it run the
# whole way. So a teammate a little farther back with a WIDE-OPEN path is credited
# for the deep spot they can reach, while a covered one earns nothing. Value =
# score_at(reached spot) × keep-probability × decay(time to reach it); the pass-flight
# decay is applied to the max() by the caller. Goalie squared to the reached spot, and
# the whole thing uses the SAME reach/clearance/score machinery as the carrier's own
# carry candidates, so both sides of the pass are valued consistently. Bounded — one
# carry, leaf value, no further passing — so no recursion. Reuses _scratch_opponents_pass.
func _receiver_drive_in_value(ctx: RoleContext, receiver_spot: Vector3,
		receiver_shot_speed: float, receiver_caps: AISkaterCaps) -> float:
	var to_net_x: float = ctx.attacking_goal_pos.x - receiver_spot.x
	var to_net_z: float = ctx.attacking_goal_pos.z - receiver_spot.z
	var d: float = sqrt(to_net_x * to_net_x + to_net_z * to_net_z)
	# Already tight to the net — no room to improve by driving; instant shot covers it.
	if d <= RECEIVER_DRIVE_MIN_NET_DIST_M + 0.1:
		return 0.0
	var reach: float = minf(RECEIVER_DRIVE_MAX_M, d - RECEIVER_DRIVE_MIN_NET_DIST_M)
	var inv: float = 1.0 / d
	var dir_x: float = to_net_x * inv
	var dir_z: float = to_net_z * inv
	var target := Vector3(
			receiver_spot.x + dir_x * reach, 0.0, receiver_spot.z + dir_z * reach)
	if not AIRoleHelpers.is_legal_position(target):
		return 0.0
	var recv_speed: float = receiver_caps.max_speed if receiver_caps != null \
			else ctx.self_max_speed
	var reach_time: float = reach / maxf(recv_speed, 1.0)
	# Reachable-set safety + strip point over the drive, using the SAME current-opponent
	# reach model the carrier's carry uses (carry_clearance/strip project the defenders
	# in by their velocity + closing reach). A clear lane keeps ~1 and reaches `target`;
	# a defender in the way drops keep and pulls the reached spot back to the strip.
	var keep: float = AIActionScoring.clearance_to_safety(
			AIActionScoring.carry_clearance(receiver_spot, target, reach_time,
					_scratch_opponents, _scratch_opponent_vels, _scratch_opponent_caps))
	if keep <= 0.0:
		return 0.0
	var reached: Vector3 = AIActionScoring.carry_strip_point(
			receiver_spot, target, reach_time,
			_scratch_opponents, _scratch_opponent_vels, _scratch_opponent_caps)
	var t: float = receiver_spot.distance_to(reached) / maxf(recv_speed, 1.0)
	_project_opponents_to(ctx, t, _scratch_opponents_pass)
	var goalie: Vector3 = AIActionScoring.goalie_squared_pos(
			_goalie_now(ctx), ctx.attacking_goal_pos, reached)
	# score_at, not score_shoot: OZ → goalie-aware shot from the reached spot; NZ/DZ →
	# position potential of the reached spot (advanced toward the zone). Same regime
	# the carrier's own carry candidates use, so the ahead man on the clear path is
	# credited for continuing the rush exactly as the carrier would credit itself.
	var advanced: float = _score_at(ctx, reached, ctx.self_pos,
			_scratch_opponents_pass, goalie, receiver_shot_speed, 0.0)
	return advanced * keep * pow(AIActionScoring.CARRY_DELAY_DISCOUNT_PER_SEC, t)


# How clear the carrier's OWN path toward the attacking objective is — the reachable
# safety of carrying straight at the net over FORWARD_PRESSURE_HORIZON_M. 1.0 when the
# lane ahead is open, dropping toward 0 as a defender sits in it. Feeds the carry's
# pass-first discount (see FORWARD_PRESSURE_*): the model already prices a defender
# ON the puck, but not one the carrier must still beat to advance — this reads that
# impending contest with the same reachable-set model the carry candidates use, so a
# defender only counts when it's genuinely in the forward lane (one off to the side
# leaves the path clear and the carry undiscounted).
func _carrier_forward_clearance(ctx: RoleContext) -> float:
	return _forward_clearance_at(ctx, ctx.self_pos, ctx.self_max_speed)


# Forward-pressure read for ANY spot: how clear the netward path out of `pos`
# is over the pressure horizon. Shared by the carrier's own discount and the
# pass receiver's (see _pass_ev) so both sides of a carry-vs-pass compete pay
# the same toll for the same clogged ice.
func _forward_clearance_at(ctx: RoleContext, pos: Vector3, speed: float) -> float:
	var to_net_x: float = ctx.attacking_goal_pos.x - pos.x
	var to_net_z: float = ctx.attacking_goal_pos.z - pos.z
	var d: float = sqrt(to_net_x * to_net_x + to_net_z * to_net_z)
	if d < 0.5:
		return 1.0
	var reach: float = minf(FORWARD_PRESSURE_HORIZON_M, d)
	var inv: float = 1.0 / d
	var target := Vector3(
			pos.x + to_net_x * inv * reach, 0.0,
			pos.z + to_net_z * inv * reach)
	var t: float = reach / maxf(speed, 1.0)
	return AIActionScoring.clearance_to_safety(
			AIActionScoring.carry_clearance(pos, target, t,
					_scratch_opponents, _scratch_opponent_vels, _scratch_opponent_caps))


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
func _best_developing_feed(ctx: RoleContext) -> float:
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
			# the normal pass scoring feeds it; nothing to wait for.
			# (slot_anchor returns ZERO for FINISHER, so we read the
			# teammate's live motion, not a brain anchor.)
			#
			# The play that WILL exist, not just the one that does: a
			# finisher still skating to his staging spot is valued at the
			# spot he's DRIVING TO — position projected along velocity, the
			# same primitive as the developing outlet below — so a fresh
			# zone entry holds for the mates still arriving instead of
			# settling for the weak from-the-top shot the moment the carrier
			# crosses the line. As he settles the projection converges to
			# his position, the live pass scoring converges to this value,
			# and fire wins the tie — the hold can't outlive the play it's
			# waiting for (and _hold_elapsed_s decays a wait that never
			# materialises). The OZ gate reads the projected spot for the
			# same reason: a finisher a stride outside the line, driving in,
			# IS the developing cross-seam.
			var fin_vel: Vector3 = tm.velocity
			var spot := Vector3(
					tm.position.x + fin_vel.x * OUTLET_DEVELOP_WINDOW_S, 0.0,
					tm.position.z + fin_vel.z * OUTLET_DEVELOP_WINDOW_S)
			if tm.is_ghost or ctx.team_brain.is_one_timer_ready(pid) \
					or -ctx.own_goal_dir * spot.z <= GameRules.BLUE_LINE_Z \
					or not AIRoleHelpers.is_legal_position(spot):
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
					pass_speed, feed_unsettled)
		elif slot == AIRoleSlots.Slot.BREAKOUT_STRONG \
				or slot == AIRoleSlots.Slot.OUTLET:
			feed = _developing_outlet_feed(ctx, tm, our_goalie, self_facing, ctx.caps_by_peer.get(pid))
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
		our_goalie: Vector3, self_facing_xz: Vector2,
		receiver_caps: AISkaterCaps = null) -> float:
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
	var rotation_time: float = _facing_rotation_time(self_facing_xz, ctx.self_pos, spot,
			ctx.self_reach_cone_half_angle, ctx.self_facing_turn_rate)
	return _pass_ev(ctx, spot, pass_speed, flight_t, release_t,
			flight_t + rotation_time, our_goalie, receiver_caps)


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
# Where a pass physically leaves from: the carried puck (riding the blade, up
# to a stick's reach from the body), falling back to the body center when the
# snapshot has no puck. Mirrors the shot model's puck-origin release ref: the
# lead solve, the friction-compensated launch speed, and the net/lane checks
# all measure the real flight, not a flight from the passer's chest — on a
# close feed the ~1 m origin error was a systematic over-lead.
func _pass_origin(ctx: RoleContext) -> Vector3:
	if ctx.snapshot.puck_state != null:
		return Vector3(
				ctx.snapshot.puck_state.position.x, 0.0,
				ctx.snapshot.puck_state.position.z)
	return ctx.self_pos


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
