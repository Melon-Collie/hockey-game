class_name PokeClaimResolver
extends RefCounted

# Host-only resolver for client-initiated poke check claims with lag compensation.
# Mirrors PickupClaimResolver but with no contest window — first valid claim
# wins, the carrier loses the puck either way. Two attackers claiming within
# microseconds of each other are arbitrated by RPC arrival order; the second
# claim sees carrier == null from the first's apply_poke_check and skips.
#
# Flow:
#   receive_claim(peer_id, host_ts, interp_delay, expected_carrier_peer_id,
#                 client_blade_curr, client_blade_prev)
#     → reject if puck locked, no carrier, carrier changed, claim stale,
#       skater missing/ghost, attempting to poke self or teammate
#     → rewind the carried puck to LagCompRewind.remote_view_time(host_ts,
#       interp_delay) and the attacker's body to self_view_time(host_ts);
#       stage-3: shift the puck segment by the carrier's forward-predicted
#       displacement (LagCompRewind.forward_predict_skater — the claimant
#       rendered the carrier intent-integrated toward present, and the carried
#       puck rides the carrier's blade);
#       reach-clamp the CLIENT-sent attacker blade to that body
#     → reject if PuckInteractionRules.check_poke fails against that geometry
#     → apply_lag_comp_poke (idempotent)
#
# The shared claim-resolver contract — the interp-delay bound, the age fence,
# the two view times, the claimant-side reconstruction — is in
# Scripts/game/CLAUDE.md, and the pieces of it that are the same on every
# resolver live in LagCompRewind.claim_is_fresh and ClaimantView.

var _registry: PlayerRegistry = null
var _state_buffer: StateBufferManager = null
var _puck_getter: Callable = Callable()             # () -> Puck
var _puck_controller_getter: Callable = Callable()  # () -> PuckController
# Stage-3 forward-prediction scratch (reused; receive_claim is host-only).
var _fp_result := SkaterMovementRules.ForwardResult.new()
# Owns its own scratch, so the claimant reconstruction can never alias the
# carrier one above.
var _claimant := ClaimantView.new()


func setup(
		registry: PlayerRegistry,
		state_buffer: StateBufferManager,
		puck_getter: Callable,
		puck_controller_getter: Callable) -> void:
	_registry = registry
	_state_buffer = state_buffer
	_puck_getter = puck_getter
	_puck_controller_getter = puck_controller_getter


func receive_claim(peer_id: int, host_timestamp: float,
		interp_delay_ms: float, input_lead_ms: float, expected_carrier_peer_id: int,
		client_blade_curr: Vector3, client_blade_prev: Vector3) -> void:
	if not _puck_getter.is_valid() or not _puck_controller_getter.is_valid():
		return
	var puck: Puck = _puck_getter.call() as Puck
	var pc: PuckController = _puck_controller_getter.call() as PuckController
	if puck == null or pc == null:
		return
	if puck.carrier == null or puck.pickup_locked:
		return
	# Anti-cheat: bound the self-reported render delay against the measured link
	# before any rewind / forward-predict depth reads it (see LagCompRewind).
	interp_delay_ms = LagCompRewind.plausible_interp_delay_ms(
			interp_delay_ms, float(NetworkManager.get_peer_ping_ms(peer_id)))
	if not LagCompRewind.claim_is_fresh(host_timestamp):
		return
	var record: PlayerRecord = _registry.get_record(peer_id)
	if record == null or record.skater == null:
		return
	# is_ghost is judged from the rewound snapshot below (skater_snap), not
	# present-time — matching PickupClaimResolver: a checker legal at their
	# view-time but ghosted (offside) in the last RTT/2 isn't wrongly denied, and
	# one who just tagged up isn't wrongly granted a poke that was illegal then.
	# Defense in depth — client-side gate already excludes these, but a
	# malformed RPC shouldn't be able to bypass the rules.
	if record.skater == puck.carrier:
		return
	var carrier_team: int = _registry.team_id_by_skater.get(puck.carrier, -1)
	var checker_team: int = _registry.team_id_by_skater.get(record.skater, -1)
	if not PuckCollisionRules.can_poke_check(carrier_team, checker_team):
		return
	if _state_buffer == null or not _state_buffer.is_ready():
		return
	# Checker's blade is SELF-view; remote-carried puck is REMOTE-view (its
	# position is pinned to the carrier's interpolated body). See LagCompRewind
	# for the derivation. The pair of get_state_at calls per entity (curr + one
	# physics tick back) feeds the swept-segment test below.
	var blade_rewind_time: float = LagCompRewind.self_view_time(host_timestamp, input_lead_ms)
	var puck_rewind_time: float = LagCompRewind.remote_view_time(host_timestamp, interp_delay_ms)
	var puck_snap: WorldSnapshot = _state_buffer.get_state_at(puck_rewind_time)
	if puck_snap.puck_state == null:
		return
	# Validate the carrier was the player the claimant was attacking. If the
	# carrier had already changed by the claimant's view-time (someone else
	# stripped first, or the carrier released the puck), the claim is stale.
	if puck_snap.puck_state.carrier_peer_id != expected_carrier_peer_id:
		return
	# Looked up here (rather than at apply time) because the stage-3 carrier
	# reconstruction below needs the carrier's controller.
	var expected_record: PlayerRecord = _registry.get_record(expected_carrier_peer_id)
	if expected_record == null or expected_record.skater == null:
		return
	var puck_pos: Vector3 = puck_snap.puck_state.position
	var puck_prev_snap: WorldSnapshot = _state_buffer.get_state_at(LagCompRewind.prev_tick(puck_rewind_time))
	var puck_prev: Vector3 = puck_prev_snap.puck_state.position if puck_prev_snap.puck_state != null else puck_pos
	# Stage-3: the claimant rendered the CARRIER forward-predicted toward
	# host-present (RemoteController's intent integration), and the carried puck
	# rides the carrier's blade — so the puck the attacker poked at sits at the
	# rewound puck position PLUS the carrier's forward-predicted displacement.
	# Shift both swept endpoints by the same delta (rigid translation: the
	# segment's shape is the carrier's own blade motion, which the render leaves
	# at its rewound body-relative pose). No-op at fraction 0 — exact legacy
	# render == rewind.
	var carrier_snap: SkaterNetworkState = puck_snap.get_skater_state(expected_carrier_peer_id)
	if LagCompRewind.forward_predict_skater(carrier_snap,
			expected_record.controller as SkaterController, interp_delay_ms, input_lead_ms,
			_fp_result):
		var carrier_delta: Vector3 = _fp_result.position - carrier_snap.position
		puck_pos += carrier_delta
		puck_prev += carrier_delta
	var blade_snap: WorldSnapshot = _state_buffer.get_state_at(blade_rewind_time)
	var blade_prev_snap: WorldSnapshot = _state_buffer.get_state_at(LagCompRewind.prev_tick(blade_rewind_time))
	var skater_snap: SkaterNetworkState = blade_snap.get_skater_state(peer_id)
	var skater_prev_snap: SkaterNetworkState = blade_prev_snap.get_skater_state(peer_id)
	if skater_snap == null or skater_prev_snap == null:
		return
	if skater_snap.is_ghost:
		return
	# A committed shot block withdraws the blade from puck play — the same
	# withdrawal the present-time loop applies in PuckController. Judged from the
	# REWOUND snapshot (like is_ghost) so the verdict matches the stance the
	# claimant actually held at send time. The client suppresses the claim itself
	# while blocking (LocalController), but the grant is decided here.
	if skater_snap.shot_state == SkaterStateMachine.State.SHOT_BLOCKING:
		return
	# The attacker's blade is client-authoritative aim; ClaimantView is what bounds
	# it against the host's own body and blade reconstruction.
	if not _claimant.resolve(_registry, peer_id, skater_snap,
			record.controller as SkaterController,
			blade_rewind_time, _state_buffer.newest_host_timestamp()):
		return
	var blade_curr: Vector3 = _claimant.clamp_blade(client_blade_curr, skater_snap)
	var blade_prev: Vector3 = _claimant.clamp_blade(client_blade_prev, skater_prev_snap)
	# Host-only claim-outcome telemetry (no-op off the host): the claim reached the
	# rewound geometry test. A check_poke fail is the "reached for it, didn't get it"
	# signal — a high miss FRACTION on the host row flags a rewind not reproducing
	# the client's view. See NetworkTelemetry / network_sessions.
	NetworkTelemetry.record_poke_claim()
	if not PuckInteractionRules.check_poke(puck_prev, puck_pos, blade_prev, blade_curr, PuckController.POKE_RADIUS):
		NetworkTelemetry.record_poke_claim_miss()
		# HOW badly (see PickupClaimResolver's matching call): ~1.0-1.2 is a
		# boundary graze, >2 means the rewind reconstructed something unrelated.
		NetworkTelemetry.record_claim_miss_separation(
				PuckInteractionRules.sweep_separation(puck_prev, puck_pos, blade_prev, blade_curr),
				PuckController.POKE_RADIUS)
		return
	# Pass the intended victim through so apply guards against the carrier
	# having changed (X → Z) between claim send and apply. Looked up from the
	# claimant's expected target (above), not from the current `puck.carrier`.
	pc.apply_lag_comp_poke(record.skater, expected_record.skater)
