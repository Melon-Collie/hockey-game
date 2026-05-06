extends GutTest

# AIRoleFinisher is stateless; tests cover the four arms of its
# decision tree (HOLD, STEP_OUT, TIP, null puck) by constructing
# minimal WorldSnapshots.

# Team 0 defends +Z; opp goal at -Z.
const OUR_NET_Z: float = 26.65
const OPP_NET_Z: float = -OUR_NET_Z
const TEAM_ID: int = 0


func _make_skater(pid: int, team: int, pos: Vector3,
		is_elevated: bool = false) -> Array:
	return [pid, team, pos, is_elevated]


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
		s.is_elevated = false
		snap.skater_states[1] = s
	else:
		for entry: Array in skaters:
			var sk := SkaterNetworkState.new()
			sk.position = entry[2]
			sk.is_elevated = entry[3]
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
	ctx.team_id_resolver = func(pid: int) -> int: return int(team_map.get(pid, -1))
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


# ─── STEP_OUT: elevated shot ──────────────────────────────────────────────

func test_step_out_when_shooter_is_elevated() -> void:
	# Same geometry as the TIP test but the shooting teammate has
	# is_elevated = true. Finisher should step laterally instead of
	# moving onto the path.
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
	# Path crosses at x ≈ 2.6, anchor.x = -2.0. step_dir = sign(2.6 - -2.0) = +1.
	# Step anchor x = -2.0 - 1 * 1.5 = -3.5 (move laterally away from path).
	assert_almost_eq(d.target_position.x, -3.5, 0.001)
	assert_almost_eq(d.target_position.z, -22.0, 0.001)
	# No aim override on STEP_OUT.
	assert_false(d.has_aim_override)


# ─── HOLD: puck won't reach our z-plane ───────────────────────────────────

func test_hold_when_puck_path_crossing_is_in_past() -> void:
	# Fast puck heading toward opp goal but the back-door bot is
	# DEEPER than the puck (further toward -Z than the puck). The
	# t_to_my_z calculation comes out negative — puck already past us.
	var anchor := Vector3(-2.0, 0.0, -25.0)
	var ctx: RoleContext = _make_ctx(
			Vector3(-2.0, 0.0, -25.0), anchor,
			Vector3(0.0, 0.0, -23.0),  # puck closer to opp goal than back-door
			Vector3(0.0, 0.0, -15.0))  # heading further toward opp goal
	var d: RoleDecision = AIRoleFinisher.decide(ctx)
	assert_eq(d.target_position, anchor)
