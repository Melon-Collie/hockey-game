class_name PostGameReplayDriver
extends Node

# Plays a playlist of goal clips behind a presentation screen. Companion to
# GoalReplayDriver: both consume the same stateless ReplayPlaybackEngine and
# drive the LIVE actors (skater / puck / goalie nodes) off recorded snapshots,
# but where GoalReplayDriver plays one clip with cinematic camera cuts + slow-mo
# + re-fired audio, this plays a PLAYLIST at normal speed on a single broadcast
# ("hard") cam with no audio — an ambient highlight reel, not a money shot.
#
# Source is GoalReplayStore, filled clip-by-clip during the game (the ~9 s
# recorder ring can't hold a whole game). Two configurations, one engine:
#   - Post-game reel (defaults): loops the whole match's goals forever behind
#     the final-score screen. Purely cosmetic, each peer loops its OWN store —
#     replay mode is entered LOCALLY (set_replay_mode_local, no RPC) so the
#     host stops fighting the frozen scene with live broadcasts and clients
#     ignore stray frames.
#   - Intermission reel (use_shared_replay_mode = true): loops the ended
#     period's goals behind the intermission band for the fixed break window —
#     GameManager's INTERMISSION_DURATION end timer (or its unanimous skip
#     vote, which stops this driver) ends it, and reel_stopped is what ends
#     the break on the host (GameStateMachine.finish_period_break). The shared
#     replay mode mirrors the flag to clients (same notify_replay_mode RPC as
#     the goal cinematic) so every peer's reel starts and tears down in
#     lockstep.
#
# Owned by GameManager. start(clips) / stop() called from there.

@export var playback_speed: float = 1.0
@export var inter_clip_gap: float = 0.6  # seconds held on the final frame between clips
# false = play the playlist once and stop (the intermission reel);
# true = wrap around forever (the post-game reel).
@export var loop: bool = true
# true routes replay mode through start/stop_replay_mode (host mirrors the
# flag to clients via the reliable notify_replay_mode RPC); false stays local.
@export var use_shared_replay_mode: bool = false

signal reel_started
# Fired as each clip's playback begins, with the store's clip Dictionary —
# meta fields (period, scorer_name, …) caption the intermission band.
signal clip_started(clip: Dictionary)
# Fired at the end of every stop(): natural playlist completion (loop = false),
# skip-vote unanimity, and external teardown all funnel here.
signal reel_stopped

var _codec: WorldStateCodec = null
var _registry: PlayerRegistry = null
var _puck: Puck = null
var _goalie_controllers: Array[GoalieController] = []

var _clips: Array[Dictionary] = []
var _clip_idx: int = -1
var _active: bool = false

# Current clip's frame stream + virtual clock, refreshed on each _begin_clip.
var _frames: Array[PackedByteArray] = []
var _timestamps: Array[float] = []
var _clip_end_ts: float = 0.0
var _virtual_clock: float = 0.0
var _gap_elapsed: float = -1.0  # >= 0 while holding the final frame between clips

# Which recorded frames bracket the virtual clock, decoded once per bracket.
var _cursor := ReplayFrameCursor.new()

var _cam: SpectatorCamera = null
var _sim_hold := ReplayLiveSimHold.new()


func setup(codec: WorldStateCodec,
		registry: PlayerRegistry,
		puck: Puck,
		goalie_controllers: Array) -> void:
	_codec = codec
	_registry = registry
	_puck = puck
	_goalie_controllers = []
	for gc: GoalieController in goalie_controllers:
		_goalie_controllers.append(gc)
	_cursor.bind(codec)


func start(clips: Array[Dictionary]) -> void:
	if _active:
		stop()
	if clips.is_empty() or _codec == null or _registry == null or _puck == null:
		return

	_clips = clips
	_active = true
	_sim_hold.grab(_puck, _goalie_controllers)

	# Single broadcast hard cam, following the puck along the rail. activate()
	# saves the current camera and restores it in deactivate() on stop().
	var puck_pos_getter: Callable = func() -> Vector3: return _puck.global_position
	_cam = SpectatorCamera.new()
	add_child(_cam)
	_cam.setup(puck_pos_getter)
	_cam.activate()

	# Replay mode: either mirrored to clients (intermission — the host stops
	# broadcasting and each client spins up its own reel off this edge) or
	# local-only (post-game — see class doc). Both stop the host's live sim
	# tick + broadcast (GameManager._physics_process bails while
	# is_replay_mode) and make clients' decode_world_state skip stray frames.
	if use_shared_replay_mode:
		NetworkManager.start_replay_mode(_clips[0].start_ts)
	else:
		NetworkManager.set_replay_mode_local(true, _clips[0].start_ts)

	_begin_clip(0)
	reel_started.emit()


func stop() -> void:
	if not _active:
		return
	_active = false

	if _cam != null:
		_cam.deactivate()
		_cam.queue_free()
		_cam = null

	if use_shared_replay_mode:
		NetworkManager.stop_replay_mode()
	else:
		NetworkManager.set_replay_mode_local(false)
	_sim_hold.release()

	_clips = []
	_clip_idx = -1
	_frames = []
	_timestamps = []
	_cursor.reset()
	_gap_elapsed = -1.0
	reel_stopped.emit()


func is_active() -> bool:
	return _active


func _begin_clip(idx: int) -> void:
	_clip_idx = idx
	var clip: Dictionary = _clips[idx]
	_frames = clip.frames
	_timestamps = clip.timestamps
	_virtual_clock = float(clip.start_ts)
	_clip_end_ts = float(clip.end_ts)
	_cursor.reset()
	_gap_elapsed = -1.0
	NetworkManager.set_replay_clock(_virtual_clock)
	# Re-anchor the cam so the puck teleporting to the next clip's start doesn't
	# whip the broadcast framing across the ice.
	if _cam != null:
		_cam.snap_to_position()
	clip_started.emit(clip)


# End of one clip (after the inter-clip hold): wrap around when looping,
# otherwise the playlist is done — stop, which announces reel_stopped.
func _advance_clip() -> void:
	var next: int = _clip_idx + 1
	if next >= _clips.size():
		if not loop:
			stop()
			return
		next = 0
	_begin_clip(next)


func _process(delta: float) -> void:
	if not _active:
		return

	# Between clips: hold the final frame briefly, then roll to the next.
	if _gap_elapsed >= 0.0:
		_gap_elapsed += delta
		if _gap_elapsed >= inter_clip_gap:
			_advance_clip()
		return

	var prev_clock: float = _virtual_clock
	_virtual_clock += delta * playback_speed
	if _virtual_clock >= _clip_end_ts:
		_virtual_clock = _clip_end_ts
		_gap_elapsed = 0.0

	NetworkManager.set_replay_clock(_virtual_clock)

	if not _cursor.seek(_frames, _timestamps, _virtual_clock):
		return
	ReplayPlaybackEngine.apply_interpolated_snapshot(
			_cursor.from_snap(), _cursor.to_snap(), _cursor.alpha(), _cursor.bracket_dt(),
			_virtual_clock - prev_clock,
			_registry.all(), _puck, _goalie_controllers)
