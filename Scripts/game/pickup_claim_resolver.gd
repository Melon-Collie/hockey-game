class_name PickupClaimResolver
extends RefCounted

# Host-only resolver for client-initiated pickup claims with lag compensation:
# age check, blade/puck rewind, contest-window arbitration.
#
# The claimant's blade is CLIENT-AUTHORITATIVE (the client's precise "aim", sent
# in the claim). The host must not reconstruct it from its own lossy self-view
# snapshot — that reconstruction diverges from what the client saw, and the
# claimant watches the puck stick and then come loose. The host still owns the
# BODY: the puck is rewound as remote-view, the claimant's body position is read
# from the self-view snapshot, and the client blade is reach-clamped to that body
# (LagCompRewind.clamp_client_blade) so a modified client can't teleport its blade.
#
# Flow:
#   receive_claim(peer_id, host_ts, interp_delay, client_blade_curr/prev, top_hand)
#     → reject if puck locked, claim stale, skater missing/ghost, on cooldown
#     → rewind puck to LagCompRewind.puck_view_time and the claimant's body to
#       self_view_time(host_ts) — since the clock unification these are the SAME
#       instant (stamp + the claimant's input lead), so the puck and the blade
#       reaching for it are judged together; reach-clamp the client blade to that
#       body — never rtt/2
#     → reject if PuckInteractionRules.check_pickup fails against the client blade
#     → if a prior claim is pending and the two SELF-VIEW instants are within
#       CONTEST_WINDOW_S, contest; otherwise whoever reached first wins outright
#     → otherwise arm pending and wait CONTEST_WINDOW_S for a contender
#   tick(delta) [each host physics frame]
#     → after CONTEST_WINDOW_S with no contender, apply_lag_comp_pickup and clear
#   clear() [when puck is granted authoritatively]
#     → drop any pending claim
#
# Host-only by contract — caller gates on NetworkManager.is_host. Emits no
# signals: every effect is a method call on the injected puck controller.

const CONTEST_WINDOW_S: float = 0.05

var _registry: PlayerRegistry = null
var _state_buffer: StateBufferManager = null
var _puck_getter: Callable = Callable()             # () -> Puck
var _puck_controller_getter: Callable = Callable()  # () -> PuckController
# The claimant's own body and blade at the instant they reached (reused; the
# resolver is host-only).
var _claimant := ClaimantView.new()

var _pending_peer_id: int = -1
var _pending_timer: float = 0.0
# The pending claimant's SELF-VIEW instant (self_view_time = stamp + their input
# lead), NOT the raw claim stamp. Both arbitration paths below compare it against
# another reach instant — the host's live blade at `now`, or a contender's own
# self-view — and the raw stamp is a lead earlier than the moment the claimant
# actually reached. Comparing a stamp to a reach instant skews every present-time
# verdict by a full lead (25-75 ms against a 50 ms window), and against a
# contender by the DIFFERENCE of two per-client servo leads.
var _pending_view_time: float = 0.0
# The pending claimant's client-sent blade geometry (already reach-clamped), kept
# so a subsequent contest resolves the prior claimant's squirt from the blade IT
# actually reported — client-authoritative for BOTH contestants, not a host-side
# reconstruction of one of them.
var _pending_blade_curr: Vector3 = Vector3.ZERO
var _pending_blade_prev: Vector3 = Vector3.ZERO

# Miss-recovery watch (telemetry only — no gameplay effect). A rejected claim
# does NOT cost the peer the puck: the host's own present-time grab is an
# independent path and still grants when the blade genuinely reaches. So a miss
# is either "the lag-comp fast path fell through and the normal path caught it a
# trip later" (a latency cost) or "the player lost it" (a gameplay loss), and the
# miss count alone cannot tell those apart even though they are not comparably
# bad. Remember the last rejected peer briefly; if the authoritative grant lands
# on them inside the window, count it recovered.
const _MISS_RECOVERY_WINDOW_S: float = 0.35
var _miss_peer_id: int = -1
var _miss_recovery_timer: float = 0.0


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
	if _miss_recovery_timer > 0.0:
		_miss_recovery_timer -= delta
		if _miss_recovery_timer <= 0.0:
			_miss_peer_id = -1
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
	_pending_view_time = 0.0
	_pending_blade_curr = Vector3.ZERO
	_pending_blade_prev = Vector3.ZERO


# Clear because someone was granted the puck authoritatively (any pickup —
# lag-comp grant, arbitrated present grab, one-timer catch). If the discarded
# pending claimant isn't the grantee, NACK them so their optimistic pin rolls
# back now instead of waiting out the RTT-scaled timeout.
func clear_for_grant(granted_peer_id: int) -> void:
	# Telemetry only (see _MISS_RECOVERY_WINDOW_S): this peer's claim was rejected
	# moments ago and the authoritative path has now handed them the puck anyway.
	if _miss_recovery_timer > 0.0 and granted_peer_id == _miss_peer_id:
		NetworkTelemetry.record_claim_miss_recovered()
		_miss_peer_id = -1
		_miss_recovery_timer = 0.0
	if _pending_peer_id != -1 and _pending_peer_id != granted_peer_id:
		NetworkManager.send_pickup_claim_nack(_pending_peer_id)
	clear()


# ── Claim-vs-present-time arbitration ────────────────────────────────────────
# The host's present-time pickup tick (PuckController._check_interactions) must
# route through here rather than granting unconditionally: an unconditional grant
# clears the pending claim, so a lag-comp claim sitting in its contest window
# always loses to a host-live blade (the host player's own, or a remote's
# replayed one) however much earlier it was stamped — "the host wins every 50/50"
# in a scramble. This entry point runs at the present-time grant moment and
# applies the same stamp-fairness rule the claim-vs-claim path uses, treating the
# live grab as a claim stamped `now`.
#
# Pure decision half, pinned by GUT. Both arguments are instants on the host
# timeline at which a blade reached the puck: `pending_view_time` is when the
# claimant reached (their self-view instant), `now` is when the live blade did.
# CONTESTED inside the contest window (a genuine 50/50 → squirt), PENDING_WON
# when the claimant reached first by more than the window — the grab happening
# before tick()'s window expiry is just RPC-arrival timing.
#
# Since claims are deferred to their own instant (DeferredClaimQueue) a pending
# claim is never armed before `now` reaches it, so `now - pending_view_time` is
# always >= 0 here. A live grab EARLIER than a still-parked claim needs no branch:
# it is granted unopposed, and the parked claim then self-rejects on release
# because the buffer at its own view time already shows the puck taken.
enum PresentGrab { CONTESTED = 0, PENDING_WON = 1 }

static func classify_present_grab(pending_view_time: float, now: float) -> int:
	return PresentGrab.CONTESTED if now - pending_view_time < CONTEST_WINDOW_S \
			else PresentGrab.PENDING_WON


# Returns true when the resolver CONSUMED the grab (contest squirt applied, or
# the pending claim granted outright) — the present-time path must then NOT set
# the carrier. Returns false when the present grab should proceed: no pending
# claim, the grabber IS the pending claimant (their replayed blade caught up
# with their own claim — the normal grant clears pending), or the pending
# claimant has despawned. Three-way scrambles (a live-vs-live contest while a
# third claim pends) keep the existing behavior — the live pair squirts and the
# pending claim resolves against the squirted puck via its own window.
func arbitrate_present_grab(grabber: Skater, grabber_peer_id: int,
		grab_blade_pos: Vector3, grab_blade_vel: Vector3, now: float) -> bool:
	if _pending_peer_id == -1:
		return false
	if grabber_peer_id == _pending_peer_id:
		return false
	var prior_record: PlayerRecord = _registry.get_record(_pending_peer_id)
	if prior_record == null or prior_record.skater == null:
		clear()  # claimant despawned/demoted mid-window — same as tick()'s handling
		return false
	if grabber == null:
		return false
	if not _puck_controller_getter.is_valid():
		return false
	var pc: PuckController = _puck_controller_getter.call() as PuckController
	if pc == null:
		return false
	if classify_present_grab(_pending_view_time, now) == PresentGrab.CONTESTED:
		# Genuine 50/50 — live grabber's kinematics vs the pending claimant's
		# stored client-reported blade (its authoritative aim at its view-time),
		# exactly mirroring the claim-vs-claim contest resolution. The claimant
		# gets no possession (squirt), so NACK their optimistic pin.
		var prior_pos: Vector3 = prior_record.skater.get_blade_contact_global()
		var prior_vel: Vector3 = prior_record.skater.blade_world_velocity
		if _pending_blade_curr != Vector3.ZERO:
			prior_pos = _pending_blade_curr
			prior_vel = (_pending_blade_curr - _pending_blade_prev) * float(Constants.PHYSICS_TICK)
		pc.apply_contested_pickup(grabber, prior_record.skater,
				grab_blade_vel, prior_vel, grab_blade_pos, prior_pos)
		NetworkManager.send_pickup_claim_nack(_pending_peer_id)
	else:
		# Stamp-earlier claim wins outright — grant now rather than at the
		# window expiry tick() would have used.
		pc.apply_lag_comp_pickup(prior_record.skater)
	clear()
	return true


# _interp_delay_ms rides the shared claim wire shape but is unused here since
# the loose-puck rewind reads the claim stamp itself (puck_view_time) and the
# blade rewind is self-view — nothing in a pickup claim renders remote-view.
func receive_claim(peer_id: int, host_timestamp: float, _interp_delay_ms: float,
		input_lead_ms: float, client_blade_curr: Vector3, client_blade_prev: Vector3,
		client_top_hand: Vector3) -> void:
	if not _puck_getter.is_valid() or not _puck_controller_getter.is_valid():
		return
	var puck: Puck = _puck_getter.call() as Puck
	var pc: PuckController = _puck_controller_getter.call() as PuckController
	if puck == null or pc == null:
		return
	if puck.carrier != null or puck.pickup_locked:
		NetworkManager.send_pickup_claim_nack(peer_id)
		return
	if not LagCompRewind.claim_is_fresh(host_timestamp):
		NetworkManager.send_pickup_claim_nack(peer_id)
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
	if puck.is_on_cooldown_at(record.skater, LagCompRewind.self_view_time(host_timestamp, input_lead_ms)):
		NetworkManager.send_pickup_claim_nack(peer_id)
		return
	if _state_buffer == null or not _state_buffer.is_ready():
		NetworkManager.send_pickup_claim_nack(peer_id)
		return
	# Blade is SELF-view; the loose puck reads through puck_view_time — the
	# claimant rendered it predicted AT the claim stamp (render == rewind at
	# present). See LagCompRewind for the derivations. The pair of get_state_at
	# calls per entity (curr + one physics tick back) feeds the swept-segment
	# test below.
	var blade_rewind_time: float = LagCompRewind.self_view_time(host_timestamp, input_lead_ms)
	var puck_rewind_time: float = LagCompRewind.puck_view_time(host_timestamp, input_lead_ms)
	var puck_snap: WorldSnapshot = _state_buffer.get_state_at(puck_rewind_time)
	if puck_snap.puck_state == null or puck_snap.puck_state.carrier_peer_id != -1:
		NetworkManager.send_pickup_claim_nack(peer_id)
		return
	var puck_pos: Vector3 = puck_snap.puck_state.position
	var puck_prev_snap: WorldSnapshot = _state_buffer.get_state_at(LagCompRewind.prev_tick(puck_rewind_time))
	var puck_prev: Vector3 = puck_prev_snap.puck_state.position if puck_prev_snap.puck_state != null else puck_pos
	var blade_snap: WorldSnapshot = _state_buffer.get_state_at(blade_rewind_time)
	var blade_prev_snap: WorldSnapshot = _state_buffer.get_state_at(LagCompRewind.prev_tick(blade_rewind_time))
	var skater_snap: SkaterNetworkState = blade_snap.get_skater_state(peer_id)
	var skater_prev_snap: SkaterNetworkState = blade_prev_snap.get_skater_state(peer_id)
	if skater_snap == null or skater_prev_snap == null:
		NetworkManager.send_pickup_claim_nack(peer_id)
		return
	if skater_snap.is_ghost:
		NetworkManager.send_pickup_claim_nack(peer_id)
		return
	# A crouched shot-blocker can't corral the puck with their stick, and
	# neither can a shooter mid follow-through (the stick is whipping through
	# a finish — this also closes the instant self-rebound re-attach after a
	# shot). Checked from the rewound snapshot (like is_ghost) so the verdict
	# matches the stance the claimant actually held at send time.
	if skater_snap.shot_state == SkaterStateMachine.State.SHOT_BLOCKING \
			or skater_snap.shot_state == SkaterStateMachine.State.FOLLOW_THROUGH:
		NetworkManager.send_pickup_claim_nack(peer_id)
		return
	# Committed to a body check at send time — the stick was off the ice (matches
	# the present-time withdrawal in PuckController._check_interactions and the
	# client's own provisional gate), so no pickup grant. hit_committed rides the
	# replicated SkaterNetworkState, so the rewound stance is authoritative here.
	if skater_snap.hit_committed:
		NetworkManager.send_pickup_claim_nack(peer_id)
		return
	# Client-authoritative blade ("aim") — the claim carries the geometry the
	# client actually reached with (see the header). The host still owns the BODY,
	# and ClaimantView is what pins the client's points to it.
	if not _claimant.resolve(_registry, peer_id, skater_snap,
			record.controller as SkaterController,
			blade_rewind_time, _state_buffer.newest_host_timestamp()):
		NetworkManager.send_pickup_claim_nack(peer_id)
		return
	var self_catch: Vector3 = _claimant.catch_up()
	var blade_curr: Vector3 = _claimant.reach_clamp(client_blade_curr, skater_snap.position)
	var blade_prev: Vector3 = _claimant.reach_clamp(client_blade_prev, skater_prev_snap.position)
	var top_hand: Vector3 = _claimant.reach_clamp(client_top_hand, skater_snap.position)
	# The two bounds are split rather than clamp_blade'd because the divergence
	# telemetry below measures BETWEEN them.
	var pre_continuity_blade: Vector3 = blade_curr
	blade_curr = _claimant.continuity_clamp(blade_curr, skater_snap.blade_contact_world)
	blade_prev = _claimant.continuity_clamp(blade_prev, skater_prev_snap.blade_contact_world)
	top_hand = _claimant.continuity_clamp(top_hand, skater_snap.top_hand_world)
	# Rewind fidelity, measured directly rather than inferred from the miss rate:
	# how far the client's blade sat from the host's OWN reconstruction of it, and
	# whether the clamp had to pull it. Recorded for EVERY claim reaching the
	# geometry test (hit or miss) so the miss rate has a denominator to read
	# against — a high miss rate with near-zero divergence is a different problem
	# from a high miss rate with the clamp biting constantly. The reference carries
	# self_catch for the same reason the clamps do: it has to be the host's
	# reconstruction at the instant the claimant reached, or the metric reports the
	# self-view gap as if it were client-vs-host disagreement.
	if skater_snap.blade_contact_world != Vector3.ZERO:
		NetworkTelemetry.record_claim_blade_divergence(
				pre_continuity_blade.distance_to(skater_snap.blade_contact_world + self_catch),
				pre_continuity_blade != blade_curr)
	# Sanity telemetry (host-only, no-op off the host): this claim reached the
	# rewound geometry test — the client's view said in-range and every
	# eligibility gate passed. A check_pickup fail below means the host's rewind
	# put the blade/puck out of overlap: the lag-comp "reached for it, didn't get
	# it" signal. Tracked as network_sessions totals so a high miss FRACTION on
	# the host row flags a rewind that isn't reproducing what the client saw.
	NetworkTelemetry.record_pickup_claim()
	if not PuckInteractionRules.check_pickup(puck_prev, puck_pos, blade_prev, blade_curr, PuckController.PICKUP_RADIUS):
		NetworkTelemetry.record_pickup_claim_miss()
		# HOW badly it missed. A bare miss count can't separate a boundary graze
		# (the client's point-in-sphere send gate passing where the swept test lands
		# just outside — expected, since blade-proximity pickup claims on every pass
		# near a loose puck) from the rewind putting blade and puck somewhere
		# unrelated. The ratio makes that readable without a threshold here.
		NetworkTelemetry.record_claim_miss_separation(
				PuckInteractionRules.sweep_separation(puck_prev, puck_pos, blade_prev, blade_curr),
				PuckController.PICKUP_RADIUS)
		_miss_peer_id = peer_id
		_miss_recovery_timer = _MISS_RECOVERY_WINDOW_S
		NetworkManager.send_pickup_claim_nack(peer_id)
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
			puck.pickup_max_speed,
			puck.deflect_min_speed * record.skater.reception_ceiling_mult,
			puck.alignment_receive_bonus * record.skater.reception_ceiling_mult):
		# Deflect verdict: redirect the puck instead of granting possession. Not a
		# contested action (no carrier change), so it fires immediately rather than
		# arming the contest window. Counts as a claim outcome (geometry hit, but the
		# rewound speed/angle said tip-not-catch) so the host row separates "missed
		# the puck" from "reached it but it wasn't catchable".
		NetworkTelemetry.record_pickup_claim_deflect()
		pc.apply_lag_comp_deflect(record.skater)
		NetworkManager.send_pickup_claim_nack(peer_id)
		return
	if _pending_peer_id != -1:
		# Gate the contest decision on when each claimant actually REACHED, not on
		# RPC arrival order. Two RPCs can arrive within the 50ms host-arrival window
		# despite their claims being far apart in client-time (jitter on one peer's
		# link), and the fairness model is "two players reaching for the puck at
		# roughly the same instant". That instant is the SELF-VIEW time, not the raw
		# stamp: the lead is per-client and servo-driven, so two raw stamps can be
		# equal while the reaches were up to MAX_LEAD_EXTRA_S apart.
		var claim_delta: float = absf(blade_rewind_time - _pending_view_time)
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
				NetworkManager.send_pickup_claim_nack(peer_id)
				NetworkManager.send_pickup_claim_nack(_pending_peer_id)
				clear()
			else:
				_arm_pending(peer_id, blade_rewind_time, blade_curr, blade_prev)
		else:
			# Not contested in client-time. Whichever was stamped earlier wins
			# outright; the later one would have found the puck already taken on
			# an ideal network. Doesn't fix the dual case (second RPC arriving
			# after the host-arrival window expired) — that's the cost of not
			# adding a fixed pickup latency.
			if blade_rewind_time < _pending_view_time:
				# New claim is actually earlier — apply it now and drop pending.
				pc.apply_lag_comp_pickup(record.skater)
				clear()
			else:
				# New claim is later — drop it and let pending resolve via tick().
				NetworkManager.send_pickup_claim_nack(peer_id)
	else:
		_arm_pending(peer_id, blade_rewind_time, blade_curr, blade_prev)


# Arm the contest window for a claimant, stashing the (reach-clamped) client blade
# so a later contender resolves this claimant's squirt from the aim it reported.
func _arm_pending(peer_id: int, view_time: float,
		blade_curr: Vector3, blade_prev: Vector3) -> void:
	_pending_peer_id = peer_id
	_pending_view_time = view_time
	_pending_timer = 0.0
	_pending_blade_curr = blade_curr
	_pending_blade_prev = blade_prev

