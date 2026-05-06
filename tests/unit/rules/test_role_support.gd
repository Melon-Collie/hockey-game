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
	ctx.team_id_resolver = func(pid: int) -> int: return int(team_map.get(pid, -1))
	return ctx


# ── Bail-out cases ──────────────────────────────────────────────────────────

func test_falls_back_to_anchor_when_no_carrier() -> void:
	# Default snapshot: just self, no puck carrier.
	var anchor := Vector3(0, 0, -16)
	var ctx: RoleContext = _make_ctx(Vector3(0, 0, -10), anchor)
	var d: RoleDecision = AIRoleSupport.decide(ctx)
	assert_eq(d.target_position, anchor,
			"no carrier → fall back to anchor")


func test_falls_back_to_anchor_when_opp_has_puck() -> void:
	var anchor := Vector3(0, 0, -16)
	var skaters: Array = [
		[1, TEAM_ID, Vector3(0, 0, -16), Vector3.ZERO],
		[200, 1 - TEAM_ID, Vector3(0, 0, -10), Vector3.ZERO],
	]
	var ctx: RoleContext = _make_ctx(Vector3(0, 0, -16), anchor, 200, skaters)
	var d: RoleDecision = AIRoleSupport.decide(ctx)
	assert_eq(d.target_position, anchor,
			"opp carrier → no offensive context, fall back to anchor")


# ── Argmax produces a valid pick ────────────────────────────────────────────

func test_returns_a_position_when_carrier_is_teammate() -> void:
	var anchor := Vector3(0, 0, -16)
	var carrier_pos := Vector3(-5, 0, -22)
	var skaters: Array = [
		[1, TEAM_ID, Vector3(0, 0, -10), Vector3.ZERO],   # us (SUPPORT)
		[100, TEAM_ID, carrier_pos, Vector3.ZERO],        # carrier
	]
	var ctx: RoleContext = _make_ctx(Vector3(0, 0, -10), anchor, 100, skaters)
	var d: RoleDecision = AIRoleSupport.decide(ctx)
	# Should be a non-zero in-rink position.
	assert_true(absf(d.target_position.x) <= GameRules.RINK_HALF_WIDTH,
			"x within rink")
	assert_true(absf(d.target_position.z) <= GameRules.GOAL_LINE_Z,
			"z within goal line bounds")


# ── Anti-crowding ───────────────────────────────────────────────────────────

func test_anti_crowding_avoids_candidates_near_teammates() -> void:
	# Anchor and a 3rd teammate sit on top of each other. Polar
	# samples around the anchor are mostly within ANTI_CROWD_RADIUS
	# of that teammate too. SUPPORT must pick the farthest sample
	# (or self) — never within ANTI_CROWD_RADIUS of the teammate.
	var anchor := Vector3(0, 0, -16)
	var teammate_at_anchor := anchor   # squatting on the anchor
	var skaters: Array = [
		[1, TEAM_ID, Vector3(8, 0, -10), Vector3.ZERO],         # us, off to the side
		[100, TEAM_ID, Vector3(-5, 0, -22), Vector3.ZERO],      # carrier
		[110, TEAM_ID, teammate_at_anchor, Vector3.ZERO],       # blocking the anchor
	]
	var ctx: RoleContext = _make_ctx(Vector3(8, 0, -10), anchor, 100, skaters)
	var d: RoleDecision = AIRoleSupport.decide(ctx)
	var dist_to_teammate: float = d.target_position.distance_to(teammate_at_anchor)
	# Allow a tiny float-rounding margin below the radius.
	assert_gt(dist_to_teammate, AIRoleHelpers.ANTI_CROWD_RADIUS_M - 0.01,
			"chosen target must clear the anti-crowd radius around the teammate")


# ── Exposure: deeper candidates penalized when opps threaten recovery ───────

func test_exposure_pulls_target_higher_when_opp_threatens_recovery() -> void:
	# Same SUPPORT/carrier setup with and without a back-checking
	# opp near our blue line. Without the threat, score is dominated
	# by score_pass (deeper candidates score well). With the threat,
	# exposure penalizes deep candidates and the chosen position
	# should be no deeper.
	#
	# "Deeper" here means closer to the opp goal — more negative z
	# (Team 0's attacking goal is at -Z).
	var anchor := Vector3(0, 0, -16)
	var support_pos := Vector3(0, 0, -10)
	var carrier_pos := Vector3(-5, 0, -22)

	var skaters_no_threat: Array = [
		[1, TEAM_ID, support_pos, Vector3.ZERO],
		[100, TEAM_ID, carrier_pos, Vector3.ZERO],
	]
	var ctx_a: RoleContext = _make_ctx(support_pos, anchor, 100, skaters_no_threat)
	var no_threat_target: Vector3 = AIRoleSupport.decide(ctx_a).target_position

	# Add a back-checking opp NEAR our net with high velocity toward
	# our goal — short ETA home, exposure for any deep candidate.
	var skaters_threat: Array = [
		[1, TEAM_ID, support_pos, Vector3.ZERO],
		[100, TEAM_ID, carrier_pos, Vector3.ZERO],
		[200, 1 - TEAM_ID, Vector3(0, 0, OUR_NET_Z - 10), Vector3(0, 0, 8)],
	]
	var ctx_b: RoleContext = _make_ctx(support_pos, anchor, 100, skaters_threat)
	var threat_target: Vector3 = AIRoleSupport.decide(ctx_b).target_position

	# threat_target.z should be GREATER (less negative — closer to NZ)
	# than no_threat_target.z. Looser assertion: not deeper.
	assert_true(threat_target.z >= no_threat_target.z - 0.01,
			"opp threatening home should pull SUPPORT no deeper than baseline; got threat=%s baseline=%s" % [threat_target, no_threat_target])


# ── No-opps edge case ───────────────────────────────────────────────────────

func test_no_opponents_means_no_exposure_penalty() -> void:
	# With no opps, exposure factor = (1 - 0) = 1.0 for every
	# candidate, so score = score_pass. argmax picks the
	# best-score_pass candidate.
	var anchor := Vector3(0, 0, -16)
	var carrier_pos := Vector3(-5, 0, -22)
	var skaters: Array = [
		[1, TEAM_ID, Vector3(0, 0, -10), Vector3.ZERO],
		[100, TEAM_ID, carrier_pos, Vector3.ZERO],
	]
	var ctx: RoleContext = _make_ctx(Vector3(0, 0, -10), anchor, 100, skaters)
	# Just verify decide() doesn't crash and picks something legal.
	var d: RoleDecision = AIRoleSupport.decide(ctx)
	assert_true(absf(d.target_position.x) <= GameRules.RINK_HALF_WIDTH)
	assert_true(absf(d.target_position.z) <= GameRules.GOAL_LINE_Z)
