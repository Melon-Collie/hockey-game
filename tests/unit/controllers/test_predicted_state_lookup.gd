extends GutTest

# PredictedState.find_at is the binary-search helper used by LocalController's
# trajectory-based reconcile. It looks up the client's predicted snapshot at a
# server-confirmed host_timestamp so the threshold check can compare
# predicted-vs-server at the same instant instead of current-vs-server.


func _snap(ts: float, x: float = 0.0) -> PredictedState:
	var s := PredictedState.new()
	s.host_timestamp = ts
	s.position = Vector3(x, 0.0, 0.0)
	s.velocity = Vector3.ZERO
	s.facing = Vector2(0.0, 1.0)
	s.shot_state = 0
	return s


func test_empty_history_returns_null() -> void:
	var history: Array[PredictedState] = []
	assert_null(PredictedState.find_at(history, 1.0))


func test_single_entry_exact_match() -> void:
	var history: Array[PredictedState] = [_snap(1.0, 42.0)]
	var hit: PredictedState = PredictedState.find_at(history, 1.0)
	assert_not_null(hit)
	assert_eq(hit.position.x, 42.0)


func test_single_entry_no_match() -> void:
	var history: Array[PredictedState] = [_snap(1.0)]
	assert_null(PredictedState.find_at(history, 2.0))
	assert_null(PredictedState.find_at(history, 0.5))


func test_exact_match_middle() -> void:
	var history: Array[PredictedState] = [
		_snap(1.0, 1.0), _snap(2.0, 2.0), _snap(3.0, 3.0),
		_snap(4.0, 4.0), _snap(5.0, 5.0)
	]
	var hit: PredictedState = PredictedState.find_at(history, 3.0)
	assert_not_null(hit)
	assert_eq(hit.position.x, 3.0)


func test_exact_match_first() -> void:
	var history: Array[PredictedState] = [
		_snap(1.0, 1.0), _snap(2.0, 2.0), _snap(3.0, 3.0)
	]
	var hit: PredictedState = PredictedState.find_at(history, 1.0)
	assert_not_null(hit)
	assert_eq(hit.position.x, 1.0)


func test_exact_match_last() -> void:
	var history: Array[PredictedState] = [
		_snap(1.0, 1.0), _snap(2.0, 2.0), _snap(3.0, 3.0)
	]
	var hit: PredictedState = PredictedState.find_at(history, 3.0)
	assert_not_null(hit)
	assert_eq(hit.position.x, 3.0)


func test_no_match_between_entries() -> void:
	# Server-confirmed timestamps land exactly on client-stamped inputs in
	# practice. But if a gap exists (history was trimmed, packets reordered)
	# the lookup must return null — never silently snap to a nearby entry.
	var history: Array[PredictedState] = [
		_snap(1.0), _snap(2.0), _snap(3.0)
	]
	assert_null(PredictedState.find_at(history, 1.5))
	assert_null(PredictedState.find_at(history, 2.5))


func test_no_match_before_oldest() -> void:
	var history: Array[PredictedState] = [_snap(5.0), _snap(6.0), _snap(7.0)]
	assert_null(PredictedState.find_at(history, 1.0))


func test_no_match_after_newest() -> void:
	var history: Array[PredictedState] = [_snap(5.0), _snap(6.0), _snap(7.0)]
	assert_null(PredictedState.find_at(history, 100.0))


func test_float_tolerance_within_epsilon() -> void:
	# host_timestamp is a float; the server echoes the client's exact value back
	# in last_processed_host_timestamp. The TS_MATCH_EPSILON (1ms) catches
	# round-trips that drift up to ~430µs at 1h session time through f32 wire
	# serialization while staying well below the 4.17ms gap between adjacent
	# 240Hz-stamped inputs (no off-by-one matches).
	var history: Array[PredictedState] = [_snap(1.234567)]
	var hit: PredictedState = PredictedState.find_at(history, 1.2345672)
	assert_not_null(hit)


func test_float_tolerance_outside_epsilon() -> void:
	# 1e-2 (10ms) is well past the 1ms TS_MATCH_EPSILON and outside any
	# realistic f32 round-trip precision loss, so the lookup must return null.
	var history: Array[PredictedState] = [_snap(1.0)]
	assert_null(PredictedState.find_at(history, 1.01))


func test_large_history_binary_search() -> void:
	# Cap is 480 entries (~2s at 240Hz). Verify O(log n) lookup hits any entry.
	var history: Array[PredictedState] = []
	for i in range(480):
		history.append(_snap(float(i) * 0.00417, float(i)))
	var hit_first: PredictedState = PredictedState.find_at(history, 0.0)
	assert_not_null(hit_first)
	assert_eq(hit_first.position.x, 0.0)
	var hit_mid: PredictedState = PredictedState.find_at(history, 239.0 * 0.00417)
	assert_not_null(hit_mid)
	assert_eq(hit_mid.position.x, 239.0)
	var hit_last: PredictedState = PredictedState.find_at(history, 479.0 * 0.00417)
	assert_not_null(hit_last)
	assert_eq(hit_last.position.x, 479.0)
