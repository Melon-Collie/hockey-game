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
	ctx.team_id_resolver = func(pid: int) -> int: return TEAM_ID if pid == 1 else 1
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
