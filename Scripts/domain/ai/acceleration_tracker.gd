class_name AIAccelerationTracker
extends RefCounted

# Global per-skater acceleration read for the bot AI. Each skater's
# frame-over-frame velocity delta, low-passed into a smoothed XZ
# acceleration, is a GLOBAL quantity — identical for every bot that
# looks at it — so it is computed ONCE per host physics frame here and
# shared (by reference) through WorldSnapshot.accel_by_peer, rather than
# every bot recomputing the same diff over every skater each tick. See
# CLAUDE.md → hot-path discipline / "memoize at the seam".
#
# Stateful (holds the previous-velocity and smoothed-accel dicts across
# frames), so it is a RefCounted the host owns and ticks — mirrors how
# TeamBrain is host-owned. Constants match the old per-bot cache exactly
# so the shared value is bit-for-bit what the bots used to compute
# themselves (SMOOTH_ALPHA / CLAMP were ACCEL_SMOOTH_ALPHA /
# ACCEL_CLAMP_M_S2 on SkaterAgentStateMachine).

# Low-pass on the raw per-frame velocity diff. The raw diff is noisy at
# 120 Hz (a one-tick velocity blip reads as a huge accel); the lerp
# folds it toward the running estimate.
const SMOOTH_ALPHA: float = 0.2
# Ceiling on the smoothed magnitude so a collision / reconcile snap can't
# register as a multi-hundred-m/s² spike that poisons receiver lead.
const CLAMP_M_S2: float = 14.0

# peer_id -> smoothed accel (XZ; y always 0). Shared by reference onto
# current_snapshot.accel_by_peer each frame — always the live value.
var accel_by_peer: Dictionary[int, Vector3] = {}

var _prev_velocity_by_peer: Dictionary[int, Vector3] = {}
# Reused scratch so the per-frame update allocates nothing: a set of the
# peers seen this frame, and the list of stale peers to prune.
var _seen: Dictionary[int, bool] = {}
var _stale: Array[int] = []


# Advance the estimate one physics frame from the freshest skater states.
# Called once per host frame from GameManager (never per bot). First-sight
# peers seed prev_velocity from the current value and contribute zero accel,
# so a spawn / rejoin doesn't register as a thrust spike.
func update(skater_states: Dictionary, delta: float) -> void:
	if delta <= 0.0:
		return
	var inv_delta: float = 1.0 / delta
	_seen.clear()
	for peer_id: int in skater_states:
		_seen[peer_id] = true
		var s: SkaterNetworkState = skater_states[peer_id]
		var curr_v: Vector3 = s.velocity
		var prev_v: Vector3 = _prev_velocity_by_peer.get(peer_id, curr_v)
		_prev_velocity_by_peer[peer_id] = curr_v
		var raw_a: Vector3 = (curr_v - prev_v) * inv_delta
		raw_a.y = 0.0
		var smoothed: Vector3 = accel_by_peer.get(peer_id, Vector3.ZERO)
		smoothed = smoothed.lerp(raw_a, SMOOTH_ALPHA)
		var mag: float = sqrt(smoothed.x * smoothed.x + smoothed.z * smoothed.z)
		if mag > CLAMP_M_S2:
			var scale: float = CLAMP_M_S2 / mag
			smoothed.x *= scale
			smoothed.z *= scale
		accel_by_peer[peer_id] = smoothed
	# Prune peers that left the snapshot (rare — swap / disconnect) so the
	# dicts don't grow over a long match. Collect into reused scratch first;
	# erasing during dict iteration is unsafe.
	_stale.clear()
	for peer_id: int in _prev_velocity_by_peer:
		if not _seen.has(peer_id):
			_stale.append(peer_id)
	for peer_id: int in _stale:
		_prev_velocity_by_peer.erase(peer_id)
		accel_by_peer.erase(peer_id)
