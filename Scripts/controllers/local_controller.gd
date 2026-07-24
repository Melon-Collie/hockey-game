class_name LocalController
extends SkaterController

# The player's own controller on their own machine — reads their local Shot
# Power Sensitivity pref (calibrates flick-for-power to their mouse DPI).
func shot_power_sensitivity() -> float:
	return PlayerPrefs.shot_power_sensitivity

const _PhysicsConstants: GDScript = preload("res://Scripts/game/constants.gd")

# Carries the victim knockback impulse (its length is the hit magnitude, its
# horizontal heading the direction the local player was shoved — used to aim the
# camera impact kick).
signal hit_received(impulse: Vector3)

# Trajectory-based reconcile: thresholds compare the client's prediction *at
# host_timestamp T* against the server's authoritative state at T, looked up
# from _prediction_history. Prediction lead (the natural client-ahead-of-server
# offset, ~0.33-0.6m at skating speeds) is subtracted out by the timestamp
# match, so these thresholds gate only true non-determinism: body-check
# impulse mis-replay, contested collision resolution, etc.
@export var reconcile_position_threshold: float = 0.05
@export var reconcile_velocity_threshold: float = 0.3
# Upper-body rotation divergence past this triggers reconcile. Pose evolution
# is currently deterministic from inputs, but `_pose.upper_body_angle` persists
# across reconciles without a server snap, so any future non-determinism (or
# accumulated float drift) would silently desync the torso twist. Setting this
# above zero makes the threshold check structurally aware of the channel.
# 0.1 rad ≈ 5.7°: well above lerp-convergence noise, well below visible desync.
@export var reconcile_upper_body_rotation_threshold: float = 0.1

@onready var camera: GameCamera = null
var _gatherer: LocalInputGatherer = null
var _current_input: InputState = InputState.new()
var _input_history: Array[InputState] = []
# Per-tick prediction snapshots keyed by input.host_timestamp. Used to compute
# true divergence against server state at the same timestamp instead of
# comparing current client position (which is ahead by prediction lead).
var _prediction_history: Array[PredictedState] = []
const _PREDICTION_HISTORY_CAP: int = _PhysicsConstants.PHYSICS_TICK * 2  # ~2 s, matches the reconcile input cap
# Highest ack (last_processed_host_timestamp) a reconcile has already consumed.
# The host broadcasts world state every tick but only advances the ack when it
# pops a due input, so consecutive broadcasts often repeat the same ack. The
# first reconcile at ack T matches its prediction and then trims it away, so a
# repeated ack would find_at-miss, fall back to the live (prediction-lead-ahead)
# position, and fire a spurious snap. Gate on this so a stale ack is skipped —
# a genuine desync is still caught on the next *advanced* ack. Reset wherever
# _prediction_history is cleared (teleport / dead-puck lock).
var _last_reconcile_ack_ts: float = 0.0
# Set true in _physics_process on any tick that processed an input (normal play
# or FACEOFF_PREP), cleared on ticks that didn't (early-outs, dead-puck drain).
# The actual prediction snapshot is deferred to skater.post_move_integrated so it
# captures the post-move position — the same sub-step the host broadcasts — which
# removes the ~1-tick client-behind phase offset that drove the reconcile storm.
# The flag preserves the exact per-tick gating the inline snapshot calls had.
var _snapshot_pending: bool = false
var _team_id: int = -1  # set at setup; needed for client-side offside prediction
var last_reconcile_error: float = 0.0
var _claim_cooldown: float = 0.0
# Claim edge state: whether the blade was within pickup / poke range last tick,
# plus short anti-jitter floors. Each claim type fires on the rising edge of
# entering range so a fast/contested contact still claims at the instant the
# host's lag-comp rewind needs, instead of being missed between throttle windows.
# Pickup and poke carry separate cooldowns so neither blocks the other.
var _was_in_pickup_range: bool = false
var _pickup_claim_floor: float = 0.0
var _was_in_poke_range: bool = false
var _poke_cooldown: float = 0.0
var _poke_claim_floor: float = 0.0
# Body checks are no longer recorded-and-replayed as cached impulses. Reconcile
# replay instead RE-RESOLVES skater-vs-skater contact each replayed tick against
# where the host actually had the other skaters (sampled from their interpolation
# buffers via this provider) — so the replayed trajectory matches host authority
# rather than a stale impulse captured against the live (interpolated) positions.
# Provider: func(exclude_skater: Skater, host_ts: float) -> Array of
# {skater, position, velocity, hit}. Set by GameManager (_sample_historical_others).
var _historical_others_provider: Callable = Callable()
# Reused across pairs during replay re-resolution — no per-pair allocation.
var _replay_collision_result: SkaterCollisionRules.Result = SkaterCollisionRules.Result.new()
const _BLADE_JUMP_THRESHOLD: float = 0.05
const _CLAIM_COOLDOWN_S: float = 0.3  # sustained re-fire gap while a claim target stays in range
const _PICKUP_CLAIM_FLOOR_S: float = 0.05  # min gap between pickup claims; caps rising-edge jitter spam
const _POKE_CLAIM_FLOOR_S: float = 0.05    # same for poke / stick-lift claims

const _RECONCILE_VISUAL_ALPHA: float = 0.20  # per-tick decay factor at the nominal 120 Hz tick; applied frame-rate-independently (see _physics_process)

func setup(assigned_skater: Skater, assigned_puck: Puck, game_state: Node) -> void:
	camera = $Camera3D
	super.setup(assigned_skater, assigned_puck, game_state)
	show_one_timer_indicator = true
	_gatherer = LocalInputGatherer.new(camera)
	add_child(_gatherer)
	camera.skater = assigned_skater
	camera.puck = assigned_puck
	camera.local_controller = self
	# Drives the camera shake / impact feedback. No longer records the impulse for
	# replay — reconcile re-resolves contact from buffered history instead (see
	# _historical_others_provider), so live prediction stays uncoupled from replay.
	skater.body_check_impulse_applied.connect(
		func(impulse: Vector3) -> void:
			hit_received.emit(impulse))
	# Capture the reconcile prediction snapshot AFTER the body has integrated this
	# tick (move_and_slide + collisions + clamp), matching the post-move sub-step
	# the host samples for its broadcast. _snapshot_pending gates it to exactly the
	# ticks the old inline calls fired on. Fires at Skater priority 0, after this
	# controller's priority -1 pass has already set _current_input and the flag.
	skater.post_move_integrated.connect(func() -> void:
		if _snapshot_pending:
			_snapshot_pending = false
			_append_prediction_snapshot())

# Called after setup() to provide the local player's team — needed for
# client-side offside prediction. Separate from setup() because GDScript
# requires overrides to match the parent signature exactly.
func set_local_team_id(team_id: int) -> void:
	_team_id = team_id
	camera.set_local_team_id(team_id)
	_gatherer.set_local_team_id(team_id)


func set_historical_others_provider(provider: Callable) -> void:
	_historical_others_provider = provider

func set_goal_context(goal_0: HockeyGoal, goal_1: HockeyGoal, carrier_team_getter: Callable) -> void:
	camera.set_goal_context(goal_0, goal_1, carrier_team_getter)

# Forces the player-locked camera framing regardless of the user's camera-mode
# pref. Used by the tutorial for the puckless movement steps so the camera sits
# centered on the player instead of zooming out toward the stashed puck.
func set_camera_force_locked(locked: bool) -> void:
	if camera != null:
		camera.force_locked = locked

func get_current_input() -> InputState:
	return _current_input

func get_input_batch(frames: int = 12) -> Array[InputState]:
	var start: int = maxi(_input_history.size() - frames, 0)
	return _input_history.slice(start)

# Used by WorldStateCodec during goal replay to reposition the local skater the
# same way RemoteController does, bypassing reconcile which is a no-op during
# dead-puck phases anyway. Mirrors RemoteController._apply_state_to_skater.
func apply_network_state(state: SkaterNetworkState, _host_ts: float) -> void:
	if skater == null:
		return
	skater.global_position = state.position
	skater.velocity = state.velocity
	skater.set_facing(state.facing)
	skater.set_upper_body_rotation(state.upper_body_rotation_y)
	skater.set_top_hand_position(state.top_hand_position)
	# Re-derive lean from velocity + hand reach so the upper body leans before
	# the blade is placed (lean isn't transmitted; receivers re-derive).
	_pose.snap_lean_to_state()
	skater.set_blade_position(state.blade_position)
	# Arm/stick meshes derive from the markers once per rendered frame in
	# Skater._process.


func teleport_to(pos: Vector3, facing: Vector2 = Vector2.ZERO) -> void:
	super.teleport_to(pos, facing)
	_input_history.clear()
	_prediction_history.clear()
	_last_reconcile_ack_ts = 0.0
	if skater != null:
		skater.visual_offset = Vector3.ZERO

func _physics_process(delta: float) -> void:
	if skater == null or puck == null or _gatherer == null:
		return
	# Cleared every tick; set true below only on ticks that process an input, so
	# the deferred post-move snapshot fires iff the old inline call would have.
	_snapshot_pending = false
	if NetworkManager.is_replay_mode():
		return
	if not skater.visual_offset.is_zero_approx():
		# Per-tick decay: (1 - alpha) is the factor at the nominal 120 Hz tick.
		# Godot reports a CONSTANT physics delta (1/120) even when the sim
		# dilates, so the exponent is always 1.0 today — the pow form only
		# matters if this decay ever moves to a variable-delta context.
		var decay: float = pow(1.0 - _RECONCILE_VISUAL_ALPHA, delta * float(Constants.PHYSICS_TICK))
		var new_offset: Vector3 = skater.visual_offset * decay
		skater.visual_offset = new_offset if new_offset.length_squared() > 0.000001 else Vector3.ZERO
	if _game_state.is_movement_locked():
		# Faceoff / intro skate-in: while an approach is active the body glides to
		# the dot (see SkaterController.begin_approach) instead of freezing. On
		# arrival tick_faceoff_approach returns false and we fall through to the
		# normal prep freeze so the player can pre-aim the draw.
		if tick_faceoff_approach(delta):
			return
		skater.velocity = Vector3.ZERO
		if _game_state.allows_blade_aim_during_lock() and _gatherer != null:
			# FACEOFF_PREP: keep the stick alive so centers can pre-angle the draw
			# during the countdown. We neutralize move_vector and the shot flags
			# so the input that flows to the host (and the same frames in our
			# reconcile history) can't smuggle locomotion or a shot trigger into
			# the live phase the instant the freeze lifts. Blade IK is the only
			# side effect — _process_input and the state machine stay skipped.
			var prep_input: InputState = _gatherer.gather()
			prep_input.delta = delta
			if NetworkManager.is_clock_ready():
				prep_input.host_timestamp = NetworkManager.estimated_input_stamp_time()
			prep_input.move_vector = Vector2.ZERO
			prep_input.shoot_pressed = false
			prep_input.shoot_held = false
			prep_input.slap_pressed = false
			prep_input.slap_held = false
			prep_input.brake = false
			prep_input.sprint_held = false
			# elevation_level passes through untouched — it's a mode, not an
			# action, so the faceoff freeze shouldn't flatten the chosen loft.
			prep_input.block_held = false
			prep_input.stick_lift_held = false
			_current_input = prep_input
			_input_history.append(_current_input)
			var prep_rtt_cap: int = clampi(int(NetworkManager.get_latest_rtt_ms() / 1000.0 * float(Constants.PHYSICS_TICK)) * 2, Constants.PHYSICS_TICK / 5, Constants.PHYSICS_TICK * 2)
			if _input_history.size() > prep_rtt_cap:
				_input_history.pop_front()
			apply_blade_aim_only(_current_input, delta)
			# Snapshot the frozen prep frame too, so a broadcast that acks a
			# prep-phase input after the lock lifts matches in find_at instead of
			# falling back to the live position (a spurious post-faceoff reconcile).
			# Deferred to post-move like the live path (position is frozen here, so
			# pre/post-move are identical, but the flag keeps one capture site).
			_snapshot_pending = true
		else:
			# Dead-puck phase with sticks frozen too — drain history so reconcile
			# can't replay stale inputs once the phase lifts.
			_input_history.clear()
			_prediction_history.clear()
			_last_reconcile_ack_ts = 0.0
		return
	# When input is blocked (menu open) the gatherer returns a neutral
	# InputState — zero movement, no held buttons. We still run the full
	# pipeline below so the skater decelerates naturally, the state machine
	# transitions cleanly, and host + client process identical inputs to
	# stay in reconcile sync. No carve-out needed here.

	# Predict offsides locally for instant ghost feedback
	_predict_offside()
	var gathered: InputState = _gatherer.gather()
	gathered.delta = delta
	if NetworkManager.is_clock_ready():
		gathered.host_timestamp = NetworkManager.estimated_input_stamp_time()
	var input: InputState = gathered
	_current_input = input
	_input_history.append(_current_input)
	# Cap history size to prevent unbounded growth
	# Cap scales with RTT so sustained high-loss can't grow the buffer unboundedly:
	# 2× RTT worth of frames (min 0.2 s, max 2 s of ticks) covers the in-flight window.
	var rtt_cap: int = clampi(int(NetworkManager.get_latest_rtt_ms() / 1000.0 * float(Constants.PHYSICS_TICK)) * 2, Constants.PHYSICS_TICK / 5, Constants.PHYSICS_TICK * 2)
	if _input_history.size() > rtt_cap:
		_input_history.pop_front()
	_process_input(_current_input, _current_input.delta)
	# Snapshot is deferred to skater.post_move_integrated (post move_and_slide) so
	# it captures the same post-integration position the host broadcasts.
	_snapshot_pending = true
	skater.current_shot_state = _sm.get_state() as int
	_update_one_timer_indicator()
	_claim_cooldown = maxf(_claim_cooldown - delta, 0.0)
	_pickup_claim_floor = maxf(_pickup_claim_floor - delta, 0.0)
	_poke_cooldown = maxf(_poke_cooldown - delta, 0.0)
	_poke_claim_floor = maxf(_poke_claim_floor - delta, 0.0)
	if not _is_host and NetworkManager.is_clock_ready() and not skater.is_ghost and not puck.pickup_locked and _sm.get_state() != State.SHOT_BLOCKING:
		var blade_pos_for_claim: Vector3 = skater.get_blade_contact_global()
		# Branch on the CLIENT-side carrier view (PuckController, driven by the
		# carrier events) — puck.carrier is host-only and never set on clients,
		# so gating on it made this always read "loose": the poke/stick-lift
		# claim branch was unreachable and the pickup branch re-claimed a
		# carried puck (pinned ~0 m from the blade) for entire carries.
		var pctrl: PuckController = GameManager.puck_controller
		var view_carrier_pid: int = pctrl.get_client_carrier_peer_id() if pctrl != null else -1
		var view_carrier: Skater = pctrl.get_client_carrier_skater() if pctrl != null else null
		if view_carrier_pid == -1:
			# Loose puck — speculative pickup claim. Host validates with rewind.
			# Edge-triggered: fire the instant the puck enters blade range so a fast
			# or contested puck brushing the blade claims at the contact moment (the
			# timestamp the host's lag-comp rewind needs) instead of being missed
			# between throttle windows. While it stays in range, re-fire on the
			# _CLAIM_COOLDOWN_S throttle to cover a sustained hover whose first claim
			# the host rejected. _PICKUP_CLAIM_FLOOR_S caps the rate so boundary
			# jitter can't spam claims.
			var dist: float = puck.global_position.distance_to(blade_pos_for_claim)
			var in_range: bool = dist <= PuckController.PICKUP_RADIUS
			var rising_edge: bool = in_range and not _was_in_pickup_range
			# A deliberate deflect (holding LMB without the puck) is NOT a pickup —
			# suppress the speculative claim + optimistic pin so we don't predict a
			# catch the host will resolve as a deflect (which would roll back). The
			# deflect itself comes back authoritatively through the puck sync. A puckless
			# one-timer wind-up (SLAPPER_CHARGE_WITHOUT_PUCK) is suppressed for the same
			# reason: it's a redirect, not a corral. Front-running it would pin the puck
			# to the raised wind-up blade (snapping it overhead for a frame) until the
			# host confirm re-pinned it to the ice zone — the host catches the feed and
			# it arrives through the puck sync.
			if in_range and not skater.deflect_intent and _sm.get_state() != State.SLAPPER_CHARGE_WITHOUT_PUCK and _pickup_claim_floor <= 0.0 and (rising_edge or _claim_cooldown <= 0.0):
				_pickup_claim_floor = _PICKUP_CLAIM_FLOOR_S
				_claim_cooldown = _CLAIM_COOLDOWN_S
				# Report the ADAPTED interp delay (get_interpolation_delay) — the value
				# that actually positioned the rendered puck this frame — not the target.
				# remote_view_time on the host subtracts exactly this to reproduce the
				# puck we reached for; target can lead adapted by tens of ms mid-jitter
				# (adapt clamps +10/-1.5 ms per packet), which is exactly when a
				# stale-view rewind makes a legit grab miss. Poke / stick-lift / hit
				# claims report the same adapted delay for the same reason.
				# Send the blade geometry WE reached with (client-authoritative aim):
				# curr + one-tick-prior blade for the host's swept test, plus the
				# top-hand grip for the reception face-normal. The host reach-clamps
				# them to our server-authoritative body. blade_pos_for_claim is this
				# frame's blade contact; get_prev_blade_contact_global is last tick's.
				NetworkManager.send_pickup_claim(
					NetworkManager.estimated_host_time(),
					NetworkManager.get_interpolation_delay() * 1000.0,
					blade_pos_for_claim, skater.get_prev_blade_contact_global(),
					skater.upper_body_to_global(skater.get_top_hand_position()))
				# Optimistic visual-only attach for uncontested pickups: pins the
				# puck to our blade immediately so the grab feels instant, rolling
				# back if the host doesn't confirm. Idempotent + self-gating, so
				# calling it on every claim (rising edge or throttle re-fire) is safe.
				if GameManager.puck_controller != null:
					GameManager.puck_controller.try_provisional_pickup(skater)
			_was_in_pickup_range = in_range
			_was_in_poke_range = false
		elif view_carrier != null and view_carrier != skater:
			_was_in_pickup_range = false
			# Opposing carrier — speculative poke OR stick-lift claim, edge-triggered
			# on the same rationale as pickup: fire the instant the blade enters poke
			# range / hooks under the shaft, so a fast sweep isn't missed between the
			# 300ms throttle windows; re-fire on the throttle while it stays in range.
			# Own timers (not the pickup cooldown) so the two actions don't block each
			# other. Skip same-team carriers — the host would reject. Carrier peer_id
			# and skater come from PuckController's client carrier view (carrier-event
			# managed, never world state), so the expected-carrier check is safe.
			var carrier_team: int = view_carrier.get_team_id()
			var carrier_pid: int = view_carrier_pid
			var in_poke_range: bool = false
			var is_lift: bool = false
			if carrier_team != _team_id and carrier_team != -1:
				if skater.blade_up:
					# Lifted blade — hook under the carrier's shaft for a stick lift.
					is_lift = true
					var c_hand: Vector3 = view_carrier.upper_body_to_global(view_carrier.get_top_hand_position())
					var c_blade: Vector3 = view_carrier.get_blade_contact_global()
					in_poke_range = PuckInteractionRules.check_blade_under_stick(
							blade_pos_for_claim, c_hand, c_blade,
							PuckController.STICK_LIFT_RADIUS, PuckController.STICK_LIFT_UNDER_MARGIN)
				else:
					in_poke_range = puck.global_position.distance_to(blade_pos_for_claim) <= PuckController.POKE_RADIUS
			var rising_poke_edge: bool = in_poke_range and not _was_in_poke_range
			if in_poke_range and _poke_claim_floor <= 0.0 and (rising_poke_edge or _poke_cooldown <= 0.0):
				_poke_claim_floor = _POKE_CLAIM_FLOOR_S
				_poke_cooldown = _CLAIM_COOLDOWN_S
				if is_lift:
					# Stick-lift is an instantaneous point test — only the current blade
					# (client aim); the victim's shaft stays host-reconstructed.
					NetworkManager.send_stick_lift_claim(
						NetworkManager.estimated_host_time(),
						NetworkManager.get_interpolation_delay() * 1000.0,
						carrier_pid, blade_pos_for_claim)
				else:
					# Poke is a swept test — curr + one-tick-prior blade (client aim).
					NetworkManager.send_poke_claim(
						NetworkManager.estimated_host_time(),
						NetworkManager.get_interpolation_delay() * 1000.0,
						carrier_pid, blade_pos_for_claim, skater.get_prev_blade_contact_global())
			_was_in_poke_range = in_poke_range
		else:
			# We carry the puck (or the carrier's skater isn't spawned on this
			# client — no geometry to aim a claim at). Reset both edges so a
			# future loose / contest contact registers as a clean rising edge.
			_was_in_pickup_range = false
			_was_in_poke_range = false

func _append_prediction_snapshot() -> void:
	# Per-input prediction snapshot keyed by host_timestamp so reconcile can
	# compare predicted-vs-server at the same instant (subtracting prediction lead
	# out of the divergence). Appended on every gathered input — including frozen
	# FACEOFF_PREP frames (position locked, velocity zero) — so a broadcast that
	# acks a prep-phase input after the lock lifts finds a match instead of falling
	# back to the live position and firing a spurious reconcile on the first touch.
	var snap := PredictedState.new()
	snap.host_timestamp = _current_input.host_timestamp
	snap.position = skater.global_position
	snap.velocity = skater.velocity
	snap.facing = _pose.facing
	snap.shot_state = _sm.get_state() as int
	snap.upper_body_rotation_y = _pose.upper_body_angle
	_prediction_history.append(snap)
	if _prediction_history.size() > _PREDICTION_HISTORY_CAP:
		_prediction_history.pop_front()


func reconcile(server_state: SkaterNetworkState) -> void:
	var pre_reconcile_blade: Vector3 = skater.get_blade_contact_global()
	var pre_reconcile_visual_pos: Vector3 = skater.global_position + skater.visual_offset
	# Apply authoritative ghost state. Server ghost=true always wins. Server
	# ghost=false is held back if the client is still locally predicting offside —
	# the broadcast was encoded before the host computed the transition and is stale.
	if server_state.is_ghost:
		skater.set_ghost(true)
	elif skater.is_ghost:
		# has_puck, not the host-only puck.carrier (see _predict_offside) — with
		# the dead read this hold-back also REFUSED the server's authoritative
		# un-ghost while the carrier's own geometry still looked offside.
		var puck_z: float = puck.global_position.z if puck != null else 0.0
		if not InfractionRules.is_offside(skater.global_position.z, _team_id, puck_z, has_puck):
			skater.set_ghost(false)
	if _game_state.is_movement_locked():
		# Dead-puck phase: don't reconcile. on_faceoff_positions is the reliable
		# source of truth for teleport positions; world-state snapshots may lag behind
		# and would fight it if applied here.
		return
	# Front-trim the acked prefix of each history. All three arrays are
	# timestamp-sorted (appended chronologically), so everything at or before
	# last_processed_host_timestamp sits at the front. The previous filter()
	# rebuilds allocated a fresh array + ran a lambda per element on every
	# broadcast (120 Hz), even in the healthy no-reconcile case.
	# The trim boundary carries TS_MATCH_EPSILON slack: the ack arrives
	# through the 0.1ms wire grid while local stamps are full-precision f64,
	# so without it the exact acked input could survive the trim (grid value
	# a hair below the local stamp) and be double-applied on replay. Epsilon
	# (1ms) is far below the 4.17ms input spacing, so it can never trim an
	# unacked input. find_at below uses the pure ack (its own epsilon match
	# handles the grid error symmetrically).
	var ack_ts: float = server_state.last_processed_host_timestamp
	# Stale-ack gate: the host broadcasts every tick but only advances the ack when
	# it pops a due input, so consecutive broadcasts routinely repeat the same ack.
	# The first reconcile at ack T matches its prediction and then trims it away
	# (below), so a repeated ack would find_at-miss, fall back to the live position
	# (which leads the server by prediction lead), and fire a spurious snap — the
	# false corrections that dominate reconcile churn on a clean connection. There
	# is no new confirmed input to compare against, so skip: a real desync is still
	# caught on the next advanced ack, at the normal cadence. Ghost state above is
	# authoritative every broadcast and has already been applied.
	if not ReconciliationRules.ack_is_new(ack_ts, _last_reconcile_ack_ts, PredictedState.TS_MATCH_EPSILON):
		return
	_last_reconcile_ack_ts = ack_ts
	var trim_ts: float = ack_ts + PredictedState.TS_MATCH_EPSILON
	while not _input_history.is_empty() and _input_history[0].host_timestamp <= trim_ts:
		_input_history.pop_front()
	# Trajectory-based threshold check: compare what we predicted for the input
	# at last_processed_host_timestamp against what the server says happened at
	# that same instant. Falls back to the live position when no match is found
	# (history capped, post-teleport, dead-puck gap, session warmup).
	var predicted: PredictedState = PredictedState.find_at(_prediction_history, ack_ts)
	NetworkTelemetry.record_reconcile_match(predicted != null)
	# On a miss, attribute WHERE the ack fell relative to the kept history — a miss
	# forces the prediction-lead fallback below (divergence_position = live), which
	# trips a spurious position snap, so the miss cause is the residual-churn signal.
	if predicted == null:
		var reason: int = ReconciliationRules.classify_match_miss(
				_prediction_history.is_empty(),
				_prediction_history[0].host_timestamp if not _prediction_history.is_empty() else 0.0,
				_prediction_history[-1].host_timestamp if not _prediction_history.is_empty() else 0.0,
				ack_ts, PredictedState.TS_MATCH_EPSILON)
		var gap_ms: float = 0.0
		if reason == ReconciliationRules.MatchMiss.OLDER:
			gap_ms = (_prediction_history[0].host_timestamp - ack_ts) * 1000.0
		elif reason == ReconciliationRules.MatchMiss.NEWER:
			gap_ms = (ack_ts - _prediction_history[-1].host_timestamp) * 1000.0
		NetworkTelemetry.record_reconcile_miss(reason, gap_ms)
	var divergence_position: Vector3 = predicted.position if predicted != null else skater.global_position
	var divergence_velocity: Vector3 = predicted.velocity if predicted != null else skater.velocity
	var divergence_upper_body: float = predicted.upper_body_rotation_y if predicted != null else _pose.upper_body_angle
	# Trim confirmed predictions — future reconciles only ever look at strictly
	# later timestamps.
	while not _prediction_history.is_empty() and _prediction_history[0].host_timestamp <= trim_ts:
		_prediction_history.pop_front()
	if not ReconciliationRules.skater_needs_reconcile(
			divergence_position, divergence_velocity,
			server_state.position, server_state.velocity,
			reconcile_position_threshold, reconcile_velocity_threshold,
			divergence_upper_body, server_state.upper_body_rotation_y,
			reconcile_upper_body_rotation_threshold):
		return
	# Suppress reconcile jitter while pressing against a boundary. Analytic
	# containment (boards / net / goalie) vs. server-physics noise repeatedly sets
	# small visual_offsets that compound into visible oscillation. is_touching_boundary
	# is the analytic stand-in for the old move_and_slide is_on_wall() flag — it's
	# raised by the clamps whenever they repositioned the body last tick.
	# Errors above 5 cm are real desync and still fire through.
	if skater.is_touching_boundary() and skater.global_position.distance_to(server_state.position) < 0.05:
		return
	# Attribute which channel tripped the snap (diagnostic): at rest the position
	# and velocity channels are ~zero, so a non-zero "rot" count isolates
	# pose/aim (upper-body) divergence firing reconciles, vs a position desync.
	NetworkTelemetry.record_reconcile_cause(
		divergence_position.distance_to(server_state.position) >= reconcile_position_threshold,
		divergence_velocity.distance_to(server_state.velocity) >= reconcile_velocity_threshold,
		reconcile_upper_body_rotation_threshold > 0.0 and absf(angle_difference(
				divergence_upper_body, server_state.upper_body_rotation_y)) >= reconcile_upper_body_rotation_threshold)
	# Diagnostic: express the same-timestamp position offset in units of one tick
	# of travel, signed +/- by whether the prediction leads or lags the server
	# along the velocity. ~+1.0 = predicted is one move_and_slide AHEAD of the
	# server; ~-1.0 = one behind. Isolates a capture/integration phase mismatch
	# (vs random non-determinism, which wouldn't sit at a clean +/-1).
	if predicted != null:
		var off_vec: Vector3 = predicted.position - server_state.position
		var spd: float = server_state.velocity.length()
		if spd > 0.05:
			var one_tick: float = spd / float(Constants.PHYSICS_TICK)
			NetworkTelemetry.record_pos_offset_ticks(
					(off_vec.length() / one_tick) * signf(off_vec.dot(server_state.velocity)))
	# Record how far the client has predicted ahead of the server's last known position.
	# This grows naturally with RTT and speed — it is not a non-determinism signal.
	var pre_replay_divergence: float = skater.global_position.distance_to(server_state.position)
	NetworkTelemetry.record_prediction_divergence(pre_replay_divergence)
	# Save shot/state-machine state — replay can transition through shoot states
	# (WRISTER_AIM → FOLLOW_THROUGH → SKATING) and leave _state wrong. Restore so
	# the next _process_input runs the correct handler and blade doesn't teleport.
	var pre_state: State = _sm.get_state()
	var pre_follow_through_timer: float = _sm.follow_through_timer
	var pre_follow_through_is_slapper: bool = _sm.follow_through_is_slapper
	var pre_follow_through_total: float = _sm.follow_through_duration_total
	var pre_follow_through_power: float = _sm.follow_through_power
	# shot_dir feeds the follow-through pose (blade sweep target + torso
	# uncoil). Replay can overwrite it with a re-derived direction, or zero it
	# outright when the replayed window walks the timer through
	# _transition_to_skating / re-enters a slapper charge — without restore the
	# rest of the live follow-through animates toward Vector3.ZERO and the
	# blade pops off the shot line.
	var pre_shot_dir: Vector3 = _sm.shot_dir
	var pre_one_timer_window_timer: float = _aiming.one_timer_window_timer
	# slapper_charge_timer ticks inside _update_slapper_charge during replay; without
	# save/restore each reconcile re-ticks the unconfirmed inputs and the timer
	# inflates O(N) per broadcast, popping the blade above slapper_wind_up_height.
	var pre_slapper_charge_timer: float = _aiming.slapper_charge_timer
	# Same shape of problem as the slapper timer: tick_wrister_charge evolves the
	# swing rotation and the cursor-speed EMA inside _update_wrister_charge during
	# replay, so without save/restore each reconcile re-runs the unconfirmed
	# window's swing and perturbs the live power signal. Save the live values and
	# restore after replay; live tick state is the truth, replay's pass through
	# the same inputs is discarded.
	var pre_charge_swing_rotation: float = _aiming.swing_rotation
	var pre_charge_cursor_speed: float = _aiming.cursor_speed_ema
	var pre_charge_stroke_travel: float = _aiming.stroke_travel
	var pre_charge_prev_intent_pos: Vector3 = _aiming.prev_intent_pos
	var pre_charge_prev_blade_pos: Vector3 = _aiming.prev_blade_pos_rel_skater
	var pre_charge_prev_blade_dir: Vector3 = _aiming.prev_blade_dir
	# Pinned at stroke start; set once on the WRISTER_AIM entry edge. Restored so a
	# replay that re-crosses that edge can't re-anchor the live origin.
	var pre_charge_origin_world: Vector3 = _aiming.wrister_origin_world
	# shot_charge is re-derived from the (restored) charge timers / swing state on
	# every live tick, but _update_slapper_charge / _update_wrister_charge also
	# rewrite it during replay from the unconfirmed window. Save/restore it with its
	# source state so it isn't left at a replay-derived value until the next live
	# tick recomputes it — otherwise the local player's stick-flex pose reads a
	# stale charge for one frame after a reconcile (cosmetic; completes the set).
	var pre_shot_charge: float = skater.shot_charge
	skater.global_position = server_state.position
	skater.velocity = server_state.velocity
	# Stamina + lockout are deterministic from inputs, exactly like velocity:
	# snap to the server baseline, then the replay loop below re-derives them
	# forward through the unacked inputs (do NOT save/restore them — that's for
	# fields replay must not advance, like the charge timers).
	stamina = server_state.stamina
	_sprint_locked = server_state.sprint_locked
	# Body-check stagger is deterministic from the host baseline + tick decay,
	# exactly like stamina: snap to the server value, then the replay loop's
	# per-tick decay (in _apply_movement) re-derives it forward.
	stagger_timer = server_state.stagger_timer
	# Knockdown rides the same rail — snap to the host value, replay re-derives the
	# per-tick decay + lock. is_knocked_down follows so the replay's _apply_movement
	# gates correctly from the first replayed tick.
	knockdown_timer = server_state.knockdown_timer
	skater.is_knocked_down = knockdown_timer > 0.0
	# Snap facing for replay accuracy — facing drives move_and_slide direction,
	# so the replay must start from the server's facing to reproduce the trajectory.
	_pose.facing = server_state.facing
	skater.set_facing(_pose.facing)
	# IK lock side is relative to the old facing; reset so the gate re-evaluates
	# cleanly from the snapped facing on the first post-reconcile frame.
	_pose.ik_locked_side = 0
	_pose.lower_body_lag = 0.0
	skater.set_lower_body_lag(0.0)
	# Snap upper-body rotation to server value. Pose evolution is deterministic
	# from inputs, but _pose.upper_body_angle is the one persistent pose field
	# that carries across reconciles without a per-cycle resync — anchoring it
	# to the server bounds drift to zero per cycle instead of accumulating.
	_pose.upper_body_angle = server_state.upper_body_rotation_y
	# Drop the IK blade smoother's baseline so it re-seeds deterministically from
	# the first replayed input's ROM-clamped target — the live smoothed value
	# would otherwise bias the replay's first tick.
	_ik.reset_blade_smoothing()
	# Replay under the ACK-TIME baseline: the host evolved these same inputs
	# starting from server_state.shot_state, so seed the state machine there
	# rather than replaying under the LIVE state (which post-dates the whole
	# unacked window — a window spanning a shot transition otherwise replays
	# its pre-release ticks in the wrong movement branch: aim facing-freeze /
	# follow-through damping vs skating). State transitions re-fire from the
	# replayed input edges with is_replaying suppressing their side effects;
	# the live state is restored below and server authority is then applied
	# through the in-flight guards, exactly as before.
	_sm.set_state(server_state.shot_state as SkaterStateMachine.State)
	is_replaying = true
	# Walk the (already ack-trimmed, chronological) prediction history alongside
	# the replayed inputs so each entry can be RE-RECORDED from the corrected
	# trajectory below — see the re-record comment inside the loop.
	var replay_hist_i: int = 0
	for input in _input_history:
		_process_input(input, input.delta)
		skater.global_position += skater.velocity * input.delta
		# Re-resolve skater-vs-skater body checks against where the host actually had
		# the other skaters at this input's timestamp (from their interpolation
		# buffers). Runs AFTER integration to mirror the host exactly: the live resolver
		# runs after move_and_slide, so it (a) evaluates contact geometry at the
		# POST-integration self position — the same instant host_ts=T samples the others
		# at and the authoritative snapshot captures — and (b) applies dvel after the
		# move, landing it on the next tick. Running before integration (the old
		# recorded-impulse slot) offset the geometry ~one tick of travel and mis-phased
		# dvel; a fixed recorded vector didn't care, but position-based re-resolution
		# does. sep still lands before the clamps below. Replaces the impulse bridge.
		_replay_resolve_body_checks(input.host_timestamp, input.hit_held)
		# Clamp to the rink boundary after every replay step — the same analytic
		# projection the live tick applies (boards are off the skater's physics
		# mask). Without this, a board interaction that differed by even one frame
		# between client and host compounds into a divergence feedback loop that
		# triggers repeated reconciles.
		skater.clamp_body_to_rink()
		# Same for the goal net (also off the skater physics mask) — keep the replay
		# in lockstep with the live tick so a net brush can't compound into a reconcile
		# loop.
		skater.clamp_body_to_net()
		# And the goalie footprint — the live tick blocks the skater out of the goalie
		# analytically now (move_and_slide is gone), so the replay must too or a goalie
		# brush compounds into a reconcile loop.
		skater.clamp_body_to_goalies()
		# Re-record this input's prediction from the corrected trajectory. The
		# stale pre-correction snapshots were made on the trajectory the replay
		# just abandoned, so without this every subsequent advanced ack in the
		# unacked span re-trips the threshold against them and re-runs a full
		# reconcile (~an RTT window of redundant corrections per real
		# divergence). The live body follows this same replayed trajectory, so
		# the re-recorded history stays honest for later comparisons. Matched
		# by timestamp (epsilon-tolerant) rather than assumed 1:1 — the live
		# capture is deferred to post_move_integrated and can skip a tick.
		while replay_hist_i < _prediction_history.size() \
				and _prediction_history[replay_hist_i].host_timestamp \
					< input.host_timestamp - PredictedState.TS_MATCH_EPSILON:
			replay_hist_i += 1
		if replay_hist_i < _prediction_history.size() \
				and absf(_prediction_history[replay_hist_i].host_timestamp - input.host_timestamp) \
					<= PredictedState.TS_MATCH_EPSILON:
			var replay_snap: PredictedState = _prediction_history[replay_hist_i]
			replay_snap.position = skater.global_position
			replay_snap.velocity = skater.velocity
			replay_snap.facing = _pose.facing
			replay_snap.shot_state = _sm.get_state() as int
			replay_snap.upper_body_rotation_y = _pose.upper_body_angle
			replay_snap.was_replay_rerecorded = true
			replay_hist_i += 1
	is_replaying = false
	# Restore shot-state fields that replay must not transition past.
	_sm.set_state(pre_state)
	_sm.follow_through_timer = pre_follow_through_timer
	_sm.follow_through_is_slapper = pre_follow_through_is_slapper
	_sm.follow_through_duration_total = pre_follow_through_total
	_sm.follow_through_power = pre_follow_through_power
	_sm.shot_dir = pre_shot_dir
	_aiming.one_timer_window_timer = pre_one_timer_window_timer
	_aiming.slapper_charge_timer = pre_slapper_charge_timer
	_aiming.swing_rotation = pre_charge_swing_rotation
	_aiming.cursor_speed_ema = pre_charge_cursor_speed
	_aiming.stroke_travel = pre_charge_stroke_travel
	_aiming.prev_intent_pos = pre_charge_prev_intent_pos
	_aiming.prev_blade_pos_rel_skater = pre_charge_prev_blade_pos
	_aiming.prev_blade_dir = pre_charge_prev_blade_dir
	_aiming.wrister_origin_world = pre_charge_origin_world
	skater.shot_charge = pre_shot_charge
	# Server authority on shot state — but never revert past a release transition.
	# If the client is in FOLLOW_THROUGH and the server is still in an aim state,
	# the host just hasn't processed the release input yet; the reliable RPC already
	# fired it. Reverting would loop the follow-through animation every reconcile cycle.
	var apply_server_shot_state: bool = server_state.shot_state != pre_state
	if apply_server_shot_state and pre_state == SkaterStateMachine.State.FOLLOW_THROUGH:
		var server_still_aiming: bool = \
				server_state.shot_state == SkaterStateMachine.State.WRISTER_AIM or \
				server_state.shot_state == SkaterStateMachine.State.SLAPPER_CHARGE_WITH_PUCK
		if server_still_aiming:
			apply_server_shot_state = false
	# Symmetric guard for the reverse direction: don't revert from an aiming state
	# back to skating when we have the puck. The server hasn't processed the shoot
	# input yet (it's still in-flight or queued); letting the server override here
	# ejects the client from WRISTER_AIM every reconcile cycle, so shoot_pressed
	# never re-fires and the release has no puck to dispatch.
	if apply_server_shot_state and has_puck:
		var client_aiming: bool = \
				pre_state == SkaterStateMachine.State.WRISTER_AIM or \
				pre_state == SkaterStateMachine.State.SLAPPER_CHARGE_WITH_PUCK
		var server_skating: bool = \
				server_state.shot_state == SkaterStateMachine.State.SKATING_WITH_PUCK or \
				server_state.shot_state == SkaterStateMachine.State.SKATING_WITHOUT_PUCK
		if client_aiming and server_skating:
			apply_server_shot_state = false
	# Same protection for the puckless one-timer wind-up. It has no puck, so the
	# has_puck guard above never covers it: a client charging a one-timer
	# (SLAPPER_CHARGE_WITHOUT_PUCK) is ejected the moment the server's lagged
	# shot_state — still SKATING_WITHOUT_PUCK because the slap press hasn't been
	# processed there yet — is applied. The eject silently kills the wind-up (the
	# held RMB can't re-fire the rising-edge entry) and strands the aim arrow on
	# screen with no one-timer reticle. Hold the local state until the server
	# catches up; any real progression still applies — the puck arriving flips
	# the server to SLAPPER_CHARGE_WITH_PUCK, a release to FOLLOW_THROUGH, neither
	# of which is SKATING_WITHOUT_PUCK.
	if apply_server_shot_state \
			and pre_state == SkaterStateMachine.State.SLAPPER_CHARGE_WITHOUT_PUCK \
			and server_state.shot_state == SkaterStateMachine.State.SKATING_WITHOUT_PUCK:
		apply_server_shot_state = false
	if apply_server_shot_state:
		_sm.set_state(server_state.shot_state as SkaterStateMachine.State)
	# Wrister charge is a local control input (the player's precision sweep), not a
	# server-owned consequence — importing the host's value here yanked the live
	# charge to the host's lagged re-sim every broadcast (felt as rubber-banded
	# charge, and starved forehand shots into the old quick-shot branch). The
	# save/restore above already keeps replay from inflating it; leave the local
	# prediction authoritative. (Determinism work will let the host re-derive the
	# shot from inputs; charge does not round-trip through server state.)
	skater.set_facing(_pose.facing)
	skater.set_upper_body_rotation(_pose.upper_body_angle)
	skater.set_lower_body_lag(_pose.lower_body_lag)
	# Report trajectory divergence (predicted vs server at the same timestamp) so
	# the F3 Reconcile magnitude reflects true non-determinism. Falls back to
	# post-replay residual when no prediction was matched.
	if predicted != null:
		last_reconcile_error = predicted.position.distance_to(server_state.position)
	else:
		last_reconcile_error = (skater.global_position - server_state.position).length()
	# Count the reconcile HERE, at the per-world-state source, not once per rendered
	# frame in GameManager._observe_telemetry. The old deferral sampled at render
	# rate, so a client below the ~120 Hz world-state rate coalesced multiple
	# reconciles into one and undercounted reconcile_per_sec (a 60fps client capped
	# the metric at 60/s no matter the true rate). This runs only past the snap
	# threshold, so it still counts real corrections only.
	NetworkTelemetry.record_reconcile(last_reconcile_error)
	# Attribution: did this reconcile fire against a replay-RE-RECORDED
	# prediction (the correction echoing through replay approximations) or a
	# live one (genuine fresh divergence)? Separates replay-fidelity churn
	# from real prediction misses in the storm telemetry.
	if predicted != null and predicted.was_replay_rerecorded:
		NetworkTelemetry.record_reconcile_on_replayed_entry()
	# Post-replay residual: distance from the server AFTER snap+replay. At rest
	# (no unacked movement to predict) this should be ~0 if the snap converged; a
	# persistently non-zero value means the replay itself leaves the body
	# off-server, so the offset rebuilds every cycle instead of settling.
	NetworkTelemetry.record_post_replay_residual(skater.global_position.distance_to(server_state.position))
	# Blade must be re-applied after position is set — upper_body_to_local()
	# uses skater.global_position, so it must reflect the final replayed position.
	# Dispatch by state: slapper/follow-through have their own pose handlers; using
	# _ik.apply_blade_from_mouse here would IK the blade to the mouse position every
	# reconcile, popping it down from the slapper wind-up pose at the broadcast rate.
	match _sm.get_state():
		State.SLAPPER_CHARGE_WITH_PUCK, State.SLAPPER_CHARGE_WITHOUT_PUCK:
			_shot_pose.apply_slapper_blade_position()
		State.FOLLOW_THROUGH:
			if _sm.follow_through_is_slapper:
				_shot_pose.apply_slapper_follow_through()
			else:
				_shot_pose.apply_wrister_follow_through()
		State.SHOT_BLOCKING:
			pass  # block stance owns the pose; no per-frame blade write
		_:
			# During the celebration the raised-stick pose owns the hands;
			# re-IKing to the mouse here would pop the blade down for a frame
			# on every reconcile. Skip — the next real tick re-applies it.
			if not is_celebrating():
				_ik.apply_blade_from_mouse(_current_input, 0.0)
	var blade_reconcile_delta: float = skater.get_blade_contact_global().distance_to(pre_reconcile_blade)
	NetworkTelemetry.record_blade_reconcile(blade_reconcile_delta)
	if blade_reconcile_delta > _BLADE_JUMP_THRESHOLD:
		NetworkTelemetry.record_blade_jump(blade_reconcile_delta)
	skater.visual_offset = pre_reconcile_visual_pos - skater.global_position
	if OS.is_debug_build() and skater.visual_offset.length() > 0.05:
		push_warning("Reconcile: %.3fm snap applied (inputs replayed: %d)" \
				% [skater.visual_offset.length(), _input_history.size()])


# Re-resolve the local skater's body-check contact for one replayed tick against
# the OTHER skaters' host-authoritative positions at `host_ts` (Slice C). Applies
# BOTH the velocity impulse AND the positional push-out (sep) to the local skater
# only — the historical others are read-only. Both are required to match the host:
# the live resolver applies sep every tick (Skater._resolve_player_collisions), so
# the host's authoritative position includes it. Omitting sep here would leave a
# per-tick residual = self's inverse-mass share of the overlap for reconcile to
# snap out — worst on LOW-TRANSFER glancing contact, where dvel is small and sep
# does the positional work (exactly the "glance off, don't dead-stop" case).
# Called AFTER this tick's integration (see the replay loop) so the geometry is
# evaluated at the post-integration self position — matching the host's resolve
# instant and the host_ts=T sample instant — and dvel lands on the next tick.
# Runs the SAME inelastic model + aggressor gate as the live resolver, so
# aggressor → decel/drive-through, victim → incoming knockback. Deterministic from
# replicated data + the replayed input (local hit-commit / brace from the input
# frame). The remote attacker's hit-commit isn't on the wire, so it stays passive
# here exactly as the live client prediction assumed — the host's real value
# reconciles on the next ack.
func _replay_resolve_body_checks(host_ts: float, local_hit_held: bool) -> void:
	if not _historical_others_provider.is_valid():
		return
	# Ghost gate — mirrors the live resolver (Skater._resolve_player_collisions):
	# a ghosted skater has no body contact in either direction. Self reads the
	# live flag (same read the live resolver makes on the host); the others read
	# their rewound snapshot's flag so a mid-window ghost transition replays the
	# way the host actually resolved it.
	if skater.is_ghost:
		return
	var others: Array = _historical_others_provider.call(skater, host_ts)
	for rec: Dictionary in others:
		var other: Skater = rec["skater"]
		if other == null or rec["ghost"]:
			continue
		var opos: Vector3 = rec["position"]
		var ovel: Vector3 = rec["velocity"]
		var ohit: bool = rec["hit"]   # the other's replicated hit-commit (brace / delivery)
		var d: Vector3 = opos - skater.global_position
		d.y = 0.0
		var dist: float = d.length()
		var n: Vector3 = Vector3(1.0, 0.0, 0.0) if dist < 0.0001 else d / dist
		# Aggressor gate from the local player's perspective — identical rule to the
		# live resolver (sum of velocities along the axis, tie-broken by the stable id).
		var agg: float = (skater.velocity + ovel).dot(n)
		var local_is_aggressor: bool
		if agg > 0.0001:
			local_is_aggressor = true
		elif agg < -0.0001:
			local_is_aggressor = false
		else:
			local_is_aggressor = skater.collision_tiebreak_id < other.collision_tiebreak_id
		if local_is_aggressor:
			# local delivery (from the replayed input) × the victim's replicated brace.
			var transfer: float = skater.body_check_transfer \
					* (1.0 if local_hit_held else skater.hit_passive_transfer_mult) \
					* (other.body_check_brace_resistance if ohit else 1.0)
			SkaterCollisionRules.resolve(_replay_collision_result,
					skater.global_position, skater.velocity, skater.weight, skater.collision_radius(),
					opos, ovel, other.weight, other.collision_radius(), transfer)
			skater.velocity += _replay_collision_result.dvel_a
			skater.global_position += _replay_collision_result.sep_a
		else:
			# Other is the aggressor, local is the victim. Now that hit-commit is
			# replicated, the attacker's full-vs-passive delivery is known (was assumed
			# passive), and the local brace comes from the replayed input's hit_held —
			# the brace moved onto the Hit button.
			var transfer: float = other.body_check_transfer \
					* (1.0 if ohit else other.hit_passive_transfer_mult) \
					* (skater.body_check_brace_resistance if local_hit_held else 1.0)
			SkaterCollisionRules.resolve(_replay_collision_result,
					opos, ovel, other.weight, other.collision_radius(),
					skater.global_position, skater.velocity, skater.weight, skater.collision_radius(), transfer)
			skater.velocity += _replay_collision_result.dvel_b
			skater.global_position += _replay_collision_result.sep_b


func on_puck_picked_up_network() -> void:
	super.on_puck_picked_up_network()
	_claim_cooldown = 0.0
	_poke_cooldown = 0.0
	# Reset claim edge state so a drop-then-regrab (or an immediate poke after
	# losing it) re-claims on the next contact instead of waiting out the throttle.
	_was_in_pickup_range = false
	_pickup_claim_floor = 0.0
	_was_in_poke_range = false
	_poke_claim_floor = 0.0


func _update_one_timer_indicator() -> void:
	var state: State = _sm.get_state()
	if state == State.SLAPPER_CHARGE_WITH_PUCK:
		# One-timer window (puck arrived mid-charge): shrink the reticle ring toward
		# the release. A plain carry → slapshot charge has no window, so it keeps
		# only the aim arrow (set in _enter_slapper_charge) and shows no reticle.
		if _aiming.one_timer_window_timer > 0.0:
			var full_window: float = one_timer_window_duration + NetworkManager.get_latest_rtt_ms() / 2000.0
			var t: float = clampf(_aiming.one_timer_window_timer / full_window, 0.0, 1.0)
			skater.update_slapper_indicator_window(t)
		else:
			skater.set_slapper_indicator(false)
	elif state == State.SLAPPER_CHARGE_WITHOUT_PUCK:
		var zone_world: Vector3 = skater.get_slapper_zone_global_position()
		var zone_xz := Vector2(zone_world.x, zone_world.z)
		var puck_xz := Vector2(puck.global_position.x, puck.global_position.z)
		var dist: float = zone_xz.distance_to(puck_xz)
		skater.set_slapper_indicator_ready(dist <= _effective_one_timer_leniency())
		skater.update_slapper_indicator_convergence(clampf(dist / slapper_zone_radius, 0.0, 1.0))
	else:
		# No slapper aim active — force BOTH HUD elements down. The arrow is
		# normally cleared by _hide_slapshot_hud on every deliberate exit, but a
		# reconcile force-set of shot_state leaves a slapper state without routing
		# through it; without this the aim arrow used to strand on screen with no
		# reticle. Driving both off from the live state every tick makes the local
		# HUD self-correcting regardless of how the state was left.
		skater.set_slapper_indicator(false)
		skater.set_slapshot_arrow(false)

func _predict_offside() -> void:
	if _is_host:
		return  # Host computes authoritatively in GameManager
	# Only ARCADE uses the per-player offside ghost. OFF disables offsides;
	# NHL handles them via delayed-offside + whistle on the host (no client
	# prediction — the FACEOFF_PREP teleport is the visible feedback).
	if GameManager.get_rule_set() != GameRules.RuleSet.ARCADE:
		return
	# has_puck, NOT puck.carrier — puck.carrier is host-only (never set on
	# clients), so it read false here even while legally carrying and the
	# "carriers are never offside" exemption was dead in local prediction:
	# a body-leading zone entry self-ghosted the carrier.
	var offside: bool = InfractionRules.is_offside(
		skater.global_position.z, _team_id, puck.global_position.z, has_puck)
	# Only predict offside → ghost. Icing ghost comes from server via reconcile.
	if offside and not skater.is_ghost:
		skater.set_ghost(true)
	# If not offside but ghost is set, we don't clear here — could be icing.
	# Server reconcile corrects within one broadcast cycle.
