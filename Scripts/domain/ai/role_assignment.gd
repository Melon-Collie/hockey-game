class_name AIRoleAssignment

# Pure-function role picker. Stateless — TeamBrain owns hysteresis and tick
# cadence. Phase 4 ships only F1 (puck pressure) vs OFF (above-puck anchor);
# the F2/F3 split lands in a later phase.
#
# F1 = teammate with smallest 2D distance to puck. No "above the puck" gate
# in this phase — pick whoever is closest, even if they're behind it. The
# Phase 3 anchor for OFF bots already pulls them above; chasing from below
# happens, but it's a known cost of MVP simplicity.

const ROLE_F1: StringName = &"F1"
const ROLE_OFF: StringName = &"OFF"


# Returns Dictionary[int, StringName] keyed by peer_id for every skater on
# the given team_id present in the snapshot. Always assigns exactly one F1
# (the closest teammate to the puck); the rest get OFF. If the team has no
# skaters in the snapshot, returns an empty dictionary.
static func compute(snapshot: WorldSnapshot, team_id: int) -> Dictionary:
	var roles: Dictionary = {}
	if snapshot == null or snapshot.num_skaters == 0:
		return roles
	var puck_xz := Vector2(snapshot.puck_pos.x, snapshot.puck_pos.z)
	var closest_idx: int = -1
	var closest_d2: float = INF
	for i: int in snapshot.num_skaters:
		if snapshot.skater_team[i] != team_id:
			continue
		var p: Vector3 = snapshot.skater_pos[i]
		var dx: float = p.x - puck_xz.x
		var dz: float = p.z - puck_xz.y
		var d2: float = dx * dx + dz * dz
		if d2 < closest_d2:
			closest_d2 = d2
			closest_idx = i
	if closest_idx < 0:
		return roles
	for i: int in snapshot.num_skaters:
		if snapshot.skater_team[i] != team_id:
			continue
		roles[snapshot.skater_peer_id[i]] = ROLE_F1 if i == closest_idx else ROLE_OFF
	return roles
