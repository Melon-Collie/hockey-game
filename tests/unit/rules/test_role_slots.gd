extends GutTest

# AIRoleSlots is pure-function. Tests cover slot lists per state,
# anchor formulas, slot assignment with permutation enumeration +
# hysteresis, and geometry-driven role distribution in TRANS states
# (no SPRINT_BY locking).

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
	assert_true(slots.has(AIRoleSlots.Slot.NET))
	assert_true(slots.has(AIRoleSlots.Slot.INSIDE))


func test_slots_for_ozone() -> void:
	var slots: Array = AIRoleSlots.slots_for_state(AIPossessionState.State.OZONE)
	assert_true(slots.has(AIRoleSlots.Slot.CARRIER))
	assert_true(slots.has(AIRoleSlots.Slot.BACKDOOR))
	assert_true(slots.has(AIRoleSlots.Slot.OUTLET))


func test_slots_for_trans_do() -> void:
	var slots: Array = AIRoleSlots.slots_for_state(AIPossessionState.State.TRANS_DO)
	assert_true(slots.has(AIRoleSlots.Slot.CARRIER))
	assert_true(slots.has(AIRoleSlots.Slot.OUTLET))
	assert_true(slots.has(AIRoleSlots.Slot.SUPPORT))


func test_slots_for_trans_od() -> void:
	var slots: Array = AIRoleSlots.slots_for_state(AIPossessionState.State.TRANS_OD)
	assert_true(slots.has(AIRoleSlots.Slot.HOME))
	assert_true(slots.has(AIRoleSlots.Slot.CHASE))
	assert_true(slots.has(AIRoleSlots.Slot.COVER))


func test_slots_for_neutral() -> void:
	var slots: Array = AIRoleSlots.slots_for_state(AIPossessionState.State.NEUTRAL)
	assert_true(slots.has(AIRoleSlots.Slot.CHASE))
	assert_true(slots.has(AIRoleSlots.Slot.FLANK_L))
	assert_true(slots.has(AIRoleSlots.Slot.FLANK_R))


# ─── Slot anchors ───────────────────────────────────────────────────────────

func test_dzone_pressure_anchor_is_goal_side_of_puck() -> void:
	var puck := Vector3(5.0, 0.0, 22.0)
	var anchor: Vector3 = AIRoleSlots.slot_anchor(
			AIRoleSlots.Slot.PRESSURE, AIPossessionState.State.DZONE,
			puck, puck, OUR_NET_Z, 1.0)
	assert_lt(anchor.x, puck.x, "anchor X moves toward 0 (net center)")
	assert_gt(anchor.z, puck.z, "anchor Z moves toward our net (+Z)")
	assert_almost_eq(puck.distance_to(anchor), 1.5, 0.01)


func test_dzone_net_anchor_strong_side_post() -> void:
	var anchor: Vector3 = AIRoleSlots.slot_anchor(
			AIRoleSlots.Slot.NET, AIPossessionState.State.DZONE,
			Vector3(5.0, 0.0, 22.0), Vector3.ZERO,
			OUR_NET_Z, 1.0)
	assert_gt(anchor.x, 0.0)
	assert_lt(anchor.x, GameRules.NET_HALF_WIDTH)
	assert_almost_eq(anchor.z, OUR_NET_Z - 1.0, 0.01)


func test_ozone_outlet_high_shadowing_puck_x() -> void:
	var puck := Vector3(5.0, 0.0, -22.0)
	var anchor: Vector3 = AIRoleSlots.slot_anchor(
			AIRoleSlots.Slot.OUTLET, AIPossessionState.State.OZONE,
			puck, Vector3.ZERO, OUR_NET_Z, 1.0)
	assert_almost_eq(anchor.x, puck.x, 0.01, "shadows puck x")
	assert_lt(anchor.z, -GameRules.BLUE_LINE_Z, "in OZ past blue line")


func test_trans_do_outlet_weak_side_blue_line() -> void:
	# In TRANS_DO, OUTLET sits at the weak-side opp blue line on the
	# NZ side. Distance from blue line is TRANS_DO_OUTLET_Z_FROM_BLUE
	# (currently 2.5 m — bumped from 1 m for offside slack).
	var anchor: Vector3 = AIRoleSlots.slot_anchor(
			AIRoleSlots.Slot.OUTLET, AIPossessionState.State.TRANS_DO,
			Vector3(5.0, 0.0, 0.0), Vector3.ZERO, OUR_NET_Z, 1.0)
	assert_lt(anchor.x, 0.0, "weak-side")
	assert_almost_eq(anchor.z,
			-GameRules.BLUE_LINE_Z + AIRoleSlots.TRANS_DO_OUTLET_Z_FROM_BLUE, 0.01,
			"NZ side of opp blue line by TRANS_DO_OUTLET_Z_FROM_BLUE")


func test_trans_od_home_anchor_defensive_slot() -> void:
	var anchor: Vector3 = AIRoleSlots.slot_anchor(
			AIRoleSlots.Slot.HOME, AIPossessionState.State.TRANS_OD,
			Vector3(5.0, 0.0, 0.0), Vector3.ZERO, OUR_NET_Z, 1.0)
	assert_almost_eq(anchor.x, 0.0, 0.01)
	assert_almost_eq(anchor.z, OUR_NET_Z - 5.0, 0.01)


func test_trans_od_cover_back_of_puck_weak_side() -> void:
	# Puck at +x (strong=+1). COVER on weak side, back of puck.
	var anchor: Vector3 = AIRoleSlots.slot_anchor(
			AIRoleSlots.Slot.COVER, AIPossessionState.State.TRANS_OD,
			Vector3(5.0, 0.0, 0.0), Vector3.ZERO, OUR_NET_Z, 1.0)
	assert_lt(anchor.x, 5.0, "weak-side of puck")
	assert_gt(anchor.z, 0.0, "back of puck toward our net")


# ─── assign() ───────────────────────────────────────────────────────────────

func test_assign_dzone_distributes_three_slots() -> void:
	# Puck at (5, 22) → strong=+1.
	var skaters: Array = [
			[100, 0, Vector3(4.5, 0.0, 22.5)],
			[110, 0, Vector3(0.5, 0.0, 25.65)],
			[120, 0, Vector3(-2.0, 0.0, 22.65)],
			[200, 1, Vector3(5.0, 0.0, 22.0)],
	]
	var snap := _make_snapshot(skaters, 200)
	var assignments: Dictionary = AIRoleSlots.assign(
			snap, TEAM_ID, OUR_NET_Z, AIPossessionState.State.DZONE,
			_resolver(skaters), {})
	assert_eq(assignments[100], AIRoleSlots.Slot.PRESSURE)
	assert_eq(assignments[110], AIRoleSlots.Slot.NET)
	assert_eq(assignments[120], AIRoleSlots.Slot.INSIDE)


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


func test_assign_trans_od_home_goes_to_highest_player() -> void:
	# Opp carrier in NZ. Bots: up-ice → HOME (sprints back to slot).
	# Near-puck of remaining → CHASE. Deep → COVER (gets pulled forward
	# by back-of-puck anchor to engage the play instead of camping the
	# slot).
	var skaters: Array = [
			[100, 0, Vector3(0.0, 0.0, -10.0)], # up-ice (caught) → HOME
			[110, 0, Vector3(0.0, 0.0, 1.5)],   # near puck → CHASE
			[120, 0, Vector3(0.0, 0.0, 21.0)],  # deep → COVER
			[200, 1, Vector3(0.0, 0.0, 0.0)],   # opp carrier
	]
	var snap := _make_snapshot(skaters, 200)
	var assignments: Dictionary = AIRoleSlots.assign(
			snap, TEAM_ID, OUR_NET_Z, AIPossessionState.State.TRANS_OD,
			_resolver(skaters), {})
	assert_eq(assignments[100], AIRoleSlots.Slot.HOME,
			"highest-up-ice bot becomes HOME (constantly backchecking)")
	assert_eq(assignments[110], AIRoleSlots.Slot.CHASE,
			"closer-to-puck of remaining becomes CHASE")
	assert_eq(assignments[120], AIRoleSlots.Slot.COVER,
			"deep bot becomes COVER (engages play via back-of-puck anchor)")


func test_assign_hysteresis_keeps_prev_when_close() -> void:
	# Two teammates roughly equally close to two slots — hysteresis
	# keeps the previous assignment.
	var skaters: Array = [
			[100, 0, Vector3(4.0, 0.0, 22.5)],
			[110, 0, Vector3(3.7, 0.0, 22.5)],   # 0.3m closer to PRESSURE
			[120, 0, Vector3(-2.0, 0.0, 22.65)],
			[200, 1, Vector3(5.0, 0.0, 22.0)],
	]
	var snap := _make_snapshot(skaters, 200)
	var prev: Dictionary = {
			100: AIRoleSlots.Slot.PRESSURE,
			110: AIRoleSlots.Slot.INSIDE,
			120: AIRoleSlots.Slot.NET,
	}
	var assignments: Dictionary = AIRoleSlots.assign(
			snap, TEAM_ID, OUR_NET_Z, AIPossessionState.State.DZONE,
			_resolver(skaters), prev)
	assert_eq(assignments[100], AIRoleSlots.Slot.PRESSURE,
			"peer 100 keeps PRESSURE despite peer 110 being marginally closer")


# ─── Mixed-team behavior ────────────────────────────────────────────────────

func test_mixed_team_human_carrier_bots_fill_other_slots() -> void:
	# Human (real peer 1) has the puck → CARRIER. Two bots fill
	# BACKDOOR and OUTLET in OZONE.
	var skaters: Array = [
			[1, 0, Vector3(0.0, 0.0, -22.0)],     # human carrier
			[10000, 0, Vector3(-3.0, 0.0, -25.0)],# bot near BACKDOOR
			[10001, 0, Vector3(0.0, 0.0, -16.0)], # bot near OUTLET
	]
	var snap := _make_snapshot(skaters, 1)
	var assignments: Dictionary = AIRoleSlots.assign(
			snap, TEAM_ID, OUR_NET_Z, AIPossessionState.State.OZONE,
			_resolver(skaters), {})
	assert_eq(assignments[1], AIRoleSlots.Slot.CARRIER)
	assert_true(assignments.has(10000))
	assert_true(assignments.has(10001))
	assert_ne(assignments[10000], assignments[10001], "bots get different slots")
