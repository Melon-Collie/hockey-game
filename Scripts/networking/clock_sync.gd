extends RefCounted

const INITIAL_PING_COUNT: int = 3
const INITIAL_PING_INTERVAL: float = 0.5
const ONGOING_PING_INTERVAL: float = 2.0
const SAMPLE_WINDOW: int = 8
const OUTLIER_DROP: int = 2
const OFFSET_EMA_ALPHA: float = 0.3  # after is_ready; ~3 pings to reach 66% of a new target

# Lead time added to input timestamps so they arrive at the host before their
# scheduled processing tick, keeping the host queue non-empty.
# BATCH_INTERVAL: worst-case send delay (input stamped right after a batch went
#   out) — derived from Constants.INPUT_RATE so a send-rate change can't
#   silently strand the lead (the old hardcoded 1/60 did exactly that when the
#   physics tick moved).
# BUFFER_TICKS: target host-side queue depth after accounting for batch delay.
const _PhysicsConstants: GDScript = preload("res://Scripts/game/constants.gd")
const BATCH_INTERVAL: float = 1.0 / _PhysicsConstants.INPUT_RATE
const BUFFER_TICKS: float = 2.0
const TICK_DURATION: float = 1.0 / _PhysicsConstants.PHYSICS_TICK
const INPUT_LEAD_SEC: float = BATCH_INTERVAL + BUFFER_TICKS * TICK_DURATION  # ~25 ms at 120 Hz input / 120 Hz tick

# ── Adaptive input-lead extra ────────────────────────────────────────────────
# The static INPUT_LEAD_SEC proved marginal in playtest: on a clean ~23 ms link
# the host's input queue ran median-0 with pops averaging 25-40 ms overdue —
# transit + batching + NTP offset error consumed the whole cushion, costing
# ~1 fallback tick/sec and the reconcile churn that follows. The client can see
# this itself from data already on the wire: each snapshot's input ack tells it
# how overdue that input was when the host popped it (snapshot host_ts − ack
# stamp). This servo adapts a bounded EXTRA lead on top of the constant, stepped
# asymmetrically (fast up: a starving host queue is felt immediately; slow down:
# over-lead only costs remote-visibility latency). The claim rewind convention
# follows it: claims carry the lead the client stamped with, and
# LagCompRewind.self_view_time uses the carried value (bounded host-side), so
# render == rewind holds at any adapted lead.
#
# THE TARGET MUST SIT ABOVE THE MEASURE'S OWN FLOOR. Pop-overdue is one-sided:
#
#     overdue = max(0, arrival − stamp) + tick quantization
#
# The lead can drive the lateness term to zero but never the quantization term,
# so overdue has a hard floor of a uniform [0, TICK) — mean ~TICK/2, Jacobson
# mean-absolute-deviation ~TICK/4. An earlier form servoed `mean + 4·dev` toward
# one tick of grace, which is unreachable BY CONSTRUCTION: 4·dev alone floors at
# ~TICK, so the error term floors at ~1.5·TICK against a 1·TICK target and stays
# positive at any lead. The integrator therefore had no zero and wound to
# MAX_LEAD_EXTRA_S on every link, including a perfect one — measured pinned at
# the 50 ms ceiling across three sessions on a 23 ms / 0%-loss link, i.e. a
# permanent 50 ms input-latency tax plus a host input queue running 3x its
# designed depth. Servo the MEAN alone, whose floor (~TICK/2) leaves real
# headroom under the one-tick target.
#
# The variance margin cannot be restored by moving it elsewhere: any margin the
# integrator can OBSERVE (added to the stamp, hence to the lead) reduces measured
# overdue and is simply backed out of _lead_extra, leaving the equilibrium
# unchanged. Burst tolerance comes from the fast-up/slow-down asymmetry below,
# which is not a bias and does not move the fixed point.
#
# NOTE (invariant): this state is SEPARATE from the NTP offset. ClockSync's
# offset stays pure ping/pong NTP — the ban on queue-depth feedback into
# _offset stands; the lead servo only shapes future STAMPS, never the clock.
const MAX_LEAD_EXTRA_S: float = 0.05          # hard ceiling: 6 ticks of extra
const _LEAD_GRACE_S: float = TICK_DURATION    # target MEAN overdue; floor is ~TICK/2
const _OVR_GAIN: float = 0.05                 # EMA horizon ~20 acks (~170 ms)
const _LEAD_UP_STEP_S: float = 0.001          # per ack: ~120 ms/s climb at 120 Hz
const _LEAD_DOWN_STEP_S: float = 0.00005      # per ack: ~6 ms/s relax
# Overdue beyond this is a phase-resume artifact (an input parked across a
# replay/intermission), not link lateness — excluded from the servo.
const _OVR_SAMPLE_MAX_S: float = 0.25
var _lead_extra: float = TICK_DURATION  # start one tick up (the playtest-measured deficit)
var _ovr_mean: float = 0.0


# Feed one measured pop-overdue sample (snapshot host_ts − freshly-advanced
# input ack). Caller dedupes repeated acks; range-guarded here.
func record_ack_overdue(overdue_s: float) -> void:
	if not is_ready:
		return
	if overdue_s < 0.0 or overdue_s > _OVR_SAMPLE_MAX_S or not is_finite(overdue_s):
		return
	_ovr_mean += (overdue_s - _ovr_mean) * _OVR_GAIN
	# Servo: the measured overdue already includes the current extra's effect, so
	# the error is RELATIVE — how far the mean sits above one tick of grace.
	# Mean above grace → climb; below → slow relax. The fixed point is reachable
	# (see the floor derivation above), which is the whole property here.
	var error: float = _ovr_mean - _LEAD_GRACE_S
	_lead_extra = clampf(
			_lead_extra + clampf(error, -_LEAD_DOWN_STEP_S, _LEAD_UP_STEP_S),
			0.0, MAX_LEAD_EXTRA_S)


func current_input_lead_s() -> float:
	return INPUT_LEAD_SEC + _lead_extra

var is_ready: bool = false
var rtt_ms: float = 0.0
var latest_rtt_ms: float = 0.0
# Magnitude of the last post-ready EMA correction to the offset (ms). The
# clock-quality telemetry signal: a settled clock corrects by ~0 each pong;
# sustained large corrections mean the offset estimate is unstable (asymmetric
# path, drifting clock), which silently poisons lag-comp rewind timestamps and
# the delay-spread measurement before anything visibly breaks.
var last_correction_ms: float = 0.0

var _offset: float = 0.0
var _last_estimated_time: float = 0.0
var _samples: Array = []  # Array of {rtt: float, offset: float}
var _pings_sent: int = 0
var _timer: float = 0.0
var _session_start_ms: int = 0

func init_session(ms: int) -> void:
	_session_start_ms = ms

func tick(delta: float) -> bool:
	_timer -= delta
	if _timer > 0.0:
		return false
	_timer = INITIAL_PING_INTERVAL if _pings_sent < INITIAL_PING_COUNT else ONGOING_PING_INTERVAL
	_pings_sent += 1
	return true

func record_pong(client_send_time: float, host_time: float, recv_time: float) -> void:
	var rtt := recv_time - client_send_time
	latest_rtt_ms = rtt * 1000.0
	var offset := (host_time + rtt / 2.0) - recv_time
	_samples.append({rtt = rtt, offset = offset})
	if _samples.size() > SAMPLE_WINDOW:
		_samples.pop_front()
	_recompute()
	if not is_ready and _samples.size() >= INITIAL_PING_COUNT:
		is_ready = true

func estimated_host_time() -> float:
	var t := (Time.get_ticks_msec() - _session_start_ms) / 1000.0 + _offset
	_last_estimated_time = maxf(t, _last_estimated_time)
	return _last_estimated_time

func estimated_input_stamp_time() -> float:
	return estimated_host_time() + INPUT_LEAD_SEC + _lead_extra

func _recompute() -> void:
	var sorted := _samples.duplicate()
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.rtt < b.rtt)
	var keep_end: int = maxi(sorted.size() - OUTLIER_DROP, 1)
	var keep := sorted.slice(0, keep_end)
	var rtt_sum := 0.0
	var offset_sum := 0.0
	for s: Dictionary in keep:
		rtt_sum += s.rtt
		offset_sum += s.offset
	rtt_ms = (rtt_sum / keep.size()) * 1000.0
	var raw_offset := offset_sum / keep.size()
	if is_ready:
		var corrected := lerpf(_offset, raw_offset, OFFSET_EMA_ALPHA)
		last_correction_ms = absf(corrected - _offset) * 1000.0
		_offset = corrected
	else:
		_offset = raw_offset
