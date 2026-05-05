extends GutTest

# AIRoleSlots is pure-function. Tests cover slot lists per state,
# anchor formulas, sprint-by picking, slot assignment with
# permutation enumeration + hysteresis, and graduate detection.

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
	assert_true(slots.has(AIRoleSlots.Slot.SPRINT_BY))
	assert_true(slots.has(AIRoleSlots.Slot.SUPPORT))


func test_slots_for_trans_od() -> void:
	var slots: Array = AIRoleSlots.slots_for_state(AIPossessionState.State.TRANS_OD)
	assert_true(slots.has(AIRoleSlots.Slot.SPRINT_BY))
	assert_true(slots.has(AIRoleSlots.Slot.F1))
	assert_true(slots.has(AIRoleSlots.Slot.F2))


func test_slots_for_neutral() -> void:
	var slots: Array = AIRoleSlots.slots_for_state(AIPossessionState.State.NEUTRAL)
	assert_true(slots.has(AIRoleSlots.Slot.CHASE))
	assert_true(slots.has(AIRoleSlots.Slot.FLANK_L))
	assert_true(slots.has(AIRoleSlots.Slot.FLANK_R))


# ─── Slot anchors ───────────────────────────────────────────────────────────

func test_dzone_pressure_anchor_is_goal_side_of_puck() -> void:
	# Team 0, puck at (5, 22), our_net at (0, 26.65). PRESSURE sits 1.5m
	# along the puck→net line.
	var puck := Vector3(5.0, 0.0, 22.0)
	var anchor: Vector3 = AIRoleSlots.slot_anchor(
			AIRoleSlots.Slot.PRESSURE, AIPossessionState.State.DZONE,
			puck, puck, Vector3.ZERO, OUR_NET_Z, 1.0)
	# Anchor is between puck and net, 1.5m from puck.
	assert_lt(anchor.x, puck.x, "anchor X moves toward 0 (net center)")
	assert_gt(anchor.z, puck.z, "anchor Z moves toward our net (+Z)")
	var dist: float = puck.distance_to(anchor)
	assert_almost_eq(dist, 1.5, 0.01)


func test_dzone_net_anchor_strong_side_post() -> void:
	var anchor: Vector3 = AIRoleSlots.slot_anchor(
			AIRoleSlots.Slot.NET, AIPossessionState.State.DZONE,
			Vector3(5.0, 0.0, 22.0), Vector3.ZERO, Vector3.ZERO,
			OUR_NET_Z, 1.0)
	assert_gt(anchor.x, 0.0, "strong-side post (puck on +x)")
	assert_lt(anchor.x, GameRules.NET_HALF_WIDTH, "inside the post")
	# 1m in front of goal line, so at z = 25.65
	assert_almost_eq(anchor.z, OUR_NET_Z - 1.0, 0.01)


func test_dzone_inside_anchor_weak_side_slot() -> void:
	var anchor: Vector3 = AIRoleSlots.slot_anchor(
			AIRoleSlots.Slot.INSIDE, AIPossessionState.State.DZONE,
			Vector3(5.0, 0.0, 22.0), Vector3.ZERO, Vector3.ZERO,
			OUR_NET_Z, 1.0)
	assert_lt(anchor.x, 0.0, "weak-side (opposite puck)")
	# 4m in front of goal line — slot depth.
	assert_almost_eq(anchor.z, OUR_NET_Z - 4.0, 0.01)


func test_ozone_backdoor_weak_side_post() -> void:
	# Team 0 attacks -Z. Strong puck at +x, BACKDOOR at -x post in front
	# of opp goal (z negative).
	var anchor: Vector3 = AIRoleSlots.slot_anchor(
			AIRoleSlots.Slot.BACKDOOR, AIPossessionState.State.OZONE,
			Vector3(5.0, 0.0, -22.0), Vector3.ZERO, Vector3.ZERO,
			OUR_NET_Z, 1.0)
	assert_lt(anchor.x, 0.0, "weak-side post")
	assert_lt(anchor.z, 0.0, "in opp DZ")


func test_ozone_outlet_high_shadowing_puck_x() -> void:
	var puck := Vector3(5.0, 0.0, -22.0)
	var anchor: Vector3 = AIRoleSlots.slot_anchor(
			AIRoleSlots.Slot.OUTLET, AIPossessionState.State.OZONE,
			puck, Vector3.ZERO, Vector3.ZERO, OUR_NET_Z, 1.0)
	assert_almost_eq(anchor.x, puck.x, 0.01, "shadows puck x")
	# Z is 2m past opp blue line into OZ, opp blue line at z=-14.65.
	assert_lt(anchor.z, -GameRules.BLUE_LINE_Z, "in OZ past blue line")


func test_trans_do_sprint_by_target_weak_side_blue_line() -> void:
	var target: Vector3 = AIRoleSlots.compute_sprint_by_target(
			AIPossessionState.State.TRANS_DO,
			Vector3(5.0, 0.0, 0.0), OUR_NET_Z, 1.0)
	assert_lt(target.x, 0.0, "weak-side (opposite puck)")
	# 1m on NZ side of opp blue line.
	assert_almost_eq(target.z, -GameRules.BLUE_LINE_Z + 1.0, 0.01)


func test_trans_od_sprint_by_target_defensive_slot() -> void:
	var target: Vector3 = AIRoleSlots.compute_sprint_by_target(
			AIPossessionState.State.TRANS_OD,
			Vector3(5.0, 0.0, 0.0), OUR_NET_Z, 1.0)
	assert_almost_eq(target.x, 0.0, 0.01, "centered (no side bias)")
	# 5m in front of own goal line.
	assert_almost_eq(target.z, OUR_NET_Z - 5.0, 0.01)


# ─── pick_sprint_by_peer ────────────────────────────────────────────────────

func test_pick_sprint_by_trans_od_furthest_from_own_net() -> void:
	# TRANS_OD: pick teammate furthest from own net (deepest forward).
	# Team 0's own net is at +z; deepest forward = most negative z.
	var skaters: Array = [
			[100, 0, Vector3(0.0, 0.0, 5.0)],   # near our blue line
			[110, 0, Vector3(0.0, 0.0, -10.0)], # deep forward
			[120, 0, Vector3(0.0, 0.0, 15.0)],  # in our DZ
			[200, 1, Vector3(0.0, 0.0, 0.0)],   # opp carrier
	]
	var snap := _make_snapshot(skaters, 200)
	var pid: int = AIRoleSlots.pick_sprint_by_peer(
			AIPossessionState.State.TRANS_OD, snap, TEAM_ID, OUR_NET_Z,
			_resolver(skaters))
	assert_eq(pid, 110, "teammate at z=-10 is furthest from own net")


func test_pick_sprint_by_trans_do_furthest_from_opp_net() -> void:
	# TRANS_DO: pick teammate furthest from opp net (deepest defender).
	# Opp net at -z; deepest = most positive z. Carrier excluded.
	var skaters: Array = [
			[100, 0, Vector3(0.0, 0.0, 0.0)],   # carrier
			[110, 0, Vector3(0.0, 0.0, 15.0)],  # deep defender
			[120, 0, Vector3(0.0, 0.0, 5.0)],   # mid
	]
	var snap := _make_snapshot(skaters, 100)
	var pid: int = AIRoleSlots.pick_sprint_by_peer(
			AIPossessionState.State.TRANS_DO, snap, TEAM_ID, OUR_NET_Z,
			_resolver(skaters))
	assert_eq(pid, 110, "teammate at z=15 is furthest from opp net (carrier excluded)")


# ─── assign() ───────────────────────────────────────────────────────────────

func test_assign_dzone_distributes_three_slots() -> void:
	# DZONE: 3 slots (PRESSURE, NET, INSIDE) for 3 teammates by closest
	# position. Puck at (5, 22) → strong_x = +1.
	var skaters: Array = [
			[100, 0, Vector3(4.5, 0.0, 22.5)],  # closest to PRESSURE anchor
			[110, 0, Vector3(0.5, 0.0, 25.65)], # closest to NET (strong-side post @ 0.6)
			[120, 0, Vector3(-2.0, 0.0, 22.65)],# closest to INSIDE
			[200, 1, Vector3(5.0, 0.0, 22.0)],  # opp carrier
	]
	var snap := _make_snapshot(skaters, 200)
	var assignments: Dictionary = AIRoleSlots.assign(
			snap, TEAM_ID, OUR_NET_Z, AIPossessionState.State.DZONE,
			_resolver(skaters), {}, 0, Vector3.ZERO)
	assert_eq(assignments[100], AIRoleSlots.Slot.PRESSURE)
	assert_eq(assignments[110], AIRoleSlots.Slot.NET)
	assert_eq(assignments[120], AIRoleSlots.Slot.INSIDE)


func test_assign_ozone_carrier_is_fixed() -> void:
	# OZONE: peer with the puck is CARRIER regardless of geometry.
	var skaters: Array = [
			[100, 0, Vector3(0.0, 0.0, -22.0)], # the carrier
			[110, 0, Vector3(-3.0, 0.0, -25.0)],# closer to BACKDOOR
			[120, 0, Vector3(0.0, 0.0, -16.0)], # near OUTLET (high)
	]
	var snap := _make_snapshot(skaters, 100)
	var assignments: Dictionary = AIRoleSlots.assign(
			snap, TEAM_ID, OUR_NET_Z, AIPossessionState.State.OZONE,
			_resolver(skaters), {}, 0, Vector3.ZERO)
	assert_eq(assignments[100], AIRoleSlots.Slot.CARRIER)
	# 110 and 120 fill BACKDOOR / OUTLET via permutation.
	assert_true(assignments.has(110))
	assert_true(assignments.has(120))


func test_assign_sprint_by_locked_to_passed_in_peer() -> void:
	# TRANS_OD: SPRINT_BY pre-locked to peer 110, others fill F1/F2.
	var skaters: Array = [
			[100, 0, Vector3(0.0, 0.0, 5.0)],
			[110, 0, Vector3(0.0, 0.0, -10.0)],  # the sprinter
			[120, 0, Vector3(0.0, 0.0, 15.0)],
			[200, 1, Vector3(2.0, 0.0, 5.0)],
	]
	var snap := _make_snapshot(skaters, 200)
	var sprint_target := Vector3(0.0, 0.0, OUR_NET_Z - 5.0)
	var assignments: Dictionary = AIRoleSlots.assign(
			snap, TEAM_ID, OUR_NET_Z, AIPossessionState.State.TRANS_OD,
			_resolver(skaters), {}, 110, sprint_target)
	assert_eq(assignments[110], AIRoleSlots.Slot.SPRINT_BY)


func test_assign_hysteresis_keeps_prev_when_close() -> void:
	# Two teammates roughly equally close to two slots. Prev assignment
	# was (peer 100 → PRESSURE, peer 110 → INSIDE). Even with peer 110
	# slightly closer to PRESSURE this tick, hysteresis keeps the
	# previous assignment.
	# Use a setup where peer 110 is ~0.3m closer to PRESSURE than peer 100.
	# HYSTERESIS_PENALTY (1.5m) >> 0.3m, so swap is rejected.
	var skaters: Array = [
			[100, 0, Vector3(4.0, 0.0, 22.5)],   # near PRESSURE anchor
			[110, 0, Vector3(3.7, 0.0, 22.5)],   # 0.3m closer
			[120, 0, Vector3(-2.0, 0.0, 22.65)], # near INSIDE
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
			_resolver(skaters), prev, 0, Vector3.ZERO)
	# Hysteresis should keep peer 100 in PRESSURE since the swap saves
	# only 0.3m but costs 2 × 1.5m hysteresis penalty.
	assert_eq(assignments[100], AIRoleSlots.Slot.PRESSURE,
			"peer 100 keeps PRESSURE despite peer 110 being marginally closer")


# ─── Sprint-by graduation ───────────────────────────────────────────────────

func test_sprint_by_graduates_when_within_two_meters() -> void:
	var skaters: Array = [[110, 0, Vector3(0.0, 0.0, 21.5)]]
	var snap := _make_snapshot(skaters)
	var target := Vector3(0.0, 0.0, OUR_NET_Z - 5.0)  # = 21.65
	# peer at 21.5 is 0.15m from target — well under 2m graduate dist.
	assert_true(AIRoleSlots.sprint_by_should_graduate(110, target, snap))


func test_sprint_by_does_not_graduate_when_far() -> void:
	var skaters: Array = [[110, 0, Vector3(0.0, 0.0, -10.0)]]
	var snap := _make_snapshot(skaters)
	var target := Vector3(0.0, 0.0, OUR_NET_Z - 5.0)
	assert_false(AIRoleSlots.sprint_by_should_graduate(110, target, snap))
