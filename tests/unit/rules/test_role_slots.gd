extends GutTest

# AIRoleSlots is pure-function. Tests cover slot lists per state and
# assignment via state-specific semantic queries (soonest-to-puck,
# soonest-to-net, goal-side gap defender). Elections are momentum-aware
# (time_to_arrive at each peer's Speed cap); stationary peers with
# default caps reduce to distance ordering, which most tests use.

const OUR_NET_Z: float = 26.65
const TEAM_ID: int = 0


func _make_snapshot(skaters: Array, carrier_pid: int = -1, puck_z: float = 0.0,
		puck_x: float = 0.0) -> WorldSnapshot:
	# skaters: Array of [peer_id, team_id, position] or
	# [peer_id, team_id, position, velocity]
	var snap := WorldSnapshot.new()
	for entry: Array in skaters:
		var s := SkaterNetworkState.new()
		s.position = entry[2]
		if entry.size() > 3:
			s.velocity = entry[3]
		snap.skater_states[entry[0]] = s
	var puck := PuckNetworkState.new()
	puck.carrier_peer_id = carrier_pid
	if carrier_pid != -1:
		for entry: Array in skaters:
			if entry[0] == carrier_pid:
				puck.position = entry[2]
				break
	else:
		puck.position = Vector3(puck_x, 0.0, puck_z)
	snap.puck_state = puck
	return snap


func _resolver(skaters: Array) -> Dictionary:
	var team_map: Dictionary = {}
	for entry: Array in skaters:
		team_map[entry[0]] = entry[1]
	return team_map


# ─── Slot lists ─────────────────────────────────────────────────────────────

func test_slots_for_dzone() -> void:
	# One PRESSURE on the carrier, the rest MARK a man each.
	var slots: Array = AIRoleSlots.slots_for_state(AIPossessionState.State.DZONE)
	assert_true(slots.has(AIRoleSlots.Slot.PRESSURE))
	assert_true(slots.has(AIRoleSlots.Slot.MARK))


func test_slots_for_ozone() -> void:
	var slots: Array = AIRoleSlots.slots_for_state(AIPossessionState.State.OZONE)
	assert_true(slots.has(AIRoleSlots.Slot.CARRIER))
	assert_true(slots.has(AIRoleSlots.Slot.FINISHER))
	assert_true(slots.has(AIRoleSlots.Slot.SUPPORT))


func test_slots_for_trans_do() -> void:
	var slots: Array = AIRoleSlots.slots_for_state(AIPossessionState.State.TRANS_DO)
	assert_true(slots.has(AIRoleSlots.Slot.CARRIER))
	assert_true(slots.has(AIRoleSlots.Slot.OUTLET))
	assert_true(slots.has(AIRoleSlots.Slot.SUPPORT))


func test_slots_for_breakout() -> void:
	# BREAKOUT (we possess in our own DZ) uses {CARRIER, BREAKOUT_STRONG,
	# BREAKOUT_WEAK}: the carrier plus a strong-side-wall outlet and a
	# weak-side reverse valve.
	var slots: Array = AIRoleSlots.slots_for_state(AIPossessionState.State.BREAKOUT)
	assert_true(slots.has(AIRoleSlots.Slot.CARRIER))
	assert_true(slots.has(AIRoleSlots.Slot.BREAKOUT_STRONG))
	assert_true(slots.has(AIRoleSlots.Slot.BREAKOUT_WEAK))


func test_slots_for_trans_od() -> void:
	# TRANS_OD uses {CONTAIN, MARK×2}: the goal-side peer gap-controls the
	# carrier (CONTAIN), the other two sprint home to cover a man each (MARK).
	# PRESSURE is no longer a transition role — exactly one peer (CONTAIN)
	# engages the carrier.
	var slots: Array = AIRoleSlots.slots_for_state(AIPossessionState.State.TRANS_OD)
	assert_true(slots.has(AIRoleSlots.Slot.CONTAIN))
	assert_true(slots.has(AIRoleSlots.Slot.MARK))
	assert_false(slots.has(AIRoleSlots.Slot.PRESSURE),
			"PRESSURE is no longer assigned in transition")


func test_slots_for_neutral() -> void:
	# NEUTRAL has its own role behaviors (CHASE, FLANK_L, FLANK_R)
	# since the no-carrier scenario calls for "race to puck + hold
	# support" semantics rather than the inverse-scoring defensive
	# roles. See test_role_chase.gd / test_role_flank.gd for the
	# behavior tests.
	var slots: Array = AIRoleSlots.slots_for_state(AIPossessionState.State.NEUTRAL)
	assert_true(slots.has(AIRoleSlots.Slot.CHASE))
	assert_true(slots.has(AIRoleSlots.Slot.FLANK_L))
	assert_true(slots.has(AIRoleSlots.Slot.FLANK_R))


# ─── Slot anchors ───────────────────────────────────────────────────────────
# slot_anchor() is now dead surface. Every role owns its positional
# target in its role-behavior module. Step 3 (final cleanup) deletes
# the function entirely.


# ─── assign() ───────────────────────────────────────────────────────────────

func test_assign_dzone_distributes_slots() -> void:
	# PRESSURE = closest to the puck; the other two MARK a man each. Which
	# marker ends up net-front vs. weak-side is decided downstream by the threat
	# partition, not here — so both non-pressure peers are simply MARK.
	var skaters: Array = [
			[100, 0, Vector3(4.5, 0.0, 22.5)],   # closest to puck → PRESSURE
			[110, 0, Vector3(0.5, 0.0, 25.65)],
			[120, 0, Vector3(-2.0, 0.0, 22.65)],
			[200, 1, Vector3(5.0, 0.0, 22.0)],
	]
	var snap := _make_snapshot(skaters, 200)
	var assignments: Dictionary[int, int] = AIRoleSlots.assign(
			snap, TEAM_ID, OUR_NET_Z, AIPossessionState.State.DZONE,
			_resolver(skaters), {})
	assert_eq(assignments[100], AIRoleSlots.Slot.PRESSURE)
	assert_eq(assignments[110], AIRoleSlots.Slot.MARK)
	assert_eq(assignments[120], AIRoleSlots.Slot.MARK)


func test_assign_ozone_carrier_is_fixed() -> void:
	var skaters: Array = [
			[100, 0, Vector3(0.0, 0.0, -22.0)],
			[110, 0, Vector3(-3.0, 0.0, -25.0)],
			[120, 0, Vector3(0.0, 0.0, -16.0)],
	]
	var snap := _make_snapshot(skaters, 100)
	var assignments: Dictionary[int, int] = AIRoleSlots.assign(
			snap, TEAM_ID, OUR_NET_Z, AIPossessionState.State.OZONE,
			_resolver(skaters), {})
	assert_eq(assignments[100], AIRoleSlots.Slot.CARRIER)
	assert_true(assignments.has(110))
	assert_true(assignments.has(120))
	# OZONE non-carrier slots are FINISHER and SUPPORT (no OUTLET).
	var non_carrier_slots: Array = [assignments[110], assignments[120]]
	assert_true(AIRoleSlots.Slot.FINISHER in non_carrier_slots)
	assert_true(AIRoleSlots.Slot.SUPPORT in non_carrier_slots)


func test_assign_trans_do_geometry_drives_outlet_and_support() -> void:
	# Carrier at NZ. Bot up-ice in OZ → OUTLET. Bot deep in DZ → SUPPORT.
	var skaters: Array = [
			[100, 0, Vector3(0.0, 0.0, 0.0)],   # carrier (NZ center)
			[110, 0, Vector3(-4.0, 0.0, -13.0)],# up-ice weak-side near OUTLET anchor
			[120, 0, Vector3(0.0, 0.0, 5.0)],   # deeper, near SUPPORT anchor
	]
	var snap := _make_snapshot(skaters, 100)
	var assignments: Dictionary[int, int] = AIRoleSlots.assign(
			snap, TEAM_ID, OUR_NET_Z, AIPossessionState.State.TRANS_DO,
			_resolver(skaters), {})
	assert_eq(assignments[100], AIRoleSlots.Slot.CARRIER)
	assert_eq(assignments[110], AIRoleSlots.Slot.OUTLET, "up-ice bot becomes OUTLET")
	assert_eq(assignments[120], AIRoleSlots.Slot.SUPPORT, "deep bot becomes SUPPORT")


func test_breakout_strong_keeps_the_outlet_role_across_the_handoff() -> void:
	# BREAKOUT→TRANS_DO renames BREAKOUT_STRONG→OUTLET; the peer that was the
	# up-ice strong-side outlet should STAY the up-ice OUTLET across the flip
	# (hysteresis continuity class), not swap destinations with the trailer.
	# Two peers tied on ETA to the opp net: the pid tiebreak alone would hand
	# OUTLET to the lower pid (110), but 120 held BREAKOUT_STRONG last tick, so
	# the continuity bonus keeps OUTLET on 120.
	var skaters: Array = [
			[100, 0, Vector3(0.0, 0.0, 0.0)],    # carrier at NZ
			[110, 0, Vector3(-3.0, 0.0, -10.0)], # tied ETA to opp net
			[120, 0, Vector3(3.0, 0.0, -10.0)],  # tied ETA to opp net
	]
	var snap := _make_snapshot(skaters, 100)
	var prev: Dictionary = {
			120: AIRoleSlots.Slot.BREAKOUT_STRONG,
			110: AIRoleSlots.Slot.BREAKOUT_WEAK,
	}
	var assignments: Dictionary[int, int] = AIRoleSlots.assign(
			snap, TEAM_ID, OUR_NET_Z, AIPossessionState.State.TRANS_DO,
			_resolver(skaters), prev)
	assert_eq(assignments[120], AIRoleSlots.Slot.OUTLET,
			"the ex-BREAKOUT_STRONG peer stays the up-ice OUTLET")
	assert_eq(assignments[110], AIRoleSlots.Slot.SUPPORT,
			"the ex-BREAKOUT_WEAK peer stays the trailer")


func test_assign_breakout_strong_goes_to_strong_side_peer() -> void:
	# Carrier deep in our own zone. Strong side is +X (default
	# _strong_x = +1), so the +X non-carrier takes BREAKOUT_STRONG and
	# the -X one takes the weak-side reverse (BREAKOUT_WEAK).
	var skaters: Array = [
			[100, 0, Vector3(0.0, 0.0, 20.0)],   # carrier, deep in our DZ
			[110, 0, Vector3(9.0, 0.0, 12.0)],   # +X side → STRONG
			[120, 0, Vector3(-9.0, 0.0, 20.0)],  # -X side → WEAK
	]
	var snap := _make_snapshot(skaters, 100)
	var assignments: Dictionary[int, int] = AIRoleSlots.assign(
			snap, TEAM_ID, OUR_NET_Z, AIPossessionState.State.BREAKOUT,
			_resolver(skaters), {}, 1.0)
	assert_eq(assignments[100], AIRoleSlots.Slot.CARRIER)
	assert_eq(assignments[110], AIRoleSlots.Slot.BREAKOUT_STRONG,
			"+X-side bot takes the strong-side-wall outlet")
	assert_eq(assignments[120], AIRoleSlots.Slot.BREAKOUT_WEAK,
			"-X-side bot takes the weak-side reverse valve")


func test_assign_breakout_strong_follows_strong_x_sign() -> void:
	# Flip the strong side to -X: now the -X peer should take STRONG.
	var skaters: Array = [
			[100, 0, Vector3(0.0, 0.0, 20.0)],
			[110, 0, Vector3(9.0, 0.0, 12.0)],
			[120, 0, Vector3(-9.0, 0.0, 12.0)],
	]
	var snap := _make_snapshot(skaters, 100)
	var assignments: Dictionary[int, int] = AIRoleSlots.assign(
			snap, TEAM_ID, OUR_NET_Z, AIPossessionState.State.BREAKOUT,
			_resolver(skaters), {}, -1.0)
	assert_eq(assignments[120], AIRoleSlots.Slot.BREAKOUT_STRONG,
			"with strong side -X, the -X bot takes the strong outlet")
	assert_eq(assignments[110], AIRoleSlots.Slot.BREAKOUT_WEAK)


func test_slots_for_forecheck() -> void:
	# FORECHECK (opp possesses in their own DZ) uses {F1_PRESSURE,
	# F2_MID, F3_HIGH}: the 1-1-1 forecheck. No CARRIER (opp has it).
	var slots: Array = AIRoleSlots.slots_for_state(AIPossessionState.State.FORECHECK)
	assert_true(slots.has(AIRoleSlots.Slot.F1_PRESSURE))
	assert_true(slots.has(AIRoleSlots.Slot.F2_MID))
	assert_true(slots.has(AIRoleSlots.Slot.F3_HIGH))


func test_assign_forecheck_f1_pressures_puck_f3_is_high() -> void:
	# Team 0 forechecking in the opp end (opp net at -Z). Opp 200 carries
	# the puck deep (z = -22). F3 = closest to the opp blue line (highest
	# / least deep), F1 = closest to the puck of the rest, F2 = leftover.
	var skaters: Array = [
			[100, 0, Vector3(0.0, 0.0, -8.0)],   # high, near opp blue (-7.29) → F3
			[110, 0, Vector3(2.0, 0.0, -21.0)],  # deep, near puck → F1
			[120, 0, Vector3(-3.0, 0.0, -14.0)], # mid → F2
			[200, 1, Vector3(0.0, 0.0, -22.0)],  # opp carrier, deep
	]
	var snap := _make_snapshot(skaters, 200)
	var assignments: Dictionary[int, int] = AIRoleSlots.assign(
			snap, TEAM_ID, OUR_NET_Z, AIPossessionState.State.FORECHECK,
			_resolver(skaters), {})
	assert_eq(assignments[100], AIRoleSlots.Slot.F3_HIGH, "highest bot is the safety")
	assert_eq(assignments[110], AIRoleSlots.Slot.F1_PRESSURE, "bot nearest the puck pressures")
	assert_eq(assignments[120], AIRoleSlots.Slot.F2_MID, "leftover bot reads the mid lane")


func test_assign_trans_od_gap_is_closest_goal_side_to_carrier() -> void:
	# TRANS_OD: CONTAIN goes to the closest GOAL-SIDE peer (between carrier and
	# our +Z net), not the deepest. Carrier at z=0; peer 110 (z=5) is goal-side
	# and nearest the carrier, so it gaps; the deep peer (120) and the
	# caught-up-ice peer (100, not goal-side) backcheck to a man each.
	var skaters: Array = [
			[100, 0, Vector3(0.0, 0.0, -8.0)],  # up-ice, NOT goal-side → MARK
			[110, 0, Vector3(0.0, 0.0, 5.0)],   # goal-side, closest to carrier → CONTAIN
			[120, 0, Vector3(0.0, 0.0, 20.0)],  # goal-side but deep → MARK
			[200, 1, Vector3(0.0, 0.0, 0.0)],   # opp carrier
	]
	var snap := _make_snapshot(skaters, 200)
	var assignments: Dictionary[int, int] = AIRoleSlots.assign(
			snap, TEAM_ID, OUR_NET_Z, AIPossessionState.State.TRANS_OD,
			_resolver(skaters), {})
	assert_eq(assignments[110], AIRoleSlots.Slot.CONTAIN,
			"closest goal-side peer gaps the carrier as CONTAIN")
	assert_eq(assignments[100], AIRoleSlots.Slot.MARK,
			"caught-up-ice peer marks home to a man")
	assert_eq(assignments[120], AIRoleSlots.Slot.MARK,
			"deep peer marks (it's not the closest to the carrier)")
	# Exactly one engager — no double-team.
	var contain_count: int = 0
	for pid: int in [100, 110, 120]:
		if assignments[pid] == AIRoleSlots.Slot.CONTAIN:
			contain_count += 1
	assert_eq(contain_count, 1, "exactly one CONTAIN")


func test_assign_trans_od_gap_falls_back_to_deepest_when_none_goal_side() -> void:
	# The whole team caught up-ice on the turnover — nobody is goal-side of the
	# carrier (all on the -Z side of it). CONTAIN falls back to the deepest peer
	# (closest to our +Z net), who recovers into the gap fastest.
	var skaters: Array = [
			[100, 0, Vector3(0.0, 0.0, -5.0)],  # deepest of the caught peers → CONTAIN
			[110, 0, Vector3(0.0, 0.0, -10.0)],
			[120, 0, Vector3(0.0, 0.0, -8.0)],
			[200, 1, Vector3(0.0, 0.0, 0.0)],   # opp carrier; all peers are up-ice of it
	]
	var snap := _make_snapshot(skaters, 200)
	var assignments: Dictionary[int, int] = AIRoleSlots.assign(
			snap, TEAM_ID, OUR_NET_Z, AIPossessionState.State.TRANS_OD,
			_resolver(skaters), {})
	assert_eq(assignments[100], AIRoleSlots.Slot.CONTAIN,
			"no goal-side peer → deepest (nearest our net) recovers as the gapper")
	assert_eq(assignments[110], AIRoleSlots.Slot.MARK)
	assert_eq(assignments[120], AIRoleSlots.Slot.MARK)


func test_assign_hysteresis_keeps_prev_when_close() -> void:
	# Semantic assignment: PRESSURE = soonest to puck, with
	# HYSTERESIS_PENALTY_S added to a contender's effective arrival
	# time. Setup: peer 110 is 0.5 m closer to puck than 100, but 100
	# currently has PRESSURE — the time penalty on 110 keeps 100 in
	# the slot.
	var skaters: Array = [
			[100, 0, Vector3(4.0, 0.0, 22.0)],   # 1.0 m from puck
			[110, 0, Vector3(4.5, 0.0, 22.0)],   # 0.5 m from puck (raw closer)
			[120, 0, Vector3(-2.0, 0.0, 25.0)],  # near our net
			[200, 1, Vector3(5.0, 0.0, 22.0)],
	]
	var snap := _make_snapshot(skaters, 200)
	var prev: Dictionary = {
			100: AIRoleSlots.Slot.PRESSURE,
			110: AIRoleSlots.Slot.MARK,
			120: AIRoleSlots.Slot.MARK,
	}
	var assignments: Dictionary[int, int] = AIRoleSlots.assign(
			snap, TEAM_ID, OUR_NET_Z, AIPossessionState.State.DZONE,
			_resolver(skaters), prev)
	# Effective ETA at league speed 9: 100 = 1.0/9 ≈ 0.111 s (no
	# penalty, was PRESSURE); 110 = 0.5/9 + 0.12 ≈ 0.176 s. 100 wins.
	assert_eq(assignments[100], AIRoleSlots.Slot.PRESSURE,
			"peer 100 keeps PRESSURE despite peer 110 being 0.5 m closer to puck")


func test_assign_hysteresis_swaps_when_contender_meaningfully_sooner() -> void:
	# The contender's arrival advantage now exceeds the hysteresis
	# margin — the slot flips to the genuinely better-placed peer.
	var skaters: Array = [
			[100, 0, Vector3(2.0, 0.0, 22.0)],   # 3.0 m from puck → 0.333 s
			[110, 0, Vector3(4.0, 0.0, 22.0)],   # 1.0 m → 0.111 + 0.12 = 0.231 s
			[120, 0, Vector3(-2.0, 0.0, 25.0)],
			[200, 1, Vector3(5.0, 0.0, 22.0)],
	]
	var snap := _make_snapshot(skaters, 200)
	var prev: Dictionary = {
			100: AIRoleSlots.Slot.PRESSURE,
			110: AIRoleSlots.Slot.MARK,
			120: AIRoleSlots.Slot.MARK,
	}
	var assignments: Dictionary[int, int] = AIRoleSlots.assign(
			snap, TEAM_ID, OUR_NET_Z, AIPossessionState.State.DZONE,
			_resolver(skaters), prev)
	assert_eq(assignments[110], AIRoleSlots.Slot.PRESSURE,
			"a contender arriving clearly sooner takes the slot through hysteresis")


func test_assign_momentum_beats_raw_distance() -> void:
	# The election is momentum-aware: a nearer peer coasting AWAY from the
	# puck loses PRESSURE to a farther peer already skating at it. This is
	# the raw-distance failure the ETA election replaces (the old metric
	# handed the slot to the wrong body, which then brake-pivoted).
	var skaters: Array = [
			[100, 0, Vector3(3.0, 0.0, 22.0), Vector3(-8.0, 0.0, 0.0)],  # 2 m away, fleeing → ETA 2/(9−8) = 2 s
			[110, 0, Vector3(9.0, 0.0, 22.0), Vector3(-8.0, 0.0, 0.0)],  # 4 m away, closing → ETA 4/17 ≈ 0.24 s
			[120, 0, Vector3(-2.0, 0.0, 25.0)],
			[200, 1, Vector3(5.0, 0.0, 22.0)],
	]
	var snap := _make_snapshot(skaters, 200)
	var assignments: Dictionary[int, int] = AIRoleSlots.assign(
			snap, TEAM_ID, OUR_NET_Z, AIPossessionState.State.DZONE,
			_resolver(skaters), {})
	assert_eq(assignments[110], AIRoleSlots.Slot.PRESSURE,
			"the peer skating AT the puck wins over a nearer peer coasting away")
	assert_eq(assignments[100], AIRoleSlots.Slot.MARK)


func test_assign_speed_cap_feeds_election() -> void:
	# Each peer races at its real Speed cap: a faster build farther out
	# arrives sooner and takes the slot.
	var skaters: Array = [
			[100, 0, Vector3(1.0, 0.0, 22.0)],   # 4 m from puck at ref 9 → 0.444 s
			[110, 0, Vector3(-1.0, 0.0, 22.0)],  # 6 m from puck at cap 20 → 0.3 s
			[120, 0, Vector3(-2.0, 0.0, 25.0)],
			[200, 1, Vector3(5.0, 0.0, 22.0)],
	]
	var snap := _make_snapshot(skaters, 200)
	var fast_caps := AISkaterCaps.new()
	fast_caps.max_speed = 20.0
	var assignments: Dictionary[int, int] = AIRoleSlots.assign(
			snap, TEAM_ID, OUR_NET_Z, AIPossessionState.State.DZONE,
			_resolver(skaters), {}, 1.0, {110: fast_caps})
	assert_eq(assignments[110], AIRoleSlots.Slot.PRESSURE,
			"a faster Speed build farther out wins the arrival race")


# ─── NEUTRAL assignment ─────────────────────────────────────────────────────

func test_assign_neutral_chase_and_flanks() -> void:
	# Loose puck at center ice. CHASE goes to closest peer; the other
	# two split lateral L/R based on X position.
	var skaters: Array = [
			[100, 0, Vector3(1.0, 0.0, 0.0)],    # closest to puck
			[110, 0, Vector3(-5.0, 0.0, -3.0)],  # left side
			[120, 0, Vector3(5.0, 0.0, -3.0)],   # right side
	]
	var snap := _make_snapshot(skaters, -1, 0.0, 0.0)
	var assignments: Dictionary[int, int] = AIRoleSlots.assign(
			snap, TEAM_ID, OUR_NET_Z, AIPossessionState.State.NEUTRAL,
			_resolver(skaters), {})
	assert_eq(assignments[100], AIRoleSlots.Slot.CHASE)
	assert_eq(assignments[110], AIRoleSlots.Slot.FLANK_L)
	assert_eq(assignments[120], AIRoleSlots.Slot.FLANK_R)


func test_assign_neutral_flank_hysteresis_holds_through_center() -> void:
	# Two peers near center — without hysteresis they'd flip L/R any
	# time their X order swaps. With prev assignments preserving
	# their sides, the 1.0 m penalty keeps them stable.
	# Puck placed on top of 100 so 100 wins CHASE (closest); the
	# remaining flank pair near center exercises the hysteresis.
	var skaters: Array = [
			[100, 0, Vector3(0.0, 0.0, 5.0)],    # at puck → CHASE
			[110, 0, Vector3(0.3, 0.0, -3.0)],   # nominally right of center
			[120, 0, Vector3(-0.3, 0.0, -3.0)],  # nominally left of center
	]
	var snap := _make_snapshot(skaters, -1, 5.0, 0.0)
	# Prev: 110 was FLANK_L, 120 was FLANK_R. Their X positions
	# now swap by 0.6 m; hysteresis (1.0 m on each side) keeps
	# them in their previous slots.
	var prev: Dictionary = {
			100: AIRoleSlots.Slot.CHASE,
			110: AIRoleSlots.Slot.FLANK_L,
			120: AIRoleSlots.Slot.FLANK_R,
	}
	var assignments: Dictionary[int, int] = AIRoleSlots.assign(
			snap, TEAM_ID, OUR_NET_Z, AIPossessionState.State.NEUTRAL,
			_resolver(skaters), prev)
	# Effective X: 110 = 0.3 - 1.0 = -0.7. 120 = -0.3 + 1.0 = 0.7.
	# 110 still has lower effective X → keeps FLANK_L.
	assert_eq(assignments[110], AIRoleSlots.Slot.FLANK_L,
			"FLANK_L sticks across a small center crossing")
	assert_eq(assignments[120], AIRoleSlots.Slot.FLANK_R,
			"FLANK_R sticks across a small center crossing")


# ─── Mixed-team behavior ────────────────────────────────────────────────────

func test_mixed_team_human_carrier_bots_fill_other_slots() -> void:
	# Human (real peer 1) has the puck → CARRIER. Two bots fill
	# FINISHER and SUPPORT in OZONE.
	var skaters: Array = [
			[1, 0, Vector3(0.0, 0.0, -22.0)],     # human carrier
			[10000, 0, Vector3(-3.0, 0.0, -25.0)],# bot near FINISHER
			[10001, 0, Vector3(0.0, 0.0, -16.0)], # bot near SUPPORT
	]
	var snap := _make_snapshot(skaters, 1)
	var assignments: Dictionary[int, int] = AIRoleSlots.assign(
			snap, TEAM_ID, OUR_NET_Z, AIPossessionState.State.OZONE,
			_resolver(skaters), {})
	assert_eq(assignments[1], AIRoleSlots.Slot.CARRIER)
	assert_true(assignments.has(10000))
	assert_true(assignments.has(10001))
	assert_ne(assignments[10000], assignments[10001], "bots get different slots")
