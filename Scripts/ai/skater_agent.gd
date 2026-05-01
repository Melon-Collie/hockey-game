class_name SkaterAgent
extends RefCounted

# Per-bot decision loop. Owned by AIController. Owns the InputState scratch
# buffer and forwards to a SkaterAgentStateMachine that holds the actual
# transition logic + per-state behavior. Mirrors the SkaterController /
# SkaterStateMachine pairing — controller does glue, state machine owns
# the decision graph.

var _scratch_input: InputState = InputState.new()
var _sm: SkaterAgentStateMachine = SkaterAgentStateMachine.new()


func setup(peer_id: int, team_id: int, brain: TeamBrain, resolver: Callable) -> void:
	_sm.setup(peer_id, team_id, brain, resolver)


# Returns the InputState for this physics tick. Caller must not retain a
# reference past the next tick — same scratch buffer is reused.
func tick(snapshot: WorldSnapshot, delta: float, host_timestamp: float) -> InputState:
	_zero_input(_scratch_input, delta, host_timestamp)
	_sm.dispatch(_scratch_input, snapshot)
	return _scratch_input


func get_state() -> SkaterAgentStateMachine.State:
	return _sm.get_state()


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
