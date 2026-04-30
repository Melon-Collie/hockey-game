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

# Single global reaction delay (Phase 2: arbitrary 24 ticks ≈ 100 ms; tunable
# in playtest). We deliberately do not derive this from a per-bot skill —
# all bots share one profile.
const REACTION_DELAY_TICKS: int = 24

# Cached most-recent snapshot read this tick. Public for debugging /
# inspection and for upcoming phases that may want to read the same
# snapshot from outside the controller without re-fetching.
var perceived_snapshot: WorldSnapshot = null


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
	# Phase 2: read a tick-delayed snapshot. Currently consumed only as a
	# debug surface; the agent layer in Phase 3 will turn this into anchor
	# tracking. Buffer is only allocated on the host (where bots run), but
	# guard anyway so a stripped-down test scene doesn't crash.
	if GameManager.perception != null:
		perceived_snapshot = GameManager.perception.read(REACTION_DELAY_TICKS)
	_zero_input.delta = delta
	_zero_input.host_timestamp = NetworkManager.estimated_host_time()
	_process_input(_zero_input, delta)
	skater.current_shot_state = _sm.get_state() as int
