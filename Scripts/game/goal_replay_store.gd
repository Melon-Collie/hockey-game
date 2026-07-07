class_name GoalReplayStore
extends RefCounted

# Persistent per-game list of goal clips, one per goal scored. The live
# GoalReplayDriver extracts + trims a clip from the ~9 s ReplayRecorder ring
# buffer on every goal; that ring only holds the last few seconds, so by
# game-over it no longer contains earlier goals. This store shadows a copy of
# each trimmed clip as it plays so PostGameReplayDriver can loop through ALL of
# them behind the final-score screen.
#
# Lives on every peer (host + clients each run their own GoalReplayDriver and
# capture their own copies). Cleared at match start / rematch rollover.

# Blowouts are rare in 3v3, but cap so a runaway score can't grow memory
# without bound. Oldest goal drops first when over the cap.
const MAX_CLIPS: int = 24

# Each entry: { frames: Array[PackedByteArray], timestamps: Array[float],
#               start_ts: float, end_ts: float }. start_ts is the trimmed
# clip start (the play that scored), not necessarily timestamps[0].
var _clips: Array[Dictionary] = []


func add(clip: Dictionary) -> void:
	var frames: Array[PackedByteArray] = clip.get("frames", [] as Array[PackedByteArray])
	var timestamps: Array[float] = clip.get("timestamps", [] as Array[float])
	# A clip needs at least two frames to interpolate a bracket.
	if frames.size() < 2 or timestamps.size() < 2:
		return
	# Duplicate the arrays so a later GoalReplayDriver.stop() (which rebinds its
	# own _frames/_timestamps) can never disturb what we hold. Shallow copy —
	# the PackedByteArray elements are never mutated after recording.
	_clips.append({
		"frames": frames.duplicate(),
		"timestamps": timestamps.duplicate(),
		"start_ts": float(clip.get("start_ts", timestamps[0])),
		"end_ts": float(clip.get("end_ts", timestamps[timestamps.size() - 1])),
	})
	if _clips.size() > MAX_CLIPS:
		_clips.pop_front()


func clear() -> void:
	_clips.clear()


func size() -> int:
	return _clips.size()


func is_empty() -> bool:
	return _clips.is_empty()


# Returns the stored clips in scoring order. Caller must not mutate the frame
# arrays (they're shared references), only read them for playback.
func clips() -> Array[Dictionary]:
	return _clips
