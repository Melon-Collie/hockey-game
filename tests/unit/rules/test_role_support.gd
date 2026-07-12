extends GutTest

# AIRoleSupport's decide() is mostly an integration of existing
# scoring primitives (score_pass + time_to_arrive) over a candidate
# set. These tests cover the structural contracts:
#   - Bail-out cases (no carrier / opp carrier).
#   - Anti-crowding filter.
#   - Argmax actually picks something non-degenerate.
#   - Exposure penalizes deeper candidates when opps threaten recovery.
#
# The geometric details of score_pass / time_to_arrive are already
# covered in test_ai_action_scoring; we don't re-test them here.

const TEAM_ID: int = 0
const OUR_NET_Z: float = 26.65   # Team 0 defends +Z
const OPP_NET_Z: float = -OUR_NET_Z


func _make_ctx(self_pos: Vector3, anchor: Vector3, carrier_pid: int = -1,
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
	ctx.attacking_goal_pos = Vector3(0.0, 0.0, OPP_NET_Z)
	ctx.defending_goal_pos = Vector3(0.0, 0.0, OUR_NET_Z)
	ctx.own_goal_dir = 1.0
	ctx.anchor = anchor
	ctx.team_id_by_peer = team_map
	return ctx


# ── Bail-out cases ──────────────────────────────────────────────────────────

func test_supports_loose_puck_instead_of_freezing() -> void:
	# Loose puck (breakout pass in flight). SUPPORT used to freeze at
	# self_pos — the "stuck on the heels" bug. It must now read off the
	# puck and present a support option. Bot starts buried deep in our
	# own end; target must advance toward the play, never self_pos.
	var self_pos := Vector3(10, 0, 22)   # buried deep in our own end
	var ctx: RoleContext = _make_ctx(self_pos, Vector3.ZERO)   # loose puck at origin
	var d: RoleDecision = AIRoleSupport.decide(ctx)
	assert_ne(d.target_position, self_pos,
			"loose puck → support the play, don't freeze at self_pos")
	assert_lt(d.target_position.z, self_pos.z,
			"target advances toward the puck / opp net; got z=%f" % d.target_position.z)


func test_falls_back_to_self_pos_when_opp_has_puck() -> void:
	var self_pos := Vector3(0, 0, -16)
	var skaters: Array = [
		[1, TEAM_ID, self_pos, Vector3.ZERO],
		[200, 1 - TEAM_ID, Vector3(0, 0, -10), Vector3.ZERO],
	]
	var ctx: RoleContext = _make_ctx(self_pos, Vector3.ZERO, 200, skaters)
	var d: RoleDecision = AIRoleSupport.decide(ctx)
	assert_eq(d.target_position, self_pos,
			"opp carrier → no offensive context, fall back to self_pos")


# ── Argmax produces a valid pick ────────────────────────────────────────────

func test_returns_a_legal_position_when_carrier_is_teammate() -> void:
	var carrier_pos := Vector3(-5, 0, -22)
	var skaters: Array = [
		[1, TEAM_ID, Vector3(0, 0, -10), Vector3.ZERO],   # us (SUPPORT)
		[100, TEAM_ID, carrier_pos, Vector3.ZERO],        # carrier
	]
	var ctx: RoleContext = _make_ctx(Vector3(0, 0, -10), Vector3.ZERO, 100, skaters)
	var d: RoleDecision = AIRoleSupport.decide(ctx)
	assert_true(absf(d.target_position.x) <= GameRules.RINK_HALF_WIDTH,
			"x within rink")
	assert_true(absf(d.target_position.z) <= GameRules.GOAL_LINE_Z,
			"z within goal line bounds")


# ── Safety valve: stays goal-side of the carrier ────────────────────────────

func test_stays_goal_side_of_carrier() -> void:
	# SUPPORT is the conservative safety valve: even starting up-ice
	# (ahead of the carrier toward the opp net) where the cleanest
	# pass/shot would sit, it must pick a position goal-side of the
	# carrier so the carrier is never the last man back. Team 0 attacks
	# -Z / defends +Z, so own_goal_dir * z grows toward our net.
	var carrier_pos := Vector3(0, 0, 5)        # breaking out, our half
	var self_pos := Vector3(3, 0, -12)         # up-ice, ahead of the carrier
	var skaters: Array = [
		[1, TEAM_ID, self_pos, Vector3.ZERO],          # us (SUPPORT)
		[100, TEAM_ID, carrier_pos, Vector3.ZERO],     # carrier
	]
	var ctx: RoleContext = _make_ctx(self_pos, Vector3.ZERO, 100, skaters)
	var d: RoleDecision = AIRoleSupport.decide(ctx)
	assert_true(
			ctx.own_goal_dir * d.target_position.z
				>= ctx.own_goal_dir * carrier_pos.z - AIRoleSupport.GOAL_SIDE_TOLERANCE_M - 0.01,
			"SUPPORT must stay goal-side of the carrier; got target.z=%f vs carrier.z=%f"
				% [d.target_position.z, carrier_pos.z])
	assert_gt(d.target_position.z, self_pos.z,
			"SUPPORT drops back from an up-ice start toward the safety position")


# ── Anti-crowding ───────────────────────────────────────────────────────────

func test_anti_crowding_avoids_candidates_near_teammates() -> void:
	# Place a 3rd teammate squarely on a candidate position generated
	# by the polar pattern around the carrier (at 5m on the +Z axis
	# from carrier — that's "behind toward our net" for Team 0).
	# That candidate gets anti-crowd-filtered; chosen target must be
	# at least ANTI_CROWD_RADIUS_M away from the squatting teammate.
	var carrier_pos := Vector3(0, 0, -22)
	var crowding_teammate_pos := Vector3(carrier_pos.x,
			0.0, carrier_pos.z + AIRoleSupport.SEARCH_RADIUS_M)  # exact polar sample location
	var skaters: Array = [
		[1, TEAM_ID, Vector3(8, 0, 0), Vector3.ZERO],            # us, off to the side
		[100, TEAM_ID, carrier_pos, Vector3.ZERO],               # carrier
		[110, TEAM_ID, crowding_teammate_pos, Vector3.ZERO],     # squatting on a candidate
	]
	var ctx: RoleContext = _make_ctx(Vector3(8, 0, 0), Vector3.ZERO, 100, skaters)
	var d: RoleDecision = AIRoleSupport.decide(ctx)
	var dist_to_teammate: float = d.target_position.distance_to(crowding_teammate_pos)
	assert_gt(dist_to_teammate, AIRoleHelpers.ANTI_CROWD_RADIUS_M - 0.01,
			"chosen target must clear the anti-crowd radius around the teammate")


# ── Exposure: deeper candidates penalized when opps threaten recovery ───────

func test_exposure_pulls_target_higher_when_opp_threatens_recovery() -> void:
	# Same SUPPORT/carrier setup with and without a back-checking
	# opp near our blue line. Without the threat, score is dominated
	# by score_pass. With the threat, exposure penalizes deep
	# candidates and the chosen position should be no deeper.
	var support_pos := Vector3(0, 0, -10)
	var carrier_pos := Vector3(-5, 0, -22)

	var skaters_no_threat: Array = [
		[1, TEAM_ID, support_pos, Vector3.ZERO],
		[100, TEAM_ID, carrier_pos, Vector3.ZERO],
	]
	var ctx_a: RoleContext = _make_ctx(support_pos, Vector3.ZERO, 100, skaters_no_threat)
	var no_threat_target: Vector3 = AIRoleSupport.decide(ctx_a).target_position

	var skaters_threat: Array = [
		[1, TEAM_ID, support_pos, Vector3.ZERO],
		[100, TEAM_ID, carrier_pos, Vector3.ZERO],
		[200, 1 - TEAM_ID, Vector3(0, 0, OUR_NET_Z - 10), Vector3(0, 0, 8)],
	]
	var ctx_b: RoleContext = _make_ctx(support_pos, Vector3.ZERO, 100, skaters_threat)
	var threat_target: Vector3 = AIRoleSupport.decide(ctx_b).target_position

	assert_true(threat_target.z >= no_threat_target.z - 0.01,
			"opp threatening home should pull SUPPORT no deeper than baseline;"
			+ " got threat=%s baseline=%s" % [threat_target, no_threat_target])


# ── No-opps edge case ───────────────────────────────────────────────────────

func test_no_opponents_means_no_exposure_penalty() -> void:
	var carrier_pos := Vector3(-5, 0, -22)
	var skaters: Array = [
		[1, TEAM_ID, Vector3(0, 0, -10), Vector3.ZERO],
		[100, TEAM_ID, carrier_pos, Vector3.ZERO],
	]
	var ctx: RoleContext = _make_ctx(Vector3(0, 0, -10), Vector3.ZERO, 100, skaters)
	var d: RoleDecision = AIRoleSupport.decide(ctx)
	assert_true(absf(d.target_position.x) <= GameRules.RINK_HALF_WIDTH)
	assert_true(absf(d.target_position.z) <= GameRules.GOAL_LINE_Z)


func _opp(pos: Vector3) -> SkaterNetworkState:
	var s := SkaterNetworkState.new()
	s.position = pos
	return s


func _speed_caps(v: float) -> AISkaterCaps:
	var c := AISkaterCaps.new()
	c.max_speed = v
	return c


func test_min_opp_time_home_uses_each_opponents_real_speed() -> void:
	# One opponent, fixed position. A faster opponent (higher Speed) recovers to
	# our net in less time — SUPPORT reads a shorter min-time-home.
	var net := Vector3(0, 0, OUR_NET_Z)
	var opps: Array[SkaterNetworkState] = [_opp(Vector3(0, 0, 0))]
	var slow: float = AIRoleSupport._min_opp_time_home(opps, [_speed_caps(6.0)], net)
	var fast: float = AIRoleSupport._min_opp_time_home(opps, [_speed_caps(14.0)], net)
	assert_lt(fast, slow, "a faster opponent recovers home sooner")


func test_exposure_lower_for_a_faster_defender() -> void:
	# Same candidate and opponent-recovery time, but a faster ME (Speed) beats the
	# puck back from that spot more easily → less exposure.
	var net := Vector3(0, 0, OUR_NET_Z)
	var candidate := Vector3(0, 0, 0)  # ~26.65 m from our net
	var min_home: float = 3.0
	var slow_me: float = AIRoleSupport._exposure(candidate, net, min_home, 6.0)
	var fast_me: float = AIRoleSupport._exposure(candidate, net, min_home, 14.0)
	assert_lt(fast_me, slow_me, "a faster defender is less exposed from the same spot")


# ── Third man HIGH in the offensive zone ─────────────────────────────────────

func test_plays_the_high_post_when_the_carrier_works_the_oz_corner() -> void:
	# Carrier cycling deep in the OZ corner. The old candidate set orbited the
	# carrier (5 m), structurally gluing the third man to the play — the
	# "SUPPORT pinches too hard" failure that left nobody back on a turnover.
	# The OZ station is now the HIGH POST: top of the zone, near the blue line.
	var carrier_pos := Vector3(-9, 0, -23)     # deep left corner (attacking -Z)
	var self_pos := Vector3(-5, 0, -18)        # currently pinched low
	var skaters: Array = [
		[1, TEAM_ID, self_pos, Vector3.ZERO],          # us (SUPPORT)
		[100, TEAM_ID, carrier_pos, Vector3.ZERO],     # carrier in the corner
		[200, 1, Vector3(-6, 0, -21), Vector3.ZERO],   # defenders collapsed low
		[210, 1, Vector3(-2, 0, -23), Vector3.ZERO],
	]
	var ctx: RoleContext = _make_ctx(self_pos, Vector3.ZERO, 100, skaters)
	var d: RoleDecision = AIRoleSupport.decide(ctx)
	assert_gt(d.target_position.distance_to(carrier_pos), AIRoleSupport.SEARCH_RADIUS_M + 1.0,
			"the third man is no longer glued to the carrier's orbit; got %s"
			% str(d.target_position))
	assert_lt(absf(d.target_position.z - (-GameRules.BLUE_LINE_Z)),
			AIRoleSupport.HIGH_POST_INSET_M + AIRoleSupport.SEARCH_RADIUS_M + 0.5,
			"…and holds the top of the zone (high post); got z=%f" % d.target_position.z)


func test_transition_keeps_the_carrier_orbit_trail() -> void:
	# Carrier still in the neutral zone (TRANS_DO): the high post would be
	# ahead of the play, so SUPPORT keeps the old goal-side trail orbit.
	var carrier_pos := Vector3(0, 0, -2)
	var self_pos := Vector3(3, 0, 2)
	var skaters: Array = [
		[1, TEAM_ID, self_pos, Vector3.ZERO],
		[100, TEAM_ID, carrier_pos, Vector3.ZERO],
	]
	var ctx: RoleContext = _make_ctx(self_pos, Vector3.ZERO, 100, skaters)
	var d: RoleDecision = AIRoleSupport.decide(ctx)
	assert_lt(d.target_position.distance_to(carrier_pos),
			AIRoleSupport.SEARCH_RADIUS_M + 1.0,
			"in transition SUPPORT trails within the carrier orbit; got %s"
			% str(d.target_position))
