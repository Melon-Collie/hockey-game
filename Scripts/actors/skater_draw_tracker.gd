class_name SkaterDrawTracker
extends RefCounted

# Faceoff draw tracking (host-only; the two centers, only during a faceoff).
# While active, retain a decaying peak of the horizontal blade velocity so the
# contested pickup reads the SWIPE'S CREST rather than the raw per-tick velocity
# at contact — a well-aimed sweep lands even if it peaks a few ticks off the
# drop. Zero cost unless `begin` is called: Skater skips `update` entirely while
# idle, and FaceoffDrawRules.decay_peak_speed and the timing weight are pure.
#
# Sister to the other Skater collaborators, but the only one with no geometry:
# it is a small clock the phase coordinator arms and the contested-pickup
# resolver reads.

var _tracking: bool = false
var _elapsed: float = 0.0             # real host physics time, for auto-expire only
var _drop_elapsed: float = -1.0       # _elapsed at the drop (auto-expire pin)
var _peak_vel: Vector3 = Vector3.ZERO # heading × retained crest speed
var _peak_speed: float = 0.0
# Timing is judged in SHARED host-clock time (the input's host_timestamp), NOT
# host physics elapsed: a client's draw is scored by WHEN IT INTENDED to swing
# (its stamped host-time of effect), not when its input happened to land on the
# host. So ping no longer taxes the timing bonus — only clock-sync accuracy does
# — and every client is judged on the same clock, an equal shot regardless of
# ping. (The host's own player / bots stamp host-now, so they're unchanged.)
var _input_host_time: float = 0.0     # current input's host_timestamp
var _peak_host_time: float = 0.0      # shared host-time of the retained crest
var _drop_host_time: float = -1.0     # shared host-time of the drop, -1 until marked
var _peak_decay: float = 0.0          # m/s per second (set by begin)
var _valid_window_s: float = 0.0      # auto-end this long after the drop


# Start retaining the blade-swipe crest for this skater's draw. Called by the
# phase coordinator on the two centers at FACEOFF_PREP entry so a swing during
# the countdown pre-rolls into the contest; reset on every call. peak_decay
# bleeds the retained crest (m/s per second); valid_window_s auto-ends tracking
# that long after the drop so a resolved draw never leaks a stale peak into
# later play.
func begin(peak_decay: float, valid_window_s: float) -> void:
	_tracking = true
	_elapsed = 0.0
	_drop_elapsed = -1.0
	_peak_vel = Vector3.ZERO
	_peak_speed = 0.0
	_input_host_time = 0.0
	_peak_host_time = 0.0
	_drop_host_time = -1.0
	_peak_decay = peak_decay
	_valid_window_s = valid_window_s


# Feed the current input's shared host-clock stamp so the crest is timed by when
# the swing was INTENDED (ping-neutral), not when it landed. Called by the
# controller each tick a draw is tracked.
func set_input_time(host_time: float) -> void:
	_input_host_time = host_time


# Stamp the drop instant (FACEOFF entry). host_time is the shared-clock drop
# time the timing bonus measures from; _elapsed pins the real-time auto-expire.
func mark_drop(host_time: float) -> void:
	_drop_elapsed = _elapsed
	_drop_host_time = host_time


func end() -> void:
	_tracking = false


func is_tracking() -> bool:
	return _tracking


# Retained swipe crest (heading × decayed peak speed) for the contested pickup.
func peak_velocity() -> Vector3:
	return _peak_vel


# Seconds from the drop to the retained crest, in shared host-clock time;
# negative if the crest predates the drop (an early swing) or the drop hasn't
# been marked → treated as neutral timing.
func since_drop() -> float:
	if _drop_host_time < 0.0:
		return -1.0
	return _peak_host_time - _drop_host_time


func update(delta: float, blade_world_velocity: Vector3) -> void:
	_elapsed += delta
	if _drop_elapsed >= 0.0 and _elapsed - _drop_elapsed > _valid_window_s:
		_tracking = false
		return
	var horiz := Vector3(blade_world_velocity.x, 0.0, blade_world_velocity.z)
	var cur_speed: float = horiz.length()
	var new_peak: float = FaceoffDrawRules.decay_peak_speed(
			_peak_speed, cur_speed, _peak_decay, delta)
	if cur_speed >= new_peak - 0.0001:
		# Current sweep is the crest — capture its heading and shared-clock time.
		if cur_speed > 0.0001:
			_peak_vel = horiz
			_peak_host_time = _input_host_time
	elif _peak_vel.length() > 0.0001:
		# Decaying — hold the crest heading, shed magnitude to the decayed peak.
		_peak_vel = _peak_vel.normalized() * new_peak
	_peak_speed = new_peak
