class_name SkaterAgent
extends RefCounted

# Per-bot state machine driving anchor (where to skate), aim point (where
# the blade points), and input flags (shoot_pressed/held). Mirrors the
# pattern at Scripts/controllers/skater_state_machine.gd — dispatch on
# _state to a per-state handler that owns the full per-tick behavior
# including transitions.
#
# Adding a new behavior (PASS, DUMP, PROTECT) is a new State enum value
# plus a _state_<name> handler and one match arm in _dispatch.
#
# Consumes the existing WorldSnapshot from StateBufferManager. team_id
# is not on SkaterNetworkState, so the agent uses a Callable resolver
# bound at setup time.
#
# State graph:
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
	CARRY,           # with puck, no committed shot — anchor at slot
	SHOOT_PRESSED,   # one-tick press window; release fires next tick
}

const ANCHOR_DEPTH: float = 4.0
const QUIET_EYE_TICKS: int = 8
# How wide the goalie's shadow on the net plane should be considered
# (meters, half-width). Tuneable in playtest.
const GOALIE_SHADOW_HALF: float = 0.5

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

# Reused buffers — avoids per-tick allocations.
var _scratch_input: InputState = InputState.new()
var _scratch_teammates: Array[Vector3] = []


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


# ── Tick (AIController entry point) ──────────────────────────────────────────

# Returns the InputState for this physics tick. Caller must not retain a
# reference past the next tick — same scratch buffer is reused.
func tick(snapshot: WorldSnapshot, delta: float, host_timestamp: float) -> InputState:
	var input: InputState = _scratch_input
	_zero_input(input, delta, host_timestamp)

	if snapshot == null or snapshot.puck_state == null or snapshot.skater_states.is_empty():
		_state = State.OFF_PUCK
		_ticks_in_state = 0
		return input
	var self_state: SkaterNetworkState = snapshot.skater_states.get(_peer_id)
	if self_state == null:
		# Snapshot pre-dates this bot's spawn; freeze for one tick.
		_state = State.OFF_PUCK
		_ticks_in_state = 0
		return input

	var self_pos: Vector3 = self_state.position
	var role: StringName = _team_brain.get_role(_peer_id) if _team_brain != null else AIRoleAssignment.ROLE_OFF
	var have_puck: bool = (snapshot.puck_state.carrier_peer_id == _peer_id)

	_ticks_in_state += 1
	_dispatch(input, snapshot, self_pos, role, have_puck)
	return input


# ── Dispatch ─────────────────────────────────────────────────────────────────

func _dispatch(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, role: StringName, have_puck: bool) -> void:
	match _state:
		State.OFF_PUCK:
			_state_off_puck(input, snapshot, self_pos, role, have_puck)
		State.CHASE_PUCK:
			_state_chase_puck(input, snapshot, self_pos, role, have_puck)
		State.CARRY:
			_state_carry(input, snapshot, self_pos, role, have_puck)
		State.SHOOT_PRESSED:
			_state_shoot_pressed(input, snapshot, self_pos, role, have_puck)


# ── State handlers ───────────────────────────────────────────────────────────

func _state_off_puck(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, role: StringName, have_puck: bool) -> void:
	# Anchor: 4 m above the puck on own-net side.
	var anchor_z: float = snapshot.puck_state.position.z + _own_goal_dir * ANCHOR_DEPTH
	anchor_z = clampf(anchor_z, -GameRules.GOAL_LINE_Z + 1.0, GameRules.GOAL_LINE_Z - 1.0)
	_apply_steering(input, snapshot, self_pos, Vector3(self_pos.x, 0.0, anchor_z))
	input.mouse_world_pos = _attacking_goal_pos
	# Transitions
	if have_puck:
		_set_state(State.CARRY)
	elif role == AIRoleAssignment.ROLE_F1:
		_set_state(State.CHASE_PUCK)


func _state_chase_puck(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, role: StringName, have_puck: bool) -> void:
	var puck_pos: Vector3 = snapshot.puck_state.position
	var target := Vector3(puck_pos.x, 0.0, puck_pos.z)
	_apply_steering(input, snapshot, self_pos, target)
	# Aim at the puck so the blade is on it at intercept time instead of
	# swung toward the far goal.
	input.mouse_world_pos = target
	# Transitions
	if have_puck:
		_set_state(State.CARRY)
	elif role != AIRoleAssignment.ROLE_F1:
		_set_state(State.OFF_PUCK)


func _state_carry(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, role: StringName, have_puck: bool) -> void:
	# Anchor: opposing high slot (5 m off the goal line) so the carrier
	# stops in front of the net rather than skating into the cage.
	var slot_z: float = -_own_goal_dir * (GameRules.GOAL_LINE_Z - 5.0)
	_apply_steering(input, snapshot, self_pos, Vector3(0.0, 0.0, slot_z))
	input.mouse_world_pos = _shot_aim_point(snapshot, self_pos)
	# Transitions
	if not have_puck:
		_set_state(State.CHASE_PUCK if role == AIRoleAssignment.ROLE_F1 else State.OFF_PUCK)
	elif _ticks_in_state >= QUIET_EYE_TICKS and _in_offensive_zone(self_pos):
		_enter_shoot_pressed()


func _state_shoot_pressed(input: InputState, snapshot: WorldSnapshot, self_pos: Vector3, role: StringName, have_puck: bool) -> void:
	# Same anchor + aim as CARRY — we're still on the puck mid-press.
	var slot_z: float = -_own_goal_dir * (GameRules.GOAL_LINE_Z - 5.0)
	_apply_steering(input, snapshot, self_pos, Vector3(0.0, 0.0, slot_z))
	input.mouse_world_pos = _shot_aim_point(snapshot, self_pos)
	# Press flags. SkaterStateMachine handles SKATING_WITH_PUCK +
	# shoot_pressed → WRISTER_AIM, then next tick (CARRY again here)
	# shoot_held=false fires release_wrister.
	input.shoot_pressed = true
	input.shoot_held = true
	# Transitions: always exits next tick. Losing the puck mid-sequence
	# (e.g., body-checked) drops us to chase/off straight away.
	if not have_puck:
		_set_state(State.CHASE_PUCK if role == AIRoleAssignment.ROLE_F1 else State.OFF_PUCK)
	else:
		_set_state(State.CARRY)


# ── Internal helpers ─────────────────────────────────────────────────────────

func _enter_shoot_pressed() -> void:
	_state = State.SHOOT_PRESSED
	_ticks_in_state = 0


func _set_state(s: State) -> void:
	if s != _state:
		_state = s
		_ticks_in_state = 0


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


func _in_offensive_zone(self_pos: Vector3) -> bool:
	# own_goal_dir = +1 for Team 0 (attacks -Z, OZ at z < -BLUE_LINE_Z),
	# -1 for Team 1 (attacks +Z, OZ at z > +BLUE_LINE_Z). Symmetric form:
	return -_own_goal_dir * self_pos.z > GameRules.BLUE_LINE_Z


func _zero_input(input: InputState, delta: float, host_timestamp: float) -> void:
	input.delta = delta
	input.host_timestamp = host_timestamp
	input.move_vector = Vector2.ZERO
	input.mouse_world_pos = Vector3.ZERO
	input.mouse_screen_pos = Vector2.ZERO
	input.shoot_pressed = false
	input.shoot_held = false
	input.slap_pressed = false
	input.slap_held = false
	input.brake = false
	input.elevation_up = false
	input.elevation_down = false
	input.block_held = false
