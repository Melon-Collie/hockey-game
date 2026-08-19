class_name SnapshotEventLog
extends RefCounted

# Redundant delivery channel for latency-critical carrier events (pickup grant,
# carrier change, steal, drop): the host appends its recent events as a trailing
# block on every unreliable world-state packet, so an event survives any single
# packet loss with zero added latency instead of costing a reliable-retransmit
# round-trip. Both channels carry the same monotonic `event_seq`; the client
# applies each event at most once via the `_last_applied_seq` watermark. Why the
# dual channel is safe, and why the log is CONNECTION-scoped rather than
# match-scoped, are in Scripts/networking/CLAUDE.md.
#
# `apply_block` advances the watermark over EVERY record, including ones
# targeted at other peers — the seq space is global, so skipping a not-for-me
# seq is correct, not a gap.
#
# Hot-path notes: `record` runs per event (rare, event-driven — a Dictionary
# alloc is fine); `append_block` fills the caller's existing buffer in place;
# `apply_block` allocates nothing and early-outs on the 1-byte empty block that
# rides the common no-recent-events packet.

enum EventType {
	CARRIER_CHANGED = 0,  # arg = new carrier peer_id (-1 = none), broadcast
	PICKED_UP = 1,        # targeted at the granted carrier, no arg
	STOLEN = 2,           # targeted at the victim, arg = was_stick_lift (0/1)
	DROPPED = 3,          # targeted at the ex-carrier (goal reset), no arg
}

# Godot peer ids are positive 31-bit ints, so 0 is a safe broadcast sentinel.
const TARGET_ALL: int = 0
# u32 seq + u8 type + s32 target_peer + s32 arg. target/arg are s32 because
# carrier_changed carries -1 for "no carrier".
const RECORD_SIZE: int = 13
# Worst-case block: 16 × 13 + 1 count byte = 209 B, and only during a scramble
# that produced 16 events inside RETENTION_S. Typical packets carry 1 byte.
const MAX_EVENTS: int = 16
# Re-broadcast window. Must comfortably exceed the reliable-retransmit time so
# a client that missed every snapshot copy of an event still can't see a NEWER
# event via the log before the older reliable copy arrives — 1 s of total
# snapshot loss means ~120 consecutive drops, at which point the session is
# already in extrapolation freeze and event ordering is the least of it.
const RETENTION_S: float = 1.0

# Host side.
var _next_seq: int = 1
var _events: Array[Dictionary] = []
# Client side.
var _last_applied_seq: int = 0


# Host: register an event for redundant broadcast. Returns the seq the caller
# must attach to the reliable backstop RPC for the same event.
func record(type: int, target_peer: int, arg: int, now: float) -> int:
	var seq: int = _next_seq
	_next_seq += 1
	_events.append({seq = seq, type = type, target = target_peer, arg = arg, time = now})
	# Cap so offline / free-play sessions (which record but never encode, and
	# therefore never age-prune) can't grow the log unboundedly.
	while _events.size() > MAX_EVENTS:
		_events.pop_front()
	return seq


# Host: append the still-fresh events plus a trailing count byte to a
# world-state packet. The count sits LAST so the client can find the block
# without knowing the codec payload's length.
func append_block(buf: PackedByteArray, now: float) -> void:
	while not _events.is_empty() and now - (_events[0].time as float) > RETENTION_S:
		_events.pop_front()
	var base: int = buf.size()
	buf.resize(base + _events.size() * RECORD_SIZE + 1)
	var o: int = base
	for ev: Dictionary in _events:
		buf.encode_u32(o, ev.seq)
		buf.encode_u8(o + 4, ev.type)
		buf.encode_s32(o + 5, ev.target)
		buf.encode_s32(o + 9, ev.arg)
		o += RECORD_SIZE
	buf.encode_u8(o, _events.size())


# Client: parse the trailing block, advance the watermark, and dispatch fresh
# events addressed to this peer (or to all) via handler.call(type, arg).
# Records are stored oldest-first, so dispatch order matches host emit order.
func apply_block(data: PackedByteArray, local_peer_id: int, handler: Callable) -> void:
	if data.size() < 1:
		return
	var count: int = data.decode_u8(data.size() - 1)
	if count == 0:
		return
	var start: int = data.size() - 1 - count * RECORD_SIZE
	if count > MAX_EVENTS or start < 0:
		return  # malformed / truncated — protocol handshake makes this corruption, not skew
	var o: int = start
	for _i: int in count:
		var seq: int = data.decode_u32(o)
		var type: int = data.decode_u8(o + 4)
		var target: int = data.decode_s32(o + 5)
		var arg: int = data.decode_s32(o + 9)
		o += RECORD_SIZE
		if seq <= _last_applied_seq:
			continue
		_last_applied_seq = seq
		if target == TARGET_ALL or target == local_peer_id:
			handler.call(type, arg)


# Client: gate for the reliable backstop RPCs. True exactly once per seq, and
# never after a newer seq has been applied (the anti-regression guard).
func try_apply_reliable(seq: int) -> bool:
	if seq <= _last_applied_seq:
		return false
	_last_applied_seq = seq
	return true
