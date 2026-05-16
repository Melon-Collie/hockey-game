class_name SkaterAgent
extends RefCounted

# Per-bot decision loop. Owned by AIController. Owns the InputState scratch
# buffer and forwards to a SkaterAgentStateMachine that holds the actual
# transition logic + per-state behavior. Mirrors the SkaterController /
# SkaterStateMachine pairing — controller does glue, state machine owns
# the decision graph.

var _scratch_input: InputState = InputState.new()
var _sm: SkaterAgentStateMachine = SkaterAgentStateMachine.new()

# Mouse-world lerp factor — closes 75% of the gap toward the SM's
# desired mouse_world_pos each tick. At 240 Hz that's a ~14 ms
# half-life: bot blade always lags slightly behind its target so
# tracking isn't perfectly instant, dekes don't immediately get
# matched, and aim transitions (state change, carrier change) read
# as a smooth swing rather than a snap.
const MOUSE_LERP_FACTOR: float = 0.75
var _prev_mouse_world_pos: Vector3 = Vector3.ZERO
var _has_prev_mouse: bool = false


func setup(peer_id: int, team_id: int, brain: TeamBrain, team_id_by_peer: Dictionary,
		is_left_handed: bool) -> void:
	_sm.setup(peer_id, team_id, brain, team_id_by_peer, is_left_handed)


# Returns the InputState for this physics tick. Caller must not retain a
# reference past the next tick — same scratch buffer is reused.
func tick(snapshot: WorldSnapshot, delta: float, host_timestamp: float) -> InputState:
	_zero_input(_scratch_input, delta, host_timestamp)
	_sm.dispatch(_scratch_input, snapshot)
	# Lerp the SM's desired mouse_world_pos so the blade always lags a
	# bit behind. Skipped on the first ever tick (no prev to lerp from)
	# and after any tick where the SM left mouse at ZERO (state didn't
	# explicitly aim — don't drag a stale lag value into a subsequent
	# real aim).
	if _has_prev_mouse and _scratch_input.mouse_world_pos != Vector3.ZERO:
		_scratch_input.mouse_world_pos = _prev_mouse_world_pos.lerp(
				_scratch_input.mouse_world_pos, MOUSE_LERP_FACTOR)
	_prev_mouse_world_pos = _scratch_input.mouse_world_pos
	_has_prev_mouse = _scratch_input.mouse_world_pos != Vector3.ZERO
	return _scratch_input


func get_state() -> SkaterAgentStateMachine.State:
	return _sm.get_state()


# ── Debug accessors ───────────────────────────────────────────────────────────
# Read by AIController to populate the floating per-bot debug label.

func debug_state_name() -> String:
	return SkaterAgentStateMachine.State.keys()[_sm.get_state()]


func debug_role() -> String:
	return _sm.debug_role()


func debug_last_decision() -> String:
	return _sm.debug_last_decision


func debug_shoot_score() -> float:
	return _sm.debug_shoot_score


func debug_shoot_label() -> String:
	return "SHOOT"


func debug_pass_score() -> float:
	return _sm.debug_pass_score


func debug_pass_slot() -> String:
	return _sm.debug_pass_slot()


func debug_carry_score() -> float:
	return _sm.debug_carry_score


func debug_carry_dir(snapshot: WorldSnapshot) -> String:
	if snapshot == null or not snapshot.skater_states.has(_sm._peer_id):
		return "—"
	return _sm.debug_carry_dir(snapshot.skater_states[_sm._peer_id].position)


func debug_winner() -> String:
	return _sm.debug_winner()


func debug_intent() -> String:
	return _sm.debug_intent()


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
	# Default elevation_down high so the SkaterController's sticky
	# _is_elevated flag is reset every tick the bot isn't actively
	# firing an elevated shot. Press states override with
	# elevation_up=true / elevation_down=false on the tick they want
	# the controller to raise the flag.
	input.elevation_up = false
	input.elevation_down = true
	input.block_held = false
