class_name SkaterAgent
extends RefCounted

# Per-bot decision loop. Owned by AIController.
#
# Phase 4 split behavior by role read from the TeamBrain blackboard (F1
# chases / carries, OFF holds the above-the-puck anchor). Phase 5a layers
# on the first on-puck behavior: F1 with the puck in the offensive zone
# fires a quick wrister at the goal mouth instead of holding forever.
#
# Consumes the existing WorldSnapshot from StateBufferManager. team_id
# is not on SkaterNetworkState, so the agent uses a Callable resolver
# bound at setup time.

# How far above the puck OFF bots sit (toward own goal, in meters).
const ANCHOR_DEPTH: float = 4.0

# Once an on-puck action commits, hold it for this many ticks before
# re-deciding. Prevents per-tick flip-flop between SHOOT and CARRY when
# the bot crosses the offensive blue line. ~33 ms at 240 Hz.
const QUIET_EYE_TICKS: int = 8

enum Action { CARRY, SHOOT }

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

# On-puck commit + shot phase. _shoot_phase: 0=idle, 1=press fired (wait for
# release), 2=release fired (shot done). Reset whenever the bot loses the
# puck or the commit window expires.
var _committed_action: Action = Action.CARRY
var _commit_remaining: int = 0
var _shoot_phase: int = 0


func setup(peer_id: int, team_id: int, brain: TeamBrain, resolver: Callable) -> void:
	_peer_id = peer_id
	_team_id = team_id
	_own_goal_dir = 1.0 if team_id == 0 else -1.0
	# Aim point at the opposing goal mouth. Used as mouse_world_pos so blade
	# IK points toward goal whether or not we're carrying. y=0 — blade IK
	# lives in 2D for now.
	_attacking_goal_pos = Vector3(0.0, 0.0, -_own_goal_dir * GameRules.GOAL_LINE_Z)
	_team_brain = brain
	_team_id_resolver = resolver


# Returns the InputState for this physics tick. Caller must not retain a
# reference past the next tick — same scratch buffer is reused.
func tick(snapshot: WorldSnapshot, delta: float, host_timestamp: float) -> InputState:
	var input: InputState = _scratch_input
	_zero_input(input, delta, host_timestamp)

	if snapshot == null or snapshot.puck_state == null or snapshot.skater_states.is_empty():
		_reset_on_puck_state()
		return input
	var self_state: SkaterNetworkState = snapshot.skater_states.get(_peer_id)
	if self_state == null:
		# Snapshot pre-dates this bot's spawn; freeze for one tick.
		_reset_on_puck_state()
		return input
	var self_pos: Vector3 = self_state.position
	var role: StringName = _team_brain.get_role(_peer_id) if _team_brain != null else AIRoleAssignment.ROLE_OFF
	var have_puck: bool = (snapshot.puck_state.carrier_peer_id == _peer_id)

	var anchor: Vector3 = _compute_anchor(role, self_pos, snapshot, have_puck)

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

	# Aim point: when carrying, point the blade toward the opposing goal so
	# the IK doesn't pull the stick toward (0,0,0). Off-puck bots get the
	# same aim — harmless for IK and avoids a useless branch.
	input.mouse_world_pos = _attacking_goal_pos

	# On-puck branch. Drives the press/release sequence for SHOOT and the
	# quiet-eye commit. Off-puck bots do nothing here; their behavior is
	# fully determined by anchor steering above.
	if have_puck:
		_on_puck_tick(input, self_pos)
	else:
		_reset_on_puck_state()

	return input


# Anchor selection by role.
#   F1 + has_puck: high-slot in opposing zone (5 m off the goal line) so the
#                  carrier stops in front of the net rather than skating into
#                  the cage. Phase 5a's shoot trigger fires from here.
#   F1 + no puck: chase puck position
#   OFF: Phase 3 "above the puck on own-net side"
func _compute_anchor(role: StringName, self_pos: Vector3, snapshot: WorldSnapshot, have_puck: bool) -> Vector3:
	if role == AIRoleAssignment.ROLE_F1:
		if have_puck:
			var slot_z: float = -_own_goal_dir * (GameRules.GOAL_LINE_Z - 5.0)
			return Vector3(0.0, 0.0, slot_z)
		var puck_pos: Vector3 = snapshot.puck_state.position
		return Vector3(puck_pos.x, 0.0, puck_pos.z)
	# OFF
	var anchor_z: float = snapshot.puck_state.position.z + _own_goal_dir * ANCHOR_DEPTH
	anchor_z = clampf(anchor_z, -GameRules.GOAL_LINE_Z + 1.0, GameRules.GOAL_LINE_Z - 1.0)
	return Vector3(self_pos.x, 0.0, anchor_z)


# Per-tick on-puck decision + execution. Decides which action to commit to
# (within the quiet-eye window) and fills the input flags accordingly.
func _on_puck_tick(input: InputState, self_pos: Vector3) -> void:
	if _commit_remaining <= 0:
		_committed_action = _pick_action(self_pos)
		_commit_remaining = QUIET_EYE_TICKS
		_shoot_phase = 0
	_commit_remaining -= 1

	match _committed_action:
		Action.SHOOT:
			_execute_shoot(input)
		Action.CARRY:
			pass  # default carry — input.move_vector already aims at the slot.


# Phase 5a action heuristic: SHOOT iff we're past our attacking blue line.
# Distance and angle gating come in 5b along with goalie-shadow aim.
func _pick_action(self_pos: Vector3) -> Action:
	# Blue lines sit at ±BLUE_LINE_Z. The bot is in the offensive zone when
	# its z is past the blue line on the attacking side; with own_goal_dir
	# = +1 for Team 0 (attacks -Z) and -1 for Team 1 (attacks +Z), the
	# expression is symmetric.
	var in_offensive_zone: bool = -_own_goal_dir * self_pos.z > GameRules.BLUE_LINE_Z
	if in_offensive_zone:
		return Action.SHOOT
	return Action.CARRY


# Two-tick press/release sequence for a quick wrister. The first tick sets
# shoot_pressed (state machine transitions SKATING_WITH_PUCK → WRISTER_AIM)
# and shoot_held (so the released-while-aimed gate in WRISTER_AIM doesn't
# fire prematurely on the same tick). The second tick drops shoot_held,
# triggering release_wrister. Bots don't sweep the cursor, so charge
# stays near zero and ShotMechanics.release_wrister always picks the
# quick-shot path — direction = blade-from-player. mouse_world_pos was
# already set to _attacking_goal_pos earlier in tick(), so the blade is
# already aimed at the net.
func _execute_shoot(input: InputState) -> void:
	if _shoot_phase == 0:
		input.shoot_pressed = true
		input.shoot_held = true
		_shoot_phase = 1
	elif _shoot_phase == 1:
		# shoot_held is already false from _zero_input — leave it that way
		# so WRISTER_AIM transitions to release this tick.
		_shoot_phase = 2
	# _shoot_phase >= 2: shot already fired. Hold idle until commit expires
	# or puck-loss resets the state. The puck has left our blade by now so
	# the next tick will branch into the off-puck path anyway.


func _reset_on_puck_state() -> void:
	_commit_remaining = 0
	_shoot_phase = 0
	_committed_action = Action.CARRY


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
