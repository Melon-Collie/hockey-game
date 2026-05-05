class_name PuckController
extends Node

const PICKUP_RADIUS: float = 0.5
const POKE_RADIUS: float = 0.5
const CONTEST_SQUIRT_SPEED: float = 3.0

# Crease pushout — frees a puck stuck under the goalie. If a loose puck sits
# nearly stationary inside a crease for CREASE_PUSHOUT_DELAY seconds, the host
# kicks it outward at CREASE_PUSHOUT_SPEED. Naturally retries (timer resets to
# 0 after each kick) if the first kick doesn't dislodge it.
const CREASE_PUSHOUT_DELAY: float = 2.0
const CREASE_PUSHOUT_SPEED: float = 3.0
const CREASE_STATIONARY_SPEED: float = 0.5

@export var interpolation_delay: float = Constants.NETWORK_INTERPOLATION_DELAY
@export var extrapolation_max_ms: float = 50.0
# Velocity decay applied during extrapolation to approximate ice friction.
# Set to match observed Jolt physics deceleration rate (m/s per second linear).
@export var extrapolation_friction: float = 0.5
@export var trajectory_hard_snap_threshold: float = 1.5
@export var trajectory_soft_blend_threshold: float = 0.3
@export var position_correction_blend: float = 0.1
@export var rejoin_blend_duration: float = 0.075
# Extra friction applied during trajectory prediction to compensate for any
# divergence between client and host Jolt friction. Set to 0 while both run
# identical physics; tune upward if free-puck trajectories drift apart.
@export var prediction_extra_friction: float = 0.0
@export var carry_smoothing_speed: float = 80.0

var puck: Puck = null
var is_server: bool = false

# ── State ─────────────────────────────────────────────────────────────────────
var _carrier_peer_id: int = -1            # server-side authoritative carrier
var _local_carrier_skater: Skater = null  # client-side: local skater while carrying
var _prev_puck_pos: Vector3 = Vector3.ZERO
var _state_buffer: Array[BufferedPuckState] = []
var _predicting_trajectory: bool = false
var _pending_local_release: bool = false  # true from local release until host confirms carrier == -1
var _shot_rtt_ms: float = 0.0             # RTT captured at release time; used for trajectory reconcile
var is_extrapolating: bool = false

var _rejoin_blend_elapsed: float = -1.0  # < 0 means inactive
var _post_contact_timer: float = -1.0    # >= 0 while suppressing reconcile after a bounce
var _rejoin_blend_from_pos: Vector3 = Vector3.ZERO
var _crease_idle_timer: float = 0.0      # server-only; seconds loose & stationary in a crease

func get_buffer_depth() -> int:
	return _state_buffer.size()

func get_local_carrier() -> Skater:
	return _local_carrier_skater

# Callable (Skater) -> int peer_id, or -1 if not registered.
var _peer_id_resolver: Callable = Callable()
# Callable () -> Array[Skater] of all active skaters. Host-only interaction detection.
var _skater_getter: Callable = Callable()
# Callable (Skater) -> int team_id. Used by poke-check eligibility.
var _team_id_resolver: Callable = Callable()

# ── Signals (server-side puck events, GameManager listens) ───────────────────
signal puck_picked_up_by(peer_id: int)
signal puck_released_by_carrier(peer_id: int)
signal puck_stripped_from(peer_id: int)
signal puck_touched_while_loose(peer_id: int)  # deflection or body block — peer who touched
signal puck_touched_by_goalie(goalie: Goalie)  # puck contacted a goalie body while a shot was in flight

# ── Setup ─────────────────────────────────────────────────────────────────────
func setup(assigned_puck: Puck, assigned_is_server: bool) -> void:
	puck = assigned_puck
	is_server = assigned_is_server
	puck.set_server_mode(is_server)
	process_physics_priority = 1  # Run after Skater.move_and_slide so blade world pos is current
	if is_server:
		puck.puck_released.connect(_on_puck_released)
		puck.puck_stripped.connect(_on_puck_stripped)
		puck.puck_touched_loose.connect(func(s: Skater) -> void: puck_touched_while_loose.emit(_peer_id_resolver.call(s)))
		puck.puck_body_blocked.connect(func(s: Skater) -> void: puck_touched_while_loose.emit(_peer_id_resolver.call(s)))
		puck.puck_touched_goalie.connect(func(g: Goalie) -> void: puck_touched_by_goalie.emit(g))
	else:
		puck.puck_touched_goalie.connect(_on_client_puck_hit_goalie)
		puck.puck_touched_post.connect(_on_client_puck_hit_post)

func set_peer_id_resolver(resolver: Callable) -> void:
	_peer_id_resolver = resolver

func set_skater_getter(getter: Callable) -> void:
	_skater_getter = getter

func set_team_id_resolver(resolver: Callable) -> void:
	_team_id_resolver = resolver

func _physics_process(delta: float) -> void:
	if puck == null:
		return
	if is_server:
		_check_interactions()
		_tick_crease_pushout(delta)
		_prev_puck_pos = puck.get_puck_position()
		return
	if _rejoin_blend_elapsed >= 0.0:
		_rejoin_blend_elapsed += delta
	if _local_carrier_skater != null:
		is_extrapolating = false
		_apply_local_carrier_position(delta)
		if NetworkTelemetry.instance: NetworkTelemetry.instance.puck_mode = "pinned"
	elif not _predicting_trajectory:
		_interpolate()
		if NetworkTelemetry.instance: NetworkTelemetry.instance.puck_mode = "interpolating"
	else:
		is_extrapolating = false
		if NetworkTelemetry.instance: NetworkTelemetry.instance.puck_mode = "predicting"
		if _post_contact_timer >= 0.0:
			_post_contact_timer -= delta
			if _post_contact_timer < 0.0:
				# Suppression window expired: buffer has post-bounce data. Transition
				# to interpolation with a rejoin blend from the Jolt-simulated position.
				_rejoin_blend_from_pos = puck.get_puck_position()
				_rejoin_blend_elapsed = 0.0
				_predicting_trajectory = false
				puck.set_client_prediction_mode(false)
		if _predicting_trajectory and prediction_extra_friction > 0.0:
			puck.set_puck_velocity(puck.get_puck_velocity() * pow(1.0 - prediction_extra_friction, delta))

# ── Lag Compensation ─────────────────────────────────────────────────────────
# Called by GameManager after validating a client pickup claim against the
# state buffer. Re-checks carrier == null so a concurrent _check_interactions
# detection (which needs no validation) is never double-applied.
func apply_lag_comp_pickup(skater: Skater) -> void:
	if not is_instance_valid(skater) or puck.carrier != null:
		return
	puck.set_carrier(skater)
	_on_puck_picked_up(skater)


# Two valid pickup claims arrived within the contest window. Neither player
# wins — the puck squirts perpendicular to the line between the two blade
# contact points (both blades pressing inward pinch the puck like a seed
# between two fingers; it exits sideways, randomised left or right).
func apply_contested_pickup(skater_a: Skater, skater_b: Skater) -> void:
	if not is_instance_valid(skater_a) or not is_instance_valid(skater_b):
		return
	var along := skater_a.get_blade_contact_global() - skater_b.get_blade_contact_global()
	along.y = 0.0
	if along.length() < 0.001:
		along = Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0))
	var perp := Vector3(-along.z, 0.0, along.x)
	if randf() > 0.5:
		perp = -perp
	puck.set_puck_velocity(perp.normalized() * CONTEST_SQUIRT_SPEED)
	puck.set_skater_cooldown(skater_a, puck.reattach_cooldown)
	puck.set_skater_cooldown(skater_b, puck.reattach_cooldown)


# ── Server Interaction Detection ─────────────────────────────────────────────
func _check_interactions() -> void:
	if not _skater_getter.is_valid():
		return
	var puck_curr: Vector3 = puck.get_puck_position()
	var skaters: Array = _skater_getter.call()

	if puck.carrier != null:
		if not puck.pickup_locked:
			for skater: Skater in skaters:
				if skater == puck.carrier or skater.is_ghost:
					continue
				var carrier_team: int = _team_id_resolver.call(puck.carrier)
				var checker_team: int = _team_id_resolver.call(skater)
				if not PuckCollisionRules.can_poke_check(carrier_team, checker_team):
					continue
				var blade_curr: Vector3 = skater.get_blade_contact_global()
				var blade_prev: Vector3 = skater.get_prev_blade_contact_global()
				if PuckInteractionRules.check_poke(_prev_puck_pos, puck_curr,
						blade_prev, blade_curr, POKE_RADIUS):
					puck.apply_poke_check(skater)
					break
	else:
		if not puck.pickup_locked:
			for skater: Skater in skaters:
				if skater.is_ghost or puck.is_on_cooldown(skater):
					continue
				var blade_curr: Vector3 = skater.get_blade_contact_global()
				var blade_prev: Vector3 = skater.get_prev_blade_contact_global()
				if not PuckInteractionRules.check_pickup(_prev_puck_pos, puck_curr,
						blade_prev, blade_curr, PICKUP_RADIUS):
					continue
				var puck_speed: float = puck.get_puck_velocity().length()
				var rel_speed: float = (puck.get_puck_velocity() - skater.blade_world_velocity).length()
				if puck_speed <= puck.pickup_max_speed or rel_speed < puck.deflect_min_speed:
					puck.set_carrier(skater)
					_on_puck_picked_up(skater)
				else:
					puck.apply_blade_deflect(skater)
				break


# ── Crease Pushout ───────────────────────────────────────────────────────────
# Frees a puck that sits stationary in a crease (typically wedged under the
# goalie). Speed gate uses puck velocity; any blade deflect / body block / poke
# bumps the puck above the threshold so legitimate play resets the timer for
# free. Pickup also resets via the carrier check.
func _tick_crease_pushout(delta: float) -> void:
	if puck.carrier != null or puck.pickup_locked:
		_crease_idle_timer = 0.0
		return
	var puck_pos: Vector3 = puck.get_puck_position()
	var puck_xz: Vector2 = Vector2(puck_pos.x, puck_pos.z)
	if not CreaseRules.is_in_crease(puck_xz):
		_crease_idle_timer = 0.0
		return
	if puck.get_puck_velocity().length() > CREASE_STATIONARY_SPEED:
		_crease_idle_timer = 0.0
		return
	_crease_idle_timer += delta
	if _crease_idle_timer < CREASE_PUSHOUT_DELAY:
		return
	var outward: Vector2 = CreaseRules.outward_direction(puck_xz)
	puck.set_puck_velocity(Vector3(outward.x, 0.0, outward.y) * CREASE_PUSHOUT_SPEED)
	_crease_idle_timer = 0.0


# ── Local Prediction ──────────────────────────────────────────────────────────
func notify_local_pickup(local_skater: Skater) -> void:
	_local_carrier_skater = local_skater
	_predicting_trajectory = false
	_post_contact_timer = -1.0
	puck.set_client_prediction_mode(false)
	_state_buffer.clear()

func notify_local_release(direction: Vector3, power: float, rtt_ms: float, skater_vel: Vector3 = Vector3.ZERO) -> void:
	# PuckController (priority 1) runs after LocalController (priority 0), so the puck
	# hasn't been re-pinned to the current blade position yet this frame. Read blade
	# directly from the carrier so we start from the current-frame position, not last
	# frame's pin.
	var release_pos: Vector3 = puck.get_puck_position()
	if _local_carrier_skater != null:
		release_pos = _local_carrier_skater.get_blade_contact_global()
		release_pos.y = puck.ice_height
	_local_carrier_skater = null
	_predicting_trajectory = true
	_pending_local_release = true
	_shot_rtt_ms = rtt_ms
	puck.set_client_prediction_mode(true)
	puck.set_goal_line_clamp(true)
	var rtt_half: float = rtt_ms / 2000.0
	puck.set_puck_position(release_pos + (direction * power + skater_vel) * rtt_half)
	puck.apply_release_velocity(direction * power)
	_state_buffer.clear()

func notify_remote_carrier_changed(new_carrier_peer_id: int) -> void:
	_pending_local_release = false
	# Guard: don't kill our own trajectory prediction — we initiated the release
	# locally and are soft-reconciling via world state.
	if new_carrier_peer_id == -1 and _predicting_trajectory:
		return
	_predicting_trajectory = false
	_post_contact_timer = -1.0
	puck.set_client_prediction_mode(false)  # also clears _clamp_at_goal_line

# Called when the server forcibly ends a carry (e.g. goal scored).
# Does not start trajectory prediction — just drops back to interpolation.
func notify_local_puck_dropped() -> void:
	_local_carrier_skater = null
	_predicting_trajectory = false
	_pending_local_release = false
	_post_contact_timer = -1.0
	puck.set_client_prediction_mode(false)
	_state_buffer.clear()

func _apply_local_carrier_position(delta: float) -> void:
	# Smooth puck toward the blade contact point each tick. The lerp damps rapid
	# blade movements so the puck feels weighty during stickhandling rather than
	# teleporting instantly to the blade tip.
	var contact: Vector3 = _local_carrier_skater.get_blade_contact_global()
	contact.y = puck.ice_height
	puck.set_puck_position(puck.get_puck_position().lerp(contact, carry_smoothing_speed * delta))

# ── Server Signals ────────────────────────────────────────────────────────────
# Run on host only (connected in setup() when is_server). Each resolves the
# affected peer_id via the injected resolver and emits a signal upward — the
# three variants below differ only in how peer_id is sourced (resolve from
# the skater argument vs. read the cached carrier) and which signal fires.
# GameManager listens and does the player-registry / RPC work.
func _on_puck_picked_up(carrier: Skater) -> void:
	var peer_id: int = _resolve_peer_id(carrier)
	if peer_id == -1:
		return
	_carrier_peer_id = peer_id
	puck_picked_up_by.emit(peer_id)

func _on_puck_released() -> void:
	var peer_id: int = _carrier_peer_id
	_carrier_peer_id = -1
	if peer_id != -1:
		puck_released_by_carrier.emit(peer_id)

func _on_puck_stripped(ex_carrier: Skater) -> void:
	var peer_id: int = _resolve_peer_id(ex_carrier)
	if peer_id == -1:
		return
	puck_stripped_from.emit(peer_id)

func _resolve_peer_id(skater: Skater) -> int:
	if skater == null or not _peer_id_resolver.is_valid():
		return -1
	return _peer_id_resolver.call(skater)

func _on_client_puck_hit_goalie(_goalie: Goalie) -> void:
	if not _predicting_trajectory or _post_contact_timer >= 0.0:
		return
	# Hold prediction for RTT + one broadcast interval so the buffer fills with
	# post-bounce server data before we switch to interpolation. Ending prediction
	# immediately would blend toward pre-bounce buffer positions, making the puck
	# appear to slide backward into the goalie. Jolt keeps simulating the bounce
	# and server states are buffered (not reconciled) until the window expires.
	_pending_local_release = false
	_post_contact_timer = NetworkManager.get_latest_rtt_ms() / 1000.0 + 0.025

func _on_client_puck_hit_post() -> void:
	if not _predicting_trajectory or _post_contact_timer >= 0.0:
		return
	_pending_local_release = false
	_post_contact_timer = NetworkManager.get_latest_rtt_ms() / 1000.0 + 0.025

# ── State Serialization ───────────────────────────────────────────────────────
# Returns the typed network state object. Flattening to Array happens at the
# RPC boundary (GameManager.get_world_state), not here.
func get_state() -> PuckNetworkState:
	var state := PuckNetworkState.new()
	state.position = puck.get_puck_position()
	state.velocity = puck.get_puck_velocity()
	state.carrier_peer_id = _carrier_peer_id
	return state

func apply_state(state: PuckNetworkState, host_ts: float) -> void:
	if is_server:
		return
	if _local_carrier_skater != null:
		return  # Puck is pinned to local blade; interpolation isn't running
	if _predicting_trajectory:
		if state.carrier_peer_id != -1:
			if _pending_local_release:
				# Stale world state — host hasn't confirmed our release yet.
				# Keep predicting; wait for the authoritative carrier_changed RPC.
				return
			# A different player picked it up — end trajectory prediction.
			_predicting_trajectory = false
			_post_contact_timer = -1.0
			puck.set_client_prediction_mode(false)
		elif _post_contact_timer >= 0.0:
			# Post-contact suppression window: buffer states for interpolation but
			# skip reconcile. Pre-bounce server states would otherwise hard-snap the
			# puck backward into the goalie/boards. Jolt is running; buffer fills so
			# interpolation has post-bounce data when the window expires.
			if not _state_buffer.is_empty() and host_ts < _state_buffer.back().timestamp:
				return
			var post_contact_buf := BufferedPuckState.new()
			post_contact_buf.timestamp = host_ts
			post_contact_buf.state = state
			_state_buffer.append(post_contact_buf)
			if _state_buffer.size() > 30:
				_state_buffer.pop_front()
			_adapt_interpolation_delay()
			return
		else:
			if _pending_local_release:
				_pending_local_release = false
			var rtt_s: float = _shot_rtt_ms / 1000.0
			var latency_corrected := PuckNetworkState.new()
			latency_corrected.position = state.position + state.velocity * rtt_s
			latency_corrected.velocity = state.velocity
			# Both client and host Jolt start from the same position (same rtt_ms
			# used for both advances), so they run identically. Small errors are
			# RTT jitter — blending toward a noisy target creates visible snapback.
			# Only hard-snap on genuine physics divergence (wall/goalie bounce
			# that differed between client and host).
			var dist: float = puck.get_puck_position().distance_to(latency_corrected.position)
			if dist > trajectory_hard_snap_threshold:
				# Large divergence (wall/goalie bounce that differed): hard snap both.
				puck.set_puck_position(latency_corrected.position)
				puck.set_puck_velocity(latency_corrected.velocity)
				_state_buffer.clear()
			elif dist > trajectory_soft_blend_threshold:
				# Medium divergence: velocity-only blend, no position change.
				puck.set_puck_velocity(puck.get_puck_velocity().lerp(latency_corrected.velocity, 0.15))
			else:
				# Small divergence (RTT jitter): soft position blend + velocity blend.
				puck.set_puck_position(puck.get_puck_position().lerp(latency_corrected.position, position_correction_blend))
				puck.set_puck_velocity(puck.get_puck_velocity().lerp(latency_corrected.velocity, 0.15))
			return  # Don't buffer during prediction; interpolation isn't running
	if not _state_buffer.is_empty() and host_ts < _state_buffer.back().timestamp:
		return
	var buffered := BufferedPuckState.new()
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
	var interpolated := PuckNetworkState.new()
	if bracket.is_extrapolating:
		var dt: float = minf(bracket.extrapolation_dt, extrapolation_max_ms / 1000.0)
		var newest: PuckNetworkState = bracket.to_state
		# Decay velocity to approximate ice friction so the extrapolated position
		# matches Jolt's deceleration rather than linear dead-reckoning overshoot.
		var friction_vel: Vector3 = newest.velocity * maxf(0.0, 1.0 - extrapolation_friction * dt)
		interpolated.position = newest.position + friction_vel * dt
		interpolated.velocity = friction_vel
	else:
		var from_state: PuckNetworkState = bracket.from_state
		var to_state: PuckNetworkState = bracket.to_state
		interpolated.position = BufferedStateInterpolator.hermite(from_state.position, from_state.velocity,
				to_state.position, to_state.velocity, bracket.t, bracket.bracket_dt)
		interpolated.velocity = from_state.velocity.lerp(to_state.velocity, bracket.t)
	if prev_extrapolating and not is_extrapolating:
		_rejoin_blend_from_pos = puck.get_puck_position()
		_rejoin_blend_elapsed = 0.0
	if _rejoin_blend_elapsed >= 0.0:
		var ease_t: float = clampf(_rejoin_blend_elapsed / rejoin_blend_duration, 0.0, 1.0)
		interpolated.position = _rejoin_blend_from_pos.lerp(interpolated.position, ease_t)
		if ease_t >= 1.0:
			_rejoin_blend_elapsed = -1.0
	_apply_state_to_puck(interpolated)
	BufferedStateInterpolator.drop_stale(_state_buffer, render_time)

func _adapt_interpolation_delay() -> void:
	interpolation_delay = NetworkManager.adapt_interpolation_delay(interpolation_delay)

func _apply_state_to_puck(state: PuckNetworkState) -> void:
	# Position only — puck is frozen during interpolation, Jolt ignores velocity.
	puck.set_puck_position(state.position)
