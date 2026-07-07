extends GutTest

# SnapshotEventLog — the redundant snapshot-piggybacked delivery channel for
# latency-critical carrier events, and the seq watermark that makes its dual
# delivery (unreliable log block + reliable backstop RPC) apply-once and
# regression-safe.

const LOCAL_PEER: int = 42
const OTHER_PEER: int = 77


class Capture:
	var events: Array = []

	func handle(type: int, arg: int) -> void:
		events.append([type, arg])


func _make() -> SnapshotEventLog:
	return SnapshotEventLog.new()


# Simulates the wire: codec payload bytes + appended event block.
func _packet(log: SnapshotEventLog, now: float, payload_size: int = 32) -> PackedByteArray:
	var buf := PackedByteArray()
	buf.resize(payload_size)
	log.append_block(buf, now)
	return buf


# ── Round-trip ───────────────────────────────────────────────────────────────

func test_events_round_trip_in_order() -> void:
	var log := _make()
	log.record(SnapshotEventLog.EventType.CARRIER_CHANGED, SnapshotEventLog.TARGET_ALL, LOCAL_PEER, 10.0)
	log.record(SnapshotEventLog.EventType.CARRIER_CHANGED, SnapshotEventLog.TARGET_ALL, -1, 10.1)
	var cap := Capture.new()
	_make().apply_block(_packet(log, 10.2), LOCAL_PEER, cap.handle)
	assert_eq(cap.events.size(), 2)
	assert_eq(cap.events[0], [SnapshotEventLog.EventType.CARRIER_CHANGED, LOCAL_PEER])
	assert_eq(cap.events[1], [SnapshotEventLog.EventType.CARRIER_CHANGED, -1])


func test_negative_arg_round_trips() -> void:
	var log := _make()
	log.record(SnapshotEventLog.EventType.CARRIER_CHANGED, SnapshotEventLog.TARGET_ALL, -1, 0.0)
	var cap := Capture.new()
	_make().apply_block(_packet(log, 0.0), LOCAL_PEER, cap.handle)
	assert_eq(cap.events[0][1], -1)


func test_empty_block_is_one_byte_and_dispatches_nothing() -> void:
	var log := _make()
	var buf := _packet(log, 0.0, 32)
	assert_eq(buf.size(), 33)
	var cap := Capture.new()
	_make().apply_block(buf, LOCAL_PEER, cap.handle)
	assert_eq(cap.events.size(), 0)


# ── Target filtering ─────────────────────────────────────────────────────────

func test_targeted_event_reaches_only_its_peer() -> void:
	var log := _make()
	log.record(SnapshotEventLog.EventType.STOLEN, OTHER_PEER, 1, 0.0)
	var pkt := _packet(log, 0.0)
	var mine := Capture.new()
	_make().apply_block(pkt, LOCAL_PEER, mine.handle)
	assert_eq(mine.events.size(), 0, "event for OTHER_PEER must be filtered")
	var theirs := Capture.new()
	_make().apply_block(pkt, OTHER_PEER, theirs.handle)
	assert_eq(theirs.events, [[SnapshotEventLog.EventType.STOLEN, 1]])


func test_filtered_event_still_advances_watermark() -> void:
	var log := _make()
	var seq: int = log.record(SnapshotEventLog.EventType.PICKED_UP, OTHER_PEER, 0, 0.0)
	var client := _make()
	client.apply_block(_packet(log, 0.0), LOCAL_PEER, Capture.new().handle)
	assert_false(client.try_apply_reliable(seq),
			"a seq seen via the log (even not-for-me) must reject the reliable copy")


# ── Apply-once / dedupe ──────────────────────────────────────────────────────

func test_reapplying_same_block_dispatches_nothing() -> void:
	var log := _make()
	log.record(SnapshotEventLog.EventType.CARRIER_CHANGED, SnapshotEventLog.TARGET_ALL, LOCAL_PEER, 0.0)
	var pkt := _packet(log, 0.0)
	var client := _make()
	var cap := Capture.new()
	client.apply_block(pkt, LOCAL_PEER, cap.handle)
	client.apply_block(pkt, LOCAL_PEER, cap.handle)
	assert_eq(cap.events.size(), 1)


func test_reliable_applies_exactly_once() -> void:
	var client := _make()
	assert_true(client.try_apply_reliable(1))
	assert_false(client.try_apply_reliable(1))


func test_log_then_reliable_deduped() -> void:
	var log := _make()
	var seq: int = log.record(SnapshotEventLog.EventType.CARRIER_CHANGED, SnapshotEventLog.TARGET_ALL, LOCAL_PEER, 0.0)
	var client := _make()
	client.apply_block(_packet(log, 0.0), LOCAL_PEER, Capture.new().handle)
	assert_false(client.try_apply_reliable(seq))


func test_reliable_then_log_deduped() -> void:
	var log := _make()
	var seq: int = log.record(SnapshotEventLog.EventType.CARRIER_CHANGED, SnapshotEventLog.TARGET_ALL, LOCAL_PEER, 0.0)
	var client := _make()
	assert_true(client.try_apply_reliable(seq))
	var cap := Capture.new()
	client.apply_block(_packet(log, 0.0), LOCAL_PEER, cap.handle)
	assert_eq(cap.events.size(), 0)


# ── Anti-regression ordering ─────────────────────────────────────────────────

func test_stale_reliable_cannot_regress_newer_log_event() -> void:
	# Host: carrier=X (seq 1) then carrier cleared (seq 2), with seq 1 aged out
	# of the log and its reliable copy stuck in retransmit. The client first
	# learns of seq 2 from the log; the late reliable seq 1 must then be
	# rejected, or the client would re-install carrier=X after the host
	# cleared it.
	var log := _make()
	var seq1: int = log.record(SnapshotEventLog.EventType.CARRIER_CHANGED, SnapshotEventLog.TARGET_ALL, LOCAL_PEER, 0.0)
	var seq2: int = log.record(SnapshotEventLog.EventType.CARRIER_CHANGED, SnapshotEventLog.TARGET_ALL, -1, SnapshotEventLog.RETENTION_S + 0.05)
	assert_true(seq2 > seq1)
	var client := _make()
	var cap := Capture.new()
	client.apply_block(_packet(log, SnapshotEventLog.RETENTION_S + 0.06), LOCAL_PEER, cap.handle)
	assert_eq(cap.events.size(), 1, "seq 1 aged out — only seq 2 arrives via the log")
	assert_eq(cap.events[0][1], -1)
	assert_false(client.try_apply_reliable(seq1), "stale reliable must not regress")


func test_missed_snapshots_recovered_from_later_block() -> void:
	# Every event stays in the block for RETENTION_S, so a client that lost
	# the packets carrying seq 1 still gets it (in order) from a later packet.
	var log := _make()
	log.record(SnapshotEventLog.EventType.CARRIER_CHANGED, SnapshotEventLog.TARGET_ALL, LOCAL_PEER, 0.0)
	_packet(log, 0.0)  # this packet is "lost" — client never applies it
	log.record(SnapshotEventLog.EventType.CARRIER_CHANGED, SnapshotEventLog.TARGET_ALL, -1, 0.1)
	var cap := Capture.new()
	_make().apply_block(_packet(log, 0.1), LOCAL_PEER, cap.handle)
	assert_eq(cap.events.size(), 2)
	assert_eq(cap.events[0][1], LOCAL_PEER)
	assert_eq(cap.events[1][1], -1)


# ── Retention / caps ─────────────────────────────────────────────────────────

func test_events_expire_after_retention() -> void:
	var log := _make()
	log.record(SnapshotEventLog.EventType.CARRIER_CHANGED, SnapshotEventLog.TARGET_ALL, LOCAL_PEER, 0.0)
	var cap := Capture.new()
	_make().apply_block(_packet(log, SnapshotEventLog.RETENTION_S + 0.01), LOCAL_PEER, cap.handle)
	assert_eq(cap.events.size(), 0)


func test_log_capped_at_max_events_dropping_oldest() -> void:
	var log := _make()
	for i: int in SnapshotEventLog.MAX_EVENTS + 4:
		log.record(SnapshotEventLog.EventType.CARRIER_CHANGED, SnapshotEventLog.TARGET_ALL, i, 0.0)
	var cap := Capture.new()
	_make().apply_block(_packet(log, 0.0), LOCAL_PEER, cap.handle)
	assert_eq(cap.events.size(), SnapshotEventLog.MAX_EVENTS)
	assert_eq(cap.events[0][1], 4, "oldest events beyond the cap are dropped")


func test_malformed_count_byte_applies_nothing() -> void:
	# A garbage count that would read past the buffer start must bail cleanly.
	var buf := PackedByteArray()
	buf.resize(8)
	buf.encode_u8(7, 5)  # claims 5 records (65 B) in a 7-byte prefix
	var cap := Capture.new()
	_make().apply_block(buf, LOCAL_PEER, cap.handle)
	assert_eq(cap.events.size(), 0)
