class_name BufferedStateInterpolator

# Shared interpolation helper for PuckController / RemoteController /
# GoalieController. All three buffer timestamped network-state snapshots
# and interpolate between bracketing pairs; this class collapses the bracket
# search and stale-trim logic into one place. The per-field lerp stays in
# each controller because each state type has its own field mix.
#
# Buffer element contract (duck-typed): { timestamp: float, state }.

class BracketResult:
	var from_state: Variant = null
	var to_state: Variant = null
	var t: float = 0.0            # clamped [0, 1]; 1.0 when extrapolating
	var is_extrapolating: bool = false
	var extrapolation_dt: float = 0.0  # seconds past the newest snapshot
	var bracket_dt: float = 0.0   # time span between from and to snapshots

# Returns a BracketResult locating render_time within the buffer, or null if
# the buffer is empty or render_time hasn't reached the oldest entry yet.
# When render_time overshoots the newest snapshot, returns is_extrapolating=true
# with extrapolation_dt set so callers can dead-reckon with the newest velocity.
# Works with a single-entry buffer for the extrapolation case.
# Tick-path callers pass a reused `out` instance (every field is rewritten on
# each fill) so the per-tick lookup is allocation-free; null return still means
# "no bracket" regardless of whether `out` was supplied.
static func find_bracket(buffer: Array, render_time: float, out: BracketResult = null) -> BracketResult:
	if buffer.is_empty():
		return null
	if out == null:
		out = BracketResult.new()
	var newest = buffer[buffer.size() - 1]
	if render_time > newest.timestamp:
		out.from_state = newest.state
		out.to_state = newest.state
		out.t = 1.0
		out.is_extrapolating = true
		out.extrapolation_dt = render_time - newest.timestamp
		out.bracket_dt = 0.0
		return out
	if buffer.size() < 2:
		# Only one snapshot and render_time is behind it — display it directly
		# rather than holding at the spawn position until a second arrives.
		out.from_state = newest.state
		out.to_state = newest.state
		out.t = 0.0
		out.is_extrapolating = false
		out.extrapolation_dt = 0.0
		out.bracket_dt = 0.0
		return out
	for i in range(buffer.size() - 1):
		var a = buffer[i]
		var b = buffer[i + 1]
		if a.timestamp <= render_time and render_time <= b.timestamp:
			return _make(a, b, render_time, out)
	return null

# Drops stale buffer entries; keeps at least min_keep at the tail so the next
# tick still has material to bracket against.
static func drop_stale(buffer: Array, render_time: float, min_keep: int = 2) -> void:
	while buffer.size() > min_keep and buffer[1].timestamp < render_time:
		buffer.pop_front()

static func hermite(p0: Vector3, v0: Vector3, p1: Vector3, v1: Vector3, t: float, dt: float) -> Vector3:
	var t2: float = t * t
	var t3: float = t2 * t
	return (2.0*t3 - 3.0*t2 + 1.0) * p0 \
		 + (t3 - 2.0*t2 + t) * dt * v0 \
		 + (-2.0*t3 + 3.0*t2) * p1 \
		 + (t3 - t2) * dt * v1


static func hermite_angle(a0: float, av0: float, a1: float, av1: float, t: float, dt: float) -> float:
	# Unwrap a1 to within ±π of a0 so interpolation takes the short way around
	# the circle. Without this, a turn that crosses the ±π wrap (e.g. a0 = 3.1
	# ≈ 179°, a1 = -3.1 ≈ -179°) interpolates through 0° — a visible
	# half-rotation jump in one bracket instead of the intended tiny nudge.
	# Surfaced as a one-frame "weird rotation" hitch in goal replays and in
	# live remote skater rendering whenever a player turns past 180°.
	var diff: float = a1 - a0
	if diff > PI:
		a1 -= TAU
	elif diff < -PI:
		a1 += TAU
	var t2: float = t * t
	var t3: float = t2 * t
	return (2.0*t3 - 3.0*t2 + 1.0) * a0 \
		 + (t3 - 2.0*t2 + t) * dt * av0 \
		 + (-2.0*t3 + 3.0*t2) * a1 \
		 + (t3 - t2) * dt * av1

static func _make(a, b, render_time: float, out: BracketResult) -> BracketResult:
	out.from_state = a.state
	out.to_state = b.state
	var span: float = b.timestamp - a.timestamp
	out.t = clampf((render_time - a.timestamp) / span, 0.0, 1.0) if span > 0.0 else 0.0
	out.is_extrapolating = false
	out.extrapolation_dt = 0.0
	out.bracket_dt = span
	return out
