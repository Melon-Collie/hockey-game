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
# True when this entry was RE-RECORDED by a reconcile replay (its values come
# from the replay's manual integration) rather than the live post-move capture.
# Attribution flag for reconcile telemetry: a reconcile whose matched
# prediction was re-recorded fires against the replay's approximations (no
# goalie-body sliding, snapshot-approximated body checks), so a high
# replayed-entry share of reconciles points at replay fidelity, while a high
# live-entry share points at genuine live prediction divergence.
var was_replay_rerecorded: bool = false
# Upper-body twist in radians. Reconcile compares this against server's
# broadcast `upper_body_rotation_y` so a divergence channel (drift between
# host and client's lerped upper-body angle across reconciles) is visible
# to the threshold check instead of silently accumulating.
var upper_body_rotation_y: float


# Binary search for the snapshot at exactly target_ts. Returns null when the
# timestamp is outside the buffered range (cap overflow, cleared after teleport,
# session-boundary effects). The history must be append-ordered (chronological
# by host_timestamp). Mirrors StateBufferManager._find_bracket — same shape,
# applied to a client-side history instead of the host's ring buffer.
#
# Epsilon must exceed the wire round-trip error of host_timestamp.
# last_processed_host_timestamp rides the wire as u32 in 0.1ms units
# (Constants.TIME_WIRE_SCALE), so the worst-case round-trip error against the
# f64 the local history stores is 0.05ms — constant regardless of session
# length, which an f32 encoding would not be (its ULP grows with host uptime).
# 1ms is comfortably
# above that and well below the 8.33ms gap between adjacent 120 Hz-stamped
# inputs, so no risk of off-by-one matches.
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
