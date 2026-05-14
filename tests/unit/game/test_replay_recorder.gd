extends GutTest

# ReplayRecorder — in-memory circular buffer of world-state frames.
# Tests verify that extract_clip returns the correct chronological subset.

var _recorder: ReplayRecorder = null


func before_each() -> void:
	_recorder = ReplayRecorder.new()
	_recorder.setup()


func _fill(count: int, interval_sec: float = 0.025) -> void:
	for i: int in count:
		var data := PackedByteArray()
		data.resize(4)
		data.encode_u32(0, i)          # store frame index as payload for easy verification
		_recorder.record_frame(data, float(i) * interval_sec)


func test_empty_recorder_returns_empty_clip() -> void:
	var clip: Dictionary = _recorder.extract_clip(5.0)
	assert_eq(clip.frames.size(), 0)
	assert_eq(clip.timestamps.size(), 0)


func test_single_frame_returns_itself() -> void:
	_recorder.record_frame(PackedByteArray([1, 2, 3]), 1.0)
	var clip: Dictionary = _recorder.extract_clip(5.0)
	assert_eq(clip.frames.size(), 1)
	assert_eq(clip.timestamps[0], 1.0)


func test_extract_clip_returns_chronological_order() -> void:
	_fill(10)  # timestamps 0.000 … 0.225
	var clip: Dictionary = _recorder.extract_clip(5.0)
	assert_eq(clip.frames.size(), 10)
	for i: int in clip.timestamps.size() - 1:
		assert_true(clip.timestamps[i] < clip.timestamps[i + 1],
				"timestamps must be strictly ascending")


func test_extract_clip_respects_duration_window() -> void:
	_fill(200)  # timestamps 0.000 … 4.975 s (at 40 Hz = 0.025 s each)
	var clip: Dictionary = _recorder.extract_clip(2.0)
	assert_gt(clip.frames.size(), 0)
	var newest_ts: float = clip.timestamps[clip.timestamps.size() - 1]
	var oldest_ts: float = clip.timestamps[0]
	assert_almost_eq(newest_ts - oldest_ts, 2.0, 0.03,
			"clip duration should be approximately 2 seconds")


func test_extract_clip_does_not_exceed_available_frames() -> void:
	_fill(10)
	var clip: Dictionary = _recorder.extract_clip(100.0)
	assert_eq(clip.frames.size(), 10)


func test_frames_and_timestamps_are_parallel() -> void:
	_fill(20)
	var clip: Dictionary = _recorder.extract_clip(5.0)
	assert_eq(clip.frames.size(), clip.timestamps.size(),
			"frames and timestamps arrays must have equal length")


func test_circular_overwrite_returns_newest_data() -> void:
	# Fill the entire 200-slot buffer then overwrite some slots.
	_fill(200)
	# Record 10 more frames with high timestamps so they are the newest.
	for i: int in 10:
		var data := PackedByteArray()
		data.resize(4)
		data.encode_u32(0, 9000 + i)
		_recorder.record_frame(data, 100.0 + float(i) * 0.025)
	var clip: Dictionary = _recorder.extract_clip(1.0)
	# The newest frame in the clip must be in the high-timestamp range.
	var newest_ts: float = clip.timestamps[clip.timestamps.size() - 1]
	assert_gt(newest_ts, 99.0)


func test_frame_payload_is_preserved() -> void:
	var original := PackedByteArray([10, 20, 30, 40])
	_recorder.record_frame(original, 0.5)
	var clip: Dictionary = _recorder.extract_clip(1.0)
	assert_eq(clip.frames.size(), 1)
	var recovered: PackedByteArray = clip.frames[0]
	assert_eq(recovered, original)


# ── Events ────────────────────────────────────────────────────────────────────

func test_extract_events_returns_empty_when_none_recorded() -> void:
	var events: Array[Dictionary] = _recorder.extract_events(0.0, 100.0)
	assert_eq(events.size(), 0)


func test_extract_events_chronological_within_window() -> void:
	_recorder.record_event(0.5, {"kind": "puck_boards"})
	_recorder.record_event(1.0, {"kind": "puck_post"})
	_recorder.record_event(1.5, {"kind": "puck_pickup"})
	_recorder.record_event(2.0, {"kind": "shot"})
	var events: Array[Dictionary] = _recorder.extract_events(1.0, 1.75)
	assert_eq(events.size(), 2)
	assert_eq(events[0].event.kind, "puck_post")
	assert_eq(events[0].host_ts, 1.0)
	assert_eq(events[1].event.kind, "puck_pickup")
	assert_eq(events[1].host_ts, 1.5)


func test_extract_events_full_range_returns_all_in_order() -> void:
	for i: int in 5:
		_recorder.record_event(float(i), {"idx": i})
	var events: Array[Dictionary] = _recorder.extract_events(-10.0, 100.0)
	assert_eq(events.size(), 5)
	for i: int in 5:
		assert_eq(events[i].event.idx, i, "event order preserved")


func test_event_buffer_wraps_and_returns_newest() -> void:
	# Overfill the event ring (EVENT_MEMORY_SIZE = 720). Oldest entries get
	# overwritten; extract within a late window still returns the newest.
	var n: int = ReplayRecorder.EVENT_MEMORY_SIZE + 50
	for i: int in n:
		_recorder.record_event(float(i) * 0.01, {"idx": i})
	# Window covering the last ~20 events.
	var events: Array[Dictionary] = _recorder.extract_events(
			float(n - 20) * 0.01, float(n) * 0.01)
	assert_eq(events.size(), 20)
	assert_eq(events[events.size() - 1].event.idx, n - 1)
