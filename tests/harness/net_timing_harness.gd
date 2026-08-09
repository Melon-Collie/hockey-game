class_name NetTimingHarness
extends RefCounted

# Deterministic simulation of the INPUT TIMING PIPELINE — the seam every netcode
# defect found so far has actually lived in.
#
# Not a physics harness. Nothing here skates or shoots. It models the plumbing:
# how a client's physics steps are scheduled against its render loop, what
# instant each input is stamped with, how the link delays/reorders/drops the
# batch, how the host dedupes and gates consumption, and what the lead servo
# measures. Those are clocks, queues, buffers and ordering — and clocks, queues,
# buffers and ordering are where the bugs have been.
#
# It exists because the alternative is finding these by feel. Every defect in
# this area so far surfaced from reading code or reading telemetry after a
# session, one at a time, months apart. An assertion that fails in 20 seconds is
# a different development loop.
#
# THE CRITICAL PROPERTY: the harness can reproduce the KNOWN bug. `StampMode`
# switches between the legacy wall-clock stamping and the shipping tick-domain
# clock, and the suite asserts that the legacy mode loses inputs while the
# current one does not. A harness that only ever passes proves nothing about the
# next defect; one that fails on demand has teeth.
#
# Real code under test, not reimplementations:
#   - NetworkManager.next_sim_offset  (the tick-domain slew)
#   - ClockSync.record_ack_overdue / current_input_lead_s  (the lead servo)
# The dedupe, gate and drain rules mirror RemoteController; they live in a Node
# that can't be stood up headless, and the mirrors are pinned to the same
# constants so a divergence shows up as a failing expectation rather than drift.

const _ClockSyncScript: GDScript = preload("res://Scripts/networking/clock_sync.gd")

# Mirrors of RemoteController's queue policy. Sourced from the class consts so a
# change there is a change here.
const DRAIN_TRIGGER_S: float = RemoteController._DRAIN_TRIGGER_S
const DRAIN_TARGET_S: float = RemoteController._DRAIN_TARGET_S


enum StampMode {
	WALL_CLOCK,   # legacy: Time.get_ticks_msec() at 1 ms resolution
	TICK_DOMAIN,  # shipping: NetworkManager.sim_time()
}


class Config:
	var client_fps: float = 60.0
	var host_fps: float = 60.0
	var physics_hz: float = 120.0
	var rtt_ms: float = 30.0
	var jitter_ms: float = 0.0
	var loss_pct: float = 0.0
	var duration_s: float = 5.0
	var stamp_mode: StampMode = StampMode.TICK_DOMAIN
	var seed: int = 12345


class Result:
	var produced: int = 0            # inputs the client's physics steps generated
	var sent: int = 0                # survived the link
	var deduped: int = 0             # dropped as a TRUE duplicate (same stamp already queued)
	var late_drops: int = 0          # arrived after that instant was already consumed
	var consumed: int = 0            # actually applied
	var starvations: int = 0         # gate found an empty queue on a live tick
	var drains: int = 0              # backlog drain fired
	var drained_inputs: int = 0      # inputs acked-without-applying by the drain
	var lead_extra_ms: float = 0.0   # where the servo settled
	var overdue_mean_ms: float = 0.0
	var overdue_max_ms: float = 0.0
	var queue_depth_max: int = 0
	var colliding_stamps: int = 0    # consecutive stamps that were not distinguishable

	func summary() -> String:
		return ("produced=%d sent=%d deduped=%d late=%d consumed=%d collisions=%d "
				+ "starve=%d drains=%d lead_extra=%.1fms overdue_mean=%.1fms qmax=%d") % [
				produced, sent, deduped, late_drops, consumed, colliding_stamps,
				starvations, drains, lead_extra_ms, overdue_mean_ms, queue_depth_max]


class _Packet:
	var stamp: float = 0.0
	var arrive_wall: float = 0.0


# A peer's physics scheduling. The whole point: Godot accumulates elapsed real
# time inside the main loop and runs however many fixed steps fit, THEN renders.
# So at 60 fps with a 120 Hz tick, two steps execute back to back and both
# observe the SAME wall clock — which is the entire bug this harness was built
# to catch.
class _Peer:
	var wall: float = 0.0
	var _accum: float = 0.0
	var _step: float = 0.0
	var _frame: float = 0.0
	# Tick-domain clock state (mirrors NetworkManager's, using its real slew).
	var sim_ticks: int = 0
	var sim_offset: float = 0.0
	var sim_started: bool = false
	# Wall clock as the engine actually exposes it: 1 ms resolution.
	var wall_offset: float = 0.0

	func _init(fps: float, physics_hz: float, clock_offset: float) -> void:
		_step = 1.0 / physics_hz
		_frame = 1.0 / fps
		wall_offset = clock_offset

	func frame_interval() -> float:
		return _frame

	# Advance this peer to a point on the SHARED wall timeline and return how many
	# physics steps that frame ran. Every step inside the returned count observes
	# the same wall clock — which is the entire effect being modelled.
	func advance_to(new_wall: float) -> int:
		_accum += new_wall - wall
		wall = new_wall
		var steps: int = 0
		while _accum >= _step:
			_accum -= _step
			steps += 1
		return steps

	# What Time.get_ticks_msec() would report: quantized to 1 ms.
	func wall_now() -> float:
		return floorf((wall + wall_offset) * 1000.0) / 1000.0

	func advance_sim_tick() -> void:
		var w: float = wall_now()
		if not sim_started:
			sim_started = true
			sim_ticks = 0
			sim_offset = w
			return
		sim_ticks += 1
		sim_offset = NetworkManager.next_sim_offset(sim_offset, sim_ticks, w)

	func sim_now() -> float:
		if not sim_started:
			return wall_now()
		return float(sim_ticks) * (1.0 / 120.0) + sim_offset


var _rng := RandomNumberGenerator.new()


func run(cfg: Config) -> Result:
	var res := Result.new()
	_rng.seed = cfg.seed

	var one_way: float = cfg.rtt_ms / 2000.0
	# Both peers share a clock ORIGIN because a real client's estimated_host_time()
	# is already NTP-corrected onto the host's timeline — the raw offset is removed
	# before anything here reads it. Modelling an uncorrected offset would simulate
	# a state the system never occupies. What still differs, and is the point, is
	# the two peers' FRAME cadence.
	var client := _Peer.new(cfg.client_fps, cfg.physics_hz, 0.0)
	var host := _Peer.new(cfg.host_fps, cfg.physics_hz, 0.0)

	var servo: RefCounted = _ClockSyncScript.new()
	servo.init_session(0)

	var in_flight: Array[_Packet] = []
	var queue: Array[float] = []          # stamps, sorted
	var last_processed: float = -INF
	var last_stamp: float = -INF
	var overdue_sum: float = 0.0
	var overdue_n: int = 0

	# Shared wall timeline: each peer's frames fire when they are due, so two peers
	# at different framerates stay on ONE clock. Driving both once per iteration
	# instead lets their wall times diverge, which silently invalidates every
	# queue-depth and starvation assertion downstream.
	const EPS: float = 1e-9
	var t: float = 0.0
	var c_next: float = client.frame_interval()
	var h_next: float = host.frame_interval()
	while true:
		t = minf(c_next, h_next)
		if t > cfg.duration_s:
			break

		if c_next <= t + EPS:
			c_next += client.frame_interval()
			for _s: int in client.advance_to(t):
				client.advance_sim_tick()
				var stamp: float = client.sim_now() \
						if cfg.stamp_mode == StampMode.TICK_DOMAIN else client.wall_now()
				# current_input_lead_s() is the FULL lead (base + servo extra).
				stamp += servo.current_input_lead_s()
				res.produced += 1
				# Distinguishability on the 0.1 ms wire grid — the property the
				# host's strictly-greater dedupe depends on.
				if last_stamp > -INF and absf(stamp - last_stamp) < 0.0001:
					res.colliding_stamps += 1
				last_stamp = stamp
				if cfg.loss_pct > 0.0 and _rng.randf() * 100.0 < cfg.loss_pct:
					continue
				var pkt := _Packet.new()
				pkt.stamp = stamp
				var jitter: float = 0.0
				if cfg.jitter_ms > 0.0:
					jitter = _rng.randf_range(0.0, cfg.jitter_ms / 1000.0)
				pkt.arrive_wall = t + one_way + jitter
				in_flight.append(pkt)
				res.sent += 1

		if h_next <= t + EPS:
			h_next += host.frame_interval()
			for _s: int in host.advance_to(t):
				host.advance_sim_tick()
				var now: float = host.sim_now() \
						if cfg.stamp_mode == StampMode.TICK_DOMAIN else host.wall_now()

				# Delivery + the host's strictly-greater dedupe.
				var still: Array[_Packet] = []
				for pkt: _Packet in in_flight:
					if pkt.arrive_wall > t:
						still.append(pkt)
						continue
					# Mirrors RemoteController.receive_input_batch: an input whose
					# instant has already been consumed is gone, but one that merely
					# arrives OUT OF ORDER is still new and gets inserted (the real
					# code builds a seen-set rather than dropping everything at or
					# below the newest queued stamp). Counting them apart matters:
					# late drops are honest packet reordering, duplicates are a
					# stamping bug.
					if pkt.stamp <= last_processed:
						res.late_drops += 1
						continue
					if queue.has(pkt.stamp):
						res.deduped += 1
						continue
					queue.append(pkt.stamp)
				in_flight = still
				queue.sort()
				res.queue_depth_max = maxi(res.queue_depth_max, queue.size())

				# Backlog drain (mirrors RemoteController._drain_backlog).
				if queue.size() > 1 and now - queue[0] > DRAIN_TRIGGER_S:
					res.drains += 1
					var drain_to: float = now - DRAIN_TARGET_S
					while queue.size() > 1 and queue[0] < drain_to:
						last_processed = queue.pop_front()
						res.drained_inputs += 1

				# Consumption gate.
				if queue.is_empty():
					res.starvations += 1
					continue
				if queue[0] > now:
					continue
				var stamp: float = queue.pop_front()
				last_processed = stamp
				res.consumed += 1
				var overdue: float = now - stamp
				overdue_sum += overdue
				overdue_n += 1
				res.overdue_max_ms = maxf(res.overdue_max_ms, overdue * 1000.0)
				servo.record_ack_overdue(overdue)

	res.lead_extra_ms = (servo.current_input_lead_s() - NetworkManager.INPUT_LEAD_SEC) * 1000.0
	res.overdue_mean_ms = (overdue_sum / float(maxi(overdue_n, 1))) * 1000.0
	return res
