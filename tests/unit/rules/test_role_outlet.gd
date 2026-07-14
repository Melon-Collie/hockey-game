extends GutTest

# AIRoleOutlet's decide() is the SUPPORT structure minus the
# exposure factor, plus an offside filter. Tests cover the
# OUTLET-specific behavior:
#   - Bail-out cases (no carrier / opp carrier).
#   - Argmax produces a legal pick.
#   - Anti-crowding filter respected.
#   - Offside filter rejects OZ candidates (past opp blue line).
#   - Covered stretch spot → stage somewhere open (live argmax).
#
# The geometric guts (lane_clear / position_potential) are covered in
# test_ai_action_scoring.

const TEAM_ID: int = 0
const OUR_NET_Z: float = 26.65   # Team 0 defends +Z, attacks -Z
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


# ── Bail-outs ───────────────────────────────────────────────────────────────

func test_presents_outlet_on_loose_puck_instead_of_freezing() -> void:
	# Loose puck (breakout in flight). OUTLET used to freeze at self_pos
	# — the "stuck on the heels" bug. It must now read off the puck and
	# get up-ice to present the stretch option. Bot starts buried deep
	# in our own end; target must advance up-ice, never self_pos.
	var self_pos := Vector3(4, 0, 20)   # buried deep in our own end
	var ctx: RoleContext = _make_ctx(self_pos, Vector3.ZERO)   # loose puck at origin
	var d: RoleDecision = AIRoleOutlet.decide(ctx)
	assert_ne(d.target_position, self_pos,
			"loose puck → get up-ice for the outlet, don't freeze")
	assert_lt(d.target_position.z, self_pos.z,
			"target advances up-ice toward the stretch position; got z=%f" % d.target_position.z)


func test_falls_back_to_self_pos_when_opp_has_puck() -> void:
	var self_pos := Vector3(-4, 0, -GameRules.BLUE_LINE_Z + 2.5)
	var skaters: Array = [
		[1, TEAM_ID, self_pos, Vector3.ZERO],
		[200, 1 - TEAM_ID, Vector3(0, 0, 0), Vector3.ZERO],
	]
	var ctx: RoleContext = _make_ctx(self_pos, Vector3.ZERO, 200, skaters)
	var d: RoleDecision = AIRoleOutlet.decide(ctx)
	assert_eq(d.target_position, self_pos,
			"opp carrier → no offensive context, fall back to self_pos")


# ── Argmax pick is legal and NZ-side ────────────────────────────────────────

func test_returns_legal_position_with_teammate_carrier() -> void:
	var self_pos := Vector3(-4, 0, -GameRules.BLUE_LINE_Z + 2.5)
	var carrier_pos := Vector3(0, 0, 0)
	var skaters: Array = [
		[1, TEAM_ID, self_pos, Vector3.ZERO],
		[100, TEAM_ID, carrier_pos, Vector3.ZERO],
	]
	var ctx: RoleContext = _make_ctx(self_pos, Vector3.ZERO, 100, skaters)
	var d: RoleDecision = AIRoleOutlet.decide(ctx)
	assert_true(absf(d.target_position.x) <= GameRules.RINK_HALF_WIDTH,
			"x within rink bounds")
	assert_true(absf(d.target_position.z) <= GameRules.GOAL_LINE_Z,
			"z within goal-line bounds")


# ── Side consistency (strong_x, not the carrier's live x) ────────────────────

func test_outlet_side_follows_strong_x_not_the_carrier_wobble() -> void:
	# The stretch spot mirrors to the WEAK side of the brain's hysteretic
	# strong_x, not a raw -carrier.x. So a carrier wheeling just across center
	# (puck crossing the middle while strong_x is held) must NOT flip the
	# OUTLET's staging side — the raw mirror did, sending the OUTLET across the
	# SUPPORT trailer's path on the breakout→rush handoff. With no opponents
	# the pick is potential-driven and independent of the carrier's position,
	# so identical strong_x + equal |carrier.x| must give the same target.
	var self_pos := Vector3(-4, 0, -6)
	var sk_plus: Array = [
			[1, TEAM_ID, self_pos, Vector3.ZERO],
			[100, TEAM_ID, Vector3(1, 0, 0), Vector3.ZERO],   # carrier +X of center
	]
	var ctx_plus: RoleContext = _make_ctx(self_pos, Vector3.ZERO, 100, sk_plus)
	ctx_plus.strong_x = 1.0
	var d_plus: RoleDecision = AIRoleOutlet.decide(ctx_plus)
	var sk_minus: Array = [
			[1, TEAM_ID, self_pos, Vector3.ZERO],
			[100, TEAM_ID, Vector3(-1, 0, 0), Vector3.ZERO],  # carrier wheeled to -X
	]
	var ctx_minus: RoleContext = _make_ctx(self_pos, Vector3.ZERO, 100, sk_minus)
	ctx_minus.strong_x = 1.0
	var d_minus: RoleDecision = AIRoleOutlet.decide(ctx_minus)
	assert_almost_eq(d_minus.target_position.x, d_plus.target_position.x, 0.01,
			"the carrier's cross-center wobble doesn't flip the OUTLET's side")


# ── Offside filter ──────────────────────────────────────────────────────────

func test_offside_filter_rejects_oz_candidates() -> void:
	# Team 0: opp blue line at z = -BLUE_LINE_Z. The OUTLET search
	# center sits BLUE_LINE_BUFFER_M NZ-side of that line (z = -BLUE
	# + buffer). Polar samples at SEARCH_STEP_M (3 m) toward -Z would
	# be at z = -BLUE - (3 - buffer), in OZ. Those must be filtered.
	# Verify the chosen target.z is NZ-side.
	var self_pos := Vector3(-4, 0, -GameRules.BLUE_LINE_Z + 2.5)
	var carrier_pos := Vector3(0, 0, 0)
	var skaters: Array = [
		[1, TEAM_ID, self_pos, Vector3.ZERO],
		[100, TEAM_ID, carrier_pos, Vector3.ZERO],
	]
	var ctx: RoleContext = _make_ctx(self_pos, Vector3.ZERO, 100, skaters)
	var d: RoleDecision = AIRoleOutlet.decide(ctx)
	assert_gt(d.target_position.z, -GameRules.BLUE_LINE_Z,
			"OUTLET stays NZ-side of opp blue line; got %s" % d.target_position)


# ── Velocity-corrected offside filter ──────────────────────────────────────

func test_velocity_buffer_pushes_target_back_at_speed() -> void:
	# A bot moving fast toward the opp net needs to slow down before
	# the blue line — the velocity-corrected offside filter rejects
	# candidates that the bot would overshoot in SKATER_BRAKE_TIME_S.
	# Compared with a stationary bot, the moving bot's chosen target
	# should sit further NZ-side (further from the opp blue line).
	var carrier_pos := Vector3(0, 0, 0)
	var self_pos := Vector3(-4, 0, -GameRules.BLUE_LINE_Z + 5.0)

	# Stationary baseline.
	var stationary_skaters: Array = [
		[1, TEAM_ID, self_pos, Vector3.ZERO],
		[100, TEAM_ID, carrier_pos, Vector3.ZERO],
	]
	var ctx_static: RoleContext = _make_ctx(self_pos, Vector3.ZERO, 100, stationary_skaters)
	ctx_static.self_velocity = Vector3.ZERO
	var stationary_target: Vector3 = AIRoleOutlet.decide(ctx_static).target_position

	# Same setup but bot is moving at near top speed toward opp net
	# (own_goal_dir = +1, so attacking is -Z; velocity.z negative).
	var ctx_moving: RoleContext = _make_ctx(self_pos, Vector3.ZERO, 100, stationary_skaters)
	ctx_moving.self_velocity = Vector3(0.0, 0.0, -10.0)
	var moving_target: Vector3 = AIRoleOutlet.decide(ctx_moving).target_position

	# Moving target should be NZ-side of the stationary one (higher z
	# for Team 0). Brake time × velocity ≈ 3 m of forward overshoot
	# the filter accounts for.
	assert_gt(moving_target.z, stationary_target.z - 0.01,
			"moving bot's target should be at least as far NZ-side; got moving=%s stationary=%s" % [moving_target, stationary_target])


# ── Covered stretch spot ─────────────────────────────────────────────────────

func test_avoids_defender_camped_on_the_stretch_spot() -> void:
	# A defender parked right on the OUTLET search center. Every legal
	# candidate out here is past SHOT_RANGE_FALLOFF_M, where score_shoot
	# is 0 by definition — so the old score_pass argmax scored every
	# candidate 0 and degenerated to "first in the list", sending the
	# outlet to the raw search center, straight into the defender. The
	# lane × potential scoring keeps a live gradient, so the outlet
	# stages an open spot instead.
	var carrier_pos := Vector3(5, 0, 0)
	# Search center: weak-side mirror of carrier X, BLUE_LINE_BUFFER_M
	# NZ-side of the opp blue line. Defender sits on it, half a metre
	# net-side (inside the candidate's forward pressure cone).
	var center := Vector3(-5, 0, -GameRules.BLUE_LINE_Z + AIRoleOutlet.BLUE_LINE_BUFFER_M)
	var defender := Vector3(center.x, 0, center.z - 0.5)
	var skaters: Array = [
		[1, TEAM_ID, Vector3(-3, 0, 3), Vector3.ZERO],   # us, trailing the play
		[100, TEAM_ID, carrier_pos, Vector3.ZERO],
		[200, 1 - TEAM_ID, defender, Vector3.ZERO],
	]
	var ctx: RoleContext = _make_ctx(Vector3(-3, 0, 3), Vector3.ZERO, 100, skaters)
	var d: RoleDecision = AIRoleOutlet.decide(ctx)
	assert_gt(d.target_position.distance_to(defender), 2.0,
			"outlet must stage clear of a defender camped on the stretch spot; got %s vs defender %s" \
			% [d.target_position, defender])


# ── In-stride rush entry ────────────────────────────────────────────────────

func _rush_skaters(carrier_vel: Vector3) -> Array:
	# OUTLET on the weak side; carrier just own-side of center with the given
	# velocity. Team 0 attacks -Z, so a -Z carrier velocity is a rush.
	return [
		[1, TEAM_ID, Vector3(-2, 0, -2), Vector3.ZERO],
		[100, TEAM_ID, Vector3(2, 0, 2), carrier_vel],
	]


func test_rush_sets_arrive_at_speed_but_set_play_does_not() -> void:
	var moving: RoleDecision = AIRoleOutlet.decide(
			_make_ctx(Vector3(-2, 0, -2), Vector3.ZERO, 100,
					_rush_skaters(Vector3(0, 0, -8))))
	var still: RoleDecision = AIRoleOutlet.decide(
			_make_ctx(Vector3(-2, 0, -2), Vector3.ZERO, 100,
					_rush_skaters(Vector3.ZERO)))
	assert_true(moving.arrive_at_speed,
			"a live rush arrives at speed (no arrival brake) to hit the line in stride")
	assert_false(still.arrive_at_speed,
			"a set play holds the line and brakes to a stop, as before")


func test_rush_paces_outlet_behind_the_parked_stretch_spot() -> void:
	# Same deep carrier; only its velocity differs. Parked (set play) stages
	# up at the blue line; on a rush the pace cap keeps the OUTLET level with
	# the carrier's advance — meaningfully further NZ-side (higher z for Team
	# 0) so it arrives in stride instead of standing at the line.
	var rush_z: float = AIRoleOutlet.decide(
			_make_ctx(Vector3(-2, 0, -2), Vector3.ZERO, 100,
					_rush_skaters(Vector3(0, 0, -8)))).target_position.z
	var set_z: float = AIRoleOutlet.decide(
			_make_ctx(Vector3(-2, 0, -2), Vector3.ZERO, 100,
					_rush_skaters(Vector3.ZERO))).target_position.z
	assert_gt(rush_z, set_z + 1.0,
			"rush paces the OUTLET back off the line vs the parked stretch spot; got rush=%f set=%f" \
			% [rush_z, set_z])


# ── Anti-crowding ───────────────────────────────────────────────────────────

func test_anti_crowding_avoids_candidates_near_teammates() -> void:
	# Place a teammate at OUTLET's computed search center (weak-side
	# of carrier on X, NZ-side of opp blue line on Z). The center
	# itself is a candidate; the anti-crowd filter rejects it.
	# Carrier at +5 → weak side X = -5; Z = -BLUE + 2.5.
	var carrier_pos := Vector3(5, 0, 0)
	var search_center := Vector3(-5, 0, -GameRules.BLUE_LINE_Z + 2.5)
	var skaters: Array = [
		[1, TEAM_ID, Vector3(8, 0, 5), Vector3.ZERO],     # us, off to the side
		[100, TEAM_ID, carrier_pos, Vector3.ZERO],        # carrier
		[110, TEAM_ID, search_center, Vector3.ZERO],      # squatting on the center
	]
	var ctx: RoleContext = _make_ctx(Vector3(8, 0, 5), Vector3.ZERO, 100, skaters)
	var d: RoleDecision = AIRoleOutlet.decide(ctx)
	var dist_to_teammate: float = d.target_position.distance_to(search_center)
	assert_gt(dist_to_teammate, AIRoleHelpers.ANTI_CROWD_RADIUS_M - 0.01,
			"chosen target must clear the anti-crowd radius around the teammate")
