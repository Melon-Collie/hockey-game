class_name SkaterAgent
extends RefCounted

# Per-bot decision loop. Owned by AIController. Phase 4 splits behavior by
# role read from the TeamBrain blackboard:
#   F1  — chase the puck (or carry it toward the opposing goal if we have it)
#   OFF — Phase 3 anchor (4 m above the puck on own-net side)
#
# Future phases will add F2/F3 differentiation, on-puck SHOOT/PASS/CARRY
# scoring, hysteresis (quiet-eye commits), and teammate-polite rules.

# How far above the puck OFF bots sit (toward own goal, in meters).
const ANCHOR_DEPTH: float = 4.0

# Reused buffers — avoids per-tick allocations.
var _scratch_input: InputState = InputState.new()
var _scratch_teammates: Array[Vector3] = []

var _peer_id: int = 0
var _team_id: int = 0
# +1 if own goal is at +GOAL_LINE_Z (Team 0), -1 for Team 1.
# See LocalController.get_attacking_goal_z for the source of truth.
var _own_goal_dir: float = 1.0
var _attacking_goal_pos: Vector3 = Vector3.ZERO
var _team_brain: TeamBrain = null


func setup(peer_id: int, team_id: int, brain: TeamBrain) -> void:
	_peer_id = peer_id
	_team_id = team_id
	_own_goal_dir = 1.0 if team_id == 0 else -1.0
	# Aim point at the opposing goal mouth. Used as mouse_world_pos so blade
	# IK points toward goal whether or not we're carrying. y=0 — blade IK
	# lives in 2D for now.
	_attacking_goal_pos = Vector3(0.0, 0.0, -_own_goal_dir * GameRules.GOAL_LINE_Z)
	_team_brain = brain


# Returns the InputState for this physics tick. Caller must not retain a
# reference past the next tick — same scratch buffer is reused.
func tick(snapshot: WorldSnapshot, delta: float, host_timestamp: float) -> InputState:
	var input: InputState = _scratch_input
	_zero_input(input, delta, host_timestamp)

	if snapshot == null or snapshot.num_skaters == 0:
		return input
	var self_idx: int = snapshot.find_skater(_peer_id)
	if self_idx < 0:
		# Snapshot pre-dates this bot's spawn; freeze for one tick.
		return input
	var self_pos: Vector3 = snapshot.skater_pos[self_idx]
	var role: StringName = _team_brain.get_role(_peer_id) if _team_brain != null else AIRoleAssignment.ROLE_OFF
	var have_puck: bool = (snapshot.puck_possessor_idx == self_idx)

	var anchor: Vector3 = _compute_anchor(role, self_pos, snapshot, have_puck)

	_scratch_teammates.clear()
	for i: int in snapshot.num_skaters:
		if i == self_idx:
			continue
		if snapshot.skater_team[i] != _team_id:
			continue
		_scratch_teammates.append(snapshot.skater_pos[i])

	input.move_vector = AISteering.compute_move_vector(
			self_pos, anchor, _scratch_teammates,
			GameRules.RINK_HALF_WIDTH, GameRules.RINK_HALF_LENGTH)

	# Aim point: when carrying, point the blade toward the opposing goal so
	# the IK doesn't pull the stick toward (0,0,0). Off-puck bots get the
	# same aim — harmless for IK and avoids a useless branch.
	input.mouse_world_pos = _attacking_goal_pos
	return input


# Anchor selection by role.
#   F1 + has_puck: high-slot in opposing zone (5 m off the goal line) so the
#                  carrier stops in front of the net rather than skating into
#                  the cage. Phase 5's shooting will happen from here.
#   F1 + no puck: chase puck position
#   OFF: Phase 3 "above the puck on own-net side"
func _compute_anchor(role: StringName, self_pos: Vector3, snapshot: WorldSnapshot, have_puck: bool) -> Vector3:
	if role == AIRoleAssignment.ROLE_F1:
		if have_puck:
			var slot_z: float = -_own_goal_dir * (GameRules.GOAL_LINE_Z - 5.0)
			return Vector3(0.0, 0.0, slot_z)
		return Vector3(snapshot.puck_pos.x, 0.0, snapshot.puck_pos.z)
	# OFF
	var anchor_z: float = snapshot.puck_pos.z + _own_goal_dir * ANCHOR_DEPTH
	anchor_z = clampf(anchor_z, -GameRules.GOAL_LINE_Z + 1.0, GameRules.GOAL_LINE_Z - 1.0)
	return Vector3(self_pos.x, 0.0, anchor_z)


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
