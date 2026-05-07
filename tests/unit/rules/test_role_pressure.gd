extends GutTest

# AIRolePressure — DZONE + TRANS_OD puck pressurer. Tests cover:
#   - Bail-out (no carrier).
#   - Goal-side filter rejects wrong-side candidates.
#   - Argmax picks a position that blocks the shot lane when
#     carrier has a clear shot.
#   - Argmax shifts toward a pass-lane when an opp teammate offers
#     a more dangerous pass than the shot.
# Underlying score_shoot / score_pass primitives are tested in
# test_ai_action_scoring.

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
	ctx.team_id_resolver = func(pid: int) -> int: return int(team_map.get(pid, -1))
	return ctx


# ── Bail-outs ───────────────────────────────────────────────────────────────

func test_falls_back_to_self_pos_when_no_threat_origin() -> void:
	# Snapshot has no usable puck data (default ctx has puck at
	# Vector3.ZERO with no carrier — resolve_threat_pos returns
	# ZERO). Safe fallback to self_pos.
	var self_pos := Vector3(0, 0, 18)
	var ctx: RoleContext = _make_ctx(self_pos)
	var d: RoleDecision = AIRolePressure.decide(ctx)
	assert_eq(d.target_position, self_pos,
			"no threat origin → fall back to self_pos")


func test_uses_puck_pos_as_threat_when_no_carrier() -> void:
	# NEUTRAL — loose puck at meaningful position, no carrier.
	# PRESSURE should treat puck_pos as the threat origin and run
	# its argmax instead of bailing.
	var self_pos := Vector3(8, 0, 0)
	var skaters: Array = [
		[1, TEAM_ID, self_pos, Vector3.ZERO],
		[200, 1 - TEAM_ID, Vector3(-3, 0, 5), Vector3.ZERO],
	]
	var ctx: RoleContext = _make_ctx(self_pos, -1, skaters)
	# Puck loose at (0, 0, 5) — Z>0 so on our-net side of NZ center.
	ctx.snapshot.puck_state.position = Vector3(0, 0, 5)
	var d: RoleDecision = AIRolePressure.decide(ctx)
	# Argmax should pick a goal-side candidate (z >= puck.z).
	assert_true(d.target_position.z >= 5.0 - 0.01,
			"with no carrier, PRESSURE uses puck as threat; target stays goal-side; got %s" % d.target_position)


# ── Goal-side filter ────────────────────────────────────────────────────────

func test_chosen_target_is_goal_side_of_carrier() -> void:
	# Team 0 defends +Z. Carrier at (0, 0, 22) deep in our DZ. Our
	# net at (0, 0, 26.65). PRESSURE must pick a candidate with
	# z >= 22 (goal-side, between carrier and our net).
	var carrier_pos := Vector3(0, 0, 22)
	var skaters: Array = [
		[1, TEAM_ID, Vector3(0, 0, 18), Vector3.ZERO],   # us (PRESSURE)
		[200, 1 - TEAM_ID, carrier_pos, Vector3.ZERO],   # opp carrier
	]
	var ctx: RoleContext = _make_ctx(Vector3(0, 0, 18), 200, skaters)
	var d: RoleDecision = AIRolePressure.decide(ctx)
	assert_true(d.target_position.z >= carrier_pos.z - 0.01,
			"chosen target must be on the our-net side of the carrier; got z=%f vs carrier.z=%f" % [d.target_position.z, carrier_pos.z])


# ── Argmax denies the carrier's best option ─────────────────────────────────

func test_argmax_blocks_shot_lane_when_no_pass_options() -> void:
	# Solo opp carrier with a clear shot at our net. No opp teammates,
	# so the carrier's only option is to shoot. PRESSURE should pick
	# the candidate that most blocks the shot lane — typically the
	# polar sample directly between carrier and our net.
	var carrier_pos := Vector3(0, 0, 22)
	var skaters: Array = [
		[1, TEAM_ID, Vector3(8, 0, 18), Vector3.ZERO],   # us, off to the side
		[200, 1 - TEAM_ID, carrier_pos, Vector3.ZERO],   # opp carrier
	]
	var ctx: RoleContext = _make_ctx(Vector3(8, 0, 18), 200, skaters)
	var d: RoleDecision = AIRolePressure.decide(ctx)
	# Chosen target should be approximately on the carrier→our-net
	# line. The carrier→net line is along +Z (from z=22 to z=26.65),
	# so target.x should be near 0 (close to the line in X) and z
	# should be > carrier.z.
	assert_true(d.target_position.z >= carrier_pos.z - 0.01,
			"target is goal-side of carrier (z=%f)" % d.target_position.z)
	assert_lt(absf(d.target_position.x), 3.5,
			"target stays close to the shot-lane axis; got x=%f" % d.target_position.x)


func test_argmax_shifts_toward_pass_lane_when_pass_dominates() -> void:
	# Carrier with a back-checker right behind them and an open
	# teammate to the side. The shot lane is essentially blocked by
	# our own positioning so the pass becomes the dominant threat.
	# PRESSURE should shade laterally toward the pass lane between
	# carrier and the opp teammate.
	#
	# Geometry: carrier at (0, 0, 22). Opp teammate at (5, 0, 22) —
	# same depth, lateral. Pass lane goes along +X. PRESSURE should
	# shade toward +X relative to a baseline (no-pass-option) setup.
	var carrier_pos := Vector3(0, 0, 22)
	var opp_teammate_pos := Vector3(5, 0, 22)

	# Baseline: only the carrier.
	var skaters_solo: Array = [
		[1, TEAM_ID, Vector3(0, 0, 18), Vector3.ZERO],
		[200, 1 - TEAM_ID, carrier_pos, Vector3.ZERO],
	]
	var ctx_a: RoleContext = _make_ctx(Vector3(0, 0, 18), 200, skaters_solo)
	var solo_target: Vector3 = AIRolePressure.decide(ctx_a).target_position

	# With pass option: opp teammate to the +X side.
	var skaters_pass: Array = [
		[1, TEAM_ID, Vector3(0, 0, 18), Vector3.ZERO],
		[200, 1 - TEAM_ID, carrier_pos, Vector3.ZERO],
		[210, 1 - TEAM_ID, opp_teammate_pos, Vector3.ZERO],
	]
	var ctx_b: RoleContext = _make_ctx(Vector3(0, 0, 18), 200, skaters_pass)
	var pass_target: Vector3 = AIRolePressure.decide(ctx_b).target_position

	# With a +X pass option, PRESSURE should shade toward +X (or at
	# least no further -X than the solo baseline). Loose assertion:
	# pass-target.x >= solo-target.x.
	assert_true(pass_target.x >= solo_target.x - 0.01,
			"adding +X pass option should not pull PRESSURE further -X; got pass=%s solo=%s" % [pass_target, solo_target])


# ── Wrong-side filter ───────────────────────────────────────────────────────

func test_wrong_side_candidates_are_filtered() -> void:
	# Carrier at (0, 0, 0). Polar samples include (0, 0, -3) (angle
	# 270° — toward opp net for Team 0). That candidate is between
	# carrier and the OPP net, the wrong side. PRESSURE must never
	# pick it; chosen target.z >= carrier.z.
	var carrier_pos := Vector3(0, 0, 0)
	var skaters: Array = [
		[1, TEAM_ID, Vector3(-3, 0, -2), Vector3.ZERO],  # us, currently on wrong side
		[200, 1 - TEAM_ID, carrier_pos, Vector3.ZERO],
	]
	var ctx: RoleContext = _make_ctx(Vector3(-3, 0, -2), 200, skaters)
	var d: RoleDecision = AIRolePressure.decide(ctx)
	assert_true(d.target_position.z >= carrier_pos.z - 0.01,
			"wrong-side candidates must be filtered; chosen target.z=%f vs carrier.z=%f" % [d.target_position.z, carrier_pos.z])
