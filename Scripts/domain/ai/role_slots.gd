class_name AIRoleSlots

# Pure-function role slot assignment for the v2 possession-state model.
# Roles are assigned per brain tick by current kinematics — the peer that
# would ARRIVE at each slot's reference point soonest wins (momentum-aware
# time_to_arrive at its real Speed cap, matching AILoosePuckChase and the
# threat partition), with arrival-time hysteresis. No locking, no sticky
# state — the bot whose body is already in (or genuinely moving into) the
# right place gets the role, so roles "stick" naturally as long as nothing
# kinematic reshuffles. Raw distance was the original metric; it handed
# PRESSURE/RUSH_D1 to a nearer bot coasting AWAY over a teammate already
# skating at the carrier — the brake-pivot turnaround read as "the wrong
# man went".
#
# DZONE uses {PRESSURE, MARK×2}: one pressurer on the carrier, two
# man-markers. The two MARKs are partitioned across the carrier's
# receivers by TeamBrain's threat assignment (a distinct man each) —
# which marker sits net-front vs. weak-side is emergent from WHICH man
# the optimal matcher hands each, not a fixed slot.
#
# TRANS_OD uses {RUSH_D1, TRACK_PUCK, TRACK_MID} — the layered rush
# defense (docs/transition-defense-plan.md §5.2), NOT man coverage.
# RUSH_D1 goes to the LAST MAN BACK (the peer soonest to our OWN NET,
# momentum-aware) and owns the carrier on the gap ladder; TRACK_PUCK runs
# the carrier down from behind; TRACK_MID owns the middle lane. Two bodies
# on the puck is correct here — one in front holding a gap, one behind
# running him down — and it is affordable because transition is BOUNDED:
# once the attack becomes a settled three-man threat needing a body on each
# man, the puck is in our zone and DZONE's coverage takes over (the
# readiness gate, plan §9).
#
# This replaced {CONTAIN, MARK×2}, which man-marked through transition and
# so had markers running cover-position argmaxes from 20 m up-ice
# mid-backcheck — the "lazy escorting, no urgency" failure. That in turn had
# replaced a PRESSURE+BACKCHECK+CONTAIN triad where TWO peers engaged the
# carrier FORWARD (overcommit / bad angle / breakaways).
#
# MARK unifies the old DZONE ANCHOR/COVER and TRANS_OD BACKCHECK, which
# had converged to identical man-marking in the assigned-man path (see
# AIRoleMark). It is now a DZONE-only role.
#
# OZONE replaces OUTLET with SUPPORT; OUTLET stays a TRANS_DO-only
# role. BACKDOOR was renamed to FINISHER (more descriptive of the
# scoring-threat semantics).
#
# Mixed teams: humans are teammates and get slot assignments same as
# bots. The brain doesn't distinguish — humans drive the structure,
# bots auto-fill the gaps.

enum Slot {
	NONE,
	# Shared by multiple states.
	CARRIER,    # OZONE + TRANS_DO: peer with the puck.
	# Defensive: PRESSURE closes the carrier in DZONE (also reused as
	# FORECHECK's F1). MARK is the off-puck man-marker — the DZONE defenders
	# NOT on the puck each cover a distinct assigned opponent (threat
	# partition). Transition uses the rush layers at the bottom of this enum,
	# never these two. NEUTRAL has no carrier and uses CHASE + FLANK below.
	PRESSURE,   # DZONE: puck pressurer, closes the carrier.
	MARK,       # DZONE: covers an assigned man (threat partition).
	# Offensive roles.
	FINISHER,   # OZONE: scoring threat near opp net. Roams the slot.
	OUTLET,     # TRANS_DO: stretch-pass option at opp blue line.
	SUPPORT,    # OZONE + TRANS_DO: weak-side trail / cycle support.
	# BREAKOUT (we possess in our OWN DZ). Two outlet options for the
	# carrier breaking the puck out:
	BREAKOUT_STRONG,  # strong-side-wall outlet, free to advance up-ice.
	BREAKOUT_WEAK,    # weak-side reverse valve, stays goal-side of carrier.
	# FORECHECK (opp possesses in THEIR DZ). Conservative 1-1-1 press:
	F1_PRESSURE,  # deep puck-pressurer (reuses PRESSURE). Accepts tag-up risk.
	F2_MID,       # mid-lane breakout-pass read, high in the zone.
	F3_HIGH,      # high safety at the opp blue line; first man back.
	# NEUTRAL — loose puck, no clear possession. Race + hold shape.
	CHASE,      # closest peer races to the puck for retrieval.
	FLANK_L,    # left flank, defensive support behind puck.
	FLANK_R,    # right flank, defensive support behind puck.
	# ── 5v5-only slots (assigned by AIRoleSlots5; never in the 3v3 sets) ─────
	# OZONE: 3 F low / 2 D at the points.
	NET_FRONT,      # F: crease-edge screen / backdoor man (finisher job).
	HIGH_SLOT,      # F: F3 — the soft ice between the dots, above the puck.
	POINT_STRONG,   # D: strong-side point, sinks down his wall with the cycle.
	POINT_WEAK,     # D: weak-side point, holds the line shaded central.
	# FORECHECK: the 1-2-2 (F1 reuses F1_PRESSURE).
	F2_STRONG,      # F: strong-side wall lane — kills the half-wall outlet.
	F2_WEAK,        # F: middle lane, circle-tops-to-blue-line height.
	DP_STRONG,      # D: offensive blue line, strong side, inside the dots.
	DP_WEAK,        # D: offensive blue line, weak side.
	# DZONE: hybrid zone with soft-lock (see zone_coverage.gd).
	ZONE_D_STRONG,  # D: puck-side low — the corner/boards battle.
	ZONE_D_WEAK,    # D: net-front box.
	ZONE_C,         # F: the slot — low support + seam insurance.
	ZONE_W_STRONG,  # F: strong wall/point coverage high.
	ZONE_W_WEAK,    # F: weak-side high-slot sag.
	# BREAKOUT extras (CARRIER + BREAKOUT_STRONG shared with 3v3).
	BREAKOUT_D2,      # D: net-front/opposite post — the D-to-D "over" valve.
	BREAKOUT_C,       # F: center's low swing — the second outlet.
	BREAKOUT_STRETCH, # F: weak-side winger — mid-ice cross / stretch option.
	# TRANS_DO rush shape (CARRIER fixed; MARK reused in TRANS_OD).
	WIDE_L,         # F: left wide lane, paced to the carrier.
	WIDE_R,         # F: right wide lane.
	TRAILER,        # ANY: high-slot trailer (the activating fourth man).
	DVALVE,         # D: safety valve trailing the rush.
	# NEUTRAL back shape (CHASE/FLANK reused).
	DBACK_L,        # D: left goal-side hold inside the dots.
	DBACK_R,        # D: right goal-side hold.
	# TRANS_OD rush defense — the layered replacement for CONTAIN + MARK
	# (docs/transition-defense-plan.md §5). Both team sizes; 3v3 uses
	# RUSH_D1 / TRACK_PUCK / TRACK_MID, 5v5 adds RUSH_D2 and splits the mid
	# trackers strong/weak.
	RUSH_D1,          # D: strong-side D. Owns the carrier — gap ladder + angling.
	RUSH_D2,          # D: weak-side D. Holds mid-ice, takes the mid-lane drive.
	TRACK_PUCK,       # F: F1 back. Runs the carrier down through mid-ice.
	TRACK_MID_STRONG, # F: F2. Back through mid-ice, stops at the circle tops.
	TRACK_MID_WEAK,   # F: F3. Same, weak side.
	TRACK_MID,        # The single mid tracker (3v3) — centre lane, no side split.
}

# Hysteresis for the soonest-to-arrive elections: a peer that didn't
# have the slot last tick pays this many seconds of effective arrival
# time to take it. Sticky enough to prevent flicker between
# kinematically-similar peers, loose enough that natural play movement
# triggers role swaps. Same margin as AILoosePuckChase.HYSTERESIS_S,
# so the two election seams stay consistent. ≈ 1 m of positional
# difference at the calibrated ETA's close-range standing-start rate
# (~2 m at cruise) — re-derived when time_to_arrive moved from the
# free-ramp heuristic to the measured phase model.
const HYSTERESIS_PENALTY_S: float = 0.2

# Hysteresis for the NEUTRAL flank L/R split, which is an X-axis SIDE
# choice rather than a race — a peer wobbling near center keeps its
# previous side unless it drifts this far past it. (The slot elections
# above use the time-based HYSTERESIS_PENALTY_S instead.)
const HYSTERESIS_PENALTY_M: float = 1.0

# DZONE: PRESSURE + MARK own their positional targets in their
# role behaviors. No DZONE-specific anchor constants left.

# OZONE: FINISHER + SUPPORT now compute their own targets in their
# role modules (Step 2 of the no-anchors refactor). Anchor formulas
# deleted; the brain assigns slots semantically without consulting
# slot_anchor for these roles.

# TRANS_DO: OUTLET + SUPPORT also own their own targets — anchor
# formulas deleted.

# TRANS_OD: the rush layers own their positional targets in their role
# behaviors (AIRoleRushD / AIRoleTrack). No TRANS_OD-specific anchor
# constants left.

# NEUTRAL: CHASE + FLANK_L/R. Roles own their positional
# targets — no NEUTRAL-specific anchor constants.


# Returns the list of slots for a given state, in canonical order.
# CARRIER (if applicable) is the only fixed-resolution slot — all
# others are filled by the permutation enumeration.
static func slots_for_state(state: int) -> Array[int]:
	match state:
		AIPossessionState.State.DZONE:
			return [Slot.PRESSURE, Slot.MARK]
		AIPossessionState.State.OZONE:
			return [Slot.CARRIER, Slot.FINISHER, Slot.SUPPORT]
		AIPossessionState.State.TRANS_DO:
			return [Slot.CARRIER, Slot.OUTLET, Slot.SUPPORT]
		AIPossessionState.State.BREAKOUT:
			return [Slot.CARRIER, Slot.BREAKOUT_STRONG, Slot.BREAKOUT_WEAK]
		AIPossessionState.State.FORECHECK:
			return [Slot.F1_PRESSURE, Slot.F2_MID, Slot.F3_HIGH]
		AIPossessionState.State.TRANS_OD:
			return [Slot.RUSH_D1, Slot.TRACK_PUCK, Slot.TRACK_MID]
		AIPossessionState.State.NEUTRAL:
			return [Slot.CHASE, Slot.FLANK_L, Slot.FLANK_R]
		_:
			return []


# Carrier doesn't have a brain anchor — they're driven by the carrier
# utility AI in `_state_carry`. Every other role owns its positional
# target in its role-behavior module; slot_anchor is dead surface that
# Step 3 of the no-anchors refactor will delete entirely.
static func slot_anchor(slot: Slot, carrier_pos: Vector3) -> Vector3:
	if slot == Slot.CARRIER:
		return carrier_pos
	return Vector3.ZERO


# Assigns each teammate to a slot. Returns Dictionary[peer_id, Slot].
#
# Per-state semantic-query assignment (every "soonest" below is the
# momentum-aware time_to_arrive election at each peer's real Speed cap):
#   DZONE     PRESSURE = soonest to puck;  MARK = remaining two (a man each)
#   OZONE     CARRIER fixed;  FINISHER = soonest to opp net;  SUPPORT = remaining
#   TRANS_DO  CARRIER fixed;  OUTLET = soonest to opp net;  SUPPORT = remaining
#   TRANS_OD  RUSH_D1 = last man back (peer soonest to OUR net, momentum-aware);
#             TRACK_PUCK = soonest to the puck of the rest; TRACK_MID = leftover
#   NEUTRAL   CHASE = soonest to puck;  FLANK_L / FLANK_R = X-axis split of remaining
#
# TRANS_OD encodes the compressed three-layer rush defense: RUSH_D1 goes to
# the last man back — the peer soonest to our own net (momentum-aware), the
# deepest line of defense — and owns the carrier on the gap ladder; whoever of
# the remaining two reaches the puck soonest takes TRACK_PUCK and runs the
# carrier down from behind; the leftover owns the middle lane. Exactly one peer
# stands in FRONT of the carrier, so the gap is never double-manned.
#
# Hysteresis: each soonest-to-X query adds HYSTERESIS_PENALTY_S to the
# effective arrival time for peers who didn't hold the slot last tick,
# so a sticky peer keeps the role unless another arrives meaningfully
# sooner. `prev_assignments` is last tick's Dictionary[peer_id, Slot];
# pass {} on the first tick or after a state change. `caps_by_peer` is
# the live peer→AISkaterCaps map (missing entries → league default).
static func assign(
		snapshot: WorldSnapshot,
		team_id: int,
		own_goal_z: float,
		state: int,
		team_id_by_peer: Dictionary,
		prev_assignments: Dictionary,
		_strong_x: float = 1.0,
		caps_by_peer: Dictionary = {}) -> Dictionary[int, int]:
	var result: Dictionary[int, int] = {}
	if snapshot == null:
		return result

	# Collect our team's peers.
	var teammates: Array[int] = []
	for peer_id: int in snapshot.skater_states:
		if team_id_by_peer.get(peer_id, -1) == team_id:
			teammates.append(peer_id)
	if teammates.is_empty():
		return result

	var fixed_peers: Dictionary = {}

	# Fixed CARRIER for OZONE / TRANS_DO / BREAKOUT.
	if state == AIPossessionState.State.OZONE \
			or state == AIPossessionState.State.TRANS_DO \
			or state == AIPossessionState.State.BREAKOUT:
		var carrier_pid: int = snapshot.puck_state.carrier_peer_id if snapshot.puck_state else -1
		if carrier_pid != -1 and team_id_by_peer.get(carrier_pid, -1) == team_id:
			result[carrier_pid] = Slot.CARRIER
			fixed_peers[carrier_pid] = true

	var puck_pos: Vector3 = snapshot.puck_state.position if snapshot.puck_state else Vector3.ZERO
	var our_net := Vector3(0.0, 0.0, own_goal_z)
	var opp_net := Vector3(0.0, 0.0, -own_goal_z)

	match state:
		AIPossessionState.State.DZONE:
			# PRESSURE = soonest to the puck; the other two MARK a man each.
			# Which marker ends up net-front vs. weak-side is decided by
			# TeamBrain's threat partition (which man each is assigned), not a
			# fixed net-front/weak-side slot split.
			_assign_one_then_remainder(
					snapshot, teammates, fixed_peers, prev_assignments, result,
					Slot.PRESSURE, puck_pos,
					Slot.MARK, caps_by_peer)

		AIPossessionState.State.TRANS_OD:
			# The layered rush defense, compressed to three bodies
			# (docs/transition-defense-plan.md §5.2). Same modules 5v5 runs; the
			# only difference is that with three skaters there is no D pair, so
			# RUSH_D2's mid-ice layer folds into the single mid tracker.
			#
			# TWO bodies on the puck is correct here, and it is not the old
			# "PRESSURE + BACKCHECK both engage forward" failure this file's
			# header warns about: RUSH_D1 is in FRONT of the carrier holding a
			# gap and TRACK_PUCK is BEHIND him running him down, which is one
			# rush being defended from both ends rather than two bodies taking
			# bad angles from the same side. It is affordable because transition
			# is BOUNDED — the moment the attack becomes a settled three-man
			# threat that needs a body on each man, the puck is in our zone and
			# DZONE's coverage takes over. TRANS_OD's job is to kill the rush,
			# not to solve coverage.
			#
			# RUSH_D1 elects first (most structurally important): the peer
			# soonest to OUR NET, momentum-aware — the last man back, already in
			# front of the rush. TRACK_PUCK is then whoever of the remaining two
			# gets to the puck soonest, and the leftover takes the middle lane.
			_assign_pair_then_remainder(
					snapshot, teammates, fixed_peers, prev_assignments, result,
					Slot.RUSH_D1, our_net,
					Slot.TRACK_PUCK, puck_pos,
					Slot.TRACK_MID, caps_by_peer)

		AIPossessionState.State.OZONE:
			_assign_one_then_remainder(
					snapshot, teammates, fixed_peers, prev_assignments, result,
					Slot.FINISHER, opp_net,
					Slot.SUPPORT, caps_by_peer)

		AIPossessionState.State.TRANS_DO:
			_assign_one_then_remainder(
					snapshot, teammates, fixed_peers, prev_assignments, result,
					Slot.OUTLET, opp_net,
					Slot.SUPPORT, caps_by_peer)

		AIPossessionState.State.BREAKOUT:
			# Strong-side outlet goes to whichever non-carrier is nearest
			# the strong-side-wall breakout spot (strong-side boards at our
			# blue line); the remaining peer takes the weak-side reverse
			# valve. `_strong_x` is the brain's hysteretic strong side, so
			# the strong/weak split doesn't thrash when the D carries the
			# puck across the middle behind the net.
			var own_dir: float = signf(own_goal_z)
			var strong_wall := Vector3(
					_strong_x * GameRules.RINK_HALF_WIDTH, 0.0,
					own_dir * GameRules.BLUE_LINE_Z)
			_assign_one_then_remainder(
					snapshot, teammates, fixed_peers, prev_assignments, result,
					Slot.BREAKOUT_STRONG, strong_wall,
					Slot.BREAKOUT_WEAK, caps_by_peer)

		AIPossessionState.State.FORECHECK:
			# Conservative 1-1-1: F1 pressures the puck deep, F3 is the
			# high safety at the opp blue line (longest way home), F2 reads
			# the mid-lane in between. F3 anchored at the opp blue line
			# gets first claim so the safety is always filled even if the
			# geometry is awkward; F1 then takes whoever of the remaining
			# two is closest to the puck, and F2 takes the leftover.
			var opp_blue := Vector3(0.0, 0.0, -signf(own_goal_z) * GameRules.BLUE_LINE_Z)
			_assign_pair_then_remainder(
					snapshot, teammates, fixed_peers, prev_assignments, result,
					Slot.F3_HIGH, opp_blue,
					Slot.F1_PRESSURE, puck_pos,
					Slot.F2_MID, caps_by_peer)

		AIPossessionState.State.NEUTRAL:
			_assign_chase_and_flanks(
					snapshot, teammates, fixed_peers, prev_assignments, result,
					puck_pos, caps_by_peer)

	return result


# ── Assignment helpers ──────────────────────────────────────────────────────

# Picks the peer that would ARRIVE at `target_pos` soonest from `teammates`,
# excluding already-fixed peers, with hysteresis. Momentum-aware: each peer's
# ETA folds its current velocity in (time_to_arrive) and races at its real
# Speed cap, so a peer already skating the right way wins the slot over a
# nearer body coasting away. Returns -1 if no eligible peer.
static func _pick_soonest_with_hysteresis(
		snapshot: WorldSnapshot,
		teammates: Array,
		fixed_peers: Dictionary,
		prev_assignments: Dictionary,
		target_pos: Vector3,
		slot: Slot,
		caps_by_peer: Dictionary) -> int:
	var best_pid: int = -1
	var best_score: float = INF
	for pid: int in teammates:
		if fixed_peers.has(pid):
			continue
		var s: SkaterNetworkState = snapshot.skater_states[pid]
		var caps: AISkaterCaps = caps_by_peer.get(pid)
		var speed: float = caps.max_speed if caps != null \
				else AIActionScoring.SKATER_REF_SPEED_M_S
		var t: float = AIActionScoring.time_to_arrive(
				s.position, target_pos, s.velocity, speed)
		# Hysteresis: peers who didn't hold this slot (or its cross-state
		# continuity sibling — see _hysteresis_class) last tick pay
		# HYSTERESIS_PENALTY_S to take it. Sticky peer keeps the
		# slot unless another arrives meaningfully sooner.
		if _hysteresis_class(prev_assignments.get(pid, Slot.NONE)) != _hysteresis_class(slot):
			t += HYSTERESIS_PENALTY_S
		if t < best_score or (t == best_score and (best_pid == -1 or pid < best_pid)):
			best_score = t
			best_pid = pid
	return best_pid


# Cross-state hysteresis continuity. The soonest-to-arrive elections give a
# peer that HELD a slot last tick a stickiness bonus, keyed on the slot enum —
# but a possession-state flip renames the slots, so BREAKOUT_STRONG becomes
# OUTLET and BREAKOUT_WEAK becomes SUPPORT, and an exact-enum match sees NO
# continuity across the flip. With zero stickiness the two non-carriers'
# near-tied elections could reverse destinations at the handoff, sending them
# on crossing paths into each other (the breakout→rush collision). Mapping
# each slot to its continuity CLASS — the up-ice attacking option
# (BREAKOUT_STRONG / OUTLET / FINISHER) and the trailing support
# (BREAKOUT_WEAK / SUPPORT) — lets the peer that was the up-ice guy stay the
# up-ice guy (and the trailer stay the trailer) through the rename. The bonus
# is only HYSTERESIS_PENALTY_S, so a genuine kinematic advantage still
# swaps them; it only settles the near-ties that used to flicker. Every other
# slot maps to itself (exact-match, unchanged).
static func _hysteresis_class(slot: int) -> int:
	match slot:
		Slot.BREAKOUT_STRONG, Slot.OUTLET, Slot.FINISHER:
			return Slot.OUTLET       # up-ice attacking option
		Slot.BREAKOUT_WEAK, Slot.SUPPORT:
			return Slot.SUPPORT      # trailing support / reverse valve
		Slot.RUSH_D1, Slot.PRESSURE:
			return Slot.PRESSURE     # the body that owns the carrier
		Slot.TRACK_MID, Slot.MARK:
			return Slot.MARK         # off-puck coverage
		_:
			return slot


# Assigns slot1 to soonest-to-target1 peer, slot2 to soonest-to-target2
# peer, then dumps any remainder into slot_remainder. Used by FORECHECK.
static func _assign_pair_then_remainder(
		snapshot: WorldSnapshot,
		teammates: Array,
		fixed_peers: Dictionary,
		prev_assignments: Dictionary,
		result: Dictionary,
		slot1: Slot, target1: Vector3,
		slot2: Slot, target2: Vector3,
		slot_remainder: Slot,
		caps_by_peer: Dictionary) -> void:
	var pid1: int = _pick_soonest_with_hysteresis(
			snapshot, teammates, fixed_peers, prev_assignments,
			target1, slot1, caps_by_peer)
	if pid1 != -1:
		result[pid1] = slot1
		fixed_peers[pid1] = true

	var pid2: int = _pick_soonest_with_hysteresis(
			snapshot, teammates, fixed_peers, prev_assignments,
			target2, slot2, caps_by_peer)
	if pid2 != -1:
		result[pid2] = slot2
		fixed_peers[pid2] = true

	for pid: int in teammates:
		if not fixed_peers.has(pid):
			result[pid] = slot_remainder


# Assigns slot1 to soonest-to-target1 peer, then dumps any remainder
# into slot_remainder. Used by DZONE, OZONE, TRANS_DO and BREAKOUT
# (after CARRIER fix).
static func _assign_one_then_remainder(
		snapshot: WorldSnapshot,
		teammates: Array,
		fixed_peers: Dictionary,
		prev_assignments: Dictionary,
		result: Dictionary,
		slot: Slot, target: Vector3,
		slot_remainder: Slot,
		caps_by_peer: Dictionary) -> void:
	var pid: int = _pick_soonest_with_hysteresis(
			snapshot, teammates, fixed_peers, prev_assignments,
			target, slot, caps_by_peer)
	if pid != -1:
		result[pid] = slot
		fixed_peers[pid] = true

	for pid_r: int in teammates:
		if not fixed_peers.has(pid_r):
			result[pid_r] = slot_remainder


# NEUTRAL: CHASE goes to soonest-to-puck. Remaining peers split on
# X axis with hysteresis — lowest effective X = FLANK_L, rest = FLANK_R.
# Hysteresis applied as an X-axis bias toward the previous slot's
# side, so a peer wobbling near center doesn't flip L/R every tick.
static func _assign_chase_and_flanks(
		snapshot: WorldSnapshot,
		teammates: Array,
		fixed_peers: Dictionary,
		prev_assignments: Dictionary,
		result: Dictionary,
		puck_pos: Vector3,
		caps_by_peer: Dictionary) -> void:
	var chase_pid: int = _pick_soonest_with_hysteresis(
			snapshot, teammates, fixed_peers, prev_assignments,
			puck_pos, Slot.CHASE, caps_by_peer)
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
