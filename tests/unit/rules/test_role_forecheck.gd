extends GutTest

# AIRoleForecheck — FORECHECK off-puck roles. F1 reuses AIRolePressure
# (covered in test_role_pressure), so here we cover F3 (high safety at
# the opp blue line) and F2 (mid-lane breakout read). The underlying
# threat_surface_pass primitive is covered in test_ai_action_scoring;
# these cover the structural contracts:
#   - F3 holds at the opp blue line on the strong side.
#   - F2 reads off a loose puck (doesn't freeze) and stays OZ-side of
#     the opp blue line (doesn't drop deep into F1's area).

const TEAM_ID: int = 0
const OUR_NET_Z: float = 26.65   # Team 0 defends +Z, attacks -Z
const OPP_NET_Z: float = -OUR_NET_Z


func _make_ctx(self_pos: Vector3, carrier_pid: int, skaters: Array,
		strong_x: float = 1.0) -> RoleContext:
	var snap := WorldSnapshot.new()
	for entry: Array in skaters:
		var sk := SkaterNetworkState.new()
		sk.position = entry[2]
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


# ── F3: high safety ──────────────────────────────────────────────────────────

func test_f3_holds_at_opp_blue_line() -> void:
	var self_pos := Vector3(5, 0, -10)
	var ctx := _make_ctx(self_pos, 200, [
			[1, TEAM_ID, self_pos],
			[200, 1, Vector3(0, 0, -22)],
	], 1.0)
	var d: RoleDecision = AIRoleForecheck.decide(ctx, true)
	# Team 0 attacks -Z, opp blue line at z = -BLUE_LINE_Z.
	assert_almost_eq(d.target_position.z, -GameRules.BLUE_LINE_Z, 0.001,
			"F3 holds at the opp blue line")
	assert_gt(d.target_position.x, 0.0, "F3 holds on the +X strong side")


func test_f3_follows_strong_x_flip() -> void:
	var self_pos := Vector3(-5, 0, -10)
	var ctx := _make_ctx(self_pos, 200, [
			[1, TEAM_ID, self_pos],
			[200, 1, Vector3(0, 0, -22)],
	], -1.0)
	var d: RoleDecision = AIRoleForecheck.decide(ctx, true)
	assert_lt(d.target_position.x, 0.0, "F3 holds on the -X side when strong side flips")


# ── F2: mid-lane read ────────────────────────────────────────────────────────

func test_f2_reads_off_loose_puck_instead_of_freezing() -> void:
	# Loose puck deep in the opp zone — a prime forecheck moment. F2 must
	# set up a read, not freeze at self_pos.
	var self_pos := Vector3(0, 0, -2)
	var skaters: Array = [
			[1, TEAM_ID, self_pos],
			[200, 1, Vector3(3, 0, -22)],   # opp near loose puck
			[210, 1, Vector3(-4, 0, -18)],  # opp outlet receiver
	]
	var ctx := _make_ctx(self_pos, -1, skaters, 1.0)
	ctx.snapshot.puck_state.position = Vector3(3, 0, -22)  # loose, deep in opp zone
	var d: RoleDecision = AIRoleForecheck.decide(ctx, false)
	assert_ne(d.target_position, self_pos, "F2 reads off the loose puck, doesn't freeze")


func test_f2_stays_oz_side_of_opp_blue_line() -> void:
	# F2's target must stay on the attacking-zone side of the opp blue
	# line (z <= -BLUE_LINE_Z for team 0) so it doesn't drop deep into
	# F1's pressure area — and so it never trails the puck out to ghost.
	var self_pos := Vector3(0, 0, -12)
	var skaters: Array = [
			[1, TEAM_ID, self_pos],
			[200, 1, Vector3(2, 0, -20)],   # opp carrier deep
			[210, 1, Vector3(-3, 0, -16)],  # outlet receiver
	]
	var ctx := _make_ctx(self_pos, 200, skaters, 1.0)
	var d: RoleDecision = AIRoleForecheck.decide(ctx, false)
	assert_lte(d.target_position.z, -GameRules.BLUE_LINE_Z + 0.001,
			"F2 stays OZ-side of the opp blue line (never drops deep / trails out)")
