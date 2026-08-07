class_name RemoteController
extends SkaterController

# Host-side: the remote client's Shot Power Sensitivity, replicated at join and
# set by GameManager._on_player_spawned, so the host fires this player's wrister
# at the same power their own client predicted.
func shot_power_sensitivity() -> float:
	return net_shot_power_sensitivity

# (host_time: float, out: SkaterController.PuckView) -> void — reads the host's
# world-state buffer, leaving `out` untouched when it has no sample at that
# time. Injected by GameManager, which owns the buffer.
var _puck_history_provider: Callable = Callable()

func set_puck_history_provider(provider: Callable) -> void:
	_puck_history_provider = provider


# The puck this remote shooter was aiming at, one INPUT LEAD before the tick the
# host replays their swing on.
#
# The client applied this input at its own estimate of host time
# `host_timestamp - INPUT_LEAD_SEC` while rendering the loose puck predicted to
# that same instant (PuckController's predicted mode), and the host replays the
# input at `host_timestamp` — so the host's live puck is a whole lead further
# down the feed than the one the player swung at. That offset is fixed and
# ping-independent, which is the point: it is the ONLY lag compensation the
# one-timer needs now that the shot fires off the input stream instead of an
# arrival-timed claim RPC.
#
# The base-constant lead is used rather than the client's adapted one (which
# never rides the per-input wire). The servo only ever raises the lead, so this
# under-rewinds slightly on a client running adapted — erring toward a tighter
# window, never a friendlier one. Falls back to the live puck whenever the
# buffer has no sample (warmup, or a stamp older than the buffer).
func sample_shooter_puck_view(input: InputState, out: SkaterController.PuckView) -> void:
	super(input, out)
	if not _is_host or _puck_history_provider.is_null():
		return
	_puck_history_provider.call(
			input.host_timestamp - NetworkManager.INPUT_LEAD_SEC, out)


# The host arms this carrier's caught-one-timer window on the tick it grants the
# pickup; the carrier's own client arms it a one-way trip later and releases an
# input lead before the host sees it. Hold the host's deadline open by that
# offset so the client's honest window lands inside it, and the two cancel on
# the same input stamp. See ShotReleaseRules.one_timer_window_grace.
func one_timer_window_lag_grace() -> float:
	if not _is_host:
		return 0.0
	return ShotReleaseRules.one_timer_window_grace(
			float(NetworkManager.get_peer_ping_ms(net_peer_id)),
			NetworkManager.INPUT_LEAD_SEC,
			1.0 / float(Constants.STATE_RATE))

@export var extrapolation_max_ms: float = 50.0
# Critically-damped smoothing time (s) for the remote body position. Larger =
# smoother corrections, more chase lag; smaller = snappier, jumpier.
@export var position_smooth_time: float = 0.05

var _input_queue: Array[InputState] = []
# Stamp set for the input dedupe, hoisted out of receive_input_batch (120 batches/s
# per client). Built lazily — see there — and never escapes the call.
var _input_dedupe_scratch: Dictionary = {}
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
# Stage-3 forward-prediction scratch (see _interpolate): reused so the per-tick ×
# remotes intent-integration allocates nothing.
var _fp_result := SkaterMovementRules.ForwardResult.new()
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
	# Blade history for this tick, before any path below can move the stick. On
	# the host that includes the faceoff-prep aim-only sync and the skate-in
	# glide, neither of which runs _process_input, yet both feed the host's
	# swept-segment pickup/poke test. See Skater.capture_prev_blade_contact.
	skater.capture_prev_blade_contact()
	if _is_host:
		_drive_from_input(delta)
	else:
		# Live interpolation owns this body's cosmetics, so the render-rate gait
		# hook must run. Clear _self_posing here: a replay driving this same skater
		# via apply_replay_state raises the flag (that path poses its own gait), and
		# nothing else lowers it on a client-rendered remote — _process_input, the
		# only other reset, never runs on this path — so without this the flag stuck
		# true after the first goal/intermission replay and the render hook yielded
		# forever, freezing every remote's legs for the rest of the match. Guarded by
		# the is_replay_mode() early-return above, so this only fires in live play.
		_self_posing = false
		if _knockback_lead_elapsed >= 0.0:
			_knockback_lead_elapsed += delta
		_interpolate(delta)
		# Cosmetic leg gait + lower-body yaw moved to render rate (_render_pose_
		# update below, invoked from Skater._process). Age the goal-celebration
		# timer here at physics rate, though — it used to ride the gait pass, and
		# the render gait is visibility-gated so it can't own the timer any more
		# (a wire-fed remote still needs its celebration leg bounce to end).
		tick_celebration(delta)

# Render-rate cosmetic pose for a remote body (overrides SkaterController).
# Two sub-cases:
#  - Host-simulating this client's real inputs (_is_host): it has a live cursor
#    aim and apply_facing already wrote the leg-yaw, so head-track like a local.
#  - Client-rendering an interpolated remote: no cursor aim (skip head), and
#    apply_facing never ran, so mirror the gait's leg-yaw channels here.
func _render_pose_update(delta: float) -> void:
	if skater == null or _self_posing:
		return
	_skating.apply(delta)
	_apply_knockdown_fall()
	if _is_host:
		_pose.apply_head_tracking_aim(_current_aim_world, delta)
	else:
		skater.set_lower_body_lag(
				_skating.stop_yaw_offset + _skating.travel_align_yaw + _skating.shot_hip_yaw)
	if _celebration_timer <= 0.0:
		_ik.update_bottom_hand()


static func _input_ts_less(a: InputState, b: InputState) -> bool:
	return a.host_timestamp < b.host_timestamp


# Returns this queue's DEDUPE WATERMARK: the newest stamp already known here,
# whether processed or still queued. The host's decoder skips records at or below
# it, so it never pays InputState.from_bytes for the ~119-in-120 redundant frames
# a batch carries for loss resilience. Reported by the caller, which owns the
# peer id (GameManager._on_input_batch_received).
func receive_input_batch(batch: Array[InputState]) -> float:
	# Reject inputs whose timestamps fall outside a plausible window around the
	# host clock. Legitimate timestamps land in [now - RTT, now + INPUT_LEAD_SEC];
	# anything wildly outside is either a malicious peer or a desynced clock and
	# would otherwise sit in the queue indefinitely (future) or fail the gate
	# forever (past). The queue cap below already truncates older stragglers.
	const FUTURE_SLACK_S: float = 0.1   # INPUT_LEAD_SEC (~25ms) + slack for jitter / clock convergence
	const PAST_SLACK_S: float = 2.0     # generous: queue cap is ~0.5 s, this is 4x
	var now: float = NetworkManager.estimated_host_time()
	# The queue is kept sorted below, so its last entry is the newest stamp in it.
	# A record strictly newer than that cannot be a duplicate — which, behind the
	# host-side skip, is every record of a healthy batch — so the dedupe set is
	# built only if some record lands at or below the newest queued stamp.
	var newest_queued: float = -INF
	if not _input_queue.is_empty():
		newest_queued = _input_queue.back().host_timestamp
	var seen: Dictionary = _input_dedupe_scratch
	var seen_built: bool = false
	var out_of_order: bool = false
	for state: InputState in batch:
		if state.host_timestamp <= last_processed_host_timestamp:
			continue
		if state.host_timestamp <= newest_queued:
			if not seen_built:
				seen_built = true
				seen.clear()
				for queued: InputState in _input_queue:
					seen[queued.host_timestamp] = true
			if seen.has(state.host_timestamp):
				continue
			# A gap fill: this lands before the queue's newest entry, so the
			# append below breaks the sort order and has to be repaired.
			out_of_order = true
		if state.host_timestamp < now - PAST_SLACK_S or state.host_timestamp > now + FUTURE_SLACK_S:
			continue
		_input_queue.append(state)
		if seen_built:
			seen[state.host_timestamp] = true
		if state.host_timestamp > newest_queued:
			newest_queued = state.host_timestamp
	# Batches are chronological and the queue only grows at its newest end, so the
	# ordering is normally preserved by construction — sort only when a gap fill
	# actually broke it, rather than paying O(n log n) plus a fresh comparator
	# lambda on every batch.
	if out_of_order:
		_input_queue.sort_custom(_input_ts_less)
	var MAX_QUEUE_DEPTH: int = Constants.PHYSICS_TICK / 2  # ~0.5 s
	while _input_queue.size() > MAX_QUEUE_DEPTH:
		_input_queue.pop_front()
	if _input_queue.is_empty():
		return last_processed_host_timestamp
	return maxf(last_processed_host_timestamp, _input_queue.back().host_timestamp)

# Backlog drain thresholds. Consumption is one input per tick and production is
# one per tick, so the queue can never catch up on its own: an upstream jitter
# burst that empties the queue for N ticks (fallback fires, consumption pauses,
# production continues) leaves the queue N deep PERMANENTLY once the delayed
# inputs land — every subsequent input applied ~N ticks stale, ratcheting up
# with each burst until the 0.5 s cap. The drain bounds that: when the front
# input is overdue past the trigger, stale inputs are acked-without-applying
# (the same philosophy as the movement-locked drain) down to the target, with
# edge flags (presses) folded into the next applied input so a press inside the
# dropped span still fires once. The client sees one reconcile correction for
# the dropped span — the honest cost of inputs the network delivered too late —
# instead of a session of staleness.
#
# SIZING (measured, 3-peer 5v5 host row + the host_input_queue_depth metric):
# the queue runs 9-10 deep — that IS the stamp-lead cushion working — while the
# front pops ~12 ms overdue in steady state. That 12 ms is not lateness: the
# host renders ~100-110 fps against a 120 Hz tick, so physics ticks bunch two
# to a frame and a pop lands up to a frame after its due instant. Ordinary
# hitches add ~15-25 ms on top.
#
# The old 4-tick (33 ms) trigger sat INSIDE that band, so it fired 4-12/s on a
# perfectly healthy deep queue — and every fire discards real inputs the client
# already predicted with, which costs it one visible reconcile. Worse, the old
# 1-tick target drained to ~8.3 ms, BELOW the 12 ms quantization floor, so the
# very next frame read as overdue again and re-armed the trigger.
#
# The trade is asymmetric and that decides the sizing: tolerating slip costs
# input LATENCY (invisible, bounded, and corrected when it grows); draining
# costs a visible correction. So the trigger sits above the quantization +
# hitch band and only catches a genuine ratchet, and the target lands clear of
# the quantization floor so one drain actually settles it.
const _DRAIN_TRIGGER_S: float = 8.0 / 120.0  # ~67 ms overdue engages the drain
const _DRAIN_TARGET_S: float = 2.0 / 120.0   # drain back to ~17 ms, clear of the ~12 ms floor
# A LONE input this stale is a phase-resume artifact (parked across a goal
# replay / intermission), not the freshest available intent — drop-and-ack it
# (fallback covers the tick) instead of applying seconds-old held state. Its
# presses are equally stale actions and are deliberately NOT carried.
const _DRAIN_STALE_SOLO_S: float = 0.25
# Drains counted in telemetry only at jitter scale — a phase-resume flush is a
# designed catch-up, and counting it buried the ratchet-fix signal the metric
# exists to show.
const _DRAIN_TELEMETRY_MAX_S: float = 1.0


func _drain_backlog(now: float) -> void:
	if _input_queue.is_empty():
		return
	# Lone-stale drop (see _DRAIN_STALE_SOLO_S).
	if _input_queue.size() == 1 			and now - _input_queue.front().host_timestamp > _DRAIN_STALE_SOLO_S:
		var solo: InputState = _input_queue.pop_front()
		last_processed_host_timestamp = solo.host_timestamp
		return
	if _input_queue.size() <= 1:
		return
	if now - _input_queue.front().host_timestamp <= _DRAIN_TRIGGER_S:
		return
	var target: float = now - _DRAIN_TARGET_S
	while _input_queue.size() > 1 and _input_queue.front().host_timestamp < target:
		var stale: InputState = _input_queue.pop_front()
		var overdue: float = now - stale.host_timestamp
		last_processed_host_timestamp = stale.host_timestamp
		# Record the lead here too. A drained input is BY DEFINITION the most
		# overdue one in the queue, so omitting it made input_lead_ms
		# survivorship-biased: its own max was bounded by _DRAIN_TARGET_S, and a
		# session could report a max well under _DRAIN_TRIGGER_S while draining
		# several times a second — the two readings looked mutually impossible.
		# Phase-resume artifacts stay out, matching the servo's sample gate.
		if overdue <= _DRAIN_STALE_SOLO_S:
			NetworkTelemetry.record_input_lead(overdue)
		# Presses are edges the player committed — dropping the frame that carried
		# one must not eat the action. Held/absolute state (move vector, brake,
		# aim, elevation_level) is NOT carried: the next applied input holds the
		# current truth, which is the point of the drain. Presses older than the
		# stale-solo bound are phase artifacts and are dropped with their frame.
		if overdue <= _DRAIN_STALE_SOLO_S:
			var next: InputState = _input_queue.front()
			next.shoot_pressed = next.shoot_pressed or stale.shoot_pressed
			next.slap_pressed = next.slap_pressed or stale.slap_pressed
			next.stick_lift_pressed = next.stick_lift_pressed or stale.stick_lift_pressed
			next.quick_pass_pressed = next.quick_pass_pressed or stale.quick_pass_pressed
		if overdue <= _DRAIN_TELEMETRY_MAX_S:
			NetworkTelemetry.record_input_drain()


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
	if NetworkManager.is_clock_ready():
		_drain_backlog(NetworkManager.estimated_host_time())
	var input_due: bool = _input_queue.size() > 0 and (
			not NetworkManager.is_clock_ready() or
			_input_queue.front().host_timestamp <= NetworkManager.estimated_host_time())
	if input_due:
		var input: InputState = _input_queue.pop_front()
		last_processed_host_timestamp = input.host_timestamp
		if not _game_state.is_movement_locked():
			# Recorded for LIVE pops only: locked-phase pops (faceoff prep,
			# celebrations) measure phase cadence, not link health, and were
			# skewing the metric the adaptive lead is judged by.
			NetworkTelemetry.record_input_lead(
					NetworkManager.estimated_host_time() - input.host_timestamp)
		if not _game_state.is_movement_locked():
			_process_input(input, delta)
		elif not tick_faceoff_approach(delta):
			# Faceoff / intro skate-in glides the body to the dot (host-authoritative;
			# broadcasts to clients like any other motion). On arrival it returns
			# false and we fall back to the frozen aim-only sync below.
			skater.velocity = Vector3.ZERO
			# FACEOFF_PREP: keep the host's view of this remote peer's stick in
			# sync with their mouse so world state broadcasts the right blade
			# position for everyone else to see. _process_input still doesn't
			# run, so body/shot inputs stay suppressed.
			if _game_state.allows_blade_aim_during_lock():
				apply_blade_aim_only(input, delta)
		# Clear just_pressed flags before saving as fallback so they don't
		# re-fire on subsequent ticks while the queue is empty. elevation_level
		# stays — it's an absolute mode, and holding the last known level
		# through an input gap is exactly right.
		input.shoot_pressed = false
		input.slap_pressed = false
		_fallback_input = input
	else:
		if _game_state.is_movement_locked():
			if not tick_faceoff_approach(delta):
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
	# Recycle the evicted front entry as the new back one instead of allocating a
	# fresh wrapper per packet (see PuckController.apply_state). Safe because the
	# interpolation bracket is re-derived from the buffer every tick before use,
	# so no consumer holds a wrapper across frames.
	var buffered: BufferedSkaterState
	if _state_buffer.size() >= 30:
		buffered = _state_buffer.pop_front()
	else:
		buffered = BufferedSkaterState.new()
	buffered.timestamp = host_ts
	buffered.state = state
	_state_buffer.append(buffered)


# Where the HOST had this skater at host_time, from the interpolation buffer. The
# local player's reconcile replay samples every OTHER skater here to re-resolve
# body checks against the host's authoritative positions (Slice C) instead of
# replaying a stale recorded impulse — so replay matches host authority. Returns a
# shared scratch (read it before the next call) with position / velocity /
# brake_intent, or null when the buffer can't bracket the time (warmup / gap), in
# which case the caller skips the pair. Separate bracket scratch from _interpolate
# so a reconcile-time sample can't clobber the live render bracket.
var _sample_bracket: BufferedStateInterpolator.BracketResult = BufferedStateInterpolator.BracketResult.new()
var _sample_scratch: SkaterNetworkState = SkaterNetworkState.new()

func sample_state_at(host_time: float) -> SkaterNetworkState:
	if _state_buffer.is_empty():
		return null
	var bracket: BufferedStateInterpolator.BracketResult = BufferedStateInterpolator.find_bracket(
			_state_buffer, host_time, _sample_bracket)
	if bracket == null:
		return null
	if bracket.is_extrapolating:
		# `host_time` here is an INPUT STAMP (`now + input lead`), so it is always
		# past the newest buffered snapshot — this branch is the steady state for
		# reconcile replay, not an edge case.
		#
		# Intent-integrate the newest snapshot forward to the requested instant,
		# which is what this function's contract already promised ("where the HOST
		# had this skater at host_time"): the host resolves the input stamped T
		# against its live bodies at T, so that is the geometry replay must
		# reproduce. It is also the SAME primitive, decay constant and has_puck
		# convention the live render (`_interpolate`) and the host's own hit-claim
		# rewind (`LagCompRewind.forward_predict_skater`) use.
		#
		# It previously FROZE at the newest sample, on the reasoning that a
		# projected lead "could fabricate a false overlap the host never resolved."
		# That was sound when remotes rendered in the past — freezing was
		# conservative relative to the screen. Since the render gained stage-3
		# forward prediction it inverted: the live step collides against a
		# ~host-present body while replay re-resolved the same contact against one
		# `one_way + broadcast_interval/2` older, so replay could flip overlap, the
		# aggressor gate, and the contact normal against both the screen AND the
		# host. Freezing was the only one of the three parties still in the past.
		var newest: SkaterNetworkState = bracket.to_state
		_sample_scratch.position = newest.position
		_sample_scratch.velocity = newest.velocity
		_sample_scratch.brake_intent = newest.brake_intent
		_sample_scratch.hit_committed = newest.hit_committed
		# Ghost gate for the reconcile replay's body-check re-resolution: without
		# this the scratch held the constructor default (false) forever and the
		# replay resolved contacts against ghosted skaters the host skipped —
		# a reconcile snap-loop for as long as the overlap persisted.
		_sample_scratch.is_ghost = newest.is_ghost
		_predict_sample_forward(newest, bracket.extrapolation_dt)
	else:
		var f: SkaterNetworkState = bracket.from_state
		var to: SkaterNetworkState = bracket.to_state
		_sample_scratch.position = BufferedStateInterpolator.hermite(
				f.position, f.velocity, to.position, to.velocity, bracket.t, bracket.bracket_dt)
		_sample_scratch.velocity = f.velocity.lerp(to.velocity, bracket.t)
		# Brace at/before host_time — a discrete flag, so take the earlier sample.
		_sample_scratch.brake_intent = f.brake_intent
		_sample_scratch.hit_committed = f.hit_committed
		# Discrete like brake_intent — the at/before-host_time sample, so a
		# mid-window ghost transition replays the way the host resolved it.
		_sample_scratch.is_ghost = f.is_ghost
	return _sample_scratch


# Beyond this the buffer is too stale to project honestly and the sample holds at
# the newest snapshot instead (the old freeze, kept as the deep-loss fallback).
# Steady state is well inside it: the gap is `input lead + one_way +
# broadcast_interval/2` — ~115 ms even on a poor link — so the cap only engages
# when snapshots have genuinely stopped arriving, where inventing a third of a
# second of skating would fabricate contacts rather than reconstruct them.
const _SAMPLE_PREDICT_MAX_S: float = 0.15


# Advances `_sample_scratch` from `newest` by `dt` using the shared movement
# integration — the same primitive/decay/has_puck=false convention as
# `_interpolate`'s stage-3 lead and `LagCompRewind.forward_predict_skater`, so all
# three reconstruct a remote body identically. Facing is held (matching both), and
# the intent fields come from the snapshot the wire already quantized, so no
# re-quantization is needed here (unlike the host-side helper, which reads raw
# analog bot intent).
func _predict_sample_forward(newest: SkaterNetworkState, dt: float) -> void:
	if dt <= 0.0 or dt > _SAMPLE_PREDICT_MAX_S or not is_finite(dt):
		return
	var ticks: int = roundi(dt * float(Constants.PHYSICS_TICK))
	if ticks <= 0:
		return
	var heading: float = atan2(newest.facing.x, newest.facing.y)
	var nm: RefCounted = native_movement()
	if nm != null:
		nm.integrate_forward(
				newest.position, newest.velocity, newest.move_intent,
				heading, false, newest.brake_intent, newest.sprint_active,
				1.0 / float(Constants.PHYSICS_TICK), ticks,
				Constants.FORWARD_PREDICT_INTENT_DECAY_TICKS, newest.stagger_timer, true)
		_sample_scratch.position = nm.get_forward_position()
		_sample_scratch.velocity = nm.get_forward_velocity()
	else:
		SkaterMovementRules.integrate_forward(
				newest.position, newest.velocity, newest.move_intent,
				heading, false, newest.brake_intent, newest.sprint_active,
				_movement_config(), 1.0 / float(Constants.PHYSICS_TICK), ticks,
				Constants.FORWARD_PREDICT_INTENT_DECAY_TICKS, _fp_result,
				newest.stagger_timer, _body_check_config())
		_sample_scratch.position = _fp_result.position
		_sample_scratch.velocity = _fp_result.velocity

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
			- interp_delay
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
		interpolated.elevation_level = newest.elevation_level
		interpolated.blade_up = newest.blade_up
		interpolated.shot_state = newest.shot_state
		interpolated.shot_charge = newest.shot_charge
		interpolated.stagger_timer = newest.stagger_timer
		interpolated.knockdown_timer = newest.knockdown_timer
		interpolated.move_intent = newest.move_intent
		interpolated.brake_intent = newest.brake_intent
		interpolated.hit_committed = newest.hit_committed
		interpolated.sprint_active = newest.sprint_active
		interpolated.wrister_address_side = newest.wrister_address_side
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
		# without a one-broadcast delay. (shot_state / elevation were
		# previously never copied onto the interpolated object at all, so
		# _apply_state_to_skater wrote type defaults to the skater every tick
		# and the elevated-blade replication had no effect on remotes.)
		interpolated.is_ghost = to_state.is_ghost
		interpolated.elevation_level = to_state.elevation_level
		interpolated.blade_up = to_state.blade_up
		interpolated.shot_state = to_state.shot_state
		# Charge is a scalar — lerp it so the remote's stick-flex load bow
		# grows smoothly through the drag instead of stepping per broadcast.
		interpolated.shot_charge = lerpf(from_state.shot_charge, to_state.shot_charge, t)
		interpolated.stagger_timer = lerpf(from_state.stagger_timer, to_state.stagger_timer, t)
		interpolated.knockdown_timer = lerpf(from_state.knockdown_timer, to_state.knockdown_timer, t)
		interpolated.move_intent = to_state.move_intent
		interpolated.brake_intent = to_state.brake_intent
		interpolated.hit_committed = to_state.hit_committed
		interpolated.sprint_active = to_state.sprint_active
		interpolated.wrister_address_side = to_state.wrister_address_side
		# The hermite result sits a full interp_delay in the past (or, past the
		# newest sample, the is_extrapolating branch dead-reckons it); the stage-3
		# intent integration below is what carries the body toward present. Any
		# correction error is absorbed by the SmoothDamp stage. blade/top_hand are
		# upper_body-local
		# and ride the body through the scene tree, so they need no projection.
	# Stage-3 forward prediction: intent-integrate the interpolated-past body toward
	# host-present so a remote reads at its true closing distance instead of a full
	# interp_delay behind. The host runs the IDENTICAL integration on the hit-claim
	# rewind snapshot (HitClaimResolver) via the shared forward_predict_ticks depth,
	# so render == rewind holds at any fraction. has_puck is forced false to match
	# that host reconstruction exactly (the carry speed cap is a ~cm-scale term over
	# the window and both sides drop it). Facing is held (rendered from the
	# interpolated value); position + velocity advance. No-op at fraction 0 —
	# forward_predict_ticks returns 0 and integrate_forward is the identity.
	var fp_ticks: int = LagCompRewind.forward_predict_ticks(
			Constants.REMOTE_FORWARD_PREDICT_FRACTION, interp_delay)
	if fp_ticks > 0:
		# Stagger from the bracket's NEWER endpoint — the same snapshot the host's
		# rewind reads (StateBufferManager copies newer-endpoint too), so the
		# thrust penalty is identical on both sides.
		var fp_stagger: float = _scratch_bracket.to_state.stagger_timer \
				if _scratch_bracket.to_state != null else 0.0
		var nm: RefCounted = native_movement()
		if nm != null:
			nm.integrate_forward(
					interpolated.position, interpolated.velocity, interpolated.move_intent,
					atan2(interpolated.facing.x, interpolated.facing.y), false,
					interpolated.brake_intent, interpolated.sprint_active,
					1.0 / float(Constants.PHYSICS_TICK), fp_ticks,
					Constants.FORWARD_PREDICT_INTENT_DECAY_TICKS, fp_stagger, true)
			interpolated.position = nm.get_forward_position()
			interpolated.velocity = nm.get_forward_velocity()
		else:
			SkaterMovementRules.integrate_forward(
					interpolated.position, interpolated.velocity, interpolated.move_intent,
					atan2(interpolated.facing.x, interpolated.facing.y), false,
					interpolated.brake_intent, interpolated.sprint_active, _movement_config(),
					1.0 / float(Constants.PHYSICS_TICK), fp_ticks,
					Constants.FORWARD_PREDICT_INTENT_DECAY_TICKS, _fp_result,
					fp_stagger, _body_check_config())
			interpolated.position = _fp_result.position
			interpolated.velocity = _fp_result.velocity
	# Forward-prediction quality: the pre-damp error the smoother is about to
	# absorb on this body (fp error + correction pressure). Teleport-scale
	# distances (faceoff/goal resets — anything the snap guard hard-snaps) are
	# excluded: legitimate repositions, not prediction error (they buried the
	# real peaks under ~40 m resets in the first playtest's rows).
	if _smooth_initialized:
		var residual: float = (interpolated.position - _smooth_pos).length()
		if residual < _SMOOTH_SNAP_DIST:
			NetworkTelemetry.record_remote_correction(residual)
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
	# Replicated from the host so the loft-level blade scoop (Skater
	# ._update_blade_elevation) shows on spectated remotes, not just locally.
	skater.elevation_level = state.elevation_level
	# Resolved stick-lift state. The lifted blade pose already rides in via the
	# replicated blade_position above; this keeps skater.blade_up correct for
	# any reader (AI off-puck, VFX) on spectated remotes.
	skater.blade_up = state.blade_up
	skater.current_shot_state = state.shot_state
	# Wrister address, gated on the aim state — the wire bit is garbage
	# otherwise. The skater's address pass adopts it so a spectated shooter's
	# frozen blade re-addresses the same side the shooter sees (Skater
	# .set_wrister_address_side).
	if state.shot_state == SkaterStateMachine.State.WRISTER_AIM:
		skater.set_wrister_address_side(state.wrister_address_side)
	# Charge drives the stick-flex load bow (Skater._update_stick_flex reads
	# it in WRISTER_AIM every rendered frame). It was replicated and decoded
	# but never applied here, so remote wristers always bowed at zero charge
	# — only the release whip's minimum pop showed on other machines.
	skater.shot_charge = state.shot_charge
	# Movement intent for the gait's input-driven reads (glide, intent
	# crossovers, brake-gated hockey stop) — the client-rendered remote's
	# equivalent of the per-tick stamp in SkaterController._process_input.
	skater.move_intent = state.move_intent
	skater.brake_intent = state.brake_intent
	# Replicated hit-commit so the body-check resolver reads this remote's brace /
	# full-vs-passive delivery on this machine (the brace moved onto the Hit button).
	skater.hit_committed = state.hit_committed
	# The skid VFX (SkaterVFX trail marks + spray) keys off skater.is_braking,
	# which only _process_input stamps — mirror it from the replicated brake
	# bit so another player's hockey stop actually sprays on this machine.
	skater.is_braking = state.brake_intent
	# The gait's sprint read keys off the CONTROLLER's sprint_active, which
	# only the simulating machine resolves (_apply_movement) — mirror it from
	# the replicated bit so another player's sprint visibly changes their
	# stride on this machine (the on-screen stamina tell).
	sprint_active = state.sprint_active
	# The stagger-stumble wobble reads the CONTROLLER's stagger_timer (the
	# gait derives its phase from the countdown). It was replicated since v10
	# for the local victim's reconcile, but never applied to client-rendered
	# remotes — so a checked opponent stumbled on the host and stood rock-
	# steady on everyone else's screen.
	stagger_timer = state.stagger_timer
	# Knockdown mirrors stagger onto client-rendered remotes: the controller value
	# and the skater flag so the down pose and any is_knocked_down read reflect a
	# checked opponent on every machine, not just the host. The meta sync seeds
	# the fall (direction + tip rate) from the replicated slide velocity stamped
	# above, so the remote body falls the way the hit actually shoved it.
	var prev_kd: float = knockdown_timer
	knockdown_timer = state.knockdown_timer
	skater.is_knocked_down = knockdown_timer > 0.0
	_sync_knockdown_meta(prev_kd)
	# Bottom hand is purely reactive to top_hand + blade and needs no network
	# state of its own; it's posed once per rendered frame in _render_pose_update
	# (Skater._process) along with the gait, not here.
