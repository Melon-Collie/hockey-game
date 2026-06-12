class_name ReplayRecorder
extends RefCounted

# Shadows the host's 120 Hz world-state broadcast into a fixed-size in-memory
# circular buffer so GoalReplayDriver can extract the last N seconds on demand.
# Lives on the host only; created alongside WorldStateCodec in game_scene.gd.
#
# Also shadows transient game events (puck collisions, pickups, shots, body
# checks) into a parallel buffer so GoalReplayDriver can re-fire sounds + VFX
# in time with the visual replay. Without this the in-memory replay is silent
# because the live signals that drive sounds (puck.puck_hit_boards et al.)
# don't fire while physics is frozen.

# ~9 s at the 120 Hz broadcast rate (covers the 8 s clip + 0.5 s post-goal
# window). Was 360 from the 40 Hz era — at 120 Hz that held only 3 s, so goal
# replays were silently truncated to the last ~3 seconds.
const MEMORY_SIZE: int = 1080
const EVENT_MEMORY_SIZE: int = 720  # bursty (shots, body checks, deflections); size for headroom

var _frames: Array[PackedByteArray]
var _timestamps: Array[float]
var _ptr: int = 0
var _count: int = 0

var _events: Array[Dictionary] = []
var _event_timestamps: Array[float] = []
var _event_ptr: int = 0
var _event_count: int = 0


func setup() -> void:
	_frames.resize(MEMORY_SIZE)
	_timestamps.resize(MEMORY_SIZE)
	for i: int in MEMORY_SIZE:
		_frames[i] = PackedByteArray()
		_timestamps[i] = 0.0
	_ptr = 0
	_count = 0
	_events.resize(EVENT_MEMORY_SIZE)
	_event_timestamps.resize(EVENT_MEMORY_SIZE)
	for i: int in EVENT_MEMORY_SIZE:
		_events[i] = {}
		_event_timestamps[i] = 0.0
	_event_ptr = 0
	_event_count = 0


func record_frame(data: PackedByteArray, host_ts: float) -> void:
	_frames[_ptr] = data.duplicate()
	_timestamps[_ptr] = host_ts
	_ptr = (_ptr + 1) % MEMORY_SIZE
	_count = mini(_count + 1, MEMORY_SIZE)


func record_event(host_ts: float, event: Dictionary) -> void:
	_events[_event_ptr] = event
	_event_timestamps[_event_ptr] = host_ts
	_event_ptr = (_event_ptr + 1) % EVENT_MEMORY_SIZE
	_event_count = mini(_event_count + 1, EVENT_MEMORY_SIZE)


# Returns { frames: Array[PackedByteArray], timestamps: Array[float] } in
# chronological order covering the last `duration_secs` seconds.
# If fewer frames are available the full buffer is returned without error.
func extract_clip(duration_secs: float) -> Dictionary:
	if _count == 0:
		return {frames = [] as Array[PackedByteArray], timestamps = [] as Array[float]}

	var newest_ptr: int = (_ptr - 1 + MEMORY_SIZE) % MEMORY_SIZE
	var cutoff_ts: float = _timestamps[newest_ptr] - duration_secs

	# Walk backward from newest to find how many frames fall within the window.
	var include_count: int = 0
	for i: int in _count:
		var logical_newest: int = (_ptr - 1 - i + MEMORY_SIZE * 2) % MEMORY_SIZE
		if _timestamps[logical_newest] >= cutoff_ts:
			include_count += 1
		else:
			break

	# Oldest included frame index (logical order = chronological).
	var oldest_phys: int = (_ptr - include_count + MEMORY_SIZE * 2) % MEMORY_SIZE

	var out_frames: Array[PackedByteArray] = []
	var out_timestamps: Array[float] = []
	out_frames.resize(include_count)
	out_timestamps.resize(include_count)

	for i: int in include_count:
		var phys: int = (oldest_phys + i) % MEMORY_SIZE
		out_frames[i] = _frames[phys]
		out_timestamps[i] = _timestamps[phys]

	return {frames = out_frames, timestamps = out_timestamps}


# Events within [start_ts, end_ts] in chronological order. Returned as
# parallel { event, host_ts } pairs so consumers can compare against their
# virtual clock without re-deriving the sort.
func extract_events(start_ts: float, end_ts: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _event_count == 0:
		return out
	# Walk in chronological order. Oldest entry physical index = _event_ptr
	# when buffer is full, else 0.
	var oldest_phys: int = _event_ptr if _event_count == EVENT_MEMORY_SIZE else 0
	for i: int in _event_count:
		var phys: int = (oldest_phys + i) % EVENT_MEMORY_SIZE
		var ts: float = _event_timestamps[phys]
		if ts < start_ts:
			continue
		if ts > end_ts:
			break
		out.append({"event": _events[phys], "host_ts": ts})
	return out
