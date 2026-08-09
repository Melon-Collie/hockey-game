class_name AIRoleSlots5

# 5v5 role-slot assignment — the position-aware sibling of AIRoleSlots
# (which stays the verbatim 3v3 path; TeamBrain branches on team_size).
# Design: docs/5v5-ai-plan.md §1–§2.
#
# Same election machinery as 3v3 — a momentum-aware soonest-to-arrive race
# per slot (time_to_arrive at each peer's real Speed cap) with arrival-time
# hysteresis — but **group-scoped**: every 5v5 slot is tagged F (forwards:
# lobby slots C/LW/RW), D (defensemen: LD/RD) or ANY, and each slot's race
# runs inside its group. Your defenseman being nearest the puck no longer
# vacuums him up-ice into a forward's job; the F/D split is the identity
# layer 5v5 is built on. Slots elect in a fixed priority order (the most
# structurally important first), and any slot whose group ran out of bodies
# — the carrier came from that group, or a human is wandering — CROSS-FILLS
# from whoever is left, which is what makes "a D activates, a forward covers
# his point" emergent rather than scripted.
#
# Strong/weak is emergent (whichever D reaches the strong-side job first
# wins it; the brain's hysteretic strong_x sets the side), while the lobby's
# L/R label survives as a REST BIAS: a peer whose lobby position matches a
# slot's home identity gets POSITION_BIAS_S shaved off its effective arrival
# time. At rest the bias always decides (LD takes the left point); a genuine
# kinematic advantage larger than the bias still swaps the pair on a
# cross-ice swing — the real-hockey exchange.
#
# Positions come from `position_by_peer` (peer_id → lobby team_slot 0–4,
# PlayerRegistry's live view). Unknown peers default to the F group — a
# rover fills forward jobs, never a D post.

# Flat arrival-time discount for a peer whose lobby position matches the
# slot's home identity (see header). Bigger than HYSTERESIS_PENALTY_S so the
# rest state is decided by identity, small enough that real momentum wins.
const POSITION_BIAS_S: float = 0.35

# Same stickiness the 3v3 elections use — REFERENCED, not copied (the rationale
# for the value lives on AIRoleSlots.HYSTERESIS_PENALTY_S). This was a duplicated
# literal and it drifted: 3v3's was re-derived to 0.2 when time_to_arrive moved
# to the measured phase model, this copy stayed at 0.12, and the comment kept
# claiming they matched — so 5v5's elections were ~40% less sticky than intended.
# Two numbers that must agree should not be two numbers.
const HYSTERESIS_PENALTY_S: float = AIRoleSlots.HYSTERESIS_PENALTY_S

# ── Election-target geometry (metres, world coords) ─────────────────────────
# These are the RACE TARGETS the assignment queries use — "who is best placed
# to take this job" — not the behavior anchors (role behaviors own their own
# positioning). Rough centers of each job's ice, from the researched shapes
# (plan §2 / appendix).
const _POINT_INSET_M: float = 1.0        # points: just inside the blue line
const _POINT_WEAK_X_M: float = 3.0       # weak point shades central
const _NET_FRONT_OFF_M: float = 2.5      # crease-edge screen depth
const _HIGH_SLOT_DEPTH_M: float = 9.5    # F3's between-the-dots float
const _F2_WALL_INSET_M: float = 4.0      # strong-side wall lane
const _F2_STRONG_DEPTH_M: float = 12.0   # half-wall height in their zone
const _F2_WEAK_LEAD_M: float = 3.5       # middle lane, inside their line
const _DP_STAND_BACK_M: float = 0.5      # D pair: NZ side of the line
const _DP_WEAK_X_M: float = 5.0          # weak-side point, inside the dots
const _ZONE_NET_FRONT_M: float = 2.0     # D-zone net-front box depth
const _ZONE_SLOT_DEPTH_M: float = 5.5    # ZONE_C's mid-slot post
const _ZONE_WALL_X_M: float = 8.5        # strong winger's wall lane
const _ZONE_WALL_DEPTH_M: float = 9.5
const _ZONE_WEAK_X_M: float = 4.0        # weak winger's high-slot sag
const _ZONE_WEAK_DEPTH_M: float = 10.0
const _BREAKOUT_SWING_DEPTH_M: float = 6.0   # C's low-swing race point
const _STRETCH_WALL_INSET_M: float = 4.0     # weak winger's mid-NZ post
const _WIDE_LANE_INSET_M: float = 4.0        # rush wide lanes
const _DBACK_X_M: float = 5.0            # NZ back pair, inside the dots
const _FLANK_SPREAD_M: float = 6.0       # NEUTRAL flank race offsets
const _FLANK_TRAIL_M: float = 4.0
const _TRACK_MID_SPLIT_M: float = 2.5    # F2/F3 recovery lanes off centre

# Group tags. F = lobby C/LW/RW, D = LD/RD.
enum Group { ANY, F, D }


# One slot's election order entry. Pure data holder filled per assign() call.
class SlotSpec:
	var slot: int
	var group: int          # Group enum
	var target: Vector3     # soonest-to-arrive race target
	var home_slot: int      # lobby team_slot whose holder gets POSITION_BIAS_S
	                        # (-1 = no identity bias)
	# Feasibility deadline (s): a pass-1 candidate whose RAW arrival time at
	# the race target exceeds this is skipped, deferring the slot to the
	# cross-fill pass. INF = no deadline (every other slot). Physical filter,
	# so hysteresis/home-bias adjustments don't enter it.
	var deadline_s: float = INF

	static func make(p_slot: int, p_group: int, p_target: Vector3,
			p_home_slot: int = -1) -> SlotSpec:
		var s := SlotSpec.new()
		s.slot = p_slot
		s.group = p_group
		s.target = p_target
		s.home_slot = p_home_slot
		return s


# Is `slot` one of the five D-zone hybrid-coverage areas? The brain uses this to
# pull the zone roles into the man partition (they cover a man like MARK does,
# just restricted to the ice they own).
static func is_zone_slot(slot: int) -> bool:
	return slot == AIRoleSlots.Slot.ZONE_D_STRONG \
			or slot == AIRoleSlots.Slot.ZONE_D_WEAK \
			or slot == AIRoleSlots.Slot.ZONE_C \
			or slot == AIRoleSlots.Slot.ZONE_W_STRONG \
			or slot == AIRoleSlots.Slot.ZONE_W_WEAK


# Canonical slot list per state (mirrors AIRoleSlots.slots_for_state).
static func slots_for_state(state: int) -> Array[int]:
	match state:
		AIPossessionState.State.DZONE:
			return [AIRoleSlots.Slot.ZONE_D_STRONG, AIRoleSlots.Slot.ZONE_D_WEAK,
					AIRoleSlots.Slot.ZONE_C, AIRoleSlots.Slot.ZONE_W_STRONG,
					AIRoleSlots.Slot.ZONE_W_WEAK]
		AIPossessionState.State.OZONE:
			return [AIRoleSlots.Slot.CARRIER, AIRoleSlots.Slot.POINT_STRONG,
					AIRoleSlots.Slot.POINT_WEAK, AIRoleSlots.Slot.NET_FRONT,
					AIRoleSlots.Slot.HIGH_SLOT]
		AIPossessionState.State.TRANS_OFFENSE:
			return [AIRoleSlots.Slot.CARRIER, AIRoleSlots.Slot.DVALVE,
					AIRoleSlots.Slot.WIDE_L, AIRoleSlots.Slot.WIDE_R,
					AIRoleSlots.Slot.TRAILER]
		AIPossessionState.State.BREAKOUT:
			return [AIRoleSlots.Slot.CARRIER, AIRoleSlots.Slot.BREAKOUT_D2,
					AIRoleSlots.Slot.BREAKOUT_STRONG, AIRoleSlots.Slot.BREAKOUT_C,
					AIRoleSlots.Slot.BREAKOUT_STRETCH]
		AIPossessionState.State.FORECHECK:
			return [AIRoleSlots.Slot.F1_PRESSURE, AIRoleSlots.Slot.DP_STRONG,
					AIRoleSlots.Slot.DP_WEAK, AIRoleSlots.Slot.F2_STRONG,
					AIRoleSlots.Slot.F2_WEAK]
		AIPossessionState.State.TRANS_DEFENSE:
			return [AIRoleSlots.Slot.RUSH_D1, AIRoleSlots.Slot.RUSH_D2,
					AIRoleSlots.Slot.TRACK_PUCK,
					AIRoleSlots.Slot.TRACK_MID_STRONG,
					AIRoleSlots.Slot.TRACK_MID_WEAK]
		AIPossessionState.State.NEUTRAL:
			return [AIRoleSlots.Slot.CHASE, AIRoleSlots.Slot.DBACK_L,
					AIRoleSlots.Slot.DBACK_R, AIRoleSlots.Slot.FLANK_L,
					AIRoleSlots.Slot.FLANK_R]
		_:
			return []


# Assigns each teammate to a 5v5 slot. Same contract as AIRoleSlots.assign
# plus `position_by_peer` (peer_id → lobby team_slot). Returns
# Dictionary[peer_id, AIRoleSlots.Slot].
static func assign(
		snapshot: WorldSnapshot,
		team_id: int,
		own_goal_z: float,
		state: int,
		team_id_by_peer: Dictionary,
		prev_assignments: Dictionary,
		strong_x: float,
		caps_by_peer: Dictionary,
		position_by_peer: Dictionary) -> Dictionary[int, int]:
	var result: Dictionary[int, int] = {}
	if snapshot == null:
		return result

	var teammates: Array[int] = []
	for peer_id: int in snapshot.skater_states:
		if team_id_by_peer.get(peer_id, -1) == team_id:
			teammates.append(peer_id)
	if teammates.is_empty():
		return result

	var assigned: Dictionary = {}
	var carrier_pid: int = snapshot.puck_state.carrier_peer_id if snapshot.puck_state else -1

	# Fixed CARRIER for the possession states, exactly like 3v3.
	if state == AIPossessionState.State.OZONE \
			or state == AIPossessionState.State.TRANS_OFFENSE \
			or state == AIPossessionState.State.BREAKOUT:
		if carrier_pid != -1 and team_id_by_peer.get(carrier_pid, -1) == team_id:
			result[carrier_pid] = AIRoleSlots.Slot.CARRIER
			assigned[carrier_pid] = true

	var puck_pos: Vector3 = snapshot.puck_state.position if snapshot.puck_state else Vector3.ZERO
	var specs: Array[SlotSpec] = _specs_for_state(
			state, own_goal_z, strong_x, puck_pos)

	# TRANS_DEFENSE gap feasibility: RUSH_D1's D-scoping only holds while a
	# defenseman can actually do the job — beat the carrier home with enough
	# time in hand to arrive SET (the brake margin: the seconds a skater at
	# league top speed needs to shed it, the same set-arrival quantity the
	# race-home primitives use). A D who is caught up-ice — pinched point,
	# beaten forecheck line — can chase the rush forever without ever getting
	# goal-side, and handing him RUSH_D1 anyway is how "everyone marked a man
	# but nobody picked up the carrier" happened: the threat partition excludes
	# the carrier because RUSH_D1 nominally owns him. With the deadline, an
	# infeasible D group defers RUSH_D1 to the cross-fill pass, where the
	# deepest feasible body — the classic backchecking third-man-high — picks
	# the rush up instead, and the caught D fall to MARK duty on the trailers.
	if state == AIPossessionState.State.TRANS_DEFENSE and carrier_pid != -1 \
			and team_id_by_peer.get(carrier_pid, -1) != team_id \
			and snapshot.skater_states.has(carrier_pid):
		var cs: SkaterNetworkState = snapshot.skater_states[carrier_pid]
		var c_caps: AISkaterCaps = caps_by_peer.get(carrier_pid)
		var c_speed: float = c_caps.max_speed if c_caps != null \
				else AIActionScoring.SKATER_REF_SPEED_M_S
		var t_carrier: float = AIActionScoring.time_to_arrive(
				cs.position, Vector3(0.0, 0.0, own_goal_z), cs.velocity, c_speed)
		var set_margin_s: float = GameRules.DEFAULT_SKATER_MAX_SPEED_M_S \
				/ AISteering.ARRIVAL_BRAKE_DECEL_M_S2
		for spec: SlotSpec in specs:
			if spec.slot == AIRoleSlots.Slot.RUSH_D1:
				spec.deadline_s = maxf(t_carrier - set_margin_s, 0.0)

	# Pass 1 — group-scoped elections in priority order. A slot whose group
	# has no free peer left is deferred to the cross-fill pass.
	var deferred: Array[SlotSpec] = []
	for spec: SlotSpec in specs:
		var pid: int = _pick_soonest(snapshot, teammates, assigned,
				prev_assignments, spec, caps_by_peer, position_by_peer, true)
		if pid == -1 and spec.deadline_s < INF:
			# INFEASIBILITY deferral, not an empty group: the group had bodies,
			# none of them can do the job in time. That slot needs the best
			# available body AT ITS OWN PRIORITY — waiting for the pass-2
			# cross-fill would let every lower-priority slot consume the forwards
			# first, and the only peer left to pick up the carrier would be one of
			# the very defensemen just ruled out. (Empty-group deferrals still
			# wait for pass 2: there the slot genuinely wants whoever is spare.)
			pid = _pick_soonest(snapshot, teammates, assigned,
					prev_assignments, spec, caps_by_peer, position_by_peer, false)
		if pid == -1:
			deferred.append(spec)
			continue
		result[pid] = spec.slot
		assigned[pid] = true

	# Pass 2 — cross-fill: deferred slots take whoever is left, any group.
	# This is the emergent cover rotation (a D carrier's point falls to the
	# leftover forward).
	for spec: SlotSpec in deferred:
		var pid: int = _pick_soonest(snapshot, teammates, assigned,
				prev_assignments, spec, caps_by_peer, position_by_peer, false)
		if pid == -1:
			break  # fewer peers than slots (short roster) — done
		result[pid] = spec.slot
		assigned[pid] = true

	# Remainder — peers beyond the spec'd slots. TRANS_DEFENSE's MARK crew by
	# design; a defensive-shape fallback everywhere else (extra bodies play
	# the man, never stand slotless).
	for pid: int in teammates:
		if not assigned.has(pid):
			result[pid] = AIRoleSlots.Slot.MARK

	return result


# ── Per-state slot specs (priority-ordered) ──────────────────────────────────

static func _specs_for_state(state: int, own_goal_z: float, strong_x: float,
		puck_pos: Vector3) -> Array[SlotSpec]:
	var own_dir: float = signf(own_goal_z)
	var our_net := Vector3(0.0, 0.0, own_goal_z)
	var half_w: float = GameRules.RINK_HALF_WIDTH
	# Depth helpers: their zone grows along -own_dir, ours along +own_dir.
	var opp_goal_z: float = -own_dir * GameRules.GOAL_LINE_Z
	var opp_blue_z: float = -own_dir * GameRules.BLUE_LINE_Z
	var our_blue_z: float = own_dir * GameRules.BLUE_LINE_Z

	match state:
		AIPossessionState.State.OZONE:
			return [
				SlotSpec.make(AIRoleSlots.Slot.POINT_STRONG, Group.D,
						Vector3(strong_x * GameRules.END_ZONE_FACEOFF_DOT_X, 0.0,
								opp_blue_z - own_dir * _POINT_INSET_M),
						_side_home_d(strong_x)),
				SlotSpec.make(AIRoleSlots.Slot.POINT_WEAK, Group.D,
						Vector3(-strong_x * _POINT_WEAK_X_M, 0.0,
								opp_blue_z - own_dir * _POINT_INSET_M),
						_side_home_d(-strong_x)),
				SlotSpec.make(AIRoleSlots.Slot.NET_FRONT, Group.F,
						Vector3(0.0, 0.0, opp_goal_z + own_dir * _NET_FRONT_OFF_M)),
				SlotSpec.make(AIRoleSlots.Slot.HIGH_SLOT, Group.F,
						Vector3(0.0, 0.0, opp_goal_z + own_dir * _HIGH_SLOT_DEPTH_M),
						0),  # the C's rest job — F3 duty splits off the pivot
			]

		AIPossessionState.State.FORECHECK:
			return [
				SlotSpec.make(AIRoleSlots.Slot.F1_PRESSURE, Group.F, puck_pos),
				SlotSpec.make(AIRoleSlots.Slot.DP_STRONG, Group.D,
						Vector3(strong_x * GameRules.END_ZONE_FACEOFF_DOT_X, 0.0,
								opp_blue_z + own_dir * _DP_STAND_BACK_M),
						_side_home_d(strong_x)),
				SlotSpec.make(AIRoleSlots.Slot.DP_WEAK, Group.D,
						Vector3(-strong_x * _DP_WEAK_X_M, 0.0,
								opp_blue_z + own_dir * _DP_STAND_BACK_M),
						_side_home_d(-strong_x)),
				SlotSpec.make(AIRoleSlots.Slot.F2_STRONG, Group.F,
						Vector3(strong_x * (half_w - _F2_WALL_INSET_M), 0.0,
								opp_goal_z + own_dir * _F2_STRONG_DEPTH_M),
						_side_home_f(strong_x)),
				SlotSpec.make(AIRoleSlots.Slot.F2_WEAK, Group.F,
						Vector3(0.0, 0.0, opp_blue_z - own_dir * _F2_WEAK_LEAD_M)),
			]

		AIPossessionState.State.DZONE:
			return [
				# Puck-side D takes the battle (race to the puck, D-scoped);
				# far D fronts the net.
				SlotSpec.make(AIRoleSlots.Slot.ZONE_D_STRONG, Group.D, puck_pos,
						_side_home_d(strong_x)),
				SlotSpec.make(AIRoleSlots.Slot.ZONE_D_WEAK, Group.D,
						Vector3(-strong_x * 1.0, 0.0,
								own_goal_z - own_dir * _ZONE_NET_FRONT_M),
						_side_home_d(-strong_x)),
				SlotSpec.make(AIRoleSlots.Slot.ZONE_C, Group.F,
						Vector3(strong_x * 1.5, 0.0,
								own_goal_z - own_dir * _ZONE_SLOT_DEPTH_M),
						0),
				SlotSpec.make(AIRoleSlots.Slot.ZONE_W_STRONG, Group.F,
						Vector3(strong_x * _ZONE_WALL_X_M, 0.0,
								own_goal_z - own_dir * _ZONE_WALL_DEPTH_M),
						_side_home_f(strong_x)),
				SlotSpec.make(AIRoleSlots.Slot.ZONE_W_WEAK, Group.F,
						Vector3(-strong_x * _ZONE_WEAK_X_M, 0.0,
								own_goal_z - own_dir * _ZONE_WEAK_DEPTH_M),
						_side_home_f(-strong_x)),
			]

		AIPossessionState.State.BREAKOUT:
			return _breakout_post_specs(own_goal_z, own_dir, strong_x,
					half_w, our_blue_z)

		AIPossessionState.State.TRANS_DEFENSE:
			# The layered rush defense (docs/transition-defense-plan.md §5): a D
			# pair in front, three forwards tracking back through mid-ice. Race
			# targets are LANE points, not men — the structure is lanes and
			# layers, and which man each body ends up on falls out of whose ice
			# he skates into.
			var mid_gate: Vector3 = our_net - _rush_axis(our_net, puck_pos) \
					* AIZoneCoverage.HOUSE_TOP_DEPTH_M
			return [
				# D1 races home (the gap he holds sweeps toward our net); D2
				# races the mid-ice layer behind him.
				SlotSpec.make(AIRoleSlots.Slot.RUSH_D1, Group.D, our_net),
				SlotSpec.make(AIRoleSlots.Slot.RUSH_D2, Group.D, mid_gate),
				# F1 back races the CARRIER — the only man-shaped target here,
				# because running the puck down is a man-shaped job.
				SlotSpec.make(AIRoleSlots.Slot.TRACK_PUCK, Group.F, puck_pos),
				SlotSpec.make(AIRoleSlots.Slot.TRACK_MID_STRONG, Group.F,
						mid_gate + Vector3(strong_x * _TRACK_MID_SPLIT_M, 0.0, 0.0),
						_side_home_f(strong_x)),
				SlotSpec.make(AIRoleSlots.Slot.TRACK_MID_WEAK, Group.F,
						mid_gate - Vector3(strong_x * _TRACK_MID_SPLIT_M, 0.0, 0.0),
						_side_home_f(-strong_x)),
			]

		AIPossessionState.State.TRANS_OFFENSE:
			return [
				SlotSpec.make(AIRoleSlots.Slot.DVALVE, Group.D, our_net),
				SlotSpec.make(AIRoleSlots.Slot.WIDE_L, Group.F,
						Vector3(-(half_w - _WIDE_LANE_INSET_M), 0.0, puck_pos.z), 1),
				SlotSpec.make(AIRoleSlots.Slot.WIDE_R, Group.F,
						Vector3(half_w - _WIDE_LANE_INSET_M, 0.0, puck_pos.z), 2),
				# The trailer cross-fills by construction: it's the leftover
				# F when a D carries, the activating D when a forward does.
				SlotSpec.make(AIRoleSlots.Slot.TRAILER, Group.ANY,
						Vector3(0.0, 0.0, puck_pos.z + own_dir * 6.0)),
			]

		AIPossessionState.State.NEUTRAL:
			return [
				# A loose puck is everyone's puck — the retrieval race is
				# global (ANY), so a D nearest a faceoff scrum still takes it.
				SlotSpec.make(AIRoleSlots.Slot.CHASE, Group.ANY, puck_pos),
				SlotSpec.make(AIRoleSlots.Slot.DBACK_L, Group.D,
						Vector3(-_DBACK_X_M, 0.0, our_blue_z), 3),
				SlotSpec.make(AIRoleSlots.Slot.DBACK_R, Group.D,
						Vector3(_DBACK_X_M, 0.0, our_blue_z), 4),
				SlotSpec.make(AIRoleSlots.Slot.FLANK_L, Group.F,
						Vector3(puck_pos.x - _FLANK_SPREAD_M, 0.0,
								puck_pos.z + own_dir * _FLANK_TRAIL_M), 1),
				SlotSpec.make(AIRoleSlots.Slot.FLANK_R, Group.F,
						Vector3(puck_pos.x + _FLANK_SPREAD_M, 0.0,
								puck_pos.z + own_dir * _FLANK_TRAIL_M), 2),
			]

	var empty: Array[SlotSpec] = []
	return empty


# The four breakout post specs: the outlets a carrier breaking out reads for.
static func _breakout_post_specs(own_goal_z: float, own_dir: float,
		strong_x: float, half_w: float, our_blue_z: float) -> Array[SlotSpec]:
	return [
		SlotSpec.make(AIRoleSlots.Slot.BREAKOUT_D2, Group.D,
				Vector3(0.0, 0.0, own_goal_z - own_dir * 1.0)),
		SlotSpec.make(AIRoleSlots.Slot.BREAKOUT_STRONG, Group.F,
				Vector3(strong_x * (half_w - 2.0), 0.0, our_blue_z),
				_side_home_f(strong_x)),
		SlotSpec.make(AIRoleSlots.Slot.BREAKOUT_C, Group.F,
				Vector3(0.0, 0.0, own_goal_z - own_dir * _BREAKOUT_SWING_DEPTH_M),
				0),
		SlotSpec.make(AIRoleSlots.Slot.BREAKOUT_STRETCH, Group.F,
				Vector3(-strong_x * (half_w - _STRETCH_WALL_INSET_M), 0.0, 0.0),
				_side_home_f(-strong_x)),
	]


# Unit vector from the rush origin toward our net — the axis the TRANS_DEFENSE lane
# targets lay out along, so the whole structure rotates with a rush coming up a
# wall instead of assuming it comes down the middle.
static func _rush_axis(our_net: Vector3, puck_pos: Vector3) -> Vector3:
	var dx: float = our_net.x - puck_pos.x
	var dz: float = our_net.z - puck_pos.z
	var d: float = sqrt(dx * dx + dz * dz)
	if d < 0.001:
		return Vector3(0.0, 0.0, signf(our_net.z))
	return Vector3(dx / d, 0.0, dz / d)


# Home identity for a side-signed D slot: LD (lobby slot 3) rests on the -X
# side, RD (4) on +X. World X is side-stable for both teams (the lobby grid
# and FACEOFF_OFFSETS put the L slots at -X regardless of attack direction).
static func _side_home_d(side_x: float) -> int:
	return 3 if side_x < 0.0 else 4


# Same for the side-signed F wall slots: LW (1) rests -X, RW (2) +X.
static func _side_home_f(side_x: float) -> int:
	return 1 if side_x < 0.0 else 2


# ── Election ─────────────────────────────────────────────────────────────────

# Soonest-to-arrive election with hysteresis + home-identity bias, scoped to
# the spec's group when `group_scoped` (pass 1) and open to everyone
# otherwise (pass 2 cross-fill).
static func _pick_soonest(
		snapshot: WorldSnapshot,
		teammates: Array[int],
		assigned: Dictionary,
		prev_assignments: Dictionary,
		spec: SlotSpec,
		caps_by_peer: Dictionary,
		position_by_peer: Dictionary,
		group_scoped: bool) -> int:
	var best_pid: int = -1
	var best_score: float = INF
	for pid: int in teammates:
		if assigned.has(pid):
			continue
		if group_scoped and spec.group != Group.ANY \
				and _group_of(pid, position_by_peer) != spec.group:
			continue
		var s: SkaterNetworkState = snapshot.skater_states[pid]
		var caps: AISkaterCaps = caps_by_peer.get(pid)
		var speed: float = caps.max_speed if caps != null \
				else AIActionScoring.SKATER_REF_SPEED_M_S
		var t: float = AIActionScoring.time_to_arrive(
				s.position, spec.target, s.velocity, speed)
		# Feasibility deadline (pass 1 only): a candidate who can't make the
		# race target in time is no candidate — defer to cross-fill rather
		# than electing a body that can never do the job. Raw kinematic t;
		# the stickiness/identity adjustments below are preferences, not
		# physics, so they don't buy time against the deadline.
		if group_scoped and t > spec.deadline_s:
			continue
		if _hysteresis_class(prev_assignments.get(pid, AIRoleSlots.Slot.NONE)) \
				!= _hysteresis_class(spec.slot):
			t += HYSTERESIS_PENALTY_S
		if spec.home_slot != -1 and position_by_peer.get(pid, -1) == spec.home_slot:
			t -= POSITION_BIAS_S
		if t < best_score or (t == best_score and (best_pid == -1 or pid < best_pid)):
			best_score = t
			best_pid = pid
	return best_pid


static func _group_of(pid: int, position_by_peer: Dictionary) -> int:
	var lobby_slot: int = position_by_peer.get(pid, 0)
	return Group.D if PlayerRules.is_defense_slot(lobby_slot) else Group.F


# Cross-state hysteresis continuity for the 5v5 slots (the 3v3 sibling is
# AIRoleSlots._hysteresis_class). Possession flips rename the jobs — the
# strong-side D's corner battle becomes the strong point becomes the
# forecheck's strong line stand — and exact-enum hysteresis would see no
# continuity across the rename, reshuffling the pair at every state flip.
# Mapping each slot to its continuity class keeps the strong-side guy the
# strong-side guy (and the trailer the trailer) through the rename; the
# bonus is only HYSTERESIS_PENALTY_S, so real kinematics still swap them.
static func _hysteresis_class(slot: int) -> int:
	match slot:
		AIRoleSlots.Slot.ZONE_D_STRONG, AIRoleSlots.Slot.POINT_STRONG, \
		AIRoleSlots.Slot.DP_STRONG, AIRoleSlots.Slot.RUSH_D1:
			return AIRoleSlots.Slot.ZONE_D_STRONG        # strong/engaged D
		AIRoleSlots.Slot.ZONE_D_WEAK, AIRoleSlots.Slot.POINT_WEAK, \
		AIRoleSlots.Slot.DP_WEAK, AIRoleSlots.Slot.BREAKOUT_D2, \
		AIRoleSlots.Slot.DVALVE, AIRoleSlots.Slot.RUSH_D2:
			return AIRoleSlots.Slot.ZONE_D_WEAK          # safety/net-front D
		AIRoleSlots.Slot.ZONE_W_STRONG, AIRoleSlots.Slot.F2_STRONG, \
		AIRoleSlots.Slot.BREAKOUT_STRONG, AIRoleSlots.Slot.TRACK_MID_STRONG:
			return AIRoleSlots.Slot.ZONE_W_STRONG        # strong-wall F
		AIRoleSlots.Slot.ZONE_W_WEAK, AIRoleSlots.Slot.F2_WEAK, \
		AIRoleSlots.Slot.BREAKOUT_STRETCH, AIRoleSlots.Slot.HIGH_SLOT, \
		AIRoleSlots.Slot.TRACK_MID_WEAK:
			return AIRoleSlots.Slot.ZONE_W_WEAK          # weak-side/high F
		AIRoleSlots.Slot.ZONE_C, AIRoleSlots.Slot.BREAKOUT_C, \
		AIRoleSlots.Slot.TRAILER, AIRoleSlots.Slot.TRACK_PUCK:
			return AIRoleSlots.Slot.ZONE_C               # middle-support F
		AIRoleSlots.Slot.NET_FRONT, AIRoleSlots.Slot.FINISHER:
			return AIRoleSlots.Slot.FINISHER             # net-front scorer
		_:
			return slot
