extends GutTest

# AIRoleChase — NEUTRAL only. Trivial: target = puck position.
# The state machine takes over puck retrieval via CHASE_PUCK once
# the bot is closest.

const TEAM_ID: int = 0
const OUR_NET_Z: float = 26.65


func _make_ctx(self_pos: Vector3, puck_pos: Vector3) -> RoleContext:
	var snap := WorldSnapshot.new()
	var s := SkaterNetworkState.new()
	s.position = self_pos
	snap.skater_states[1] = s
	var puck := PuckNetworkState.new()
	puck.carrier_peer_id = -1
	puck.position = puck_pos
	snap.puck_state = puck

	var ctx := RoleContext.new()
	ctx.snapshot = snap
	ctx.self_pos = self_pos
	ctx.team_id = TEAM_ID
	ctx.peer_id = 1
	ctx.attacking_goal_pos = Vector3(0.0, 0.0, -OUR_NET_Z)
	ctx.defending_goal_pos = Vector3(0.0, 0.0, OUR_NET_Z)
	ctx.own_goal_dir = 1.0
	ctx.team_id_by_peer = {1: TEAM_ID}
	return ctx


func test_target_is_puck_position() -> void:
	var puck_pos := Vector3(2, 0, -3)
	var ctx: RoleContext = _make_ctx(Vector3(8, 0, 0), puck_pos)
	var d: RoleDecision = AIRoleChase.decide(ctx)
	assert_eq(d.target_position, puck_pos,
			"CHASE target is the puck position")


func test_falls_back_to_self_pos_when_no_puck_state() -> void:
	var self_pos := Vector3(8, 0, 0)
	var ctx: RoleContext = _make_ctx(self_pos, Vector3.ZERO)
	ctx.snapshot.puck_state = null
	var d: RoleDecision = AIRoleChase.decide(ctx)
	assert_eq(d.target_position, self_pos,
			"null puck_state → fall back to self_pos")


# ── Lost race → pre-contain, don't push ──────────────────────────────────────

func test_lost_race_retreats_to_the_pre_contain_point() -> void:
	# Missed pass running away up-ice: an opponent is right on the puck while
	# we're 12 m behind the race. Pushing is skating out of the play — the
	# chaser retreats to CONTAIN's gap point on the imminent pickup instead,
	# so the TRANS_OD structure is already standing when possession flips.
	var puck_pos := Vector3(0, 0, -14)          # up-ice (we defend +Z)
	var self_pos := Vector3(0, 0, -2)
	var ctx: RoleContext = _make_ctx(self_pos, puck_pos)
	var opp := SkaterNetworkState.new()
	opp.position = Vector3(1, 0, -14.5)         # on the puck
	ctx.snapshot.skater_states[200] = opp
	ctx.team_id_by_peer[200] = 1
	var d: RoleDecision = AIRoleChase.decide(ctx)
	assert_gt(d.target_position.z, puck_pos.z + AIRoleContain.GAP_MIN_M - 0.01,
			"lost race → the target is goal-side of the pickup, not the puck;"
			+ " got %s" % str(d.target_position))


func test_contested_race_still_chases() -> void:
	# Opponent equidistant — inside the contest band. The race is live; the
	# drive-through contest machinery wants the chaser IN it.
	var puck_pos := Vector3(0, 0, -8)
	var self_pos := Vector3(0, 0, -4)
	var ctx: RoleContext = _make_ctx(self_pos, puck_pos)
	var opp := SkaterNetworkState.new()
	opp.position = Vector3(0, 0, -12)           # mirrored, same 4 m
	ctx.snapshot.skater_states[200] = opp
	ctx.team_id_by_peer[200] = 1
	var d: RoleDecision = AIRoleChase.decide(ctx)
	assert_eq(d.target_position, puck_pos,
			"a live 50/50 still races the puck")
