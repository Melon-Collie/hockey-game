class_name AIAccelerationTracker
extends RefCounted

# Global per-skater acceleration read for the bot AI. Each skater's
# frame-over-frame velocity delta, low-passed into a smoothed XZ acceleration,
# is a GLOBAL quantity — identical for every bot that looks at it — so it is
# computed ONCE per host physics frame here and shared by reference through
# WorldSnapshot.accel_by_peer, rather than every bot recomputing the same diff
# over every skater each tick. See CLAUDE.md -> hot-path discipline,
# "memoize at the seam".
#
# Stateful (holds the previous-velocity and smoothed-accel dicts across frames),
# so it is a RefCounted the host owns and ticks — mirroring TeamBrain.

# Low-pass on the raw per-frame velocity diff. The raw diff is noisy at
# 120 Hz (a one-tick velocity blip reads as a huge accel); the lerp
# folds it toward the running estimate.
const SMOOTH_ALPHA: float = 0.2
# Ceiling on the smoothed magnitude so a collision / reconcile snap can't
# register as a multi-hundred-m/s² spike that poisons receiver lead.
const CLAMP_M_S2: float = 14.0

# ── Heading turn rate (receiver-commitment perception) ────────────────────────
# Alongside the linear accel, low-pass the per-skater HEADING angular velocity
# (rad/s — how fast the travel direction is rotating). This is the passer's
# "how committed is this receiver to a direction" read: a skater mid-cut spins
# its heading fast (low confidence — hard to lead), one holding a line settles
# toward zero (high confidence — lead it freely). It is a running estimate, so
# it GAINS confidence over time — a receiver coming out of a turn reads
# uncertain for a beat, then settles as the filter decays. Consumed by the pass
# EV (AIActionScoring.receiver_heading_uncertainty_m) to stop bots chucking
# feeds at turning players; a settled receiver is penalised ~0, so a clean quick
# feed is unaffected.
#
# Low-pass is slightly slower than the linear accel (a heading estimate should
# build/decay over a beat, not snap tick-to-tick). Below OMEGA_MIN_SPEED there's
# no reliable heading to differentiate (velocity direction is noise near rest),
# so the raw rate is treated as zero — a near-stationary receiver is EASY to
# feed (no lead), which is exactly "settled / confident". The clamp caps a
# one-frame velocity flip (collision / reconcile snap) from reading as an
# impossible spin.
const OMEGA_SMOOTH_ALPHA: float = 0.15
const OMEGA_CLAMP_RAD_S: float = 8.0
const OMEGA_MIN_SPEED_M_S: float = 1.0

# peer_id -> smoothed accel (XZ; y always 0). Shared by reference onto
# current_snapshot.accel_by_peer each frame — always the live value.
var accel_by_peer: Dictionary[int, Vector3] = {}

# peer_id -> smoothed heading turn rate (rad/s, signed; magnitude is what the
# pass EV reads). Shared by reference onto current_snapshot.heading_omega_by_peer
# each frame. Smoothing SIGNED (not magnitude) so straight-line direction noise
# cancels around zero while a sustained turn's consistent sign accumulates.
var heading_omega_by_peer: Dictionary[int, float] = {}

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
		# Heading turn rate: the signed XZ angle swept from prev→curr velocity
		# per second. atan2(cross, dot) handles the full range and sign; both
		# ends need real travel speed or the direction is noise (→ raw 0).
		var raw_omega: float = 0.0
		var prev_speed: float = sqrt(prev_v.x * prev_v.x + prev_v.z * prev_v.z)
		var curr_speed: float = sqrt(curr_v.x * curr_v.x + curr_v.z * curr_v.z)
		if prev_speed > OMEGA_MIN_SPEED_M_S and curr_speed > OMEGA_MIN_SPEED_M_S:
			var dot: float = prev_v.x * curr_v.x + prev_v.z * curr_v.z
			var cross: float = prev_v.x * curr_v.z - prev_v.z * curr_v.x
			raw_omega = atan2(cross, dot) * inv_delta
		var omega: float = lerpf(heading_omega_by_peer.get(peer_id, 0.0),
				raw_omega, OMEGA_SMOOTH_ALPHA)
		omega = clampf(omega, -OMEGA_CLAMP_RAD_S, OMEGA_CLAMP_RAD_S)
		heading_omega_by_peer[peer_id] = omega
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
		heading_omega_by_peer.erase(peer_id)
