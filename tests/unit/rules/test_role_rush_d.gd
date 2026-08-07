extends GutTest

# AIRoleRushD — the rush D pair (docs/transition-defense-plan.md §5–§6).
# Team 0 defends +Z and attacks -Z; peer 1 is the bot under test, peer 10 is
# the opposing carrier. A rush at us travels in +Z.

const TEAM_ID: int = 0
const OUR_NET_Z: float = 26.65
const STICK: float = 2.0


# `support_behind` puts a teammate home between us and our net. It is ON by
# default because it makes the LAST-MAN STEP-UP BOUND inert
# (AIRoleRushD._settable_gap), and every case below is about the ladder, the
# numbers rungs, or the angling — one variable each, per this file's premise.
# The bound now only survives for a LOOSE puck (a live carrier is a frame the
# route regulates on its own), and there it still dominates these fixtures:
# they place the D 9-16 m goal-side of the stand he is being asked to take,
# which is a step-up no ice-frame seek arrives at set, so the ladder underneath
# would be invisible.
func _ctx(self_pos: Vector3, skaters: Array, carrier_pid: int,
		numbers: int = AIRushRead.Numbers.EVEN_OR_UP,
		backpressure: float = INF, support_behind: bool = true) -> RoleContext:
	var snap := WorldSnapshot.new()
	var s := SkaterNetworkState.new()
	s.position = self_pos
	snap.skater_states[1] = s
	var team_map: Dictionary = {1: TEAM_ID}
	if support_behind:
		var home := SkaterNetworkState.new()
		home.position = Vector3(0.0, 0.0, OUR_NET_Z - 2.0)
		snap.skater_states[2] = home
		team_map[2] = TEAM_ID
	for e: Array in skaters:
		var sk := SkaterNetworkState.new()
		sk.position = e[2]
		sk.velocity = e[3] if e.size() > 3 else Vector3.ZERO
		snap.skater_states[e[0]] = sk
		team_map[e[0]] = e[1]
	var puck := PuckNetworkState.new()
	puck.carrier_peer_id = carrier_pid
	puck.position = snap.skater_states[carrier_pid].position \
			if snap.skater_states.has(carrier_pid) else Vector3.ZERO
	snap.puck_state = puck

	var ctx := RoleContext.new()
	ctx.snapshot = snap
	ctx.self_pos = self_pos
	ctx.team_id = TEAM_ID
	ctx.peer_id = 1
	ctx.attacking_goal_pos = Vector3(0.0, 0.0, -OUR_NET_Z)
	ctx.defending_goal_pos = Vector3(0.0, 0.0, OUR_NET_Z)
	ctx.own_goal_dir = 1.0
	ctx.team_id_by_peer = team_map
	ctx.team_size = 5
	ctx.self_is_defense = true
	ctx.self_home_side = 1.0
	ctx.self_blade_reach = STICK
	# A live read with the posture under test. Filled directly rather than via
	# a brain so each case pins one variable.
	var read := AIRushRead.new()
	read.fill(snap, TEAM_ID, OUR_NET_Z, team_map, {}, {})
	read.numbers = numbers
	read.backpressure_s = backpressure
	ctx.rush_read = read
	# The lane fan is a separate concern; keep these cases on the ladder.
	ctx.plays_rush_pass_lanes = false
	return ctx


# The gap the model actually holds, measured against the carrier's VELOCITY-LED
# point — the reference the role builds its stand off (AIRoleHelpers.lead_threat).
# Measuring off the raw body instead folds the lead distance into every reading,
# which at rush speeds is a couple of metres of pure artifact.
func _led(carrier: Vector3, vel: Vector3) -> Vector3:
	return AIRoleHelpers.lead_threat(carrier, vel, 1.0)


func _gap(d: RoleDecision, carrier: Vector3, vel: Vector3 = Vector3.ZERO) -> float:
	var ref: Vector3 = _led(carrier, vel)
	return Vector2(d.target_position.x, d.target_position.z).distance_to(
			Vector2(ref.x, ref.z))


# ── The gap ladder: ice remaining, not pace ──────────────────────────────────

func test_gap_tightens_as_the_carrier_approaches_our_blue_line() -> void:
	# The doctrine ladder: ~3 sticks at their blue line, 2 at the red line, 1 at
	# ours. The old model was a function of PACE, so a carrier at full flight
	# held a ~3-stick gap all the way to our net — that is the sag.
	var far_carrier := Vector3(0.0, 0.0, -7.29)   # their blue line
	var mid_carrier := Vector3(0.0, 0.0, 0.0)     # red line
	var near_carrier := Vector3(0.0, 0.0, 7.29)   # our blue line
	var vel := Vector3(0.0, 0.0, 7.0)
	var gaps: Array[float] = []
	for c: Vector3 in [far_carrier, mid_carrier, near_carrier]:
		var ctx: RoleContext = _ctx(Vector3(0.0, 0.0, 16.0),
				[[10, 1, c, vel]], 10,
				AIRushRead.Numbers.DOWN_ONE)   # neutral rung: no tighten/loosen
		var d: RoleDecision = AIRoleRushD.decide(ctx, AIRoleSlots.Slot.RUSH_D1)
		gaps.append(_gap(d, c, vel))
	assert_gt(gaps[0], gaps[1], "gap shrinks from their blue line to the red line")
	assert_gt(gaps[1], gaps[2], "gap shrinks from the red line to ours")
	assert_lt(gaps[2], 2.5 * STICK,
			"at our own blue line the gap is tight, not a 3-stick sag; got %.2f m"
			% gaps[2])


func test_pace_alone_cannot_produce_the_old_sag() -> void:
	# Same spot on the ice, wildly different closing speeds. Pace is now a
	# correction capped at half a stick, so it can no longer be the driver.
	var carrier := Vector3(0.0, 0.0, 4.0)
	var slow_ctx: RoleContext = _ctx(Vector3(0.0, 0.0, 16.0),
			[[10, 1, carrier, Vector3(0.0, 0.0, 4.0)]], 10,
			AIRushRead.Numbers.DOWN_ONE)
	var fast_ctx: RoleContext = _ctx(Vector3(0.0, 0.0, 16.0),
			[[10, 1, carrier, Vector3(0.0, 0.0, 9.0)]], 10,
			AIRushRead.Numbers.DOWN_ONE)
	var slow: float = _gap(
			AIRoleRushD.decide(slow_ctx, AIRoleSlots.Slot.RUSH_D1), carrier,
			Vector3(0.0, 0.0, 4.0))
	var fast: float = _gap(
			AIRoleRushD.decide(fast_ctx, AIRoleSlots.Slot.RUSH_D1), carrier,
			Vector3(0.0, 0.0, 9.0))
	assert_lt(absf(fast - slow), AIRoleRushD.PACE_CORRECTION_MAX_STICKS * STICK + 0.01,
			"pace moves the gap by at most half a stick; slow=%.2f fast=%.2f"
			% [slow, fast])


# ── Numbers ──────────────────────────────────────────────────────────────────

func test_even_numbers_tighten_the_gap() -> void:
	var carrier := Vector3(0.0, 0.0, 0.0)
	var even: RoleContext = _ctx(Vector3(0.0, 0.0, 16.0),
			[[10, 1, carrier, Vector3(0.0, 0.0, 6.0)]], 10,
			AIRushRead.Numbers.EVEN_OR_UP)
	var down: RoleContext = _ctx(Vector3(0.0, 0.0, 16.0),
			[[10, 1, carrier, Vector3(0.0, 0.0, 6.0)]], 10,
			AIRushRead.Numbers.DOWN_ONE)
	assert_lt(_gap(AIRoleRushD.decide(even, AIRoleSlots.Slot.RUSH_D1), carrier, Vector3(0.0, 0.0, 6.0)),
			_gap(AIRoleRushD.decide(down, AIRoleSlots.Slot.RUSH_D1), carrier, Vector3(0.0, 0.0, 6.0)),
			"even numbers is licence to stand up")


func test_down_one_does_not_concede_depth() -> void:
	# The failure mode this exists to prevent: conceding DEPTH on an odd-man
	# rush turns a 2-on-1 into a breakaway. An odd-man concession is lateral.
	var carrier := Vector3(0.0, 0.0, 0.0)
	var down_one: RoleContext = _ctx(Vector3(0.0, 0.0, 16.0),
			[[10, 1, carrier, Vector3(0.0, 0.0, 6.0)]], 10,
			AIRushRead.Numbers.DOWN_ONE)
	var down_two: RoleContext = _ctx(Vector3(0.0, 0.0, 16.0),
			[[10, 1, carrier, Vector3(0.0, 0.0, 6.0)]], 10,
			AIRushRead.Numbers.DOWN_TWO_PLUS)
	assert_lt(_gap(AIRoleRushD.decide(down_one, AIRoleSlots.Slot.RUSH_D1), carrier, Vector3(0.0, 0.0, 6.0)),
			_gap(AIRoleRushD.decide(down_two, AIRoleSlots.Slot.RUSH_D1), carrier, Vector3(0.0, 0.0, 6.0)),
			"DOWN_ONE holds its depth; only DOWN_TWO_PLUS buys time with ground")


func test_backpressure_lets_the_d_stand_up() -> void:
	var carrier := Vector3(0.0, 0.0, 0.0)
	var alone: RoleContext = _ctx(Vector3(0.0, 0.0, 16.0),
			[[10, 1, carrier, Vector3(0.0, 0.0, 6.0)]], 10,
			AIRushRead.Numbers.DOWN_ONE, INF)
	var helped: RoleContext = _ctx(Vector3(0.0, 0.0, 16.0),
			[[10, 1, carrier, Vector3(0.0, 0.0, 6.0)]], 10,
			AIRushRead.Numbers.DOWN_ONE, 0.8)
	assert_lt(_gap(AIRoleRushD.decide(helped, AIRoleSlots.Slot.RUSH_D1), carrier, Vector3(0.0, 0.0, 6.0)),
			_gap(AIRoleRushD.decide(alone, AIRoleSlots.Slot.RUSH_D1), carrier, Vector3(0.0, 0.0, 6.0)),
			"a backchecker on his hip lets the D tighten and stand up")


# ── The stand rides the carrier ──────────────────────────────────────────────
# The ladder says where the stand IS. What used to answer "may I take the trip to
# it?" was a stand-PLACEMENT bound (AIRoleHelpers.settable_stand_depth): hold the
# stand back to where a charge would end set, because an ice-frame seek could only
# ever reach a spot by charging it and braking to zero.
#
# The route answers it now. RUSH_D1 publishes the stand's own velocity and the
# steering flies the whole approach in that frame (AISteering, "moving-frame
# pursuit"), where the commanded velocity is the stand's plus a closing term that
# decays to nothing on arrival — so the trip ENDS matched to the rush by
# construction, and there is no charge left to bound. Running both put two
# controllers on one axis: the bound charges for a pivot the route no longer
# performs, which placed the stand within 0.3 m of wherever the D already stood,
# and a D whose stand is always where he is never closes on anybody.
#
# The behavioural half of this — how much up-ice speed he actually carries into
# the meet — is pinned in tests/unit/ai/test_rush_gap_discipline.gd, which
# measures the body over multi-second rushes. That is the only place it can
# honestly live; a single dispatch cannot see a route. Here we pin the contract
# the route is built on.

func test_the_stand_publishes_the_carriers_velocity() -> void:
	var carrier := Vector3(0.0, 0.0, 0.0)
	var vel := Vector3(0.0, 0.0, 7.0)
	var ctx: RoleContext = _ctx(Vector3(0.0, 0.0, 20.0),
			[[10, 1, carrier, vel]], 10, AIRushRead.Numbers.DOWN_ONE, INF, false)
	var d: RoleDecision = AIRoleRushD.decide(ctx, AIRoleSlots.Slot.RUSH_D1)
	assert_almost_eq(d.target_velocity.z, vel.z, 0.01,
			"the gap stand rides the man it gaps; got %.2f" % d.target_velocity.z)


func test_the_ladder_is_the_stand_whether_or_not_anyone_is_home() -> void:
	# The last man reads the SAME gap as a D with a layer behind him: the route
	# regulates his approach, so his depth no longer has to. (The numbers rungs
	# still move the gap — that is the shared read, and a different question.)
	var carrier := Vector3(0.0, 0.0, 0.0)      # red line, coming at pace
	var vel := Vector3(0.0, 0.0, 7.0)
	var alone: RoleContext = _ctx(Vector3(0.0, 0.0, 20.0),
			[[10, 1, carrier, vel]], 10, AIRushRead.Numbers.DOWN_ONE, INF, false)
	var layered: RoleContext = _ctx(Vector3(0.0, 0.0, 20.0),
			[[10, 1, carrier, vel]], 10, AIRushRead.Numbers.DOWN_ONE, INF, true)
	assert_almost_eq(
			_gap(AIRoleRushD.decide(alone, AIRoleSlots.Slot.RUSH_D1), carrier, vel),
			_gap(AIRoleRushD.decide(layered, AIRoleSlots.Slot.RUSH_D1), carrier, vel),
			0.05, "the last man reads the ladder, not a depth bound")


func test_a_loose_puck_keeps_the_ice_frame_bound() -> void:
	# There is no man to ride when the puck is loose — a puck is decelerating and
	# unowned, and nobody gaps up on one — so the stand is a point on the ice
	# again and the last-man bound is still the thing that governs the trip.
	var puck := Vector3(0.0, 0.0, 0.0)
	var alone: RoleContext = _ctx(Vector3(0.0, 0.0, 20.0),
			[[10, 1, puck, Vector3(0.0, 0.0, 7.0)]], -1,
			AIRushRead.Numbers.DOWN_ONE, INF, false)
	alone.snapshot.puck_state.position = puck
	alone.snapshot.puck_state.velocity = Vector3(0.0, 0.0, 7.0)
	var layered: RoleContext = _ctx(Vector3(0.0, 0.0, 20.0),
			[[10, 1, puck, Vector3(0.0, 0.0, 7.0)]], -1,
			AIRushRead.Numbers.DOWN_ONE, INF, true)
	layered.snapshot.puck_state.position = puck
	layered.snapshot.puck_state.velocity = Vector3(0.0, 0.0, 7.0)
	var d_alone: RoleDecision = AIRoleRushD.decide(alone, AIRoleSlots.Slot.RUSH_D1)
	assert_eq(d_alone.target_velocity, Vector3.ZERO,
			"a loose puck is not a frame to hold station in")
	assert_gt(_gap(d_alone, puck, Vector3(0.0, 0.0, 7.0)),
			_gap(AIRoleRushD.decide(layered, AIRoleSlots.Slot.RUSH_D1), puck,
					Vector3(0.0, 0.0, 7.0)),
			"the last man still holds ice he cannot cover set")


# ── Gap up ───────────────────────────────────────────────────────────────────

func test_gap_up_when_the_carrier_has_no_speed() -> void:
	# The concept the pace model could not express: his speed advantage is gone,
	# so ATTACK rather than merely fear him less.
	var carrier := Vector3(0.0, 0.0, 0.0)
	var ctx: RoleContext = _ctx(Vector3(0.0, 0.0, 16.0),
			[[10, 1, carrier, Vector3(0.0, 0.0, 0.5)]], 10,
			AIRushRead.Numbers.DOWN_ONE)
	var d: RoleDecision = AIRoleRushD.decide(ctx, AIRoleSlots.Slot.RUSH_D1)
	var vel := Vector3(0.0, 0.0, 0.5)
	assert_lt(_gap(d, carrier, vel), 1.6 * STICK,
			"a stalled carrier is met at challenge range; got %.2f m"
			% _gap(d, carrier, vel))


func test_no_gap_up_when_outnumbered_by_two() -> void:
	# Stepping up into a rush you're two men down is how a scoring chance
	# becomes a goal. The trigger must respect the numbers.
	var carrier := Vector3(0.0, 0.0, 0.0)
	var ctx: RoleContext = _ctx(Vector3(0.0, 0.0, 16.0),
			[[10, 1, carrier, Vector3(0.0, 0.0, 0.5)]], 10,
			AIRushRead.Numbers.DOWN_TWO_PLUS)
	var d: RoleDecision = AIRoleRushD.decide(ctx, AIRoleSlots.Slot.RUSH_D1)
	assert_gt(_gap(d, carrier, Vector3(0.0, 0.0, 0.5)), 1.6 * STICK,
			"down two, hold the cushion even against a slow carrier")


func test_gap_up_against_a_carrier_pinned_to_the_wall() -> void:
	# No support behind on purpose: the gap-up is exempt from the last-man
	# step-up bound, because a carrier with no outside left cannot beat the
	# challenge with the pace that bound exists to respect.
	var carrier := Vector3(GameRules.INNER_HALF_WIDTH - 1.0, 0.0, 2.0)
	var ctx: RoleContext = _ctx(Vector3(6.0, 0.0, 16.0),
			[[10, 1, carrier, Vector3(0.0, 0.0, 7.0)]], 10,
			AIRushRead.Numbers.DOWN_ONE, INF, false)
	var d: RoleDecision = AIRoleRushD.decide(ctx, AIRoleSlots.Slot.RUSH_D1)
	assert_lt(_gap(d, carrier, Vector3(0.0, 0.0, 7.0)), 1.6 * STICK,
			"a carrier with no outside left gets challenged")


# ── Angling and floors ───────────────────────────────────────────────────────

func test_stand_shades_inside_to_steer_him_wide() -> void:
	# Take away the middle, give the outside. A stand dead on the carrier→net
	# line offers both lanes equally.
	var carrier := Vector3(8.0, 0.0, 0.0)
	var ctx: RoleContext = _ctx(Vector3(6.0, 0.0, 16.0),
			[[10, 1, carrier, Vector3(0.0, 0.0, 7.0)]], 10,
			AIRushRead.Numbers.DOWN_ONE)
	var d: RoleDecision = AIRoleRushD.decide(ctx, AIRoleSlots.Slot.RUSH_D1)
	var led: Vector3 = _led(carrier, Vector3(0.0, 0.0, 7.0))
	var on_line_x: float = led.x + (0.0 - led.x) \
			* (_gap(d, carrier, Vector3(0.0, 0.0, 7.0))
					/ led.distance_to(Vector3(0, 0, OUR_NET_Z)))
	assert_lt(d.target_position.x, on_line_x,
			"the stand shades to the inside of the retreat line")


func test_never_stands_deeper_than_the_house_gate() -> void:
	# A rush role on the goal line duplicates the goalie. The doorstep belongs
	# to in-zone coverage, which is a different state.
	var carrier := Vector3(0.0, 0.0, 24.0)   # already at our doorstep
	var ctx: RoleContext = _ctx(Vector3(0.0, 0.0, 25.0),
			[[10, 1, carrier, Vector3(0.0, 0.0, 2.0)]], 10,
			AIRushRead.Numbers.DOWN_TWO_PLUS)
	var d: RoleDecision = AIRoleRushD.decide(ctx, AIRoleSlots.Slot.RUSH_D1)
	assert_lte(d.target_position.z, OUR_NET_Z - AIZoneCoverage.HOUSE_TOP_DEPTH_M + 0.01,
			"the stand is clamped to the top of the circles; got %s"
			% d.target_position)


# ── RUSH_D2 ──────────────────────────────────────────────────────────────────

func test_d2_takes_the_mid_lane_driver() -> void:
	# "The mid-lane drive is fed to D2": of the two non-carrier attackers, D2
	# covers the one driving the middle, not the one out on the wall.
	var ctx: RoleContext = _ctx(Vector3(0.0, 0.0, 18.0), [
		[10, 1, Vector3(-9.0, 0.0, 4.0), Vector3(0.0, 0.0, 7.0)],   # carrier, wide
		[11, 1, Vector3(0.5, 0.0, 5.0), Vector3(0.0, 0.0, 7.0)],    # mid-lane drive
		[12, 1, Vector3(10.0, 0.0, 5.0), Vector3(0.0, 0.0, 7.0)],   # far wall
	], 10)
	var d: RoleDecision = AIRoleRushD.decide(ctx, AIRoleSlots.Slot.RUSH_D2)
	assert_lt(absf(d.target_position.x), 6.0,
			"D2 covers the middle driver, not the wall man; got %s"
			% d.target_position)


func test_d2_holds_mid_ice_with_nobody_driving() -> void:
	var ctx: RoleContext = _ctx(Vector3(0.0, 0.0, 18.0),
			[[10, 1, Vector3(0.0, 0.0, 2.0), Vector3(0.0, 0.0, 7.0)]], 10)
	var d: RoleDecision = AIRoleRushD.decide(ctx, AIRoleSlots.Slot.RUSH_D2)
	assert_lt(absf(d.target_position.x), 6.0, "D2 holds mid-ice")
	assert_lt(d.target_position.z, OUR_NET_Z,
			"and stays in front of the net, not on it")


# ── Inside angling scales with the carrier's own lateral offset ──────────────
# The shade takes away the middle. A carrier already IN the middle has no inside
# to take, so the depth goes to zero there — which is also what makes the two
# sides meet continuously instead of the stand jumping across as he crosses
# centre.

func _stand_for_carrier_x(carrier_x: float) -> Vector3:
	var ctx: RoleContext = _ctx(Vector3(0.0, 0.0, 14.0), [
		[10, 1, Vector3(carrier_x, 0.0, 0.0), Vector3(0.0, 0.0, 7.0)],
	], 10)
	return AIRoleRushD.decide(ctx, AIRoleSlots.Slot.RUSH_D1).target_position


func test_a_centre_lane_carrier_gets_no_lateral_shade() -> void:
	var stand: Vector3 = _stand_for_carrier_x(0.0)
	assert_almost_eq(stand.x, 0.0, 0.05,
			"dead centre there is no inside to take away; got %s" % stand)


func test_the_shade_does_not_jump_across_centre() -> void:
	# The defect: a fixed shade had to pick a side, so the stand flipped a full
	# 2x ANGLE_INSIDE_M between a carrier a centimetre either side of x = 0.
	var left: Vector3 = _stand_for_carrier_x(-0.05)
	var right: Vector3 = _stand_for_carrier_x(0.05)
	assert_lt(absf(left.x - right.x), 0.15,
			"the stand must be continuous through centre; got %s vs %s"
			% [left, right])


func test_a_wide_carrier_is_shaded_toward_the_middle() -> void:
	# Out at the dot lane the inside/outside split is real and the full shade
	# applies — toward centre, i.e. the opposite side from the carrier.
	var stand: Vector3 = _stand_for_carrier_x(GameRules.END_ZONE_FACEOFF_DOT_X)
	assert_lt(stand.x, GameRules.END_ZONE_FACEOFF_DOT_X,
			"shaded inside of the carrier, not outside him; got %s" % stand)
	var mid: Vector3 = _stand_for_carrier_x(GameRules.END_ZONE_FACEOFF_DOT_X * 0.5)
	var wide_shade: float = GameRules.END_ZONE_FACEOFF_DOT_X - stand.x
	var mid_shade: float = GameRules.END_ZONE_FACEOFF_DOT_X * 0.5 - mid.x
	assert_gt(wide_shade, mid_shade,
			"the shade deepens as the carrier gets wider (%.2f vs %.2f)"
			% [wide_shade, mid_shade])


func test_the_shade_is_mirror_symmetric() -> void:
	var left: Vector3 = _stand_for_carrier_x(-GameRules.END_ZONE_FACEOFF_DOT_X)
	var right: Vector3 = _stand_for_carrier_x(GameRules.END_ZONE_FACEOFF_DOT_X)
	assert_almost_eq(left.x, -right.x, 0.05,
			"both wings are angled the same way; got %s vs %s" % [left, right])


# ── RUSH_D2 only leaves mid-ice for a genuinely mid-lane man ─────────────────
# D2's whole job is the middle. Picking argmin|x| over the rush with no bound
# meant a lone second attacker on the boards read as "the mid-lane drive" and
# pulled him off the lane the layered defense keeps him in.

func _d2_target(second_x: float) -> Vector3:
	var ctx: RoleContext = _ctx(Vector3(-2.0, 0.0, 16.0), [
		[10, 1, Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.0, 7.0)],       # carrier
		[11, 1, Vector3(second_x, 0.0, 2.0), Vector3(0.0, 0.0, 7.0)],  # second man
	], 10)
	return AIRoleRushD.decide(ctx, AIRoleSlots.Slot.RUSH_D2).target_position


func test_d2_covers_a_man_driving_the_middle() -> void:
	var target: Vector3 = _d2_target(1.5)
	assert_lt(absf(target.x - 1.5), 6.0,
			"a man in the middle is D2's to take; got %s" % target)


func test_d2_holds_mid_ice_against_a_wall_man() -> void:
	# Outside the dot lane he is the mid trackers' pickup as he cuts in, not
	# D2's to chase — chasing him vacates the middle.
	var wall_x: float = GameRules.END_ZONE_FACEOFF_DOT_X + 3.0
	var target: Vector3 = _d2_target(wall_x)
	assert_lt(absf(target.x), absf(wall_x) * 0.5,
			"D2 stays central instead of chasing the wall man; got %s" % target)


func test_the_mid_lane_band_is_the_dot_lane() -> void:
	# Just inside the dots is his; just outside is not. Pinned so the boundary
	# can't drift without the intent being restated.
	var inside: Vector3 = _d2_target(GameRules.END_ZONE_FACEOFF_DOT_X - 0.5)
	var outside: Vector3 = _d2_target(GameRules.END_ZONE_FACEOFF_DOT_X + 0.5)
	assert_gt(absf(inside.x), absf(outside.x),
			"the man inside the dots pulls D2 wider than the one outside them; "
			+ "got %s vs %s" % [inside, outside])
