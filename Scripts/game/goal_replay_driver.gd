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
#
# Testing: no headless unit test — this extends Node and drives LIVE scene
# actors (Skater / Puck / Goalie nodes) via the actor-driven
# ReplayPlaybackEngine, so it's integration-only (a live scene, poor headless
# ROI). The unit-testable pieces it composes ARE covered: the codec's
# side-effect-free decode_for_replay (test_world_state_codec), ReplayRecorder
# (test_replay_recorder), and GoalReplayStore (test_goal_replay_store).
# Consciously accepted as integration-only — see the closed GH issue on
# agent-SM / replay-driver coverage gaps.

const CLIP_DURATION: float = 8.0  # seconds of history to replay

@export var playback_speed: float = 1.0
@export var slowmo_window: float = 0.75  # fallback offset before clip end (used when no shot event present)
@export var slowmo_speed: float = 0.4    # playback multiplier during slow-motion window
@export var outro_duration: float = 0.25 # extra hold at clip end before stopping
@export var pre_shot_lead: float = 0.0   # offset before shot release where slow-mo + cut fire. 0 = on release.

# Adaptive clip-start tuning. Walks "puck_pickup" events backward from the shot
# to find the scoring possession's start. Within a tight gap, chained pickups
# (assists / tic-tac-toe) extend the clip naturally. When the only pickup is a
# single long carry, we use a fixed pre-shot floor instead of showing the whole
# carry. On top of that, a scrappy net-front goal — a scramble of jams, rebounds,
# and stick battles — is cut to its LAST decisive contest (hit / stickcheck /
# strip / tip) rather than replaying the whole pile-up. See
# _compute_trimmed_clip_start_ts() for the algorithm.
@export var pickup_chain_gap: float = 2.0    # max gap between consecutive pickups still in the chain
@export var pre_pickup_buffer: float = 0.5   # extra time shown before the earliest chained pickup
@export var pre_contest_buffer: float = 0.75 # extra time shown before the last hit/stickcheck/tip when it cuts the clip
@export var min_pre_shot: float = 1.5        # floor when chain captures pickups (or no pickup found)
@export var min_pre_shot_long_carry: float = 3.0  # floor when a pickup exists but the chain didn't capture it
@export var max_pre_shot: float = 6.5        # ceiling on how far before the shot we'll trim back to

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

# Which recorded frames bracket the virtual clock, decoded once per bracket.
var _cursor := ReplayFrameCursor.new()

var _sim_hold := ReplayLiveSimHold.new()

var _outro_elapsed: float = -1.0  # >= 0 while holding the final frame
# Two replay cameras: hard cam (broadcast main, current at clip start) and
# inside-net cam (parked behind the defending goal). At slow-mo entry the
# driver cuts to the inside-net cam for the climactic frame. The driver
# tracks _saved_prev_camera itself so we can drive make_current() on either
# cam directly without fighting SpectatorCamera's single-cam activate flow.
var _hard_cam: SpectatorCamera = null
var _inside_net_cam: SpectatorCamera = null
var _saved_prev_camera: Camera3D = null
var _has_cut_to_inside_net: bool = false
# Z position of the defending goal — drives the inside-net cam placement.
# Defaults to 0 (no cut) so the replay still works if the caller didn't supply
# a defending goal (e.g. a future debug-trigger path).
var _defending_goal_z: float = 0.0
# Shot release timestamp + position, pulled from the clip's recorded events on
# start(). Drives both slow-mo entry timing (so the wind-up + release land in
# slo-mo regardless of where in the clip the shot happened) and the behind-net
# cam's lateral offset (mirror the shooter so the trajectory crosses frame
# diagonally). _shot_event_ts < 0 means no shot event was found — fall back
# to the slowmo_window-from-clip-end timing.
var _shot_event_ts: float = -1.0
var _shot_release_pos: Vector3 = Vector3.ZERO

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
		goalie_controllers: Array,
		defending_goal_z: float = 0.0) -> void:
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
	_cursor.bind(codec)
	_cursor.reset()
	_outro_elapsed = -1.0
	_active = true
	# Pull recorded events for the clip window and reset the walker so the
	# first _process tick fires anything queued at the start of the clip.
	_events = recorder.extract_events(_clip_start_ts, _clip_end_ts)
	_next_event_idx = 0

	# Scan for the last "shot" event in the clip — that's the goal shot.
	# Both regular shots and one-timers record under the same kind. We use the
	# event's recorded puck-position as the shooter's release position; it's
	# captured at release time in GameManager._record_replay_audio_event.
	_shot_event_ts = -1.0
	_shot_release_pos = Vector3.ZERO
	for entry: Dictionary in _events:
		var ev: Dictionary = entry.event
		if ev.has("kind") and ev.kind == "shot":
			_shot_event_ts = entry.host_ts
			var p: Array = ev.pos
			_shot_release_pos = Vector3(p[0], p[1], p[2])

	# Trim the clip start to "the play that scored." Walks puck_pickup events
	# backward from the shot, extending through consecutive pickups within
	# pickup_chain_gap (assist chain), and falls back to a fixed long-carry
	# floor when there's only one pickup well before the shot.
	var trimmed_start: float = _compute_trimmed_clip_start_ts()
	if trimmed_start > _clip_start_ts:
		_clip_start_ts = trimmed_start
		_virtual_clock = trimmed_start
		while _next_event_idx < _events.size() and _events[_next_event_idx].host_ts < trimmed_start:
			_next_event_idx += 1

	_sim_hold.grab(_puck, _goalie_controllers)

	_defending_goal_z = defending_goal_z
	_has_cut_to_inside_net = false
	_saved_prev_camera = get_viewport().get_camera_3d()

	var puck_pos_getter: Callable = func() -> Vector3: return _puck.global_position
	_hard_cam = SpectatorCamera.new()
	add_child(_hard_cam)
	_hard_cam.setup(puck_pos_getter)
	_hard_cam.snap_to_position()
	_hard_cam.make_current()

	# Behind-the-net cam parked past the end boards, elevated, with a lateral
	# offset based on the shot release. The X-mirror places the camera on the
	# opposite side from the shooter so the trajectory crosses the camera's
	# line of sight diagonally instead of head-on — angles the look-direction
	# toward the shooter, per the user's reference. Skipped if no defending
	# goal was provided.
	if _defending_goal_z != 0.0:
		_inside_net_cam = SpectatorCamera.new()
		add_child(_inside_net_cam)
		_inside_net_cam.setup(puck_pos_getter)
		var z_sign: float = signf(_defending_goal_z)
		var lateral: float = 0.0
		if _shot_event_ts >= 0.0:
			lateral = clampf(-_shot_release_pos.x * 0.5, -3.5, 3.5)
		var booth: Vector3 = Vector3(lateral, 3.0, _defending_goal_z + z_sign * 4.5)
		_inside_net_cam.set_booth(booth, 55.0, 0.15)
		_inside_net_cam.snap_to_position()

	# The hard cam is the far press-box shot; widen the 3D sound falloff so the
	# recorded events stay audible from that distance (the inside-net cut below
	# drops to the gentler near preset). Restored to LIVE in stop().
	SoundManager.set_world_audio_range(SoundManager.AudioRange.REPLAY_FAR)

	NetworkManager.start_replay_mode(_clip_start_ts)
	replay_started.emit()


func stop() -> void:
	if not _active:
		return
	_active = false
	_outro_elapsed = -1.0

	if _saved_prev_camera != null and is_instance_valid(_saved_prev_camera):
		_saved_prev_camera.make_current()
	_saved_prev_camera = null
	if _hard_cam != null:
		_hard_cam.queue_free()
		_hard_cam = null
	if _inside_net_cam != null:
		_inside_net_cam.queue_free()
		_inside_net_cam = null
	_has_cut_to_inside_net = false

	# Restore the live 3D sound falloff (widened for the replay cameras above).
	SoundManager.set_world_audio_range(SoundManager.AudioRange.LIVE)

	NetworkManager.stop_replay_mode()
	_sim_hold.release()
	_frames = []
	_timestamps = []
	_cursor.reset()
	_events = []
	_next_event_idx = 0
	_codec = null
	_registry = null
	_puck = null
	_goalies = []
	_goalie_controllers = []
	replay_stopped.emit()


func is_active() -> bool:
	return _active


# Snapshot of the clip currently being replayed, for GoalReplayStore to keep a
# copy that outlives the ~9 s recorder ring. start_ts is the TRIMMED start (the
# play that scored) so the post-game loop begins where the live cinematic did,
# not at the raw 8 s clip head. Valid between replay_started and replay_stopped.
func get_active_clip() -> Dictionary:
	return {
		"frames": _frames,
		"timestamps": _timestamps,
		"start_ts": _clip_start_ts,
		"end_ts": _clip_end_ts,
	}


func _process(delta: float) -> void:
	if not _active:
		return

	# Outro: hold the final frame for outro_duration real seconds then stop.
	if _outro_elapsed >= 0.0:
		_outro_elapsed += delta
		if _outro_elapsed >= outro_duration:
			stop()
		return

	# Anchor slow-mo to shot release if we have one — pre_shot_lead seconds of
	# wind-up plus the release land in slow-mo. Fall back to clip-end offset
	# for clips with no shot event (deflection-style goals, etc.).
	var slowmo_trigger_ts: float = _shot_event_ts - pre_shot_lead \
			if _shot_event_ts >= 0.0 else _clip_end_ts - slowmo_window
	var in_slowmo: bool = _virtual_clock >= slowmo_trigger_ts
	var speed: float = slowmo_speed if in_slowmo else playback_speed
	var prev_clock: float = _virtual_clock
	_virtual_clock += delta * speed
	if _virtual_clock >= _clip_end_ts:
		_virtual_clock = _clip_end_ts
		_outro_elapsed = 0.0

	# Cut to the inside-net cam at slow-mo entry — the broadcast money shot.
	# Single one-way cut per clip; we don't cut back to the hard cam during
	# the outro hold (the climax frame stays on screen until stop()).
	if in_slowmo and not _has_cut_to_inside_net and _inside_net_cam != null:
		_inside_net_cam.snap_to_position()
		_inside_net_cam.make_current()
		_has_cut_to_inside_net = true
		# Behind-the-net cam is close to the puck — drop from the wide hard-cam
		# falloff to the gentler near preset so the climax stays audible without
		# over-amplifying at point-blank range.
		SoundManager.set_world_audio_range(SoundManager.AudioRange.REPLAY_NEAR)

	NetworkManager.set_replay_clock(_virtual_clock)

	if not _cursor.seek(_frames, _timestamps, _virtual_clock):
		return
	# Pass the virtual-clock advance (slow-mo-scaled, exactly clamped at clip end)
	# rather than the wall-frame delta, so procedural pose driven off it — the
	# skater leg gait — keeps cadence with the on-screen motion during slow-mo.
	ReplayPlaybackEngine.apply_interpolated_snapshot(
			_cursor.from_snap(), _cursor.to_snap(), _cursor.alpha(), _cursor.bracket_dt(),
			_virtual_clock - prev_clock,
			_registry.all(), _puck, _goalie_controllers)
	_dispatch_due_events()


# Walk events whose timestamps have passed the virtual clock and fire each
# one through ReplayEventReplayer so puck-collision sounds, pickup sounds,
# shot sounds, and body-check sound+VFX play in time with the cinematic.
func _dispatch_due_events() -> void:
	while _next_event_idx < _events.size() \
			and _events[_next_event_idx].host_ts <= _virtual_clock:
		ReplayEventReplayer.dispatch(_events[_next_event_idx].event, _registry)
		_next_event_idx += 1


# Finds where the scoring play started. Two anchors, whichever sits closer to
# the shot wins (so a late scramble touch shortens the clip rather than the
# possession chain dragging it back through a whole pile-up):
#   - the pickup-chain possession start (assists / tic-tac-toe / long carry —
#     see _pickup_chain_start_ts), and
#   - the last decisive CONTEST before the shot (hit / stickcheck / strip / tip
#     — see _last_contest_event_ts). A jammy net-front goal chains a pile of
#     pickups back through the scramble; cutting to its final contest instead
#     shows "the last hit/stickcheck/tip and the goal," not the whole pile-up.
# Result is clamped to (shot_ts - max_pre_shot, shot_ts - min_pre_shot), so the
# clip is never shorter than min_pre_shot even when the contest was point-blank.
func _compute_trimmed_clip_start_ts() -> float:
	if _shot_event_ts < 0.0:
		return _clip_start_ts  # no shot event — keep the full clip
	var play_start: float = _pickup_chain_start_ts()
	var contest_ts: float = _last_contest_event_ts()
	if contest_ts >= 0.0:
		play_start = maxf(play_start, contest_ts - pre_contest_buffer)
	return clampf(play_start, _shot_event_ts - max_pre_shot, _shot_event_ts - min_pre_shot)


# The pickup-chain possession start. Three cases:
#   - Chain of pickups within pickup_chain_gap: extends through them (assists,
#     tic-tac-toe). Starts pre_pickup_buffer before the earliest chain pickup.
#   - Single pickup well before the shot (long single carry): floor to
#     min_pre_shot_long_carry — show only the last few seconds, not the whole carry.
#   - No pickups at all (faceoff scramble, weird scenarios): use the standard
#     min_pre_shot floor.
func _pickup_chain_start_ts() -> float:
	var play_start: float = _shot_event_ts
	var prev_ts: float = _shot_event_ts
	var has_any_pickup: bool = false
	# _events is sorted ascending by host_ts — walk back from the end.
	for i: int in range(_events.size() - 1, -1, -1):
		var entry: Dictionary = _events[i]
		var ev: Dictionary = entry.event
		if not (ev.has("kind") and ev.kind == "puck_pickup"):
			continue
		var ts: float = entry.host_ts
		if ts >= _shot_event_ts:
			continue
		has_any_pickup = true
		if prev_ts - ts > pickup_chain_gap:
			break
		play_start = ts
		prev_ts = ts
	if play_start == _shot_event_ts:
		# No chain captured. Long-carry floor if a pickup exists somewhere
		# earlier in the clip; otherwise standard floor.
		var floor_seconds: float = min_pre_shot_long_carry if has_any_pickup else min_pre_shot
		return _shot_event_ts - clampf(floor_seconds, min_pre_shot, max_pre_shot)
	return play_start - pre_pickup_buffer


# Timestamp of the last "contest" event strictly before the shot — a body check
# (hit), stick lift (stickcheck), poke strip, or deflection (tip). These mark
# the decisive touches of a net-front scramble. Returns -1.0 when the scoring
# play had none (a clean rush), so the pickup chain alone drives the clip start.
func _last_contest_event_ts() -> float:
	for i: int in range(_events.size() - 1, -1, -1):
		var entry: Dictionary = _events[i]
		var ev: Dictionary = entry.event
		if not ev.has("kind"):
			continue
		var kind: String = ev.kind
		if kind != "body_check" and kind != "stick_lift" \
				and kind != "puck_strip" and kind != "puck_deflection":
			continue
		var ts: float = entry.host_ts
		if ts >= _shot_event_ts:
			continue
		return ts
	return -1.0
