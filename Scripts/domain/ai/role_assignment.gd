class_name AIRoleAssignment

# Pure-function role picker. Stateless — TeamBrain owns hysteresis and tick
# cadence. Phase 4 ships only F1 (puck pressure) vs OFF (above-puck anchor);
# the F2/F3 split lands in a later phase.
#
# F1 = teammate with smallest 2D distance to puck. No "above the puck" gate
# in this phase — pick whoever is closest, even if they're behind it. The
# Phase 3 anchor for OFF bots already pulls them above; chasing from below
# happens, but it's a known cost of MVP simplicity.
#
# Consumes the existing WorldSnapshot (Scripts/networking/world_snapshot.gd)
# captured by StateBufferManager. team_id is not on SkaterNetworkState, so
# callers pass a Callable resolver: `func(peer_id: int) -> int`.

const ROLE_F1: StringName = &"F1"
const ROLE_OFF: StringName = &"OFF"


# Returns Dictionary[int, StringName] keyed by peer_id for every skater on
# the given team_id present in the snapshot. Always assigns exactly one F1
# (the closest teammate to the puck); the rest get OFF. If the team has no
# skaters in the snapshot, returns an empty dictionary.
static func compute(snapshot: WorldSnapshot, team_id: int, team_id_resolver: Callable) -> Dictionary:
	var roles: Dictionary = {}
	if snapshot == null or snapshot.puck_state == null or snapshot.skater_states.is_empty():
		return roles
	var puck_x: float = snapshot.puck_state.position.x
	var puck_z: float = snapshot.puck_state.position.z
	# closest_peer starts at 0 as a placeholder. We use closest_d2 == INF as
	# the "found nothing" sentinel because bot peer_ids are negative (-1..-6),
	# so a < 0 check would false-positive whenever a bot wins F1.
	var closest_peer: int = 0
	var closest_d2: float = INF
	for peer_id: int in snapshot.skater_states:
		if int(team_id_resolver.call(peer_id)) != team_id:
			continue
		var s: SkaterNetworkState = snapshot.skater_states[peer_id]
		var dx: float = s.position.x - puck_x
		var dz: float = s.position.z - puck_z
		var d2: float = dx * dx + dz * dz
		if d2 < closest_d2:
			closest_d2 = d2
			closest_peer = peer_id
	if closest_d2 == INF:
		return roles
	for peer_id: int in snapshot.skater_states:
		if int(team_id_resolver.call(peer_id)) != team_id:
			continue
		roles[peer_id] = ROLE_F1 if peer_id == closest_peer else ROLE_OFF
	return roles
