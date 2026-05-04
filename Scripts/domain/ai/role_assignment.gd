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
# Role-yield to humans. If the closest teammate to the puck is a bot
# but a human teammate's distance is within this fraction of the
# bot's, swap them — the human takes F1. Spec § 12: the player gets
# first refusal on a 50-50 puck, bots are support. Only fires when
# the human is genuinely competitive; a human 5 m away while a bot
# is 1 m away keeps the bot on F1.
const HUMAN_F1_PROXIMITY_TOLERANCE: float = 0.20


# Returns Dictionary[int, StringName] keyed by peer_id for every skater on
# the given team_id present in the snapshot. Assigns F1 / F2 / F3 in
# rank order; extra teammates (rare — 4+ on a team) get OFF.
#
# `is_human_resolver` returns true when the given peer_id is a real
# human (ENet peer) rather than a bot. Used to apply the role-yield
# rule (see HUMAN_F1_PROXIMITY_TOLERANCE).
static func compute(snapshot: WorldSnapshot, team_id: int,
		team_id_resolver: Callable, is_human_resolver: Callable) -> Dictionary:
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

	# F3 high-man pin: outside our own DZ, the deepest non-carrier
	# teammate (closest to own net AND back of the puck) is locked as
	# F3 regardless of distance to puck. Without this rule a loose puck
	# near the high man rotated them to F1 → CHASE_PUCK, leaving the
	# team with no last line of defense and giving up easy odd-man
	# rushes on turnover. Real-hockey 3v3 rule: the high man doesn't
	# pinch unless there's clear support behind. Skipped in DZ since
	# coverage_assignment owns the defensive shape there.
	#
	# Gates:
	#   - Puck NOT in our own zone (NZ or OZ scenarios only).
	#   - 3+ teammates (a 2-teammate team has no F3 to pin).
	#   - The deepest non-carrier is genuinely back of the puck —
	#     dist_to_own_net < puck dist_to_own_net. If everyone's forward
	#     of the puck (full rush), there's no high-man to pin.
	if not snapshot.skater_states.is_empty() and ranked.size() >= 3:
		var puck_pos: Vector3 = snapshot.puck_state.position
		var own_goal_dir: float = 1.0 if team_id == 0 else -1.0
		var puck_in_own_zone: bool = own_goal_dir * puck_pos.z > GameRules.BLUE_LINE_Z
		if not puck_in_own_zone:
			var own_goal_z: float = own_goal_dir * GameRules.GOAL_LINE_Z
			var puck_dist: float = absf(puck_pos.z - own_goal_z)
			var carrier: int = snapshot.puck_state.carrier_peer_id
			var deepest_idx: int = -1
			var deepest_dist: float = INF
			for i: int in ranked.size():
				var pid: int = ranked[i][0]
				if pid == carrier:
					continue
				var pos: Vector3 = snapshot.skater_states[pid].position
				var d: float = absf(pos.z - own_goal_z)
				if d < deepest_dist:
					deepest_idx = i
					deepest_dist = d
			# Only pin if the deepest is meaningfully back of the puck.
			if deepest_idx >= 0 and deepest_dist < puck_dist and deepest_idx != 2:
				var deepest_entry: Array = ranked[deepest_idx]
				ranked.remove_at(deepest_idx)
				ranked.insert(2, deepest_entry)

	# Role-yield: if F1 (rank 0) is currently a bot, find the highest-
	# ranked human within the proximity tolerance and promote them.
	# Tolerance compares distance (sqrt of d²) — squaring it gives the
	# d² threshold we can compare against directly without a sqrt call.
	var f1_pid: int = ranked[0][0]
	if not bool(is_human_resolver.call(f1_pid)):
		var threshold_factor: float = (1.0 + HUMAN_F1_PROXIMITY_TOLERANCE) ** 2
		var f1_d2: float = ranked[0][1]
		for i: int in range(1, ranked.size()):
			var pid: int = ranked[i][0]
			if not bool(is_human_resolver.call(pid)):
				continue
			if ranked[i][1] <= f1_d2 * threshold_factor:
				# Swap into rank 0. Human becomes F1; bot drops one rank.
				var promoted: Array = ranked[i]
				ranked.remove_at(i)
				ranked.insert(0, promoted)
				break

	const ROLE_BY_RANK: Array[StringName] = [ROLE_F1, ROLE_F2, ROLE_F3]
	for i: int in ranked.size():
		var pid: int = ranked[i][0]
		if i < ROLE_BY_RANK.size():
			roles[pid] = ROLE_BY_RANK[i]
		else:
			roles[pid] = ROLE_OFF
	return roles
