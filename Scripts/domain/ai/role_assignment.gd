class_name AIRoleAssignment

# Pure-function role picker. Stateless — TeamBrain owns hysteresis and tick
# cadence.
#
# Roles, in priority order:
#   F1 — puck pressure. Closest teammate to puck (predicted position).
#        Chases loose pucks, carries when held, applies pressure to opp
#        carrier.
#   F2 — triangle apex on the strong side. Second-closest teammate.
#        Offers a strong-side support presence near the puck.
#   F3 — weak-side support. Third-closest. Trails on weak side, safety
#        valve.
#   OFF — fallback for any extra teammates beyond three (4v4 etc).
#
# Distance is computed on PREDICTED positions at F1_LOOKAHEAD_S so a
# bot already turning toward the puck wins F1 over a stationary closer
# bot. Stable sort with peer_id tiebreak keeps role assignment from
# flickering when distances tie.

const ROLE_F1: StringName = &"F1"
const ROLE_F2: StringName = &"F2"
const ROLE_F3: StringName = &"F3"
const ROLE_OFF: StringName = &"OFF"

# How far ahead to project skaters and the puck when ranking. Short
# enough that ordinary play doesn't mis-pick (skater velocities aren't
# wildly different at < 0.5 s lookahead) and long enough that intent
# matters (a bot accelerating toward the puck beats a coasting one).
const F1_LOOKAHEAD_S: float = 0.5


# Returns Dictionary[int, StringName] keyed by peer_id for every skater on
# the given team_id present in the snapshot. Assigns F1 / F2 / F3 in
# rank order; extra teammates (rare — 4+ on a team) get OFF.
static func compute(snapshot: WorldSnapshot, team_id: int, team_id_resolver: Callable) -> Dictionary:
	var roles: Dictionary = {}
	if snapshot == null or snapshot.puck_state == null or snapshot.skater_states.is_empty():
		return roles
	# Predicted puck position (where we expect it to be in F1_LOOKAHEAD_S).
	var future_puck: Vector3 = AITrajectory.predict_at(
			snapshot.puck_state.position, snapshot.puck_state.velocity,
			F1_LOOKAHEAD_S)

	# Collect teammates with predicted-distance scores.
	var ranked: Array = []  # [peer_id, d2] pairs
	for peer_id: int in snapshot.skater_states:
		if int(team_id_resolver.call(peer_id)) != team_id:
			continue
		var s: SkaterNetworkState = snapshot.skater_states[peer_id]
		var future_skater: Vector3 = AITrajectory.predict_at(
				s.position, s.velocity, F1_LOOKAHEAD_S)
		var dx: float = future_skater.x - future_puck.x
		var dz: float = future_skater.z - future_puck.z
		ranked.append([peer_id, dx * dx + dz * dz])

	if ranked.is_empty():
		return roles
	# Sort by predicted d² ascending; stable peer_id tiebreak so ties don't
	# flicker between bots.
	ranked.sort_custom(func(a: Array, b: Array) -> bool:
		if a[1] != b[1]:
			return a[1] < b[1]
		return a[0] < b[0])

	const ROLE_BY_RANK: Array[StringName] = [ROLE_F1, ROLE_F2, ROLE_F3]
	for i: int in ranked.size():
		var pid: int = ranked[i][0]
		if i < ROLE_BY_RANK.size():
			roles[pid] = ROLE_BY_RANK[i]
		else:
			roles[pid] = ROLE_OFF
	return roles
