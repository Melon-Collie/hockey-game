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
}

const ANCHOR_DEPTH: float = 4.0
const QUIET_EYE_TICKS: int = 8
# How wide the goalie's shadow on the net plane should be considered
# (meters, half-width). Tuneable in playtest.
const GOALIE_SHADOW_HALF: float = 0.3
# How far in front of the goal line the carrier sits when they reach the
# offensive zone — high slot, not in the cage.
const SLOT_DEPTH_FROM_GOAL_LINE: float = 5.0
# Pass to a teammate only if they're at least this much closer to the
# opposing goal than us. Prevents marginal "0.2 m better" passes that
# would just be churn.
const PASS_DISTANCE_ADVANTAGE_M: float = 3.0
# Lead time when aiming a pass — extrapolate the receiver's position by
# this many seconds along their current velocity. Ballpark for a quick
# wrister at typical pass distances; tune in playtest.
const PASS_LEAD_TIME_S: float = 0.3

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

# Set when CARRY commits to PASS_PRESSED; consumed by _state_pass_pressed
# the next tick. 0 means "no current pass target" (real peer_ids are
# either 1+ for humans or 10000+ for bots, so 0 is safe as sentinel).
var _pass_target_peer_id: int = 0


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


# ── State handlers ───────────────────────────────────────────────────────────

func _state_off_puck(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, have_puck: bool) -> void:
	# Anchor: ANCHOR_DEPTH above the puck on own-net side.
	var anchor_z: float = snapshot.puck_state.position.z + _own_goal_dir * ANCHOR_DEPTH
	anchor_z = clampf(anchor_z, -GameRules.GOAL_LINE_Z + 1.0, GameRules.GOAL_LINE_Z - 1.0)
	_apply_steering(input, snapshot, self_pos, Vector3(self_pos.x, 0.0, anchor_z))
	input.mouse_world_pos = _attacking_goal_pos
	# Transitions
	if have_puck:
		_set_state(State.CARRY)
	elif _is_f1():
		_set_state(State.CHASE_PUCK)


func _state_chase_puck(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, have_puck: bool) -> void:
	var puck_pos: Vector3 = snapshot.puck_state.position
	var target := Vector3(puck_pos.x, 0.0, puck_pos.z)
	_apply_steering(input, snapshot, self_pos, target)
	# Aim at the puck so the blade is on it at intercept time.
	input.mouse_world_pos = target
	# Transitions
	if have_puck:
		_set_state(State.CARRY)
	elif not _is_f1():
		_set_state(State.OFF_PUCK)


func _state_carry(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, have_puck: bool) -> void:
	_apply_slot_steering(input, snapshot, self_pos)
	input.mouse_world_pos = _shot_aim_point(snapshot, self_pos)
	# Transitions
	if not have_puck:
		_set_state(_post_puck_lost_state())
	elif _ticks_in_state >= QUIET_EYE_TICKS and _in_offensive_zone(self_pos):
		var pass_target: int = _pick_pass_target(snapshot, self_pos)
		if pass_target != 0:
			_pass_target_peer_id = pass_target
			_set_state(State.PASS_PRESSED)
		else:
			_set_state(State.SHOOT_PRESSED)


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
	input.mouse_world_pos = _pass_aim_point(snapshot)
	input.shoot_pressed = true
	input.shoot_held = true
	# Same one-tick-then-exit pattern as SHOOT_PRESSED. Clear the target
	# either way so a future PASS picks a fresh one.
	_pass_target_peer_id = 0
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


# Pick the best teammate to pass to. Returns the receiver's peer_id, or
# 0 if no teammate is meaningfully better positioned than us.
#
# Phase 5c heuristic: distance-to-opposing-goal only. Teammate must be
# in our offensive zone AND at least PASS_DISTANCE_ADVANTAGE_M closer
# to the goal than we are. No lane-clear check yet (that lands when
# the utility-scoring framework arrives in 5d).
func _pick_pass_target(snapshot: WorldSnapshot, self_pos: Vector3) -> int:
	var my_dist: float = self_pos.distance_to(_attacking_goal_pos)
	var best_peer: int = 0
	var best_dist: float = my_dist - PASS_DISTANCE_ADVANTAGE_M
	for peer_id: int in snapshot.skater_states:
		if peer_id == _peer_id:
			continue
		if int(_team_id_resolver.call(peer_id)) != _team_id:
			continue
		var their_pos: Vector3 = snapshot.skater_states[peer_id].position
		if not _in_offensive_zone(their_pos):
			continue
		var their_dist: float = their_pos.distance_to(_attacking_goal_pos)
		if their_dist < best_dist:
			best_dist = their_dist
			best_peer = peer_id
	return best_peer


# Lead the receiver by PASS_LEAD_TIME_S along their current velocity.
# Falls back to the goal if the target slot disappeared between picking
# and pressing (rare — bot demoted, peer disconnected, etc.).
func _pass_aim_point(snapshot: WorldSnapshot) -> Vector3:
	var receiver: SkaterNetworkState = snapshot.skater_states.get(_pass_target_peer_id)
	if receiver == null:
		return _attacking_goal_pos
	var lead_x: float = receiver.position.x + receiver.velocity.x * PASS_LEAD_TIME_S
	var lead_z: float = receiver.position.z + receiver.velocity.z * PASS_LEAD_TIME_S
	return Vector3(lead_x, 0.0, lead_z)


func _apply_steering(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, anchor: Vector3) -> void:
	_scratch_teammates.clear()
	for peer_id: int in snapshot.skater_states:
		if peer_id == _peer_id:
			continue
		if int(_team_id_resolver.call(peer_id)) != _team_id:
			continue
		_scratch_teammates.append(snapshot.skater_states[peer_id].position)
	input.move_vector = AISteering.compute_move_vector(
			self_pos, anchor, _scratch_teammates,
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


# Where to drop into when the puck is lost mid-on-puck-state. F1s chase,
# everyone else holds the above-puck anchor.
func _post_puck_lost_state() -> State:
	return State.CHASE_PUCK if _is_f1() else State.OFF_PUCK


func _in_offensive_zone(self_pos: Vector3) -> bool:
	# own_goal_dir = +1 for Team 0 (attacks -Z, OZ at z < -BLUE_LINE_Z),
	# -1 for Team 1 (attacks +Z, OZ at z > +BLUE_LINE_Z). Symmetric form:
	return -_own_goal_dir * self_pos.z > GameRules.BLUE_LINE_Z


func _set_state(s: State) -> void:
	if s != _state:
		_state = s
		_ticks_in_state = 0


func _reset_to_off_puck() -> void:
	_state = State.OFF_PUCK
	_ticks_in_state = 0
	_pass_target_peer_id = 0
