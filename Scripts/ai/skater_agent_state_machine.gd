class_name SkaterAgentStateMachine
extends RefCounted

# Per-bot AI state machine. Mirrors the dispatch + match + per-state handler
# pattern used by Scripts/controllers/skater_state_machine.gd. Owned by
# SkaterAgent; the agent owns the InputState scratch buffer and the
# AIController glue, the SM owns identity + state transitions + per-state
# behavior.
#
# Adding a new behavior (PASS, DUMP, PROTECT) is a clean four-step recipe:
#   1. Append a State enum value
#   2. Add a match arm in dispatch()
#   3. Write the _state_<name> handler
#   4. Decide where the transition into it happens (usually a transition
#      check inside _state_carry)
#
# State graph (today):
#                          ┌─ no puck ─────────────────────┐
#                          │                               │
#       OFF_PUCK ◄──────────► CHASE_PUCK (F1 only) ────────│
#          │                       │                       │
#          │  picks up puck        │  picks up puck        │
#          ▼                       ▼                       │
#         CARRY ──[in OZ + quiet-eye expired]──► SHOOT_PRESSED
#          ▲                                          │
#          └──────────────────────────────────────────┘
#                  (next tick, release fires)

enum State {
	OFF_PUCK,        # default off-puck — anchor above puck, aim at goal
	CHASE_PUCK,      # F1 without puck — pursue, blade on the puck
	CARRY,           # with puck, no committed action — aim at goal
	SHOOT_PRESSED,   # one-tick press window aimed at goalie shadow
	PASS_PRESSED,    # one-tick press window aimed at a teammate's lead position
	DUMP_PRESSED,    # one-tick press window aimed at a deep-zone clear
}

# Off-puck anchor offsets. F2 is the triangle apex on the strong side
# (puck's X side), 3 m off the puck X-wise and 2 m back toward our own
# goal Z-wise. F3 is the weak-side trailer, 5 m mirrored across the
# puck X and 8 m back. The legacy OFF anchor (no F2/F3 role assigned —
# 4+ teammates case) keeps the original above-puck behavior.
const F2_OFFSET_X: float = 3.0
const F2_OFFSET_Z_BACK: float = 2.0
const F3_OFFSET_X_WEAK: float = 5.0
const F3_OFFSET_Z_BACK: float = 8.0
const LEGACY_OFF_DEPTH: float = 4.0
# Man-to-man gap: defender anchors this far on the goal-side of their
# mark, on the line from mark → our net.
const MAN_GAP_DEPTH_M: float = 1.0
# Lead time for predicting mark position. Defender anchors against where
# the mark WILL BE, not where they are right now — without this, the
# defender is always trailing a step behind a moving forward.
const MAN_LEAD_TIME_S: float = 0.5
# Strong-side X is sign(puck.x), but only when the puck is meaningfully
# off-center; below this we default to the +X side so we don't flip
# F2/F3 sides every time the puck wiggles through center.
const STRONG_SIDE_X_DEADBAND: float = 0.5
# Margins from the rink edge / goal line that anchors are clamped inside of.
const RINK_X_INSET: float = 0.5
const RINK_Z_INSET: float = 1.0

const QUIET_EYE_TICKS: int = 8
# Per-tick blend rate for action-score smoothing. The bot polls scores
# every physics tick (240Hz) but commits on the SMOOTHED score, not the
# raw one — so a one-frame flash of openness doesn't fire a shot. With
# α=0.01 a perfect (raw=1.0) opportunity crosses ACTION_THRESHOLD after
# ~120ms and saturates near 1.0 after ~700ms. A mediocre raw=0.4 score
# plateaus around 0.4 and never crosses threshold, which is what we
# want. EMAs reset on entering CARRY so confidence doesn't bleed
# across possessions.
const SCORE_EMA_ALPHA: float = 0.01
# How wide the goalie's shadow on the net plane should be considered
# (meters, half-width). Tuneable in playtest.
const GOALIE_SHADOW_HALF: float = 0.3
# How far in front of the goal line the carrier sits when they reach the
# offensive zone — high slot, not in the cage.
const SLOT_DEPTH_FROM_GOAL_LINE: float = 5.0
# Reference puck speed for pass leading. Lead time = distance to receiver
# / this constant — a longer pass leads further because it takes longer
# to arrive. Approximate quick-wrister puck speed; doesn't have to be
# perfect, small over/under just shifts the aim point a few cm.
const PASS_PUCK_SPEED_REF_M_S: float = 22.0
# Cap on pass lead so a degenerate state (zero pass speed estimate, or a
# long bomb across the rink) doesn't project the receiver into next week.
const PASS_LEAD_MAX_S: float = 0.6
# DUMP aim — deep into the attacking zone, on the bot's strong side.
# DUMP_CORNER_X is the absolute X of the dump target (corner area).
# DUMP_DEPTH_FROM_GOAL_M is how far in front of the attacking goal line
# the dump lands (deep-zone corner, far from the net so the goalie
# can't easily glove it).
const DUMP_CORNER_X: float = 8.0
const DUMP_DEPTH_FROM_GOAL_M: float = 6.0
# After a puck-engagement event (we got stripped, or we just stripped
# someone — both detected as "puck became loose while we were close"),
# pull the blade back to our body for this many ticks. Speed-scaled:
# a bot at full skating speed was committed harder and takes longer
# to reset; a slow bot recovers quickly. The variance breaks lockstep
# between two bots involved in the same engagement (their speeds are
# almost never identical).
const ENGAGEMENT_COOLDOWN_MIN_TICKS: int = 24    # ~100 ms at 240 Hz
const ENGAGEMENT_COOLDOWN_MAX_TICKS: int = 96    # ~400 ms at 240 Hz
const ENGAGEMENT_SPEED_REF_M_S: float = 10.5     # SkaterController.max_speed default
const ENGAGEMENT_PROXIMITY_M: float = 2.0        # blade-on-puck range

# Reference top skating speed used for chase intercept lookahead. Doesn't
# need to match SkaterController exactly — small over/under shifts where
# the intercept point lands but doesn't break behavior.
const CHASE_SPEED_REF_M_S: float = 10.5
# Cap on lead lookahead so a barely-moving puck doesn't project an
# intercept point a million seconds away.
const CHASE_MAX_LOOKAHEAD_S: float = 1.5
# Steps per chase trajectory walk. Granular enough that the rink clamp
# catches a sliding puck hitting the boards mid-flight (so we don't aim
# at a point inside the wall), cheap enough at 6 Hz brain tick.
const CHASE_TRAJECTORY_STEPS: int = 12

# Carrier anchor search step. The carrier samples candidate positions
# this far from their current spot in 8 cardinal directions and picks
# the one with the best shoot-or-pass score. Bot drifts toward the
# best-option spot tick by tick — no teleporting, just gradient
# follow.
const CARRY_SEARCH_STEP_M: float = 3.0
# Margin from the attacking goal line we won't drift past while
# searching (carrier shouldn't anchor behind the net).
const CARRY_GOAL_LINE_BUFFER_M: float = 1.0

# Lead time for the carrier endpoint of the shot-lane repel. Off-puck
# bots step out of the FUTURE shooting lane, not the current one — by
# the time our steering moves us, the carrier has skated forward and
# the lane has rotated. Short window; long leads put the lane in the
# wrong zone entirely.
const SHOT_LANE_LEAD_TIME_S: float = 0.25

# Blade-reach radius. Inside this distance the bot's stick can already
# reach the puck where it actually is, so the blade IK should aim at
# the puck's CURRENT position instead of the lead intercept — otherwise
# the blade rides 0.5 m past a puck that's right at our feet and we
# fan on it. Steering still uses the lead so the body keeps closing.
# A bit larger than blade_length + stick_length (≈1.6 m) so the snap
# kicks in slightly before the blade actually arrives.
const BLADE_REACH_M: float = 1.8

# ── Owned state ──────────────────────────────────────────────────────────────
var _state: State = State.OFF_PUCK
var _ticks_in_state: int = 0

# Identity / orientation
var _peer_id: int = 0
var _team_id: int = 0
# +1 if own goal is at +GOAL_LINE_Z (Team 0), -1 for Team 1.
# See LocalController.get_attacking_goal_z for the source of truth.
var _own_goal_dir: float = 1.0
var _attacking_goal_pos: Vector3 = Vector3.ZERO
var _team_brain: TeamBrain = null
var _team_id_resolver: Callable = Callable()

# Reused buffer for steering's teammate-position list. Cleared at the top
# of each _apply_steering call.
var _scratch_teammates: Array[Vector3] = []
# Reused buffer for action scoring's opponent-position list. Cleared at
# the top of _pick_action.
var _scratch_opponents: Array[Vector3] = []

# Set when CARRY commits to PASS_PRESSED; consumed by _state_pass_pressed
# the next tick. 0 means "no current pass target" (real peer_ids are
# either 1+ for humans or 10000+ for bots, so 0 is safe as sentinel).
var _pass_target_peer_id: int = 0

# Engagement cooldown — see ENGAGEMENT_COOLDOWN_TICKS. _prev_carrier
# tracks last tick's puck.carrier_peer_id so we can detect the
# transition into "loose".
var _engagement_cooldown: int = 0
var _prev_carrier_peer_id: int = -1

# Smoothed action scores. Updated each _pick_action tick by lerping
# toward the raw score at SCORE_EMA_ALPHA. Decision threshold + argmax
# run on these, not the raw scores. Reset on CARRY entry so a fresh
# possession doesn't inherit confidence from the previous one.
var _shoot_ema: float = 0.0
var _dump_ema: float = 0.0
# peer_id -> smoothed pass score. One entry per teammate; we update
# every observed teammate each tick and pick the peer with the highest
# smoothed score. Per-peer (not "best pass overall") so leader changes
# don't poison the EMA — switching from receiver A to receiver B
# starts B's confidence at 0, not at A's plateau.
var _pass_ema: Dictionary = {}


# ── Setup ────────────────────────────────────────────────────────────────────

func setup(peer_id: int, team_id: int, brain: TeamBrain, resolver: Callable) -> void:
	_peer_id = peer_id
	_team_id = team_id
	_own_goal_dir = 1.0 if team_id == 0 else -1.0
	# Aim point at the opposing goal mouth. Used as fallback aim and as
	# the net plane for shot-aim geometry. y=0 — blade IK is 2D for now.
	_attacking_goal_pos = Vector3(0.0, 0.0, -_own_goal_dir * GameRules.GOAL_LINE_Z)
	_team_brain = brain
	_team_id_resolver = resolver


# ── State accessors ──────────────────────────────────────────────────────────

func get_state() -> State:
	return _state


# ── Dispatch ─────────────────────────────────────────────────────────────────

# Caller (SkaterAgent) is responsible for zeroing `input` before this call.
# We fill move_vector / mouse_world_pos / shoot flags based on _state.
func dispatch(input: InputState, snapshot: WorldSnapshot) -> void:
	if snapshot == null or snapshot.puck_state == null or snapshot.skater_states.is_empty():
		_reset_to_off_puck()
		return
	var self_state: SkaterNetworkState = snapshot.skater_states.get(_peer_id)
	if self_state == null:
		# Snapshot pre-dates this bot's spawn; freeze for one tick.
		_reset_to_off_puck()
		return

	var self_pos: Vector3 = self_state.position
	var have_puck: bool = (snapshot.puck_state.carrier_peer_id == _peer_id)
	_ticks_in_state += 1
	_update_engagement_cooldown(snapshot, self_state)

	match _state:
		State.OFF_PUCK:
			_state_off_puck(input, snapshot, self_pos, have_puck)
		State.CHASE_PUCK:
			_state_chase_puck(input, snapshot, self_pos, have_puck)
		State.CARRY:
			_state_carry(input, snapshot, self_pos, have_puck)
		State.SHOOT_PRESSED:
			_state_shoot_pressed(input, snapshot, self_pos, have_puck)
		State.PASS_PRESSED:
			_state_pass_pressed(input, snapshot, self_pos, have_puck)
		State.DUMP_PRESSED:
			_state_dump_pressed(input, snapshot, self_pos, have_puck)


# ── State handlers ───────────────────────────────────────────────────────────

func _state_off_puck(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, have_puck: bool) -> void:
	# Anchor depends on role: F2 strong-side support, F3 weak-side trailer,
	# or legacy "above puck" for any unassigned role (4+ teammate case).
	var anchor: Vector3 = _off_puck_anchor(snapshot.puck_state.position, self_pos, snapshot)
	_apply_steering(input, snapshot, self_pos, anchor)
	input.mouse_world_pos = _attacking_goal_pos
	# Transitions
	if have_puck:
		_set_state(State.CARRY)
	elif _is_f1() and not _teammate_has_puck(snapshot):
		_set_state(State.CHASE_PUCK)


func _state_chase_puck(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, have_puck: bool) -> void:
	# Lead intercept: aim at where the puck WILL be when we'd actually
	# arrive, not at where it is now. Per-bot t_arrival (distance / max
	# speed) means two bots converging on the same loose puck compute
	# different intercept points, breaking the "both glued to the same
	# puck position" pattern.
	var puck_pos: Vector3 = snapshot.puck_state.position
	var target: Vector3 = _lead_intercept(self_pos, puck_pos, snapshot.puck_state.velocity)
	_apply_steering(input, snapshot, self_pos, target)
	# Aim: normally blade-on-intercept, but during the engagement cooldown
	# (just got stripped or just stick-checked someone) pull the blade
	# back to our body so the puck can settle without auto-magnetting
	# back to us. Once the puck is inside our blade reach, snap the aim
	# to the puck's ACTUAL position — leading at this range puts the
	# blade past a puck that's already on our stick.
	if _engagement_cooldown > 0:
		input.mouse_world_pos = Vector3(self_pos.x, 0.0, self_pos.z)
	elif self_pos.distance_to(puck_pos) <= BLADE_REACH_M:
		input.mouse_world_pos = puck_pos
	else:
		input.mouse_world_pos = target
	# Transitions
	if have_puck:
		_set_state(State.CARRY)
	elif not _is_f1() or _teammate_has_puck(snapshot):
		# Either we're not F1 anymore, or a teammate just picked up the
		# puck — in both cases, drop back to off-puck support instead of
		# pinning our blade to the puck on our own teammate's stick.
		_set_state(State.OFF_PUCK)


func _state_carry(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, have_puck: bool) -> void:
	# In NZ/DZ, drive toward the high slot to enter the offensive zone.
	# Once in OZ, search for the position with the best shot/pass option
	# and drift toward it — patient cycling.
	var anchor: Vector3 = _carry_anchor(snapshot, self_pos)
	_apply_steering(input, snapshot, self_pos, anchor)
	input.mouse_world_pos = _shot_aim_point(snapshot, self_pos)
	# Transitions
	if not have_puck:
		_set_state(_post_puck_lost_state())
		return
	if _ticks_in_state < QUIET_EYE_TICKS:
		return
	# Quiet-eye expired — pick the highest-scoring action. CARRY is the
	# implicit default if nothing clears the threshold (set elsewhere as
	# AIActionScoring.ACTION_THRESHOLD).
	_pick_action(snapshot, self_pos)


func _state_shoot_pressed(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, have_puck: bool) -> void:
	_apply_slot_steering(input, snapshot, self_pos)
	input.mouse_world_pos = _shot_aim_point(snapshot, self_pos)
	# Press flags. SkaterStateMachine handles SKATING_WITH_PUCK +
	# shoot_pressed → WRISTER_AIM, then next tick (back in CARRY here)
	# shoot_held=false fires release_wrister.
	input.shoot_pressed = true
	input.shoot_held = true
	# Transitions: always exits next tick. Losing the puck mid-sequence
	# (e.g., body-checked) drops us to chase/off straight away.
	if not have_puck:
		_set_state(_post_puck_lost_state())
	else:
		_set_state(State.CARRY)


func _state_pass_pressed(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, have_puck: bool) -> void:
	_apply_slot_steering(input, snapshot, self_pos)
	# Aim at the receiver's lead position. Quick-shot direction is
	# blade-from-player at release, and the blade IK swings toward
	# mouse_world_pos — so this fires the puck along the bot→receiver
	# vector.
	input.mouse_world_pos = _pass_aim_point(snapshot, self_pos)
	input.shoot_pressed = true
	input.shoot_held = true
	# Same one-tick-then-exit pattern as SHOOT_PRESSED. Clear the target
	# either way so a future PASS picks a fresh one.
	_pass_target_peer_id = 0
	if not have_puck:
		_set_state(_post_puck_lost_state())
	else:
		_set_state(State.CARRY)


func _state_dump_pressed(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, have_puck: bool) -> void:
	_apply_slot_steering(input, snapshot, self_pos)
	# Aim at a deep corner of the attacking zone on our strong side —
	# typical hockey "dump it deep, chase it down." Quick-shot direction
	# is blade-from-player so the puck flies along the bot→corner
	# vector; even at fixed quick_shot_power the dump usually clears
	# the bot's zone, which is what matters.
	input.mouse_world_pos = _dump_aim_point(self_pos)
	input.shoot_pressed = true
	input.shoot_held = true
	if not have_puck:
		_set_state(_post_puck_lost_state())
	else:
		_set_state(State.CARRY)


# ── Internal helpers ─────────────────────────────────────────────────────────

# Anchor + steering shared by CARRY / SHOOT_PRESSED / PASS_PRESSED. Each
# state sets `input.mouse_world_pos` itself because the aim differs
# (goal-shadow vs receiver lead).
func _apply_slot_steering(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3) -> void:
	var slot_z: float = -_own_goal_dir * (GameRules.GOAL_LINE_Z - SLOT_DEPTH_FROM_GOAL_LINE)
	_apply_steering(input, snapshot, self_pos, Vector3(0.0, 0.0, slot_z))


# Score every applicable action and transition into the highest-scoring
# state. CARRY is the implicit default — if neither SHOOT nor any PASS
# clears AIActionScoring.ACTION_THRESHOLD we stay in CARRY without
# transitioning (next tick re-evaluates).
#
# Mutates _pass_target_peer_id when PASS wins.
func _pick_action(snapshot: WorldSnapshot, self_pos: Vector3) -> void:
	# Build opponents list once for shoot scoring + receiver pressure.
	_scratch_opponents.clear()
	for peer_id: int in snapshot.skater_states:
		if int(_team_id_resolver.call(peer_id)) != _team_id and peer_id != _peer_id:
			_scratch_opponents.append(snapshot.skater_states[peer_id].position)

	# SHOOT score — at most one. Falls back to attacking_goal_pos if no
	# opposing goalie is buffered (e.g., first-frame edge case).
	var goalie_pos: Vector3 = _attacking_goal_pos
	var opp_team_id: int = 1 - _team_id
	var opp_goalie: GoalieNetworkState = snapshot.goalie_states.get(opp_team_id)
	if opp_goalie != null:
		goalie_pos = Vector3(opp_goalie.position_x, 0.0, opp_goalie.position_z)
	var shoot_score: float = AIActionScoring.score_shoot(
			self_pos, _attacking_goal_pos, goalie_pos,
			GameRules.NET_HALF_WIDTH, GOALIE_SHADOW_HALF,
			_scratch_opponents)

	# PASS scores — one per teammate, EMA per peer. Track best smoothed.
	var best_pass_peer: int = 0
	var best_pass_smoothed: float = 0.0
	for peer_id: int in snapshot.skater_states:
		if peer_id == _peer_id:
			continue
		if int(_team_id_resolver.call(peer_id)) != _team_id:
			continue
		var receiver: Vector3 = snapshot.skater_states[peer_id].position
		var raw: float = AIActionScoring.score_pass(
				self_pos, receiver, _attacking_goal_pos, goalie_pos,
				GameRules.NET_HALF_WIDTH, GOALIE_SHADOW_HALF,
				_scratch_opponents)
		var prev: float = _pass_ema.get(peer_id, 0.0)
		var smoothed: float = lerpf(prev, raw, SCORE_EMA_ALPHA)
		_pass_ema[peer_id] = smoothed
		if smoothed > best_pass_smoothed:
			best_pass_smoothed = smoothed
			best_pass_peer = peer_id

	# DUMP score — fires when pressured + far from attacking goal. Pure
	# function of pressure and zone, doesn't compete on shot/pass quality.
	var dump_raw: float = AIActionScoring.score_dump(
			self_pos, _attacking_goal_pos, _own_goal_dir,
			GameRules.BLUE_LINE_Z, _scratch_opponents)

	# Smooth the binary action scores. Pass EMAs were updated inline
	# above to keep the per-peer dictionary mutation in one place.
	_shoot_ema = lerpf(_shoot_ema, shoot_score, SCORE_EMA_ALPHA)
	_dump_ema = lerpf(_dump_ema, dump_raw, SCORE_EMA_ALPHA)

	# Pick the winner from SMOOTHED scores. Threshold gates "do nothing" —
	# a one-tick flash of openness can't accumulate enough EMA to fire,
	# which is the whole point of smoothing.
	var max_score: float = maxf(maxf(_shoot_ema, best_pass_smoothed), _dump_ema)
	if max_score < AIActionScoring.ACTION_THRESHOLD:
		return
	if _shoot_ema >= best_pass_smoothed and _shoot_ema >= _dump_ema:
		_set_state(State.SHOOT_PRESSED)
	elif best_pass_smoothed >= _dump_ema:
		_pass_target_peer_id = best_pass_peer
		_set_state(State.PASS_PRESSED)
	else:
		_set_state(State.DUMP_PRESSED)


# Lead the receiver by their flight-time along their current velocity.
# Long passes lead further than short ones — the puck takes longer to
# arrive, so the receiver moves further during transit. Falls back to
# the goal if the target slot disappeared between picking and pressing
# (rare — bot demoted, peer disconnected, etc.).
func _pass_aim_point(snapshot: WorldSnapshot, self_pos: Vector3) -> Vector3:
	var receiver: SkaterNetworkState = snapshot.skater_states.get(_pass_target_peer_id)
	if receiver == null:
		return _attacking_goal_pos
	# Flight time estimate — distance to receiver / pass speed. Capped so
	# a degenerate near-zero-speed estimate can't blow up the lead.
	var dist: float = self_pos.distance_to(receiver.position)
	var flight_t: float = clampf(
			dist / PASS_PUCK_SPEED_REF_M_S, 0.0, PASS_LEAD_MAX_S)
	return AITrajectory.predict_at(receiver.position, receiver.velocity, flight_t)


func _apply_steering(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, anchor: Vector3) -> void:
	# Single-pass split into teammate vs opponent buckets — both feed
	# AISteering's repel forces.
	_scratch_teammates.clear()
	_scratch_opponents.clear()
	for peer_id: int in snapshot.skater_states:
		if peer_id == _peer_id:
			continue
		if int(_team_id_resolver.call(peer_id)) == _team_id:
			_scratch_teammates.append(snapshot.skater_states[peer_id].position)
		else:
			_scratch_opponents.append(snapshot.skater_states[peer_id].position)

	# Shot-lane endpoints: only set when a teammate (not us, not opp) is
	# the carrier — keeps off-puck bots out of the carrier's lane to the
	# attacking goal. Carrier-side bots pass zero (they aren't repelled
	# from their own lane).
	var lane_start: Vector3 = Vector3.ZERO
	var lane_end: Vector3 = Vector3.ZERO
	var carrier: int = snapshot.puck_state.carrier_peer_id
	if carrier != -1 and carrier != _peer_id:
		if int(_team_id_resolver.call(carrier)) == _team_id:
			var carrier_state: SkaterNetworkState = snapshot.skater_states.get(carrier)
			if carrier_state != null:
				# Lead the carrier — the lane we want to clear is where
				# they'll shoot from, not where they are right now.
				lane_start = AITrajectory.predict_at(
						carrier_state.position, carrier_state.velocity,
						SHOT_LANE_LEAD_TIME_S)
				lane_end = _attacking_goal_pos

	input.move_vector = AISteering.compute_move_vector(
			self_pos, anchor, _scratch_teammates, _scratch_opponents,
			lane_start, lane_end,
			GameRules.RINK_HALF_WIDTH, GameRules.RINK_HALF_LENGTH)


# Shot aim past the goalie's projected shadow. Falls back to goal center
# if the opposing goalie state isn't buffered yet.
func _shot_aim_point(snapshot: WorldSnapshot, self_pos: Vector3) -> Vector3:
	var opp_team_id: int = 1 - _team_id
	var opp_goalie: GoalieNetworkState = snapshot.goalie_states.get(opp_team_id)
	if opp_goalie == null:
		return _attacking_goal_pos
	var goalie_pos := Vector3(opp_goalie.position_x, 0.0, opp_goalie.position_z)
	return AIShotAim.compute_open_net_aim(
			self_pos, goalie_pos,
			_attacking_goal_pos.z,
			GameRules.NET_HALF_WIDTH,
			GOALIE_SHADOW_HALF)


func _is_f1() -> bool:
	return _team_brain != null and _team_brain.get_role(_peer_id) == AIRoleAssignment.ROLE_F1


# Off-puck anchor selection.
#   - DZ + opp possession (or loose puck in DZ): switch to man-to-man.
#     F2/F3 anchor on their assigned mark, 1 m goal-side.
#   - Otherwise: zone-ish triangle. F2 strong-side support, F3 weak-side
#     trailer, OFF (4+ teammate fallback) plays legacy above-puck.
func _off_puck_anchor(puck_pos: Vector3, self_pos: Vector3, snapshot: WorldSnapshot) -> Vector3:
	# Man-to-man takes priority in our defensive zone when the opp has
	# the puck (or it's loose in our zone). The brain publishes the
	# coverage map at 6 Hz; we just look up our mark.
	if _should_play_man_to_man(snapshot):
		var mark_pid: int = _team_brain.get_coverage_target(_peer_id) if _team_brain != null else 0
		if mark_pid != 0:
			var mark: SkaterNetworkState = snapshot.skater_states.get(mark_pid)
			if mark != null:
				return _man_anchor(mark)

	var role: StringName = _team_brain.get_role(_peer_id) if _team_brain != null else AIRoleAssignment.ROLE_OFF
	match role:
		AIRoleAssignment.ROLE_F2:
			return _f2_anchor(puck_pos)
		AIRoleAssignment.ROLE_F3:
			return _f3_anchor(puck_pos)
	# Legacy / fallback — Phase 3 anchor (above puck on own-net side, X
	# tracking the bot's current X to avoid sliding sideways).
	var anchor_z: float = puck_pos.z + _own_goal_dir * LEGACY_OFF_DEPTH
	return _clamp_anchor(Vector3(self_pos.x, 0.0, anchor_z))


# F2 anchor — triangle apex on the strong side (the side of the rink
# the puck is on), 3 m off the puck X and 2 m back toward our own
# goal Z. With STRONG_SIDE_X_DEADBAND we don't flip strong/weak when
# the puck wiggles through the center.
func _f2_anchor(puck_pos: Vector3) -> Vector3:
	var strong_x: float = signf(puck_pos.x) if absf(puck_pos.x) > STRONG_SIDE_X_DEADBAND else 1.0
	var x: float = puck_pos.x + strong_x * F2_OFFSET_X
	var z: float = puck_pos.z + _own_goal_dir * F2_OFFSET_Z_BACK
	return _clamp_anchor(Vector3(x, 0.0, z))


# True iff we're in our own zone defending — opp has the puck (or it's
# loose in our zone). Man-to-man only fires here; everywhere else (NZ,
# OZ, own possession) we keep the zone triangle.
func _should_play_man_to_man(snapshot: WorldSnapshot) -> bool:
	var puck_pos: Vector3 = snapshot.puck_state.position
	# In our DZ? oriented_z > BLUE_LINE_Z means past our own blue line.
	if _own_goal_dir * puck_pos.z <= GameRules.BLUE_LINE_Z:
		return false
	# Don't play man if our team has possession — that's a breakout, not
	# a defensive coverage situation. Loose pucks in our zone DO trigger
	# man (forwards are crashing, mark them).
	var carrier: int = snapshot.puck_state.carrier_peer_id
	if carrier != -1 and int(_team_id_resolver.call(carrier)) == _team_id:
		return false
	return true


# Man-to-man anchor: MAN_GAP_DEPTH_M off the mark along the line from
# the mark's PREDICTED position to our own net. Body shades the actual
# lane to net regardless of where the mark is on the ice (a mark out
# by the boards still gets shaded toward center, not just behind on
# Z). Predicting MAN_LEAD_TIME_S ahead means a moving forward doesn't
# slip past the defender — the defender anchors against where the
# mark will be by the time they arrive.
func _man_anchor(mark: SkaterNetworkState) -> Vector3:
	var lead_pos: Vector3 = AITrajectory.predict_at(
			mark.position, mark.velocity, MAN_LEAD_TIME_S)
	var our_net := Vector3(0.0, 0.0, _own_goal_dir * GameRules.GOAL_LINE_Z)
	var dx: float = our_net.x - lead_pos.x
	var dz: float = our_net.z - lead_pos.z
	var dist: float = sqrt(dx * dx + dz * dz)
	if dist < 0.001:
		# Mark sitting on top of our net — degenerate case; just anchor
		# at the lead pos and let the goalie + steering sort it out.
		return _clamp_anchor(lead_pos)
	var step: float = MAN_GAP_DEPTH_M / dist
	return _clamp_anchor(Vector3(
			lead_pos.x + dx * step, 0.0,
			lead_pos.z + dz * step))


# F3 anchor — weak-side trailer, mirrored across the puck X and 8 m
# back toward our own goal. Safety-valve role.
func _f3_anchor(puck_pos: Vector3) -> Vector3:
	var strong_x: float = signf(puck_pos.x) if absf(puck_pos.x) > STRONG_SIDE_X_DEADBAND else 1.0
	var weak_x: float = -strong_x
	var x: float = puck_pos.x + weak_x * F3_OFFSET_X_WEAK
	var z: float = puck_pos.z + _own_goal_dir * F3_OFFSET_Z_BACK
	return _clamp_anchor(Vector3(x, 0.0, z))


# Clamp an anchor to the playable rink with a small margin so steering
# doesn't pull the bot into the boards or behind the goal line.
func _clamp_anchor(p: Vector3) -> Vector3:
	var x: float = clampf(p.x,
			-GameRules.RINK_HALF_WIDTH + RINK_X_INSET,
			GameRules.RINK_HALF_WIDTH - RINK_X_INSET)
	var z: float = clampf(p.z,
			-GameRules.GOAL_LINE_Z + RINK_Z_INSET,
			GameRules.GOAL_LINE_Z - RINK_Z_INSET)
	# Push out of either crease — bots shouldn't anchor inside a goalie's
	# space. Steering's crease repel is the runtime force; this is the
	# destination-side guard so the anchor doesn't actively PULL the bot
	# into the crease in the first place.
	var xz := Vector2(x, z)
	if CreaseRules.is_in_crease(xz):
		var dir: Vector2 = CreaseRules.outward_direction(xz)
		var goal_z: float = signf(xz.y) * GameRules.GOAL_LINE_Z
		var center := Vector2(0.0, goal_z)
		var pushed: Vector2 = center + dir * (CreaseRules.ARC_RADIUS + RINK_Z_INSET)
		x = pushed.x
		z = pushed.y
	return Vector3(x, 0.0, z)


# Carrier anchor. In NZ/DZ, drive toward the high slot. Once in OZ,
# search nearby for the position with the best shoot-or-pass option
# (8 cardinal directions × CARRY_SEARCH_STEP_M plus stay-here).
func _carry_anchor(snapshot: WorldSnapshot, self_pos: Vector3) -> Vector3:
	if -_own_goal_dir * self_pos.z <= GameRules.BLUE_LINE_Z:
		var slot_z: float = -_own_goal_dir * (GameRules.GOAL_LINE_Z - SLOT_DEPTH_FROM_GOAL_LINE)
		return Vector3(0.0, 0.0, slot_z)
	return _find_best_carry_position(snapshot, self_pos)


func _find_best_carry_position(snapshot: WorldSnapshot, self_pos: Vector3) -> Vector3:
	var goalie_pos: Vector3 = _attacking_goal_pos
	var opp_goalie: GoalieNetworkState = snapshot.goalie_states.get(1 - _team_id)
	if opp_goalie != null:
		goalie_pos = Vector3(opp_goalie.position_x, 0.0, opp_goalie.position_z)

	# Refresh the scratch lists. _pick_action would also populate
	# _scratch_opponents but it runs later in the same tick (after
	# QUIET_EYE_TICKS) so we can't rely on its state. Rebuild here.
	_scratch_opponents.clear()
	var teammates: Array[Vector3] = []
	for peer_id: int in snapshot.skater_states:
		if peer_id == _peer_id:
			continue
		if int(_team_id_resolver.call(peer_id)) == _team_id:
			teammates.append(snapshot.skater_states[peer_id].position)
		else:
			_scratch_opponents.append(snapshot.skater_states[peer_id].position)

	# Score current position as the baseline; only move if a candidate
	# beats it.
	var best_pos: Vector3 = self_pos
	var best_score: float = AIActionScoring.carry_position_score(
			self_pos, _attacking_goal_pos, goalie_pos,
			GameRules.NET_HALF_WIDTH, GOALIE_SHADOW_HALF,
			teammates, _scratch_opponents)

	# 8 cardinal/diagonal directions. Pre-baked so we don't recompute
	# trig each tick.
	const SQRT2_INV: float = 0.70710678
	const DIRS: Array[Vector2] = [
			Vector2(1, 0), Vector2(SQRT2_INV, SQRT2_INV),
			Vector2(0, 1), Vector2(-SQRT2_INV, SQRT2_INV),
			Vector2(-1, 0), Vector2(-SQRT2_INV, -SQRT2_INV),
			Vector2(0, -1), Vector2(SQRT2_INV, -SQRT2_INV),
	]
	for d: Vector2 in DIRS:
		var candidate := Vector3(
				self_pos.x + d.x * CARRY_SEARCH_STEP_M, 0.0,
				self_pos.z + d.y * CARRY_SEARCH_STEP_M)
		# Don't drift back into the neutral zone or past the attacking
		# goal line. RINK_X_INSET keeps us off the boards.
		if -_own_goal_dir * candidate.z <= GameRules.BLUE_LINE_Z:
			continue
		if absf(candidate.z) > absf(_attacking_goal_pos.z) - CARRY_GOAL_LINE_BUFFER_M:
			continue
		if absf(candidate.x) > GameRules.RINK_HALF_WIDTH - RINK_X_INSET:
			continue
		var s: float = AIActionScoring.carry_position_score(
				candidate, _attacking_goal_pos, goalie_pos,
				GameRules.NET_HALF_WIDTH, GOALIE_SHADOW_HALF,
				teammates, _scratch_opponents)
		if s > best_score:
			best_score = s
			best_pos = candidate
	return best_pos


# Dump target — deep corner of the attacking zone on the bot's strong
# side. Quick-shot direction is blade-from-player so the puck fires
# along the bot→corner vector, sliding into the deep zone where a
# forechecker can chase it down.
func _dump_aim_point(self_pos: Vector3) -> Vector3:
	var strong_x: float = signf(self_pos.x) if absf(self_pos.x) > STRONG_SIDE_X_DEADBAND else 1.0
	var deep_z: float = _attacking_goal_pos.z + _own_goal_dir * DUMP_DEPTH_FROM_GOAL_M
	return Vector3(strong_x * DUMP_CORNER_X, 0.0, deep_z)


# Walk the puck's predicted trajectory and pick the earliest step where
# we could actually reach the puck. The earliest reachable step is the
# best intercept — any later step the puck has slid further past us, any
# earlier step we wouldn't have arrived yet. Trajectory walk also gives
# us free rink-clamping (a sliding puck heading into corner boards no
# longer projects an intercept inside the wall) and a single seam to
# add puck friction later. Falls back to the puck's current position
# when no step is reachable in the lookahead window.
func _lead_intercept(self_pos: Vector3, puck_pos: Vector3, puck_vel: Vector3) -> Vector3:
	var dt: float = CHASE_MAX_LOOKAHEAD_S / float(CHASE_TRAJECTORY_STEPS)
	var traj: Array[Vector3] = AITrajectory.predict(
			puck_pos, puck_vel, CHASE_TRAJECTORY_STEPS, dt)
	for i: int in traj.size():
		var t_step: float = (i + 1) * dt
		var reach: float = self_pos.distance_to(traj[i])
		if reach <= CHASE_SPEED_REF_M_S * t_step:
			return traj[i]
	# Puck is moving away faster than we can chase — aim at the last
	# projected position so we at least head in the right direction.
	return traj[traj.size() - 1] if traj.size() > 0 else puck_pos


# True iff a TEAMMATE (not me, not opp) currently has the puck. Used to
# suppress CHASE_PUCK so non-carrier bots don't sprint at their own
# teammate carrier with their blade out.
func _teammate_has_puck(snapshot: WorldSnapshot) -> bool:
	var carrier: int = snapshot.puck_state.carrier_peer_id
	if carrier == -1 or carrier == _peer_id:
		return false
	return int(_team_id_resolver.call(carrier)) == _team_id


# Where to drop into when the puck is lost mid-on-puck-state. F1s chase,
# everyone else holds the above-puck anchor.
func _post_puck_lost_state() -> State:
	return State.CHASE_PUCK if _is_f1() else State.OFF_PUCK


# Detects "puck just became loose" and arms the engagement cooldown if
# we were close enough to be involved. Single rule covers both sides:
#   - We had the puck and got stripped: prev=us, now=-1, distance≈0
#   - We stick-checked someone: prev=opp, now=-1, we were near to do it
# The carrier-just-changed-to-someone-else case (a teammate or opp picked
# up cleanly without us being close) doesn't fire — prev was set, now
# is the new carrier, not -1.
#
# Cooldown duration scales with our skating speed at the moment of
# engagement: a bot moving at full speed was committed harder and takes
# longer to reset; a near-stationary bot recovers fast. Two bots in the
# same engagement almost never have identical speeds, so this also
# breaks the lockstep that made bots re-engage in unison.
func _update_engagement_cooldown(snapshot: WorldSnapshot, self_state: SkaterNetworkState) -> void:
	var carrier: int = snapshot.puck_state.carrier_peer_id
	if _prev_carrier_peer_id != -1 and carrier == -1:
		var self_pos: Vector3 = self_state.position
		var puck_pos: Vector3 = snapshot.puck_state.position
		var dx: float = puck_pos.x - self_pos.x
		var dz: float = puck_pos.z - self_pos.z
		if dx * dx + dz * dz < ENGAGEMENT_PROXIMITY_M * ENGAGEMENT_PROXIMITY_M:
			var v: Vector3 = self_state.velocity
			var speed: float = sqrt(v.x * v.x + v.z * v.z)
			var ratio: float = clampf(speed / ENGAGEMENT_SPEED_REF_M_S, 0.0, 1.0)
			_engagement_cooldown = int(round(lerpf(
					float(ENGAGEMENT_COOLDOWN_MIN_TICKS),
					float(ENGAGEMENT_COOLDOWN_MAX_TICKS),
					ratio)))
	_prev_carrier_peer_id = carrier
	if _engagement_cooldown > 0:
		_engagement_cooldown -= 1


func _set_state(s: State) -> void:
	if s != _state:
		# Entering CARRY = start of a new look at the world. Wipe smoothed
		# scores so the bot has to re-confirm any option from scratch.
		# (Re-entering CARRY from SHOOT_PRESSED / PASS_PRESSED also resets,
		# which is fine — those exits already mean we just released the
		# puck or are about to.)
		if s == State.CARRY:
			_shoot_ema = 0.0
			_dump_ema = 0.0
			_pass_ema.clear()
		_state = s
		_ticks_in_state = 0


func _reset_to_off_puck() -> void:
	_state = State.OFF_PUCK
	_ticks_in_state = 0
	_pass_target_peer_id = 0
