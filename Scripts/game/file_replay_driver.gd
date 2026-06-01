class_name FileReplayDriver
extends Node

# Scene-level driver for full-game .mreplay playback. Companion to
# GoalReplayDriver — both consume the same ReplayPlaybackEngine, but where
# GoalReplayDriver runs on the live host and freezes the simulation,
# FileReplayDriver runs in the offline ReplayViewer scene, walks an
# arbitrary virtual clock (with seek + speed control), and drives actors
# that have no networking attached.
#
# Setup expects a roster + frame list parsed from ReplayFileReader.read().
# World-state frames feed the playback engine; event frames (kind=="goal",
# "player_joined", "player_left", …) replay through event_emitted at their
# host_ts so the viewer can update HUD banners and roster on the fly.

@export var playback_speed: float = 1.0

# Brackets larger than this are treated as recording gaps (e.g. host's
# goal-replay window — broadcasts pause for ~8 s). Without special handling
# the interpolator would drift actors smoothly across the gap; instead we
# hold the FROM frame for _GAP_DWELL_S of virtual time so the moment that
# triggered the gap registers, then jump straight to the post-gap timestamp.
# Normal-play brackets are well under this (40 Hz = 25 ms; 5 Hz dead-puck
# phase = 200 ms; jitter adds tens of ms on top).
const _GAP_THRESHOLD_S: float = 0.5
# Dwell scales with playback_speed (uses virtual clock, not wall time) so
# at 4× the dwell flies by — consistent with the rest of playback where
# speed multiplies everything.
const _GAP_DWELL_S: float = 0.5

signal event_emitted(event: Dictionary)
# Fires after a backward seek so the viewer can rebuild the roster snapshot
# at the new clock. Forward play / forward seek don't need this — the
# event_emitted stream catches up by re-firing events between old and new
# clock. Backward goes the other way: events whose side effects already
# applied (a despawn, say) need to be undone. Cleanest fix is "tear down,
# rebuild from header, replay events ≤ t," and the viewer owns the spawn
# logic so the driver hands it the events list and lets it run the rebuild.
signal roster_rebuild_requested(events_through_t: Array)
signal game_state_changed(game_state: Dictionary)
signal playback_ended

var _codec: WorldStateCodec = null
# peer_id → PlayerRecord; built by the viewer from the .mreplay header roster.
# Avoids the heavyweight PlayerRegistry setup (state machine + teams + spawn
# wireup) that the live game uses.
var _records: Dictionary = {}
var _puck: Puck = null
var _goalie_controllers: Array[GoalieController] = []

# Filtered frame stream — index-aligned arrays keep _find_frame_idx hot
# without the per-frame Dictionary access cost.
var _frames: Array[PackedByteArray] = []
var _timestamps: Array[float] = []
# Goal events sorted by host_ts; replayed once each as virtual_clock crosses.
var _events: Array[Dictionary] = []
var _next_event_idx: int = 0

var _virtual_clock: float = 0.0
var _start_ts: float = 0.0
var _end_ts: float = 0.0
var _paused: bool = true
var _last_emitted_game_state: Dictionary = {}

# Bracket cache — re-decoded only when virtual_clock crosses a frame boundary.
var _cached_from_snap: Dictionary = {}
var _cached_to_snap: Dictionary = {}
var _cached_from_idx: int = -1
var _cached_to_idx: int = -1
# Forward-scan hint so _find_frame_idx stays O(1) when the clock advances
# normally; reset on backward seek.
var _frame_idx_hint: int = 0

# Set by any backward seek; cleared by commit_drag (or by a same-call seek
# when allow_rebuild=true). The viewer's roster rebuild queue_frees and
# respawns every actor, so doing it per-pixel during a slider drag produces
# a visible strobe. seek_drag() defers the rebuild until drag_ended.
var _has_pending_rebuild: bool = false


func setup(codec: WorldStateCodec,
		records: Dictionary,
		puck: Puck,
		goalie_controllers: Array,
		decoded_frames: Array) -> void:
	_codec = codec
	_records = records
	_puck = puck
	_goalie_controllers = []
	for gc: GoalieController in goalie_controllers:
		_goalie_controllers.append(gc)
	_frames.clear()
	_timestamps.clear()
	_events.clear()
	for entry: Dictionary in decoded_frames:
		var kind: int = entry.kind
		if kind == ReplayFileWriter.KIND_WORLD_STATE:
			_frames.append(entry.payload)
			_timestamps.append(entry.host_ts)
		elif kind == ReplayFileWriter.KIND_EVENT:
			var parsed: Variant = JSON.parse_string(
					(entry.payload as PackedByteArray).get_string_from_utf8())
			if parsed is Dictionary:
				_events.append({"host_ts": entry.host_ts, "data": parsed as Dictionary})
	if _frames.is_empty():
		return
	_start_ts = _timestamps[0]
	_end_ts = _timestamps[_timestamps.size() - 1]
	_virtual_clock = _start_ts
	# Mirror the virtual clock into NetworkManager._replay_clock so any code
	# path that consults estimated_host_time() during file replay (debug
	# overlays, draw callbacks, future ghost handling) sees the playback
	# timeline rather than 0. Sync the same way GoalReplayDriver does.
	NetworkManager.set_replay_clock(_virtual_clock)
	_paused = true


# ── Playback controls ────────────────────────────────────────────────────────

func play() -> void:
	if _frames.is_empty():
		return
	if _virtual_clock >= _end_ts:
		# End-of-replay restart — full backward seek with immediate rebuild.
		_seek_internal(_start_ts, true)
	_paused = false


func pause() -> void:
	_paused = true


func toggle_pause() -> void:
	if _paused:
		play()
	else:
		pause()


func is_paused() -> bool:
	return _paused


func seek(t: float) -> void:
	_seek_internal(clampf(t, _start_ts, _end_ts), true)


# Frame-step while paused. direction>0 jumps to the next recorded world-state
# frame, direction<0 to the previous. Uses the recorded host_ts (rather than a
# fixed delta) so gaps in the recording don't show up as a stalled step —
# stepping across the host's goal-replay window jumps in one press.
func step_frame(direction: int) -> void:
	if _frames.is_empty() or direction == 0:
		return
	var idx: int = _find_frame_idx(_virtual_clock)
	if idx < 0:
		idx = 0
	# Backward from an in-bracket clock should land on the bracket's FROM
	# frame (idx itself), not idx-1. Forward always jumps a full bracket.
	var target_idx: int
	if direction > 0:
		target_idx = idx + 1
	else:
		target_idx = idx if _virtual_clock > _timestamps[idx] else idx - 1
	target_idx = clampi(target_idx, 0, _timestamps.size() - 1)
	seek(_timestamps[target_idx])


# Lightweight seek used while the user is dragging the seek slider. Walks
# the clock and refreshes the visible frame, but defers the roster rebuild
# (queue_free + respawn of every actor — visible strobe at slider step
# granularity). drag_ended must call commit_drag() to flush the pending
# rebuild once at the final drag position.
func seek_drag(t: float) -> void:
	_seek_internal(clampf(t, _start_ts, _end_ts), false)


# Flush a pending roster rebuild queued by seek_drag. Idempotent — no-op if
# nothing is pending (e.g. the drag never went backward, or commit was
# already called).
func commit_drag() -> void:
	_maybe_emit_pending_rebuild()


func _seek_internal(t: float, allow_rebuild: bool) -> void:
	var was_backward: bool = t < _virtual_clock
	if was_backward:
		_frame_idx_hint = 0  # backward seek invalidates forward scan hint
		_has_pending_rebuild = true
	_virtual_clock = t
	_cached_from_idx = -1
	_cached_to_idx = -1
	_next_event_idx = _find_next_event_idx(_virtual_clock)
	# Refresh the visible frame immediately when paused so the world snaps
	# to the new clock instead of waiting for the next play. _process is
	# early-returning while paused, so the apply has to be inline here.
	if _paused:
		_apply_current_frame(0.0)
		_emit_due_events()
	if allow_rebuild:
		_maybe_emit_pending_rebuild()


func _maybe_emit_pending_rebuild() -> void:
	if not _has_pending_rebuild:
		return
	_has_pending_rebuild = false
	var snapshot: Array = []
	for i: int in _next_event_idx:
		snapshot.append(_events[i].data)
	roster_rebuild_requested.emit(snapshot)


# ── Read accessors for the viewer HUD ────────────────────────────────────────

func get_virtual_clock() -> float:
	return _virtual_clock


func get_start_ts() -> float:
	return _start_ts


func get_end_ts() -> float:
	return _end_ts


func get_duration() -> float:
	return _end_ts - _start_ts


func get_progress() -> float:
	var dur: float = get_duration()
	return (_virtual_clock - _start_ts) / dur if dur > 0.0 else 0.0


# Goal events sorted by host_ts. Caller can build jump-to-goal buttons.
func get_events() -> Array[Dictionary]:
	return _events.duplicate()


# ── Driving ──────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	if _paused or _frames.is_empty():
		return
	_virtual_clock += delta * playback_speed
	_skip_recording_gaps()
	# Pass the virtual-time advance (playback-speed-scaled), not the wall-frame
	# delta, so the skater leg gait strides in cadence with on-screen motion at
	# any playback speed. Seeks call _apply_current_frame(0.0) — no advance.
	var sim_delta: float = delta * playback_speed
	if _virtual_clock >= _end_ts:
		_virtual_clock = _end_ts
		_paused = true
		_apply_current_frame(sim_delta)
		_emit_due_events()
		playback_ended.emit()
		return
	_apply_current_frame(sim_delta)
	_emit_due_events()


# When the virtual clock would otherwise sit on a gap bracket (host paused
# broadcasting during a goal-replay cinematic, or any future broadcast
# pause), jump straight to the post-gap timestamp so the viewer doesn't
# stare at a frozen goal-moment frame for 8 wall-clock seconds. Goal
# events are still surfaced because _emit_due_events catches anything
# with host_ts <= the new virtual_clock on the next tick.
func _skip_recording_gaps() -> void:
	var idx: int = _find_frame_idx(_virtual_clock)
	if idx < 0 or idx >= _frames.size() - 1:
		return
	var bracket_dt: float = _timestamps[idx + 1] - _timestamps[idx]
	if bracket_dt <= _GAP_THRESHOLD_S:
		return
	# Hold the FROM frame for _GAP_DWELL_S of virtual time so the moment
	# that triggered the gap (goal, period end) registers visually before
	# the snap.
	if _virtual_clock - _timestamps[idx] < _GAP_DWELL_S:
		return
	_virtual_clock = _timestamps[idx + 1]


func _apply_current_frame(sim_delta: float) -> void:
	# Keep NetworkManager._replay_clock in lockstep with the virtual clock
	# so estimated_host_time() reflects playback position rather than 0.
	# Mirrors GoalReplayDriver._process. Set every apply (rather than once
	# per _process tick) so seek-while-paused keeps the clock fresh too.
	NetworkManager.set_replay_clock(_virtual_clock)
	var idx: int = _find_frame_idx(_virtual_clock)
	if idx < 0:
		return
	var idx_next: int = mini(idx + 1, _frames.size() - 1)
	if idx != _cached_from_idx or idx_next != _cached_to_idx:
		_cached_from_snap = _codec.decode_for_replay(_frames[idx])
		_cached_to_snap = _codec.decode_for_replay(_frames[idx_next])
		_cached_from_idx = idx
		_cached_to_idx = idx_next
	if _cached_from_snap.is_empty():
		return
	var bracket_dt: float = _timestamps[idx_next] - _timestamps[idx]
	var t: float
	if bracket_dt > _GAP_THRESHOLD_S:
		t = 0.0  # hold FROM across the gap; snap when clock reaches TO
	elif bracket_dt > 0.0:
		t = clampf((_virtual_clock - _timestamps[idx]) / bracket_dt, 0.0, 1.0)
	else:
		t = 0.0
	ReplayPlaybackEngine.apply_interpolated_snapshot(
			_cached_from_snap, _cached_to_snap, t, bracket_dt, sim_delta,
			_records, _puck, _goalie_controllers)
	# Emit game-state changes (score / phase / period / clock) so the viewer
	# HUD doesn't have to poll every tick. Compare-and-emit avoids spamming
	# subscribers with the same dict every frame.
	var gs: Dictionary = _cached_to_snap.get("game_state", {})
	if not gs.is_empty() and gs != _last_emitted_game_state:
		_last_emitted_game_state = gs
		game_state_changed.emit(gs)


func _emit_due_events() -> void:
	while _next_event_idx < _events.size() and _events[_next_event_idx].host_ts <= _virtual_clock:
		event_emitted.emit(_events[_next_event_idx].data)
		_next_event_idx += 1


# Linear scan starting from the last successful index. When the clock
# advances normally this is O(1) per frame; backward seeks reset the hint
# so a worst-case seek-to-start is still O(N).
func _find_frame_idx(t: float) -> int:
	if _frame_idx_hint > 0 and _timestamps[_frame_idx_hint] > t:
		_frame_idx_hint = 0
	var best: int = -1
	for i: int in range(_frame_idx_hint, _timestamps.size()):
		if _timestamps[i] <= t:
			best = i
		else:
			break
	if best >= 0:
		_frame_idx_hint = best
	return best


func _find_next_event_idx(t: float) -> int:
	for i: int in _events.size():
		if _events[i].host_ts > t:
			return i
	return _events.size()
