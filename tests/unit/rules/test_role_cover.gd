extends GutTest

# AIRoleCover — DZONE + TRANS_OD weak-side support /
# pass-interception read. Tests cover:
#   - Bail-outs (no carrier, no opp teammates).
#   - Argmax positions between puck and our net (back-of-play).
#   - Pass-lane denial: with a single opp pass receiver, COVER
#     positions to disrupt that pass.
# Underlying score_pass primitive is tested in test_ai_action_scoring.

const TEAM_ID: int = 0
const OUR_NET_Z: float = 26.65   # Team 0 defends +Z


func _make_ctx(self_pos: Vector3, carrier_pid: int = -1,
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
	ctx.team_id_resolver = func(pid: int) -> int: return int(team_map.get(pid, -1))
	return ctx


# ── Bail-outs ───────────────────────────────────────────────────────────────

func test_falls_back_to_self_pos_when_no_carrier() -> void:
	# Loose puck — COVER has no carrier to read. NEUTRAL play uses
	# CHASE/FLANK; an in-flight pass moment in DZONE/TRANS_OD
	# resolves within a frame via the brain's event-driven re-tick.
	var self_pos := Vector3(-3, 0, 18)
	var ctx: RoleContext = _make_ctx(self_pos)
	var d: RoleDecision = AIRoleCover.decide(ctx)
	assert_eq(d.target_position, self_pos,
			"loose puck → fall back to self_pos")


func test_falls_back_to_self_pos_when_only_carrier_no_pass_receivers() -> void:
	# Solo opp carrier, no pass receivers. PRESSURE/ANCHOR cover the
	# carrier's direct options; COVER has no pass threat to read.
	var self_pos := Vector3(-3, 0, 18)
	var skaters: Array = [
		[1, TEAM_ID, self_pos, Vector3.ZERO],
		[200, 1 - TEAM_ID, Vector3(5, 0, 22), Vector3.ZERO],
	]
	var ctx: RoleContext = _make_ctx(self_pos, 200, skaters)
	var d: RoleDecision = AIRoleCover.decide(ctx)
	assert_eq(d.target_position, self_pos,
			"single opp (no pass receivers) → fall back to self_pos")


# ── Positioning lands between puck and our net ─────────────────────────────

func test_chosen_target_is_between_puck_and_our_net() -> void:
	# Carrier at (5, 0, 22) deep DZ, opp teammate at (-3, 0, 25)
	# (back-door). COVER's search center is the midpoint between
	# carrier and our net, shifted weak-side. Chosen target should
	# be roughly between puck.z and our_net.z.
	var carrier_pos := Vector3(5, 0, 22)
	var skaters: Array = [
		[1, TEAM_ID, Vector3(0, 0, 18), Vector3.ZERO],
		[200, 1 - TEAM_ID, carrier_pos, Vector3.ZERO],
		[210, 1 - TEAM_ID, Vector3(-3, 0, 25), Vector3.ZERO],
	]
	var ctx: RoleContext = _make_ctx(Vector3(0, 0, 18), 200, skaters)
	var d: RoleDecision = AIRoleCover.decide(ctx)
	# z should be on the our-net side of the carrier (z >= carrier.z),
	# within reasonable polar-sample range of the midpoint.
	assert_true(d.target_position.z >= carrier_pos.z - 4.0,
			"target is back-of-puck or further; got z=%f vs carrier.z=%f" % [d.target_position.z, carrier_pos.z])


# ── Pass-lane denial ───────────────────────────────────────────────────────

func test_argmax_blocks_dominant_pass_lane() -> void:
	# Carrier at (5, 0, 18), pass receiver at (-3, 0, 22). Pass lane
	# runs roughly southwest-to-northeast through (1, 0, 20). COVER
	# should pick a candidate that intersects this lane (lane sits
	# in COVER's search region — back of puck weak-side).
	#
	# Verify by comparing against a baseline with no pass receiver:
	# COVER's chosen X should shift toward the receiver's X side
	# (negative) when the receiver is added.
	var carrier_pos := Vector3(5, 0, 18)
	var receiver_pos := Vector3(-3, 0, 22)

	# Baseline: solo carrier, no receivers.
	var skaters_solo: Array = [
		[1, TEAM_ID, Vector3(0, 0, 18), Vector3.ZERO],
		[200, 1 - TEAM_ID, carrier_pos, Vector3.ZERO],
	]
	var ctx_a: RoleContext = _make_ctx(Vector3(0, 0, 18), 200, skaters_solo)
	var solo_target: Vector3 = AIRoleCover.decide(ctx_a).target_position
	# Solo case has no receivers — COVER bails out to self_pos.

	# With receiver.
	var skaters_with_rcv: Array = [
		[1, TEAM_ID, Vector3(0, 0, 18), Vector3.ZERO],
		[200, 1 - TEAM_ID, carrier_pos, Vector3.ZERO],
		[210, 1 - TEAM_ID, receiver_pos, Vector3.ZERO],
	]
	var ctx_b: RoleContext = _make_ctx(Vector3(0, 0, 18), 200, skaters_with_rcv)
	var with_rcv_target: Vector3 = AIRoleCover.decide(ctx_b).target_position

	# When the -X receiver is added, COVER's chosen target should
	# be different from the bail-out (it should run argmax). Loose
	# assertion: the target moved.
	assert_ne(with_rcv_target, solo_target,
			"adding a pass receiver should pull COVER away from the bail-out position")

	# And the target should be roughly between carrier.x and
	# receiver.x (in the lane region).
	assert_true(with_rcv_target.x <= carrier_pos.x + 0.01,
			"with -X receiver, COVER target x <= carrier x; got x=%f" % with_rcv_target.x)
