extends GutTest

# AIZoneCoverage — the 5v5 D-zone geometry (plan §3/§5). Team 0 defends +Z
# (own_goal_z = +26.65); depths are metres off that goal line into the zone.

const NET_Z: float = 26.65


func _pt(x: float, depth: float) -> Vector3:
	# World point at lateral x and depth off the defended (+Z) goal line.
	return Vector3(x, 0.0, NET_Z - depth)


# ── depth_of ─────────────────────────────────────────────────────────────────

func test_depth_measures_off_the_defended_goal_line() -> void:
	assert_almost_eq(AIZoneCoverage.depth_of(NET_Z, _pt(0.0, 0.0)), 0.0, 0.001)
	assert_almost_eq(AIZoneCoverage.depth_of(NET_Z, _pt(0.0, 10.0)), 10.0, 0.001)
	# Behind the goal line reads negative.
	assert_lt(AIZoneCoverage.depth_of(NET_Z, Vector3(0, 0, NET_Z + 2.0)), 0.0)
	# Mirrored net: same answer for team 1's zone.
	assert_almost_eq(AIZoneCoverage.depth_of(-NET_Z, Vector3(0, 0, -NET_Z + 5.0)),
			5.0, 0.001)


# ── pressure ownership: exactly one owner everywhere ─────────────────────────

func test_pressure_owner_by_region() -> void:
	var s: float = 1.0  # strong side = +X
	# Corner battle (strong side low) → strong D.
	assert_eq(AIZoneCoverage.pressure_owner(s, NET_Z, _pt(9.0, 3.0)),
			AIRoleSlots.Slot.ZONE_D_STRONG)
	# Behind the net → strong D (the low perimeter is his battle).
	assert_eq(AIZoneCoverage.pressure_owner(s, NET_Z, _pt(0.0, -1.5)),
			AIRoleSlots.Slot.ZONE_D_STRONG)
	# WEAK-side corner also belongs to the battle D (the strong sign flips
	# with the brain's hysteresis as the puck crosses).
	assert_eq(AIZoneCoverage.pressure_owner(s, NET_Z, _pt(-9.0, 3.0)),
			AIRoleSlots.Slot.ZONE_D_STRONG)
	# Net-front jam → the net-front box D.
	assert_eq(AIZoneCoverage.pressure_owner(s, NET_Z, _pt(0.5, 2.0)),
			AIRoleSlots.Slot.ZONE_D_WEAK)
	# Mid slot → the center.
	assert_eq(AIZoneCoverage.pressure_owner(s, NET_Z, _pt(1.0, 8.5)),
			AIRoleSlots.Slot.ZONE_C)
	# Strong point → strong winger.
	assert_eq(AIZoneCoverage.pressure_owner(s, NET_Z, _pt(7.0, 16.0)),
			AIRoleSlots.Slot.ZONE_W_STRONG)
	# Weak point → weak winger.
	assert_eq(AIZoneCoverage.pressure_owner(s, NET_Z, _pt(-7.0, 16.0)),
			AIRoleSlots.Slot.ZONE_W_WEAK)


func test_pressure_owner_is_unique_across_a_zone_sweep() -> void:
	# Every point in the zone maps to exactly one owner (a total function —
	# the match can't return two, so this asserts it's one of the five
	# and never crashes across the sweep).
	var zone_roles: Array[int] = [
		AIRoleSlots.Slot.ZONE_D_STRONG, AIRoleSlots.Slot.ZONE_D_WEAK,
		AIRoleSlots.Slot.ZONE_C, AIRoleSlots.Slot.ZONE_W_STRONG,
		AIRoleSlots.Slot.ZONE_W_WEAK]
	for xi: int in range(-12, 13, 3):
		for di: int in range(-3, 19, 2):
			var owner: int = AIZoneCoverage.pressure_owner(
					1.0, NET_Z, _pt(float(xi), float(di)))
			assert_has(zone_roles, owner,
					"x=%d depth=%d has no owner" % [xi, di])


func test_every_house_point_is_inside_some_area() -> void:
	# The house (posts → dots → circle tops) must always be someone's
	# responsibility — no dead seam a net-front man can hide in.
	var zone_roles: Array[int] = [
		AIRoleSlots.Slot.ZONE_D_STRONG, AIRoleSlots.Slot.ZONE_D_WEAK,
		AIRoleSlots.Slot.ZONE_C, AIRoleSlots.Slot.ZONE_W_STRONG,
		AIRoleSlots.Slot.ZONE_W_WEAK]
	for xi: int in range(-6, 7, 2):
		for di: int in range(0, 11, 2):
			var p: Vector3 = _pt(float(xi), float(di))
			var covered: bool = false
			for role: int in zone_roles:
				if AIZoneCoverage.in_area(role, 1.0, NET_Z, p):
					covered = true
					break
			assert_true(covered, "house point x=%d depth=%d uncovered" % [xi, di])


# ── Breathing anchors ────────────────────────────────────────────────────────

func test_wingers_collapse_when_the_puck_goes_below_the_goal_line() -> void:
	var puck_low: Vector3 = _pt(8.0, -1.0)     # corner, behind the goal line
	var puck_point: Vector3 = _pt(6.0, 16.0)   # at the point
	var sink: Vector3 = AIZoneCoverage.anchor_of(
			AIRoleSlots.Slot.ZONE_W_STRONG, 1.0, NET_Z, puck_low)
	var extend: Vector3 = AIZoneCoverage.anchor_of(
			AIRoleSlots.Slot.ZONE_W_STRONG, 1.0, NET_Z, puck_point)
	# Collapsed: at the circle top. Extended (point threat): stepped up
	# toward the puck — much further from our net.
	assert_almost_eq(AIZoneCoverage.depth_of(NET_Z, sink),
			AIZoneCoverage.W_STRONG_SINK_DEPTH_M, 0.5)
	assert_gt(AIZoneCoverage.depth_of(NET_Z, extend), 12.0,
			"point threat pulls the strong winger up the lane")


func test_point_threat_anchor_blocks_the_shot_lane() -> void:
	# Puck at the strong point: the winger's anchor must sit ON the
	# puck→net line, SHOT_LANE_STEP_M from the puck.
	var puck: Vector3 = _pt(6.0, 16.0)
	var a: Vector3 = AIZoneCoverage.anchor_of(
			AIRoleSlots.Slot.ZONE_W_STRONG, 1.0, NET_Z, puck)
	var to_net: Vector3 = Vector3(0, 0, NET_Z) - puck
	var expected: Vector3 = puck + to_net.normalized() * AIZoneCoverage.SHOT_LANE_STEP_M
	assert_lt(a.distance_to(expected), 0.1)


func test_weak_winger_sags_into_the_high_slot_when_puck_is_low() -> void:
	var a: Vector3 = AIZoneCoverage.anchor_of(
			AIRoleSlots.Slot.ZONE_W_WEAK, 1.0, NET_Z, _pt(9.0, 1.0))
	# Weak side of center, high-slot depth band.
	assert_lt(a.x, 0.0)
	assert_between(AIZoneCoverage.depth_of(NET_Z, a), 7.5, 10.0)


func test_anchors_mirror_with_strong_side_and_net() -> void:
	# Strong side −X, team 1's net: the geometry mirrors cleanly.
	var a: Vector3 = AIZoneCoverage.anchor_of(
			AIRoleSlots.Slot.ZONE_D_STRONG, -1.0, -NET_Z, Vector3(-8, 0, -20))
	assert_lt(a.x, 0.0, "strong-side anchor follows the strong sign")
	assert_lt(a.z, 0.0, "anchor is in team 1's zone")


# ── Soft-lock man query ──────────────────────────────────────────────────────

func _snapshot_with_men(men: Array) -> WorldSnapshot:
	var snap := WorldSnapshot.new()
	for entry: Array in men:
		var s := SkaterNetworkState.new()
		s.position = entry[1]
		snap.skater_states[entry[0]] = s
	var puck := PuckNetworkState.new()
	puck.position = _pt(9.0, 3.0)
	puck.carrier_peer_id = 100
	snap.puck_state = puck
	return snap


func test_locks_the_most_dangerous_man_in_area() -> void:
	# Two opponents in the net-front box, goalie tracking the corner
	# carrier (strong-side shade): the backdoor man with the open half of
	# the net out-dangers the man parked on the goalie's side.
	var snap: WorldSnapshot = _snapshot_with_men([
		[100, _pt(9.0, 3.0)],    # carrier (excluded)
		[101, _pt(-1.5, 2.0)],   # backdoor — net open to his side
		[102, _pt(2.4, 4.0)],    # goalie-side box edge
	])
	var team_map: Dictionary = {100: 1, 101: 1, 102: 1}
	var goalie_pos: Vector3 = Vector3(0.8, 0.0, NET_Z - 0.6)  # shaded to the carrier
	var man: int = AIZoneCoverage.most_dangerous_man_in_area(
			AIRoleSlots.Slot.ZONE_D_WEAK, 1.0, NET_Z, snap, 0, team_map,
			goalie_pos, 100)
	assert_eq(man, 101)


func test_lock_releases_when_the_man_leaves_the_area() -> void:
	# The incumbent walked out past the box + release margin: the query
	# must let him go (the neighbor's area inherits him).
	var snap: WorldSnapshot = _snapshot_with_men([
		[100, _pt(9.0, 3.0)],
		[101, _pt(0.0, 8.0)],   # left the net-front box for the slot
	])
	var team_map: Dictionary = {100: 1, 101: 1}
	var man: int = AIZoneCoverage.most_dangerous_man_in_area(
			AIRoleSlots.Slot.ZONE_D_WEAK, 1.0, NET_Z, snap, 0, team_map,
			Vector3(0, 0, NET_Z - 1.0), 100, 101)
	assert_eq(man, -1, "boundary release: never chase him out of the box")
	# ...and ZONE_C, whose ice he entered, picks him up.
	var c_man: int = AIZoneCoverage.most_dangerous_man_in_area(
			AIRoleSlots.Slot.ZONE_C, 1.0, NET_Z, snap, 0, team_map,
			Vector3(0, 0, NET_Z - 1.0), 100)
	assert_eq(c_man, 101)


func test_incumbent_held_just_past_the_edge() -> void:
	# A man half a metre past the box edge: a fresh query ignores him, but
	# the incumbent margin keeps the lock alive (no seam flicker).
	var edge_pos: Vector3 = _pt(NET_FRONT_EDGE_X + 0.5, 2.0)
	var snap: WorldSnapshot = _snapshot_with_men([
		[100, _pt(9.0, 3.0)],
		[101, edge_pos],
	])
	var team_map: Dictionary = {100: 1, 101: 1}
	var fresh: int = AIZoneCoverage.most_dangerous_man_in_area(
			AIRoleSlots.Slot.ZONE_D_WEAK, 1.0, NET_Z, snap, 0, team_map,
			Vector3(0, 0, NET_Z - 1.0), 100)
	assert_eq(fresh, -1)
	var held: int = AIZoneCoverage.most_dangerous_man_in_area(
			AIRoleSlots.Slot.ZONE_D_WEAK, 1.0, NET_Z, snap, 0, team_map,
			Vector3(0, 0, NET_Z - 1.0), 100, 101)
	assert_eq(held, 101)

const NET_FRONT_EDGE_X: float = 2.6  # AIZoneCoverage.NET_FRONT_HALF_WIDTH_M


# ── Defensive-responsibility anchor ──────────────────────────────────────────

func test_defensive_anchor_geometry() -> void:
	var ld: Vector3 = AIZoneCoverage.defensive_anchor(true, -1.0, NET_Z)
	assert_lt(ld.x, 0.0, "LD's post is on the left")
	assert_almost_eq(ld.z, GameRules.BLUE_LINE_Z, 0.001)
	var fwd: Vector3 = AIZoneCoverage.defensive_anchor(false, 0.0, NET_Z)
	assert_lt(fwd.z, ld.z, "a forward's post is up-ice of the D's")
