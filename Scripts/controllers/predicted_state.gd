class_name PredictedState
extends RefCounted

# Per-input snapshot of what the client predicted for the moment immediately
# after applying an input. Keyed by the input's host_timestamp, so when the
# server confirms `last_processed_host_timestamp = T` the client can look up
# its own prediction at T and compare position/velocity directly — true
# divergence, with prediction lead subtracted out.
#
# Mirrors the subset of SkaterNetworkState that the server broadcasts and that
# the client can validate against. Stored in a ring buffer on LocalController.

var host_timestamp: float
var position: Vector3
var velocity: Vector3
var facing: Vector2
var shot_state: int


# Binary search for the snapshot at exactly target_ts. Returns null when the
# timestamp is outside the buffered range (cap overflow, cleared after teleport,
# session-boundary effects). The history must be append-ordered (chronological
# by host_timestamp). Mirrors StateBufferManager._find_bracket — same shape,
# applied to a client-side history instead of the host's ring buffer.
#
# Epsilon must exceed the float32 round-trip precision of host_timestamp.
# last_processed_host_timestamp is serialized as f32 on the wire (world state
# codec, 4B), so its precision is T × 2^-23 — ~430µs at 1h session time.
# Local history stores the original f64. 1ms is comfortably above f32 precision
# for multi-hour sessions and well below the 4.17ms gap between adjacent
# 240Hz-stamped inputs, so no risk of off-by-one matches.
const TS_MATCH_EPSILON: float = 1e-3

static func find_at(history: Array[PredictedState], target_ts: float) -> PredictedState:
	if history.is_empty():
		return null
	var lo: int = 0
	var hi: int = history.size() - 1
	while lo <= hi:
		var mid: int = (lo + hi) >> 1
		var mid_ts: float = history[mid].host_timestamp
		if absf(mid_ts - target_ts) < TS_MATCH_EPSILON:
			return history[mid]
		if mid_ts < target_ts:
			lo = mid + 1
		else:
			hi = mid - 1
	return null
