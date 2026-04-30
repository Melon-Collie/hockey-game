class_name AIController
extends SkaterController

# Host-only controller for AI bots. Owns one SkaterAgent and forwards its
# per-tick InputState to SkaterController._process_input. Clients see the
# bot through the existing SkaterNetworkState broadcast (no input
# replication path — LocalController.get_input_batch is the human path).
#
# Reads a tick-delayed WorldSnapshot from GameManager.get_state_at, which
# forwards to StateBufferManager. We don't keep a separate AI perception
# buffer — the lag-comp ring is already capturing the same data.

# Single global reaction delay, ~100 ms. Tunable in playtest; not derived
# from a per-bot skill (we deliberately don't ship scaling difficulties —
# see CLAUDE.md / AI_PLAN.md §13 callout).
const REACTION_DELAY_S: float = 0.1

var _agent: SkaterAgent = null
# Cached most-recent snapshot read this tick. Public for debug inspection.
var perceived_snapshot: WorldSnapshot = null


func setup(assigned_skater: Skater, assigned_puck: Puck, game_state: Node) -> void:
	super.setup(assigned_skater, assigned_puck, game_state)
	_agent = SkaterAgent.new()


# Bots are spawned by PlayerRegistry.spawn_bot, which knows the bot's
# peer_id and team_id but not the controller — so the registry calls this
# after spawn to wire the agent. Separate from setup() because setup() is
# called by ActorSpawner before the registry knows which slot it belongs to.
func setup_agent(peer_id: int, team_id: int, brain: TeamBrain, resolver: Callable) -> void:
	if _agent != null:
		_agent.setup(peer_id, team_id, brain, resolver)


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
	# Read tick-delayed snapshot. StateBufferManager interpolates between
	# captured frames so the result is stable even if no entry exists at
	# exactly target_time.
	var target_time: float = NetworkManager.local_time() - REACTION_DELAY_S
	perceived_snapshot = GameManager.get_state_at(target_time)
	var input: InputState = _agent.tick(perceived_snapshot, delta, NetworkManager.estimated_host_time())
	_process_input(input, delta)
	skater.current_shot_state = _sm.get_state() as int
