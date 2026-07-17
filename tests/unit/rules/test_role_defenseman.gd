extends GutTest

# AIRoleDefenseman — the 5v5 off-puck D (plan §4). Team 0 defends +Z and
# attacks -Z; peer 1 is the bot under test.

const TEAM_ID: int = 0
const OUR_NET_Z: float = 26.65


func _make_ctx(self_pos: Vector3, skaters: Array = [],
		carrier_pid: int = -1, puck_pos: Vector3 = Vector3.ZERO,
		strong_x: float = 1.0) -> RoleContext:
	var snap := WorldSnapshot.new()
	var have_self: bool = false
	for entry: Array in skaters:
		if entry[0] == 1:
			have_self = true
	if not have_self:
		var s := SkaterNetworkState.new()
		s.position = self_pos
		snap.skater_states[1] = s
	for entry: Array in skaters:
		var sk := SkaterNetworkState.new()
		sk.position = entry[2]
		sk.velocity = entry[3] if entry.size() > 3 else Vector3.ZERO
		snap.skater_states[entry[0]] = sk
	var puck := PuckNetworkState.new()
	puck.carrier_peer_id = carrier_pid
	if carrier_pid != -1 and snap.skater_states.has(carrier_pid):
		puck.position = snap.skater_states[carrier_pid].position
	else:
		puck.position = puck_pos
	snap.puck_state = puck

	var team_map: Dictionary = {1: TEAM_ID}
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
	ctx.strong_x = strong_x
	ctx.team_size = 5
	ctx.self_is_defense = true
	return ctx


# ── OZONE points ─────────────────────────────────────────────────────────────

func test_point_holds_just_inside_the_offensive_blue_line() -> void:
	# Own carrier cycling low, no opponents: the strong point stands at the
	# line on the strong side.
	var ctx: RoleContext = _make_ctx(Vector3(6.0, 0.0, -8.0),
			[[2, TEAM_ID, Vector3(8.0, 0.0, -22.0)]], 2)
	var d: RoleDecision = AIRoleDefenseman.decide(ctx, AIRoleSlots.Slot.POINT_STRONG)
	# Inside the zone (z past the attacking blue line), near the line.
	assert_lt(d.target_position.z, -GameRules.BLUE_LINE_Z + 0.01)
	assert_gt(d.target_position.z, -GameRules.BLUE_LINE_Z - 6.0)
	assert_gt(d.target_position.x, 0.0, "strong point works the strong side")


func test_point_walks_off_a_covered_shot_lane() -> void:
	# A shot-blocker parked on the wall lane: the walk-the-line argmax must
	# move the stand off that lane (the researched lateral walk).
	var wall_stand := Vector3(6.71, 0.0, -8.29)
	var blocker_pos: Vector3 = wall_stand + (Vector3(0, 0, -OUR_NET_Z) - wall_stand).normalized() * 3.0
	var ctx: RoleContext = _make_ctx(wall_stand, [
			[2, TEAM_ID, Vector3(8.0, 0.0, -22.0)],
			[10, 1, blocker_pos],
	], 2)
	var d: RoleDecision = AIRoleDefenseman.decide(ctx, AIRoleSlots.Slot.POINT_STRONG)
	assert_gt(wall_stand.distance_to(d.target_position), 1.5,
			"a blocked lane walks the point off the wall stand")


func test_point_holds_the_line_against_high_zone_coverage() -> void:
	# The reported oscillation bug. Own team cycling deep in the O-zone, a
	# defending winger covering the point HIGH in his zone (the researched
	# D-zone winger stand) — no puck on his blade. The old beat-him-to-our-net
	# radius read that winger as an un-raceable counter threat (equal top
	# speeds, similar distance home) and sagged the point to center ice, then
	# skated back up when he drifted deeper: blue-line-to-blue-line pacing.
	# The grounded read: a counter must move the PUCK (outlet flight, then a
	# carry the point man stands directly in the path of), so the line holds.
	var line_stand := Vector3(6.71, 0.0, -8.29)
	var ctx: RoleContext = _make_ctx(line_stand, [
			[2, TEAM_ID, Vector3(8.0, 0.0, -22.0)],   # our carrier, cycling low
			[10, 1, Vector3(5.0, 0.0, -10.0)],        # winger covering the point
			[11, 1, Vector3(-4.0, 0.0, -21.0)],       # rest of the coverage, low
			[12, 1, Vector3(3.0, 0.0, -24.0)],
	], 2)
	var d: RoleDecision = AIRoleDefenseman.decide(ctx, AIRoleSlots.Slot.POINT_STRONG)
	assert_lt(d.target_position.z, -GameRules.BLUE_LINE_Z + 0.01,
			"puckless high coverage must not chase the point off the line; got %s"
			% d.target_position)


func test_point_does_not_pace_the_neutral_zone_as_coverage_jitters() -> void:
	# Stability half of the oscillation regression: as the covering winger
	# drifts up and down his wall with small velocity swings (a real cycle's
	# coverage motion), the point's stand must stay in the zone every single
	# read — the old radius model flipped between "hold the line" and "sag to
	# center ice" whenever the winger's naive ETA-home crossed the knife edge.
	for wz: float in [-14.0, -12.0, -10.0, -8.5, -10.0, -13.0]:
		for wvz: float in [-1.5, 0.0, 1.5]:
			var ctx: RoleContext = _make_ctx(Vector3(6.71, 0.0, -8.29), [
					[2, TEAM_ID, Vector3(8.0, 0.0, -22.0)],
					[10, 1, Vector3(5.0, 0.0, wz), Vector3(0.0, 0.0, wvz)],
			], 2)
			var d: RoleDecision = AIRoleDefenseman.decide(
					ctx, AIRoleSlots.Slot.POINT_STRONG)
			assert_lt(d.target_position.z, -GameRules.BLUE_LINE_Z + 2.0,
					("coverage jitter (wz=%.1f wvz=%.1f) must not pull the point"
					+ " out of the zone; got %s") % [wz, wvz, d.target_position])


func test_point_sags_when_the_race_home_is_lost() -> void:
	# A stretch opponent already behind our point pair, burning for our net:
	# the keep-in bound must pull the stand out of the deep zone entirely.
	var ctx: RoleContext = _make_ctx(Vector3(6.0, 0.0, -8.0), [
			[2, TEAM_ID, Vector3(8.0, 0.0, -22.0)],
			[10, 1, Vector3(0.0, 0.0, 8.0), Vector3(0.0, 0.0, 8.0)],
	], 2)
	var d: RoleDecision = AIRoleDefenseman.decide(ctx, AIRoleSlots.Slot.POINT_STRONG)
	var stand_dist_home: float = d.target_position.distance_to(Vector3(0, 0, OUR_NET_Z))
	var line_dist_home: float = Vector3(6.71, 0, -8.29).distance_to(Vector3(0, 0, OUR_NET_Z))
	assert_lt(stand_dist_home, line_dist_home,
			"a lurking stretch threat pulls the point toward home")


# ── FORECHECK line pair ──────────────────────────────────────────────────────

func test_dp_holds_the_line_when_opponents_are_bottled() -> void:
	# Opp carrier pinned deep in THEIR zone: the D pair stands at the line.
	var ctx: RoleContext = _make_ctx(Vector3(6.0, 0.0, -4.0),
			[[10, 1, Vector3(4.0, 0.0, -24.0)]], 10)
	var d: RoleDecision = AIRoleDefenseman.decide(ctx, AIRoleSlots.Slot.DP_STRONG)
	assert_almost_eq(d.target_position.z, -GameRules.BLUE_LINE_Z + 0.5, 0.6,
			"line stand on the NZ side of the blue line")
	assert_almost_eq(d.target_position.x, 6.7, 0.1, "strong lane inside the dots")


func test_dp_sags_off_a_stretch_threat() -> void:
	# A stretch man lurking at center ice: the race home shrinks — the line
	# stand slides down the NZ toward our end.
	var ctx: RoleContext = _make_ctx(Vector3(6.0, 0.0, -4.0), [
			[10, 1, Vector3(4.0, 0.0, -24.0)],
			[11, 1, Vector3(0.0, 0.0, 2.0), Vector3(0.0, 0.0, 6.0)],
	], 10)
	var d: RoleDecision = AIRoleDefenseman.decide(ctx, AIRoleSlots.Slot.DP_WEAK)
	assert_gt(d.target_position.z, -GameRules.BLUE_LINE_Z + 0.5,
			"the stand sags off the line when the race home tightens")


# ── TRANS_DO valve ───────────────────────────────────────────────────────────

func test_valve_trails_the_rush_at_speed() -> void:
	var ctx: RoleContext = _make_ctx(Vector3(0.0, 0.0, 6.0),
			[[2, TEAM_ID, Vector3(2.0, 0.0, -4.0)]], 2)
	var d: RoleDecision = AIRoleDefenseman.decide(ctx, AIRoleSlots.Slot.DVALVE)
	assert_true(d.arrive_at_speed, "the valve paces a moving waypoint")
	assert_gt(d.target_position.z, -4.0, "trails goal-side of the carrier")
	assert_almost_eq(d.target_position.x, 0.0, 0.5, "central reset lane")


func test_valve_never_loses_the_race_home() -> void:
	# An opponent already deep behind the valve: the race-home cap must pull
	# the trail point toward our net, whatever the carrier is doing.
	var ctx: RoleContext = _make_ctx(Vector3(0.0, 0.0, 6.0), [
			[2, TEAM_ID, Vector3(2.0, 0.0, -18.0)],
			[10, 1, Vector3(1.0, 0.0, 14.0), Vector3(0.0, 0.0, 7.0)],
	], 2)
	var d: RoleDecision = AIRoleDefenseman.decide(ctx, AIRoleSlots.Slot.DVALVE)
	# The un-threatened trail point would sit a zone behind the carrier
	# (z ≈ -8); the burner already deep behind the valve must pull the stand
	# well into our half, near even with him — never left playing catch-up.
	assert_gt(d.target_position.z, 5.0,
			"a deep burner pulls the valve home toward even; got %s"
			% d.target_position)


# ── NEUTRAL back pair ────────────────────────────────────────────────────────

func test_dback_holds_side_posts_at_our_blue_line() -> void:
	var ctx: RoleContext = _make_ctx(Vector3(-4.0, 0.0, 6.0), [],
			-1, Vector3(0.0, 0.0, -2.0))
	var left: RoleDecision = AIRoleDefenseman.decide(ctx, AIRoleSlots.Slot.DBACK_L)
	var right: RoleDecision = AIRoleDefenseman.decide(ctx, AIRoleSlots.Slot.DBACK_R)
	assert_lt(left.target_position.x, 0.0)
	assert_gt(right.target_position.x, 0.0)
	assert_almost_eq(left.target_position.z, GameRules.BLUE_LINE_Z, 0.1)


func test_dback_shades_with_the_puck() -> void:
	var ctx: RoleContext = _make_ctx(Vector3(-4.0, 0.0, 6.0), [],
			-1, Vector3(10.0, 0.0, -2.0))
	var left: RoleDecision = AIRoleDefenseman.decide(ctx, AIRoleSlots.Slot.DBACK_L)
	assert_gt(left.target_position.x, -5.0,
			"the back post slides toward the puck side, bounded")
