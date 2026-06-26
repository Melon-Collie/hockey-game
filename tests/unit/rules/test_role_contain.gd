extends GutTest

# AIRoleContain — TRANS_OD-only last man back: gap control on the carrier.
# Target is goal-side of the carrier on the carrier→our-net line, at a gap
# that tightens as the carrier nears the net. Tests cover:
#   - Loose puck → contain its spot (don't freeze).
#   - Target is goal-side of the carrier (between carrier and our net).
#   - Gap tightens as the carrier closes on the net.
#   - Never retreats behind our own goal line.

const TEAM_ID: int = 0
const OUR_NET_Z: float = 26.65


func _make_ctx(self_pos: Vector3, skaters: Array = [],
		carrier_pid: int = -1) -> RoleContext:
	var snap := WorldSnapshot.new()
	if skaters.is_empty():
		var s := SkaterNetworkState.new()
		s.position = self_pos
		snap.skater_states[1] = s
	else:
		for entry: Array in skaters:
			var sk := SkaterNetworkState.new()
			sk.position = entry[2]
			sk.velocity = entry[3] if entry.size() > 3 else Vector3.ZERO
			snap.skater_states[entry[0]] = sk
	var puck := PuckNetworkState.new()
	puck.carrier_peer_id = carrier_pid
	if carrier_pid != -1:
		for entry: Array in skaters:
			if entry[0] == carrier_pid:
				puck.position = entry[2]
				break
	else:
		puck.position = Vector3.ZERO
	snap.puck_state = puck

	var team_map: Dictionary = {1: TEAM_ID}
	if not skaters.is_empty():
		team_map.clear()
		for entry: Array in skaters:
			team_map[entry[0]] = entry[1]

	var ctx := RoleContext.new()
	ctx.snapshot = snap
	ctx.self_pos = self_pos
	ctx.team_id = TEAM_ID
	ctx.peer_id = 1
	ctx.attacking_goal_pos = Vector3(0.0, 0.0, -OUR_NET_Z)
	ctx.defending_goal_pos = Vector3(0.0, 0.0, OUR_NET_Z)
	ctx.own_goal_dir = 1.0
	ctx.team_id_by_peer = team_map
	return ctx


# ── Loose puck: contain its spot, don't freeze ─────────────────────────────

func test_contains_loose_puck_instead_of_freezing() -> void:
	# Loose puck at origin — CONTAIN holds a gap goal-side of the puck spot
	# (toward our +Z net), not self_pos.
	var self_pos := Vector3(0, 0, -6)   # up-ice (offensive side)
	var ctx: RoleContext = _make_ctx(self_pos)   # loose puck at origin
	var d: RoleDecision = AIRoleContain.decide(ctx)
	assert_ne(d.target_position, self_pos,
			"loose puck → hold a gap toward our net, don't freeze")
	assert_gt(d.target_position.z, 0.0,
			"target is goal-side (+Z) of the loose puck; got z=%f" % d.target_position.z)


# ── Gap control geometry ───────────────────────────────────────────────────

func test_target_is_goal_side_of_carrier_on_net_line() -> void:
	# Carrier in NZ at z=0; our net at +26.65. The gap target sits goal-side
	# of the carrier (between carrier and net), on the carrier→net line (x≈0).
	var carrier_pos := Vector3(0, 0, 0)
	var skaters: Array = [
		[1, TEAM_ID, Vector3(0, 0, 18), Vector3.ZERO],   # us, deep
		[200, 1 - TEAM_ID, carrier_pos, Vector3.ZERO],
	]
	var ctx: RoleContext = _make_ctx(Vector3(0, 0, 18), skaters, 200)
	var d: RoleDecision = AIRoleContain.decide(ctx)
	assert_gt(d.target_position.z, carrier_pos.z,
			"target is goal-side of carrier; got z=%f" % d.target_position.z)
	assert_lt(d.target_position.z, OUR_NET_Z,
			"target stays in front of the net; got z=%f" % d.target_position.z)
	assert_almost_eq(d.target_position.x, 0.0, 0.01,
			"target sits on the carrier→net line; got x=%f" % d.target_position.x)


func test_gap_tightens_as_carrier_nears_net() -> void:
	# Far carrier → loose gap (stand off); near carrier → tight gap (on him).
	var far_carrier := Vector3(0, 0, 0)
	var near_carrier := Vector3(0, 0, 24)
	var far_skaters: Array = [
		[1, TEAM_ID, Vector3(0, 0, 18), Vector3.ZERO],
		[200, 1 - TEAM_ID, far_carrier, Vector3.ZERO],
	]
	var near_skaters: Array = [
		[1, TEAM_ID, Vector3(0, 0, 22), Vector3.ZERO],
		[200, 1 - TEAM_ID, near_carrier, Vector3.ZERO],
	]
	var far_t: Vector3 = AIRoleContain.decide(_make_ctx(Vector3(0, 0, 18), far_skaters, 200)).target_position
	var near_t: Vector3 = AIRoleContain.decide(_make_ctx(Vector3(0, 0, 22), near_skaters, 200)).target_position
	var far_gap: float = far_carrier.distance_to(far_t)
	var near_gap: float = near_carrier.distance_to(near_t)
	assert_lt(near_gap, far_gap,
			"gap tightens as the carrier nears the net; near=%f far=%f" % [near_gap, far_gap])


func test_never_retreats_behind_goal_line() -> void:
	# Even with the carrier right at the net mouth, the gap target stays in
	# front of (not past) our goal line.
	var carrier_pos := Vector3(0, 0, 25.5)
	var skaters: Array = [
		[1, TEAM_ID, Vector3(0, 0, 24), Vector3.ZERO],
		[200, 1 - TEAM_ID, carrier_pos, Vector3.ZERO],
	]
	var d: RoleDecision = AIRoleContain.decide(_make_ctx(Vector3(0, 0, 24), skaters, 200))
	assert_lt(d.target_position.z, OUR_NET_Z + 0.01,
			"never projects behind our goal line; got z=%f" % d.target_position.z)
