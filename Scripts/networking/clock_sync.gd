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
	return estimated_host_time() + INPUT_LEAD_SEC

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
