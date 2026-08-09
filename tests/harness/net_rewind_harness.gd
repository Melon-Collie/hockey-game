class_name NetRewindHarness
extends RefCounted

# Deterministic simulation of the CLAIM REWIND seam: does every lookup a claim
# resolver makes actually land inside the host's state buffer, and do the client
# and host agree on the depth they reconstruct a remote body at?
#
# Companion to NetTimingHarness, which covers the input pipeline. This one covers
# the other half of the plumbing — the buffer and the view-time formulas. Between
# them they cover the seam every netcode defect found so far has lived in.
#
# The bug that motivated it: LagCompRewind.self_view_time returns host_ts + lead,
# but the host holds a client's input until its stamp comes due, so at claim
# ARRIVAL the newest capture sits at host_ts + one_way. Whenever the lead exceeds
# the one-way trip — most links, and the CLEANER the link the worse it is —
# get_state_at is handed an instant the host has not simulated, and
# _find_bracket answers a future query with its newest sample and no signal at
# all. The claimant's own body is then rewound short, and the reach/continuity
# clamps fence an honest full-extension claim against a stale body.
#
# THE CRITICAL PROPERTY, same as the timing harness: this can reproduce that bug
# on demand. `ResolveMode` switches between resolving on arrival (legacy) and
# holding until the buffer covers the instant (DeferredClaimQueue, shipping), and
# the suite asserts the legacy mode still overruns the buffer. A harness that
# only ever passes proves nothing about the next defect.
#
# Real code under test, not reimplementations:
#   - StateBufferManager.get_state_at / _find_bracket / newest_host_timestamp
#   - LagCompRewind.self_view_time / remote_view_time / puck_view_time
#   - LagCompRewind.forward_predict_ticks (the shared render == rewind depth)
# Only the RING WRITE is mirrored: capture() needs live controllers to pull state
# from, which cannot be stood up headless. The write is mechanical and touches
# the same fields, so the thing that actually decides these tests — the lookup —
# is entirely the shipping implementation.

const _PEER: int = 7


enum ResolveMode {
	ON_ARRIVAL,       # legacy: resolve the moment the RPC lands
	DEFER_TO_INSTANT, # shipping: hold until the buffer covers the self-view instant
}


class Config:
	var rtt_ms: float = 30.0
	var interp_delay_ms: float = 45.0
	var input_lead_ms: float = 25.0
	var duration_s: float = 3.0
	var claim_every_ticks: int = 7
	var resolve_mode: ResolveMode = ResolveMode.DEFER_TO_INSTANT
	# Straight-line speed of the modelled body, m/s. Only used to give the buffer
	# something with a known answer so an interpolation error is detectable.
	var speed: float = 9.0


class Result:
	var claims: int = 0
	var resolved: int = 0
	var self_view_past_newest: int = 0    # THE bug: asked for an unsimulated instant
	var remote_view_past_newest: int = 0
	var puck_view_past_newest: int = 0
	var view_before_oldest: int = 0       # asked for something the ring has evicted
	var max_lookup_overrun_ms: float = 0.0
	var max_interp_error_m: float = 0.0   # buffer's answer vs the known trajectory
	var depth_mismatches: int = 0         # client vs host forward-predict depth
	var warmup_skipped: int = 0           # claims excluded because the ring is not deep yet

	func summary() -> String:
		return ("claims=%d resolved=%d warmup_skipped=%d self_past=%d remote_past=%d "
				+ "puck_past=%d before_oldest=%d overrun_max=%.1fms interp_err_max=%.3fm "
				+ "depth_mismatch=%d") % [
				claims, resolved, warmup_skipped, self_view_past_newest,
				remote_view_past_newest, puck_view_past_newest, view_before_oldest,
				max_lookup_overrun_ms, max_interp_error_m, depth_mismatches]


class _Claim:
	var stamp: float = 0.0        # the client's estimated_host_time() at send
	var arrive: float = 0.0       # host time the RPC lands
	var interp_delay_ms: float = 0.0
	var input_lead_ms: float = 0.0
	var resolved: bool = false


# Mirror of StateBufferManager.capture()'s ring write for one skater. Everything
# the tests actually exercise — bracket search, interpolation, the future-query
# branch — is the real implementation reading what this wrote.
static func _push_skater(buf: StateBufferManager, peer_id: int,
		pos: Vector3, ts: float) -> void:
	if not buf._skater_buffers.has(peer_id):
		buf._alloc_skater(peer_id)
	var ptr: int = buf._skater_ptrs[peer_id]
	var slot: SkaterNetworkState = buf._skater_buffers[peer_id][ptr]
	slot.position = pos
	slot.velocity = Vector3.ZERO
	slot.facing = Vector2(0.0, 1.0)
	slot.host_timestamp = ts
	buf._skater_ptrs[peer_id] = (ptr + 1) % StateBufferManager.BUFFER_SIZE
	buf._skater_counts[peer_id] = mini(
			buf._skater_counts.get(peer_id, 0) + 1, StateBufferManager.BUFFER_SIZE)
	buf._newest_ts = ts
	buf._capture_count += 1


func run(cfg: Config) -> Result:
	var res := Result.new()
	var tick: float = Constants.TICK_DURATION
	var one_way: float = cfg.rtt_ms / 2000.0
	var lead_s: float = cfg.input_lead_ms / 1000.0

	var buf := StateBufferManager.new()
	var pending: Array[_Claim] = []
	var oldest_ts: float = -1.0

	var total: int = int(cfg.duration_s / tick)
	for i: int in total:
		var now: float = float(i) * tick
		# Host captures this tick's state. Straight-line motion so the buffer's
		# interpolated answer has a known closed form to check against.
		_push_skater(buf, _PEER, Vector3(0.0, 0.0, -cfg.speed * now), now)
		if oldest_ts < 0.0:
			oldest_ts = now
		if buf._skater_counts.get(_PEER, 0) >= StateBufferManager.BUFFER_SIZE:
			oldest_ts = now - float(StateBufferManager.BUFFER_SIZE - 1) * tick

		# The client stamps a claim with its estimate of host-now. Its clock is
		# NTP-corrected onto the host's timeline, so that estimate IS `now`; the
		# RPC then takes a one-way trip.
		if i % cfg.claim_every_ticks == 0 and i > 0:
			var c := _Claim.new()
			c.stamp = now
			c.arrive = now + one_way
			c.interp_delay_ms = cfg.interp_delay_ms
			c.input_lead_ms = cfg.input_lead_ms
			pending.append(c)
			res.claims += 1

		if not buf.is_ready():
			continue

		var newest: float = buf.newest_host_timestamp()
		for c: _Claim in pending:
			if c.resolved or now < c.arrive:
				continue
			# The shipping path holds the claim until the buffer covers the
			# instant it names; the legacy path resolves the moment it lands.
			if cfg.resolve_mode == ResolveMode.DEFER_TO_INSTANT \
					and newest < LagCompRewind.self_view_time(c.stamp, c.input_lead_ms):
				continue
			c.resolved = true
			res.resolved += 1

			# Until the ring holds at least the deepest rewind this claim will
			# ask for, a "before oldest" verdict says only that the session just
			# started — the buffer cannot contain pre-session history, and the
			# real resolvers cover this with is_ready() plus MAX_CLAIM_AGE_S.
			# Counted rather than silently skipped, so a test can tell the
			# difference between "excluded a warmup claim" and "asserted nothing".
			# Anchored on the CLAIM'S STAMP, not on `now`: the rewind reaches back
			# from the instant the claim names, so what matters is whether the ring
			# ever held that instant — not how long ago the session started.
			var deepest: float = c.interp_delay_ms / 1000.0 + tick
			if c.stamp - deepest < oldest_ts:
				res.warmup_skipped += 1
				continue

			var self_t: float = LagCompRewind.self_view_time(c.stamp, c.input_lead_ms)
			var remote_t: float = LagCompRewind.remote_view_time(c.stamp, c.interp_delay_ms)
			var puck_t: float = LagCompRewind.puck_view_time(c.stamp, c.input_lead_ms)

			# Answerability. A lookup past `newest` is silently clamped to the
			# newest sample, so nothing downstream can tell it was wrong.
			if self_t > newest:
				res.self_view_past_newest += 1
				res.max_lookup_overrun_ms = maxf(
						res.max_lookup_overrun_ms, (self_t - newest) * 1000.0)
			if remote_t > newest:
				res.remote_view_past_newest += 1
			if puck_t > newest:
				res.puck_view_past_newest += 1
			if minf(remote_t, LagCompRewind.prev_tick(remote_t)) < oldest_ts:
				res.view_before_oldest += 1

			# The remote-view lookup has a known closed form on this trajectory,
			# so an interpolation regression shows up as a position error rather
			# than as a plausible-looking number.
			if remote_t >= oldest_ts and remote_t <= newest:
				var snap: WorldSnapshot = buf.get_state_at(remote_t)
				var got: SkaterNetworkState = snap.get_skater_state(_PEER)
				if got != null:
					res.max_interp_error_m = maxf(res.max_interp_error_m,
							absf(got.position.z - (-cfg.speed * remote_t)))

			# render == rewind: the client's render depth and the host's
			# reconstruction depth must come out identical from the claim-carried
			# values. Both call the same shared helper — this catches a caller
			# that re-derives the lead or the fraction locally.
			var client_depth: int = LagCompRewind.forward_predict_ticks(
					Constants.REMOTE_FORWARD_PREDICT_FRACTION,
					cfg.interp_delay_ms / 1000.0, lead_s)
			var host_depth: int = LagCompRewind.forward_predict_ticks(
					Constants.REMOTE_FORWARD_PREDICT_FRACTION,
					c.interp_delay_ms / 1000.0,
					LagCompRewind.clamped_lead_s(c.input_lead_ms))
			if client_depth != host_depth:
				res.depth_mismatches += 1

		var keep: Array[_Claim] = []
		for c: _Claim in pending:
			if not c.resolved:
				keep.append(c)
		pending = keep

	return res
