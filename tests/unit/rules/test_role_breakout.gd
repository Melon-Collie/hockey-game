extends GutTest

# AIRoleBreakout's decide() integrates existing primitives (lane_clear +
# position_potential) over a side-gated candidate set. These tests cover
# the structural contracts rather than re-testing the scoring math
# (covered in test_ai_action_scoring):
#   - Bail-out when there's no puck.
#   - STRONG sets up on the strong side; WEAK on the weak side.
#   - WEAK stays goal-side of the carrier (reverse valve); STRONG may
#     advance up-ice past the carrier.

const TEAM_ID: int = 0
const OUR_NET_Z: float = 26.65   # Team 0 defends +Z, attacks -Z
const OPP_NET_Z: float = -OUR_NET_Z


func _make_ctx(self_pos: Vector3, carrier_pid: int, skaters: Array,
		strong_x: float = 1.0) -> RoleContext:
	var snap := WorldSnapshot.new()
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
	snap.puck_state = puck

	var team_map: Dictionary = {}
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
	ctx.team_id_by_peer = team_map
	ctx.strong_x = strong_x
	return ctx


func test_no_puck_stands_still() -> void:
	var self_pos := Vector3(5, 0, 20)
	var ctx := _make_ctx(self_pos, -1, [[1, TEAM_ID, self_pos]])
	ctx.snapshot.puck_state = null
	var d: RoleDecision = AIRoleBreakout.decide(ctx, true)
	assert_eq(d.target_position, self_pos, "no puck → stand still")


func test_strong_sets_up_on_strong_side() -> void:
	# Carrier deep in our own zone, strong side +X. The STRONG outlet
	# should target the +X half of the ice.
	var self_pos := Vector3(2, 0, 18)
	var skaters: Array = [
			[1, TEAM_ID, self_pos],              # us (STRONG)
			[100, TEAM_ID, Vector3(0, 0, 24)],   # carrier, deep
			[200, 1, Vector3(0, 0, 10)],         # opp forechecker
	]
	var ctx := _make_ctx(self_pos, 100, skaters, 1.0)
	var d: RoleDecision = AIRoleBreakout.decide(ctx, true)
	assert_gt(d.target_position.x, 0.0, "strong outlet sets up on the +X strong side")


func test_weak_sets_up_on_weak_side() -> void:
	# Same setup; the WEAK outlet works the -X side when strong is +X.
	var self_pos := Vector3(-2, 0, 22)
	var skaters: Array = [
			[1, TEAM_ID, self_pos],              # us (WEAK)
			[100, TEAM_ID, Vector3(0, 0, 24)],   # carrier, deep
			[200, 1, Vector3(0, 0, 10)],         # opp forechecker
	]
	var ctx := _make_ctx(self_pos, 100, skaters, 1.0)
	var d: RoleDecision = AIRoleBreakout.decide(ctx, false)
	assert_lt(d.target_position.x, 0.0, "weak outlet sets up on the -X weak side")


func test_weak_stays_goal_side_of_carrier() -> void:
	# The weak-side reverse valve must not drift up-ice past the carrier
	# (beyond the tolerance) — it's the safety release. own_goal_dir * z
	# grows toward our net, so the target's z must be >= carrier.z minus
	# the tolerance.
	var carrier_z: float = 20.0
	var self_pos := Vector3(-3, 0, 22)
	var skaters: Array = [
			[1, TEAM_ID, self_pos],
			[100, TEAM_ID, Vector3(0, 0, carrier_z)],
			[200, 1, Vector3(0, 0, 12)],
	]
	var ctx := _make_ctx(self_pos, 100, skaters, 1.0)
	var d: RoleDecision = AIRoleBreakout.decide(ctx, false)
	assert_gte(d.target_position.z,
			carrier_z - AIRoleBreakout.GOAL_SIDE_TOLERANCE_M - 0.001,
			"weak valve stays goal-side of (no further up-ice than) the carrier")


func test_strong_follows_strong_x_flip() -> void:
	# Flip strong side to -X: STRONG now works the -X half.
	var self_pos := Vector3(-2, 0, 18)
	var skaters: Array = [
			[1, TEAM_ID, self_pos],
			[100, TEAM_ID, Vector3(0, 0, 24)],
			[200, 1, Vector3(0, 0, 10)],
	]
	var ctx := _make_ctx(self_pos, 100, skaters, -1.0)
	var d: RoleDecision = AIRoleBreakout.decide(ctx, true)
	assert_lt(d.target_position.x, 0.0, "strong outlet follows the flipped (-X) strong side")
