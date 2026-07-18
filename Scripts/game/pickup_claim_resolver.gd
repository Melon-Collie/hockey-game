class_name PickupClaimResolver
extends RefCounted

# Host-only resolver for client-initiated pickup claims with lag compensation.
# Pulled out of GameManager so the validation flow (age check, blade/puck
# rewind, contest-window arbitration) lives in one testable place.
#
# The claimant's blade is CLIENT-AUTHORITATIVE (the client's precise "aim", sent
# in the claim), exactly as AAA FPS lag-comp takes the shooter's aim from the
# usercmd rather than re-deriving it. The host reconstructing the blade from its
# lossy self-view snapshot was the grab-then-lose bug. The host still owns the
# BODY: the puck is rewound as remote-view, the claimant's body position is read
# from the self-view snapshot, and the client blade is reach-clamped to that body
# (LagCompRewind.clamp_client_blade) so a modified client can't teleport its blade.
#
# Flow:
#   receive_claim(peer_id, host_ts, interp_delay, client_blade_curr/prev, top_hand)
#     → reject if puck locked, claim stale, skater missing/ghost, on cooldown
#     → rewind puck to LagCompRewind.remote_view_time(host_ts, interp_delay) and
#       the claimant's body to self_view_time(host_ts); reach-clamp the client
#       blade to that body — never rtt/2
#     → reject if PuckInteractionRules.check_pickup fails against the client blade
#     → if a prior claim is pending and |Δhost_ts| < CONTEST_WINDOW_S, contest;
#       otherwise the earlier claim_timestamp wins outright
#     → otherwise arm pending and wait CONTEST_WINDOW_S for a contender
#   tick(delta) [each host physics frame]
#     → after CONTEST_WINDOW_S with no contender, apply_lag_comp_pickup and clear
#   clear() [when puck is granted authoritatively]
#     → drop any pending claim
#
# Host-only by contract — caller gates on NetworkManager.is_host. Emits no
# signals: every effect is a method call on the injected puck controller.

const MAX_CLAIM_AGE_S: float = 0.2
const CONTEST_WINDOW_S: float = 0.05

var _registry: PlayerRegistry = null
var _state_buffer: StateBufferManager = null
var _puck_getter: Callable = Callable()             # () -> Puck
var _puck_controller_getter: Callable = Callable()  # () -> PuckController

var _pending_peer_id: int = -1
var _pending_timer: float = 0.0
var _pending_host_timestamp: float = 0.0
# The pending claimant's client-sent blade geometry (already reach-clamped), kept
# so a subsequent contest resolves the prior claimant's squirt from the blade IT
# actually reported — client-authoritative for BOTH contestants, not a host-side
# reconstruction of one of them.
var _pending_blade_curr: Vector3 = Vector3.ZERO
var _pending_blade_prev: Vector3 = Vector3.ZERO


func setup(
		registry: PlayerRegistry,
		state_buffer: StateBufferManager,
		puck_getter: Callable,
		puck_controller_getter: Callable) -> void:
	_registry = registry
	_state_buffer = state_buffer
	_puck_getter = puck_getter
	_puck_controller_getter = puck_controller_getter


func tick(delta: float) -> void:
	if _pending_peer_id == -1:
		return
	_pending_timer += delta
	if _pending_timer < CONTEST_WINDOW_S:
		return
	# Resolve at use time so a peer that disconnected / demoted during the
	# contest window doesn't dereference a freed skater.
	var record: PlayerRecord = _registry.get_record(_pending_peer_id)
	if record != null and record.skater != null and _puck_controller_getter.is_valid():
		var pc: PuckController = _puck_controller_getter.call() as PuckController
		if pc != null:
			pc.apply_lag_comp_pickup(record.skater)
	clear()


func clear() -> void:
	_pending_peer_id = -1
	_pending_timer = 0.0
	_pending_host_timestamp = 0.0
	_pending_blade_curr = Vector3.ZERO
	_pending_blade_prev = Vector3.ZERO


func receive_claim(peer_id: int, host_timestamp: float, interp_delay_ms: float,
		client_blade_curr: Vector3, client_blade_prev: Vector3,
		client_top_hand: Vector3) -> void:
	if not _puck_getter.is_valid() or not _puck_controller_getter.is_valid():
		return
	var puck: Puck = _puck_getter.call() as Puck
	var pc: PuckController = _puck_controller_getter.call() as PuckController
	if puck == null or pc == null:
		return
	if puck.carrier != null or puck.pickup_locked:
		return
	# Use session-relative game time so the age check matches host_timestamp's
	# time base (the client stamped it with estimated_host_time).
	# Time.get_ticks_msec() is OS uptime and would diverge by however long the
	# host was alive before the game started.
	var now: float = NetworkManager.local_time()
	if now - host_timestamp > MAX_CLAIM_AGE_S:
		return
	var record: PlayerRecord = _registry.get_record(peer_id)
	if record == null or record.skater == null:
		return
	# is_ghost is checked from the rewound snapshot below (skater_snap), not
	# present-time, so a player who became ghost in the last RTT/2 isn't
	# wrongly denied a claim that was legal at send time, and a player who
	# just cleared ghost isn't wrongly granted one that was illegal then.
	#
	# Cooldown is judged at the claimant's SELF-view time for the same reason:
	# present-time is up to one-way latency later, so a reattach cooldown that
	# expired in that window would grant a claim the claimant couldn't have made
	# at send time. self_view_time is the claimant's own body timeline (matching
	# the blade rewind below); the expiry store shares its local_time base.
	if puck.is_on_cooldown_at(record.skater, LagCompRewind.self_view_time(host_timestamp)):
		return
	if _state_buffer == null or not _state_buffer.is_ready():
		return
	# Blade is SELF-view, puck is REMOTE-view — see LagCompRewind for the
	# derivation of both. The pair of get_state_at calls per entity (curr + one
	# physics tick back) feeds the swept-segment test below.
	var blade_rewind_time: float = LagCompRewind.self_view_time(host_timestamp)
	var puck_rewind_time: float = LagCompRewind.remote_view_time(host_timestamp, interp_delay_ms)
	var puck_snap: WorldSnapshot = _state_buffer.get_state_at(puck_rewind_time)
	if puck_snap.puck_state == null or puck_snap.puck_state.carrier_peer_id != -1:
		return
	var puck_pos: Vector3 = puck_snap.puck_state.position
	var puck_prev_snap: WorldSnapshot = _state_buffer.get_state_at(LagCompRewind.prev_tick(puck_rewind_time))
	var puck_prev: Vector3 = puck_prev_snap.puck_state.position if puck_prev_snap.puck_state != null else puck_pos
	var blade_snap: WorldSnapshot = _state_buffer.get_state_at(blade_rewind_time)
	var blade_prev_snap: WorldSnapshot = _state_buffer.get_state_at(LagCompRewind.prev_tick(blade_rewind_time))
	var skater_snap: SkaterNetworkState = blade_snap.get_skater_state(peer_id)
	var skater_prev_snap: SkaterNetworkState = blade_prev_snap.get_skater_state(peer_id)
	if skater_snap == null or skater_prev_snap == null:
		return
	if skater_snap.is_ghost:
		return
	# A crouched shot-blocker can't corral the puck with their stick, and
	# neither can a shooter mid follow-through (the stick is whipping through
	# a finish — this also closes the instant self-rebound re-attach after a
	# shot). Checked from the rewound snapshot (like is_ghost) so the verdict
	# matches the stance the claimant actually held at send time.
	if skater_snap.shot_state == SkaterStateMachine.State.SHOT_BLOCKING \
			or skater_snap.shot_state == SkaterStateMachine.State.FOLLOW_THROUGH:
		return
	# Client-authoritative blade ("aim"): the claim carries the blade geometry the
	# client actually reached with, instead of the host reconstructing it from its
	# lossy self-view snapshot (the reconstruction diverged from what the client
	# saw — the grab-then-lose bug). The host still owns the BODY: each client point
	# is pinned to within the claimant's physical reach of the server-authoritative
	# body (skater_snap.position) so a modified client can't teleport its blade.
	var max_reach: float = _peer_max_reach(peer_id)
	var blade_curr: Vector3 = LagCompRewind.clamp_client_blade(
			client_blade_curr, skater_snap.position, max_reach)
	var blade_prev: Vector3 = LagCompRewind.clamp_client_blade(
			client_blade_prev, skater_prev_snap.position, max_reach)
	var top_hand: Vector3 = LagCompRewind.clamp_client_blade(
			client_top_hand, skater_snap.position, max_reach)
	# Sanity telemetry (host-only, no-op off the host): this claim reached the
	# rewound geometry test — the client's view said in-range and every
	# eligibility gate passed. A check_pickup fail below means the host's rewind
	# put the blade/puck out of overlap: the lag-comp "reached for it, didn't get
	# it" signal. Tracked as network_sessions totals so a high miss FRACTION on
	# the host row flags a rewind that isn't reproducing what the client saw.
	NetworkTelemetry.record_pickup_claim()
	if not PuckInteractionRules.check_pickup(puck_prev, puck_pos, blade_prev, blade_curr, PuckController.PICKUP_RADIUS):
		NetworkTelemetry.record_pickup_claim_miss()
		return
	# Catch vs deflect — run the SAME decision the present-time path uses
	# (PuckController._check_interactions → PuckReceptionRules.should_receive),
	# but against the rewound snapshot. Without it the claim path granted a
	# pickup on blade overlap ALONE, so a remote player reaching for a too-fast /
	# poorly-angled puck caught it magnetically where a local player would have
	# deflected it. Puck velocity is stored on the snapshot; the receiver's velocity
	# (for the relative-frame decision) is the server-authoritative body kinematics
	# from the rewound skater snapshot, while the blade/hand world points (for the
	# face normal) are the client-sent, reach-clamped aim above — so the verdict
	# judges the same closing speed and stick angle the claimant saw at send time.
	var puck_vel: Vector3 = puck_snap.puck_state.velocity
	var relative_vel: Vector3 = puck_vel - skater_snap.velocity
	var face_normal: Vector3 = PuckReceptionRules.blade_face_normal(
			blade_curr, top_hand, relative_vel,
			Vector3(skater_snap.facing.x, 0.0, skater_snap.facing.y))
	if not PuckReceptionRules.should_receive(
			puck_vel, skater_snap.velocity, face_normal,
			puck.pickup_max_speed, puck.deflect_min_speed, puck.alignment_receive_bonus):
		# Deflect verdict: redirect the puck instead of granting possession. Not a
		# contested action (no carrier change), so it fires immediately rather than
		# arming the contest window. Counts as a claim outcome (geometry hit, but the
		# rewound speed/angle said tip-not-catch) so the host row separates "missed
		# the puck" from "reached it but it wasn't catchable".
		NetworkTelemetry.record_pickup_claim_deflect()
		pc.apply_lag_comp_deflect(record.skater)
		return
	if _pending_peer_id != -1:
		# Gate the contest decision on claim timestamps, not RPC arrival order.
		# Two RPCs can arrive within the 50ms host-arrival window despite their
		# claim timestamps being far apart (jitter on one peer's link), and the
		# fairness model is "two players reaching for the puck at roughly the
		# same client-time," which is what host_timestamp captures.
		var claim_delta: float = absf(host_timestamp - _pending_host_timestamp)
		if claim_delta < CONTEST_WINDOW_S:
			# Genuine contest — both claims stamped within window.
			# Resolve the prior claimant at contest time. If they've disconnected
			# or demoted in the contest window, treat the new claim as uncontested.
			var prior_record: PlayerRecord = _registry.get_record(_pending_peer_id)
			if prior_record != null and prior_record.skater != null:
				# Resolve the squirt from the CLIENT-REPORTED blade of BOTH claimants
				# — the aim each was authoritative over at its own view-time — not
				# present-time (a contest window + RTT later). The new claimant's
				# blade is in hand (client_blade_curr/prev, reach-clamped above); the
				# prior claimant's was stored (reach-clamped) when its claim armed
				# pending. If somehow absent, fall back to its live blade.
				var new_vel: Vector3 = (blade_curr - blade_prev) * float(Constants.PHYSICS_TICK)
				var prior_pos: Vector3 = prior_record.skater.get_blade_contact_global()
				var prior_vel: Vector3 = prior_record.skater.blade_world_velocity
				if _pending_blade_curr != Vector3.ZERO:
					prior_pos = _pending_blade_curr
					prior_vel = (_pending_blade_curr - _pending_blade_prev) * float(Constants.PHYSICS_TICK)
				pc.apply_contested_pickup(record.skater, prior_record.skater,
						new_vel, prior_vel, blade_curr, prior_pos)
				clear()
			else:
				_arm_pending(peer_id, host_timestamp, blade_curr, blade_prev)
		else:
			# Not contested in client-time. Whichever was stamped earlier wins
			# outright; the later one would have found the puck already taken on
			# an ideal network. Doesn't fix the dual case (second RPC arriving
			# after the host-arrival window expired) — that's the cost of not
			# adding a fixed pickup latency.
			if host_timestamp < _pending_host_timestamp:
				# New claim is actually earlier — apply it now and drop pending.
				pc.apply_lag_comp_pickup(record.skater)
				clear()
			# else: new claim is later, drop it and let pending resolve via tick().
	else:
		_arm_pending(peer_id, host_timestamp, blade_curr, blade_prev)


# Arm the contest window for a claimant, stashing the (reach-clamped) client blade
# so a later contender resolves this claimant's squirt from the aim it reported.
func _arm_pending(peer_id: int, host_timestamp: float,
		blade_curr: Vector3, blade_prev: Vector3) -> void:
	_pending_peer_id = peer_id
	_pending_host_timestamp = host_timestamp
	_pending_timer = 0.0
	_pending_blade_curr = blade_curr
	_pending_blade_prev = blade_prev


# The claimant's fully-extended physical reach (AISkaterCaps.max_blade_reach),
# used to bound the client-sent blade against the server body. 0.0 when the peer
# has no caps entry (can't-happen for a spawned claimant) — the clamp then no-ops.
func _peer_max_reach(peer_id: int) -> float:
	if _registry == null:
		return 0.0
	var caps: AISkaterCaps = _registry.caps_by_peer.get(peer_id)
	return caps.max_blade_reach if caps != null else 0.0
