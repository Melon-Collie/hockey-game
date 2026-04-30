class_name AIController
extends SkaterController

# Host-only controller for AI bots. Owns one SkaterAgent and forwards its
# per-tick InputState to SkaterController._process_input. Clients see the
# bot through the existing SkaterNetworkState broadcast (no input
# replication path — LocalController.get_input_batch is the human path).
#
# Phase 1 emitted a frozen zero input. Phase 2 added perception buffer
# wiring. Phase 3 (this file's current state) routes through SkaterAgent
# for anchor-following steering.

# Single global reaction delay, ≈100 ms at 240 Hz. Tunable in playtest;
# not derived from a per-bot skill (we deliberately don't ship scaling
# difficulties — see CLAUDE.md / AI_PLAN.md §13 callout).
const REACTION_DELAY_TICKS: int = 24

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
func setup_agent(peer_id: int, team_id: int) -> void:
	if _agent != null:
		_agent.setup(peer_id, team_id)


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
	# Read tick-delayed snapshot. Buffer is only allocated on the host; guard
	# anyway so a stripped-down test scene doesn't crash.
	if GameManager.perception != null:
		perceived_snapshot = GameManager.perception.read(REACTION_DELAY_TICKS)
	var input: InputState = _agent.tick(perceived_snapshot, delta, NetworkManager.estimated_host_time())
	_process_input(input, delta)
	skater.current_shot_state = _sm.get_state() as int
