class_name GoalReplayDriver
extends Node

# Drives in-game goal replay on the HOST by:
#   1. Extracting the last CLIP_DURATION seconds from ReplayRecorder on goal.
#   2. Freezing live host physics (puck) so authoritative simulation
#      doesn't fight the replay positions.
#   3. Decoding each recorded packet into typed actor states (via the codec's
#      side-effect-free decode_for_replay) and applying them directly to the
#      Skater / Puck nodes.
#   4. Freezing goalie AI and applying recorded GoalieNetworkState (position,
#      rotation, state_enum, five_hole_openness) so poses reflect what happened.
#
# Bypasses WorldStateCodec.decode_world_state because that path mutates the
# host's GameStateMachine — replaying a packet would slam phase / score / clock
# back to whatever was captured before the goal.
#
# Owned by GameManager (host only). start() / stop() called from there.

const CLIP_DURATION: float = 8.0  # seconds of history to replay

@export var playback_speed: float = 1.0
@export var slowmo_window: float = 0.75  # seconds before clip end that slow-motion kicks in
@export var slowmo_speed: float = 0.4    # playback multiplier during slow-motion window
@export var outro_duration: float = 0.25 # extra hold at clip end before stopping

signal replay_started
signal replay_stopped

var _codec: WorldStateCodec = null
var _registry: PlayerRegistry = null
var _puck: Puck = null
var _goalies: Array[Goalie] = []
var _goalie_controllers: Array[GoalieController] = []

var _frames: Array[PackedByteArray] = []
var _timestamps: Array[float] = []
var _clip_start_ts: float = 0.0
var _clip_end_ts: float = 0.0
var _virtual_clock: float = 0.0
var _active: bool = false

# Bracket cache — re-decoded only when the virtual clock crosses a frame boundary.
var _cached_from_snap: Dictionary = {}
var _cached_to_snap: Dictionary = {}
var _cached_from_idx: int = -1
var _cached_to_idx: int = -1

var _saved_goalie_processing: Array[bool] = []

var _outro_elapsed: float = -1.0  # >= 0 while holding the final frame
var _spectator_cam: SpectatorCamera = null

# Vote-to-skip tally for the current clip, keyed by peer_id. Cleared on every
# start() so a previous goal's votes don't carry over. Driven by
# GameManager.request_local_skip_vote / _on_remote_skip_replay_request.
var _skip_votes: Dictionary[int, bool] = {}

# Audio + body-check VFX events extracted from the recorder, ordered by
# host_ts. We walk these in lockstep with the virtual clock so the cinematic
# re-fires the sounds and burst VFX that played live — see
# ReplayEventReplayer for the actual dispatch.
var _events: Array[Dictionary] = []
var _next_event_idx: int = 0


func start(recorder: ReplayRecorder,
		codec: WorldStateCodec,
		registry: PlayerRegistry,
		puck: Puck,
		goalie_controllers: Array) -> void:
	if _active:
		stop()

	var clip: Dictionary = recorder.extract_clip(CLIP_DURATION)
	var frames: Array[PackedByteArray] = clip.frames
	var timestamps: Array[float] = clip.timestamps
	if frames.size() < 2:
		return

	_codec = codec
	_registry = registry
	_puck = puck
	_goalie_controllers = []
	_goalies = []
	for gc: GoalieController in goalie_controllers:
		_goalie_controllers.append(gc)
		_goalies.append(gc.goalie)

	_frames = frames
	_timestamps = timestamps
	_clip_start_ts = timestamps[0]
	_clip_end_ts = timestamps[timestamps.size() - 1]
	_virtual_clock = _clip_start_ts
	_cached_from_idx = -1
	_cached_to_idx = -1
	_outro_elapsed = -1.0
	_skip_votes.clear()
	_active = true
	# Pull recorded events for the clip window and reset the walker so the
	# first _process tick fires anything queued at the start of the clip.
	_events = recorder.extract_events(_clip_start_ts, _clip_end_ts)
	_next_event_idx = 0

	_freeze_live_simulation()

	_spectator_cam = SpectatorCamera.new()
	add_child(_spectator_cam)
	_spectator_cam.setup(func() -> Vector3: return _puck.global_position)
	_spectator_cam.activate()

	NetworkManager.start_replay_mode(_clip_start_ts)
	replay_started.emit()


func stop() -> void:
	if not _active:
		return
	_active = false
	_outro_elapsed = -1.0

	if _spectator_cam != null:
		_spectator_cam.deactivate()
		_spectator_cam.queue_free()
		_spectator_cam = null

	NetworkManager.stop_replay_mode()
	_unfreeze_live_simulation()
	_frames = []
	_timestamps = []
	_cached_from_snap = {}
	_cached_to_snap = {}
	_cached_from_idx = -1
	_cached_to_idx = -1
	_events = []
	_next_event_idx = 0
	_codec = null
	_registry = null
	_puck = null
	_goalies = []
	_goalie_controllers = []
	_skip_votes.clear()
	replay_stopped.emit()


func is_active() -> bool:
	return _active


# Host-only: record a vote-to-skip. Returns the new vote count (0 if rejected
# because the replay isn't active). Each peer can only vote once per clip;
# duplicate votes are no-ops. When the tally reaches total_voters, the driver
# stops itself, which triggers the existing post-goal advance flow on the host.
func register_skip_vote(peer_id: int, total_voters: int) -> int:
	if not _active:
		return 0
	_skip_votes[peer_id] = true
	var count: int = _skip_votes.size()
	if count >= total_voters and total_voters > 0:
		stop()
	return count


func get_skip_vote_count() -> int:
	return _skip_votes.size()


func _process(delta: float) -> void:
	if not _active:
		return

	# Outro: hold the final frame for outro_duration real seconds then stop.
	if _outro_elapsed >= 0.0:
		_outro_elapsed += delta
		if _outro_elapsed >= outro_duration:
			stop()
		return

	var speed: float = slowmo_speed if (_clip_end_ts - _virtual_clock) < slowmo_window else playback_speed
	_virtual_clock += delta * speed
	if _virtual_clock >= _clip_end_ts:
		_virtual_clock = _clip_end_ts
		_outro_elapsed = 0.0

	NetworkManager.set_replay_clock(_virtual_clock)

	var idx: int = _find_frame_idx(_virtual_clock)
	if idx < 0:
		return
	var idx_next: int = mini(idx + 1, _frames.size() - 1)

	# Re-decode only when the bracket changes (every ~25 ms at 40 Hz).
	if idx != _cached_from_idx or idx_next != _cached_to_idx:
		_cached_from_snap = _codec.decode_for_replay(_frames[idx])
		_cached_to_snap = _codec.decode_for_replay(_frames[idx_next])
		_cached_from_idx = idx
		_cached_to_idx = idx_next

	if _cached_from_snap.is_empty():
		return

	var bracket_dt: float = _timestamps[idx_next] - _timestamps[idx]
	var t: float = clampf((_virtual_clock - _timestamps[idx]) / bracket_dt, 0.0, 1.0) \
			if bracket_dt > 0.0 else 0.0
	_apply_interpolated_snapshot(t, bracket_dt, delta)
	_dispatch_due_events()


# Walk events whose timestamps have passed the virtual clock and fire each
# one through ReplayEventReplayer so puck-collision sounds, pickup sounds,
# shot sounds, and body-check sound+VFX play in time with the cinematic.
func _dispatch_due_events() -> void:
	while _next_event_idx < _events.size() \
			and _events[_next_event_idx].host_ts <= _virtual_clock:
		ReplayEventReplayer.dispatch(_events[_next_event_idx].event, _registry)
		_next_event_idx += 1


func _find_frame_idx(t: float) -> int:
	var best: int = -1
	for i: int in _timestamps.size():
		if _timestamps[i] <= t:
			best = i
		else:
			break
	return best


func _apply_interpolated_snapshot(t: float, dt: float, delta: float) -> void:
	ReplayPlaybackEngine.apply_interpolated_snapshot(
			_cached_from_snap, _cached_to_snap, t, dt, delta,
			_registry.all(), _puck, _goalie_controllers)


func _freeze_live_simulation() -> void:
	if _puck != null:
		_puck.freeze = true
	_saved_goalie_processing.clear()
	for gc: GoalieController in _goalie_controllers:
		_saved_goalie_processing.append(gc.is_physics_processing())
		gc.set_physics_process(false)


func _unfreeze_live_simulation() -> void:
	# puck.freeze is intentionally not restored: after stop() the game transitions
	# to FACEOFF_PREP which calls puck.reset(), unconditionally setting freeze=false.
	# Restoring a saved value here could re-freeze the puck before reset() runs.
	if _puck != null:
		_puck.freeze = false
	for i: int in _goalie_controllers.size():
		var was: bool = _saved_goalie_processing[i] if i < _saved_goalie_processing.size() else true
		_goalie_controllers[i].set_physics_process(was)
	_saved_goalie_processing.clear()
