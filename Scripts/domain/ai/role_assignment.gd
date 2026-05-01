class_name AIRoleAssignment

# Pure-function role picker. Stateless — TeamBrain owns hysteresis and tick
# cadence. Today: F1 (puck pressure) vs OFF (above-puck anchor). The
# F2/F3 split lands in a later phase.
#
# F1 = teammate whose predicted XZ position in F1_LOOKAHEAD_S is closest
# to the puck's predicted position. Velocity weighting beats raw distance:
# a bot already turning toward the puck wins F1 over a stationary bot
# slightly closer.

const ROLE_F1: StringName = &"F1"
const ROLE_OFF: StringName = &"OFF"

# How far ahead to project skaters and the puck when picking F1. Short
# enough that ordinary play doesn't mis-pick (skaters' velocities aren't
# that different at < 0.5 s lookahead) and long enough that intent
# matters (a bot accelerating toward the puck beats a coasting one).
const F1_LOOKAHEAD_S: float = 0.5


# Returns Dictionary[int, StringName] keyed by peer_id for every skater on
# the given team_id present in the snapshot. Always assigns exactly one F1
# (the closest teammate to the puck); the rest get OFF. If the team has no
# skaters in the snapshot, returns an empty dictionary.
static func compute(snapshot: WorldSnapshot, team_id: int, team_id_resolver: Callable) -> Dictionary:
	var roles: Dictionary = {}
	if snapshot == null or snapshot.puck_state == null or snapshot.skater_states.is_empty():
		return roles
	# Predicted puck position (where we expect it to be in F1_LOOKAHEAD_S).
	var puck_pos: Vector3 = snapshot.puck_state.position
	var puck_vel: Vector3 = snapshot.puck_state.velocity
	var future_puck_x: float = puck_pos.x + puck_vel.x * F1_LOOKAHEAD_S
	var future_puck_z: float = puck_pos.z + puck_vel.z * F1_LOOKAHEAD_S
	# closest_peer starts at 0 as a placeholder. We use closest_d2 == INF as
	# the "found nothing" sentinel because peer_ids can take any sign in
	# legacy code paths and we want this to be value-agnostic.
	var closest_peer: int = 0
	var closest_d2: float = INF
	for peer_id: int in snapshot.skater_states:
		if int(team_id_resolver.call(peer_id)) != team_id:
			continue
		var s: SkaterNetworkState = snapshot.skater_states[peer_id]
		# Predicted skater position — same lookahead as the puck.
		var future_x: float = s.position.x + s.velocity.x * F1_LOOKAHEAD_S
		var future_z: float = s.position.z + s.velocity.z * F1_LOOKAHEAD_S
		var dx: float = future_x - future_puck_x
		var dz: float = future_z - future_puck_z
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
