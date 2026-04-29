class_name RemoteController
extends SkaterController

@export var interpolation_delay: float = Constants.NETWORK_INTERPOLATION_DELAY
@export var extrapolation_max_ms: float = 50.0
@export var rejoin_blend_duration: float = 0.075

var _input_queue: Array[InputState] = []
var _fallback_input: InputState = InputState.new()
var _state_buffer: Array[BufferedSkaterState] = []
var is_extrapolating: bool = false

var _rejoin_blend_elapsed: float = -1.0  # < 0 means inactive
var _rejoin_blend_from_pos: Vector3 = Vector3.ZERO
var _rejoin_blend_from_blade: Vector3 = Vector3.ZERO
var _rejoin_blend_from_hand: Vector3 = Vector3.ZERO

func get_buffer_depth() -> int:
	return _state_buffer.size()

func get_queue_depth() -> int:
	return _input_queue.size()

func apply_ghost_rpc(is_ghost: bool) -> void:
	if skater != null:
		skater.set_ghost(is_ghost)

func _physics_process(delta: float) -> void:
	if skater == null:
		return
	if NetworkManager.is_replay_mode():
		return
	if _is_host:
		_drive_from_input(delta)
	else:
		if _rejoin_blend_elapsed >= 0.0:
			_rejoin_blend_elapsed += delta
		_interpolate()
		skater.update_stick_mesh()

func receive_input_batch(batch: Array[InputState]) -> void:
	# Reject inputs whose timestamps fall outside a plausible window around the
	# host clock. Legitimate timestamps land in [now - RTT, now + INPUT_LEAD_SEC];
	# anything wildly outside is either a malicious peer or a desynced clock and
	# would otherwise sit in the queue indefinitely (future) or fail the gate
	# forever (past). The queue cap below already truncates older stragglers.
	const FUTURE_SLACK_S: float = 0.1   # INPUT_LEAD_SEC (~25ms) + slack for jitter / clock convergence
	const PAST_SLACK_S: float = 2.0     # generous: queue cap is 0.5s at 240Hz, this is 4x
	var now: float = NetworkManager.estimated_host_time()
	var existing_timestamps: Dictionary = {}
	for queued: InputState in _input_queue:
		existing_timestamps[queued.host_timestamp] = true
	for state: InputState in batch:
		if state.host_timestamp <= last_processed_host_timestamp:
			continue
		if existing_timestamps.has(state.host_timestamp):
			continue
		if state.host_timestamp < now - PAST_SLACK_S or state.host_timestamp > now + FUTURE_SLACK_S:
			continue
		_input_queue.append(state)
		existing_timestamps[state.host_timestamp] = true
	_input_queue.sort_custom(func(a: InputState, b: InputState) -> bool:
		return a.host_timestamp < b.host_timestamp)
	const MAX_QUEUE_DEPTH: int = 120  # 0.5s at 240 Hz
	while _input_queue.size() > MAX_QUEUE_DEPTH:
		_input_queue.pop_front()

func _drive_from_input(delta: float) -> void:
	# Pop one input per physics tick so every client input gets simulated on the
	# host in order. last_processed_host_timestamp advances only for inputs that
	# were actually simulated — the client's reconcile filter drops confirmed inputs
	# from its replay history based on this value.
	# During locked phases drain the queue (advancing the ack) but don't apply
	# movement — stale input would contaminate server state and cause a velocity
	# burst when the phase lifts.
	#
	# Timestamp gate: only pop an input when its scheduled host time has arrived.
	# Without this, inputs are consumed immediately on arrival regardless of their
	# timestamp, so the queue empties between 60Hz batches and fallback-input fires
	# every gap. Fall through when clock isn't ready to preserve behaviour during
	# NTP warmup.
	var input_due: bool = _input_queue.size() > 0 and (
			not NetworkManager.is_clock_ready() or
			_input_queue.front().host_timestamp <= NetworkManager.estimated_host_time())
	if input_due:
		var input: InputState = _input_queue.pop_front()
		last_processed_host_timestamp = input.host_timestamp
		NetworkTelemetry.record_input_lead(
				NetworkManager.estimated_host_time() - input.host_timestamp)
		if not _game_state.is_movement_locked():
			_process_input(input, delta)
		else:
			skater.velocity = Vector3.ZERO
		# Clear just_pressed flags before saving as fallback so they don't
		# re-fire on subsequent ticks while the queue is empty.
		input.shoot_pressed = false
		input.slap_pressed = false
		input.elevation_up = false
		input.elevation_down = false
		_fallback_input = input
	else:
		if _game_state.is_movement_locked():
			skater.velocity = Vector3.ZERO
			return
		if _input_queue.is_empty():
			NetworkTelemetry.record_input_starvation()
		_process_input(_fallback_input, delta)


func apply_network_state(state: SkaterNetworkState, host_ts: float) -> void:
	if _is_host:
		return
	if not _state_buffer.is_empty() and host_ts < _state_buffer.back().timestamp:
		NetworkTelemetry.record_ooo_drop()
		return
	var buffered := BufferedSkaterState.new()
	buffered.timestamp = host_ts
	buffered.state = state
	_state_buffer.append(buffered)
	if _state_buffer.size() > 30:
		_state_buffer.pop_front()
	_adapt_interpolation_delay()

func _interpolate() -> void:
	var render_time: float = NetworkManager.estimated_host_time() - interpolation_delay
	var bracket: BufferedStateInterpolator.BracketResult = BufferedStateInterpolator.find_bracket(
			_state_buffer, render_time)
	var prev_extrapolating: bool = is_extrapolating
	is_extrapolating = bracket != null and bracket.is_extrapolating
	if bracket == null:
		return
	var interpolated := SkaterNetworkState.new()
	if bracket.is_extrapolating:
		var dt: float = minf(bracket.extrapolation_dt, extrapolation_max_ms / 1000.0)
		var newest: SkaterNetworkState = bracket.to_state
		interpolated.position = newest.position + newest.velocity * dt
		interpolated.velocity = newest.velocity
		# blade_position and top_hand_position are in upper_body local space;
		# velocity is world space — do not advance them here. The scene graph
		# moves their world positions when body position advances above.
		interpolated.blade_position = newest.blade_position
		interpolated.top_hand_position = newest.top_hand_position
		interpolated.upper_body_rotation_y = newest.upper_body_rotation_y + newest.upper_body_angular_velocity * dt
		var extrap_fa: float = atan2(newest.facing.x, newest.facing.y) + newest.facing_angular_velocity * dt
		interpolated.facing = Vector2(sin(extrap_fa), cos(extrap_fa))
		interpolated.facing_angular_velocity = newest.facing_angular_velocity
		interpolated.upper_body_angular_velocity = newest.upper_body_angular_velocity
		interpolated.is_ghost = newest.is_ghost
	else:
		var from_state: SkaterNetworkState = bracket.from_state
		var to_state: SkaterNetworkState = bracket.to_state
		var t: float = bracket.t
		var dt: float = bracket.bracket_dt
		interpolated.position = BufferedStateInterpolator.hermite(from_state.position, from_state.velocity,
				to_state.position, to_state.velocity, t, dt)
		interpolated.velocity = from_state.velocity.lerp(to_state.velocity, t)
		interpolated.blade_position = from_state.blade_position.lerp(to_state.blade_position, t)
		interpolated.top_hand_position = from_state.top_hand_position.lerp(to_state.top_hand_position, t)
		interpolated.upper_body_rotation_y = BufferedStateInterpolator.hermite_angle(
				from_state.upper_body_rotation_y, from_state.upper_body_angular_velocity,
				to_state.upper_body_rotation_y, to_state.upper_body_angular_velocity, t, dt)
		var interp_fa: float = BufferedStateInterpolator.hermite_angle(
				atan2(from_state.facing.x, from_state.facing.y), from_state.facing_angular_velocity,
				atan2(to_state.facing.x, to_state.facing.y), to_state.facing_angular_velocity, t, dt)
		interpolated.facing = Vector2(sin(interp_fa), cos(interp_fa))
		# Boolean fields can't be lerped; take the freshest value so ghost-mode
		# toggles flow through to remote skaters without a one-broadcast delay.
		interpolated.is_ghost = to_state.is_ghost
		# Push position forward from render_time to present using the interpolated
		# velocity. Capped at extrapolation_max_ms so a large interpolation buffer
		# on a rough connection doesn't over-predict on direction changes.
		var forward_dt: float = minf(interpolation_delay, extrapolation_max_ms / 1000.0)
		interpolated.position += interpolated.velocity * forward_dt
		# blade_position and top_hand_position are in upper_body local space;
		# velocity is world space. Adding them is a coordinate frame error.
		# The body forward-advance above already moves their world positions
		# via the scene tree — no additional local-space offset needed.
	if prev_extrapolating and not is_extrapolating and skater != null:
		_rejoin_blend_from_pos = skater.global_position
		_rejoin_blend_from_blade = skater.get_blade_position()
		_rejoin_blend_from_hand = skater.top_hand.position
		_rejoin_blend_elapsed = 0.0
	if _rejoin_blend_elapsed >= 0.0:
		var ease_t: float = clampf(_rejoin_blend_elapsed / rejoin_blend_duration, 0.0, 1.0)
		interpolated.position = _rejoin_blend_from_pos.lerp(interpolated.position, ease_t)
		interpolated.blade_position = _rejoin_blend_from_blade.lerp(interpolated.blade_position, ease_t)
		interpolated.top_hand_position = _rejoin_blend_from_hand.lerp(interpolated.top_hand_position, ease_t)
		if ease_t >= 1.0:
			_rejoin_blend_elapsed = -1.0
	_apply_state_to_skater(interpolated)
	BufferedStateInterpolator.drop_stale(_state_buffer, render_time)

func _adapt_interpolation_delay() -> void:
	interpolation_delay = NetworkManager.adapt_interpolation_delay(interpolation_delay)

func _apply_state_to_skater(state: SkaterNetworkState) -> void:
	skater.global_position = state.position
	skater.velocity = state.velocity
	# Facing and upper-body rotation must be set before blade so the shaft mesh
	# orients against the correct body transform, not the previous tick's.
	skater.set_facing(state.facing)
	skater.set_upper_body_rotation(state.upper_body_rotation_y)
	# Top hand before blade so set_blade_position has the correct hand pivot.
	skater.set_top_hand_position(state.top_hand_position)
	skater.set_blade_position(state.blade_position)
	skater.set_ghost(state.is_ghost)
	# Arms are derived from shoulder + hand each frame; update after both are set.
	skater.update_arm_mesh()
	# Bottom hand is purely reactive to top_hand + blade (both already set
	# above) and needs no network state of its own.
	_ik.update_bottom_hand()
	skater.update_bottom_arm_mesh()
