class_name RemoteController
extends SkaterController

@export var extrapolation_max_ms: float = 50.0
# Forward-projection toward host-present, 0..1 (see _interpolate). 0 reproduces
# the legacy interpolate-in-the-past behaviour; higher values close the chase and
# body-check contact gap. Tune up by feel; the SmoothDamp stage absorbs the error.
@export_range(0.0, 1.0, 0.05) var extrapolation_lead_fraction: float = 0.5
# Critically-damped smoothing time (s) for the remote body position. Larger =
# smoother corrections, more chase lag; smaller = snappier, jumpier.
@export var position_smooth_time: float = 0.05

var _input_queue: Array[InputState] = []
var _fallback_input: InputState = InputState.new()
var _state_buffer: Array[BufferedSkaterState] = []
var is_extrapolating: bool = false

# Knockback lead (Lever B): a brief, self-zeroing forward bias on the interpolated
# position right after a credited check, so the victim's knockback reads as a sharp
# punch on remote screens instead of reading soft under the SmoothDamp stage.
# Applied as a final additive AFTER the position smoother (see _interpolate) so the
# offset is a 0→peak→0 pulse that never causes lasting divergence — it lurches the
# body into the hit direction immediately, then decays as the real (now less-delayed)
# knockback samples catch up and hand off. Magnitude and duration are feel-tunable.
var _knockback_lead_elapsed: float = -1.0  # < 0 means inactive
var _knockback_lead_offset: Vector3 = Vector3.ZERO  # peak offset = dir * meters
const _KNOCKBACK_LEAD_DURATION_S: float = 0.12
const _KNOCKBACK_LEAD_MAX_M: float = 0.22  # peak lead at a full-strength check
# Reused scratch objects for the per-tick interpolation lookup + output —
# allocating fresh ones each tick was measurable churn at the physics rate × 5 remotes.
var _scratch_bracket := BufferedStateInterpolator.BracketResult.new()
var _scratch_interp := SkaterNetworkState.new()
# Critically-damped position smoother state (see _interpolate). Persistent across
# ticks; SmoothDamp tracks the moving render target so lead errors blend out.
var _smooth_pos: Vector3 = Vector3.ZERO
var _smooth_vel: Vector3 = Vector3.ZERO
var _smooth_initialized: bool = false
const _SMOOTH_SNAP_DIST: float = 2.0  # teleport/faceoff jump → snap, don't slide

func get_buffer_depth() -> int:
	return _state_buffer.size()

func get_queue_depth() -> int:
	return _input_queue.size()

func apply_ghost_rpc(is_ghost: bool) -> void:
	if skater != null:
		skater.set_ghost(is_ghost)

# Called by GameManager when this remote skater is the victim of a credited check
# (Lever B). Starts the knockback-lead pulse, scaled by hit strength. No-op on the
# host (host drives remotes from input, not interpolation) and for a zero/degenerate
# hit direction.
func start_knockback_lead(hit_dir: Vector3, force: float) -> void:
	if _is_host:
		return
	var flat := Vector3(hit_dir.x, 0.0, hit_dir.z)
	if flat.length_squared() < 0.0001:
		return
	_knockback_lead_offset = flat.normalized() * (_KNOCKBACK_LEAD_MAX_M * SkaterVFX.check_intensity(force))
	_knockback_lead_elapsed = 0.0

func _physics_process(delta: float) -> void:
	if skater == null:
		return
	if NetworkManager.is_replay_mode():
		return
	if _is_host:
		_drive_from_input(delta)
	else:
		if _knockback_lead_elapsed >= 0.0:
			_knockback_lead_elapsed += delta
		_interpolate(delta)
		# Cosmetic leg gait, derived from the interpolated velocity — no extra
		# network state. (Host-driven remotes animate via _process_input above.
		# Stick/arm meshes update once per rendered frame in Skater._process.)
		_skating.apply(delta)

func receive_input_batch(batch: Array[InputState]) -> void:
	# Reject inputs whose timestamps fall outside a plausible window around the
	# host clock. Legitimate timestamps land in [now - RTT, now + INPUT_LEAD_SEC];
	# anything wildly outside is either a malicious peer or a desynced clock and
	# would otherwise sit in the queue indefinitely (future) or fail the gate
	# forever (past). The queue cap below already truncates older stragglers.
	const FUTURE_SLACK_S: float = 0.1   # INPUT_LEAD_SEC (~25ms) + slack for jitter / clock convergence
	const PAST_SLACK_S: float = 2.0     # generous: queue cap is ~0.5 s, this is 4x
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
	var MAX_QUEUE_DEPTH: int = Constants.PHYSICS_TICK / 2  # ~0.5 s
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
			# FACEOFF_PREP: keep the host's view of this remote peer's stick in
			# sync with their mouse so world state broadcasts the right blade
			# position for everyone else to see. _process_input still doesn't
			# run, so body/shot inputs stay suppressed.
			if _game_state.allows_blade_aim_during_lock():
				apply_blade_aim_only(input, delta)
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
			if _game_state.allows_blade_aim_during_lock():
				# Keep the stick on the most recent mouse aim we have — stale
				# but better than freezing mid-swing while the input queue gaps.
				apply_blade_aim_only(_fallback_input, delta)
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

func _interpolate(delta: float) -> void:
	# Shared delay (NetworkManager) keeps the puck and other remotes on the same
	# timeline; the per-skater lead below shifts this body toward host-present.
	var interp_delay: float = NetworkManager.get_interpolation_delay()
	# Lead the render time toward host-present by a fraction of the buffer depth so
	# remote bodies sit closer to where the host actually has them — the chase gap
	# and the client-vs-host body-check contact mismatch both shrink with it.
	# fraction 0 == legacy "interpolate in the past"; 1 == render at present (full
	# ~interp_delay of dead-reckon). Scales with interp_delay, so it tracks RTT/jitter.
	var render_time: float = NetworkManager.estimated_host_time() \
			- interp_delay * (1.0 - extrapolation_lead_fraction)
	var bracket: BufferedStateInterpolator.BracketResult = BufferedStateInterpolator.find_bracket(
			_state_buffer, render_time, _scratch_bracket)
	is_extrapolating = bracket != null and bracket.is_extrapolating
	if bracket == null:
		return
	# Reused scratch (per-tick path): both branches below write every field that
	# _apply_state_to_skater reads, so no stale value can leak across ticks.
	var interpolated := _scratch_interp
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
		interpolated.is_elevated = newest.is_elevated
		interpolated.blade_up = newest.blade_up
		interpolated.shot_state = newest.shot_state
		interpolated.shot_charge = newest.shot_charge
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
		# Boolean/enum fields can't be lerped; take the freshest value so
		# ghost-mode and shot-pose toggles flow through to remote skaters
		# without a one-broadcast delay. (shot_state / is_elevated were
		# previously never copied onto the interpolated object at all, so
		# _apply_state_to_skater wrote type defaults to the skater every tick
		# and the elevated-blade replication had no effect on remotes.)
		interpolated.is_ghost = to_state.is_ghost
		interpolated.is_elevated = to_state.is_elevated
		interpolated.blade_up = to_state.blade_up
		interpolated.shot_state = to_state.shot_state
		# Smooth float: lerped so the remote charge-glow ramps like the local one.
		interpolated.shot_charge = lerpf(from_state.shot_charge, to_state.shot_charge, t)
		# render_time is led toward present by extrapolation_lead_fraction, so the
		# hermite result already sits close to the host's live pose (or, past the
		# newest sample, the is_extrapolating branch dead-reckons it). The position
		# error from a wrong lead is absorbed by the SmoothDamp stage below — the
		# old "interpolate strictly in the past" rule was relaxed once that smoother
		# replaced the snap-prone steady advance. blade/top_hand are upper_body-local
		# and ride the body through the scene tree, so they need no projection.
	# Velocity-feed-forward error smoothing on the collision body position. We advance
	# by the target's OWN velocity each frame (zero steady-state lag — smoothing the
	# absolute position instead trails a moving body by ~velocity × smooth_time) and
	# critically-damp only the residual error toward the authoritative target. So a
	# wrong lead, a contradicting snapshot, or an interp<->extrap branch flip blends
	# out, while straight-line motion tracks exactly. position_smooth_time now governs
	# how fast that residual decays, not steady tracking. Subsumes the former
	# rejoin-blend (every seam); a large delta (teleport / faceoff / goal reset) snaps.
	var target_pos: Vector3 = interpolated.position
	if not _smooth_initialized or _smooth_pos.distance_to(target_pos) > _SMOOTH_SNAP_DIST:
		_smooth_pos = target_pos
		_smooth_vel = Vector3.ZERO
		_smooth_initialized = true
	else:
		_smooth_pos += interpolated.velocity * delta
		_smooth_pos = _smooth_damp(_smooth_pos, target_pos, position_smooth_time, delta)
	interpolated.position = _smooth_pos
	# Knockback lead pulse (Lever B), applied as a final additive AFTER smoothing so
	# the punch stays sharp instead of being absorbed by SmoothDamp. sin(t·π) is a
	# clean 0→1→0: the body lurches into the hit immediately, peaks ~60ms, then
	# decays as the real (now less-delayed) knockback samples arrive.
	if _knockback_lead_elapsed >= 0.0:
		var klt: float = _knockback_lead_elapsed / _KNOCKBACK_LEAD_DURATION_S
		if klt >= 1.0:
			_knockback_lead_elapsed = -1.0
		else:
			interpolated.position += _knockback_lead_offset * sin(klt * PI)
	_apply_state_to_skater(interpolated)
	BufferedStateInterpolator.drop_stale(_state_buffer, render_time)


# Unity-style critically damped smoothing toward a (possibly moving) target.
# Mutates _smooth_vel; returns the new position. Pure value-type math — no alloc,
# hot-path safe at 120 Hz × remotes.
func _smooth_damp(current: Vector3, target: Vector3, smooth_time: float, delta: float) -> Vector3:
	var omega: float = 2.0 / maxf(smooth_time, 0.0001)
	var x: float = omega * delta
	var exp_factor: float = 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x)
	var change: Vector3 = current - target
	var temp: Vector3 = (_smooth_vel + change * omega) * delta
	_smooth_vel = (_smooth_vel - temp * omega) * exp_factor
	return target + (change + temp) * exp_factor

func _apply_state_to_skater(state: SkaterNetworkState) -> void:
	skater.global_position = state.position
	skater.velocity = state.velocity
	# Facing and upper-body rotation must be set before blade so the shaft mesh
	# orients against the correct body transform, not the previous tick's.
	skater.set_facing(state.facing)
	skater.set_upper_body_rotation(state.upper_body_rotation_y)
	# Top hand before blade so set_blade_position has the correct hand pivot.
	skater.set_top_hand_position(state.top_hand_position)
	# Re-derive lean from velocity + hand reach (not in network state) so the
	# upper body is leaning correctly when the blade marker is placed —
	# otherwise the host's lean-compensated blade_y lands above the ice.
	_pose.snap_lean_to_state()
	skater.set_blade_position(state.blade_position)
	skater.set_ghost(state.is_ghost)
	# Replicated from the host so the elevated-shot blade lift (Skater
	# ._update_blade_elevation) shows on spectated remotes, not just locally.
	skater.is_elevated = state.is_elevated
	# Resolved stick-lift state. The lifted blade pose already rides in via the
	# replicated blade_position above; this keeps skater.blade_up correct for
	# any reader (AI off-puck, VFX) on spectated remotes.
	skater.blade_up = state.blade_up
	skater.current_shot_state = state.shot_state
	# Cosmetic: drives the blade charge-glow (SkaterVFX) on remote skaters, so
	# an opponent's wind-up is a readable tell everywhere, not just locally.
	skater.shot_charge = state.shot_charge
	# Bottom hand is purely reactive to top_hand + blade (both already set
	# above) and needs no network state of its own. Arm/stick meshes derive
	# from the markers once per rendered frame in Skater._process.
	_ik.update_bottom_hand()
