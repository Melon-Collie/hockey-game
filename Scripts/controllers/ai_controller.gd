class_name AIController
extends SkaterController

# Phase 1: emits a frozen InputState every physics tick. Lives on the host;
# clients see this skater through the existing SkaterNetworkState broadcast,
# same as a RemoteController-driven skater. No input replication path —
# LocalController.get_input_batch() is what NetworkManager polls for human
# clients, and we deliberately don't extend that.
#
# Future phases will replace _zero_input population with real perception +
# decision logic (see docs/specs/AI_PLAN.md). The contract with
# SkaterController is unchanged: hand it an InputState each tick.

var _zero_input: InputState = InputState.new()


func _physics_process(delta: float) -> void:
	if skater == null or puck == null:
		return
	if NetworkManager.is_replay_mode():
		return
	if _game_state.is_movement_locked():
		# Mirror LocalController/RemoteController: zero velocity during dead
		# phases so residual inertia from before the lock can't drift the bot.
		skater.velocity = Vector3.ZERO
		return
	if _game_state.is_input_blocked():
		return
	_zero_input.delta = delta
	_zero_input.host_timestamp = NetworkManager.estimated_host_time()
	_process_input(_zero_input, delta)
	skater.current_shot_state = _sm.get_state() as int
