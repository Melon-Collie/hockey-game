extends GutTest

# AIRoleOutlet's decide() is the SUPPORT structure minus the
# exposure factor, plus an offside filter. Tests cover the
# OUTLET-specific behavior:
#   - Bail-out cases (no carrier / opp carrier).
#   - Argmax produces a legal pick.
#   - Anti-crowding filter respected.
#   - Offside filter rejects OZ candidates (past opp blue line).
#
# The geometric guts (score_pass) are covered in test_ai_action_scoring.

const TEAM_ID: int = 0
const OUR_NET_Z: float = 26.65   # Team 0 defends +Z, attacks -Z
const OPP_NET_Z: float = -OUR_NET_Z


func _make_ctx(self_pos: Vector3, anchor: Vector3, carrier_pid: int = -1,
		skaters: Array = []) -> RoleContext:
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
	ctx.attacking_goal_pos = Vector3(0.0, 0.0, OPP_NET_Z)
	ctx.defending_goal_pos = Vector3(0.0, 0.0, OUR_NET_Z)
	ctx.own_goal_dir = 1.0
	ctx.anchor = anchor
	ctx.team_id_resolver = func(pid: int) -> int: return int(team_map.get(pid, -1))
	return ctx


# ── Bail-outs ───────────────────────────────────────────────────────────────

func test_falls_back_to_anchor_when_no_carrier() -> void:
	var anchor := Vector3(-4, 0, -GameRules.BLUE_LINE_Z + 2.5)
	var ctx: RoleContext = _make_ctx(Vector3(-4, 0, -10), anchor)
	var d: RoleDecision = AIRoleOutlet.decide(ctx)
	assert_eq(d.target_position, anchor,
			"no carrier → fall back to anchor")


func test_falls_back_to_anchor_when_opp_has_puck() -> void:
	var anchor := Vector3(-4, 0, -GameRules.BLUE_LINE_Z + 2.5)
	var skaters: Array = [
		[1, TEAM_ID, anchor, Vector3.ZERO],
		[200, 1 - TEAM_ID, Vector3(0, 0, 0), Vector3.ZERO],
	]
	var ctx: RoleContext = _make_ctx(anchor, anchor, 200, skaters)
	var d: RoleDecision = AIRoleOutlet.decide(ctx)
	assert_eq(d.target_position, anchor,
			"opp carrier → no offensive context, fall back to anchor")


# ── Argmax pick is legal and NZ-side ────────────────────────────────────────

func test_returns_legal_position_with_teammate_carrier() -> void:
	# TRANS_DO setup: carrier in NZ, OUTLET at weak-side blue line.
	var anchor := Vector3(-4, 0, -GameRules.BLUE_LINE_Z + 2.5)
	var carrier_pos := Vector3(0, 0, 0)
	var skaters: Array = [
		[1, TEAM_ID, anchor, Vector3.ZERO],
		[100, TEAM_ID, carrier_pos, Vector3.ZERO],
	]
	var ctx: RoleContext = _make_ctx(anchor, anchor, 100, skaters)
	var d: RoleDecision = AIRoleOutlet.decide(ctx)
	assert_true(absf(d.target_position.x) <= GameRules.RINK_HALF_WIDTH,
			"x within rink bounds")
	assert_true(absf(d.target_position.z) <= GameRules.GOAL_LINE_Z,
			"z within goal-line bounds")


# ── Offside filter ──────────────────────────────────────────────────────────

func test_offside_filter_rejects_oz_candidates() -> void:
	# Team 0: opp blue line at z = -BLUE_LINE_Z. NZ-side requires
	# z > -BLUE_LINE_Z. OUTLET anchor sits 2.5m NZ-side of the line
	# (z = -BLUE_LINE_Z + 2.5). Polar samples at SEARCH_STEP_M = 3m
	# in the -Z direction would be at z = -BLUE_LINE_Z - 0.5 — past
	# the line, in OZ. Those must be filtered.
	#
	# Verify the chosen target.z is NZ-side (z > -BLUE_LINE_Z).
	var anchor := Vector3(-4, 0, -GameRules.BLUE_LINE_Z + 2.5)
	var carrier_pos := Vector3(0, 0, 0)
	var skaters: Array = [
		[1, TEAM_ID, anchor, Vector3.ZERO],
		[100, TEAM_ID, carrier_pos, Vector3.ZERO],
	]
	var ctx: RoleContext = _make_ctx(anchor, anchor, 100, skaters)
	var d: RoleDecision = AIRoleOutlet.decide(ctx)
	assert_gt(d.target_position.z, -GameRules.BLUE_LINE_Z,
			"OUTLET stays NZ-side of opp blue line; got %s" % d.target_position)


# ── Anti-crowding ───────────────────────────────────────────────────────────

func test_anti_crowding_avoids_candidates_near_teammates() -> void:
	# Anchor and a teammate sitting on top of each other. SUPPORT
	# polar samples around the anchor get filtered by anti-crowd;
	# the chosen position must be at least ANTI_CROWD_RADIUS_M from
	# the squatting teammate.
	var anchor := Vector3(-4, 0, -GameRules.BLUE_LINE_Z + 2.5)
	var teammate_at_anchor := anchor
	var skaters: Array = [
		[1, TEAM_ID, Vector3(8, 0, -5), Vector3.ZERO],     # us, off to the side
		[100, TEAM_ID, Vector3(0, 0, 0), Vector3.ZERO],    # carrier
		[110, TEAM_ID, teammate_at_anchor, Vector3.ZERO],  # blocking the anchor
	]
	var ctx: RoleContext = _make_ctx(Vector3(8, 0, -5), anchor, 100, skaters)
	var d: RoleDecision = AIRoleOutlet.decide(ctx)
	var dist_to_teammate: float = d.target_position.distance_to(teammate_at_anchor)
	assert_gt(dist_to_teammate, AIRoleOutlet.ANTI_CROWD_RADIUS_M - 0.01,
			"chosen target must clear the anti-crowd radius around the teammate")
