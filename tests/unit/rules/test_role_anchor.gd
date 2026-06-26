extends GutTest

# AIRoleAnchor — DZONE-only net-front / deep defender (TRANS_OD
# uses BACKCHECK + CONTAIN instead). Tests cover:
#   - Bail-out (no opps).
#   - Argmax positions in slot area (close to our net).
#   - Lane-blocking: with a single opp shooter, ANCHOR positions
#     to block the shot lane.
#   - Cross-crease shading: with two opp threats, ANCHOR shifts
#     toward whichever threat is dominant.
# Underlying score_shoot primitive is tested in test_ai_action_scoring.

const TEAM_ID: int = 0
const OUR_NET_Z: float = 26.65   # Team 0 defends +Z


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


# ── Bail-outs ───────────────────────────────────────────────────────────────

func test_falls_back_to_self_pos_when_no_opps() -> void:
	# No opps means no shot threat to defend against.
	var self_pos := Vector3(0, 0, 21)
	var ctx: RoleContext = _make_ctx(self_pos)
	var d: RoleDecision = AIRoleAnchor.decide(ctx)
	assert_eq(d.target_position, self_pos,
			"no opps → fall back to self_pos")


# ── Positioning lands in the slot area ─────────────────────────────────────

func test_chosen_target_is_near_our_net_in_dzone() -> void:
	# DZONE: opp carrier deep in our zone at (0, 0, 22). ANCHOR's
	# search center is midpoint(puck, our_net) = (0, 0, 24.3) — close
	# to net. Polar samples around this center stay near the slot.
	var skaters: Array = [
		[1, TEAM_ID, Vector3(0, 0, 18), Vector3.ZERO],   # us
		[200, 1 - TEAM_ID, Vector3(0, 0, 22), Vector3.ZERO],
	]
	var ctx: RoleContext = _make_ctx(Vector3(0, 0, 18), skaters, 200)
	var d: RoleDecision = AIRoleAnchor.decide(ctx)
	# DZ midpoint pulls ANCHOR close to net. Target.z should be in
	# [puck.z - SEARCH_STEP, our_net.z] so within ~9 m of net.
	assert_lt(absf(OUR_NET_Z - d.target_position.z), 9.0,
			"target stays near our net in DZONE; got z=%f" % d.target_position.z)


# ── Lane-blocking: argmax cuts the shot lane ───────────────────────────────

func test_argmax_blocks_shot_lane_for_single_opp() -> void:
	# Single opp carrier shooting from (0, 0, 22) at our net (0, 0, 26.65).
	# Puck at carrier; ANCHOR's search center = midpoint(puck, our_net)
	# = (0, 0, 24.3). ANCHOR picks a candidate on the shot-lane axis
	# (X near 0) — defender placement on the lane reduces opp's
	# threat surface via pressure cone alignment.
	var skaters: Array = [
		[1, TEAM_ID, Vector3(8, 0, 18), Vector3.ZERO],   # us, off to the side
		[200, 1 - TEAM_ID, Vector3(0, 0, 22), Vector3.ZERO],
	]
	var ctx: RoleContext = _make_ctx(Vector3(8, 0, 18), skaters, 200)
	var d: RoleDecision = AIRoleAnchor.decide(ctx)
	assert_lt(absf(d.target_position.x), 3.5,
			"target stays close to shot-lane axis; got x=%f" % d.target_position.x)


# ── Cross-crease shading ───────────────────────────────────────────────────

func test_argmax_shades_toward_dominant_threat() -> void:
	# Two opp threats — one at center-ice in our zone (clean shot
	# axis), one off to the side. The on-axis opp carries the puck
	# (it's the dominant shot threat). Search center = midpoint(puck,
	# our_net) = (0, 0, 24.3). Off-axis baseline: same midpoint when
	# off_axis_opp is the carrier.
	#
	# When on-axis carrier is added, ANCHOR should bias toward x=0
	# to cover the on-axis lane (covering both shot threats from a
	# single position).
	var off_axis_opp := Vector3(8, 0, 20)

	# Baseline: only the off-axis threat (carrier).
	var skaters_off: Array = [
		[1, TEAM_ID, Vector3(0, 0, 18), Vector3.ZERO],
		[200, 1 - TEAM_ID, off_axis_opp, Vector3.ZERO],
	]
	var ctx_a: RoleContext = _make_ctx(Vector3(0, 0, 18), skaters_off, 200)
	var off_only_target: Vector3 = AIRoleAnchor.decide(ctx_a).target_position

	# Add a more-threatening on-axis shooter as carrier.
	var on_axis_opp := Vector3(0, 0, 22)
	var skaters_both: Array = [
		[1, TEAM_ID, Vector3(0, 0, 18), Vector3.ZERO],
		[200, 1 - TEAM_ID, off_axis_opp, Vector3.ZERO],
		[210, 1 - TEAM_ID, on_axis_opp, Vector3.ZERO],
	]
	var ctx_b: RoleContext = _make_ctx(Vector3(0, 0, 18), skaters_both, 210)
	var both_target: Vector3 = AIRoleAnchor.decide(ctx_b).target_position

	# When the on-axis carrier is added, ANCHOR should shift toward 0
	# (covering the on-axis lane). Loose assertion:
	# |both_target.x| <= |off_only_target.x| + epsilon.
	assert_true(absf(both_target.x) <= absf(off_only_target.x) + 0.01,
			"adding on-axis carrier should shade ANCHOR toward center; got both=%s off-only=%s" % [both_target, off_only_target])


# ── Man-on-threat coverage (brain assigned us a specific opponent) ──────────

func test_assigned_man_drives_coverage_side() -> void:
	# Carrier at center, two receivers wide. When the brain assigns ANCHOR the
	# LEFT receiver it covers the left side; the RIGHT receiver flips it right.
	# Proves the central partition — not the global-max minimax — drives which
	# man this defender takes.
	var carrier := Vector3(0, 0, 20)
	var left_man := Vector3(-7, 0, 19)
	var right_man := Vector3(7, 0, 19)
	var skaters: Array = [
		[1, TEAM_ID, Vector3(0, 0, 16), Vector3.ZERO],
		[200, 1 - TEAM_ID, carrier, Vector3.ZERO],
		[210, 1 - TEAM_ID, left_man, Vector3.ZERO],
		[220, 1 - TEAM_ID, right_man, Vector3.ZERO],
	]

	var ctx_left: RoleContext = _make_ctx(Vector3(0, 0, 16), skaters, 200)
	ctx_left.assigned_threat_peer = 210
	var left_target: Vector3 = AIRoleAnchor.decide(ctx_left).target_position
	assert_lt(left_target.x, 0.0,
			"assigned the left man → cover the left side; got x=%f" % left_target.x)

	var ctx_right: RoleContext = _make_ctx(Vector3(0, 0, 16), skaters, 200)
	ctx_right.assigned_threat_peer = 220
	var right_target: Vector3 = AIRoleAnchor.decide(ctx_right).target_position
	assert_gt(right_target.x, 0.0,
			"assigned the right man → cover the right side; got x=%f" % right_target.x)

	# Goal-side of the assigned man (between him and our net, not out past him).
	assert_gt(left_target.z, left_man.z - 0.01,
			"coverage is goal-side of the man; got z=%f" % left_target.z)


