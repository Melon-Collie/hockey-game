extends GutTest

# AIRoleHelpers target switch-hysteresis — the shared off-puck argmax stickiness
# (append_incumbent / incumbent_bonus / TARGET_SWITCH_MARGIN). Covers the pure
# helpers directly, then the black-box guarantee at a converted role (SUPPORT):
# a near-tied standing spot is held; a clearly-beaten one is dropped. Per-role
# scoring lives in each role's own test; this pins the shared mechanism.

const TEAM_ID: int = 0
const OUR_NET_Z: float = 26.65   # Team 0 defends +Z


func _bare_ctx() -> RoleContext:
	var ctx := RoleContext.new()
	ctx.prev_role_target = Vector3.INF
	return ctx


# ── append_incumbent ─────────────────────────────────────────────────────────

func test_append_incumbent_adds_finite_prev_target() -> void:
	var ctx: RoleContext = _bare_ctx()
	ctx.prev_role_target = Vector3(3, 0, -5)
	var candidates: Array[Vector3] = [Vector3.ZERO, Vector3(1, 0, 1)]
	AIRoleHelpers.append_incumbent(ctx, candidates)
	assert_eq(candidates.size(), 3, "the incumbent is injected as an extra candidate")
	assert_eq(candidates[2], Vector3(3, 0, -5), "…at exactly the standing target")


func test_append_incumbent_noop_without_incumbent() -> void:
	# INF (first dispatch / slot change) injects nothing.
	var ctx: RoleContext = _bare_ctx()
	var candidates: Array[Vector3] = [Vector3.ZERO]
	AIRoleHelpers.append_incumbent(ctx, candidates)
	assert_eq(candidates.size(), 1, "no incumbent → no injection")


# ── incumbent_bonus ──────────────────────────────────────────────────────────

func test_incumbent_bonus_only_for_the_standing_target() -> void:
	var ctx: RoleContext = _bare_ctx()
	ctx.prev_role_target = Vector3(3, 0, -5)
	assert_eq(AIRoleHelpers.incumbent_bonus(ctx, Vector3(3, 0, -5)),
			AIRoleHelpers.TARGET_SWITCH_MARGIN, "the standing spot earns the margin bonus")
	assert_eq(AIRoleHelpers.incumbent_bonus(ctx, Vector3(3.1, 0, -5)), 0.0,
			"a different spot earns nothing")


func test_incumbent_bonus_zero_without_incumbent() -> void:
	var ctx: RoleContext = _bare_ctx()
	# No candidate is ever == INF, so the bonus is always 0.
	assert_eq(AIRoleHelpers.incumbent_bonus(ctx, Vector3(3, 0, -5)), 0.0,
			"no incumbent → no bonus")


# ── Black-box: hysteresis at a converted role (SUPPORT) ──────────────────────

func _support_ctx(self_pos: Vector3, carrier_pid: int, skaters: Array) -> RoleContext:
	var snap := WorldSnapshot.new()
	var team_map: Dictionary = {}
	for entry: Array in skaters:
		var sk := SkaterNetworkState.new()
		sk.position = entry[2]
		sk.velocity = entry[3] if entry.size() > 3 else Vector3.ZERO
		snap.skater_states[entry[0]] = sk
		team_map[entry[0]] = entry[1]
	var puck := PuckNetworkState.new()
	puck.carrier_peer_id = carrier_pid
	for entry: Array in skaters:
		if entry[0] == carrier_pid:
			puck.position = entry[2]
			break
	snap.puck_state = puck

	var ctx := RoleContext.new()
	ctx.snapshot = snap
	ctx.self_pos = self_pos
	ctx.team_id = TEAM_ID
	ctx.peer_id = 1
	ctx.attacking_goal_pos = Vector3(0.0, 0.0, -OUR_NET_Z)
	ctx.defending_goal_pos = Vector3(0.0, 0.0, OUR_NET_Z)
	ctx.own_goal_dir = 1.0
	ctx.self_max_speed = 9.0
	ctx.team_id_by_peer = team_map
	ctx.prev_role_target = Vector3.INF
	return ctx


func test_support_holds_a_near_tied_standing_spot() -> void:
	# SUPPORT picks a high-post station; nudging the standing target a hair off
	# that spot scores essentially the same, so hysteresis keeps the prev.
	var self_pos := Vector3(4, 0, -10)
	var skaters: Array = [
			[1, TEAM_ID, self_pos],
			[2, TEAM_ID, Vector3(-6, 0, -18)],        # carrier working the OZ corner
	]
	var first: Vector3 = AIRoleSupport.decide(_support_ctx(self_pos, 2, skaters)).target_position
	var prev: Vector3 = first + Vector3(0.3, 0, 0.3)  # a hair off the chosen spot
	var ctx2: RoleContext = _support_ctx(self_pos, 2, skaters)
	ctx2.prev_role_target = prev
	var second: Vector3 = AIRoleSupport.decide(ctx2).target_position
	assert_eq(second, prev,
			"a near-equal standing station is held through hysteresis")


# ── The margin contract (controlled scores, role-agnostic) ───────────────────
# Drives the exact loop shape every converted role uses — score + incumbent_bonus,
# keep the max — with hand-set scores so the margin boundary is pinned without
# role-scoring noise. (The role-side drop path is also exercised in
# test_role_pressure's hysteresis tests, now that PRESSURE runs the shared helper.)

func _argmax_with_bonus(ctx: RoleContext, candidates: Array[Vector3],
		raw_scores: Dictionary) -> Vector3:
	var best_pos: Vector3 = Vector3.INF
	var best_score: float = -INF
	for c: Vector3 in candidates:
		var score: float = float(raw_scores[c]) + AIRoleHelpers.incumbent_bonus(ctx, c)
		if score > best_score:
			best_score = score
			best_pos = c
	return best_pos


func test_incumbent_held_when_beaten_within_the_margin() -> void:
	var ctx: RoleContext = _bare_ctx()
	ctx.prev_role_target = Vector3(5, 0, 0)
	var candidates: Array[Vector3] = [Vector3(1, 0, 0)]  # a fresh spot
	AIRoleHelpers.append_incumbent(ctx, candidates)
	# Fresh beats the incumbent by only 0.02 (< 0.04 margin) → incumbent holds.
	var raw := {Vector3(1, 0, 0): 1.00, Vector3(5, 0, 0): 0.98}
	assert_eq(_argmax_with_bonus(ctx, candidates, raw), Vector3(5, 0, 0),
			"a standing spot beaten by less than the margin is kept")


func test_incumbent_dropped_when_beaten_beyond_the_margin() -> void:
	var ctx: RoleContext = _bare_ctx()
	ctx.prev_role_target = Vector3(5, 0, 0)
	var candidates: Array[Vector3] = [Vector3(1, 0, 0)]
	AIRoleHelpers.append_incumbent(ctx, candidates)
	# Fresh beats the incumbent by 0.10 (> 0.04 margin) → switch to the fresh spot.
	var raw := {Vector3(1, 0, 0): 1.00, Vector3(5, 0, 0): 0.90}
	assert_eq(_argmax_with_bonus(ctx, candidates, raw), Vector3(1, 0, 0),
			"a standing spot beaten past the margin is dropped for the fresh spot")