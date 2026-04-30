class_name SkaterAgent
extends RefCounted

# Per-bot decision loop. Owned by AIController, not a scene node. Stateless
# in Phase 3 — no quiet-eye commits, no role hysteresis. The controller
# hands us a snapshot and we return an InputState.
#
# Phase 3 cut: every bot plays one role ("above the puck on own-goal side").
# Phases 4+ will replace this with the F1/F2/F3 enumeration from AI_PLAN.md
# §8 and add on-puck utility (SHOOT/PASS/CARRY/etc).

# How far above the puck (toward own goal, in meters) the anchor sits.
const ANCHOR_DEPTH: float = 4.0

# Reused buffers — avoids per-tick allocations.
var _scratch_input: InputState = InputState.new()
var _scratch_teammates: Array[Vector3] = []

var _peer_id: int = 0
var _team_id: int = 0
# +1 if own goal is at +GOAL_LINE_Z (Team 0), -1 for Team 1.
# See LocalController.get_attacking_goal_z for the source of truth.
var _own_goal_dir: float = 1.0


func setup(peer_id: int, team_id: int) -> void:
	_peer_id = peer_id
	_team_id = team_id
	_own_goal_dir = 1.0 if team_id == 0 else -1.0


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

	# Anchor: hold current X, sit ANCHOR_DEPTH meters above the puck on the
	# own-goal side. Clamped to keep the anchor inside the playable rink so
	# the bot doesn't try to skate through the boards behind its own net.
	var anchor_z: float = snapshot.puck_pos.z + _own_goal_dir * ANCHOR_DEPTH
	anchor_z = clampf(anchor_z, -GameRules.GOAL_LINE_Z + 1.0, GameRules.GOAL_LINE_Z - 1.0)
	var anchor := Vector3(self_pos.x, 0.0, anchor_z)

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
	return input


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
