class_name AICoverageAssignment

# Pure-function man-to-man coverage assignment for DZ defending. Given
# the current world state and per-team role assignments, returns
#   Dictionary[peer_id, opposing_peer_id]
# mapping each non-F1 defender to a specific opposing skater to mark.
#
# F1 is excluded (they pressure the puck) except in alone-back rush
# scenarios where F1 takes the carrier as a man-to-man mark — see
# the alone_back branch below. F2 takes the most dangerous off-puck
# opponent (closest to our net); F3 takes the next.
#
# Mark stickiness: if `prev_coverage` is provided and a defender's
# previous mark is still in the opponents pool, the defender keeps
# that mark instead of reshuffling to whoever is closest to net
# right now. Without stickiness, F1/F2/F3 role labels flicker every
# brain tick as the opp passes around the DZ — bots swap mark
# pairings even when the position-based assignment hasn't really
# changed. Stickiness eliminates that flicker.
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
		roles: Dictionary,
		prev_coverage: Dictionary = {}) -> Dictionary:
	var result: Dictionary = {}
	if snapshot == null or snapshot.puck_state == null or roles.is_empty():
		return result

	var carrier: int = snapshot.puck_state.carrier_peer_id

	# Find F1's peer_id once.
	var f1_pid: int = 0
	for pid: int in roles:
		if roles[pid] == AIRoleAssignment.ROLE_F1:
			f1_pid = pid
			break

	# Alone-back state: nobody on our team is between the puck and our
	# net. F1 is the closest-to-puck role and thus the natural one to
	# chase the carrier from behind during the backcheck — assign F1
	# the carrier as a man-to-man mark so OFF_PUCK uses a stable
	# defensive anchor (between carrier and our net at 1 m gap depth)
	# instead of the legacy "trail puck by 4 m" anchor.
	#
	# Skipped when puck is in our OZ (forecheck, not backcheck) and
	# when our team has the carrier (breakout, not coverage).
	var alone_back: bool = false
	if carrier != -1 and int(team_id_resolver.call(carrier)) != team_id:
		var puck_z: float = snapshot.puck_state.position.z
		var puck_in_our_oz: bool = -signf(own_goal_z) * puck_z > GameRules.BLUE_LINE_Z
		if not puck_in_our_oz:
			var puck_dist_net: float = absf(puck_z - own_goal_z)
			alone_back = true
			for pid: int in snapshot.skater_states:
				if int(team_id_resolver.call(pid)) != team_id:
					continue
				var tpos: Vector3 = snapshot.skater_states[pid].position
				if absf(tpos.z - own_goal_z) < puck_dist_net:
					alone_back = false
					break
	if alone_back and f1_pid != 0:
		result[f1_pid] = carrier

	# Whether the carrier should appear in the F2/F3 pool. The carrier
	# is excluded when F1 has them — either by being in position to
	# chase (forward of carrier, can pressure naturally) OR by the
	# alone-back assignment above. Otherwise (rare: F1 caught up-ice
	# but a teammate is back of puck) F2 picks up the carrier.
	var f1_in_position: bool = alone_back
	if not f1_in_position and carrier != -1 and f1_pid != 0:
		var f1_state: SkaterNetworkState = snapshot.skater_states.get(f1_pid)
		var carrier_state: SkaterNetworkState = snapshot.skater_states.get(carrier)
		if f1_state != null and carrier_state != null:
			var f1_dist_net: float = absf(f1_state.position.z - own_goal_z)
			var carrier_dist_net: float = absf(carrier_state.position.z - own_goal_z)
			f1_in_position = f1_dist_net <= carrier_dist_net

	# Collect opponents with their threat level (closer to our net =
	# more dangerous). Carrier excluded when F1 has them. Sorted
	# ascending — opponents[0] is the most dangerous.
	var opponents: Array = []  # [peer_id, distance_to_our_net]
	for peer_id: int in snapshot.skater_states:
		if int(team_id_resolver.call(peer_id)) == team_id:
			continue
		if peer_id == carrier and f1_in_position:
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

	# F2/F3 mark assignment with stickiness. First pass keeps any
	# previous mark that's still in the opponents pool; second pass
	# fills remaining roles greedily by danger (most-dangerous to F2,
	# next to F3). Stickiness is per-PEER (not per-role) so a bot
	# whose label flipped from F2 to F3 between ticks keeps their
	# defensive responsibility. The role label still drives WHICH
	# bots are eligible for marks (only F2 and F3) and the greedy
	# fallback ordering (F2 gets the most-dangerous available).
	var f2_pid: int = 0
	var f3_pid: int = 0
	for peer_id: int in roles:
		match roles[peer_id]:
			AIRoleAssignment.ROLE_F2:
				f2_pid = peer_id
			AIRoleAssignment.ROLE_F3:
				f3_pid = peer_id
	# Build a quick set of available opp pids for sticky-membership lookup.
	var available_set: Dictionary = {}
	for entry: Array in opponents:
		available_set[entry[0]] = true
	var f2_sticky: int = 0
	var f3_sticky: int = 0
	if f2_pid != 0:
		var prev_mark: int = prev_coverage.get(f2_pid, 0)
		if prev_mark != 0 and available_set.has(prev_mark):
			f2_sticky = prev_mark
	if f3_pid != 0:
		var prev_mark: int = prev_coverage.get(f3_pid, 0)
		if prev_mark != 0 and available_set.has(prev_mark) and prev_mark != f2_sticky:
			f3_sticky = prev_mark
	# Remaining opp pool for greedy fallback — exclude any sticky marks.
	var remaining: Array = []
	for entry: Array in opponents:
		if entry[0] == f2_sticky or entry[0] == f3_sticky:
			continue
		remaining.append(entry)
	# Assign F2 (sticky first, then most-dangerous remaining).
	if f2_pid != 0:
		if f2_sticky != 0:
			result[f2_pid] = f2_sticky
		elif remaining.size() >= 1:
			result[f2_pid] = remaining[0][0]
			remaining.pop_front()
	# Assign F3 (sticky first, then most-dangerous remaining).
	if f3_pid != 0:
		if f3_sticky != 0:
			result[f3_pid] = f3_sticky
		elif remaining.size() >= 1:
			result[f3_pid] = remaining[0][0]
			remaining.pop_front()

	return result
