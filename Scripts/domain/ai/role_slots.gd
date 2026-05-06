class_name AIRoleSlots

# Pure-function role slot assignment for the v2 possession-state model.
# Roles are assigned per brain tick by current geometry — closest peer
# to each slot anchor wins via permutation enumeration with distance
# hysteresis. No locking, no sticky state — the bot whose body is
# already in the right place gets the role, which means roles tend
# to "stick" naturally as long as nothing geometric reshuffles.
#
# In TRANS states the assignment encodes "lean into what you're
# already doing": the deepest forward bot becomes OUTLET (TRANS_DO)
# or COVER (TRANS_OD), the deepest defender becomes SUPPORT (TRANS_DO)
# or HOME (TRANS_OD). No sprint-by lock needed because the up-ice
# bot is naturally closest to the up-ice anchor and the deep bot is
# naturally closest to the deep anchor.
#
# Mixed teams: humans are teammates and get slot assignments same as
# bots. The brain doesn't distinguish — humans drive the structure,
# bots auto-fill the gaps.

enum Slot {
	NONE,
	# Shared by multiple states.
	CARRIER,    # OZONE + TRANS_DO: peer with the puck.
	# DZONE — rotating 1-2 zone defense.
	PRESSURE,
	NET,
	INSIDE,
	# OZONE — extended OZ rotation.
	BACKDOOR,
	OUTLET,     # OZONE: high in OZ. TRANS_DO: weak-side at opp blue line.
	# TRANS_DO — geometric assignment, no locking.
	SUPPORT,    # closest-to-own-net non-carrier; behind carrier weak-side.
	# TRANS_OD — geometric assignment with HOME pre-pick.
	HOME,       # highest player (closest to opp net); backchecks to slot.
	COVER,      # remaining; back-of-puck weak-side, second-wave defense.
	# NEUTRAL + TRANS_OD — chases puck (anchor differs by state).
	CHASE,      # NEUTRAL: at puck. TRANS_OD: 1.5m goal-side of puck.
	# NEUTRAL — faceoff / fresh loose puck. Simple 1-2 shape.
	FLANK_L,    # left flank, slightly defensive of puck
	FLANK_R,    # right flank, slightly defensive of puck
}

# Hysteresis: a (peer, slot) pairing that doesn't match the previous
# tick's assignment costs an extra HYSTERESIS_PENALTY_M of "distance"
# in the cost function. Swaps only fire when the geometric improvement
# exceeds this threshold.
const HYSTERESIS_PENALTY_M: float = 1.5

# DZONE anchor constants.
const DZONE_PRESSURE_GAP_M: float = 1.5            # m goal-side of puck along puck→net line
const DZONE_NET_X_FROM_POST: float = 0.3           # m inside the strong-side post (toward center)
const DZONE_NET_Z_FROM_GOAL: float = 1.0           # m in front of goal line
const DZONE_INSIDE_X: float = 2.0                  # m weak-side of rink center
const DZONE_INSIDE_Z_FROM_GOAL: float = 4.0        # m in front of goal line (mid-slot depth)

# OZONE anchor constants.
const OZONE_BACKDOOR_X_FROM_POST: float = 0.5      # m inside the far post (toward center)
# Pulled back from 1m to 3m to keep BACKDOOR off the goal line — the
# bot is at slot depth instead of crease depth, less likely to body-
# block teammate shots. Tip / step-out / hold decision in
# `_backdoor_decision` (SM) handles incoming-puck reactions on top.
const OZONE_BACKDOOR_Z_FROM_GOAL: float = 3.0      # m in front of opp goal line
const OZONE_OUTLET_Z_PAST_BLUE: float = 2.0        # m past opp blue line into OZ

# TRANS_DO anchor constants.
const TRANS_DO_OUTLET_X: float = 4.0               # m off rink center, weak-side
const TRANS_DO_OUTLET_Z_FROM_BLUE: float = 2.5     # m on NZ side of opp blue line (offside-safe; bumped from 1m for offside slack)
# OUTLET shouldn't get more than this far up-ice from the puck.
# Without the cap, OUTLET sprints to the blue line even when the
# puck is still in our DZ — they're 30+ m ahead of the play.
const TRANS_DO_OUTLET_MAX_LEAD_M: float = 10.0
const TRANS_DO_SUPPORT_X: float = 3.0              # m weak-side of carrier
const TRANS_DO_SUPPORT_Z: float = 3.0              # m back of carrier toward our net

# TRANS_OD anchor constants.
const TRANS_OD_HOME_Z_FROM_GOAL: float = 5.0       # m in front of own goal line (defensive slot)
const TRANS_OD_CHASE_GAP_M: float = 1.5            # m goal-side of puck (same as DZONE PRESSURE)
const TRANS_OD_COVER_X: float = 2.0                # m weak-side of puck
const TRANS_OD_COVER_Z: float = 3.0                # m back of puck toward our net

# NEUTRAL anchor constants. Simple 1-2 shape: CHASE pursues puck, two
# flankers stand off to either side slightly defensive of puck.
const NEUTRAL_FLANK_X: float = 3.0                 # m to either side of puck
const NEUTRAL_FLANK_Z_DEFENSIVE: float = 2.0       # m back of puck toward own net


# Returns the list of slots for a given state, in canonical order.
# CARRIER (if applicable) is the only fixed-resolution slot — all
# others are filled by the permutation enumeration.
static func slots_for_state(state: int) -> Array:
	match state:
		AIPossessionState.State.DZONE:
			return [Slot.PRESSURE, Slot.NET, Slot.INSIDE]
		AIPossessionState.State.OZONE:
			return [Slot.CARRIER, Slot.BACKDOOR, Slot.OUTLET]
		AIPossessionState.State.TRANS_DO:
			return [Slot.CARRIER, Slot.OUTLET, Slot.SUPPORT]
		AIPossessionState.State.TRANS_OD:
			return [Slot.HOME, Slot.CHASE, Slot.COVER]
		AIPossessionState.State.NEUTRAL:
			return [Slot.CHASE, Slot.FLANK_L, Slot.FLANK_R]
		_:
			return []


# Computes the world-space anchor for a slot in a given state.
# `carrier_pos` is needed by TRANS_DO SUPPORT (relative to carrier).
static func slot_anchor(
		slot: Slot,
		state: int,
		puck_pos: Vector3,
		carrier_pos: Vector3,
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
			if state == AIPossessionState.State.TRANS_DO:
				# Weak-side at opp blue line, NZ-safe (offside buffer).
				# Capped: OUTLET shouldn't be more than
				# TRANS_DO_OUTLET_MAX_LEAD_M up-ice of the puck (the
				# play). Without the cap, OUTLET parks at the blue
				# line even when the carrier is still deep in our DZ.
				#
				# Signed depth: own_goal_dir * z grows toward own
				# goal. Smaller depth = further up-ice. OUTLET's
				# minimum depth = puck_depth − MAX_LEAD_M.
				var base_z: float = -own_goal_dir * (GameRules.BLUE_LINE_Z - TRANS_DO_OUTLET_Z_FROM_BLUE)
				var puck_depth: float = own_goal_dir * puck_pos.z
				var min_depth: float = puck_depth - TRANS_DO_OUTLET_MAX_LEAD_M
				var base_depth: float = own_goal_dir * base_z
				var capped_depth: float = maxf(base_depth, min_depth)
				return Vector3(
						-strong_x * TRANS_DO_OUTLET_X, 0.0,
						own_goal_dir * capped_depth)
			# OZONE OUTLET: high in OZ, shadows puck X.
			return Vector3(
					puck_pos.x,
					0.0,
					-own_goal_dir * (GameRules.BLUE_LINE_Z + OZONE_OUTLET_Z_PAST_BLUE))

		Slot.SUPPORT:
			# Behind carrier, weak-side. Closest-to-own-net non-carrier
			# wins this naturally via the permutation cost.
			return Vector3(
					carrier_pos.x - strong_x * TRANS_DO_SUPPORT_X,
					0.0,
					carrier_pos.z + own_goal_dir * TRANS_DO_SUPPORT_Z)

		Slot.HOME:
			# Defensive slot center. Closest-to-own-net peer wins.
			return Vector3(
					0.0, 0.0,
					own_goal_dir * (GameRules.GOAL_LINE_Z - TRANS_OD_HOME_Z_FROM_GOAL))

		Slot.COVER:
			# Back of puck, weak-side. Second-wave defender for the bot
			# whose role isn't HOME or CHASE — typically the deep
			# defender, who gets pulled forward by this anchor to
			# engage the play.
			return Vector3(
					puck_pos.x - strong_x * TRANS_OD_COVER_X,
					0.0,
					puck_pos.z + own_goal_dir * TRANS_OD_COVER_Z)

		Slot.CHASE:
			if state == AIPossessionState.State.TRANS_OD:
				# 1.5m goal-side of puck (same formula as DZONE PRESSURE).
				var to_net2: Vector3 = our_net - puck_pos
				var l2: float = sqrt(to_net2.x * to_net2.x + to_net2.z * to_net2.z)
				if l2 < 0.001:
					return puck_pos
				var step2: float = TRANS_OD_CHASE_GAP_M / l2
				return Vector3(
						puck_pos.x + to_net2.x * step2,
						0.0,
						puck_pos.z + to_net2.z * step2)
			# NEUTRAL: anchor at puck position. The bot's SM transitions
			# to CHASE_PUCK naturally via _should_chase_loose_puck once
			# they're closest.
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


# Assigns each teammate to a slot. Returns Dictionary[peer_id, Slot].
#
# CARRIER is the only fixed slot — goes to the puck holder if they're
# on our team. Remaining slots are filled by permutation enumeration
# minimizing total distance + hysteresis penalty (1.5 m).
#
# `prev_assignments` is the previous tick's `Dictionary[peer_id, Slot]`.
# Pass an empty dict on the first tick or after a state change.
static func assign(
		snapshot: WorldSnapshot,
		team_id: int,
		own_goal_z: float,
		state: int,
		team_id_resolver: Callable,
		prev_assignments: Dictionary,
		strong_x: float = 1.0) -> Dictionary:
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

	# Resolve fixed CARRIER first if applicable.
	var fixed_peers: Dictionary = {}  # peer_id -> true
	var remaining_slots: Array = []
	for slot: Slot in slots:
		if slot == Slot.CARRIER:
			var carrier: int = snapshot.puck_state.carrier_peer_id if snapshot.puck_state else -1
			if carrier != -1 and int(team_id_resolver.call(carrier)) == team_id:
				result[carrier] = Slot.CARRIER
				fixed_peers[carrier] = true
		else:
			remaining_slots.append(slot)

	# TRANS_OD HOME pre-pick: assign HOME to the highest-up-ice
	# teammate (closest to opp net = furthest from our net). Without
	# this, the closest-to-net peer would naturally be assigned HOME
	# by permutation cost — leaving the deep bot stuck at the slot
	# with nothing to do during NZ play. Pre-picking flips it so the
	# up-ice bot becomes the active backchecker; the deep bot drops
	# into COVER (back-of-puck) and engages the play.
	if state == AIPossessionState.State.TRANS_OD:
		var opp_goal_z: float = -own_goal_z
		var home_pid: int = 0
		var home_dist: float = INF
		for pid: int in snapshot.skater_states:
			if int(team_id_resolver.call(pid)) != team_id:
				continue
			if fixed_peers.has(pid):
				continue
			var d: float = absf(snapshot.skater_states[pid].position.z - opp_goal_z)
			if d < home_dist or (d == home_dist and pid < home_pid):
				home_dist = d
				home_pid = pid
		if home_pid != 0 and Slot.HOME in remaining_slots:
			result[home_pid] = Slot.HOME
			fixed_peers[home_pid] = true
			remaining_slots.erase(Slot.HOME)

	# Filter peers down to those not already fixed.
	var remaining_peers: Array = []
	for pid: int in teammates:
		if not fixed_peers.has(pid):
			remaining_peers.append(pid)

	# Anchors are needed for the 1-peer geometric pick AND for permutation
	# enumeration below — compute once.
	var puck_pos: Vector3 = snapshot.puck_state.position if snapshot.puck_state else Vector3.ZERO
	var carrier_pos: Vector3 = puck_pos
	var carrier_pid: int = snapshot.puck_state.carrier_peer_id if snapshot.puck_state else -1
	if carrier_pid != -1 and snapshot.skater_states.has(carrier_pid):
		carrier_pos = snapshot.skater_states[carrier_pid].position

	var anchors: Dictionary = {}  # slot -> Vector3
	for slot: Slot in remaining_slots:
		anchors[slot] = slot_anchor(
				slot, state, puck_pos, carrier_pos,
				own_goal_z, strong_x)

	# Empty cases — nothing to assign.
	if remaining_peers.is_empty() or remaining_slots.is_empty():
		return result

	# Single-peer case (e.g. 2-bot team with carrier teammate, leaving 1
	# remaining peer for 2 slots): pick the geometrically-best slot
	# rather than slots[0]. Permutation enumeration below assumes matched
	# peer/slot counts, so this case has its own pick.
	if remaining_peers.size() == 1:
		var pid: int = remaining_peers[0]
		var pos: Vector3 = snapshot.skater_states[pid].position
		var best_slot: Slot = remaining_slots[0]
		var best_d: float = INF
		for slot: Slot in remaining_slots:
			var anchor: Vector3 = anchors[slot]
			var dx: float = pos.x - anchor.x
			var dz: float = pos.z - anchor.z
			var d: float = dx * dx + dz * dz
			if d < best_d:
				best_d = d
				best_slot = slot
		result[pid] = best_slot
		return result

	# Single-slot case: same shape, pick the closest peer.
	if remaining_slots.size() == 1:
		var slot: Slot = remaining_slots[0]
		var anchor: Vector3 = anchors[slot]
		var best_pid: int = remaining_peers[0]
		var best_d2: float = INF
		for pid_c: int in remaining_peers:
			var pos_c: Vector3 = snapshot.skater_states[pid_c].position
			var dx_c: float = pos_c.x - anchor.x
			var dz_c: float = pos_c.z - anchor.z
			var d_c: float = dx_c * dx_c + dz_c * dz_c
			if d_c < best_d2:
				best_d2 = d_c
				best_pid = pid_c
		result[best_pid] = slot
		return result

	# Permutation enumeration. n=2 or n=3, at most 6 perms.
	# (puck_pos / carrier_pos / anchors were computed above for the
	# single-peer / single-slot fast paths.)
	var best_perm: Array = []
	var best_cost: float = INF
	for perm: Array in _permutations(remaining_peers):
		var cost: float = 0.0
		for i: int in remaining_slots.size():
			var slot_p: Slot = remaining_slots[i]
			var pid_p: int = perm[i]
			var pos_p: Vector3 = snapshot.skater_states[pid_p].position
			var anchor_p: Vector3 = anchors[slot_p]
			var dx_p: float = pos_p.x - anchor_p.x
			var dz_p: float = pos_p.z - anchor_p.z
			cost += sqrt(dx_p * dx_p + dz_p * dz_p)
			if prev_assignments.get(pid_p, Slot.NONE) != slot_p:
				cost += HYSTERESIS_PENALTY_M
		if cost < best_cost:
			best_cost = cost
			best_perm = perm.duplicate()

	for i: int in remaining_slots.size():
		result[best_perm[i]] = remaining_slots[i]
	return result


# All permutations of an array. n=2 returns 2 perms; n=3 returns 6.
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
