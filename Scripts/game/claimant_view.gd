class_name ClaimantView
extends RefCounted

# The claimant's own body and blade at the instant they reached — the half of a
# lag-compensated claim all four resolvers reconstruct identically, and the half
# a new resolver silently gets wrong.
#
# Three steps in order, and only the last one is obvious from the geometry:
#
#   1. Catch the body up to the self-view instant. That instant is NOT in the
#      host's buffer and cannot be — the host holds a client's input until its
#      stamp comes due, so the lookup lands past the newest sample and
#      StateBufferManager answers it with the newest entry and no signal at all.
#   2. Reach-clamp the client-sent point to that caught-up body.
#   3. Continuity-clamp it toward the host's own reconstruction, translated by
#      the same catch-up.
#
# Doing 2 and 3 without 1 is the failure with no symptom: both clamps then fence
# an honest full-extension claim against a body rewound short by
# (lead - one_way), and the claim just quietly misses. Routing every resolver
# through here is what makes the order structural instead of a bullet in
# Scripts/game/CLAUDE.md that the fifth resolver has to remember.
#
# One instance per resolver, reused — receive_claim is host-only and single-
# threaded, so the scratch below never overlaps a second claim.

var _catch: Vector3 = Vector3.ZERO
var _max_reach: float = 0.0
var _continuity: float = 0.0
var _fp := SkaterMovementRules.ForwardResult.new()


# Reconstructs the claimant at their self-view instant and loads the two bounds
# from their physical caps. False when there is no snapshot to reconstruct from —
# the caller must reject the claim rather than fall through to an unclamped one.
func resolve(registry: PlayerRegistry, peer_id: int, snap: SkaterNetworkState,
		ctrl: SkaterController, self_view_t: float, newest_ts: float) -> bool:
	_catch = Vector3.ZERO
	_max_reach = 0.0
	# No caps entry (can't-happen for a spawned claimant) leaves the reach clamp
	# off and the continuity clamp at its slack floor — still a valid bound.
	_continuity = LagCompRewind.blade_continuity_tolerance(0.0)
	if snap == null:
		return false
	_catch = LagCompRewind.self_view_catch_up(snap, ctrl, self_view_t, newest_ts, _fp)
	var caps: AISkaterCaps = registry.caps_by_peer.get(peer_id) if registry != null else null
	if caps != null:
		_max_reach = caps.max_blade_reach
		_continuity = LagCompRewind.blade_continuity_tolerance(caps.blade_speed)
	return true


# Displacement to ADD to any body-anchored quantity read from the claimant's
# self-view snapshot — position, blade_contact_world, top_hand_world all
# rigid-translate with the body.
func catch_up() -> Vector3:
	return _catch


func reach_clamp(point: Vector3, body: Vector3) -> Vector3:
	return LagCompRewind.clamp_client_blade(point, body + _catch, _max_reach)


func continuity_clamp(point: Vector3, reconstructed: Vector3) -> Vector3:
	return LagCompRewind.continuity_clamp(point, reconstructed + _catch, _continuity)


# Both bounds against one snapshot's blade — the whole treatment a client-sent
# blade point needs. Resolvers that measure between the two stages (pickup's
# blade-divergence telemetry) call the halves instead.
func clamp_blade(point: Vector3, snap: SkaterNetworkState) -> Vector3:
	return continuity_clamp(reach_clamp(point, snap.position), snap.blade_contact_world)
