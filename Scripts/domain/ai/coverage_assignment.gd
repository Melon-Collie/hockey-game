class_name AICoverageAssignment

# Pure-function man-to-man coverage assignment for DZ defending. Given
# the current world state and per-team role assignments, returns
#   Dictionary[peer_id, opposing_peer_id]
# mapping each non-F1 defender to a specific opposing skater to mark.
#
# F1 is excluded — they pressure the puck, not a man. F2 takes the
# most dangerous off-puck opponent (closest to our net); F3 takes the
# next. Greedy nearest-mark is sufficient at 3v3 — at most 2 defenders
# vs 2 marks, no permutation conflicts.
#
# When to USE the result is a separate decision the SM owns: man-to-man
# fires when in DZ + not in own possession, otherwise the SM ignores
# coverage_targets and uses zone anchors. This function always computes
# the assignment so brain-tick cadence stays uniform — the cost is
# negligible (sort 2 opponents at 6 Hz).

# Computes coverage. Returns peer_id → opposing_peer_id. Defenders
# without a mark (e.g. 4-vs-2 game where the team has more defenders
# than opponents) are simply absent from the dict.
static func compute(
		snapshot: WorldSnapshot,
		team_id: int,
		own_goal_z: float,
		team_id_resolver: Callable,
		roles: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	if snapshot == null or snapshot.puck_state == null or roles.is_empty():
		return result

	# Collect non-carrier opponents with their threat level (closer to
	# our net = more dangerous). Sorted ascending — opponents[0] is
	# the most dangerous.
	var carrier: int = snapshot.puck_state.carrier_peer_id
	var opponents: Array = []  # [peer_id, distance_to_our_net]
	for peer_id: int in snapshot.skater_states:
		if int(team_id_resolver.call(peer_id)) == team_id:
			continue
		if peer_id == carrier:
			# F1 covers the carrier through chase, not man marking.
			continue
		var pos: Vector3 = snapshot.skater_states[peer_id].position
		var d: float = absf(pos.z - own_goal_z)
		opponents.append([peer_id, d])
	# Stable peer_id tiebreak so coverage doesn't flicker between F2 / F3
	# when two opps tie on distance.
	opponents.sort_custom(func(a: Array, b: Array) -> bool:
		if a[1] != b[1]:
			return a[1] < b[1]
		return a[0] < b[0])

	# F2 takes the most dangerous opp; F3 takes the next. Assignment is
	# explicit by role rather than positional — F2 is whoever the
	# AIRoleAssignment says is F2 (it ranks by predicted distance to
	# puck, which is independent of our net distance).
	for peer_id: int in roles:
		var role: StringName = roles[peer_id]
		if role == AIRoleAssignment.ROLE_F2 and opponents.size() >= 1:
			result[peer_id] = opponents[0][0]
		elif role == AIRoleAssignment.ROLE_F3 and opponents.size() >= 2:
			result[peer_id] = opponents[1][0]
	return result
