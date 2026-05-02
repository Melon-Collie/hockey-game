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

var _agent: SkaterAgent = null
# Cached most-recent snapshot read this tick. Public for debug inspection.
var perceived_snapshot: WorldSnapshot = null

# Reaction delay was 0.1s in the original design but reading delayed-past
# from StateBufferManager logged "ts predates oldest" warnings whenever the
# buffer hadn't filled (post-rehost, post-faceoff, etc.) — for Phase 4 we
# read the freshest captured state. A future phase can re-introduce delay
# via clamping the requested ts to the buffer's oldest entry.


func setup(assigned_skater: Skater, assigned_puck: Puck, game_state: Node) -> void:
	super.setup(assigned_skater, assigned_puck, game_state)
	_agent = SkaterAgent.new()


# Bots are spawned by PlayerRegistry.spawn_bot, which knows the bot's
# peer_id and team_id but not the controller — so the registry calls this
# after spawn to wire the agent. Separate from setup() because setup() is
# called by ActorSpawner before the registry knows which slot it belongs to.
func setup_agent(peer_id: int, team_id: int, brain: TeamBrain, resolver: Callable,
		is_left_handed: bool) -> void:
	if _agent != null:
		_agent.setup(peer_id, team_id, brain, resolver, is_left_handed)


func _physics_process(delta: float) -> void:
	if skater == null or puck == null or _agent == null:
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
	# Read the frame's shared snapshot. GameManager publishes it once per
	# host physics frame after StateBufferManager.capture; reading it here
	# avoids 6 bots × redundant interpolation passes per frame.
	perceived_snapshot = GameManager.current_snapshot
	var input: InputState = _agent.tick(perceived_snapshot, delta, NetworkManager.estimated_host_time())
	_process_input(input, delta)
	skater.current_shot_state = _sm.get_state() as int
