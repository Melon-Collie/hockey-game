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
static func find_at(history: Array[PredictedState], target_ts: float) -> PredictedState:
	if history.is_empty():
		return null
	var lo: int = 0
	var hi: int = history.size() - 1
	while lo <= hi:
		var mid: int = (lo + hi) >> 1
		var mid_ts: float = history[mid].host_timestamp
		if absf(mid_ts - target_ts) < 1e-6:
			return history[mid]
		if mid_ts < target_ts:
			lo = mid + 1
		else:
			hi = mid - 1
	return null
