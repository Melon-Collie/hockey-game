class_name PuckController
extends Node

const PICKUP_RADIUS: float = 0.5
const POKE_RADIUS: float = GameRules.POKE_RADIUS_M
# Contested-pickup squirt tuning (see PuckCollisionRules.contested_pickup_velocity).
# The exit is biased toward the stronger blade and paced by the combined blade
# momentum, clamped here; a true deadlock pops out sideways at contest_deadlock_speed.
# Speeds are kept gentle so faceoffs read as doable rather than a coin flip:
# winning a draw should deliver the puck toward your target at a pace you can skate
# onto (contest_min_speed), while a hard committed sweep still snaps it out toward
# contest_max_speed. A true 50/50 only trickles off the dot (contest_deadlock_speed)
# and stays a live loose puck to keep battling for, instead of firing to a random side.
@export var contest_min_speed: float = 1.5
@export var contest_max_speed: float = 9.0
@export var contest_deadlock_speed: float = 1.2
@export var contest_deadlock_threshold: float = 0.5  # net blade momentum (m/s) below which it's a 50/50
# Faceoff-draw timing REWARD (see FaceoffDrawRules.timing_weight). When a center is
# draw-tracking (armed by PhaseCoordinator), its contest momentum is the retained
# swipe crest (SkaterController.faceoff_draw_*) scaled by this timing weight, so a
# blade crest landing on the drop wins decisively and a late stab is discounted.
# contest_draw_timing_bonus is the peak multiplier added for a crest right on the
# drop; it eases to contest_draw_timing_min_weight by contest_draw_timing_miss_
# window seconds later. Off a faceoff (board scrambles) no center is tracking, so
# the contest keeps reading the raw blade velocity — these don't apply.
@export var contest_draw_timing_bonus: float = 0.4
@export var contest_draw_timing_miss_window: float = 0.35
@export var contest_draw_timing_min_weight: float = 0.7
# Stick-lift geometry: how close the attacker's (lifted) blade must be to the
# carrier's hand→blade shaft, and how far below it, to hook under and pop it up.
# Slightly wider than POKE_RADIUS — the lifted blade meets the shaft up off the
# ice rather than the puck on it.
const STICK_LIFT_RADIUS: float = 0.45
const STICK_LIFT_UNDER_MARGIN: float = 0.0
# How long a forced stick-lift keeps the victim's blade popped up after the hook
# lands — enough to read as a lift and to deny an instant re-grab on top of the
# reattach cooldown apply_stick_lift_strip already sets.
const STICK_LIFT_FORCED_LIFT_S: float = 0.4

@export var extrapolation_max_ms: float = 50.0
@export var trajectory_hard_snap_threshold: float = 1.5
@export var trajectory_soft_blend_threshold: float = 0.3
@export var position_correction_blend: float = 0.1
# Trajectory→interpolation handoff slew (see PuckHandoffRules). During shot
# prediction the puck renders ~RTT/2 AHEAD of host-present; interpolation
# renders interp_delay BEHIND it. Jumping between the two timelines at handoff
# moves the puck backward along its own flight by velocity × (RTT/2 +
# interp_delay) — metres on a shot. Instead, interpolation starts with a
# temporary render-time lead that lines its first target up with the live puck,
# then sheds it at handoff_slew_rate seconds-per-second: the puck briefly runs
# at (1 − rate) of true pace (reads as dying off the pads) instead of ever
# flying backward. Rate must stay < 1 so render time remains monotonic;
# handoff_max_lead_s bounds the lead when a divergent bounce projects nonsense.
@export_range(0.05, 0.9, 0.05) var handoff_slew_rate: float = 0.35
@export var handoff_max_lead_s: float = 0.35
# Below this speed (m/s) the along-track decomposition in PuckHandoffRules is
# meaningless: no slew is seeded and the smoother's snap guard falls back to
# the plain distance check (covers faceoff/goal-reset teleports, at rest).
const _HANDOFF_MIN_SPEED: float = 2.0
# Along-track smoother error is tolerated up to velocity × this window before
# snapping — the expected timeline offset a fast puck carries, which the slew
# (not the position smoother) is responsible for absorbing.
const _ALONG_SNAP_TIME_S: float = 0.3
# Loose-puck forward lead toward host-present, 0..1 (see _interpolate), mirroring
# RemoteController so a chasing skater and the loose puck share a timeline. Held
# at 0 so the puck renders a FULL interp_delay behind host-present — matching the
# lag-comp pickup/poke rewind (LagCompRewind.remote_view_time subtracts the full
# interp_delay). A non-zero lead renders the puck closer to present but makes the
# host validate grabs against a puck up to interp_delay/2 behind where the
# claimant reached for it, so pickups miss — badly during jitter, when
# interp_delay spikes. The SmoothDamp below still absorbs bounce overshoot.
#
# SUPERSEDED by stage-4: _interpolate now leads via Constants.PUCK_FORWARD_LEAD_FRACTION
# (decoupled from the skater fraction, parked at 0 — see that constant) gated by
# _blade_lead_scale, which eases the lead to 0 as a blade nears so render == rewind
# holds where pickups fire — this raw export had no such gate and is no longer read.
# Left at 0.
@export_range(0.0, 1.0, 0.05) var extrapolation_lead_fraction: float = 0.0
# Critically-damped smoothing time (s) for the loose-puck position. Slightly above
# the skater's so bounce overshoot blends out cleanly.
@export var position_smooth_time: float = 0.06
# Smart extrapolation: when the forward dead-reckon would carry the puck across a
# board within the lead window, stop leading for that frame and hold at the newest
# authoritative position instead of projecting through the boards (see _interpolate).
@export var stop_extrapolation_at_boards: bool = true
# Extra friction applied during trajectory prediction to compensate for any
# divergence between client and host Jolt friction. Set to 0 while both run
# identical physics; tune upward if free-puck trajectories drift apart.
@export var prediction_extra_friction: float = 0.0
@export var carry_smoothing_speed: float = 80.0
# Optimistic (visual-only) pickup: a loose pickup is treated as uncontested —
# safe to attach locally before the host confirms — only when no other skater's
# blade is within this radius of the puck on our rendered view. Inflated past
# PICKUP_RADIUS to absorb the ~interp-delay lag in other skaters' rendered
# positions, so a converging opponent still trips it. Tune up for fewer
# rollbacks, down for snappier attaches in light traffic.
@export var contest_danger_radius: float = 1.5

var puck: Puck = null
var is_server: bool = false

# ── State ─────────────────────────────────────────────────────────────────────
var _carrier_peer_id: int = -1            # server-side authoritative carrier
var _local_carrier_skater: Skater = null  # client-side: local skater while carrying
# Client-side: the remote skater currently carrying, when it's NOT the local
# player. While set, the puck is pinned to this skater's interpolated blade
# rather than interpolating from its own buffer — the two used to run on
# independent adaptive delays, drifting the puck off the carrier's stick.
var _remote_carrier_skater: Skater = null
# Client-side optimistic pickup (visual only). When the local blade enters an
# uncontested loose puck, the puck pins to it immediately so the grab looks
# instant, but the carry state machine does NOT engage until the host confirms
# via notify_local_pickup — on grant the pin promotes seamlessly, on timeout or
# a different carrier it rolls back to interpolation. Gating on "uncontested"
# preserves the no-pickup-prediction guarantee for contested plays (the case
# where rollback feels worse than the round-trip).
var _provisional_carrier_skater: Skater = null
var _provisional_deadline: float = -1.0       # local_time past which we roll back
# Post-loss lockout: don't optimistically re-grab while the host's reattach
# cooldown would still refuse us, which would attach then visibly pop off.
var _provisional_lockout_until: float = -1.0
const _PROVISIONAL_TIMEOUT_S: float = 0.3     # floor; scaled up by RTT in try_provisional_pickup
var _prev_puck_pos: Vector3 = Vector3.ZERO
var _state_buffer: Array[BufferedPuckState] = []
var _predicting_trajectory: bool = false
var _pending_local_release: bool = false  # true from local release until host confirms carrier == -1
# Hard deadline (session-relative seconds, NetworkManager.local_time base) past
# which _pending_local_release force-clears even without a confirming snapshot.
# Defends against the lock-forever case where both the confirming world state
# AND the post-contact handlers are lost — without this, the puck stays in
# pending-release mode indefinitely and apply_state early-returns on every
# broadcast.
var _pending_local_release_deadline: float = -1.0
const _PENDING_RELEASE_TIMEOUT_S: float = 0.3  # ~2× typical RTT, well above any healthy network
var _shot_rtt_ms: float = 0.0             # RTT captured at release time; used for trajectory reconcile
var is_extrapolating: bool = false

# ── Phase-0 shadow-puck comparator (dev + host only) ──────────────────────────
# Runs the analytic shadow puck (PuckShadowComparator) alongside the real Jolt puck
# each host tick and logs divergence — the determinism go/no-go instrument
# (docs/netcode-phase0-shadow-puck-spec.md). Created ONLY in dev builds
# (BuildInfo.VERSION == "dev", the same gate NetworkSimManager uses), so it's absent
# from exported builds and can never ship. Never drives the real puck.
var _shadow: PuckShadowComparator = null
var _goalie_shadow: GoalieCollisionShadow = null  # Phase-2 goalie-collision harness
var _shadow_board_contact: bool = false
var _shadow_goalie_contact: bool = false  # Jolt fired a goalie entry this tick (probe ground truth)
var _goalie_provider: Callable = Callable()  # dev-only: returns Array[Goalie] for the FP probe
var _shadow_log_timer: float = 0.0
const _SHADOW_LOG_INTERVAL_S: float = 3.0
# Dev-build mode switch (see setup): true = the analytic sim drives the loose puck
# (the determinism-migration playtest configuration); false = Jolt drives and the
# Phase-0/2 shadow harnesses measure the analytic model against it. Mutually
# exclusive because a harness measuring the drive's own output measures nothing.
const _ANALYTIC_DRIVE_IN_DEV: bool = true
# The proactive FP probe only runs when a goalie is within this of the puck — a cheap gate
# so probe_ticks (and the per-tick get_colliding_bodies allocation) stay off unless the
# puck is actually near a net.
const _GOALIE_PROBE_RANGE_M: float = 1.5
# Scoped true only while a stick-lift strip is being applied, so the synchronous
# puck_stripped_from handlers (sound + victim notify) can tell a stick lift apart
# from a poke/body-check strip and pick the right cue. Read via
# is_processing_stick_lift(); always reset immediately after apply_stick_lift_strip.
var _processing_stick_lift: bool = false

var _post_contact_timer: float = -1.0    # >= 0 while suppressing reconcile after a bounce
# Reused scratch objects for the per-tick interpolation lookup + output.
var _scratch_bracket := BufferedStateInterpolator.BracketResult.new()
var _scratch_interp := PuckNetworkState.new()
# Critically-damped position smoother for the loose puck (see _interpolate).
# Reseeded from the puck's live position on every fresh entry into interpolation
# (carry / trajectory / extrap → loose), so it blends those seams instead of
# snapping — subsumes the former rejoin-blend.
var _smooth_pos: Vector3 = Vector3.ZERO
var _smooth_vel: Vector3 = Vector3.ZERO
var _smooth_initialized: bool = false
const _SMOOTH_SNAP_DIST: float = 2.0  # pathological gap → snap rather than slide
# Handoff slew state (see the handoff_slew_rate export). _handoff_slew_pending
# is armed by every trajectory-prediction → interpolation exit and consumed by
# the first _interpolate with buffer data, which seeds _slew_lead empirically
# (PuckHandoffRules.timeline_lead). While the lead is nonzero the puck renders
# AHEAD of the lag-comp rewind instant, so the optimistic pickup pin is gated
# off for the slew's duration (see try_provisional_pickup).
var _handoff_slew_pending: bool = false
var _slew_lead: float = 0.0

func get_buffer_depth() -> int:
	return _state_buffer.size()

func get_local_carrier() -> Skater:
	return _local_carrier_skater

func get_carrier_peer_id() -> int:
	return _carrier_peer_id

# Callable (Skater) -> int peer_id, or -1 if not registered.
var _peer_id_resolver: Callable = Callable()
# Callable () -> Array[Skater] of all active skaters. Host-only interaction detection.
var _skater_getter: Callable = Callable()
# Live Skater -> team_id dict owned by PlayerRegistry. Read in the
# host-side poke-check loop at the physics rate — used to be a Callable that
# internally scanned the player dict, which doubled up the cost.
var _team_id_by_skater: Dictionary = {}

# ── Signals (server-side puck events, GameManager listens) ───────────────────
signal puck_picked_up_by(peer_id: int)
signal puck_released_by_carrier(peer_id: int)
signal puck_stripped_from(peer_id: int)
signal puck_poke_checked_by(peer_id: int)  # defender who poke-stripped the carrier
signal puck_touched_while_loose(peer_id: int)  # deflection or body block — peer who touched
signal puck_touched_by_goalie(goalie: Goalie)  # puck contacted a goalie body while a shot was in flight

# ── Setup ─────────────────────────────────────────────────────────────────────
func setup(assigned_puck: Puck, assigned_is_server: bool) -> void:
	puck = assigned_puck
	is_server = assigned_is_server
	puck.set_server_mode(is_server)
	# Cooldown expiry timestamps share the host's local_time base (the same clock
	# StateBufferManager stamps rewind snapshots with) so is_on_cooldown_at can be
	# queried at a claimant's view-time. Injected here to keep the actor clock-agnostic.
	puck.set_time_provider(NetworkManager.local_time)
	process_physics_priority = 1  # Run after Skater.move_and_slide so blade world pos is current
	if is_server:
		puck.puck_released.connect(_on_puck_released)
		puck.puck_stripped.connect(_on_puck_stripped)
		puck.puck_touched_loose.connect(func(s: Skater) -> void: puck_touched_while_loose.emit(_peer_id_resolver.call(s)))
		puck.puck_body_blocked.connect(func(s: Skater) -> void: puck_touched_while_loose.emit(_peer_id_resolver.call(s)))
		puck.puck_touched_goalie.connect(func(g: Goalie) -> void: puck_touched_by_goalie.emit(g))
		# Dev + host only: EITHER the analytic drive OR the Phase-0/2 shadow
		# harnesses — never both. The harnesses measure the analytic model
		# against Jolt; with the drive on, "Jolt's" state IS the analytic sim,
		# so every digest would compare the model against itself (divergence
		# ≡ 0, ground truth = the drive's own signals) — measurement theater.
		# Flip the const to false for a measurement session against real Jolt.
		if BuildInfo.VERSION == "dev":
			if _ANALYTIC_DRIVE_IN_DEV:
				# Determinism migration: the analytic sim drives the loose puck.
				# The goalie provider is forwarded in set_goalie_provider.
				puck.set_analytic_drive_enabled(true)
			else:
				_shadow = PuckShadowComparator.new()
				puck.puck_hit_boards.connect(func() -> void: _shadow_board_contact = true)
				_goalie_shadow = GoalieCollisionShadow.new()
				puck.puck_touched_goalie.connect(_on_shadow_goalie_contact)
	else:
		puck.puck_touched_goalie.connect(_on_client_puck_hit_goalie)
		puck.puck_touched_post.connect(_on_client_puck_hit_post)

func set_peer_id_resolver(resolver: Callable) -> void:
	_peer_id_resolver = resolver

func set_skater_getter(getter: Callable) -> void:
	_skater_getter = getter

func set_team_id_by_skater(d: Dictionary) -> void:
	_team_id_by_skater = d


# Dev-only: a Callable returning the live Array[Goalie], for the Phase-2 proactive
# false-positive probe AND the analytic puck drive's goalie contact detection. Injected by
# GameManager; absent in release (neither runs). Forwarded to the puck so its host drive can
# detect goalie contacts.
func set_goalie_provider(provider: Callable) -> void:
	_goalie_provider = provider
	if puck != null:
		puck.set_goalie_provider(provider)

func _physics_process(delta: float) -> void:
	if puck == null:
		return
	if is_server:
		_check_interactions()
		_observe_shadow(delta)
		_prev_puck_pos = puck.get_puck_position()
		return
	# A despawned / demoted remote carrier drops the pin back to interpolation.
	if _remote_carrier_skater != null and not is_instance_valid(_remote_carrier_skater):
		_remote_carrier_skater = null
	# Drop an optimistic pin the instant it stops being legitimate: the puck went
	# dead (whistle/goal — host is about to reset it) or we got ghosted (offside —
	# can't hold the puck). Timeout/grant/steal are handled below and in the RPCs.
	if _provisional_carrier_skater != null and (puck.pickup_locked \
			or not is_instance_valid(_provisional_carrier_skater) \
			or _provisional_carrier_skater.is_ghost or _provisional_carrier_skater.is_knocked_down):
		_clear_provisional()
	if _local_carrier_skater != null:
		is_extrapolating = false
		_smooth_initialized = false
		_pin_puck_to_carrier(_local_carrier_skater, delta)
		if NetworkTelemetry.instance: NetworkTelemetry.instance.puck_mode = "pinned"
	elif _provisional_carrier_skater != null:
		if not is_instance_valid(_provisional_carrier_skater) or NetworkManager.local_time() > _provisional_deadline:
			# No host grant arrived in time (or the carrier despawned): roll back to
			# interpolation. The buffer stayed warm during the pin, so the hand-off
			# is seamless. This is the felt "grab, then lose it" — the host silently
			# declined the claim (no grant, no steal). The predicate gate above should
			# drive this toward zero; the counter proves it session-over-session.
			NetworkTelemetry.record_provisional_timeout()
			_clear_provisional()
			_interpolate(delta)
			if NetworkTelemetry.instance: NetworkTelemetry.instance.puck_mode = "interpolating"
		else:
			is_extrapolating = false
			_smooth_initialized = false
			_pin_puck_to_carrier(_provisional_carrier_skater, delta)
			if NetworkTelemetry.instance: NetworkTelemetry.instance.puck_mode = "pinned_provisional"
	elif _remote_carrier_skater != null:
		is_extrapolating = false
		_smooth_initialized = false
		_pin_puck_to_carrier(_remote_carrier_skater, delta)
		if NetworkTelemetry.instance: NetworkTelemetry.instance.puck_mode = "pinned_remote"
	elif not _predicting_trajectory:
		_interpolate(delta)
		if NetworkTelemetry.instance:
			# "interp_handoff" surfaces the post-shot slew in F3 so playtest can see
			# how long the timeline ease actually runs on a real link.
			NetworkTelemetry.instance.puck_mode = "interp_handoff" \
					if (_slew_lead > 0.0 or _handoff_slew_pending) else "interpolating"
	else:
		is_extrapolating = false
		_smooth_initialized = false
		if NetworkTelemetry.instance:
			# "post_contact" = inside the RTT wait window after a goalie/post hit
			# (goalie: frozen at the pad; post: still simulating the local bounce).
			NetworkTelemetry.instance.puck_mode = "post_contact" \
					if _post_contact_timer >= 0.0 else "predicting"
		if _post_contact_timer >= 0.0:
			_post_contact_timer -= delta
			if _post_contact_timer < 0.0:
				# Suppression window expired: buffer has post-bounce data. Hand back to
				# interpolation; the next _interpolate reseeds the position smoother from
				# the puck's held (goalie) or Jolt-simulated (post) spot and seeds the
				# render-time slew, so the timeline eases back to the interpolated past
				# instead of the puck jumping backward along its flight — off a goalie
				# freeze the seeded lead is ~0 (stationary puck) and the cross-track
				# smoother alone carries the puck out along the host's rebound line.
				_predicting_trajectory = false
				_handoff_slew_pending = true
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


# Lag-comp counterpart to apply_lag_comp_pickup for the deflect verdict: the
# claim's rewound state ran PuckReceptionRules.should_receive and decided the
# contact should redirect the puck, not corral it. Same idempotency philosophy —
# skip if the puck is now carried/locked, and skip if the present-time
# _check_interactions already deflected this contact (it sets deflect_cooldown,
# which is_on_cooldown reads), so a contact never deflects twice. The deflect
# itself recomputes from present puck velocity + blade pose, like every other
# deflect, so it stays on the one shared apply_blade_deflect path.
func apply_lag_comp_deflect(skater: Skater) -> void:
	if not is_instance_valid(skater) or puck.carrier != null or puck.pickup_locked:
		return
	if puck.is_on_cooldown(skater):
		return
	puck.apply_blade_deflect(skater)


# Called after PokeClaimResolver validates a client poke claim against the
# state buffer. Idempotency guards:
#   - carrier == null: a host-side _check_interactions detection beat us to
#     the strip, or the carrier released the puck. Skip.
#   - carrier == checker: claimant became the carrier between send and apply
#     (shouldn't happen — client gates on `puck.carrier != skater` — but
#     defend). Skip.
#   - carrier != expected_ex_carrier: the carrier changed between claim send
#     and apply (X → Z). The claimant intended to strip X, not Z; the action
#     isn't valid against Z. Skip.
func apply_lag_comp_poke(checker: Skater, expected_ex_carrier: Skater) -> void:
	if not is_instance_valid(checker) or puck.carrier == null:
		return
	if puck.carrier == checker:
		return
	if puck.carrier != expected_ex_carrier:
		return
	puck.apply_poke_check(checker)
	puck_poke_checked_by.emit(_peer_id_resolver.call(checker))


# Called after StickLiftClaimResolver validates a client stick-lift claim
# against the state buffer. Same idempotency guards as apply_lag_comp_poke
# (carrier null / claimant became carrier / carrier changed). On success the
# victim's blade is popped up and the puck is stripped via the poke path.
func apply_lag_comp_stick_lift(checker: Skater, expected_ex_carrier: Skater) -> void:
	if not is_instance_valid(checker) or puck.carrier == null:
		return
	if puck.carrier == checker:
		return
	if puck.carrier != expected_ex_carrier:
		return
	puck.carrier.force_blade_lift(STICK_LIFT_FORCED_LIFT_S)
	_processing_stick_lift = true
	puck.apply_stick_lift_strip(checker)
	_processing_stick_lift = false


func is_processing_stick_lift() -> bool:
	return _processing_stick_lift


# Two blades reach the same loose puck at once (near-simultaneous client claims,
# or two would-be corrallers on the host's present-time tick). Neither ever gets
# possession — the puck squirts free — but its heading is biased toward the
# stronger blade (the vector sum of the two blade momenta) and paced by that
# momentum; a true 50/50 pops out sideways like a pinched seed. All the math is in
# PuckCollisionRules.contested_pickup_velocity; the randomness (deadlock side +
# degenerate fallback) is supplied here so the rule stays deterministic/testable.
#
# Blade kinematics (raw per-tick velocity + world contact point) for BOTH
# contestants are passed in rather than read off the live skaters, so the claim
# path can supply each claimant's REWOUND blade — the kinematics they actually
# saw at their view-time — instead of present-time values sampled up to a contest
# window + RTT later. The host present-time path passes the live values, so the
# two scrambles resolve from the same shared rule on matching inputs. (Draw-crest
# substitution still reads the live skater — the retained faceoff peak isn't in
# the snapshot; see _contest_blade_velocity.)
func apply_contested_pickup(
		skater_a: Skater, skater_b: Skater,
		blade_vel_a: Vector3, blade_vel_b: Vector3,
		blade_pos_a: Vector3, blade_pos_b: Vector3) -> void:
	if not is_instance_valid(skater_a) or not is_instance_valid(skater_b):
		return
	var perp_sign: float = 1.0 if randf() > 0.5 else -1.0
	var fallback := Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0))
	puck.set_puck_velocity(PuckCollisionRules.contested_pickup_velocity(
			_contest_blade_velocity(skater_a, blade_vel_a),
			_contest_blade_velocity(skater_b, blade_vel_b),
			blade_pos_a, blade_pos_b,
			contest_min_speed, contest_max_speed,
			contest_deadlock_speed, contest_deadlock_threshold,
			perp_sign, fallback))
	puck.set_skater_cooldown(skater_a, puck.reattach_cooldown)
	puck.set_skater_cooldown(skater_b, puck.reattach_cooldown)
	# The draw is resolved — stop retaining the swipe crest so it can't leak into a
	# later contest (self-expiry backs this up if a center never reaches the puck).
	skater_a.end_draw_tracking()
	skater_b.end_draw_tracking()


# The blade momentum this skater contributes to a contested pickup. At a faceoff a
# center is draw-tracking, so we use its retained swipe crest scaled by how well the
# crest landed on the drop (a well-timed sweep wins decisively; a late stab is
# discounted). Anywhere else — a board scramble — nobody is tracking, so it's the
# `raw_blade_vel` the caller supplies: the live per-tick blade velocity on the host
# present-time path, or the claimant's rewound view-time blade velocity on the
# claim path. (The retained draw crest is host-live state, not snapshotted, so a
# faceoff contest reads it live even on the claim path — acceptable since it's a
# retained peak, not an instantaneous value.)
func _contest_blade_velocity(skater: Skater, raw_blade_vel: Vector3) -> Vector3:
	if not skater.is_draw_tracking():
		return raw_blade_vel
	var weight: float = FaceoffDrawRules.timing_weight(
			skater.draw_since_drop(), contest_draw_timing_miss_window,
			contest_draw_timing_bonus, contest_draw_timing_min_weight)
	return skater.draw_peak_velocity() * weight


# Scans for a SECOND skater that would corral the same loose puck this tick — the
# other half of a contest. Returns the first such skater (excluding `first`), or
# null. Same eligibility gauntlet as the main pickup loop, minus the deflect
# branches: a blade that would only tip the puck (lifted / deflect intent /
# too-fast-or-poorly-angled) isn't corralling, so it isn't a possession contest.
# Host present-time only, and only invoked at the rare instant a pickup is about
# to be granted, so it adds no per-tick cost on the common no-pickup path.
func _find_contesting_corraller(first: Skater, skaters: Array, puck_curr: Vector3, puck_airborne: bool) -> Skater:
	for skater: Skater in skaters:
		if skater == first or skater.is_ghost or skater.is_knocked_down or puck.is_on_cooldown(skater):
			continue
		if skater.current_shot_state == SkaterStateMachine.State.SHOT_BLOCKING \
				or skater.current_shot_state == SkaterStateMachine.State.FOLLOW_THROUGH:
			continue
		if skater.blade_up or skater.deflect_intent:
			continue
		if not PuckReceptionRules.blade_can_interact(skater.blade_up, puck_airborne):
			continue
		var blade_curr: Vector3 = skater.get_blade_contact_global()
		var blade_prev: Vector3 = skater.get_prev_blade_contact_global()
		if not PuckInteractionRules.check_pickup(_prev_puck_pos, puck_curr,
				blade_prev, blade_curr, PICKUP_RADIUS):
			continue
		var puck_vel: Vector3 = puck.get_puck_velocity()
		# Face normal opposes the approach in the RECEIVER'S frame — same
		# relative velocity the receive decision judges (see should_receive).
		var relative_vel: Vector3 = puck_vel - skater.velocity
		var blade_face_normal: Vector3 = skater.get_blade_face_normal(relative_vel)
		if PuckReceptionRules.should_receive(puck_vel, skater.velocity, blade_face_normal,
				puck.pickup_max_speed, puck.deflect_min_speed, puck.alignment_receive_bonus):
			return skater
	return null


# ── Server Interaction Detection ─────────────────────────────────────────────
func _check_interactions() -> void:
	if not _skater_getter.is_valid():
		return
	var puck_curr: Vector3 = puck.get_puck_position()
	var skaters: Array = _skater_getter.call()

	if puck.carrier != null:
		if not puck.pickup_locked:
			# Hoist the carrier team out of the loop — it's invariant
			# across all checkers and the lookup was being repeated.
			var carrier_team: int = _team_id_by_skater.get(puck.carrier, -1)
			var carrier_skater: Skater = puck.carrier
			for skater: Skater in skaters:
				if skater == puck.carrier or skater.is_ghost or skater.is_knocked_down:
					continue
				var checker_team: int = _team_id_by_skater.get(skater, -1)
				if not PuckCollisionRules.can_poke_check(carrier_team, checker_team):
					continue
				var blade_curr: Vector3 = skater.get_blade_contact_global()
				if skater.blade_up:
					# Stick lift: the attacker's lifted blade hooked under the
					# carrier's shaft pops their blade up and strips the puck. A
					# lifted blade pokes nothing the normal way (it's off the ice),
					# so it's stick-lift-or-skip for this checker.
					var vic_hand: Vector3 = carrier_skater.upper_body_to_global(carrier_skater.get_top_hand_position())
					if PuckInteractionRules.check_blade_under_stick(
							blade_curr, vic_hand, carrier_skater.get_blade_contact_global(),
							STICK_LIFT_RADIUS, STICK_LIFT_UNDER_MARGIN):
						carrier_skater.force_blade_lift(STICK_LIFT_FORCED_LIFT_S)
						_processing_stick_lift = true
						puck.apply_stick_lift_strip(skater)
						_processing_stick_lift = false
						break
					continue
				var blade_prev: Vector3 = skater.get_prev_blade_contact_global()
				if PuckInteractionRules.check_poke(_prev_puck_pos, puck_curr,
						blade_prev, blade_curr, POKE_RADIUS):
					puck.apply_poke_check(skater)
					puck_poke_checked_by.emit(_peer_id_resolver.call(skater))
					break
	else:
		if not puck.pickup_locked:
			# Body block first: a puck driven into a player's torso is absorbed/dampened before
			# any stick play. If one lands, the velocity changed this tick — skip the pickup pass.
			if _check_body_blocks(skaters, puck_curr):
				return
			# On-ice/off-ice gate is invariant across skaters this tick.
			var puck_airborne: bool = puck.is_airborne()
			for skater: Skater in skaters:
				if skater.is_ghost or skater.is_knocked_down or puck.is_on_cooldown(skater):
					continue
				# A crouched shot-blocker can't corral the puck with their stick —
				# the blade is committed to the block. Same for a shooter mid
				# follow-through: the stick is whipping through a finish, not
				# playing the puck (also closes the instant self-rebound
				# re-attach right after a shot). Let it ride past (body-block
				# dampening still applies via the body collision path).
				if skater.current_shot_state == SkaterStateMachine.State.SHOT_BLOCKING \
						or skater.current_shot_state == SkaterStateMachine.State.FOLLOW_THROUGH:
					continue
				# Reach gate — grounded blade ↔ grounded puck, lifted blade ↔
				# airborne puck. blade_up already encodes the deflect level's plane
				# (grounded at FLAT/LOW, lifted only at HIGH), so a committed deflect
				# and a passive receiver share this one gate: FLAT/LOW play the ice
				# (a saucer flies over), HIGH plays the air. The loft level changes
				# the redirect DIRECTION, not which plane it reaches.
				if not PuckReceptionRules.blade_can_interact(skater.blade_up, puck_airborne):
					continue
				var blade_curr: Vector3 = skater.get_blade_contact_global()
				var blade_prev: Vector3 = skater.get_prev_blade_contact_global()
				if not PuckInteractionRules.check_pickup(_prev_puck_pos, puck_curr,
						blade_prev, blade_curr, PICKUP_RADIUS):
					continue
				# A committed deflect (Q held, any reachable level) or a forced-up
				# blade (opponent stick-lift meeting an airborne puck) tips the puck
				# off the blade face — the SAME path a too-fast puck takes naturally,
				# bypassing the catch decision so even an otherwise-catchable puck is
				# redirected. The loft level signs the redirect (flat / up / down).
				if skater.deflect_intent or skater.blade_up:
					puck.apply_blade_deflect(skater)
					break
				var puck_vel: Vector3 = puck.get_puck_velocity()
				# Face normal opposes the approach in the RECEIVER'S frame — the
				# same relative velocity the receive decision judges.
				var relative_vel: Vector3 = puck_vel - skater.velocity
				var blade_face_normal: Vector3 = skater.get_blade_face_normal(relative_vel)
				if PuckReceptionRules.should_receive(
						puck_vel,
						skater.velocity,
						blade_face_normal,
						puck.pickup_max_speed,
						puck.deflect_min_speed,
						puck.alignment_receive_bonus):
					# If a second blade would ALSO corral this same tick (a faceoff
					# draw or a board scramble), it's a contest - nobody gets it, the
					# puck squirts free biased toward the stronger blade. Otherwise this
					# skater takes it. Mirrors the client-claim contest window; the scan
					# only runs at the rare moment a pickup would actually happen.
					var contender: Skater = _find_contesting_corraller(skater, skaters, puck_curr, puck_airborne)
					if contender != null:
						# Present-time contest — both blades are host-live this tick, so
						# feed their live kinematics (the claim path feeds rewound ones).
						apply_contested_pickup(skater, contender,
								skater.blade_world_velocity, contender.blade_world_velocity,
								skater.get_blade_contact_global(), contender.get_blade_contact_global())
					else:
						puck.set_carrier(skater)
						_on_puck_picked_up(skater)
				else:
					puck.apply_blade_deflect(skater)
				break


# Analytic body-block: a loose puck driven into a player's body CYLINDER is absorbed/dampened.
# The analytic replacement for the per-skater body-block Area3D — a swept segment-vs-vertical-
# cylinder test (so a fast puck can't tunnel through the torso), reading the skater's body
# cylinder (torso-band passive, ice-sealing shot-block crouch). Ghost skaters never block
# (matching the old Area mask); the body_block_cooldown de-dups the level-triggered test the
# way the Area's edge trigger did. Knocked-down players still block, as before. Returns true
# on the first block so the caller skips the pickup pass this tick.
func _check_body_blocks(skaters: Array, puck_curr: Vector3) -> bool:
	for skater: Skater in skaters:
		if skater.is_ghost or puck.is_on_cooldown(skater):
			continue
		var axis := Vector2(skater.global_position.x, skater.global_position.z)
		var reach: float = skater.get_body_block_radius() + GameRules.PUCK_COLLISION_RADIUS
		var y_range: Vector2 = skater.get_body_block_y_range()
		if PuckInteractionRules.check_body_block(
				_prev_puck_pos, puck_curr, axis, reach, y_range.x, y_range.y):
			puck.on_body_block(skater)
			return true
	return false


# ── Local Prediction ──────────────────────────────────────────────────────────
func notify_local_pickup(local_skater: Skater) -> void:
	_local_carrier_skater = local_skater
	_remote_carrier_skater = null
	# Host confirmed our pickup. If we were already provisionally pinned to this
	# same blade, this promotes it seamlessly (no visible change); otherwise it
	# attaches now.
	if _provisional_carrier_skater != null:
		NetworkTelemetry.record_provisional_confirmed()
	_clear_provisional()
	_clear_handoff_slew()
	_predicting_trajectory = false
	_post_contact_timer = -1.0
	puck.set_client_prediction_mode(false)
	_state_buffer.clear()


# A remote (non-local) player took possession. Pin the puck to their
# interpolated blade so it shares the carrier's render timeline instead of
# interpolating from its own buffer. Mirrors notify_local_pickup. GameManager
# only calls this for non-local carriers whose skater is spawned on this client.
func notify_remote_pickup(remote_skater: Skater) -> void:
	_remote_carrier_skater = remote_skater
	_local_carrier_skater = null
	if _provisional_carrier_skater != null:
		NetworkTelemetry.record_provisional_stolen()  # legit loss of a 50/50, not the felt bug
	_clear_provisional()  # a different player won the puck — roll back our optimistic pin
	_clear_handoff_slew()
	_predicting_trajectory = false
	_pending_local_release = false
	_pending_local_release_deadline = -1.0
	_post_contact_timer = -1.0
	puck.set_client_prediction_mode(false)
	_state_buffer.clear()

func notify_local_release(direction: Vector3, power: float, rtt_ms: float) -> Vector3:
	# PuckController (priority 1) runs after LocalController (priority 0), so the puck
	# hasn't been re-pinned to the current blade position yet this frame. Read blade
	# directly from the carrier so we start from the current-frame position, not last
	# frame's pin.
	# Returns the release origin (the blade contact point) so the caller can ship it
	# to the host in the release RPC — the host fires the authoritative puck from this
	# exact point instead of guessing it from a stale buffer rewind.
	var release_pos: Vector3 = puck.get_puck_position()
	if _local_carrier_skater != null:
		release_pos = _local_carrier_skater.get_blade_contact_global()
		release_pos.y = puck.ice_height
	_local_carrier_skater = null
	_arm_provisional_lockout()  # post-release reattach cooldown — don't optimistically re-grab
	_clear_handoff_slew()
	_predicting_trajectory = true
	_pending_local_release = true
	_pending_local_release_deadline = NetworkManager.local_time() + _PENDING_RELEASE_TIMEOUT_S
	_shot_rtt_ms = rtt_ms
	puck.set_client_prediction_mode(true)
	puck.set_goal_line_clamp(true)
	# Fire from the blade and predict forward — no forward advance. The host is
	# authoritative and fires from this same (client-sent) origin; the shooter's
	# three-zone reconcile (apply_state) projects the host broadcast forward by the
	# full RTT, so prediction and authority stay aligned without shoving the puck
	# ahead of the stick (which used to pop on the host / other clients and could
	# skip the puck into a close goalie or the boards).
	puck.set_puck_position(release_pos)
	puck.apply_release_velocity(direction * power)
	_state_buffer.clear()
	return release_pos

# Client-side prediction seed for a nudge — the self-tap counterpart to
# notify_local_release. Same trajectory-prediction handoff, but the puck takes
# the full controller-computed velocity (momentum + stick push) instead of
# direction × power, and the post-nudge re-grab lockout uses the short
# nudge_cooldown so the carrier can scoop it back up after the nutmeg.
func notify_local_nudge(velocity: Vector3, rtt_ms: float) -> void:
	var release_pos: Vector3 = puck.get_puck_position()
	if _local_carrier_skater != null:
		release_pos = _local_carrier_skater.get_blade_contact_global()
		release_pos.y = puck.ice_height
	_local_carrier_skater = null
	_arm_provisional_lockout(puck.nudge_cooldown)
	_clear_handoff_slew()
	_predicting_trajectory = true
	_pending_local_release = true
	_pending_local_release_deadline = NetworkManager.local_time() + _PENDING_RELEASE_TIMEOUT_S
	_shot_rtt_ms = rtt_ms
	puck.set_client_prediction_mode(true)
	puck.set_goal_line_clamp(true)
	puck.set_puck_position(release_pos)
	var v := velocity
	v.y = 0.0
	puck.apply_release_velocity(v)
	_state_buffer.clear()

func notify_remote_carrier_changed(new_carrier_peer_id: int) -> void:
	_pending_local_release = false
	_pending_local_release_deadline = -1.0
	# Guard: don't kill our own trajectory prediction — we initiated the release
	# locally and are soft-reconciling via world state.
	if new_carrier_peer_id == -1 and _predicting_trajectory:
		return
	_remote_carrier_skater = null
	_clear_provisional()
	_clear_handoff_slew()
	_predicting_trajectory = false
	_post_contact_timer = -1.0
	puck.set_client_prediction_mode(false)  # also clears _clamp_at_goal_line

# Called when the server forcibly ends a carry (e.g. goal scored).
# Does not start trajectory prediction — just drops back to interpolation.
func notify_local_puck_dropped() -> void:
	_local_carrier_skater = null
	_remote_carrier_skater = null
	_arm_provisional_lockout()  # we just lost the puck — host won't hand it back during reattach cooldown
	_clear_handoff_slew()
	_predicting_trajectory = false
	_pending_local_release = false
	_pending_local_release_deadline = -1.0
	_post_contact_timer = -1.0
	puck.set_client_prediction_mode(false)
	_state_buffer.clear()


# ── Optimistic (visual-only) pickup ──────────────────────────────────────────
# Called by LocalController when its blade enters pickup range of a loose puck.
# Pins the puck to the local blade immediately so the grab looks instant — but
# only when the host is overwhelmingly likely to GRANT A CATCH: the puck is
# grounded and slow enough to always be caught (never deflected), we're not in
# the post-loss reattach lockout, and no other skater is contesting on our
# rendered view. The speed gate reads ABSOLUTE puck speed even though the host's
# receive decision is receiver-relative: worst case the relative speed is
# absolute + max sprint (~8 + ~12.7), still under deflect_min_speed (22), so
# "below pickup_max_speed ⇒ host grants" holds at every attribute level. Visual only — the carry state machine engages on the host's
# confirming notify_local_pickup, not here.
func try_provisional_pickup(local_skater: Skater) -> void:
	if is_server or not is_instance_valid(local_skater):
		return
	# Already committed, or the puck isn't loose on our view.
	if _local_carrier_skater != null or _provisional_carrier_skater != null:
		return
	if _remote_carrier_skater != null or _predicting_trajectory:
		return
	# Mid handoff-slew the puck renders AHEAD of the lag-comp rewind instant
	# (render == rewind only holds at lead 0), so the host would validate this
	# grab against a puck behind where we reached — likely declining it. Skip
	# the optimistic pin for the slew's brief duration; a claim is still sent
	# by LocalController, it just isn't visually front-run.
	if _handoff_slew_pending or _slew_lead > 0.0:
		return
	if _provisional_lockout_until > 0.0 and NetworkManager.local_time() < _provisional_lockout_until:
		return
	if puck.is_airborne() or _estimated_puck_speed() >= puck.pickup_max_speed:
		return
	# Mid follow-through the stick can't corral (mirrors the host's pickup
	# gate) — don't pin a puck the host is guaranteed not to grant.
	if local_skater.current_shot_state == SkaterStateMachine.State.FOLLOW_THROUGH:
		return
	# Knocked down — can't corral the puck (mirrors the host's is_knocked_down gate).
	if local_skater.is_knocked_down:
		return
	if _is_pickup_contested(local_skater):
		return
	_provisional_carrier_skater = local_skater
	NetworkTelemetry.record_provisional_pin()
	# Grant travels ~1 RTT (claim out, confirm back) plus host processing; scale
	# the rollback deadline off RTT so a slow link doesn't pop the pin before the
	# confirm arrives.
	var window: float = maxf(_PROVISIONAL_TIMEOUT_S, NetworkManager.get_latest_rtt_ms() / 1000.0 * 2.0)
	_provisional_deadline = NetworkManager.local_time() + window
	puck.set_client_prediction_mode(false)  # ensure frozen; the pin drives position


func _is_pickup_contested(local_skater: Skater) -> bool:
	if not _skater_getter.is_valid():
		return true  # can't tell who's around → assume contested (conservative)
	var puck_pos: Vector3 = puck.get_puck_position()
	for s: Skater in _skater_getter.call():
		if s == local_skater or not is_instance_valid(s) or s.is_ghost or s.is_knocked_down:
			continue
		# Any other skater (either team) racing the same loose puck is a contest —
		# only one can be granted it. Their blade is interpolated, hence the
		# inflated radius.
		if s.get_blade_contact_global().distance_to(puck_pos) <= contest_danger_radius:
			return true
	return false


# Stage-4 loose-puck lead gate (see _interpolate): 1.0 in open ice — full forward
# lead, the puck sits at ~present coherent with the forward-predicted skaters —
# easing to 0.0 as ANY blade closes on the puck. Dropping the lead near a blade is
# what preserves render == rewind exactly where pickup/poke claims happen: the host
# rewinds the puck to the past interp instant, so the puck the claimant reaches for
# must be there too. The ease is subtle for the slow loose pucks pickups target
# (present-vs-past offset = puck_speed × interp_delay); a fast puck near a blade is a
# reception/deflect, host-authoritative anyway. ALL skaters (incl. local) count, so
# the local player's own grab regime is non-leading. Invalid getter → 0 (no lead,
# the render == rewind-safe fallback). Cheap value-type math, hot-path safe.
const _LEAD_DROP_NEAR_M: float = 0.7  # ≥ pickup reach: at claim range the lead is fully off
const _LEAD_DROP_FAR_M: float = 1.8   # beyond contest range: full lead
func _blade_lead_scale(puck_pos: Vector3) -> float:
	if not _skater_getter.is_valid():
		return 0.0
	var nearest_sq: float = INF
	for s: Skater in _skater_getter.call():
		if not is_instance_valid(s) or s.is_ghost:
			continue
		var d_sq: float = s.get_blade_contact_global().distance_squared_to(puck_pos)
		if d_sq < nearest_sq:
			nearest_sq = d_sq
	return smoothstep(_LEAD_DROP_NEAR_M, _LEAD_DROP_FAR_M, sqrt(nearest_sq))


# During interpolation the RigidBody is frozen (velocity ~0), so read the host's
# broadcast speed from the newest buffered snapshot. Empty buffer → no data yet,
# treat as fast so we stay conservative and skip the optimistic attach.
func _estimated_puck_speed() -> float:
	if _state_buffer.is_empty():
		return INF
	return _state_buffer.back().state.velocity.length()


# Feed the host's authoritative loose-puck state to the Phase-0 shadow comparator
# (dev-only; _shadow is null otherwise, so this is a cheap early return in release —
# though it's never even reached there since exported builds skip creation). Any freely-
# flying loose puck is in scope — grounded slides AND airborne flights (loft shots,
# saucer passes, glove rebounds), since step_puck_3d now models gravity. Only a carried
# or dead (pinned/frozen) puck resets the comparator so each flight re-seeds. Logs a
# one-line digest on a throttle. Never mutates the puck. `puck.linear_velocity` is
# authoritative here (host-side Jolt integration).
func _observe_shadow(delta: float) -> void:
	if _shadow == null:
		return
	# Puck-trajectory shadow (Phase 0): any freely-flying loose puck is in scope (grounded
	# or airborne) — only carried / dead (pinned) pucks reset it so each flight re-seeds.
	if puck.carrier != null or puck.pickup_locked:
		_shadow.reset()
	else:
		_shadow.observe(puck.get_puck_position(), puck.linear_velocity, _shadow_board_contact, delta)
	# Phase-2 proactive false-positive probe (consumes _shadow_goalie_contact as ground truth).
	_probe_goalie_false_positives()
	_shadow_board_contact = false
	_shadow_goalie_contact = false
	# Combined throttled digest (runs regardless of puck mode — the goalie harness records
	# contacts asynchronously via the signal, including airborne glove saves).
	_shadow_log_timer += delta
	if _shadow_log_timer >= _SHADOW_LOG_INTERVAL_S:
		_shadow_log_timer = 0.0
		if _shadow.samples > 0:
			# jolt_escapes reads ~0 (C1 rescues before we see it); the true rim-around
			# escape frequency is the puck's containment_rescue_count.
			print("[phase0] %s c1_rescues=%d" % [_shadow.summary(), puck.containment_rescue_count])
		if _goalie_shadow != null and _goalie_shadow.jolt_contacts > 0:
			print("[phase2] %s" % _goalie_shadow.summary())


# Phase-2 goalie-collision harness (dev + host): on Jolt's puck-vs-goalie contact, feed
# the analytic swept-disc-vs-goalie-OBBs detector the same swept segment + the part Jolt
# reported, so it records detection agreement / part-match / normal sanity.
func _on_shadow_goalie_contact(goalie: Goalie) -> void:
	if _goalie_shadow == null:
		return
	_shadow_goalie_contact = true  # ground truth for this tick's proactive probe
	_goalie_shadow.record_contact(goalie, puck.last_goalie_contact_body,
			_prev_puck_pos, puck.get_puck_position(), GameRules.PUCK_COLLISION_RADIUS)


# Phase-2 proactive false-positive probe (dev + host): every tick the loose puck is near a
# goalie, run the analytic swept test and compare to Jolt's ground truth for the tick
# (entry signal OR continuous overlap). Counts phantoms — analytic contacts Jolt didn't
# see. The near-goalie gate keeps this (and the get_colliding_bodies allocation) off the
# hot path unless the puck is actually by a net.
func _probe_goalie_false_positives() -> void:
	if _goalie_shadow == null or _goalie_provider.is_null():
		return
	if puck.carrier != null or puck.pickup_locked:
		return
	var goalies: Array = _goalie_provider.call()
	var pk: Vector3 = puck.get_puck_position()
	var near: bool = false
	for g: Node in goalies:
		var g3: Node3D = g as Node3D
		if g3 != null and g3.global_position.distance_to(pk) < _GOALIE_PROBE_RANGE_M:
			near = true
			break
	if not near:
		return
	# Ground truth: the entry signal (fast transit / CCD) OR continuous overlap (a puck
	# resting or sliding on the goalie, which fires no fresh body_entered).
	var jolt_contact: bool = _shadow_goalie_contact
	if not jolt_contact:
		for body: Node in puck.get_colliding_bodies():
			if _body_belongs_to_a_goalie(body, goalies):
				jolt_contact = true
				break
	_goalie_shadow.probe(goalies, _prev_puck_pos, pk, GameRules.PUCK_COLLISION_RADIUS, jolt_contact)


# True if `body` is (or is under) one of the goalie nodes — Jolt reports the goalie's
# StaticBody3D part, which sits beneath the Goalie node. Compares by identity per goalie
# rather than `body in goalies`: `goalies` is a TypedArray[Goalie], and `in` / find() on it
# validates the needle's type, throwing on a plain Node (the StaticBody3D part we walk up).
static func _body_belongs_to_a_goalie(body: Node, goalies: Array) -> bool:
	for g: Node in goalies:
		if g == null:
			continue
		var n: Node = body
		while n != null:
			if n == g:
				return true
			n = n.get_parent()
	return false


func _clear_provisional() -> void:
	_provisional_carrier_skater = null
	_provisional_deadline = -1.0


# Drops any in-progress (or pending) handoff slew. Called whenever the puck
# leaves free interpolation for a pin / reset / fresh prediction, so a stale
# render-time lead can never leak into the next interpolation stretch.
func _clear_handoff_slew() -> void:
	_handoff_slew_pending = false
	_slew_lead = 0.0


func _arm_provisional_lockout(duration: float = -1.0) -> void:
	var d: float = duration if duration >= 0.0 else puck.reattach_cooldown
	_provisional_lockout_until = NetworkManager.local_time() + d
	_clear_provisional()

func _pin_puck_to_carrier(carrier: Skater, delta: float) -> void:
	# Smooth puck toward the carrier's carry target each tick. Shared by the local
	# carry and the remote-carrier pin. The lerp damps rapid blade movements so the
	# puck feels weighty during stickhandling rather than teleporting instantly to
	# the blade tip. Carry target is the un-offset contact (= cursor position on the
	# owning client) so the puck stays under the cursor while the blade renders to
	# the forehand or backhand side; on a remote skater the forehand factor is 0 so
	# it cleanly reduces to the interpolated blade contact.
	var contact: Vector3 = carrier.get_carry_target_global()
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
	# Freeze-and-wait: a locally simulated rebound off a goalie is essentially
	# always wrong — the rendered goalie sits interp_delay + RTT/2 in the past,
	# and the host's outcome isn't raw restitution anyway (GoalieSaveRules
	# deadens chest contacts, holds glove catches, steers pad rebounds
	# cornerward — controller logic this client doesn't run), so letting Jolt
	# play our own bounce animates a rebound that's wrong in KIND, then has to
	# be corrected. Instead the puck holds at the contact point ("stuck in the
	# pads") while the window below waits out the round trip for the host's
	# authoritative post-bounce data; the slewed handoff then carries it out
	# along the true line — and if the host actually deadened/smothered it, the
	# freeze already IS the correct visual. Window sizing: our predicted bounce
	# leads the host's by ~RTT/2 and the first post-bounce snapshot takes
	# another RTT/2 to arrive, so RTT + one broadcast of slack is the earliest
	# the buffer can hold the truth. Ending prediction immediately instead
	# would blend toward pre-bounce buffer positions — the puck would slide
	# backward into the goalie and replay the save.
	_pending_local_release = false
	_pending_local_release_deadline = -1.0
	_post_contact_timer = NetworkManager.get_latest_rtt_ms() / 1000.0 + 0.025
	puck.set_client_prediction_mode(false)  # freeze at the pad; velocity zeroed

func _on_client_puck_hit_post() -> void:
	if not _predicting_trajectory or _post_contact_timer >= 0.0:
		return
	# Post bounces deliberately KEEP simulating through the window (unlike the
	# goalie freeze above): the post is static geometry and both sims run
	# identical Jolt from the same client-sent origin, so the local rebound
	# usually IS the host's — freezing would add a pointless hold to a bounce
	# we can predict. The window still suppresses reconcile so pre-bounce
	# snapshots can't drag the puck back into the post; a razor-edge graze
	# that genuinely diverged lands in the zone-2 slewed handoff instead.
	_pending_local_release = false
	_pending_local_release_deadline = -1.0
	_post_contact_timer = NetworkManager.get_latest_rtt_ms() / 1000.0 + 0.025

# ── State Serialization ───────────────────────────────────────────────────────
# Returns the typed network state object. Flattening to Array happens at the
# RPC boundary (GameManager.get_world_state), not here.
func get_state() -> PuckNetworkState:
	var state := PuckNetworkState.new()
	fill_state(state)
	return state

# Caller-owned-instance variant for the per-tick StateBufferManager capture.
func fill_state(state: PuckNetworkState) -> void:
	state.position = puck.get_puck_position()
	state.velocity = puck.get_puck_velocity()
	state.carrier_peer_id = _carrier_peer_id

func apply_state(state: PuckNetworkState, host_ts: float) -> void:
	if is_server:
		return
	# Force-clear pending release if both the confirming snapshot and the
	# post-contact handlers (goalie/post bounce) failed to fire within the
	# deadline. Without this clear, apply_state's early returns below would
	# leave the puck stuck in pending-release mode indefinitely.
	if _pending_local_release and _pending_local_release_deadline > 0.0 \
			and NetworkManager.local_time() > _pending_local_release_deadline:
		_pending_local_release = false
		_pending_local_release_deadline = -1.0
	if _local_carrier_skater != null:
		return  # Puck is pinned to local blade; interpolation isn't running
	# Remote-carrier pin: the rendered position is driven by the pin in
	# _physics_process, but we keep buffering host snapshots below (prediction is
	# false while pinned, so control falls through) so the buffer stays warm. The
	# instant the carrier releases or is stripped, interpolation has fresh bracket
	# data and hands off with no refill freeze — and since the remote blade is
	# itself interpolated, the pinned puck and the buffered timeline share a render
	# time, so there's no pop at the transition.
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
			return
		else:
			var release_confirmed: bool = false
			if _pending_local_release:
				_pending_local_release = false
				_pending_local_release_deadline = -1.0
				release_confirmed = true
			var rtt_s: float = _shot_rtt_ms / 1000.0
			# Apply ice friction to the latency-corrected target so it matches
			# Jolt's deceleration over the RTT projection window (same shape as
			# `_interpolate()` extrapolation at line ~416). Without this the
			# target overshoots the actual host position by ~0.5 * a * rtt²,
			# visible as a slight forward bias on long shots at high RTT before
			# the soft blend pulls it back.
			var friction_vel: Vector3 = _ice_friction_velocity(state.velocity, rtt_s)
			var latency_corrected := PuckNetworkState.new()
			latency_corrected.position = state.position + friction_vel * rtt_s
			latency_corrected.velocity = friction_vel
			# Client and host run identical Jolt from the same (client-sent) release
			# origin — no release-time advance on either side — so small errors are
			# RTT jitter; blending toward a noisy target creates visible snapback.
			# Only hard-snap on genuine physics divergence (wall/goalie bounce
			# that differed between client and host).
			var dist: float = puck.get_puck_position().distance_to(latency_corrected.position)
			# Shot-launch divergence probe: the first host-confirmed broadcast after a
			# local release measures client-predicted vs host-authoritative launch. Both
			# run identical Jolt from the same client-sent origin, so this should be tiny
			# (RTT jitter); a spike is genuine launch divergence, and it separates
			# shot-launch causes from bounce/contact within the puck_hard_snaps total.
			if release_confirmed:
				NetworkTelemetry.record_shot_launch_divergence(
						dist, puck.get_puck_velocity().distance_to(latency_corrected.velocity))
			if dist > trajectory_hard_snap_threshold:
				# Zone 2 — genuine physics divergence (a wall/goalie bounce that
				# differed between client and host): the local sim is wrong from here
				# on, and teleporting the puck backward mid-flight is the most jarring
				# artifact a shot can produce. Exit prediction into the slewed
				# interpolation handoff instead: this broadcast seeds the buffer (fall
				# through to the append below), and the render-time slew + cross-track
				# smoother walk the rendered puck onto the authoritative trajectory
				# moving FORWARD in time (see PuckHandoffRules).
				_predicting_trajectory = false
				_post_contact_timer = -1.0
				_handoff_slew_pending = true
				puck.set_client_prediction_mode(false)
				NetworkTelemetry.record_puck_trajectory_zone(2)
			elif dist > trajectory_soft_blend_threshold:
				# Medium divergence: velocity-only blend, no position change.
				puck.set_puck_velocity(puck.get_puck_velocity().lerp(latency_corrected.velocity, 0.15))
				NetworkTelemetry.record_puck_trajectory_zone(1)
				return  # Don't buffer during prediction; interpolation isn't running
			else:
				# Small divergence (RTT jitter): soft position blend + velocity blend.
				puck.set_puck_position(puck.get_puck_position().lerp(latency_corrected.position, position_correction_blend))
				puck.set_puck_velocity(puck.get_puck_velocity().lerp(latency_corrected.velocity, 0.15))
				NetworkTelemetry.record_puck_trajectory_zone(0)
				return  # Don't buffer during prediction; interpolation isn't running
	if not _state_buffer.is_empty() and host_ts < _state_buffer.back().timestamp:
		return
	var buffered := BufferedPuckState.new()
	buffered.timestamp = host_ts
	buffered.state = state
	_state_buffer.append(buffered)
	if _state_buffer.size() > 30:
		_state_buffer.pop_front()

# Coulomb ice friction: a puck on ice loses a fixed amount of speed per second
# (mu*g = GameRules.PUCK_ICE_DECEL_M_S2), independent of speed — matching the host's
# Jolt physics material. The previous viscous model (speed × factor) decelerated
# ~100x too hard at game speeds, so extrapolated / latency-corrected pucks lagged
# the host. Horizontal in practice (a grounded puck's velocity is planar).
func _ice_friction_velocity(vel: Vector3, dt: float) -> Vector3:
	var speed: float = vel.length()
	if speed < 0.0001:
		return vel
	var new_speed: float = maxf(0.0, speed - GameRules.PUCK_ICE_DECEL_M_S2 * dt)
	return vel * (new_speed / speed)


func _interpolate(delta: float) -> void:
	# Shared delay keeps the loose puck on the skaters' timeline (render == the
	# lag-comp rewind instant at extrapolation_lead_fraction 0 — see the export).
	var interp_delay: float = NetworkManager.get_interpolation_delay()
	# Stage-4 loose-puck forward lead (own constant, parked at 0.0 — see
	# Constants.PUCK_FORWARD_LEAD_FRACTION for why it is decoupled from the
	# skater fraction): when > 0 the loose puck leads toward present with the
	# skaters, easing to 0 as any blade closes on the puck (_blade_lead_scale) —
	# that is what keeps render == rewind exactly where pickup/poke claims fire
	# (the host rewinds the puck to the past interp instant, so the puck the
	# claimant reached for must render there too). No host-side change: the puck
	# is at past whenever a claim can happen. The ice-friction dead-reckon +
	# board gate below produce the lead. 0 = legacy interpolate-in-the-past.
	var lead_fraction: float = Constants.PUCK_FORWARD_LEAD_FRACTION
	if lead_fraction > 0.0:
		lead_fraction *= _blade_lead_scale(puck.get_puck_position())
	var base_render_time: float = NetworkManager.estimated_host_time() \
			- interp_delay * (1.0 - lead_fraction)
	# Handoff slew: on a fresh entry from trajectory prediction, seed a temporary
	# render-time lead that lines the first interp target up with the live
	# (predicted) puck, then shed it at handoff_slew_rate — the timeline eases
	# back to the interpolated past instead of the puck jumping backward along
	# its flight. Seeding waits for buffer data (the newest sample defines the
	# host trajectory the live position is projected onto); rate < 1 keeps
	# render_time monotonically increasing while the lead decays.
	if _handoff_slew_pending:
		if _state_buffer.is_empty():
			return  # keep the pending seed armed until host data arrives
		_handoff_slew_pending = false
		var newest: BufferedPuckState = _state_buffer.back()
		_slew_lead = PuckHandoffRules.timeline_lead(
				puck.get_puck_position(), newest.state.position, newest.state.velocity,
				newest.timestamp, base_render_time, handoff_max_lead_s, _HANDOFF_MIN_SPEED)
	elif _slew_lead > 0.0:
		_slew_lead = maxf(_slew_lead - handoff_slew_rate * delta, 0.0)
	var render_time: float = base_render_time + _slew_lead
	var bracket: BufferedStateInterpolator.BracketResult = BufferedStateInterpolator.find_bracket(
			_state_buffer, render_time, _scratch_bracket)
	# Slew frames extrapolate past the newest sample BY DESIGN (the lead starts
	# ~RTT/2 + interp_delay ahead of the interp point); keep them out of the
	# is_extrapolating canary, which exists to catch genuine buffer underruns.
	# Slew frames AND stage-4 lead frames extrapolate past the newest sample BY
	# DESIGN — keep both out of the underrun canary (it exists to catch genuine
	# buffer starvation; at a non-zero puck lead it would otherwise saturate at
	# ~100% and poison the F3 extrapolation_pct telemetry).
	is_extrapolating = bracket != null and bracket.is_extrapolating \
			and _slew_lead <= 0.0 and lead_fraction <= 0.0
	if bracket == null:
		return
	# Reused scratch (per-tick path); both branches write position + velocity,
	# the only fields _apply_state_to_puck consumes.
	var interpolated := _scratch_interp
	if bracket.is_extrapolating:
		# The slew lead extends the dead-reckon cap: during the handoff the render
		# point sits up to _slew_lead beyond the newest sample on purpose.
		var dt: float = minf(bracket.extrapolation_dt, extrapolation_max_ms / 1000.0 + _slew_lead)
		var newest: PuckNetworkState = bracket.to_state
		# Decay velocity to approximate ice friction so the extrapolated position
		# matches Jolt's deceleration rather than linear dead-reckoning overshoot.
		var friction_vel: Vector3 = _ice_friction_velocity(newest.velocity, dt)
		var projected: Vector3 = newest.position + friction_vel * dt
		# Smart extrapolation: only dead-reckon forward when the puck won't cross a
		# board this frame. Projecting THROUGH a board overshoots outside the rink,
		# then snaps back when the host's reflected samples land. Predicting the
		# bounce client-side would risk disagreeing with the host's authoritative
		# restitution/angle, so instead we just stop leading when a board is in the
		# way — hold at the newest authoritative position until the post-bounce
		# trajectory streams in. Boards only; goalie/net/skater bounces still lean
		# on the SmoothDamp below.
		if stop_extrapolation_at_boards and _crosses_board(projected):
			# Hold at the last authoritative spot and report zero velocity so the
			# feed-forward smoother below doesn't nudge the held puck on toward the board.
			interpolated.position = newest.position
			interpolated.velocity = Vector3.ZERO
		else:
			interpolated.position = projected
			interpolated.velocity = friction_vel
	else:
		var from_state: PuckNetworkState = bracket.from_state
		var to_state: PuckNetworkState = bracket.to_state
		interpolated.position = BufferedStateInterpolator.hermite(from_state.position, from_state.velocity,
				to_state.position, to_state.velocity, bracket.t, bracket.bracket_dt)
		interpolated.velocity = from_state.velocity.lerp(to_state.velocity, bracket.t)
	# Velocity-feed-forward error smoothing on the rendered puck position. Advancing
	# by the target's own velocity gives zero steady-state lag (smoothing the absolute
	# position trails a fast puck by ~velocity × smooth_time — metres on a shot/pass);
	# only the residual error is critically damped. On a fresh entry into interpolation
	# (carry / trajectory / extrap → loose) seed from the puck's live spot so the seam
	# blends; a pathological gap snaps.
	var target_pos: Vector3 = interpolated.position
	if not _smooth_initialized:
		_smooth_pos = puck.get_puck_position()
		_smooth_vel = Vector3.ZERO
		_smooth_initialized = true
	# Velocity-aware snap guard (PuckHandoffRules): only CROSS-track error at the
	# snap distance means the rendered trajectory is genuinely wrong; along-track
	# error up to velocity × _ALONG_SNAP_TIME_S is an expected timeline offset
	# (the slew's job) and must not teleport a fast puck. At rest (resets,
	# faceoffs) it degrades to the plain distance check.
	if PuckHandoffRules.needs_hard_snap(target_pos - _smooth_pos, interpolated.velocity,
			_SMOOTH_SNAP_DIST, _ALONG_SNAP_TIME_S, _HANDOFF_MIN_SPEED):
		_smooth_pos = target_pos
		_smooth_vel = Vector3.ZERO
	else:
		_smooth_pos += interpolated.velocity * delta
		_smooth_pos = _smooth_damp(_smooth_pos, target_pos, position_smooth_time, delta)
	interpolated.position = _smooth_pos
	_apply_state_to_puck(interpolated)
	# Prune against the un-led PAST instant (est_host − full interp_delay), NOT
	# render_time: with a stage-4 lead (or the handoff slew) active, render_time
	# runs up to interp_delay ahead of the past instant, and pruning at the led
	# time discards exactly the samples the buffer needs when the blade-eased
	# lead collapses back toward the past — find_bracket would return null and
	# the rendered puck froze for the collapse window. The un-led time is the
	# minimum any future frame can request (lead and slew are both ≥ 0), so
	# pruning there is always safe.
	BufferedStateInterpolator.drop_stale(
			_state_buffer, NetworkManager.estimated_host_time() - interp_delay)


# True when world position `p` (XZ) lies outside the inner board boundary — i.e.
# a straight dead-reckon to here would have crossed a board (bounced). Uses the
# same rounded-rect projection as the puck-OOB / blade-clamp callers, so the
# corners are handled exactly.
func _crosses_board(p: Vector3) -> bool:
	var xz := Vector2(p.x, p.z)
	return GameRules.clamp_to_rink_inner(xz).distance_squared_to(xz) > 1e-6


# Unity-style critically damped smoothing toward a (possibly moving) target.
# Mutates _smooth_vel; returns the new position. Pure value-type math — no alloc.
# (Duplicated from RemoteController; hoist to a shared helper if a third caller
# appears — kept inline to avoid a per-tick out-param allocation on the hot path.)
func _smooth_damp(current: Vector3, target: Vector3, smooth_time: float, dt: float) -> Vector3:
	var omega: float = 2.0 / maxf(smooth_time, 0.0001)
	var x: float = omega * dt
	var exp_factor: float = 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x)
	var change: Vector3 = current - target
	var temp: Vector3 = (_smooth_vel + change * omega) * dt
	_smooth_vel = (_smooth_vel - temp * omega) * exp_factor
	return target + (change + temp) * exp_factor

func _apply_state_to_puck(state: PuckNetworkState) -> void:
	# Position only — puck is frozen during interpolation, Jolt ignores velocity.
	puck.set_puck_position(state.position)
