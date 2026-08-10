extends GutTest

# AIRoleChase — NEUTRAL only. The whole role is the shared "go get the puck"
# verb (AIRoleHelpers.chase_puck): race it, or hold the pre-contain stand when
# an opponent has already won it. The state machine takes over actual retrieval
# via CHASE_PUCK once the bot is closest.

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
	# chaser retreats to the RUSH GAP LADDER's point on the imminent pickup
	# instead (the same formula RUSH_D1 holds — AIRoleRushD.ladder_gap_m), so the
	# TRANS_DEFENSE structure is already standing when possession flips.
	var puck_pos := Vector3(0, 0, -14)          # up-ice (we defend +Z)
	var self_pos := Vector3(0, 0, -2)
	var ctx: RoleContext = _make_ctx(self_pos, puck_pos)
	var opp := SkaterNetworkState.new()
	opp.position = Vector3(1, 0, -14.5)         # on the puck
	ctx.snapshot.skater_states[200] = opp
	ctx.team_id_by_peer[200] = 1
	var d: RoleDecision = AIRoleChase.decide(ctx)
	assert_gt(d.target_position.z,
			puck_pos.z + AIRoleRushD.GAP_MIN_STICKS * SkaterAgentStateMachine.BLADE_REACH_M - 0.01,
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


func test_the_pre_contain_stand_is_angled_off_the_middle() -> void:
	# Same lost race, but with the puck OFF CENTRE. The pre-contain is the
	# closing verb applied to the puck, and a closing stand is shaded to the
	# inside — so the chaser plants where RUSH_D1 will want to be the instant
	# somebody collects, rather than a spot the gap defender has to correct off
	# in the direction that concedes the middle.
	#
	# The previous test deliberately runs the puck down the centre line, where
	# inside_shade_m is nil by construction (no inside to take, no side to pick),
	# so it cannot see this.
	var puck_pos := Vector3(7.0, 0.0, -14.0)    # wide right, up-ice
	var ctx: RoleContext = _make_ctx(Vector3(6.0, 0.0, -2.0), puck_pos)
	var opp := SkaterNetworkState.new()
	opp.position = Vector3(7.5, 0.0, -14.5)     # on the puck
	ctx.snapshot.skater_states[200] = opp
	ctx.team_id_by_peer[200] = 1

	var d: RoleDecision = AIRoleChase.decide(ctx)
	var to_net: Vector3 = ctx.defending_goal_pos - puck_pos
	var dir_net: Vector3 = Vector3(to_net.x, 0.0, to_net.z).normalized()
	var offset: Vector3 = d.target_position - (puck_pos + dir_net
			* puck_pos.distance_to(d.target_position))
	# Signed onto the inside axis: positive means shaded toward centre ice.
	var inside: Vector3 = AIRoleHelpers.inside_dir(puck_pos, dir_net)
	assert_gt(offset.x * inside.x + offset.z * inside.z, 0.1,
			"the pre-contain stand takes the inside of a wide puck; got %s for a puck at %s"
			% [str(d.target_position), str(puck_pos)])


func test_chase_puck_reports_whether_we_are_running_the_race() -> void:
	# The verb's contract: TRUE means we are going and the target is the puck;
	# FALSE means somebody else has it and the target is the stand instead.
	# Callers other than CHASE need that answer, not just the position.
	var puck_pos := Vector3(0.0, 0.0, -8.0)
	var live: RoleContext = _make_ctx(Vector3(0.0, 0.0, -4.0), puck_pos)
	var d_live := RoleDecision.new()
	assert_true(AIRoleHelpers.chase_puck(live, d_live), "an uncontested puck is ours to go get")
	assert_eq(d_live.target_position, puck_pos, "…and the target is the puck")

	var lost: RoleContext = _make_ctx(Vector3(0.0, 0.0, -2.0), Vector3(0.0, 0.0, -14.0))
	var opp := SkaterNetworkState.new()
	opp.position = Vector3(1.0, 0.0, -14.5)
	lost.snapshot.skater_states[200] = opp
	lost.team_id_by_peer[200] = 1
	var d_lost := RoleDecision.new()
	assert_false(AIRoleHelpers.chase_puck(lost, d_lost), "a race an opponent owns is declined")
	assert_ne(d_lost.target_position, Vector3(0.0, 0.0, -14.0),
			"…and the target is the stand, not the puck")
