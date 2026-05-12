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
	# Defensive triumvirate — used in DZONE and TRANS_OD where an
	# opp carries the puck. NEUTRAL has no carrier and uses CHASE
	# / FLANK_L / FLANK_R below instead, since the role semantics
	# differ (race to puck + hold support vs. pressure carrier +
	# defend net + read pass).
	PRESSURE,   # puck pressurer — closes the carrier.
	ANCHOR,     # deep defender / net-front.
	COVER,      # weak-side support / pass-interception read.
	# Offensive roles.
	FINISHER,   # OZONE: scoring threat near opp net. Roams the slot.
	OUTLET,     # TRANS_DO: stretch-pass option at opp blue line.
	SUPPORT,    # OZONE + TRANS_DO: weak-side trail / cycle support.
	# NEUTRAL — loose puck, no clear possession. Race + hold shape.
	CHASE,      # closest peer races to the puck for retrieval.
	FLANK_L,    # left flank, defensive support behind puck.
	FLANK_R,    # right flank, defensive support behind puck.
}

# Hysteresis: when running closest-to-X assignment queries, a peer
# that didn't have the slot last tick pays this many meters of
# effective distance to take it. Sticky enough to prevent flicker
# between geometrically-similar peers, loose enough that natural
# play movement triggers role swaps. Lowered from the original
# 1.5 m to 1.0 m for 3v3 — the higher value made roles too sticky
# in tight space, suppressing the role flex that good 3v3 demands.
const HYSTERESIS_PENALTY_M: float = 1.0

# DZONE: PRESSURE, ANCHOR, COVER all own their positional targets
# in their role behaviors. No DZONE-specific anchor constants left.

# OZONE: FINISHER + SUPPORT now compute their own targets in their
# role modules (Step 2 of the no-anchors refactor). Anchor formulas
# deleted; the brain assigns slots semantically without consulting
# slot_anchor for these roles.

# TRANS_DO: OUTLET + SUPPORT also own their own targets — anchor
# formulas deleted.

# TRANS_OD: PRESSURE, ANCHOR, COVER all own their positional
# targets in their role behaviors. No TRANS_OD-specific anchor
# constants left.

# NEUTRAL: 1 PRESSURE + N COVERs. Roles own their positional
# targets — no NEUTRAL-specific anchor constants.


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

		# Every role owns its positional target in its role-behavior
		# module. slot_anchor is dead surface — Step 3 of the
		# no-anchors refactor will delete this function entirely.

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
# Hysteresis applied as an X-axis bias toward the previous slot's
# side, so a peer wobbling near center doesn't flip L/R every tick.
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
