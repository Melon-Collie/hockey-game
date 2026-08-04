extends GutTest

# RemoteController.receive_input_batch — the host's per-client input queue.
#
# Clients ship a redundant trailing window every batch, so ~119 of every 120
# records arriving here are duplicates. The decode side now skips records at or
# below the watermark this function reports, and the dedupe here builds its stamp
# set lazily and sorts only when a gap fill actually breaks the order. All three
# are optimizations of a dedupe whose OUTPUT must not change, so these tests pin
# the queue against a straight transcription of the original
# decode-everything / dedupe / sort-every-batch algorithm.

const _FUTURE_SLACK_S: float = 0.1
const _PAST_SLACK_S: float = 2.0


func _controller() -> RemoteController:
	var rc := RemoteController.new()
	autofree(rc)
	return rc


func _stamped(ts: float) -> InputState:
	var s := InputState.new()
	s.host_timestamp = ts
	return s


func _stamps(queue: Array) -> Array:
	var out: Array = []
	for s: InputState in queue:
		out.append(s.host_timestamp)
	return out


# The pre-optimization algorithm, verbatim: rebuild the stamp set from the whole
# queue every batch, append anything new, sort unconditionally, then cap. Nothing
# in these tests consumes an input, so last_processed stays at its initial 0.0.
func _reference_queue(batches: Array, now: float) -> Array:
	var queue: Array = []
	var last_processed: float = 0.0
	var max_depth: int = Constants.PHYSICS_TICK / 2
	for batch: Array in batches:
		var seen: Dictionary = {}
		for ts: float in queue:
			seen[ts] = true
		for ts: float in batch:
			if ts <= last_processed:
				continue
			if seen.has(ts):
				continue
			if ts < now - _PAST_SLACK_S or ts > now + _FUTURE_SLACK_S:
				continue
			queue.append(ts)
			seen[ts] = true
		queue.sort()
		while queue.size() > max_depth:
			queue.pop_front()
	return queue


# Drives the real path the way the host does: the decoder drops every record at
# or below the reported watermark before the controller ever sees it, so the
# skip is exercised rather than bypassed.
func _feed(rc: RemoteController, batches: Array) -> void:
	var watermark: float = -INF
	for batch: Array in batches:
		var decoded: Array[InputState] = []
		for ts: float in batch:
			if ts <= watermark:
				continue
			decoded.append(_stamped(ts))
		watermark = rc.receive_input_batch(decoded)


func _assert_matches_reference(batches: Array, now: float, msg: String) -> void:
	var rc: RemoteController = _controller()
	_feed(rc, batches)
	assert_eq(_stamps(rc._input_queue), _reference_queue(batches, now), msg)


func test_overlapping_batches_dedupe_to_the_same_queue() -> void:
	# The steady state: each batch re-sends the previous window plus one frame.
	var now: float = NetworkManager.estimated_host_time()
	var batches: Array = []
	for b: int in 6:
		var batch: Array = []
		for i: int in 12:
			batch.append(now + 0.001 * float(b + i))
		batches.append(batch)
	_assert_matches_reference(batches, now, "overlapping windows dedupe identically")


func test_duplicate_stamps_within_one_batch_are_dropped() -> void:
	var now: float = NetworkManager.estimated_host_time()
	var batches: Array = [[now + 0.001, now + 0.001, now + 0.002, now + 0.002]]
	_assert_matches_reference(batches, now, "a repeated stamp is queued once")


func test_out_of_order_batch_is_reordered() -> void:
	# The sort is now conditional, so a descending batch is the case that proves
	# the condition fires.
	var now: float = NetworkManager.estimated_host_time()
	var batches: Array = [[now + 0.004, now + 0.001, now + 0.003, now + 0.002]]
	_assert_matches_reference(batches, now, "a descending batch still sorts ascending")


func test_gap_fill_after_loss_lands_in_order() -> void:
	# Batch 2 delivers a frame that falls INSIDE the queue's existing range — the
	# one case that breaks the append-stays-sorted invariant and must trigger the
	# sort. Reached by handing the controller an interior stamp directly, since
	# the watermark skip is what normally makes this unreachable.
	var now: float = NetworkManager.estimated_host_time()
	var rc: RemoteController = _controller()
	var first: Array[InputState] = [_stamped(now + 0.001), _stamped(now + 0.004)]
	rc.receive_input_batch(first)
	var second: Array[InputState] = [_stamped(now + 0.002)]
	rc.receive_input_batch(second)
	assert_eq(_stamps(rc._input_queue),
			[now + 0.001, now + 0.002, now + 0.004],
			"the gap fill sorts back into place rather than sitting at the tail")


func test_stamps_outside_the_plausible_window_are_rejected() -> void:
	var now: float = NetworkManager.estimated_host_time()
	var batches: Array = [[
		now - _PAST_SLACK_S - 1.0,     # far past
		now + _FUTURE_SLACK_S + 1.0,   # far future
		now + 0.01,                    # legitimate
	]]
	var rc: RemoteController = _controller()
	_feed(rc, batches)
	assert_eq(_stamps(rc._input_queue), [now + 0.01],
			"only the plausible stamp survives")


func test_queue_is_capped_at_half_a_second() -> void:
	var now: float = NetworkManager.estimated_host_time()
	var max_depth: int = Constants.PHYSICS_TICK / 2
	var batch: Array = []
	for i: int in max_depth + 20:
		batch.append(now + 0.0005 * float(i))
	var rc: RemoteController = _controller()
	_feed(rc, [batch])
	assert_eq(rc._input_queue.size(), max_depth, "capped at the queue depth")
	assert_eq(rc._input_queue.back().host_timestamp,
			now + 0.0005 * float(max_depth + 19),
			"the cap drops the OLDEST, keeping the newest frame")


# ── The reported watermark ───────────────────────────────────────────────────

func test_watermark_reports_the_newest_queued_stamp() -> void:
	var now: float = NetworkManager.estimated_host_time()
	var rc: RemoteController = _controller()
	var wm: float = rc.receive_input_batch([_stamped(now + 0.001), _stamped(now + 0.003)])
	assert_almost_eq(wm, now + 0.003, 0.000001,
			"the watermark covers everything queued")


func test_watermark_falls_back_to_last_processed_on_an_empty_queue() -> void:
	var rc: RemoteController = _controller()
	rc.last_processed_host_timestamp = 5.0
	# Every stamp here is already processed, so nothing queues.
	var wm: float = rc.receive_input_batch([_stamped(1.0), _stamped(2.0)])
	assert_eq(wm, 5.0, "an empty queue still reports what was already consumed")


func test_watermark_skip_does_not_drop_a_frame_the_queue_never_saw() -> void:
	# The load-bearing property: the decoder skips only what the consumer already
	# holds. A frame rejected downstream (here, by the future-slack window) must
	# NOT be skipped when a later batch redelivers it — hence the watermark being
	# reported by the consumer rather than tracked at the decoder.
	var rc: RemoteController = _controller()
	var now: float = NetworkManager.estimated_host_time()
	var too_far_ahead: float = now + _FUTURE_SLACK_S + 0.5
	var wm: float = rc.receive_input_batch([_stamped(too_far_ahead)])
	assert_eq(rc._input_queue.size(), 0, "the future stamp was rejected")
	assert_lt(wm, too_far_ahead,
			"and the watermark did not advance past it, so a redelivery still decodes")
