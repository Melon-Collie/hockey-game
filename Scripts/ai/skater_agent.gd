class_name SkaterAgent
extends RefCounted

# Per-bot decision loop. Owned by AIController.
#
# The agent is a small state machine driven each physics tick. State
# determines anchor (where the body wants to go), aim point (where the
# blade points), and input flags (shoot_pressed/held etc). Adding a new
# behavior — PASS, DUMP, PROTECT, etc — is a new State enum value plus
# a couple of match arms; we don't want to thread independent
# action/phase counters through every helper.
#
# Consumes the existing WorldSnapshot from StateBufferManager. team_id
# is not on SkaterNetworkState, so the agent uses a Callable resolver
# bound at setup time.
#
# State transitions:
#                          ┌─ no puck ─────────────────────┐
#                          │                               │
#       OFF_PUCK ◄──────────► CHASE_PUCK (F1 only) ────────│
#          │                       │                       │
#          │  picks up puck        │  picks up puck        │
#          ▼                       ▼                       │
#         CARRY ──[in OZ + quiet-eye expired]──► SHOOT_PRESSED
#          ▲                                          │
#          └──────────────────────────────────────────┘
#                       (release tick)
#
# CARRY is also re-entered after SHOOT_PRESSED to drop shoot_held — the
# skater state machine fires release_wrister on that tick.

const ANCHOR_DEPTH: float = 4.0
const QUIET_EYE_TICKS: int = 8
const GOALIE_SHADOW_HALF: float = 0.5

enum State {
	OFF_PUCK,        # default off-puck (OFF role, or no role) — anchor above puck
	CHASE_PUCK,      # F1 without puck — pursue the puck
	CARRY,           # with puck, no committed action yet (or post-shot)
	SHOOT_PRESSED,   # one-tick window: shoot_pressed+shoot_held set, awaiting release
}

# Reused buffers — avoids per-tick allocations.
var _scratch_input: InputState = InputState.new()
var _scratch_teammates: Array[Vector3] = []

# Identity / orientation
var _peer_id: int = 0
var _team_id: int = 0
# +1 if own goal is at +GOAL_LINE_Z (Team 0), -1 for Team 1.
# See LocalController.get_attacking_goal_z for the source of truth.
var _own_goal_dir: float = 1.0
var _attacking_goal_pos: Vector3 = Vector3.ZERO
var _team_brain: TeamBrain = null
var _team_id_resolver: Callable = Callable()

# State machine
var _state: State = State.OFF_PUCK
var _ticks_in_state: int = 0


func setup(peer_id: int, team_id: int, brain: TeamBrain, resolver: Callable) -> void:
	_peer_id = peer_id
	_team_id = team_id
	_own_goal_dir = 1.0 if team_id == 0 else -1.0
	# Aim point at the opposing goal mouth. Used as a fallback aim and as
	# the net plane for shot-aim geometry. y=0; blade IK lives in 2D.
	_attacking_goal_pos = Vector3(0.0, 0.0, -_own_goal_dir * GameRules.GOAL_LINE_Z)
	_team_brain = brain
	_team_id_resolver = resolver


# Returns the InputState for this physics tick. Caller must not retain a
# reference past the next tick — same scratch buffer is reused.
func tick(snapshot: WorldSnapshot, delta: float, host_timestamp: float) -> InputState:
	var input: InputState = _scratch_input
	_zero_input(input, delta, host_timestamp)

	if snapshot == null or snapshot.puck_state == null or snapshot.skater_states.is_empty():
		_set_state(State.OFF_PUCK)
		return input
	var self_state: SkaterNetworkState = snapshot.skater_states.get(_peer_id)
	if self_state == null:
		# Snapshot pre-dates this bot's spawn; freeze for one tick.
		_set_state(State.OFF_PUCK)
		return input
	var self_pos: Vector3 = self_state.position
	var role: StringName = _team_brain.get_role(_peer_id) if _team_brain != null else AIRoleAssignment.ROLE_OFF
	var have_puck: bool = (snapshot.puck_state.carrier_peer_id == _peer_id)

	# Transition first so per-state input filling reflects the new state.
	var next: State = _decide_next_state(role, have_puck, self_pos)
	if next == _state:
		_ticks_in_state += 1
	else:
		_state = next
		_ticks_in_state = 0

	# Anchor (where the body wants to go) + steering.
	var anchor: Vector3 = _anchor_for_state(snapshot, self_pos)
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

	# Aim (where the blade points) and any shot input flags.
	input.mouse_world_pos = _aim_for_state(snapshot, self_pos)
	_apply_shot_inputs(input)

	return input


# Pure transition function. Decides what state we should be in given the
# current world state and our quiet-eye lock. Mid-shot states (currently
# just SHOOT_PRESSED) advance unconditionally on the next tick to fire
# the release.
func _decide_next_state(role: StringName, have_puck: bool, self_pos: Vector3) -> State:
	if not have_puck:
		# Off-puck override is unconditional — losing the puck instantly
		# kicks us out of any on-puck state.
		if role == AIRoleAssignment.ROLE_F1:
			return State.CHASE_PUCK
		return State.OFF_PUCK
	# On-puck branch.
	if _state == State.SHOOT_PRESSED:
		# Two-tick press/release sequence: this tick drops shoot_held
		# (default false from _zero_input), the skater state machine
		# fires release_wrister. Back to CARRY for re-decision next tick.
		return State.CARRY
	if _state == State.OFF_PUCK or _state == State.CHASE_PUCK:
		# Just picked up the puck.
		return State.CARRY
	# _state == State.CARRY — quiet-eye-gated re-decision.
	if _ticks_in_state < QUIET_EYE_TICKS:
		return State.CARRY
	if _in_offensive_zone(self_pos):
		return State.SHOOT_PRESSED
	return State.CARRY


# Per-state anchor selection. The anchor drives `move_vector` via
# AISteering — body wants to skate toward this point.
func _anchor_for_state(snapshot: WorldSnapshot, self_pos: Vector3) -> Vector3:
	match _state:
		State.CHASE_PUCK:
			return Vector3(snapshot.puck_state.position.x, 0.0, snapshot.puck_state.position.z)
		State.CARRY, State.SHOOT_PRESSED:
			# High slot in opposing zone (5 m off the goal line) so the
			# carrier stops in front of the net rather than skating into
			# the cage.
			var slot_z: float = -_own_goal_dir * (GameRules.GOAL_LINE_Z - 5.0)
			return Vector3(0.0, 0.0, slot_z)
		_:  # OFF_PUCK
			# Phase 3 anchor — 4 m above the puck on own-net side.
			var anchor_z: float = snapshot.puck_state.position.z + _own_goal_dir * ANCHOR_DEPTH
			anchor_z = clampf(anchor_z, -GameRules.GOAL_LINE_Z + 1.0, GameRules.GOAL_LINE_Z - 1.0)
			return Vector3(self_pos.x, 0.0, anchor_z)


# Per-state aim selection. Drives blade IK and quick-shot release direction.
func _aim_for_state(snapshot: WorldSnapshot, self_pos: Vector3) -> Vector3:
	match _state:
		State.CHASE_PUCK:
			# Aim at the puck so the blade is on it at intercept time
			# instead of swung at the far goal.
			return Vector3(snapshot.puck_state.position.x, 0.0, snapshot.puck_state.position.z)
		State.CARRY, State.SHOOT_PRESSED:
			# Larger open arc past the goalie's projected shadow.
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
		_:  # OFF_PUCK
			return _attacking_goal_pos


# Per-state shoot-related input flags. Most states leave them at the
# zeroed defaults; SHOOT_PRESSED is the only state that actively presses.
func _apply_shot_inputs(input: InputState) -> void:
	if _state == State.SHOOT_PRESSED:
		input.shoot_pressed = true
		input.shoot_held = true


func _in_offensive_zone(self_pos: Vector3) -> bool:
	# own_goal_dir = +1 for Team 0 (attacks -Z, OZ at z < -BLUE_LINE_Z),
	# -1 for Team 1 (attacks +Z, OZ at z > +BLUE_LINE_Z). Symmetric form:
	return -_own_goal_dir * self_pos.z > GameRules.BLUE_LINE_Z


func _set_state(s: State) -> void:
	if s == _state:
		_ticks_in_state += 1
	else:
		_state = s
		_ticks_in_state = 0


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
