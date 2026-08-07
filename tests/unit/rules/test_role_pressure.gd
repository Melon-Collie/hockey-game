extends GutTest

# AIRolePressure — DZONE + TRANS_OD puck pressurer. Tests cover:
#   - Loose puck (no carrier) → pressures the puck, never freezes.
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
	ctx.team_id_by_peer = team_map
	return ctx


# ── Body check commit ────────────────────────────────────────────────────────

func test_commits_body_check_on_reachable_hard_hit() -> void:
	# Carrier 2 m away, head-on; a heavy pressurer predicts a separating
	# hit and commits — steering at the body intercept, not the cutoff point.
	var self_pos := Vector3(0, 0, 18)
	var skaters: Array = [
			[1, TEAM_ID, self_pos],
			[200, 1 - TEAM_ID, Vector3(0, 0, 20)],
	]
	var ctx: RoleContext = _make_ctx(self_pos, 200, skaters)
	ctx.self_max_speed = 9.0
	ctx.self_body_check_transfer = 0.61   # ~ +36% Physical
	var d: RoleDecision = AIRolePressure.decide(ctx)
	assert_true(d.commit_check, "heavy pressurer commits to a reachable hit")
	assert_almost_eq(d.check_target.z, 20.0, 0.5, "drives at the carrier's body")
	assert_eq(d.target_position, d.check_target, "steering target is the body intercept")


func test_no_body_check_when_hit_is_soft() -> void:
	# Same geometry, light pressurer: the hit wouldn't separate, so it
	# falls through to normal cutoff positioning instead of committing.
	var self_pos := Vector3(0, 0, 18)
	var skaters: Array = [
			[1, TEAM_ID, self_pos],
			[200, 1 - TEAM_ID, Vector3(0, 0, 20)],
	]
	var ctx: RoleContext = _make_ctx(self_pos, 200, skaters)
	ctx.self_max_speed = 9.0
	ctx.self_body_check_transfer = 0.29   # ~ -36% Physical
	var d: RoleDecision = AIRolePressure.decide(ctx)
	assert_false(d.commit_check, "light pressurer doesn't commit to a soft hit")


func test_no_body_check_on_loose_puck() -> void:
	# No live carrier → never a hit target; normal (loose-puck) pressure.
	var self_pos := Vector3(0, 0, 18)
	var ctx: RoleContext = _make_ctx(self_pos)   # carrier_pid -1, loose puck
	ctx.self_body_check_transfer = 0.61
	var d: RoleDecision = AIRolePressure.decide(ctx)
	assert_false(d.commit_check, "no body check without a live opponent carrier")


# ── Bail-outs ───────────────────────────────────────────────────────────────

func test_pressures_loose_puck_instead_of_freezing() -> void:
	# Loose puck (in-flight pass / contested moment). PRESSURE used to
	# freeze at self_pos here — the "stuck on the heels" bug. It must now
	# orient off the puck and close it goal-side. Bot starts up-ice on
	# the wrong side of the puck; the chosen target must be goal-side of
	# the loose puck, never self_pos.
	var self_pos := Vector3(6, 0, -4)   # up-ice, wrong side of the puck
	var ctx: RoleContext = _make_ctx(self_pos)   # loose puck at origin
	var d: RoleDecision = AIRolePressure.decide(ctx)
	assert_ne(d.target_position, self_pos,
			"loose puck → pressure the puck, don't freeze at self_pos")
	assert_true(d.target_position.z >= -0.01,
			"chosen target is goal-side of the loose puck; got z=%f" % d.target_position.z)


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


# ── Target switch-hysteresis ────────────────────────────────────────────────

func test_standing_target_sticks_within_margin() -> void:
	# A standing target whose re-scored value is within TARGET_SWITCH_MARGIN
	# of the fresh argmax is kept — the anti-flicker guarantee. Solo carrier,
	# straight shot: first decide picks a spot on the shot lane; a prev
	# target nudged 0.15 m along the same lane blocks essentially the same
	# shot, so decide must return the prev, not re-jump to the argmax.
	# (0.15 m, not more: the release-contest read grades distance from the
	# carrier's blade steeply — one stick length spans full-to-no contest —
	# so "near-equal" on this lane is a genuinely small span.)
	var carrier_pos := Vector3(0, 0, 22)
	var skaters: Array = [
		[1, TEAM_ID, Vector3(8, 0, 18), Vector3.ZERO],
		[200, 1 - TEAM_ID, carrier_pos, Vector3.ZERO],
	]
	var ctx: RoleContext = _make_ctx(Vector3(8, 0, 18), 200, skaters)
	var first: Vector3 = AIRolePressure.decide(ctx).target_position
	var prev: Vector3 = first + Vector3(0, 0, 0.15)  # a hair deeper on the lane
	var ctx2: RoleContext = _make_ctx(Vector3(8, 0, 18), 200, skaters)
	ctx2.prev_role_target = prev
	var second: Vector3 = AIRolePressure.decide(ctx2).target_position
	assert_eq(second, prev,
			"a near-equal standing target is kept through hysteresis")


func test_standing_target_dropped_when_clearly_beaten() -> void:
	# A standing target well off the shot lane blocks nothing; the fresh
	# argmax beats it past the margin and the pressurer re-anchors.
	var carrier_pos := Vector3(0, 0, 22)
	var skaters: Array = [
		[1, TEAM_ID, Vector3(8, 0, 18), Vector3.ZERO],
		[200, 1 - TEAM_ID, carrier_pos, Vector3.ZERO],
	]
	var ctx: RoleContext = _make_ctx(Vector3(8, 0, 18), 200, skaters)
	ctx.prev_role_target = Vector3(9.0, 0, 23.5)  # goal-side but far off the lane
	var target: Vector3 = AIRolePressure.decide(ctx).target_position
	assert_ne(target, ctx.prev_role_target,
			"a clearly-beaten standing target is abandoned")
	assert_lt(absf(target.x), 3.5, "re-anchors onto the shot lane")


func test_standing_target_ignored_when_wrong_side() -> void:
	# A standing target that fails the goal-side filter (carrier skated past
	# it) is dropped outright — hysteresis never holds a lost position.
	var carrier_pos := Vector3(0, 0, 22)
	var skaters: Array = [
		[1, TEAM_ID, Vector3(0, 0, 18), Vector3.ZERO],
		[200, 1 - TEAM_ID, carrier_pos, Vector3.ZERO],
	]
	var ctx: RoleContext = _make_ctx(Vector3(0, 0, 18), 200, skaters)
	ctx.prev_role_target = Vector3(0, 0, 20.0)  # opp-net side of the carrier
	var target: Vector3 = AIRolePressure.decide(ctx).target_position
	assert_true(target.z >= carrier_pos.z - 0.01,
			"wrong-side standing target is ignored, argmax runs fresh")


func test_candidate_set_includes_inner_ring() -> void:
	# PRESSURE samples at half step too (18 candidates: center + self +
	# 8 outer + 8 inner) so the cut-off can correct in small moves.
	var candidates: Array[Vector3] = AIRoleHelpers.generate_candidates_around(
			Vector3.ZERO, Vector3(5, 0, 5), true)
	assert_eq(candidates.size(), 18)
	var default_set: Array[Vector3] = AIRoleHelpers.generate_candidates_around(
			Vector3.ZERO, Vector3(5, 0, 5))
	assert_eq(default_set.size(), 10, "inner ring is opt-in")


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


# ── The last-man step-up clamp (AIRoleHelpers.settable_stand_depth) ──────────
# PRESSURE's cut-off sits one stick goal-side of where the carrier is GOING —
# a challenge position, and the right one while a layer is home behind. As the
# genuine LAST man it is also a step-up, and a rush at pace is exactly when that
# step-up cannot be made.
#
# That bound is now RETIRED for a live carrier and survives only for a loose puck
# — see test_the_last_man_bound_is_retired_for_a_live_carrier below for why. What
# these pin instead is the GAP LADDER (docs/transition-defense-plan.md §6), which
# PRESSURE never had: ~3 sticks at their blue line, 1 stick at ours, "1 stick /
# contact — you are on him" inside our own zone. §2.5 is the sentence it restores
# — "the D who gapped a carrier through the neutral zone KEEPS HIM into the zone;
# there is no handoff at the line" — since RUSH_D1 and PRESSURE now size the same
# gap off the same ladder.
#
# These pin the DOCTRINE, not the arithmetic. The clamp has been re-derived twice
# and then retired; the properties below are what must survive any version.

# Depth of the chosen stand, goal-side of the carrier along the carrier→our-net
# line. Larger = deeper = further from the carrier.
func _stand_depth(d: RoleDecision, carrier: Vector3) -> float:
	var to_net: Vector3 = Vector3(0.0, 0.0, OUR_NET_Z) - carrier
	var n: float = sqrt(to_net.x * to_net.x + to_net.z * to_net.z)
	if n < 0.001:
		return 0.0
	return ((d.target_position.x - carrier.x) * to_net.x
			+ (d.target_position.z - carrier.z) * to_net.z) / n


# A last man 12 m goal-side of a carrier flying at our net, vs the same
# geometry with a teammate home behind him.
func _rush_ctx(support_behind: bool, carrier_speed: float) -> Dictionary:
	return _rush_ctx_at(Vector3(0.0, 0.0, 0.0), carrier_speed, support_behind)


# The same, with the carrier placed explicitly — the ladder is a function of
# where he is, so its cases need to move him.
func _rush_ctx_at(carrier: Vector3, carrier_speed: float,
		support_behind: bool = true) -> Dictionary:
	var self_pos := Vector3(0.0, 0.0, 12.0)
	var vel := Vector3(0.0, 0.0, carrier_speed)
	var skaters: Array = [
			[1, TEAM_ID, self_pos],
			[200, 1 - TEAM_ID, carrier, vel],
	]
	if support_behind:
		skaters.append([2, TEAM_ID, Vector3(0.0, 0.0, 22.0)])
	var ctx: RoleContext = _make_ctx(self_pos, 200, skaters)
	ctx.self_max_speed = 9.0
	# Keep the body-check path out of it — this is about the stand.
	ctx.check_aggression = 0.0
	return {"ctx": ctx, "carrier": carrier}


func test_the_stand_is_the_gap_ladder() -> void:
	# The doctrine distance, and the defect it replaced. PRESSURE used to hold a
	# fixed one-stick stand-off measured off the carrier's LED position, so the
	# real cushion was `one stick + pace x lookahead` — 3+ sticks at a rush pace,
	# which is docs/transition-defense-plan.md §2.4 verbatim: "the correct gap for
	# the offensive blue line, applied at the defensive blue line". The ladder
	# (§6) is a function of ICE REMAINING and reads ~1 stick in our own zone.
	var ctx: Dictionary = _rush_ctx(true, 7.0)
	var d: RoleDecision = AIRolePressure.decide(ctx["ctx"])
	var want: float = AIRoleRushD.ladder_gap_m(
			ctx["carrier"], 1.0, ctx["ctx"].self_blade_reach, 7.0)
	assert_almost_eq(_stand_depth(d, ctx["carrier"]), want, 1.2,
			"the cut-off distance is the gap ladder; wanted ~%.2f m" % want)


func test_the_ladder_tightens_as_the_carrier_gets_deeper() -> void:
	# ~3 sticks at their blue line, 1 stick at ours. The old fixed stand-off could
	# not express this at all, which is why the bot held an O-zone gap at its own
	# net.
	var far: Dictionary = _rush_ctx_at(Vector3(0.0, 0.0, -7.29), 7.0)
	var near: Dictionary = _rush_ctx_at(Vector3(0.0, 0.0, 7.29), 7.0)
	assert_gt(_stand_depth(AIRolePressure.decide(far["ctx"]), far["carrier"]),
			_stand_depth(AIRolePressure.decide(near["ctx"]), near["carrier"]),
			"the gap must tighten as the carrier eats the ice")


func test_the_stand_rides_the_carrier() -> void:
	# The route is flown in the carrier's frame (AISteering's moving-frame
	# pursuit), which is what lets a ~1-stick gap be HELD rather than lunged at.
	var ctx: Dictionary = _rush_ctx(true, 7.0)
	var d: RoleDecision = AIRolePressure.decide(ctx["ctx"])
	assert_almost_eq(d.target_velocity.z, 7.0, 0.01,
			"the cut-off rides the man it is cutting off")
	assert_eq(d.engaged_peer_id, 200,
			"the man we are closing on is dropped from the proximity repel")


func test_the_last_man_bound_is_retired_for_a_live_carrier() -> void:
	# It exists because a parked-point seek could only reach a stand by charging
	# it; the moving-frame route regulates the approach instead, so running both
	# is two controllers on one axis — and the second wins in the worst place, by
	# naming a stand at wherever the body already is. That is what walked the
	# pressurer to his own goal line: a defender whose stand is always where he
	# stands can never close, so the carrier simply pushes him back. Same
	# retirement, same reason, as AIRoleRushD._settable_gap.
	var alone: Dictionary = _rush_ctx(false, 7.0)
	var layered: Dictionary = _rush_ctx(true, 7.0)
	assert_almost_eq(
			_stand_depth(AIRolePressure.decide(alone["ctx"]), alone["carrier"]),
			_stand_depth(AIRolePressure.decide(layered["ctx"]), layered["carrier"]),
			0.05, "the last man reads the ladder, not a depth bound")


func test_a_loose_puck_keeps_the_last_man_bound() -> void:
	# No man to ride means the route is a point seek again, and the trip to the
	# stand genuinely needs bounding.
	var alone: Dictionary = _rush_ctx(false, 7.0)
	alone["ctx"].snapshot.puck_state.carrier_peer_id = -1
	alone["ctx"].snapshot.puck_state.position = alone["carrier"]
	alone["ctx"].snapshot.puck_state.velocity = Vector3(0.0, 0.0, 7.0)
	var layered: Dictionary = _rush_ctx(true, 7.0)
	layered["ctx"].snapshot.puck_state.carrier_peer_id = -1
	layered["ctx"].snapshot.puck_state.position = layered["carrier"]
	layered["ctx"].snapshot.puck_state.velocity = Vector3(0.0, 0.0, 7.0)
	var bounded: float = _stand_depth(
			AIRolePressure.decide(alone["ctx"]), alone["carrier"])
	var free: float = _stand_depth(
			AIRolePressure.decide(layered["ctx"]), layered["carrier"])
	assert_gt(bounded, free,
			"the last man still holds ice he cannot cover set; %.2f vs %.2f"
			% [bounded, free])
