class_name AIRoleSlots

# Pure-function role slot assignment for the v2 possession-state model.
# Roles are assigned per brain tick by current geometry — closest peer
# to each slot anchor wins via permutation enumeration with distance
# hysteresis. No locking, no sticky state — the bot whose body is
# already in the right place gets the role, which means roles tend
# to "stick" naturally as long as nothing geometric reshuffles.
#
# Phase 3 collapses the defensive role enums so DZONE and TRANS_OD
# share {PRESSURE, ANCHOR, COVER}. The slot anchor for each branches
# on the active possession state — same role name, position relative
# to the threat geometry of the state. OZONE replaces OUTLET with
# SUPPORT; OUTLET stays a TRANS_DO-only role. BACKDOOR was renamed
# to FINISHER (more descriptive of the scoring-threat semantics).
#
# Mixed teams: humans are teammates and get slot assignments same as
# bots. The brain doesn't distinguish — humans drive the structure,
# bots auto-fill the gaps.

enum Slot {
	NONE,
	# Shared by multiple states.
	CARRIER,    # OZONE + TRANS_DO: peer with the puck.
	# Shared between DZONE and TRANS_OD. Anchors branch on state.
	PRESSURE,   # puck pressurer — closes the carrier.
	ANCHOR,     # deep defender / net-front. DZONE: strong-side post.
	            # TRANS_OD: defensive slot center.
	COVER,      # weak-side support. DZONE: mid-slot weak-side.
	            # TRANS_OD: back-of-puck weak-side.
	# OZONE — extended OZ rotation.
	FINISHER,   # scoring threat at the back-door / weak-side post.
	            # AIRoleFinisher.decide adds tip / step-out / hold on top.
	# TRANS_DO — geometric assignment, no locking.
	OUTLET,     # weak-side at opp blue line, NZ-side (offside-safe).
	SUPPORT,    # OZONE + TRANS_DO: weak-side trail. OZONE: high in OZ
	            # shadowing puck X (Phase 3 placeholder; Phase 4 utility
	            # AI replaces this with a passing-lane-availability search).
	            # TRANS_DO: weak-side of carrier, behind toward our net.
	# NEUTRAL — faceoff / fresh loose puck. Simple 1-2 shape.
	CHASE,      # at puck — closest peer transitions to CHASE_PUCK.
	FLANK_L,    # left flank, slightly defensive of puck
	FLANK_R,    # right flank, slightly defensive of puck
}

# Hysteresis: when running closest-to-X assignment queries, a peer
# that didn't have the slot last tick pays this many meters of
# effective distance to take it. Sticky enough to prevent flicker
# between geometrically-similar peers, loose enough that natural
# play movement triggers role swaps. Lowered from the original
# 1.5 m to 1.0 m for 3v3 — the higher value made roles too sticky
# in tight space, suppressing the role flex that good 3v3 demands.
const HYSTERESIS_PENALTY_M: float = 1.0

# DZONE anchor constants.
const DZONE_PRESSURE_GAP_M: float = 1.5            # m goal-side of puck along puck→net line
const DZONE_ANCHOR_X_FROM_POST: float = 0.3        # m inside the strong-side post (toward center)
const DZONE_ANCHOR_Z_FROM_GOAL: float = 1.0        # m in front of goal line
const DZONE_COVER_X: float = 2.0                   # m weak-side of rink center
const DZONE_COVER_Z_FROM_GOAL: float = 4.0         # m in front of goal line (mid-slot depth)

# OZONE: FINISHER + SUPPORT now compute their own targets in their
# role modules (Step 2 of the no-anchors refactor). Anchor formulas
# deleted; the brain assigns slots semantically without consulting
# slot_anchor for these roles.

# TRANS_DO: OUTLET + SUPPORT also own their own targets — anchor
# formulas deleted.

# TRANS_OD anchor constants.
const TRANS_OD_ANCHOR_Z_FROM_GOAL: float = 5.0     # m in front of own goal line (defensive slot)
const TRANS_OD_PRESSURE_GAP_M: float = 1.5         # m goal-side of puck (same as DZONE PRESSURE)
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
			return [Slot.PRESSURE, Slot.ANCHOR, Slot.COVER]
		AIPossessionState.State.OZONE:
			return [Slot.CARRIER, Slot.FINISHER, Slot.SUPPORT]
		AIPossessionState.State.TRANS_DO:
			return [Slot.CARRIER, Slot.OUTLET, Slot.SUPPORT]
		AIPossessionState.State.TRANS_OD:
			return [Slot.PRESSURE, Slot.ANCHOR, Slot.COVER]
		AIPossessionState.State.NEUTRAL:
			return [Slot.CHASE, Slot.FLANK_L, Slot.FLANK_R]
		_:
			return []


# Computes the world-space anchor for a slot in a given state.
# `carrier_pos` is needed by SUPPORT (relative to carrier).
# State-branched roles (PRESSURE / ANCHOR / COVER / SUPPORT) read
# `state` to pick the formula matching the current possession context.
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
			# Both DZONE and TRANS_OD: 1.5 m goal-side of puck along
			# the puck→our-net line. Same formula in both states; left
			# state-branched in case Phase 4 wants to differ aggression
			# (TRANS_OD might gap-control further, e.g.).
			var to_net: Vector3 = our_net - puck_pos
			var l: float = sqrt(to_net.x * to_net.x + to_net.z * to_net.z)
			if l < 0.001:
				return puck_pos
			var gap_m: float = DZONE_PRESSURE_GAP_M
			if state == AIPossessionState.State.TRANS_OD:
				gap_m = TRANS_OD_PRESSURE_GAP_M
			var step: float = gap_m / l
			return Vector3(
					puck_pos.x + to_net.x * step,
					0.0,
					puck_pos.z + to_net.z * step)

		Slot.ANCHOR:
			if state == AIPossessionState.State.TRANS_OD:
				# Defensive slot center. Closest-to-own-net peer wins
				# via the assign() pre-pick (highest-up-ice teammate is
				# the active backchecker; deep bot drops into COVER).
				return Vector3(
						0.0, 0.0,
						own_goal_dir * (GameRules.GOAL_LINE_Z - TRANS_OD_ANCHOR_Z_FROM_GOAL))
			# DZONE: strong-side post in front of own goal.
			return Vector3(
					strong_x * (GameRules.NET_HALF_WIDTH - DZONE_ANCHOR_X_FROM_POST),
					0.0,
					own_goal_dir * (GameRules.GOAL_LINE_Z - DZONE_ANCHOR_Z_FROM_GOAL))

		Slot.COVER:
			if state == AIPossessionState.State.TRANS_OD:
				# Back of puck, weak-side. Second-wave defender for the
				# bot whose role isn't ANCHOR or PRESSURE — typically the
				# deep defender, who gets pulled forward by this anchor
				# to engage the play instead of camping the slot.
				return Vector3(
						puck_pos.x - strong_x * TRANS_OD_COVER_X,
						0.0,
						puck_pos.z + own_goal_dir * TRANS_OD_COVER_Z)
			# DZONE: weak-side of rink center, mid-slot depth.
			return Vector3(
					-strong_x * DZONE_COVER_X,
					0.0,
					own_goal_dir * (GameRules.GOAL_LINE_Z - DZONE_COVER_Z_FROM_GOAL))

		# FINISHER, SUPPORT, OUTLET — these roles own their own
		# positional targets in their role-behavior modules. The
		# brain assigns them via semantic queries that don't read
		# slot_anchor.

		Slot.CHASE:
			# NEUTRAL only: anchor at puck position. The bot's SM
			# transitions to CHASE_PUCK naturally via _should_chase_loose_puck
			# once they're closest.
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
# Per-state semantic-query assignment:
#   DZONE     PRESSURE = closest to puck;  ANCHOR = closest to our net;  COVER = remaining
#   OZONE     CARRIER fixed;  FINISHER = closest to opp net;  SUPPORT = remaining
#   TRANS_DO  CARRIER fixed;  OUTLET = closest to opp net;  SUPPORT = remaining
#   TRANS_OD  PRESSURE = closest to puck;  ANCHOR = closest to OPP net (Sprinting Through);
#             COVER = remaining (the deep peer engages forward)
#   NEUTRAL   CHASE = closest to puck;  FLANK_L / FLANK_R = X-axis split of remaining
#
# Sprinting Through is the 3v3 backcheck technique encoded in
# TRANS_OD's ANCHOR criterion: the up-ice peer (closest to opp net)
# is the one with the longest backcheck, so they get ANCHOR — their
# positional target (near our net, set by the role behavior) pulls
# them home. The deeper peer becomes COVER and engages the play
# forward instead of camping the slot.
#
# Hysteresis: each closest-to-X query adds HYSTERESIS_PENALTY_M to
# the effective distance for peers who didn't hold the slot last
# tick, so a sticky peer keeps the role unless another is meaningfully
# closer. `prev_assignments` is last tick's Dictionary[peer_id, Slot];
# pass {} on the first tick or after a state change.
static func assign(
		snapshot: WorldSnapshot,
		team_id: int,
		own_goal_z: float,
		state: int,
		team_id_resolver: Callable,
		prev_assignments: Dictionary,
		_strong_x: float = 1.0) -> Dictionary:
	var result: Dictionary = {}
	if snapshot == null:
		return result

	# Collect our team's peers.
	var teammates: Array = []
	for peer_id: int in snapshot.skater_states:
		if int(team_id_resolver.call(peer_id)) == team_id:
			teammates.append(peer_id)
	if teammates.is_empty():
		return result

	var fixed_peers: Dictionary = {}

	# Fixed CARRIER for OZONE / TRANS_DO.
	if state == AIPossessionState.State.OZONE \
			or state == AIPossessionState.State.TRANS_DO:
		var carrier_pid: int = snapshot.puck_state.carrier_peer_id if snapshot.puck_state else -1
		if carrier_pid != -1 and int(team_id_resolver.call(carrier_pid)) == team_id:
			result[carrier_pid] = Slot.CARRIER
			fixed_peers[carrier_pid] = true

	var puck_pos: Vector3 = snapshot.puck_state.position if snapshot.puck_state else Vector3.ZERO
	var our_net := Vector3(0.0, 0.0, own_goal_z)
	var opp_net := Vector3(0.0, 0.0, -own_goal_z)

	match state:
		AIPossessionState.State.DZONE:
			_assign_pair_then_remainder(
					snapshot, teammates, fixed_peers, prev_assignments, result,
					Slot.PRESSURE, puck_pos,
					Slot.ANCHOR, our_net,
					Slot.COVER)

		AIPossessionState.State.TRANS_OD:
			# Sprinting Through: ANCHOR criterion = closest to OPP
			# net, so the up-ice peer gets the deep-defender role
			# and sprints home. The remaining peer (deeper toward
			# our net) becomes COVER and engages the play forward.
			_assign_pair_then_remainder(
					snapshot, teammates, fixed_peers, prev_assignments, result,
					Slot.PRESSURE, puck_pos,
					Slot.ANCHOR, opp_net,
					Slot.COVER)

		AIPossessionState.State.OZONE:
			_assign_one_then_remainder(
					snapshot, teammates, fixed_peers, prev_assignments, result,
					Slot.FINISHER, opp_net,
					Slot.SUPPORT)

		AIPossessionState.State.TRANS_DO:
			_assign_one_then_remainder(
					snapshot, teammates, fixed_peers, prev_assignments, result,
					Slot.OUTLET, opp_net,
					Slot.SUPPORT)

		AIPossessionState.State.NEUTRAL:
			_assign_chase_and_flanks(
					snapshot, teammates, fixed_peers, prev_assignments, result,
					puck_pos)

	return result


# ── Assignment helpers ──────────────────────────────────────────────────────

# Picks the peer closest to `target_pos` from `teammates`, excluding
# already-fixed peers, with hysteresis. Returns -1 if no eligible peer.
static func _pick_closest_with_hysteresis(
		snapshot: WorldSnapshot,
		teammates: Array,
		fixed_peers: Dictionary,
		prev_assignments: Dictionary,
		target_pos: Vector3,
		slot: Slot) -> int:
	var best_pid: int = -1
	var best_score: float = INF
	for pid: int in teammates:
		if fixed_peers.has(pid):
			continue
		var pos: Vector3 = snapshot.skater_states[pid].position
		var dx: float = pos.x - target_pos.x
		var dz: float = pos.z - target_pos.z
		var d: float = sqrt(dx * dx + dz * dz)
		# Hysteresis: peers who didn't hold this slot last tick pay
		# HYSTERESIS_PENALTY_M to take it. Sticky peer keeps the
		# slot unless another is meaningfully closer.
		if prev_assignments.get(pid, Slot.NONE) != slot:
			d += HYSTERESIS_PENALTY_M
		if d < best_score or (d == best_score and (best_pid == -1 or pid < best_pid)):
			best_score = d
			best_pid = pid
	return best_pid


# Assigns slot1 to closest-to-target1 peer, slot2 to closest-to-target2
# peer, then dumps any remainder into slot_remainder. Used by DZONE
# and TRANS_OD.
static func _assign_pair_then_remainder(
		snapshot: WorldSnapshot,
		teammates: Array,
		fixed_peers: Dictionary,
		prev_assignments: Dictionary,
		result: Dictionary,
		slot1: Slot, target1: Vector3,
		slot2: Slot, target2: Vector3,
		slot_remainder: Slot) -> void:
	var pid1: int = _pick_closest_with_hysteresis(
			snapshot, teammates, fixed_peers, prev_assignments,
			target1, slot1)
	if pid1 != -1:
		result[pid1] = slot1
		fixed_peers[pid1] = true

	var pid2: int = _pick_closest_with_hysteresis(
			snapshot, teammates, fixed_peers, prev_assignments,
			target2, slot2)
	if pid2 != -1:
		result[pid2] = slot2
		fixed_peers[pid2] = true

	for pid: int in teammates:
		if not fixed_peers.has(pid):
			result[pid] = slot_remainder


# Assigns slot1 to closest-to-target1 peer, then dumps any remainder
# into slot_remainder. Used by OZONE and TRANS_DO (after CARRIER fix).
static func _assign_one_then_remainder(
		snapshot: WorldSnapshot,
		teammates: Array,
		fixed_peers: Dictionary,
		prev_assignments: Dictionary,
		result: Dictionary,
		slot: Slot, target: Vector3,
		slot_remainder: Slot) -> void:
	var pid: int = _pick_closest_with_hysteresis(
			snapshot, teammates, fixed_peers, prev_assignments,
			target, slot)
	if pid != -1:
		result[pid] = slot
		fixed_peers[pid] = true

	for pid_r: int in teammates:
		if not fixed_peers.has(pid_r):
			result[pid_r] = slot_remainder


# NEUTRAL: CHASE goes to closest-to-puck. Remaining peers split on
# X axis with hysteresis — lowest effective X = FLANK_L, rest = FLANK_R.
# Hysteresis here is also HYSTERESIS_PENALTY_M but applied as an
# X-axis bias toward the previous slot's side, so a peer wobbling
# near center doesn't flip L/R every tick.
static func _assign_chase_and_flanks(
		snapshot: WorldSnapshot,
		teammates: Array,
		fixed_peers: Dictionary,
		prev_assignments: Dictionary,
		result: Dictionary,
		puck_pos: Vector3) -> void:
	var chase_pid: int = _pick_closest_with_hysteresis(
			snapshot, teammates, fixed_peers, prev_assignments,
			puck_pos, Slot.CHASE)
	if chase_pid != -1:
		result[chase_pid] = Slot.CHASE
		fixed_peers[chase_pid] = true

	var remaining: Array = []
	for pid: int in teammates:
		if not fixed_peers.has(pid):
			remaining.append(pid)
	if remaining.is_empty():
		return

	# Effective X for sorting: peer who held FLANK_L last tick gets
	# pulled left by the hysteresis margin; FLANK_R pulled right.
	# Net effect: a wobble at center keeps its previous side.
	var effective_x: Dictionary = {}
	for pid_r: int in remaining:
		var x: float = snapshot.skater_states[pid_r].position.x
		var prev_slot: int = prev_assignments.get(pid_r, Slot.NONE)
		if prev_slot == Slot.FLANK_L:
			x -= HYSTERESIS_PENALTY_M
		elif prev_slot == Slot.FLANK_R:
			x += HYSTERESIS_PENALTY_M
		effective_x[pid_r] = x

	remaining.sort_custom(func(a: int, b: int) -> bool:
			return effective_x[a] < effective_x[b])

	result[remaining[0]] = Slot.FLANK_L
	for i: int in range(1, remaining.size()):
		result[remaining[i]] = Slot.FLANK_R
