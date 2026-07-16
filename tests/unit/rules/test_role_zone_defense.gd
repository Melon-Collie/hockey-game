extends GutTest

# AIRoleZoneDefense — the 5v5 DZONE hybrid-zone behavior (plan §3). Team 0
# defends +Z; peer 1 is the defender under test, team 1 attacks.

const TEAM_ID: int = 0
const NET_Z: float = 26.65


func _pt(x: float, depth: float) -> Vector3:
	return Vector3(x, 0.0, NET_Z - depth)


func _make_ctx(self_pos: Vector3, skaters: Array, carrier_pid: int,
		strong_x: float = 1.0) -> RoleContext:
	var snap := WorldSnapshot.new()
	var have_self: bool = false
	for entry: Array in skaters:
		if entry[0] == 1:
			have_self = true
	if not have_self:
		var s := SkaterNetworkState.new()
		s.position = self_pos
		snap.skater_states[1] = s
	for entry: Array in skaters:
		var sk := SkaterNetworkState.new()
		sk.position = entry[2]
		sk.velocity = entry[3] if entry.size() > 3 else Vector3.ZERO
		snap.skater_states[entry[0]] = sk
	var puck := PuckNetworkState.new()
	puck.carrier_peer_id = carrier_pid
	if carrier_pid != -1 and snap.skater_states.has(carrier_pid):
		puck.position = snap.skater_states[carrier_pid].position
	snap.puck_state = puck

	var team_map: Dictionary = {1: TEAM_ID}
	for entry: Array in skaters:
		team_map[entry[0]] = entry[1]

	var ctx := RoleContext.new()
	ctx.snapshot = snap
	ctx.self_pos = self_pos
	ctx.team_id = TEAM_ID
	ctx.peer_id = 1
	ctx.attacking_goal_pos = Vector3(0.0, 0.0, -NET_Z)
	ctx.defending_goal_pos = Vector3(0.0, 0.0, NET_Z)
	ctx.own_goal_dir = 1.0
	ctx.team_id_by_peer = team_map
	ctx.strong_x = strong_x
	ctx.team_size = 5
	return ctx


func test_area_owner_pressures_the_carrier_in_its_ice() -> void:
	# Opp carrier battling in the strong corner: ZONE_D_STRONG owns that ice
	# — his decision must drive AT the carrier (the pressure path), not to a
	# rest anchor.
	var carrier_pos: Vector3 = _pt(9.0, 3.0)
	var ctx: RoleContext = _make_ctx(_pt(2.0, 3.0),
			[[10, 1, carrier_pos]], 10)
	var d: RoleDecision = AIRoleZoneDefense.decide(ctx, AIRoleSlots.Slot.ZONE_D_STRONG)
	assert_lt(d.target_position.distance_to(carrier_pos), 4.0,
			"the area owner engages the carrier")


func test_non_owner_holds_shape_instead_of_chasing() -> void:
	# Same corner carrier: the weak-side D must NOT chase — he fronts the
	# net (his breathing anchor), the classic no-double-commit rule.
	var carrier_pos: Vector3 = _pt(9.0, 3.0)
	var ctx: RoleContext = _make_ctx(_pt(-1.0, 2.0),
			[[10, 1, carrier_pos]], 10)
	var d: RoleDecision = AIRoleZoneDefense.decide(ctx, AIRoleSlots.Slot.ZONE_D_WEAK)
	assert_gt(d.target_position.distance_to(carrier_pos), 6.0,
			"the far-side D never chases the corner battle")
	assert_lt(AIZoneCoverage.depth_of(NET_Z, d.target_position), 4.0,
			"he holds the net front")


func test_soft_lock_covers_the_backdoor_man() -> void:
	# Corner carrier + a backdoor man in the net-front box: the weak D locks
	# him, goal-side (deeper than the man, toward our net).
	var man_pos: Vector3 = _pt(-1.5, 2.5)
	var ctx: RoleContext = _make_ctx(_pt(-1.0, 2.0), [
			[10, 1, _pt(9.0, 3.0)],
			[11, 1, man_pos],
	], 10)
	var d: RoleDecision = AIRoleZoneDefense.decide(ctx, AIRoleSlots.Slot.ZONE_D_WEAK)
	assert_eq(d.locked_man_pid, 11, "the box man is the lock")
	assert_lt(d.target_position.distance_to(man_pos), 4.0,
			"the cover sits on the man")


func test_winger_extends_to_the_point_when_the_puck_goes_high() -> void:
	# Carrier walks to the strong point: the strong winger's area owns that
	# ice and he steps up at the shot lane.
	var point_pos: Vector3 = _pt(6.0, 16.0)
	var ctx: RoleContext = _make_ctx(_pt(8.5, 9.5),
			[[10, 1, point_pos]], 10)
	var d: RoleDecision = AIRoleZoneDefense.decide(ctx, AIRoleSlots.Slot.ZONE_W_STRONG)
	assert_lt(d.target_position.distance_to(point_pos), 5.0,
			"the strong winger takes the point threat")


func test_center_insures_the_seam() -> void:
	# Corner carrier + a seam-cutter in the mid slot ("too high for the D,
	# too low for the winger"): ZONE_C picks him up.
	var cutter_pos: Vector3 = _pt(0.0, 7.0)
	var ctx: RoleContext = _make_ctx(_pt(1.5, 5.5), [
			[10, 1, _pt(9.0, 3.0)],
			[11, 1, cutter_pos],
	], 10)
	var d: RoleDecision = AIRoleZoneDefense.decide(ctx, AIRoleSlots.Slot.ZONE_C)
	assert_eq(d.locked_man_pid, 11)


func test_lock_releases_at_the_boundary_and_reverts_to_shape() -> void:
	# The previously-locked man has left ZONE_C's ice for the wall: the
	# center releases (no lock in the decision) and breathes on his anchor.
	var ctx: RoleContext = _make_ctx(_pt(1.5, 5.5), [
			[10, 1, _pt(9.0, 3.0)],
			[11, 1, _pt(10.0, 9.0)],   # gone to the strong wall
	], 10)
	ctx.prev_locked_man = 11
	var d: RoleDecision = AIRoleZoneDefense.decide(ctx, AIRoleSlots.Slot.ZONE_C)
	assert_eq(d.locked_man_pid, -1, "release at the boundary — don't chase")
	var anchor: Vector3 = AIZoneCoverage.anchor_of(
			AIRoleSlots.Slot.ZONE_C, 1.0, NET_Z, _pt(9.0, 3.0))
	assert_lt(d.target_position.distance_to(anchor), 3.0,
			"revert to the breathing anchor")
