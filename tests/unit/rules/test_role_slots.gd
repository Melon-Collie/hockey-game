extends GutTest

# AIRoleSlots is pure-function. Tests cover slot lists per state,
# anchor formulas (still around for now — used by role behaviors
# until Step 2 of the no-anchors refactor), and assignment via
# state-specific semantic queries (closest-to-puck, closest-to-net).
#
# Sprinting Through (TRANS_OD ANCHOR criterion = closest to opp net)
# is documented in the test name + docstring rather than hidden in
# a pre-pick branch.

const OUR_NET_Z: float = 26.65
const TEAM_ID: int = 0


func _make_snapshot(skaters: Array, carrier_pid: int = -1, puck_z: float = 0.0,
		puck_x: float = 0.0) -> WorldSnapshot:
	# skaters: Array of [peer_id, team_id, position]
	var snap := WorldSnapshot.new()
	for entry: Array in skaters:
		var s := SkaterNetworkState.new()
		s.position = entry[2]
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


func _resolver(skaters: Array) -> Callable:
	var team_map: Dictionary = {}
	for entry: Array in skaters:
		team_map[entry[0]] = entry[1]
	return func(pid: int) -> int: return int(team_map.get(pid, -1))


# ─── Slot lists ─────────────────────────────────────────────────────────────

func test_slots_for_dzone() -> void:
	var slots: Array = AIRoleSlots.slots_for_state(AIPossessionState.State.DZONE)
	assert_eq(slots.size(), 3)
	assert_true(slots.has(AIRoleSlots.Slot.PRESSURE))
	assert_true(slots.has(AIRoleSlots.Slot.ANCHOR))
	assert_true(slots.has(AIRoleSlots.Slot.COVER))


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


func test_slots_for_trans_od() -> void:
	# Phase 3: TRANS_OD now uses the same {PRESSURE, ANCHOR, COVER}
	# triple as DZONE. Anchor formulas branch on state.
	var slots: Array = AIRoleSlots.slots_for_state(AIPossessionState.State.TRANS_OD)
	assert_true(slots.has(AIRoleSlots.Slot.PRESSURE))
	assert_true(slots.has(AIRoleSlots.Slot.ANCHOR))
	assert_true(slots.has(AIRoleSlots.Slot.COVER))


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

func test_assign_dzone_distributes_three_slots() -> void:
	# Puck at (5, 22) → strong=+1.
	var skaters: Array = [
			[100, 0, Vector3(4.5, 0.0, 22.5)],   # near PRESSURE anchor
			[110, 0, Vector3(0.5, 0.0, 25.65)],  # near ANCHOR (strong-side post)
			[120, 0, Vector3(-2.0, 0.0, 22.65)], # near COVER (weak-side, mid-slot)
			[200, 1, Vector3(5.0, 0.0, 22.0)],
	]
	var snap := _make_snapshot(skaters, 200)
	var assignments: Dictionary = AIRoleSlots.assign(
			snap, TEAM_ID, OUR_NET_Z, AIPossessionState.State.DZONE,
			_resolver(skaters), {})
	assert_eq(assignments[100], AIRoleSlots.Slot.PRESSURE)
	assert_eq(assignments[110], AIRoleSlots.Slot.ANCHOR)
	assert_eq(assignments[120], AIRoleSlots.Slot.COVER)


func test_assign_ozone_carrier_is_fixed() -> void:
	var skaters: Array = [
			[100, 0, Vector3(0.0, 0.0, -22.0)],
			[110, 0, Vector3(-3.0, 0.0, -25.0)],
			[120, 0, Vector3(0.0, 0.0, -16.0)],
	]
	var snap := _make_snapshot(skaters, 100)
	var assignments: Dictionary = AIRoleSlots.assign(
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
	var assignments: Dictionary = AIRoleSlots.assign(
			snap, TEAM_ID, OUR_NET_Z, AIPossessionState.State.TRANS_DO,
			_resolver(skaters), {})
	assert_eq(assignments[100], AIRoleSlots.Slot.CARRIER)
	assert_eq(assignments[110], AIRoleSlots.Slot.OUTLET, "up-ice bot becomes OUTLET")
	assert_eq(assignments[120], AIRoleSlots.Slot.SUPPORT, "deep bot becomes SUPPORT")


func test_assign_trans_od_anchor_goes_to_highest_player() -> void:
	# Sprinting Through (3v3 backcheck technique): TRANS_OD's ANCHOR
	# criterion is closest-to-opp-net, so the up-ice peer gets the
	# deep-defender role and sprints home. The peer who was "stuck
	# at the slot doing nothing" becomes COVER and engages forward.
	var skaters: Array = [
			[100, 0, Vector3(0.0, 0.0, -10.0)], # up-ice (caught) → ANCHOR
			[110, 0, Vector3(0.0, 0.0, 1.5)],   # near puck → PRESSURE
			[120, 0, Vector3(0.0, 0.0, 21.0)],  # deep → COVER
			[200, 1, Vector3(0.0, 0.0, 0.0)],   # opp carrier
	]
	var snap := _make_snapshot(skaters, 200)
	var assignments: Dictionary = AIRoleSlots.assign(
			snap, TEAM_ID, OUR_NET_Z, AIPossessionState.State.TRANS_OD,
			_resolver(skaters), {})
	assert_eq(assignments[100], AIRoleSlots.Slot.ANCHOR,
			"highest-up-ice bot becomes ANCHOR (constantly backchecking)")
	assert_eq(assignments[110], AIRoleSlots.Slot.PRESSURE,
			"closer-to-puck of remaining becomes PRESSURE")
	assert_eq(assignments[120], AIRoleSlots.Slot.COVER,
			"deep bot becomes COVER (engages play via back-of-puck anchor)")


func test_assign_hysteresis_keeps_prev_when_close() -> void:
	# Semantic assignment: PRESSURE = closest to puck, with
	# HYSTERESIS_PENALTY_M (1.0 m) added to a contender's effective
	# distance. Setup: peer 110 is 0.5 m closer to puck than 100,
	# but 100 currently has PRESSURE — hysteresis (1.0 m penalty
	# on 110) keeps 100 in the slot.
	var skaters: Array = [
			[100, 0, Vector3(4.0, 0.0, 22.0)],   # 1.0 m from puck
			[110, 0, Vector3(4.5, 0.0, 22.0)],   # 0.5 m from puck (raw closer)
			[120, 0, Vector3(-2.0, 0.0, 25.0)],  # near our net
			[200, 1, Vector3(5.0, 0.0, 22.0)],
	]
	var snap := _make_snapshot(skaters, 200)
	var prev: Dictionary = {
			100: AIRoleSlots.Slot.PRESSURE,
			110: AIRoleSlots.Slot.COVER,
			120: AIRoleSlots.Slot.ANCHOR,
	}
	var assignments: Dictionary = AIRoleSlots.assign(
			snap, TEAM_ID, OUR_NET_Z, AIPossessionState.State.DZONE,
			_resolver(skaters), prev)
	# Effective distance: 100 = 1.0 (no penalty, was PRESSURE),
	# 110 = 0.5 + 1.0 = 1.5 (penalty for not having PRESSURE).
	# 100 wins.
	assert_eq(assignments[100], AIRoleSlots.Slot.PRESSURE,
			"peer 100 keeps PRESSURE despite peer 110 being 0.5 m closer to puck")


func test_assign_hysteresis_swaps_when_contender_meaningfully_closer() -> void:
	# Same setup but contender is now 1.5 m closer than the holder —
	# enough to overcome the 1.0 m hysteresis margin. Roles flip.
	var skaters: Array = [
			[100, 0, Vector3(4.0, 0.0, 22.0)],   # 1.0 m from puck
			[110, 0, Vector3(4.7, 0.0, 22.0)],   # ~0.3 m from puck (1.5 m advantage on raw vs hysteresis penalty)
			[120, 0, Vector3(-2.0, 0.0, 25.0)],
			[200, 1, Vector3(5.0, 0.0, 22.0)],
	]
	var snap := _make_snapshot(skaters, 200)
	var prev: Dictionary = {
			100: AIRoleSlots.Slot.PRESSURE,
			110: AIRoleSlots.Slot.COVER,
			120: AIRoleSlots.Slot.ANCHOR,
	}
	var assignments: Dictionary = AIRoleSlots.assign(
			snap, TEAM_ID, OUR_NET_Z, AIPossessionState.State.DZONE,
			_resolver(skaters), prev)
	# 100.d = 1.0; 110.d = 0.3 + 1.0 = 1.3. 100 still wins (penalty
	# margin not yet overcome).
	assert_eq(assignments[100], AIRoleSlots.Slot.PRESSURE,
			"hysteresis blocks the swap when contender's raw advantage"
			+ " is less than the penalty")


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
	var assignments: Dictionary = AIRoleSlots.assign(
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
	var assignments: Dictionary = AIRoleSlots.assign(
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
	var assignments: Dictionary = AIRoleSlots.assign(
			snap, TEAM_ID, OUR_NET_Z, AIPossessionState.State.OZONE,
			_resolver(skaters), {})
	assert_eq(assignments[1], AIRoleSlots.Slot.CARRIER)
	assert_true(assignments.has(10000))
	assert_true(assignments.has(10001))
	assert_ne(assignments[10000], assignments[10001], "bots get different slots")
