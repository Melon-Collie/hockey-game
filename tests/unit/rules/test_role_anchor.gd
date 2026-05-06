extends GutTest

# AIRoleAnchor — DZONE + TRANS_OD net-front / deep defender. Tests
# cover:
#   - Bail-out (no opps).
#   - Argmax positions in slot area (close to our net).
#   - Lane-blocking: with a single opp shooter, ANCHOR positions
#     to block the shot lane.
#   - Cross-crease shading: with two opp threats, ANCHOR shifts
#     toward whichever threat is dominant.
# Underlying score_shoot primitive is tested in test_ai_action_scoring.

const TEAM_ID: int = 0
const OUR_NET_Z: float = 26.65   # Team 0 defends +Z


func _make_ctx(self_pos: Vector3, skaters: Array = []) -> RoleContext:
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
	puck.carrier_peer_id = -1
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
	ctx.team_id_resolver = func(pid: int) -> int: return int(team_map.get(pid, -1))
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

func test_chosen_target_is_near_our_net() -> void:
	# Single opp threat. ANCHOR should pick a position in the slot
	# area (within ~SLOT_DEPTH + SEARCH_STEP of our net).
	var skaters: Array = [
		[1, TEAM_ID, Vector3(0, 0, 18), Vector3.ZERO],   # us
		[200, 1 - TEAM_ID, Vector3(0, 0, 22), Vector3.ZERO],
	]
	var ctx: RoleContext = _make_ctx(Vector3(0, 0, 18), skaters)
	var d: RoleDecision = AIRoleAnchor.decide(ctx)
	# ANCHOR's search center is SLOT_DEPTH_M (5 m) in front of our
	# net. Polar samples extend out to SEARCH_STEP_M (3 m) from the
	# center. Target.z should be roughly in [our_net.z - 8, our_net.z].
	assert_lt(absf(OUR_NET_Z - d.target_position.z), 9.0,
			"target stays in slot area near our net; got z=%f" % d.target_position.z)


# ── Lane-blocking: argmax cuts the shot lane ───────────────────────────────

func test_argmax_blocks_shot_lane_for_single_opp() -> void:
	# Single opp shooting from (0, 0, 22) at our net (0, 0, 26.65).
	# ANCHOR should pick a candidate on the shot-lane axis (X near 0).
	var skaters: Array = [
		[1, TEAM_ID, Vector3(8, 0, 18), Vector3.ZERO],   # us, off to the side
		[200, 1 - TEAM_ID, Vector3(0, 0, 22), Vector3.ZERO],
	]
	var ctx: RoleContext = _make_ctx(Vector3(8, 0, 18), skaters)
	var d: RoleDecision = AIRoleAnchor.decide(ctx)
	assert_lt(absf(d.target_position.x), 3.5,
			"target stays close to shot-lane axis; got x=%f" % d.target_position.x)


# ── Cross-crease shading ───────────────────────────────────────────────────

func test_argmax_shades_toward_dominant_threat() -> void:
	# Two opp threats — one at center-ice in our zone (clean shot
	# axis), one off to the side. ANCHOR should bias toward the
	# higher-threat shooter. Verify by comparing against a baseline
	# with only the off-side threat: ANCHOR's chosen X should shift
	# toward 0 when the on-axis threat is added.
	var off_axis_opp := Vector3(8, 0, 20)

	# Baseline: only the off-axis threat.
	var skaters_off: Array = [
		[1, TEAM_ID, Vector3(0, 0, 18), Vector3.ZERO],
		[200, 1 - TEAM_ID, off_axis_opp, Vector3.ZERO],
	]
	var ctx_a: RoleContext = _make_ctx(Vector3(0, 0, 18), skaters_off)
	var off_only_target: Vector3 = AIRoleAnchor.decide(ctx_a).target_position

	# Add a more-threatening on-axis shooter.
	var on_axis_opp := Vector3(0, 0, 22)
	var skaters_both: Array = [
		[1, TEAM_ID, Vector3(0, 0, 18), Vector3.ZERO],
		[200, 1 - TEAM_ID, off_axis_opp, Vector3.ZERO],
		[210, 1 - TEAM_ID, on_axis_opp, Vector3.ZERO],
	]
	var ctx_b: RoleContext = _make_ctx(Vector3(0, 0, 18), skaters_both)
	var both_target: Vector3 = AIRoleAnchor.decide(ctx_b).target_position

	# When the on-axis (more threatening) shot is added, ANCHOR
	# should shift toward 0 (covering the on-axis lane). Loose
	# assertion: |both_target.x| <= |off_only_target.x| + epsilon.
	assert_true(absf(both_target.x) <= absf(off_only_target.x) + 0.01,
			"adding on-axis threat should shade ANCHOR toward center; got both=%s off-only=%s" % [both_target, off_only_target])
