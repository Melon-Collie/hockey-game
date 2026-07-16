class_name AIRoleDefenseman

# The off-puck defenseman (5v5 only) — one module, four game moments, one
# philosophy: hold the structure, keep the race home winnable, threaten from
# the line. Design: plan §4; researched point play + gap doctrine in the
# plan's appendix.
#
#   OZONE points (POINT_STRONG / POINT_WEAK) — hold the offensive blue line
#     and WALK IT: a small lateral argmax opens a shooting lane (lane_clear
#     toward the net — the "walking the line" technique: move to open the
#     lane, don't stand in cover). The strong point sinks down his wall as
#     the cycle goes low (the researched staggered pair); every candidate is
#     hard-bounded by the race home (never pinned so deep a counter beats
#     you back — the keep-in insurance).
#   FORECHECK line pair (DP_STRONG / DP_WEAK) — hold the offensive blue line
#     inside the dots, per lane, sagging down the NZ exactly like the 3v3
#     forecheck's F3 when the race home stops being winnable (a stretch
#     threat lurking behind the line pulls the pair off it).
#   TRANS_DO safety valve (DVALVE) — trail the rush centrally about a zone
#     behind the play, capped by the race-home radius: always the reset
#     option, never beaten home.
#   NEUTRAL back shape (DBACK_L / DBACK_R) — the staggered goal-side pair
#     inside the dots at our blue line, shading with the puck's lateral
#     drift (the NZ 1-2-2's back wall).

# Blue-line hold: how far inside the offensive zone the points stand.
const POINT_INSET_M: float = 1.0
# Strong point's extra sink row when the cycle is low (puck below the dots)
# — toward the top of his circle, the researched wall slide.
const POINT_SINK_M: float = 3.5
const POINT_SINK_PUCK_DEPTH_M: float = 6.0
# Lateral walk-the-line samples (strong-signed u = s·x), wall → middle.
const POINT_STRONG_LANES_U: Array[float] = [9.5, 7.5, 5.5, 3.5, 1.5]
const POINT_WEAK_LANES_U: Array[float] = [6.0, 4.5, 3.0, 1.5, 0.0]
# Forecheck line pair lanes (world-x magnitude, inside the dots).
const DP_STRONG_LANE_X_M: float = 6.7
const DP_WEAK_LANE_X_M: float = 5.0
# NZ side of the line the pair stands on during the forecheck.
const DP_STAND_BACK_M: float = 0.5
# DVALVE: how far behind the play the valve trails, and its goal-line cap.
const DVALVE_TRAIL_M: float = 10.0
const DVALVE_GOAL_LINE_PAD_M: float = 2.0
# DBACK posts: inside the dots at our blue line, with a small puck shade.
const DBACK_X_M: float = 5.0
const DBACK_PUCK_SHADE: float = 0.2
const DBACK_SHADE_MAX_M: float = 1.5


static func decide(ctx: RoleContext, slot: int) -> RoleDecision:
	match slot:
		AIRoleSlots.Slot.POINT_STRONG:
			return _decide_point(ctx, true)
		AIRoleSlots.Slot.POINT_WEAK:
			return _decide_point(ctx, false)
		AIRoleSlots.Slot.DP_STRONG:
			return _decide_line_hold(ctx, ctx.strong_x * DP_STRONG_LANE_X_M)
		AIRoleSlots.Slot.DP_WEAK:
			return _decide_line_hold(ctx, -ctx.strong_x * DP_WEAK_LANE_X_M)
		AIRoleSlots.Slot.DVALVE:
			return _decide_valve(ctx)
		AIRoleSlots.Slot.DBACK_L:
			return _decide_back(ctx, -1.0)
		AIRoleSlots.Slot.DBACK_R:
			return _decide_back(ctx, 1.0)
		_:
			var d := RoleDecision.new()
			d.target_position = ctx.anchor if ctx.anchor != Vector3.ZERO else ctx.self_pos
			return d


# ── OZONE point play: hold the line, walk it for a lane ─────────────────────
static func _decide_point(ctx: RoleContext, is_strong: bool) -> RoleDecision:
	var d := RoleDecision.new()
	var own_dir: float = ctx.own_goal_dir
	var opp_net: Vector3 = ctx.attacking_goal_pos
	var line_z: float = -own_dir * (GameRules.BLUE_LINE_Z + POINT_INSET_M)
	var side: float = ctx.strong_x if is_strong else -ctx.strong_x

	var opp_positions: Array[Vector3] = ctx.scratch_opp_positions
	var opp_states: Array[SkaterNetworkState] = ctx.scratch_opp_states
	AIRoleHelpers.collect_opponents(ctx, opp_positions, opp_states)
	var teammates: Array[Vector3] = ctx.scratch_teammates
	AIRoleHelpers.collect_teammates_excluding_self(ctx, teammates)
	var our_net: Vector3 = ctx.defending_goal_pos
	# Keep-in insurance: every stand must stay inside the race home against
	# the fastest opponent — a pinned point that can't recover is the odd-man
	# rush factory the exposure term prices for the carrier (§6); off-puck we
	# simply refuse the spot.
	var r_home: float = AIRoleHelpers.race_home_radius(ctx, opp_states, our_net)

	# The strong point sinks a row down his wall when the cycle is low —
	# puck depth measured off the ATTACKED goal line (depth_of takes the
	# reference net's z; opp_net is the net whose zone we're cycling).
	var puck_depth: float = INF
	if ctx.snapshot != null and ctx.snapshot.puck_state != null:
		puck_depth = AIZoneCoverage.depth_of(
				opp_net.z, ctx.snapshot.puck_state.position)
	var allow_sink: bool = is_strong and puck_depth < POINT_SINK_PUCK_DEPTH_M

	var lanes: Array[float] = POINT_STRONG_LANES_U if is_strong else POINT_WEAK_LANES_U
	var shot_speed: float = ctx.self_wrister_shot_speed
	var base_stand := Vector3(side * lanes[0], 0.0, line_z)
	var best_pos: Vector3 = base_stand
	var best_score: float = -INF
	for u: float in lanes:
		for row: int in (2 if allow_sink else 1):
			var z: float = line_z - own_dir * (POINT_SINK_M * float(row))
			var c := Vector3(side * u, 0.0, z)
			if not AIRoleHelpers.is_legal_position(c):
				continue
			if c.distance_to(our_net) > r_home:
				continue
			if AIRoleHelpers.too_close_to_teammate(c, teammates):
				continue
			# Walking the line: prefer the stand whose SHOT LANE is open —
			# lane_clear from the candidate to the net at this D's real shot
			# speed, i.e. "could I get my point shot through from here?".
			var lane: float = AIActionScoring.lane_clear(
					c, opp_net, opp_positions, shot_speed)
			var score: float = lane + AIRoleHelpers.incumbent_bonus(ctx, c)
			if score > best_score:
				best_score = score
				best_pos = c
	if best_score == -INF:
		# Every stand failed the keep-in bound (a stretch threat lurking
		# behind the line): sag home along the retreat line to the edge of
		# the winnable-race circle instead of standing at an unrecoverable
		# point.
		var back: Vector3 = base_stand - our_net
		var back_len: float = back.length()
		if back_len > 0.001 and r_home < back_len:
			best_pos = our_net + back * (maxf(r_home, 0.0) / back_len)
	d.target_position = best_pos
	return d


# ── FORECHECK: hold the offensive blue line while the race home holds ───────
# The 3v3 forecheck-F3 bounded hold, applied per lane for the D pair: stand
# at the line on your lane; as a breakout/stretch threat develops, the
# race-home circle shrinks and the stand slides down the NZ toward home.
static func _decide_line_hold(ctx: RoleContext, lane_x: float) -> RoleDecision:
	var d := RoleDecision.new()
	var own_dir: float = ctx.own_goal_dir
	var line_z: float = -own_dir * (GameRules.BLUE_LINE_Z - DP_STAND_BACK_M)

	var opp_positions: Array[Vector3] = ctx.scratch_opp_positions
	var opp_states: Array[SkaterNetworkState] = ctx.scratch_opp_states
	AIRoleHelpers.collect_opponents(ctx, opp_positions, opp_states)
	var our_net: Vector3 = ctx.defending_goal_pos
	var r: float = AIRoleHelpers.race_home_radius(ctx, opp_states, our_net)

	var hold_z: float = line_z
	if r < INF:
		var dx: float = lane_x - our_net.x
		var lane_reach_sq: float = r * r - dx * dx
		var lane_reach: float = sqrt(lane_reach_sq) if lane_reach_sq > 0.0 else 0.0
		var allowed_fwd: float = own_dir * our_net.z - lane_reach
		hold_z = own_dir * maxf(own_dir * line_z, allowed_fwd)
	d.target_position = Vector3(lane_x, 0.0, hold_z)
	return d


# ── TRANS_DO: the safety valve ───────────────────────────────────────────────
static func _decide_valve(ctx: RoleContext) -> RoleDecision:
	var d := RoleDecision.new()
	var own_dir: float = ctx.own_goal_dir
	var play_ref: Vector3 = AIRoleHelpers.resolve_offensive_play_ref(ctx)
	if not play_ref.is_finite():
		d.target_position = ctx.self_pos
		return d
	# Trail the play centrally, one zone behind, never behind our goal line.
	var cap: float = GameRules.GOAL_LINE_Z - DVALVE_GOAL_LINE_PAD_M
	var trail_z: float = clampf(play_ref.z + own_dir * DVALVE_TRAIL_M, -cap, cap)
	var target := Vector3(0.0, 0.0, trail_z)
	# Race-home cap: the valve's whole job is to never be beaten home.
	var opp_positions: Array[Vector3] = ctx.scratch_opp_positions
	var opp_states: Array[SkaterNetworkState] = ctx.scratch_opp_states
	AIRoleHelpers.collect_opponents(ctx, opp_positions, opp_states)
	var our_net: Vector3 = ctx.defending_goal_pos
	var r: float = AIRoleHelpers.race_home_radius(ctx, opp_states, our_net)
	if r < INF and target.distance_to(our_net) > r:
		var back: Vector3 = target - our_net
		var dist: float = back.length()
		if dist > 0.001:
			target = our_net + back * (r / dist)
	d.target_position = target
	# The rush advances every tick — pace the waypoint, don't brake at it.
	d.arrive_at_speed = true
	return d


# ── NEUTRAL: the goal-side back pair ─────────────────────────────────────────
static func _decide_back(ctx: RoleContext, side: float) -> RoleDecision:
	var d := RoleDecision.new()
	var own_dir: float = ctx.own_goal_dir
	var x: float = side * DBACK_X_M
	if ctx.snapshot != null and ctx.snapshot.puck_state != null:
		# Shade with the puck's lateral drift — the back wall slides, it
		# doesn't chase.
		x += clampf(ctx.snapshot.puck_state.position.x * DBACK_PUCK_SHADE,
				-DBACK_SHADE_MAX_M, DBACK_SHADE_MAX_M)
	d.target_position = Vector3(x, 0.0, own_dir * GameRules.BLUE_LINE_Z)
	return d
