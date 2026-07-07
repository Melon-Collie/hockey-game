extends GutTest

# GoalReplayStore — persistent per-match list of goal clips fed by the live
# GoalReplayDriver, consumed by PostGameReplayDriver behind the final screen.

var _store: GoalReplayStore = null


func before_each() -> void:
	_store = GoalReplayStore.new()


func _clip(frame_count: int, start_ts: float = 0.0, end_ts: float = 1.0) -> Dictionary:
	var frames: Array[PackedByteArray] = []
	var timestamps: Array[float] = []
	for i: int in frame_count:
		var data := PackedByteArray()
		data.resize(4)
		data.encode_u32(0, i)
		frames.append(data)
		timestamps.append(float(i) * 0.01)
	return {
		"frames": frames,
		"timestamps": timestamps,
		"start_ts": start_ts,
		"end_ts": end_ts,
	}


func test_new_store_is_empty() -> void:
	assert_true(_store.is_empty())
	assert_eq(_store.size(), 0)


func test_add_appends_clip() -> void:
	_store.add(_clip(4))
	assert_false(_store.is_empty())
	assert_eq(_store.size(), 1)


func test_add_preserves_order() -> void:
	_store.add(_clip(2, 1.0, 2.0))
	_store.add(_clip(2, 3.0, 4.0))
	var clips: Array[Dictionary] = _store.clips()
	assert_eq(clips.size(), 2)
	assert_eq(float(clips[0].start_ts), 1.0)
	assert_eq(float(clips[1].start_ts), 3.0)


func test_rejects_clip_with_too_few_frames() -> void:
	_store.add(_clip(1))
	_store.add(_clip(0))
	assert_eq(_store.size(), 0)


func test_clear_empties_store() -> void:
	_store.add(_clip(3))
	_store.add(_clip(3))
	_store.clear()
	assert_true(_store.is_empty())


func test_caps_at_max_clips() -> void:
	for i: int in GoalReplayStore.MAX_CLIPS + 5:
		_store.add(_clip(2, float(i), float(i) + 1.0))
	assert_eq(_store.size(), GoalReplayStore.MAX_CLIPS)
	# Oldest dropped first — the surviving head should be clip index 5.
	assert_eq(float(_store.clips()[0].start_ts), 5.0)


func test_stored_frames_survive_source_mutation() -> void:
	var clip: Dictionary = _clip(3)
	_store.add(clip)
	# Mutating the source arrays after add() must not affect the stored copy.
	(clip.frames as Array).clear()
	(clip.timestamps as Array).clear()
	assert_eq((_store.clips()[0].frames as Array).size(), 3)
