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
	ctx.attacking_goal_pos = Vector3(0.0, 0.0, OPP_NET_Z)
	ctx.defending_goal_pos = Vector3(0.0, 0.0, OUR_NET_Z)
	ctx.own_goal_dir = 1.0
	ctx.team_id_by_peer = team_map
	return ctx


# ── Bail-out cases ──────────────────────────────────────────────────────────

func test_supports_loose_puck_instead_of_freezing() -> void:
	# Loose puck (breakout pass in flight). SUPPORT used to freeze at
	# self_pos — the "stuck on the heels" bug. It must now read off the
	# puck and present a support option. Bot starts buried deep in our
	# own end; target must advance toward the play, never self_pos.
	var self_pos := Vector3(10, 0, 22)   # buried deep in our own end
	var ctx: RoleContext = _make_ctx(self_pos)   # loose puck at origin
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
	var ctx: RoleContext = _make_ctx(self_pos, 200, skaters)
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
	var ctx: RoleContext = _make_ctx(Vector3(0, 0, -10), 100, skaters)
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
	var ctx: RoleContext = _make_ctx(self_pos, 100, skaters)
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
	var ctx: RoleContext = _make_ctx(Vector3(8, 0, 0), 100, skaters)
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
	var ctx_a: RoleContext = _make_ctx(support_pos, 100, skaters_no_threat)
	var no_threat_target: Vector3 = AIRoleSupport.decide(ctx_a).target_position

	var skaters_threat: Array = [
		[1, TEAM_ID, support_pos, Vector3.ZERO],
		[100, TEAM_ID, carrier_pos, Vector3.ZERO],
		[200, 1 - TEAM_ID, Vector3(0, 0, OUR_NET_Z - 10), Vector3(0, 0, 8)],
	]
	var ctx_b: RoleContext = _make_ctx(support_pos, 100, skaters_threat)
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
	var ctx: RoleContext = _make_ctx(Vector3(0, 0, -10), 100, skaters)
	var d: RoleDecision = AIRoleSupport.decide(ctx)
	assert_true(absf(d.target_position.x) <= GameRules.RINK_HALF_WIDTH)
	assert_true(absf(d.target_position.z) <= GameRules.GOAL_LINE_Z)


func test_covering_self_erases_the_counter_from_a_recoverable_spot() -> void:
	# The covering-set contract at SUPPORT's seam (counter_rush_cost with
	# SUPPORT itself as the per-candidate racer): same loss, same collector —
	# standing where SUPPORT beats the counter home erases the threat (self
	# joins the covering set, the counter shot is a blocked look), while
	# standing past the play leaves it live. This is what replaced the old
	# my_time/safe_time ramp: who COVERS, not who wins a footrace ratio.
	var net := Vector3(0, 0, OUR_NET_Z)
	var goalie := Vector3(0, 0, OUR_NET_Z - 0.8)
	var loss := Vector3(0, 0, 0)                      # turnover at center ice
	var opps: Array[Vector3] = [Vector3(1, 0, 1)]     # collector on the puck
	var vels: Array[Vector3] = [Vector3.ZERO]
	var no_mates: Array[Vector3] = []
	var recoverable: float = AIActionScoring.counter_rush_cost(
			loss, 1.0, net, goalie, GameRules.NET_HALF_WIDTH, no_mates,
			Vector3(0, 0, 14), AIActionScoring.SKATER_REF_SPEED_M_S,
			opps, vels, [])
	var exposed: float = AIActionScoring.counter_rush_cost(
			loss, 1.0, net, goalie, GameRules.NET_HALF_WIDTH, no_mates,
			Vector3(0, 0, -15), AIActionScoring.SKATER_REF_SPEED_M_S,
			opps, vels, [])
	assert_gt(exposed, 0.25,
			"a spot past the play leaves the counter live; got %f" % exposed)
	assert_lt(recoverable, exposed * 0.5,
			"covering the counter point collapses the threat (one body walls "
			+ "most of the slot look); recoverable=%f exposed=%f"
			% [recoverable, exposed])


func test_crease_lurker_does_not_zero_the_high_stations() -> void:
	# The covering-set replacement's headline fix: a beaten opponent parked at
	# OUR crease gave the old body-ETA ramp a ~0 time-home, which zeroed every
	# OZ station's score (the full-veto exposure) and degenerated the argmax.
	# Under the covering-set read the lurker is no counter threat at all — he
	# must skate the length of the rink to collect a loss at the carrier and
	# all the way back — so the third man plays his normal high station and
	# leaves the lurker to the goalie.
	var carrier_pos := Vector3(-9, 0, -23)
	var self_pos := Vector3(-5, 0, -14)
	var skaters: Array = [
		[1, TEAM_ID, self_pos, Vector3.ZERO],
		[100, TEAM_ID, carrier_pos, Vector3.ZERO],
		[200, 1, Vector3(-7.8, 0, -21.8), Vector3.ZERO],       # cycle pressure on the carrier
		[210, 1, Vector3(0, 0, OUR_NET_Z - 2), Vector3.ZERO],  # crease lurker
	]
	var ctx: RoleContext = _make_ctx(self_pos, 100, skaters)
	_add_opp_goalie(ctx, carrier_pos)
	var d: RoleDecision = AIRoleSupport.decide(ctx)
	assert_lt(d.target_position.z, -8.0,
			"the third man keeps a real OZ station instead of hiding home;"
			+ " got %s" % d.target_position)




# A live opposing keeper challenging on the carrier's arc. Without him the
# fixtures model a keeper parked ON the goal line, against whom every
# doorstep feed saturates to certainty and every high station reads dead —
# inverting the staging these tests lock (same fix as the finisher fixtures).
func _add_opp_goalie(ctx: RoleContext, carrier_pos: Vector3) -> void:
	var g := GoalieNetworkState.new()
	var net := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)
	var dir: Vector3 = (carrier_pos - net).normalized()
	g.position_x = net.x + dir.x * 1.3
	g.position_z = net.z + dir.z * 1.3
	ctx.snapshot.goalie_states[1 - TEAM_ID] = g

# ── Third man HIGH in the offensive zone ─────────────────────────────────────

func test_swings_off_a_covered_high_post_to_a_live_outlet() -> void:
	# A defender parked on the carrier→high-post feed lane: the high post is
	# a dead outlet, so the third man stages an alternative station whose
	# feed lane is genuinely live (the half-wall bump / center point / weak
	# flank family) — value-arbitrated, not glued to one spot.
	var carrier_pos := Vector3(-9, 0, -23)
	var self_pos := Vector3(-5, 0, -14)
	var high_post := Vector3(
			carrier_pos.x * 0.5, 0.0,
			-GameRules.BLUE_LINE_Z - AIRoleSupport.HIGH_POST_INSET_M)
	var lane_blocker: Vector3 = (carrier_pos + high_post) * 0.5
	var skaters: Array = [
		[1, TEAM_ID, self_pos, Vector3.ZERO],
		[100, TEAM_ID, carrier_pos, Vector3.ZERO],
		[200, 1, lane_blocker, Vector3.ZERO],           # on the high-post lane
		[210, 1, Vector3(-2, 0, -23), Vector3.ZERO],
	]
	var ctx: RoleContext = _make_ctx(self_pos, 100, skaters)
	_add_opp_goalie(ctx, carrier_pos)
	# Keeper drawn OUT challenging the deep-corner carrier — the regime
	# where feed value genuinely differentiates stations. (A HOME keeper
	# pre-arms every feed to parity and staging is decided by the other
	# terms — the doctrine the backdoor pre-arm added.)
	var out_goalie: GoalieNetworkState = ctx.snapshot.goalie_states[1 - TEAM_ID]
	var net := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)
	var challenge: Vector3 = (carrier_pos - net).normalized() * 4.0
	out_goalie.position_x = net.x + challenge.x
	out_goalie.position_z = net.z + challenge.z
	var d: RoleDecision = AIRoleSupport.decide(ctx)
	var chosen_lane: float = AIActionScoring.lane_clear(
			carrier_pos, d.target_position, [lane_blocker],
			AIActionScoring.expected_pass_speed(carrier_pos, d.target_position))
	var post_lane: float = AIActionScoring.lane_clear(
			carrier_pos, high_post, [lane_blocker],
			AIActionScoring.expected_pass_speed(carrier_pos, high_post))
	assert_gt(chosen_lane, post_lane,
			"the chosen station's feed lane beats the covered high post's;"
			+ " got %s" % d.target_position)


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
	var ctx: RoleContext = _make_ctx(self_pos, 100, skaters)
	_add_opp_goalie(ctx, carrier_pos)
	var d: RoleDecision = AIRoleSupport.decide(ctx)
	assert_gt(d.target_position.distance_to(carrier_pos), AIRoleSupport.SEARCH_RADIUS_M + 1.0,
			"the third man is no longer glued to the carrier's orbit; got %s"
			% str(d.target_position))


func test_deep_trailer_tracks_the_rush_past_a_beaten_forechecker() -> void:
	# Transition D→O: our carrier has broken out to the NZ and is rushing, but a
	# beaten forechecker sits deep in OUR zone (near our net → tiny time-home).
	# The old saturating exposure zeroed every up-ice candidate, stranding the
	# deep trailer back in the D-zone ("the furthest player never joins the
	# transition"). Capped exposure keeps a floor of pass value on the up-ice
	# option, so the trailer follows the rush up behind the carrier (staying
	# goal-side of it) instead of sitting deep.
	var carrier_pos := Vector3(0, 0, 0)        # rushed out to the NZ
	var self_pos := Vector3(0, 0, 20)          # trailer still buried deep
	var skaters: Array = [
		[1, TEAM_ID, self_pos, Vector3.ZERO],              # us (SUPPORT), deep
		[100, TEAM_ID, carrier_pos, Vector3.ZERO],         # carrier at NZ
		[200, 1, Vector3(0, 0, OUR_NET_Z - 4), Vector3.ZERO],  # beaten forechecker, deep in our zone
	]
	var ctx: RoleContext = _make_ctx(self_pos, 100, skaters)
	var d: RoleDecision = AIRoleSupport.decide(ctx)
	assert_lt(d.target_position.z, self_pos.z - 8.0,
			"the deep trailer advances up toward the rush instead of stranding"
			+ " deep; got z=%f (self z=%f)" % [d.target_position.z, self_pos.z])
	# Still the safety valve — goal-side of (not ahead of) the carrier.
	assert_gte(ctx.own_goal_dir * d.target_position.z,
			ctx.own_goal_dir * carrier_pos.z - AIRoleSupport.GOAL_SIDE_TOLERANCE_M - 0.01,
			"…while staying goal-side of the carrier; got z=%f" % d.target_position.z)


func test_transition_keeps_the_carrier_orbit_trail() -> void:
	# Carrier still in the neutral zone (TRANS_OFFENSE): the high post would be
	# ahead of the play, so SUPPORT keeps the old goal-side trail orbit.
	var carrier_pos := Vector3(0, 0, -2)
	var self_pos := Vector3(3, 0, 2)
	var skaters: Array = [
		[1, TEAM_ID, self_pos, Vector3.ZERO],
		[100, TEAM_ID, carrier_pos, Vector3.ZERO],
	]
	var ctx: RoleContext = _make_ctx(self_pos, 100, skaters)
	var d: RoleDecision = AIRoleSupport.decide(ctx)
	assert_lt(d.target_position.distance_to(carrier_pos),
			AIRoleSupport.SEARCH_RADIUS_M + 1.0,
			"in transition SUPPORT trails within the carrier orbit; got %s"
			% str(d.target_position))
