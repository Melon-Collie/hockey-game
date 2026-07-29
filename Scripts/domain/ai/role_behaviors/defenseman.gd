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
#     the cycle goes low (the researched staggered pair); the chosen stand is
#     then bounded by the shared pinch read (never held with a man behind you
#     and nobody covering — the keep-in insurance).
#   FORECHECK line pair (DP_STRONG / DP_WEAK) — pinch to the top of the
#     end-zone circles, per lane, and abandon it for the defensive home post
#     the moment their breakout is genuinely under way — exactly like the 3v3
#     forecheck's F3, which runs the same read.
#   TRANS_DO safety valve (DVALVE) — trail the rush centrally about a zone
#     behind the play, capped by the race-home radius: always the reset
#     option, never beaten home.
#   NEUTRAL back shape (DBACK_L / DBACK_R) — the staggered goal-side pair
#     inside the dots at our blue line, shading with the puck's lateral
#     drift (the NZ 1-2-2's back wall).

# Blue-line hold: how far inside the offensive zone the points stand — a
# full puck-handling radius, so a catch's give or a backswing at the point
# never drags the puck back across the line (the puck leaving the zone
# un-onsides the entire attack; at the old 1 m inset a routine reception's
# cushion did exactly that).
const POINT_INSET_M: float = 2.0
# Strong point's extra sink rows when the cycle is low (puck below the dots)
# — down his wall toward the top of his circle, the researched wall slide.
# Two rows: with the whole defense collapsed low, a point glued to the line
# is no option for anything but a recycle; the keep-in feasibility below is
# what bounds how deep the walk may follow the play.
const POINT_SINK_M: float = 3.5
const POINT_SINK_ROWS: int = 2
const POINT_SINK_PUCK_DEPTH_M: float = 6.0
# Lateral walk-the-line samples (strong-signed u = s·x), wall → middle.
const POINT_STRONG_LANES_U: Array[float] = [9.5, 7.5, 5.5, 3.5, 1.5]
const POINT_WEAK_LANES_U: Array[float] = [6.0, 4.5, 3.0, 1.5, 0.0]
# Forecheck line pair lanes (world-x magnitude, inside the dots).
const DP_STRONG_LANE_X_M: float = 6.7
const DP_WEAK_LANE_X_M: float = 5.0
# Pinch stand of the forecheck line pair: the top of the end-zone circles
# (dots 6.1 m off the goal line + the 4.57 m circle radius) — the standard
# forecheck-D pinch depth, and the stand the pair holds whenever the pinch read
# lets it (see _decide_line_hold).
const DP_PINCH_DEPTH_M: float = 10.7
# DVALVE: how far behind the play the valve trails, and its goal-line cap.
const DVALVE_TRAIL_M: float = 10.0
const DVALVE_GOAL_LINE_PAD_M: float = 2.0
# DBACK posts: inside the dots at our blue line, with a small puck shade.
const DBACK_X_M: float = 5.0
const DBACK_PUCK_SHADE: float = 0.2
const DBACK_SHADE_MAX_M: float = 1.5

# ── O-zone rim keep-ins (breakout plan §C.3) ─────────────────────────────────
# A board-hugging clear travelling up a point's wall would sail past the
# walk-the-line stands (they hold the line OFF the wall) and out of the zone
# untouched — the exact hole real rims exploit. The read classifies the
# flight the same way the breakout side does (loose, inside the wall band,
# fired toward our end) and is priced as the honest intercept race; losing
# the race means holding the station, not chasing a gone puck.
const RIM_WALL_BAND_M: float = 1.6       # boards-hugging corridor: ~a body off the glass
const RIM_MIN_SPEED_M_S: float = 8.0     # a FIRED clear — slower loose pucks are the
										 # chase election's ordinary business
const RIM_KEEPIN_WALL_INSET_M: float = 1.0


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

	# Keep-in pre-empt (see the RIM_* doc): a rim coming up MY wall — step to
	# the boards at the line and kill it, arriving at pace (blade to the wall
	# lane), instead of walking the line while it sails past. The weak D's
	# middle cover on the step is the existing emergent rotation; if the race
	# is lost the branch never fires and the stand below holds.
	var keepin: Vector3 = _wall_rim_keepin(ctx, side)
	if keepin.is_finite():
		d.target_position = keepin
		d.arrive_at_speed = true
		return d

	var opp_positions: Array[Vector3] = ctx.scratch_opp_positions
	var opp_states: Array[SkaterNetworkState] = ctx.scratch_opp_states
	AIRoleHelpers.collect_opponents(ctx, opp_positions, opp_states)
	var teammates: Array[Vector3] = ctx.scratch_teammates
	AIRoleHelpers.collect_teammates_excluding_self(ctx, teammates)
	# Keep-in insurance is NOT in this argmax: the walk picks the best shot
	# lane, and offensive_station_target below decides whether that stand is
	# holdable at all (puckless high coverage doesn't chase the point off the
	# line; a man genuinely behind it, with nobody covering, does).
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
		for row: int in (POINT_SINK_ROWS + 1 if allow_sink else 1):
			var z: float = line_z - own_dir * (POINT_SINK_M * float(row))
			var c := Vector3(side * u, 0.0, z)
			if not AIRoleHelpers.is_legal_position(c):
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
		best_pos = base_stand
	# The pinch read (plan §13): hold the line while we have real control and
	# either support behind or nobody behind us; otherwise back off only as far
	# as restores the numbers. Either way, stay inside feedable range of the
	# puck — a point 30 m from the play is not a point.
	d.target_position = AIRoleHelpers.offensive_station_target(
			ctx, best_pos, ctx.prev_held_forward_stand)
	d.held_forward_stand = d.target_position.distance_to(best_pos) < 0.5
	return d


# The keep-in intercept stand for a rim coming up this point's wall, or
# Vector3.INF when there is none / the race is lost. The classification is
# the shared rim-flight read (loose puck, inside the wall band on MY side,
# fired at rim pace toward our end); the stand is my wall at the blue line,
# just inside the zone; the gate is the intercept race — the puck's time to
# the line (undecayed pace: underestimating its time only makes the read
# bail earlier, the conservative direction) against my calibrated arrival.
static func _wall_rim_keepin(ctx: RoleContext, side: float) -> Vector3:
	if ctx.snapshot == null or ctx.snapshot.puck_state == null:
		return Vector3.INF
	var puck: PuckNetworkState = ctx.snapshot.puck_state
	if puck.carrier_peer_id != -1:
		return Vector3.INF
	if signf(puck.position.x) != signf(side) \
			or GameRules.INNER_HALF_WIDTH - absf(puck.position.x) > RIM_WALL_BAND_M:
		return Vector3.INF
	var own_dir: float = ctx.own_goal_dir
	var speed: float = Vector2(puck.velocity.x, puck.velocity.z).length()
	# Fired, and travelling OUT of the zone (toward our end).
	if speed < RIM_MIN_SPEED_M_S or puck.velocity.z * own_dir <= 0.0:
		return Vector3.INF
	var stand := Vector3(
			side * (GameRules.INNER_HALF_WIDTH - RIM_KEEPIN_WALL_INSET_M),
			0.0, -own_dir * (GameRules.BLUE_LINE_Z + 0.5))
	# Already escaped past the line → gone; the TRANS flip owns it.
	if (puck.position.z - stand.z) * own_dir > 0.0:
		return Vector3.INF
	var t_puck: float = absf(puck.position.z - stand.z) \
			/ maxf(absf(puck.velocity.z), 0.001)
	var t_me: float = AIActionScoring.time_to_arrive(
			ctx.self_pos, stand, ctx.self_velocity,
			ctx.self_max_speed, ctx.self_max_accel, ctx.self_lateral_grip)
	if t_me > t_puck:
		return Vector3.INF
	return stand


# ── FORECHECK: pinch on the lane, or go home ────────────────────────────────
# The shared offensive-station pinch read (offensive_station_target), applied
# per lane for the D pair — the stand is not glued to the blue line. While the
# read allows the pinch the D stands at DP_PINCH_DEPTH_M on his lane (the circle
# top — real pressure instead of blue-line statuary); the moment their breakout
# is genuinely under way (Mode.RUSH with the puck theirs) he abandons it for his
# defensive home post. There is no intermediate stand on the lane: the pinch
# read is categorical, so the pair either presses or backs out.
static func _decide_line_hold(ctx: RoleContext, lane_x: float) -> RoleDecision:
	var d := RoleDecision.new()
	var own_dir: float = ctx.own_goal_dir
	var pinch_z: float = -own_dir * (GameRules.GOAL_LINE_Z - DP_PINCH_DEPTH_M)

	var pinch_stand := Vector3(lane_x, 0.0, pinch_z)
	d.target_position = AIRoleHelpers.offensive_station_target(
			ctx, pinch_stand, ctx.prev_held_forward_stand)
	d.held_forward_stand = d.target_position.distance_to(pinch_stand) < 0.5
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
	# Race-home cap: the valve's whole job is to never be beaten home. A
	# lurker already behind the trail point pulls the valve down its retreat
	# line until the counter paths are contained again.
	var valve_stand: Vector3 = target
	target = AIRoleHelpers.offensive_station_target(
			ctx, valve_stand, ctx.prev_held_forward_stand)
	d.held_forward_stand = target.distance_to(valve_stand) < 0.5
	d.target_position = target
	# The rush advances every tick — pace the waypoint, don't brake at it.
	d.arrive_at_speed = true
	return d


# ── NEUTRAL: the goal-side back pair ─────────────────────────────────────────
# The blue-line stand is race-home bounded like every other station in this
# file. Without it this was the one D station that would hold its line no
# matter what was behind it — the puckwatching last man who stands at his own
# blue line into a guaranteed breakaway. A contained counter leaves the stand
# exactly where it was, so the NZ back wall is unchanged in ordinary play; a
# stretch threat already past the pair sags them down the retreat line instead.
static func _decide_back(ctx: RoleContext, side: float) -> RoleDecision:
	var d := RoleDecision.new()
	var own_dir: float = ctx.own_goal_dir
	var x: float = side * DBACK_X_M
	if ctx.snapshot != null and ctx.snapshot.puck_state != null:
		# Shade with the puck's lateral drift — the back wall slides, it
		# doesn't chase.
		x += clampf(ctx.snapshot.puck_state.position.x * DBACK_PUCK_SHADE,
				-DBACK_SHADE_MAX_M, DBACK_SHADE_MAX_M)
	var stand := Vector3(x, 0.0, own_dir * GameRules.BLUE_LINE_Z)
	var opp_positions: Array[Vector3] = ctx.scratch_opp_positions
	var opp_states: Array[SkaterNetworkState] = ctx.scratch_opp_states
	AIRoleHelpers.collect_opponents(ctx, opp_positions, opp_states)
	AIRoleHelpers.collect_counter_threats(
			ctx, ctx.scratch_counter_states, ctx.scratch_counter_caps)
	AIRoleHelpers.fill_counter_channels(ctx, ctx.scratch_counter_states,
			ctx.scratch_counter_caps, ctx.defending_goal_pos,
			AIRoleHelpers.ThreatSet.COUNTER_ATTACKERS)
	d.target_position = AIRoleHelpers.most_forward_feasible(
			stand, AIRoleHelpers.self_race_vmax(ctx), ctx.self_max_accel,
			AIRoleHelpers.station_retreat_floor(ctx, stand))
	return d
