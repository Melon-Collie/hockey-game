extends GutTest

# AIRoleFinisher has a two-mode decision tree:
#   1. REACTIVE — incoming shot detected → tip / step-out.
#   2. POSITIONING — no shot threat → argmax score_pass over
#      candidate set.
# Tests cover both modes plus the bail-out cases (null puck,
# no carrier).

# Team 0 defends +Z; opp goal at -Z.
const OUR_NET_Z: float = 26.65
const OPP_NET_Z: float = -OUR_NET_Z
const TEAM_ID: int = 0


func _make_skater(pid: int, team: int, pos: Vector3,
		is_elevated: bool = false) -> Array:
	# is_elevated maps to loft level: true -> HIGH (2), false -> flat (0).
	return [pid, team, pos, 2 if is_elevated else 0]


func _make_ctx(self_pos: Vector3, anchor: Vector3,
		puck_pos: Vector3, puck_vel: Vector3,
		skaters: Array = []) -> RoleContext:
	# Build a snapshot with the given puck and skaters. If `skaters`
	# is empty, just include self at self_pos so _last_shooter_is_elevated
	# has someone to look at.
	var snap := WorldSnapshot.new()
	if skaters.is_empty():
		var s := SkaterNetworkState.new()
		s.position = self_pos
		s.elevation_level = 0
		snap.skater_states[1] = s
	else:
		for entry: Array in skaters:
			var sk := SkaterNetworkState.new()
			sk.position = entry[2]
			sk.elevation_level = entry[3]
			snap.skater_states[entry[0]] = sk
	var puck := PuckNetworkState.new()
	puck.position = puck_pos
	puck.velocity = puck_vel
	puck.carrier_peer_id = -1
	snap.puck_state = puck

	var team_map: Dictionary = {}
	if skaters.is_empty():
		team_map[1] = TEAM_ID
	else:
		for entry: Array in skaters:
			team_map[entry[0]] = entry[1]

	var ctx := RoleContext.new()
	ctx.snapshot = snap
	ctx.self_pos = self_pos
	ctx.team_id = TEAM_ID
	ctx.peer_id = 1
	# Team 0: own net at +Z, attacking -Z.
	ctx.attacking_goal_pos = Vector3(0.0, 0.0, OPP_NET_Z)
	ctx.defending_goal_pos = Vector3(0.0, 0.0, OUR_NET_Z)
	ctx.own_goal_dir = 1.0
	ctx.anchor = anchor
	ctx.team_id_by_peer = team_map
	return ctx


# ─── HOLD: no incoming shot ───────────────────────────────────────────────

func test_hold_when_puck_too_slow() -> void:
	# Puck heading at our offensive goal but below INCOMING_SHOT_SPEED.
	var anchor := Vector3(-2.0, 0.0, -22.0)  # back-door anchor in OZ
	var ctx: RoleContext = _make_ctx(
			Vector3(-2.0, 0.0, -22.0), anchor,
			Vector3(0.0, 0.0, -10.0), Vector3(0.0, 0.0, -8.0))  # 8 m/s — below 12 m/s gate
	var d: RoleDecision = AIRoleFinisher.decide(ctx)
	assert_eq(d.target_position, anchor)
	assert_false(d.has_aim_override)


func test_hold_when_puck_heading_away_from_goal() -> void:
	# Fast puck but moving toward +Z (back at our defensive net), not
	# toward our offensive goal.
	var anchor := Vector3(-2.0, 0.0, -22.0)
	var ctx: RoleContext = _make_ctx(
			Vector3(-2.0, 0.0, -22.0), anchor,
			Vector3(0.0, 0.0, -10.0), Vector3(0.0, 0.0, 20.0))
	var d: RoleDecision = AIRoleFinisher.decide(ctx)
	assert_eq(d.target_position, anchor)
	assert_false(d.has_aim_override)


func test_hold_when_no_puck_state() -> void:
	var anchor := Vector3(-2.0, 0.0, -22.0)
	var ctx: RoleContext = _make_ctx(
			Vector3(-2.0, 0.0, -22.0), anchor,
			Vector3.ZERO, Vector3.ZERO)
	ctx.snapshot.puck_state = null
	var d: RoleDecision = AIRoleFinisher.decide(ctx)
	assert_eq(d.target_position, anchor)


# ─── TIP: fast ground shot ────────────────────────────────────────────────

func test_tip_shifts_anchor_onto_puck_path_and_aims_at_goal() -> void:
	# Fast ground shot from a teammate at (4, 0, -15) heading to opp
	# net (-Z direction). Finisher (peer 1) is at (-2, 0, -22) — back
	# door. Puck at (4, 0, -15) with vel (-3, 0, -15) — speed ≈ 15 m/s,
	# heading toward our offensive goal at -Z. Path crosses our z (-22)
	# at t ≈ 0.467 s, x ≈ 4 + (-3)(0.467) ≈ 2.6.
	var anchor := Vector3(-2.0, 0.0, -22.0)
	var teammate_pos := Vector3(4.0, 0.0, -15.0)
	var ctx: RoleContext = _make_ctx(
			Vector3(-2.0, 0.0, -22.0), anchor,
			teammate_pos, Vector3(-3.0, 0.0, -15.0),
			[
				_make_skater(1, TEAM_ID, Vector3(-2.0, 0.0, -22.0), false),
				_make_skater(2, TEAM_ID, teammate_pos, false),  # not elevated
			])
	var d: RoleDecision = AIRoleFinisher.decide(ctx)
	# Target shifted to puck path at our z-plane.
	assert_almost_eq(d.target_position.x, 2.6, 0.1)
	assert_almost_eq(d.target_position.z, -22.0, 0.001)
	# Aim override toward opp net.
	assert_true(d.has_aim_override)
	assert_almost_eq(d.aim_world_pos.z, OPP_NET_Z, 0.001)
	assert_almost_eq(d.aim_world_pos.x, 0.0, 0.001)


# ─── TIP + LIFT: elevated shot ────────────────────────────────────────────

func test_lift_and_tip_when_shooter_is_elevated() -> void:
	# Same geometry as the TIP test but the shooting teammate has
	# is_elevated = true. Finisher should still move ONTO the path and aim
	# at net (a tip), and additionally raise its blade so it can reach the
	# airborne puck — not step out of the way.
	var anchor := Vector3(-2.0, 0.0, -22.0)
	var teammate_pos := Vector3(4.0, 0.0, -15.0)
	var ctx: RoleContext = _make_ctx(
			Vector3(-2.0, 0.0, -22.0), anchor,
			teammate_pos, Vector3(-3.0, 0.0, -15.0),
			[
				_make_skater(1, TEAM_ID, Vector3(-2.0, 0.0, -22.0), false),
				_make_skater(2, TEAM_ID, teammate_pos, true),  # elevated
			])
	var d: RoleDecision = AIRoleFinisher.decide(ctx)
	# Target moves onto the puck path (same as the ground tip), x ≈ 2.6.
	assert_almost_eq(d.target_position.x, 2.6, 0.1)
	assert_almost_eq(d.target_position.z, -22.0, 0.001)
	# Aim override toward opp net, and the blade is lifted to reach the air.
	assert_true(d.has_aim_override)
	assert_almost_eq(d.aim_world_pos.z, OPP_NET_Z, 0.001)
	assert_true(d.lift_blade, "elevated incoming shot → lift to tip it")


func test_ground_tip_does_not_lift_blade() -> void:
	# A fast GROUND shot is tipped with the blade down — lifting would
	# make the grounded blade unable to touch the on-ice puck.
	var anchor := Vector3(-2.0, 0.0, -22.0)
	var teammate_pos := Vector3(4.0, 0.0, -15.0)
	var ctx: RoleContext = _make_ctx(
			Vector3(-2.0, 0.0, -22.0), anchor,
			teammate_pos, Vector3(-3.0, 0.0, -15.0),
			[
				_make_skater(1, TEAM_ID, Vector3(-2.0, 0.0, -22.0), false),
				_make_skater(2, TEAM_ID, teammate_pos, false),  # NOT elevated
			])
	var d: RoleDecision = AIRoleFinisher.decide(ctx)
	assert_false(d.lift_blade, "a ground shot is tipped with a grounded blade")


# ─── HOLD: puck won't reach our z-plane ───────────────────────────────────

func test_hold_when_puck_path_crossing_is_in_past() -> void:
	# Fast puck heading toward opp goal — but it's ALREADY past the
	# back-door bot's z plane. The bot is BEHIND the puck-line
	# (less deep toward opp goal), so t_to_my_z is negative and the
	# reactive returns null. With no carrier set up, positioning
	# falls back to self_pos = anchor.
	var anchor := Vector3(-2.0, 0.0, -21.0)
	var ctx: RoleContext = _make_ctx(
			Vector3(-2.0, 0.0, -21.0), anchor,
			Vector3(0.0, 0.0, -23.0),  # puck DEEPER (more -Z) than back-door
			Vector3(0.0, 0.0, -15.0))  # heading further toward opp goal — away from us
	var d: RoleDecision = AIRoleFinisher.decide(ctx)
	assert_eq(d.target_position, anchor)


# ─── POSITIONING (no incoming shot) ───────────────────────────────────────

func test_positioning_falls_back_to_self_pos_when_no_carrier() -> void:
	# No teammate carrier means no offensive context — positioning
	# falls back to self_pos (hold position; brain re-tick will
	# reassign within a frame).
	var self_pos := Vector3(-2.0, 0.0, -22.0)
	var ctx: RoleContext = _make_ctx(
			self_pos, Vector3.ZERO,
			Vector3(0.0, 0.0, -10.0), Vector3.ZERO)  # slow puck → reactive returns null
	var d: RoleDecision = AIRoleFinisher.decide(ctx)
	assert_eq(d.target_position, self_pos,
			"slow puck + no carrier → positioning falls back to self_pos")
	assert_false(d.has_aim_override)


func test_positioning_picks_legal_position_when_carrier_present() -> void:
	# Teammate carrier in OZ corner. Slow puck so reactive doesn't
	# fire (puck speed 0). FINISHER should run positioning argmax
	# and pick a legal back-door / slot candidate.
	var anchor := Vector3(-2.0, 0.0, -22.0)
	var carrier_pos := Vector3(5.0, 0.0, -22.0)  # OZ corner, strong-side
	var ctx: RoleContext = _make_ctx(
			Vector3(-2.0, 0.0, -22.0), anchor,
			carrier_pos, Vector3.ZERO,  # carrier holds puck, no shot in flight
			[
				_make_skater(1, TEAM_ID, Vector3(-2.0, 0.0, -22.0), false),
				_make_skater(100, TEAM_ID, carrier_pos, false),
			])
	# Wire the puck carrier_peer_id to the teammate.
	ctx.snapshot.puck_state.carrier_peer_id = 100
	var d: RoleDecision = AIRoleFinisher.decide(ctx)
	# Position is legal: in-rink, not in crease, not past goal line.
	assert_true(absf(d.target_position.x) <= GameRules.RINK_HALF_WIDTH,
			"x within rink bounds")
	assert_true(absf(d.target_position.z) <= GameRules.GOAL_LINE_Z,
			"z within goal-line bounds")
	# No aim override — positioning doesn't tip.
	assert_false(d.has_aim_override)


func _stage_x_for_strong_side(strong_x: float) -> float:
	# Same carrier and skaters; only the strong-side sign differs, isolating the
	# weak-side search bias.
	var carrier_pos := Vector3(6.0, 0.0, -20.0)
	var ctx: RoleContext = _make_ctx(
			Vector3(0.0, 0.0, -20.0), Vector3.ZERO,
			carrier_pos, Vector3.ZERO,
			[
				_make_skater(1, TEAM_ID, Vector3(0.0, 0.0, -20.0), false),
				_make_skater(100, TEAM_ID, carrier_pos, false),
			])
	ctx.snapshot.puck_state.carrier_peer_id = 100
	ctx.strong_x = strong_x
	return AIRoleFinisher.decide(ctx).target_position.x


func test_positioning_bias_follows_strong_side() -> void:
	# The weak-side staging bias keys off strong_x: when the puck's strong side
	# is +X the FINISHER stages further to the weak (-X) side than when it's -X.
	# Validates the bias is wired without overfitting an absolute spot (the exact
	# depth is a tuning matter — angle vs goalie-slide trade off).
	var x_strong_plus: float = _stage_x_for_strong_side(1.0)
	var x_strong_minus: float = _stage_x_for_strong_side(-1.0)
	assert_lt(x_strong_plus, x_strong_minus,
			"strong-side +X should stage weaker (lower x) than strong-side -X")


func test_positioning_does_not_stack_on_carrier_side() -> void:
	# With a strong-side carrier at x=6, the FINISHER should stage well across to
	# the slot/weak side rather than crowding the puck-side wall.
	var x: float = _stage_x_for_strong_side(1.0)
	assert_lt(x, 3.0, "FINISHER stages cross-ice from a strong-side carrier, not stacked on it")


func test_positioning_stages_weak_side_of_a_strong_side_carrier() -> void:
	# 2-on-0 read: wide strong-side (+X) carrier, no defenders. The weak-side
	# search-center bias plus the seven-hole feed geometry (a cross-seam one-timer
	# catches the goalie sliding) should stage the FINISHER on the weak (-X) side,
	# opposite the carrier — the far-post tap-in, not crowding the puck side.
	var x: float = _stage_x_for_strong_side(1.0)
	assert_lt(x, 0.0,
			"FINISHER stages weak-side, opposite the carrier; got x=%f" % x)


# ─── RUSH-AWARE STAGING ───────────────────────────────────────────────────

func _rush_ctx(carrier_vel: Vector3) -> RoleContext:
	# Stationary finisher at center-ice depth; a wide strong-side teammate
	# carrier with the given velocity. Slow puck so reactive stays off and
	# positioning runs. strong_x = +1 so the weak side is -X.
	var carrier_pos := Vector3(6.0, 0.0, -18.0)
	var ctx: RoleContext = _make_ctx(
			Vector3(0.0, 0.0, -18.0), Vector3.ZERO,
			carrier_pos, Vector3.ZERO,
			[
				_make_skater(1, TEAM_ID, Vector3(0.0, 0.0, -18.0), false),
				_make_skater(100, TEAM_ID, carrier_pos, false),
			])
	ctx.snapshot.puck_state.carrier_peer_id = 100
	ctx.snapshot.skater_states[100].velocity = carrier_vel
	ctx.strong_x = 1.0
	return ctx


func test_rush_factor_zero_for_stationary_carrier() -> void:
	assert_almost_eq(AIRoleFinisher._rush_factor(_rush_ctx(Vector3.ZERO)), 0.0, 0.001)


func test_rush_factor_zero_for_carrier_skating_away_from_net() -> void:
	# Team 0 attacks -Z; a +Z carrier velocity is away from the opp net,
	# which is never a rush.
	assert_almost_eq(
			AIRoleFinisher._rush_factor(_rush_ctx(Vector3(0.0, 0.0, 8.0))), 0.0, 0.001)


func test_rush_factor_one_for_fast_closing_carrier() -> void:
	# A -Z carrier velocity above RUSH_SPEED_HI_M_S is a full rush.
	assert_almost_eq(
			AIRoleFinisher._rush_factor(_rush_ctx(Vector3(0.0, 0.0, -8.0))), 1.0, 0.001)


func test_rush_stages_finisher_closer_to_the_net_than_set_cycle() -> void:
	# Same wide strong-side (+X) carrier; only its velocity differs. The rush
	# blend pulls the staging DEPTH in (stage_dist: SLOT_DIST_M → RUSH_NET_DRIVE_
	# DIST_M), so a rushing carrier stages the FINISHER closer to the attacking
	# net — a second attacker crashing for the rebound/backdoor tap, rather than
	# parked at the slot on a set cycle.
	var goal_z: float = OPP_NET_Z
	var set_pos: Vector3 = AIRoleFinisher.decide(_rush_ctx(Vector3.ZERO)).target_position
	var rush_pos: Vector3 = AIRoleFinisher.decide(
			_rush_ctx(Vector3(0.0, 0.0, -8.0))).target_position
	assert_lt(absf(rush_pos.z - goal_z), absf(set_pos.z - goal_z),
			"a rushing carrier stages the FINISHER closer to the net (net-crash)")
	assert_lt(set_pos.x, 0.0, "the set cycle still stages weak-side")


func test_reactive_fires_on_loose_shots_and_defers_while_the_puck_reads_held() -> void:
	# A held puck is never an incoming shot — a carrier skating it fast must
	# not flip the FINISHER into tip mode, and the carrier-reaction debounce
	# window right after a release (a live feed still nominally reads held)
	# must run positioning too: the reactive not-ready decision used to tear
	# down one-timer readiness on every feed. Reactive TIP fires the tick the
	# fast on-net puck reads loose.
	var anchor := Vector3(-2.0, 0.0, -22.0)
	var teammate_pos := Vector3(4.0, 0.0, -15.0)
	var ctx: RoleContext = _make_ctx(
			Vector3(-2.0, 0.0, -22.0), anchor,
			teammate_pos, Vector3(-3.0, 0.0, -15.0),  # fast ground shot
			[
				_make_skater(1, TEAM_ID, Vector3(-2.0, 0.0, -22.0), false),
				_make_skater(2, TEAM_ID, teammate_pos, false),
			])
	ctx.snapshot.puck_state.carrier_peer_id = 2
	var held: RoleDecision = AIRoleFinisher.decide(ctx)
	assert_false(held.has_aim_override,
			"a held puck runs positioning, never tip mode")
	ctx.snapshot.puck_state.carrier_peer_id = -1
	var loose: RoleDecision = AIRoleFinisher.decide(ctx)
	assert_true(loose.has_aim_override,
			"reactive TIP fires once the fast on-net puck reads loose")
	assert_almost_eq(loose.aim_world_pos.z, OPP_NET_Z, 0.001)
