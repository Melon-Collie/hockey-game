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

# Scratch InputState reused every FACEOFF_PREP tick so we don't allocate per
# frame. All flags default to false; we only overwrite mouse_world_pos / time
# / delta. Lifetime is the controller — bots aren't re-allocated mid-match.
var _faceoff_input: InputState = InputState.new()

# Debug: floating label above each bot showing the bot's per-tick
# decision breakdown. Refreshes only when the rendered text actually
# changes (commit flip, winner flip, score moves enough to re-format)
# so it doesn't flicker on every wobble. Toggle to false to disable
# for shipping.
const SHOW_DEBUG_LABEL: bool = false
const DEBUG_LABEL_HEIGHT_M: float = 2.4    # above the head
var _debug_label: Label3D = null
var _debug_last_text: String = ""

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
	if SHOW_DEBUG_LABEL and skater != null:
		_debug_label = Label3D.new()
		_debug_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_debug_label.no_depth_test = true
		_debug_label.fixed_size = true
		_debug_label.pixel_size = 0.001
		_debug_label.outline_size = 2
		_debug_label.font_size = 24
		_debug_label.modulate = Color(1, 1, 1, 1)
		_debug_label.outline_modulate = Color(0, 0, 0, 1)
		_debug_label.position = Vector3(0, DEBUG_LABEL_HEIGHT_M, 0)
		skater.add_child(_debug_label)


func _physics_process(delta: float) -> void:
	if skater == null or puck == null or _agent == null:
		return
	if NetworkManager.is_replay_mode():
		return
	if _game_state.is_movement_locked():
		# Mirror LocalController/RemoteController: zero velocity during dead
		# phases so residual inertia from before the lock can't drift the bot.
		skater.velocity = Vector3.ZERO
		# FACEOFF_PREP: keep the stick alive so the bot looks alive during
		# the countdown and naturally contests the drop. Aim at the puck —
		# centers clash over the dot, wings/D reach toward it. We don't run
		# _agent.tick here; the agent's full state machine isn't designed
		# for the locked phase and could drag in stale carrier / chase intent.
		if _game_state.allows_blade_aim_during_lock():
			_faceoff_input.delta = delta
			_faceoff_input.host_timestamp = NetworkManager.estimated_host_time()
			_faceoff_input.mouse_world_pos = puck.global_position
			apply_blade_aim_only(_faceoff_input, delta)
		return
	if _game_state.is_in_goal_celebration():
		# Celebration is movement-allowed live gameplay (humans can react),
		# but bots shouldn't be playing — they'd try to chase a pickup-locked
		# puck and bunch around the net. Skip agent input; physics friction
		# coasts whatever velocity the bot had at the goal moment to a stop.
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
	_refresh_debug_label()


func _refresh_debug_label() -> void:
	if _debug_label == null:
		return
	# Build the label text from the SM's per-tick scores. ► marks the
	# current winning option (independent of commit). intent: shows
	# what the bot is currently committed to (CARRY default; pre-aim
	# / charge states show the fire intent). last: persists the most
	# recent fired action.
	var winner: String = _agent.debug_winner()
	var intent: String = _agent.debug_intent()
	var lines: Array[String] = []
	lines.append("[%s] intent:%s" % [_agent.debug_role(), intent])

	var shoot_label: String = _agent.debug_shoot_label()
	var pass_slot: String = _agent.debug_pass_slot()
	var carry_dir: String = _agent.debug_carry_dir(perceived_snapshot)

	# Score lines, with ► on the winner. Round to 2 decimals — finer
	# precision changes the text every tick and defeats the change
	# detection.
	lines.append("%s %s %.2f" % [
			"►" if winner == shoot_label else " ", shoot_label, _agent.debug_shoot_score()])
	lines.append("%s PASS  %.2f →%s" % [
			"►" if winner == "PASS" else " ", _agent.debug_pass_score(), pass_slot])
	lines.append("%s CARRY %.2f %s" % [
			"►" if winner == "CARRY" else " ", _agent.debug_carry_score(), carry_dir])

	var last: String = _agent.debug_last_decision()
	if last != "":
		lines.append("last: " + last)

	var text: String = "\n".join(lines)
	if text != _debug_last_text:
		_debug_label.text = text
		_debug_last_text = text
