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
# Below this speed (m/s) the along-track decomposition in PuckHandoffRules is
# meaningless: the smoother's snap guard falls back to the plain distance
# check (covers faceoff/goal-reset teleports, at rest), and a triggered snap
# isn't counted as divergence telemetry (resets are legitimate teleports).
const _HANDOFF_MIN_SPEED: float = 2.0
# Along-track smoother error is tolerated up to velocity × this window before
# snapping — the expected timeline offset across the release-seed → snapshot
# prediction seam, which the SmoothDamp tail (not a teleport) absorbs.
const _ALONG_SNAP_TIME_S: float = 0.3
# Critically-damped smoothing time (s) for the loose-puck position. Slightly above
# the skater's so bounce overshoot blends out cleanly.
@export var position_smooth_time: float = 0.06
# Smart extrapolation: when the forward dead-reckon would carry the puck across a
# board within the lead window, stop leading for that frame and hold at the newest
# authoritative position instead of projecting through the boards (see _interpolate).
@export var stop_extrapolation_at_boards: bool = true
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
# Client-side carrier VIEW (peer id, -1 = loose), driven EXCLUSIVELY by the
# carrier events — pickup grant / carrier-changed / steal / drop, arriving via
# reliable RPC or the snapshot event block — never by world state (unreliable
# ordering vs locally-predicted transitions). This is what LocalController's
# claim gate branches on: puck.carrier is HOST-only (never set on clients), so
# gating on it left the poke/stick-lift claim path unreachable and re-fired
# pickup claims against a carried puck for entire carries.
var _client_carrier_peer_id: int = -1
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
# ── Release seed (Phase 4b) ──────────────────────────────────────────────────
# A local release/nudge seeds the loose-puck prediction from the client's own
# release instant instead of waiting for a host snapshot: while active,
# _predict_loose runs the shared analytic sim forward from (seed pos, vel,
# stamp) rather than from the newest buffered snapshot — which still shows the
# puck carried until the host processes our release ~one-way later. The seed
# hands over to normal snapshot prediction the moment the newest snapshot is
# BOTH loose (carrier == -1) and stamped at/after the seed (the host's view of
# this same release), measuring shot-launch divergence at that handover. The
# timeout is the deep-loss escape hatch: if no confirming snapshot ever lands
# (host never got the release, or we lost every broadcast), fall back to
# whatever the buffer says rather than predicting a shot the host never fired.
var _release_seed_active: bool = false
var _release_seed_stamp: float = 0.0      # estimated_host_time() at the release
var _release_seed_pos: Vector3 = Vector3.ZERO
var _release_seed_vel: Vector3 = Vector3.ZERO
const _RELEASE_SEED_TIMEOUT_S: float = 0.5  # ~2× worst healthy RTT + broadcast interval
var is_extrapolating: bool = false

# Returns Array[Goalie]: feeds the host drive's contact detection (forwarded to
# the puck in set_goalie_provider) and the client prediction's goalie stop.
var _goalie_provider: Callable = Callable()
# ── Phase-3/4b loose-puck prediction scratch (client only; see _predict_loose) ──
var _predict_frame_scratch: PuckGeometryCollision.Result = null
var _predict_tick_result: PuckAuthorityRules.TickResult = null
# NativePuckStep (null = extension absent, GDScript step). Same factory as the
# host drive's instance, so prediction and authority run the identical step.
var _native_step: RefCounted = null
# Per-re-predict goalie-box gather scratches (GoalieContactDetector
# .gather_boxes) — reused so the per-frame predictor allocates nothing.
var _gather_packed := PackedFloat32Array()
var _gather_parts: Array = []
var _gather_goalies: Array = []
# Scratch for the reachable-end goalie filter in _run_prediction — reused per frame.
var _reachable_goalies: Array = []
# Shared read-only empty (const arrays are frozen): the no-goalie-reachable default
# on every mid-ice re-predict, instead of allocating a fresh `[]` per frame.
const _NO_GOALIES: Array = []
var _predict_goalie_contact: GoalieContactDetector.Contact = null
var _predict_obb_scratch: SweptDiscOBB.Result = null
# _run_prediction's output slots (filled per call; members so the per-frame
# prediction allocates nothing and the seed-handover probe can reuse the loop).
var _sim_pos: Vector3 = Vector3.ZERO
var _sim_vel: Vector3 = Vector3.ZERO
var _sim_stopped: bool = false
# Cross-frame latches for the predicted contact cues. The prediction is a
# stateless re-predict from the newest snapshot every frame, so one physical
# contact stays inside the re-simulated span (and keeps being re-detected) for
# ~a one-way trip until a post-contact snapshot advances the base — up to
# PUCK_PREDICT_MAX_S under loss. Mirroring the host drive's cross-tick contact
# latches, a cue fires only on the rising edge: this frame's span contains the
# contact class, last frame's didn't. A gap in prediction coverage (carry pin,
# whistle, fallback interpolation) resets the latches so the first contact of
# the next loose flight isn't eaten by a stale latch.
var _pred_cue_post_prev: bool = false
var _pred_cue_net_prev: bool = false
var _pred_cue_boards_prev: bool = false
var _pred_cue_goalie_prev: bool = false
var _pred_cue_frame_ms: int = -10_000
const _PRED_CUE_STALE_MS: int = 250
# Scoped true only while a stick-lift strip is being applied, so the synchronous
# puck_stripped_from handlers (sound + victim notify) can tell a stick lift apart
# from a poke/body-check strip and pick the right cue. Read via
# is_processing_stick_lift(); always reset immediately after apply_stick_lift_strip.
var _processing_stick_lift: bool = false

# Reused scratch objects for the per-tick interpolation lookup + output.
var _scratch_bracket := BufferedStateInterpolator.BracketResult.new()
var _scratch_interp := PuckNetworkState.new()
# Critically-damped position smoother for the loose puck (see
# _smooth_apply_and_prune). Reseeded from the puck's live position on every
# fresh entry into the loose modes (carry / pin → loose), so it blends those
# seams instead of snapping — subsumes the former rejoin-blend.
var _smooth_pos: Vector3 = Vector3.ZERO
var _smooth_vel: Vector3 = Vector3.ZERO
var _smooth_initialized: bool = false
const _SMOOTH_SNAP_DIST: float = 2.0  # pathological gap → snap rather than slide

func get_buffer_depth() -> int:
	return _state_buffer.size()

func get_local_carrier() -> Skater:
	return _local_carrier_skater

func get_carrier_peer_id() -> int:
	return _carrier_peer_id

# Client-side carrier view (see _client_carrier_peer_id). -1 = loose/unknown.
func get_client_carrier_peer_id() -> int:
	return _client_carrier_peer_id

# The carrier's Skater on this client's view, when spawned locally: the pinned
# remote carrier or the local skater. Null while loose, or when the carrier's
# skater isn't available here (unspawned record) — callers that need geometry
# (poke/stick-lift aim) must handle null.
func get_client_carrier_skater() -> Skater:
	if _local_carrier_skater != null and is_instance_valid(_local_carrier_skater):
		return _local_carrier_skater
	if _remote_carrier_skater != null and is_instance_valid(_remote_carrier_skater):
		return _remote_carrier_skater
	return null

# Callable (Skater) -> int peer_id, or -1 if not registered.
var _peer_id_resolver: Callable = Callable()
# Host-only. Callable (grabber: Skater, grabber_peer_id: int, blade_pos: Vector3,
# blade_vel: Vector3, now: float) -> bool — PickupClaimResolver.arbitrate_present_grab,
# wired by GameManager. Consulted at the present-time pickup grant moment so a
# pending lag-comp claim contests the grab by STAMP instead of always losing to
# whichever blade is host-live (the "host wins every 50/50" hole). True = the
# resolver consumed the grab (contest squirt / pending granted) — don't set carrier.
var _present_grab_arbiter: Callable = Callable()


func set_present_grab_arbiter(arbiter: Callable) -> void:
	_present_grab_arbiter = arbiter
# Callable () -> Array[Skater] of all active skaters. Host-only interaction detection.
var _skater_getter: Callable = Callable()
# Live Skater -> team_id dict owned by PlayerRegistry. Read in the
# host-side poke-check loop at the physics rate — used to be a Callable that
# internally scanned the player dict, which doubled up the cost.
var _team_id_by_skater: Dictionary = {}

# ── Signals (server-side puck events, GameManager listens) ───────────────────
signal puck_picked_up_by(peer_id: int)
signal puck_released_by_carrier(peer_id: int)
# `peer_id` is the dispossessed carrier; `stripper_peer_id` is the defender who
# took the puck (poke / stick-lift / body-check), or -1 when a goalie stripped
# it. Stat attribution credits the takeaway to the stripper.
signal puck_stripped_from(peer_id: int, stripper_peer_id: int)
signal puck_poke_checked_by(peer_id: int)  # defender who poke-stripped the carrier
signal puck_touched_while_loose(peer_id: int)  # deflection or body block — peer who touched
signal puck_touched_by_goalie(goalie: Goalie)  # puck contacted a goalie body while a shot was in flight

# ── Signals (client-only predicted contact cues, GameManager plays sound/VFX) ──
# Fired from the loose-puck prediction the instant the predicted flight rings a
# post / thumps the net frame / caroms off the boards / meets a goalie. Without
# these the only cue is the host's broadcast, which lands ~RTT late and can be
# lost outright — so the client would hear its own post ping a beat after seeing
# it. Emission is edge-latched across frames (the stateless
# re-predict re-detects the same contact every frame until the snapshot base
# passes it — see the _pred_cue_*_prev latches in _run_prediction) and the
# host's broadcast of the same contact is echo-suppressed in GameManager
# (_cue_is_echo).
signal predicted_post_contact(position: Vector3, speed: float)
signal predicted_net_contact(position: Vector3, speed: float)
signal predicted_board_contact(position: Vector3, speed: float)
signal predicted_goalie_contact(position: Vector3, speed: float)

# ── Setup ─────────────────────────────────────────────────────────────────────
func setup(assigned_puck: Puck, assigned_is_server: bool) -> void:
	puck = assigned_puck
	is_server = assigned_is_server
	puck.set_server_mode(is_server)
	# Cooldown expiry timestamps share the host's local_time base (the same clock
	# StateBufferManager stamps rewind snapshots with) so is_on_cooldown_at can be
	# queried at a claimant's view-time. Injected here to keep the actor clock-agnostic.
	puck.set_time_provider(NetworkManager.local_time)
	process_physics_priority = 1  # Run after Skater's integration so blade world pos is current
	if is_server:
		puck.puck_released.connect(_on_puck_released)
		puck.puck_stripped.connect(_on_puck_stripped)
		puck.puck_touched_loose.connect(func(s: Skater) -> void: puck_touched_while_loose.emit(_peer_id_resolver.call(s)))
		puck.puck_body_blocked.connect(func(s: Skater) -> void: puck_touched_while_loose.emit(_peer_id_resolver.call(s)))
		puck.puck_touched_goalie.connect(func(g: Goalie) -> void: puck_touched_by_goalie.emit(g))
		# The analytic sim IS the authority for the loose puck on every host —
		# the puck's own _physics_process drives it (the goalie provider is
		# forwarded in set_goalie_provider). This is what lets clients run the
		# same sim predictively.
	else:
		# Phase-3/4b prediction scratch (built once; the loose-puck predictor —
		# which also carries the shooter's own release via the seed — runs per
		# physics frame and must allocate nothing). No contact-signal wiring:
		# the client puck has no physics body (it's a plain Node3D) — contacts
		# are detected analytically inside the prediction loop itself.
		_predict_frame_scratch = PuckGeometryCollision.Result.new()
		_predict_tick_result = PuckAuthorityRules.TickResult.new()
		_predict_goalie_contact = GoalieContactDetector.Contact.new()
		_predict_obb_scratch = SweptDiscOBB.Result.new()
		_native_step = NativePuckStepFactory.make_configured()

func set_peer_id_resolver(resolver: Callable) -> void:
	_peer_id_resolver = resolver

func set_skater_getter(getter: Callable) -> void:
	_skater_getter = getter

func set_team_id_by_skater(d: Dictionary) -> void:
	_team_id_by_skater = d


# A Callable returning the live Array[Goalie], for the analytic puck drive's goalie
# contact detection (host) and the client prediction's goalie stop. Injected by
# GameManager; forwarded to the puck so its host drive can detect goalie contacts.
func set_goalie_provider(provider: Callable) -> void:
	_goalie_provider = provider
	if puck != null:
		puck.set_goalie_provider(provider)

func _physics_process(delta: float) -> void:
	if puck == null:
		return
	if is_server:
		var t0: int = Time.get_ticks_usec()
		_check_interactions()
		_prev_puck_pos = puck.get_puck_position()
		HostCostProbe.record(HostCostProbe.Section.PUCK_PHYS, Time.get_ticks_usec() - t0)
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
	# Same freed-object guard as the remote/provisional pins: a despawn/demote
	# that lands before the carrier-drop notification must not dereference a
	# freed skater for the gap frame.
	if _local_carrier_skater != null and not is_instance_valid(_local_carrier_skater):
		_local_carrier_skater = null
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
	else:
		# Phase-3/4b: ONE predicted mode for every loose puck — including the
		# shooter's own shot, which _predict_loose runs from the local release
		# seed until the host's snapshots catch up. The interpolated past is
		# the fallback for stale data (deep loss) / clock warmup.
		if not _predict_loose(delta):
			_interpolate(delta)
			if NetworkTelemetry.instance:
				NetworkTelemetry.instance.puck_mode = "interpolating"

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
func _find_contesting_corraller(first: Skater, skaters: Array, puck_curr: Vector3,
		puck_airborne: bool, now: float) -> Skater:
	for skater: Skater in skaters:
		if skater == first or skater.is_ghost or skater.is_knocked_down \
				or puck.is_on_cooldown_at(skater, now):
			continue
		if skater.current_shot_state == SkaterStateMachine.State.SHOT_BLOCKING \
				or skater.current_shot_state == SkaterStateMachine.State.FOLLOW_THROUGH:
			continue
		# blade_up / deflect_intent already withdraw the stick; a committed body-check
		# does the same (stick off the ice — no corral).
		if skater.blade_up or skater.deflect_intent or skater.hit_committed:
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
		# Deflect ceiling + squared bonus lean with the RECEIVER's blade curve
		# (Skater.reception_ceiling_mult); the always-catches floor does not.
		if PuckReceptionRules.should_receive(puck_vel, skater.velocity, blade_face_normal,
				puck.pickup_max_speed,
				puck.deflect_min_speed * skater.reception_ceiling_mult,
				puck.alignment_receive_bonus * skater.reception_ceiling_mult):
			return skater
	return null


# ── Server Interaction Detection ─────────────────────────────────────────────
func _check_interactions() -> void:
	if not _skater_getter.is_valid():
		return
	var puck_curr: Vector3 = puck.get_puck_position()
	var skaters: Array = _skater_getter.call()
	# One clock sample serves every cooldown gate this tick — is_on_cooldown()
	# re-called the injected time provider per skater per loop.
	var now: float = NetworkManager.local_time()

	if puck.carrier != null:
		if not puck.pickup_locked:
			# Hoist the carrier team out of the loop — it's invariant
			# across all checkers and the lookup was being repeated.
			var carrier_team: int = _team_id_by_skater.get(puck.carrier, -1)
			var carrier_skater: Skater = puck.carrier
			# Carrier pose is likewise invariant across checkers this tick (a
			# strip/poke breaks the loop) — hoisted out of the stick-lift test.
			var carrier_hand: Vector3 = carrier_skater.upper_body_to_global(
					carrier_skater.get_top_hand_position())
			var carrier_blade: Vector3 = carrier_skater.get_blade_contact_global()
			for skater: Skater in skaters:
				if skater == puck.carrier or skater.is_ghost or skater.is_knocked_down:
					continue
				var checker_team: int = _team_id_by_skater.get(skater, -1)
				if not PuckCollisionRules.can_poke_check(carrier_team, checker_team):
					continue
				# Committed to a body check — the stick is off the ice, so no poke
				# (nor stick-lift). It's the body or nothing; matches the loose-puck
				# withdrawal gates and the claim/provisional paths.
				if skater.hit_committed:
					continue
				# A committed shot block is the same bargain: the blade is
				# choreographed flat across the lane and stops tracking the cursor,
				# so it takes nothing off a carrier who skates into it. Blocking
				# buys the body cylinder and the lane, not a free strip.
				if skater.current_shot_state == SkaterStateMachine.State.SHOT_BLOCKING:
					continue
				var blade_curr: Vector3 = skater.get_blade_contact_global()
				if skater.blade_up:
					# Stick lift: the attacker's lifted blade hooked under the
					# carrier's shaft pops their blade up and strips the puck. A
					# lifted blade pokes nothing the normal way (it's off the ice),
					# so it's stick-lift-or-skip for this checker.
					if PuckInteractionRules.check_blade_under_stick(
							blade_curr, carrier_hand, carrier_blade,
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
			if _check_body_blocks(skaters, puck_curr, now):
				return
			# On-ice/off-ice gate is invariant across skaters this tick.
			var puck_airborne: bool = puck.is_airborne()
			for skater: Skater in skaters:
				if skater.is_ghost or skater.is_knocked_down or puck.is_on_cooldown_at(skater, now):
					continue
				# Committed to a body check — the stick is off the ice, so no
				# corral/receive (mirrors the poke + claim + provisional gates).
				if skater.hit_committed:
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
						puck.deflect_min_speed * skater.reception_ceiling_mult,
						puck.alignment_receive_bonus * skater.reception_ceiling_mult):
					# If a second blade would ALSO corral this same tick (a faceoff
					# draw or a board scramble), it's a contest - nobody gets it, the
					# puck squirts free biased toward the stronger blade. Otherwise this
					# skater takes it. Mirrors the client-claim contest window; the scan
					# only runs at the rare moment a pickup would actually happen.
					var contender: Skater = _find_contesting_corraller(
							skater, skaters, puck_curr, puck_airborne, now)
					if contender != null:
						# Present-time contest — both blades are host-live this tick, so
						# feed their live kinematics (the claim path feeds rewound ones).
						apply_contested_pickup(skater, contender,
								skater.blade_world_velocity, contender.blade_world_velocity,
								skater.get_blade_contact_global(), contender.get_blade_contact_global())
					elif _present_grab_arbiter.is_valid() and _present_grab_arbiter.call(
							skater,
							_peer_id_resolver.call(skater) if _peer_id_resolver.is_valid() else -1,
							skater.get_blade_contact_global(), skater.blade_world_velocity,
							NetworkManager.local_time()):
						# A pending lag-comp claim contested (or won) this grab by
						# stamp — the resolver applied the outcome; no carrier here.
						pass
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
func _check_body_blocks(skaters: Array, puck_curr: Vector3, now: float) -> bool:
	for skater: Skater in skaters:
		if skater.is_ghost or puck.is_on_cooldown_at(skater, now):
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
	# Fresh attach re-arms the slapshot-pin snap (see _pin_puck_to_carrier):
	# a one-timer is picked up straight INTO the charge, with no ordinary carry
	# tick in between to clear the latch.
	_was_slapshot_pinned = false
	_local_carrier_skater = local_skater
	_remote_carrier_skater = null
	_client_carrier_peer_id = NetworkManager.local_peer_id()
	# Host confirmed our pickup. If we were already provisionally pinned to this
	# same blade, this promotes it seamlessly (no visible change); otherwise it
	# attaches now.
	if _provisional_carrier_skater != null:
		NetworkTelemetry.record_provisional_confirmed()
	_clear_provisional()
	_release_seed_active = false
	_state_buffer.clear()


# A remote (non-local) player took possession. Pin the puck to their
# interpolated blade so it shares the carrier's render timeline instead of
# interpolating from its own buffer. Mirrors notify_local_pickup. GameManager
# only calls this for non-local carriers whose skater is spawned on this client.
func notify_remote_pickup(remote_skater: Skater, carrier_peer_id: int) -> void:
	# Fresh attach re-arms the slapshot-pin snap (see _pin_puck_to_carrier):
	# a one-timer is picked up straight INTO the charge, with no ordinary carry
	# tick in between to clear the latch.
	_was_slapshot_pinned = false
	_remote_carrier_skater = remote_skater
	_local_carrier_skater = null
	_client_carrier_peer_id = carrier_peer_id
	if _provisional_carrier_skater != null:
		NetworkTelemetry.record_provisional_stolen()  # legit loss of a 50/50, not the felt bug
	_clear_provisional()  # a different player won the puck — roll back our optimistic pin
	_release_seed_active = false
	_state_buffer.clear()

func notify_local_release(direction: Vector3, power: float) -> Vector3:
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
	_client_carrier_peer_id = -1
	_arm_provisional_lockout()  # post-release reattach cooldown — don't optimistically re-grab
	# Fire from the blade and seed the shared loose-puck prediction — no forward
	# advance. The host is authoritative and fires from this same (client-sent)
	# origin at its own release tick; _predict_loose runs the seed forward on the
	# shared solver until the host's confirming snapshot takes over, so
	# prediction and authority stay aligned without shoving the puck ahead of
	# the stick.
	puck.set_puck_position(release_pos)
	puck.set_puck_velocity(direction * power)
	_seed_release_prediction(release_pos, direction * power)
	return release_pos

# Client-side prediction seed for a nudge — the self-tap counterpart to
# notify_local_release. Same release-seed handoff, but the puck takes the full
# controller-computed velocity (momentum + stick push) instead of direction ×
# power, and the post-nudge re-grab lockout uses the short nudge_cooldown so
# the carrier can scoop it back up after the nutmeg.
func notify_local_nudge(velocity: Vector3) -> void:
	var release_pos: Vector3 = puck.get_puck_position()
	if _local_carrier_skater != null:
		release_pos = _local_carrier_skater.get_blade_contact_global()
		release_pos.y = puck.ice_height
	_local_carrier_skater = null
	_client_carrier_peer_id = -1
	_arm_provisional_lockout(puck.nudge_cooldown)
	var v := velocity
	v.y = 0.0
	puck.set_puck_position(release_pos)
	puck.set_puck_velocity(v)
	_seed_release_prediction(release_pos, v)

# Shared tail of the two local-release paths: arm the release seed so
# _predict_loose predicts this flight from OUR release instant while the
# still-carried (pre-release) snapshots stream in, and clear the buffer — every
# buffered sample predates the release by construction (the newest still shows
# us carrying), and the seed → snapshot handover keys on the first fresh loose
# snapshot arriving after this stamp.
func _seed_release_prediction(pos: Vector3, vel: Vector3) -> void:
	_release_seed_active = true
	_release_seed_stamp = NetworkManager.estimated_host_time()
	_release_seed_pos = pos
	_release_seed_vel = vel
	_state_buffer.clear()

func notify_remote_carrier_changed(new_carrier_peer_id: int) -> void:
	# A confirmed carrier obsoletes any live release seed (someone holds the
	# puck we thought was in flight). A change TO loose (-1) leaves the seed
	# alone — that's the host confirming our own release, and the seed hands
	# over on the snapshot timeline (see _predict_loose), not on this RPC.
	if new_carrier_peer_id != -1:
		_release_seed_active = false
	_remote_carrier_skater = null
	_client_carrier_peer_id = new_carrier_peer_id
	_clear_provisional()

# Called when the server forcibly ends a carry (e.g. goal scored).
# Does not seed release prediction — just drops back to the loose-puck path.
func notify_local_puck_dropped() -> void:
	_local_carrier_skater = null
	_remote_carrier_skater = null
	_client_carrier_peer_id = -1
	_arm_provisional_lockout()  # we just lost the puck — host won't hand it back during reattach cooldown
	_release_seed_active = false
	_state_buffer.clear()


# Host NACK'd our pickup claim (stamp reject, geometry miss, deflect verdict,
# contest loss) — roll the optimistic pin back immediately instead of waiting
# out the RTT-scaled timeout. Same felt outcome as the timeout (host declined),
# so it shares the provisional_timeouts counter; arriving sooner is the point.
func notify_claim_rejected() -> void:
	if is_server or _provisional_carrier_skater == null:
		return
	NetworkTelemetry.record_provisional_timeout()
	_clear_provisional()


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
	if _remote_carrier_skater != null or _release_seed_active:
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
	# Committed to a body check — stick's off the ice (mirrors the host's
	# hit_committed pickup gate), so don't pin a puck the host won't grant.
	if local_skater.hit_committed:
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


# During interpolation the RigidBody is frozen (velocity ~0), so read the host's
# broadcast speed from the newest buffered snapshot. Empty buffer → no data yet,
# treat as fast so we stay conservative and skip the optimistic attach.
func _estimated_puck_speed() -> float:
	if _state_buffer.is_empty():
		return INF
	return _state_buffer.back().state.velocity.length()


# Rising-edge latch for the slapshot pin, so the carry smoother is reseeded once
# on entry instead of filtering across a discrete relocation. See
# _pin_puck_to_carrier.
var _was_slapshot_pinned: bool = false


func _clear_provisional() -> void:
	_provisional_carrier_skater = null
	_provisional_deadline = -1.0


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
	# SNAP ON THE SLAPSHOT PIN, don't smooth into it. Entering a slapper charge
	# relocates the carry target ~1.2 m in one tick — from the blade contact to the
	# fixed slapper-zone offset — and that is a discrete MODE CHANGE, not the rapid
	# blade movement this smoother exists to damp. Filtered, the puck instead
	# SLIDES across the ice on its own for a few tenths while the shooter stands
	# still, and every consumer reading puck position during the wind-up sees a
	# threat that is moving when nothing is.
	#
	# The goalie is the one that showed it: he reads `puck.global_position` to
	# price whether a shot is answerable, and his block threshold sits at
	# gap > 4.9 m. Measured live, the transit walked the gap 4.33 -> 5.64 m, so he
	# dropped on the pre-pin position, watched the puck drift past his threshold,
	# and stood back out of a committed butterfly — "he drops, backs up a bit, then
	# gets back up", from a standstill. The puck also never fires from any of those
	# intermediate spots: Puck.release reads the pin itself.
	#
	# Same convention the loose-mode smoother already follows (reseed on every
	# fresh mode entry rather than filtering across it).
	if carrier.is_slapshot_pinning() and not _was_slapshot_pinned:
		puck.set_puck_position(contact)
	else:
		puck.set_puck_position(puck.get_puck_position().lerp(contact, carry_smoothing_speed * delta))
	_was_slapshot_pinned = carrier.is_slapshot_pinning()

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

func _on_puck_stripped(ex_carrier: Skater, checker: Skater) -> void:
	var peer_id: int = _resolve_peer_id(ex_carrier)
	if peer_id == -1:
		return
	# checker is null for a goalie strip — resolve to -1 (no player takeaway).
	var stripper_peer_id: int = _resolve_peer_id(checker) if checker != null else -1
	puck_stripped_from.emit(peer_id, stripper_peer_id)

func _resolve_peer_id(skater: Skater) -> int:
	if skater == null or not _peer_id_resolver.is_valid():
		return -1
	return _peer_id_resolver.call(skater)

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
	if _local_carrier_skater != null:
		return  # Puck is pinned to local blade; the loose-puck paths aren't running
	# Everything else buffers unconditionally — this is JUST the snapshot intake.
	# Remote/provisional pins keep the buffer warm across the pin (the instant
	# the carrier releases, prediction has fresh data and hands off with no
	# refill freeze), and a live release seed watches the buffer for the host's
	# confirming loose snapshot (the seed → snapshot handover in _predict_loose),
	# so buffering during the seed is what makes the handover possible.
	if not _state_buffer.is_empty() and host_ts < _state_buffer.back().timestamp:
		return
	# Once the buffer is full, the evicted front entry becomes the new back one
	# rather than being dropped for a fresh allocation — so the wrapper churn
	# stops after the first 30 packets instead of running for the whole match.
	# Safe because no consumer holds a wrapper across frames: the interpolation
	# bracket is re-derived from the buffer every tick before it is read.
	var buffered: BufferedPuckState
	if _state_buffer.size() >= 30:
		buffered = _state_buffer.pop_front()
	else:
		buffered = BufferedPuckState.new()
	buffered.timestamp = host_ts
	buffered.state = state
	_state_buffer.append(buffered)

# Coulomb ice friction: a puck on ice loses a fixed amount of speed per second
# (mu*g = GameRules.PUCK_ICE_DECEL_M_S2), independent of speed — matching the host's
# analytic ice friction. The previous viscous model (speed × factor) decelerated
# ~100x too hard at game speeds, so extrapolated / latency-corrected pucks lagged
# the host. Horizontal in practice (a grounded puck's velocity is planar).
func _ice_friction_velocity(vel: Vector3, dt: float) -> Vector3:
	var speed: float = vel.length()
	if speed < 0.0001:
		return vel
	var new_speed: float = maxf(0.0, speed - GameRules.PUCK_ICE_DECEL_M_S2 * dt)
	return vel * (new_speed / speed)


# ── Phase-3/4b: client-side loose-puck prediction (the RL-family payoff) ─────
# Run the SAME analytic sim the host drives the puck with
# (PuckAuthorityRules.step_frame_substep — integration, friction, gravity,
# boards, goal frame) forward to this client's estimate of host present, every
# frame. Stateless re-predict: each frame starts over from the source state, so
# host-side events the client couldn't know (deflects, blade touches, new
# shots) are incorporated the moment their snapshot lands — the "reconcile" is
# implicit and the residual is absorbed by the shared SmoothDamp tail.
#
# The source is normally the newest authoritative snapshot. The one exception
# is the shooter's own release (Phase 4b): for the ~one-way trip until the
# host's snapshots reflect it, the source is the LOCAL RELEASE SEED — the
# client-fired origin + velocity at the release instant — because every
# buffered snapshot still shows the puck carried. The host fires the
# authoritative shot from this same client-sent origin, so the seed and the
# incoming authority are the same flight; the handover to snapshot prediction
# is an ordinary along-track seam the snap-guarded smoother absorbs, measured
# by the shot-launch divergence probe.
#
# Static geometry agrees with the host by construction (shared step); the
# GOALIE is a prediction STOP — hold at the detected contact, velocity zeroed,
# until authoritative snapshots reveal the save outcome (the save is a host
# decision; predicting a rebound would re-derive it — the ghost-save lesson).
# Returns false when prediction isn't possible (no data / stale snapshot) —
# caller falls back to the legacy interpolation path.
func _predict_loose(delta: float) -> bool:
	var now: float = NetworkManager.estimated_host_time()
	if _release_seed_active:
		var confirmed: BufferedPuckState = null
		if not _state_buffer.is_empty():
			var newest: BufferedPuckState = _state_buffer.back()
			if newest.state.carrier_peer_id == -1 and newest.timestamp >= _release_seed_stamp:
				confirmed = newest
		if confirmed != null:
			# Handover: the host's snapshots now carry this same flight. Measure
			# the launch divergence — seed-predicted position at the snapshot's
			# own instant vs the authoritative snapshot. Both sides fired from
			# the same client-sent origin on the same solver, so this should be
			# small (clock estimate error × puck speed); a spike is genuine
			# launch divergence. Then fall through to snapshot prediction.
			_run_prediction(_release_seed_pos, _release_seed_vel,
					maxf(confirmed.timestamp - _release_seed_stamp, 0.0))
			NetworkTelemetry.record_shot_launch_divergence(
					(_sim_pos - confirmed.state.position).length(),
					(_sim_vel - confirmed.state.velocity).length())
			_release_seed_active = false
		elif now - _release_seed_stamp > _RELEASE_SEED_TIMEOUT_S:
			# No confirming snapshot inside the window (deep loss, or the host
			# never processed the release) — stop trusting the seed and let the
			# buffer (or the interpolation fallback) drive.
			_release_seed_active = false
		else:
			_run_prediction(_release_seed_pos, _release_seed_vel,
					maxf(now - _release_seed_stamp, 0.0))
			is_extrapolating = false
			if NetworkTelemetry.instance:
				NetworkTelemetry.instance.puck_mode = "predicted_hold" if _sim_stopped else "predicted_seed"
			_record_predict_residual(_sim_pos)
			_smooth_apply_and_prune(_sim_pos, _sim_vel, delta, NetworkManager.get_interpolation_delay())
			return true
	if _state_buffer.is_empty():
		return false
	var source: BufferedPuckState = _state_buffer.back()
	var age: float = now - source.timestamp
	if age < 0.0 or age > Constants.PUCK_PREDICT_MAX_S:
		if age > Constants.PUCK_PREDICT_MAX_S:
			NetworkTelemetry.record_puck_predict_fallback()
		return false
	_run_prediction(source.state.position, source.state.velocity, age)
	is_extrapolating = false  # prediction is the mode, not a buffer underrun
	if NetworkTelemetry.instance:
		NetworkTelemetry.instance.puck_mode = "predicted_hold" if _sim_stopped else "predicted"
	_record_predict_residual(_sim_pos)
	_smooth_apply_and_prune(_sim_pos, _sim_vel, delta, NetworkManager.get_interpolation_delay())
	return true


# Goalies whose end the predicted span can actually reach — the client-side twin
# of the host drive's same-end filter (Puck._drive_analytic). The per-tick range
# gate below is near-EITHER-goal-line, so without this the goalie ~55 m away gets
# all ~8 of its boxes swept on every predicted tick, and its parts are gathered
# even on a re-predict that never leaves centre ice.
#
# A goalie at end sign `s` can only be contacted while `pos.z * s > thresh`, and
# over the span `pos.z * s` never exceeds `start_pos.z * s + travel`. `travel` is
# an over-estimate — the puck starts at its fastest (ice friction and the speed
# clamp only slow it, board caroms only reverse it) and the vertical component of
# the speed buys no z — so no reachable goalie can be culled.
func _reachable_goalies_for(goalies: Array, start_pos: Vector3, start_vel: Vector3,
		age: float) -> Array:
	var thresh: float = GameRules.GOAL_LINE_Z - PuckAuthorityRules.GOALIE_DETECT_RANGE_Z
	var travel: float = start_vel.length() * age
	_reachable_goalies.clear()
	for g: Node3D in goalies:
		if g == null:
			continue
		if start_pos.z * signf(g.global_position.z) + travel > thresh:
			_reachable_goalies.append(g)
	return _reachable_goalies


# The shared prediction loop: advance (start_pos, start_vel) forward `age`
# seconds on the host's analytic solver, writing the outcome to _sim_pos /
# _sim_vel / _sim_stopped (members, not a return — this runs per frame and
# must allocate nothing). Whole host ticks first, then a sub-tick velocity
# remainder so the render doesn't quantize to the tick grid.
func _run_prediction(start_pos: Vector3, start_vel: Vector3, age: float) -> void:
	var dt: float = 1.0 / float(Constants.PHYSICS_TICK)
	var ticks: int = floori(age * float(Constants.PHYSICS_TICK))
	var frac: float = age - float(ticks) * dt
	var pos: Vector3 = start_pos
	var vel: Vector3 = start_vel
	var radius: float = GameRules.PUCK_COLLISION_RADIUS
	var goalies: Array = _NO_GOALIES
	if not _goalie_provider.is_null():
		goalies = _reachable_goalies_for(_goalie_provider.call(), start_pos, start_vel, age)
	# Gather the goalie boxes ONCE per re-predict for the native fast path —
	# the rendered goalie pose is fixed for this frame, and the legacy path
	# re-read the engine properties per predicted tick.
	var goalie_box_count: int = 0
	if not goalies.is_empty() and GoalieContactDetector.native_available():
		goalie_box_count = GoalieContactDetector.gather_boxes(
				goalies, _gather_packed, _gather_parts, _gather_goalies)
	var stopped: bool = false
	# Predicted-cue latch upkeep: a gap since the last re-predict means a new
	# loose span (carry pin / whistle / fallback interpolation in between) —
	# clear the cross-frame latches so the next flight's first contact fires.
	var now_ms: int = Time.get_ticks_msec()
	if now_ms - _pred_cue_frame_ms > _PRED_CUE_STALE_MS:
		_pred_cue_post_prev = false
		_pred_cue_net_prev = false
		_pred_cue_boards_prev = false
		_pred_cue_goalie_prev = false
	_pred_cue_frame_ms = now_ms
	# Span-wide contact occurrence (any tick of THIS re-predict), compared
	# against last frame's span by the latches above to fire each cue once.
	var span_post: bool = false
	var span_net: bool = false
	var span_boards: bool = false
	var span_goalie: bool = false
	for _t in ticks:
		var tick_prev: Vector3 = pos
		var tick_vel_in: Vector3 = vel
		var tick_post: bool = false
		var tick_net: bool = false
		if _native_step != null:
			# The whole sub-stepped tick crosses the boundary once — the shape
			# the per-frame re-predict multiplies (age ticks x up to 16 substeps).
			_native_step.clear_touched()
			_native_step.step_tick(pos, vel, dt, radius,
					puck.max_speed, puck.ice_height, puck.max_height)
			pos = _native_step.get_position()
			vel = _native_step.get_velocity()
			tick_post = _native_step.get_touched_post()
			tick_net = _native_step.get_touched_net()
		else:
			var substeps: int = PuckAuthorityRules.frame_substeps(pos.z, vel.length(), dt)
			var sub_dt: float = dt / float(substeps)
			for _sub in substeps:
				_predict_tick_result.touched_post = false
				_predict_tick_result.touched_net = false
				PuckAuthorityRules.step_frame_substep(pos, vel, sub_dt, radius,
						puck.max_speed, puck.ice_height, puck.max_height,
						_predict_frame_scratch, _predict_tick_result)
				pos = _predict_tick_result.position
				vel = _predict_tick_result.velocity
				if _predict_tick_result.touched_post:
					tick_post = true
				if _predict_tick_result.touched_net:
					tick_net = true
		if tick_post and not span_post:
			span_post = true
			if not _pred_cue_post_prev:
				predicted_post_contact.emit(pos, vel.length())
		# Net gate mirrors the host drive: only a puck arriving with real pace
		# (>= 1 m/s) reads as a net-frame thump.
		if tick_net and not span_net and tick_vel_in.length() >= 1.0:
			span_net = true
			if not _pred_cue_net_prev:
				predicted_net_contact.emit(pos, vel.length())
		# Board carom: the host's own feedback read — the raw (un-reflected)
		# full-tick XZ position crossing the inner boundary with into-board
		# pace (see Puck._drive_analytic's touched_boards).
		if not span_boards and tick_vel_in.length() >= 1.0:
			var raw := Vector2(tick_prev.x + tick_vel_in.x * dt, tick_prev.z + tick_vel_in.z * dt)
			if raw.distance_to(GameRules.clamp_to_rink_inner(raw)) > 0.001:
				span_boards = true
				if not _pred_cue_boards_prev:
					predicted_board_contact.emit(pos, vel.length())
		# Goalie stop: tested over the tick's chord (cheaper than the host's
		# per-sub-step interleave; the stop is cosmetic holding, not a response,
		# so chord-level timing is enough). The goalie pose used is the client's
		# RENDERED (interpolated) goalie — approximate by nature, which is
		# exactly why the response is never predicted, only the hold.
		var pred_goalie_hit: bool = false
		if not goalies.is_empty() \
				and absf(pos.z) > GameRules.GOAL_LINE_Z - PuckAuthorityRules.GOALIE_DETECT_RANGE_Z:
			if goalie_box_count > 0:
				pred_goalie_hit = GoalieContactDetector.nearest_packed(
						_gather_packed, goalie_box_count, _gather_parts, _gather_goalies,
						tick_prev, pos, radius, _predict_goalie_contact)
			elif not GoalieContactDetector.native_available():
				pred_goalie_hit = GoalieContactDetector.nearest(goalies, tick_prev, pos,
						radius, _predict_obb_scratch, _predict_goalie_contact)
		if pred_goalie_hit:
			pos = _predict_goalie_contact.point \
					+ _predict_goalie_contact.normal * _predict_goalie_contact.depth
			span_goalie = true
			# Cue speed is the INCOMING pace (the hold zeroes vel, and the save
			# outcome — deaden vs live rebound — is host-only), so a hard shot
			# into the pads thuds like one instead of always playing the floor.
			if not _pred_cue_goalie_prev:
				predicted_goalie_contact.emit(pos, tick_vel_in.length())
			vel = Vector3.ZERO
			stopped = true
			break
	_pred_cue_post_prev = span_post
	_pred_cue_net_prev = span_net
	_pred_cue_boards_prev = span_boards
	_pred_cue_goalie_prev = span_goalie
	if not stopped and frac > 0.0:
		# The sub-tick remainder runs through the SAME solver as the whole ticks,
		# sub-stepped the same way — it is just a partial tick. It used to be a raw
		# `pos += vel * frac` lead with an after-the-fact rink clamp, which bypassed
		# every collision the step resolves: at 33 m/s the remainder is ~0.28 m, so
		# an approach frame could render the puck through a board (clamped back, but
		# only for the boards) or inside a post / the net panels.
		if _native_step != null:
			_native_step.step_tick(pos, vel, frac, radius,
					puck.max_speed, puck.ice_height, puck.max_height)
			pos = _native_step.get_position()
			vel = _native_step.get_velocity()
		else:
			var rem_steps: int = PuckAuthorityRules.frame_substeps(pos.z, vel.length(), frac)
			var rem_dt: float = frac / float(rem_steps)
			for _r in rem_steps:
				PuckAuthorityRules.step_frame_substep(pos, vel, rem_dt, radius,
						puck.max_speed, puck.ice_height, puck.max_height,
						_predict_frame_scratch, _predict_tick_result)
				pos = _predict_tick_result.position
				vel = _predict_tick_result.velocity
	# No goal prediction, for ANY predicted puck: park an inbound puck on the
	# goal line inside the posts and let the authoritative outcome arrive (the
	# goal horn is a host decision, like the save).
	#
	# Gated on the predicted center actually being INSIDE THE NET (_inside_net — the
	# shared GoalDetectionRules cavity definition), not merely "past the goal line
	# within the post width". That laxer test also matched the whole band BEHIND the
	# net (the back frame sits only NET_DEPTH past the line; there is ~2.2 m of ice
	# from there to the end boards, at every x), so a puck rimmed, dumped or carried
	# behind the cage with any outbound z-component got teleported forward onto the
	# goal line INSIDE the mouth: on clients only, the rendered puck jumped into the
	# net — past _SMOOTH_SNAP_DIST it hard-snapped there — and sat in it while the
	# host had it behind the net and awarded nothing.
	if pos.z * vel.z > 0.0 and _inside_net(pos):
		pos.z = GameRules.GOAL_LINE_Z * signf(pos.z)
		vel = Vector3.ZERO
	_sim_pos = pos
	_sim_vel = vel
	_sim_stopped = stopped


# Prediction-quality metric: the pre-damp error the smoother is about to
# absorb. Steady-state ~0 when the shared sim agrees with the authority;
# spikes measure host-side events folding in (deflects, saves, releases) and
# the release-seed → snapshot handover seam. Teleport-scale distances
# (faceoff/goal resets — anything the snap guard hard-snaps) are excluded:
# they are legitimate repositions, and recording them buried the real signal
# under ~30 m rink-length "errors" (seen in the first playtest's session rows).
func _record_predict_residual(target_pos: Vector3) -> void:
	if not _smooth_initialized:
		return
	var residual: float = (target_pos - _smooth_pos).length()
	if residual < _SMOOTH_SNAP_DIST:
		NetworkTelemetry.record_puck_predict_residual(residual)


func _interpolate(delta: float) -> void:
	# Shared delay keeps this fallback on the same timeline every interpolator
	# uses (render == the legacy lag-comp rewind instant).
	var interp_delay: float = NetworkManager.get_interpolation_delay()
	# Interpolate a full interp_delay in the past — since Phase 3 this path is
	# the stale-data FALLBACK; the normal loose puck renders through
	# _predict_loose at ~host present, so entering here means the newest
	# snapshot is already older than the prediction cap.
	var render_time: float = NetworkManager.estimated_host_time() - interp_delay
	var bracket: BufferedStateInterpolator.BracketResult = BufferedStateInterpolator.find_bracket(
			_state_buffer, render_time, _scratch_bracket)
	is_extrapolating = bracket != null and bracket.is_extrapolating
	if bracket == null:
		return
	# Reused scratch (per-tick path); both branches write position + velocity,
	# the only fields _apply_state_to_puck consumes.
	var interpolated := _scratch_interp
	if bracket.is_extrapolating:
		var dt: float = minf(bracket.extrapolation_dt, extrapolation_max_ms / 1000.0)
		var newest: PuckNetworkState = bracket.to_state
		# Decay velocity to approximate ice friction so the extrapolated position
		# matches the host's analytic ice-friction deceleration rather than linear
		# dead-reckoning overshoot.
		var friction_vel: Vector3 = _ice_friction_velocity(newest.velocity, dt)
		var projected: Vector3 = newest.position + friction_vel * dt
		# Smart extrapolation: only dead-reckon forward when the puck won't cross a
		# board this frame. Projecting THROUGH a board overshoots outside the rink,
		# then snaps back when the host's reflected samples land. Predicting the
		# bounce client-side would risk disagreeing with the host's authoritative
		# restitution/angle, so instead we just stop leading when a board is in the
		# way — hold at the newest authoritative position until the post-bounce
		# trajectory streams in. Goalie/skater bounces still lean on the SmoothDamp
		# below.
		#
		# The NET gets the same treatment, and unconditionally: a straight lead of up
		# to extrapolation_max_ms (~1.5 m at 30 m/s) can put the rendered puck in the
		# cage while the host has it hitting the frame or going wide, which reads as a
		# goal that never happened. Leading INTO the net is never ours to draw — the
		# goal is a host decision — so hold at the authoritative position instead.
		# (A real goal still renders: the held position IS the host's, and its
		# post-crossing samples stream in behind it.)
		if (stop_extrapolation_at_boards and _crosses_board(projected)) or _inside_net(projected):
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
	_smooth_apply_and_prune(interpolated.position, interpolated.velocity, delta, interp_delay)


# Shared render tail for the loose puck (interpolated AND predicted targets):
# velocity-feed-forward SmoothDamp with the velocity-aware snap guard, commit
# to the puck, prune the buffer.
#
# Snap guard (PuckHandoffRules): only CROSS-track error at the snap distance
# means the rendered trajectory is genuinely wrong; along-track error up to
# velocity × _ALONG_SNAP_TIME_S is an expected timeline offset (the release-
# seed → snapshot handover, a prediction↔fallback seam) and must not teleport
# a fast puck. At rest (resets, faceoffs) it degrades to the plain distance
# check.
#
# Prune against the PAST instant (est_host − full interp_delay), NOT the
# render target's own time: the predicted target runs up to interp_delay ahead
# of the past instant, and pruning there discards exactly the samples an
# interpolation fallback needs. The past instant is the minimum any future
# frame can request, so pruning there is always safe.
func _smooth_apply_and_prune(target_pos: Vector3, vel: Vector3, delta: float,
		interp_delay: float) -> void:
	if not _smooth_initialized:
		_smooth_pos = puck.get_puck_position()
		_smooth_vel = Vector3.ZERO
		_smooth_initialized = true
	if PuckHandoffRules.needs_hard_snap(target_pos - _smooth_pos, vel,
			_SMOOTH_SNAP_DIST, _ALONG_SNAP_TIME_S, _HANDOFF_MIN_SPEED):
		# A moving-target hard snap is genuine trajectory divergence (a bounce
		# that differed, a missed deflect) — the canary the old zone-2 counter
		# tracked. At-rest snaps are legitimate teleports (faceoff/goal resets)
		# and aren't counted.
		if vel.length() >= _HANDOFF_MIN_SPEED:
			NetworkTelemetry.record_puck_hard_snap()
		_smooth_pos = target_pos
		_smooth_vel = Vector3.ZERO
	else:
		_smooth_pos += vel * delta
		_smooth_pos = _smooth_damp(_smooth_pos, target_pos, position_smooth_time, delta)
	_scratch_interp.position = _smooth_pos
	_scratch_interp.velocity = vel
	_apply_state_to_puck(_scratch_interp)
	BufferedStateInterpolator.drop_stale(
			_state_buffer, NetworkManager.estimated_host_time() - interp_delay)


# True when world position `p` (XZ) lies outside the inner board boundary — i.e.
# a straight dead-reckon to here would have crossed a board (bounced). Uses the
# same rounded-rect projection as the puck-OOB / blade-clamp callers, so the
# corners are handled exactly.
func _crosses_board(p: Vector3) -> bool:
	var xz := Vector2(p.x, p.z)
	return GameRules.clamp_to_rink_inner(xz).distance_squared_to(xz) > 1e-6


# True when world position `p` sits inside a goal's net cavity: THE render-side
# "never draw the puck in the net on our own initiative" predicate, shared by the
# prediction park and the extrapolation guard. Routes through GoalDetectionRules so
# it is the same "inside the net" live goal detection uses — in particular the ice
# BEHIND the net (past the back frame) is not in it.
func _inside_net(p: Vector3) -> bool:
	var end_sign: float = signf(p.z)
	if end_sign == 0.0:
		return false
	return GoalDetectionRules.center_inside_net(
			p, GameRules.GOAL_LINE_Z * end_sign, end_sign,
			GameRules.NET_HALF_WIDTH, GameRules.NET_HEIGHT, GameRules.NET_POST_RADIUS,
			GameRules.PUCK_COLLISION_RADIUS, GameRules.PUCK_COLLISION_HALF_HEIGHT,
			GameRules.NET_DEPTH)


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
	# Position only — the puck is a plain Node3D with no body, so only its
	# transform is driven here (velocity lives in the interpolator/predictor).
	puck.set_puck_position(state.position)
