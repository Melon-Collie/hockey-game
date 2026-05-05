class_name AIRoleSlots

# Pure-function role slot assignment for the v2 possession-state model.
# Replaces `role_assignment.gd` (closest-to-puck F1/F2/F3) and
# `coverage_assignment.gd` (man-to-man marks) with a single positional-
# slot system driven by `AIPossessionState`.
#
# Each team-level state has 3 slots. Some slots are FIXED (CARRIER is
# whoever holds the puck; SPRINT_BY is locked at state entry). Remaining
# slots are assigned via permutation enumeration with distance-threshold
# hysteresis — at most 3! = 6 permutations per brain tick (6 Hz), so
# the cost is trivial.
#
# Slot anchors are positional and rotate with the puck. The 1-2 zone
# defense (DZONE) shifts strong/weak side as the puck moves; OZONE's
# triangle rotates similarly.
#
# Mixed teams: humans are teammates and get slot assignments same as
# bots. The brain doesn't distinguish — humans drive the structure,
# bots auto-fill the gaps.

enum Slot {
	NONE,
	# Shared by multiple states.
	CARRIER,    # OZONE + TRANS_DO: peer with the puck.
	SPRINT_BY,  # TRANS_OD + TRANS_DO: locked at state entry, sprints to target.
	# DZONE — rotating 1-2 zone defense.
	PRESSURE,
	NET,
	INSIDE,
	# OZONE — extended OZ rotation.
	BACKDOOR,
	OUTLET,
	# TRANS_DO — sprint-by attack.
	SUPPORT,
	# TRANS_OD — sprint-by defend.
	F1,
	F2,
	# NEUTRAL — faceoff / fresh loose puck. Simple 1-2 shape.
	CHASE,      # closest to puck, pursues
	FLANK_L,    # left flank, slightly defensive of puck
	FLANK_R,    # right flank, slightly defensive of puck
}

# Hysteresis: a (peer, slot) pairing that doesn't match the previous
# tick's assignment costs an extra HYSTERESIS_PENALTY_M of "distance"
# in the cost function. Swaps only fire when the geometric improvement
# exceeds this threshold.
const HYSTERESIS_PENALTY_M: float = 1.5
# SPRINT_BY graduates off the role when within this distance of target.
const SPRINT_BY_GRADUATE_DIST_M: float = 2.0

# DZONE anchor constants.
const DZONE_PRESSURE_GAP_M: float = 1.5            # m goal-side of puck along puck→net line
const DZONE_NET_X_FROM_POST: float = 0.3           # m inside the strong-side post (toward center)
const DZONE_NET_Z_FROM_GOAL: float = 1.0           # m in front of goal line
const DZONE_INSIDE_X: float = 2.0                  # m weak-side of rink center
const DZONE_INSIDE_Z_FROM_GOAL: float = 4.0        # m in front of goal line (mid-slot depth)

# OZONE anchor constants.
const OZONE_BACKDOOR_X_FROM_POST: float = 0.5      # m inside the far post (toward center)
const OZONE_BACKDOOR_Z_FROM_GOAL: float = 1.0      # m in front of opp goal line
const OZONE_OUTLET_Z_PAST_BLUE: float = 2.0        # m past opp blue line into OZ

# TRANS_DO anchor constants.
const TRANS_DO_SPRINT_BY_X: float = 4.0            # m off rink center, weak-side
const TRANS_DO_SPRINT_BY_Z_FROM_BLUE: float = 1.0  # m on NZ side of opp blue line (offside-safe)
const TRANS_DO_SUPPORT_X: float = 3.0              # m weak-side of carrier
const TRANS_DO_SUPPORT_Z: float = 3.0              # m back of carrier toward our net

# TRANS_OD anchor constants.
const TRANS_OD_SPRINT_BY_Z_FROM_GOAL: float = 5.0  # m in front of own goal line (defensive slot)
const TRANS_OD_F1_GAP_M: float = 1.5               # m goal-side of puck (same as DZONE PRESSURE)
const TRANS_OD_F2_X: float = 2.0                   # m weak-side of puck
const TRANS_OD_F2_Z: float = 3.0                   # m back of puck toward our net

# NEUTRAL anchor constants. Simple 1-2 shape: CHASE pursues puck, two
# flankers stand off to either side slightly defensive of puck.
const NEUTRAL_FLANK_X: float = 3.0                 # m to either side of puck
const NEUTRAL_FLANK_Z_DEFENSIVE: float = 2.0       # m back of puck toward own net


# Returns the list of slots for a given state, in canonical order.
# CARRIER and SPRINT_BY (if applicable) come first since they're
# fixed-resolution slots — the assign() loop handles them first.
static func slots_for_state(state: int) -> Array:
	match state:
		AIPossessionState.State.DZONE:
			return [Slot.PRESSURE, Slot.NET, Slot.INSIDE]
		AIPossessionState.State.OZONE:
			return [Slot.CARRIER, Slot.BACKDOOR, Slot.OUTLET]
		AIPossessionState.State.TRANS_DO:
			return [Slot.CARRIER, Slot.SPRINT_BY, Slot.SUPPORT]
		AIPossessionState.State.TRANS_OD:
			return [Slot.SPRINT_BY, Slot.F1, Slot.F2]
		AIPossessionState.State.NEUTRAL:
			return [Slot.CHASE, Slot.FLANK_L, Slot.FLANK_R]
		_:
			return []


# Computes the world-space anchor for a slot in a given state.
# `carrier_pos` is needed by TRANS_DO SUPPORT (relative to carrier).
# `sprint_by_target` is the locked target for SPRINT_BY in TRANS states
# — caller passes Vector3.ZERO if not applicable.
static func slot_anchor(
		slot: Slot,
		state: int,
		puck_pos: Vector3,
		carrier_pos: Vector3,
		sprint_by_target: Vector3,
		own_goal_z: float,
		strong_x: float) -> Vector3:
	var own_goal_dir: float = signf(own_goal_z)
	var our_net := Vector3(0.0, 0.0, own_goal_z)

	match slot:
		Slot.CARRIER:
			# Carrier doesn't have a brain anchor — they're driven by
			# the carrier utility AI in `_state_carry`. Return their
			# current position so the slot's "distance" is zero.
			return carrier_pos

		Slot.SPRINT_BY:
			# Target was locked at state entry. Caller threads it through.
			return sprint_by_target

		Slot.PRESSURE:
			# 1.5 m goal-side of puck along the puck→our-net line.
			var to_net: Vector3 = our_net - puck_pos
			var l: float = sqrt(to_net.x * to_net.x + to_net.z * to_net.z)
			if l < 0.001:
				return puck_pos
			var step: float = DZONE_PRESSURE_GAP_M / l
			return Vector3(
					puck_pos.x + to_net.x * step,
					0.0,
					puck_pos.z + to_net.z * step)

		Slot.NET:
			return Vector3(
					strong_x * (GameRules.NET_HALF_WIDTH - DZONE_NET_X_FROM_POST),
					0.0,
					own_goal_dir * (GameRules.GOAL_LINE_Z - DZONE_NET_Z_FROM_GOAL))

		Slot.INSIDE:
			return Vector3(
					-strong_x * DZONE_INSIDE_X,
					0.0,
					own_goal_dir * (GameRules.GOAL_LINE_Z - DZONE_INSIDE_Z_FROM_GOAL))

		Slot.BACKDOOR:
			# Weak-side post in front of opp goal.
			return Vector3(
					-strong_x * (GameRules.NET_HALF_WIDTH - OZONE_BACKDOOR_X_FROM_POST),
					0.0,
					-own_goal_dir * (GameRules.GOAL_LINE_Z - OZONE_BACKDOOR_Z_FROM_GOAL))

		Slot.OUTLET:
			# High in OZ, shadows puck X.
			return Vector3(
					puck_pos.x,
					0.0,
					-own_goal_dir * (GameRules.BLUE_LINE_Z + OZONE_OUTLET_Z_PAST_BLUE))

		Slot.SUPPORT:
			# Behind carrier, weak-side.
			return Vector3(
					carrier_pos.x - strong_x * TRANS_DO_SUPPORT_X,
					0.0,
					carrier_pos.z + own_goal_dir * TRANS_DO_SUPPORT_Z)

		Slot.F1:
			# Same formula as DZONE PRESSURE.
			var to_net2: Vector3 = our_net - puck_pos
			var l2: float = sqrt(to_net2.x * to_net2.x + to_net2.z * to_net2.z)
			if l2 < 0.001:
				return puck_pos
			var step2: float = TRANS_OD_F1_GAP_M / l2
			return Vector3(
					puck_pos.x + to_net2.x * step2,
					0.0,
					puck_pos.z + to_net2.z * step2)

		Slot.F2:
			return Vector3(
					puck_pos.x - strong_x * TRANS_OD_F2_X,
					0.0,
					puck_pos.z + own_goal_dir * TRANS_OD_F2_Z)

		Slot.CHASE:
			# NEUTRAL chaser: anchor at puck. The bot's SM transitions
			# to CHASE_PUCK naturally via _should_chase_loose_puck once
			# they're closest, so this anchor is mostly a marker.
			return puck_pos

		Slot.FLANK_L:
			# Left flank, slightly defensive of puck so they're already
			# in position if F1 loses the draw.
			return Vector3(
					puck_pos.x - NEUTRAL_FLANK_X, 0.0,
					puck_pos.z + own_goal_dir * NEUTRAL_FLANK_Z_DEFENSIVE)

		Slot.FLANK_R:
			return Vector3(
					puck_pos.x + NEUTRAL_FLANK_X, 0.0,
					puck_pos.z + own_goal_dir * NEUTRAL_FLANK_Z_DEFENSIVE)

		_:
			return Vector3.ZERO


# Computes the locked SPRINT_BY target at TRANS state entry. Caller
# captures this once when entering a TRANS state and stores it.
static func compute_sprint_by_target(
		state: int,
		puck_pos: Vector3,
		own_goal_z: float,
		strong_x: float) -> Vector3:
	var own_goal_dir: float = signf(own_goal_z)
	match state:
		AIPossessionState.State.TRANS_OD:
			# Defensive slot center.
			return Vector3(
					0.0, 0.0,
					own_goal_dir * (GameRules.GOAL_LINE_Z - TRANS_OD_SPRINT_BY_Z_FROM_GOAL))
		AIPossessionState.State.TRANS_DO:
			# Weak-side at opp blue line, NZ-safe.
			return Vector3(
					-strong_x * TRANS_DO_SPRINT_BY_X, 0.0,
					-own_goal_dir * (GameRules.BLUE_LINE_Z - TRANS_DO_SPRINT_BY_Z_FROM_BLUE))
		_:
			return Vector3.ZERO


# Picks which peer is the SPRINT_BY at TRANS state entry. Returns
# peer_id, or 0 if no eligible peer found.
#
# TRANS_OD: furthest from own net (deepest forward, has the longest
# route home).
# TRANS_DO: furthest from opp net (deepest defender, has the longest
# route up-ice for the 2v1 / mismatch).
static func pick_sprint_by_peer(
		state: int,
		snapshot: WorldSnapshot,
		team_id: int,
		own_goal_z: float,
		team_id_resolver: Callable) -> int:
	if snapshot == null or snapshot.skater_states == null:
		return 0
	var reference_z: float = own_goal_z
	if state == AIPossessionState.State.TRANS_DO:
		reference_z = -own_goal_z
	var best_pid: int = 0
	var best_dist: float = -1.0
	for peer_id: int in snapshot.skater_states:
		if int(team_id_resolver.call(peer_id)) != team_id:
			continue
		# Skip the carrier in TRANS_DO — carrier is a separate slot.
		if state == AIPossessionState.State.TRANS_DO \
				and peer_id == snapshot.puck_state.carrier_peer_id:
			continue
		var pos: Vector3 = snapshot.skater_states[peer_id].position
		var d: float = absf(pos.z - reference_z)
		# Tiebreak by stable peer_id ordering so we don't flicker on
		# exactly-equal distances (rare but cheap to handle).
		if d > best_dist or (d == best_dist and peer_id < best_pid):
			best_dist = d
			best_pid = peer_id
	return best_pid


# Assigns each teammate to a slot. Returns Dictionary[peer_id, Slot].
#
# Fixed slots (CARRIER, SPRINT_BY) are resolved first. CARRIER goes to
# the puck holder if applicable. SPRINT_BY goes to the locked peer if
# applicable. Remaining slots are filled by permutation enumeration
# minimizing total distance + hysteresis penalty.
#
# `prev_assignments` is the previous tick's `Dictionary[peer_id, Slot]`.
# Pass an empty dict on the first tick or after a state change.
# `sprint_by_peer_id` is the peer locked into SPRINT_BY (0 if none).
# `sprint_by_target` is the locked target (only used by `slot_anchor`).
static func assign(
		snapshot: WorldSnapshot,
		team_id: int,
		own_goal_z: float,
		state: int,
		team_id_resolver: Callable,
		prev_assignments: Dictionary,
		sprint_by_peer_id: int,
		sprint_by_target: Vector3) -> Dictionary:
	var result: Dictionary = {}
	if snapshot == null:
		return result

	var slots: Array = slots_for_state(state)
	if slots.is_empty():
		return result

	# Collect our team's peers.
	var teammates: Array = []  # peer_ids
	for peer_id: int in snapshot.skater_states:
		if int(team_id_resolver.call(peer_id)) == team_id:
			teammates.append(peer_id)
	if teammates.is_empty():
		return result

	# Resolve fixed slots first.
	var fixed_peers: Dictionary = {}  # peer_id -> true
	var remaining_slots: Array = []
	for slot: Slot in slots:
		match slot:
			Slot.CARRIER:
				var carrier: int = snapshot.puck_state.carrier_peer_id if snapshot.puck_state else -1
				if carrier != -1 and int(team_id_resolver.call(carrier)) == team_id:
					result[carrier] = Slot.CARRIER
					fixed_peers[carrier] = true
				else:
					# No own carrier — slot stays unassigned, drop it.
					pass
			Slot.SPRINT_BY:
				if sprint_by_peer_id != 0 and not fixed_peers.has(sprint_by_peer_id):
					result[sprint_by_peer_id] = Slot.SPRINT_BY
					fixed_peers[sprint_by_peer_id] = true
				else:
					# No active sprint_by — drop the slot, the remaining
					# peers compete for the other slots only.
					pass
			_:
				remaining_slots.append(slot)

	# Filter peers down to those not already fixed.
	var remaining_peers: Array = []
	for pid: int in teammates:
		if not fixed_peers.has(pid):
			remaining_peers.append(pid)

	# If counts don't match, just zip in order (rare — only if team has
	# fewer peers than slots, e.g., 2-bot team).
	if remaining_peers.size() <= 1 or remaining_slots.size() <= 1:
		for i: int in min(remaining_peers.size(), remaining_slots.size()):
			result[remaining_peers[i]] = remaining_slots[i]
		return result

	# Permutation enumeration. n=2 or n=3, at most 6 perms.
	var puck_pos: Vector3 = snapshot.puck_state.position if snapshot.puck_state else Vector3.ZERO
	var carrier_pos: Vector3 = puck_pos
	var carrier_pid: int = snapshot.puck_state.carrier_peer_id if snapshot.puck_state else -1
	if carrier_pid != -1 and snapshot.skater_states.has(carrier_pid):
		carrier_pos = snapshot.skater_states[carrier_pid].position
	var strong_x: float = signf(puck_pos.x)
	if absf(puck_pos.x) < 0.5:
		# Center-puck: arbitrarily pick +1 to avoid 0.0. Hysteresis on
		# strong_x is upstream (`_hysteretic_strong_x` in SM); brain-side
		# computation is just the raw sign.
		strong_x = 1.0

	var anchors: Dictionary = {}  # slot -> Vector3
	for slot: Slot in remaining_slots:
		anchors[slot] = slot_anchor(
				slot, state, puck_pos, carrier_pos, sprint_by_target,
				own_goal_z, strong_x)

	var best_perm: Array = []
	var best_cost: float = INF
	for perm: Array in _permutations(remaining_peers):
		var cost: float = 0.0
		for i: int in remaining_slots.size():
			var slot: Slot = remaining_slots[i]
			var pid: int = perm[i]
			var pos: Vector3 = snapshot.skater_states[pid].position
			var anchor: Vector3 = anchors[slot]
			var dx: float = pos.x - anchor.x
			var dz: float = pos.z - anchor.z
			cost += sqrt(dx * dx + dz * dz)
			if prev_assignments.get(pid, Slot.NONE) != slot:
				cost += HYSTERESIS_PENALTY_M
		if cost < best_cost:
			best_cost = cost
			best_perm = perm.duplicate()

	for i: int in remaining_slots.size():
		result[best_perm[i]] = remaining_slots[i]
	return result


# All permutations of an array. Used internally by assign() — for n=2
# returns 2 perms, for n=3 returns 6. Inputs > 3 are theoretically
# possible but unused at 3v3 (max 3 teammates in remaining_peers).
static func _permutations(arr: Array) -> Array:
	if arr.size() <= 1:
		return [arr.duplicate()]
	var result: Array = []
	for i: int in arr.size():
		var rest: Array = arr.duplicate()
		var pivot = rest.pop_at(i)
		for sub: Array in _permutations(rest):
			var p: Array = [pivot]
			p.append_array(sub)
			result.append(p)
	return result


# Helper for the brain: returns true if the peer assigned SPRINT_BY has
# reached their target and should "graduate" off the role.
static func sprint_by_should_graduate(
		sprint_by_peer_id: int,
		sprint_by_target: Vector3,
		snapshot: WorldSnapshot) -> bool:
	if sprint_by_peer_id == 0 or snapshot == null:
		return false
	if not snapshot.skater_states.has(sprint_by_peer_id):
		return false
	var pos: Vector3 = snapshot.skater_states[sprint_by_peer_id].position
	var dx: float = pos.x - sprint_by_target.x
	var dz: float = pos.z - sprint_by_target.z
	return sqrt(dx * dx + dz * dz) <= SPRINT_BY_GRADUATE_DIST_M
