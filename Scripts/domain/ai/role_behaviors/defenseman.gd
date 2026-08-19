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
#   FORECHECK line pair (DP_STRONG / DP_WEAK) — hold the offensive blue line,
#     per lane, and abandon it for the defensive home post the moment their
#     breakout is genuinely under way — exactly like the 3v3 forecheck's F3,
#     which runs the same read.
#   TRANS_OFFENSE safety valve (DVALVE) — trail the rush centrally about a zone
#     behind the play, bounded by the shared pinch read: always the reset
#     option, never beaten home.
#   NEUTRAL back shape (DBACK_L / DBACK_R) — the staggered goal-side pair
#     inside the dots at our blue line, shading with the puck's lateral
#     drift (the NZ 1-2-2's back wall).

# Blue-line hold: how far inside the offensive zone the points stand — a full
# puck-handling radius, so a catch's give or a backswing at the point never drags
# the puck back across the line and un-onsides the whole attack. One metre is not
# enough; a routine reception's cushion clears it.
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
# Forecheck line-hold stand: this far INSIDE the offensive blue line, on the
# lane. The D pair is the 1-2-2's back wall — the layer the three forwards
# press in FRONT of — so its depth is the line, not the zone
# (docs/5v5-ai-plan.md §2: "the two D hold the offensive blue line inside the
# dots"). A pinch past it is a per-puck read this file does not yet make.
#
# Inside the line rather than on it because the job at the line is KEEPING
# PUCKS IN, and a stand on the neutral-zone side can only watch a rim leave.
# Kept under a stick, so stepping back out with a breakout is one stride —
# which is the difference between this and the O-zone POINT_INSET_M, where the
# D holds possession and pays a full handling radius for the reception cushion.
const DP_LINE_INSET_M: float = 1.0
# DVALVE: how far behind the play the valve trails, and its goal-line cap.
const DVALVE_TRAIL_M: float = 10.0
const DVALVE_GOAL_LINE_PAD_M: float = 2.0
# DBACK posts: inside the dots at our blue line, with a small puck shade.
const DBACK_X_M: float = 5.0
const DBACK_PUCK_SHADE: float = 0.2
const DBACK_SHADE_MAX_M: float = 1.5

# ── O-zone rim keep-ins (breakout plan §C.3) ─────────────────────────────────
# A board-hugging clear travelling up a point's wall sails past the walk-the-line
# stands — they hold the line OFF the wall — and out of the zone untouched, which
# is the hole real rims exploit.
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
			# Unreachable: the dispatcher routes exactly the seven slots above
			# here. Hold rather than return a target of (0, 0, 0).
			var d := RoleDecision.new()
			d.target_position = ctx.self_pos
			return d


# ── OZONE point play: hold the line, walk it for a lane ─────────────────────
static func _decide_point(ctx: RoleContext, is_strong: bool) -> RoleDecision:
	var d := RoleDecision.new()
	var own_dir: float = ctx.own_goal_dir
	var opp_net: Vector3 = ctx.attacking_goal_pos
	var line_z: float = -own_dir * (GameRules.BLUE_LINE_Z + POINT_INSET_M)
	var side: float = ctx.strong_x if is_strong else -ctx.strong_x

	# Keep-in pre-empt: a rim coming up MY wall — step to the boards at the line
	# and kill it at pace instead of walking the line while it sails past. The weak
	# D's middle cover on the step is emergent rotation; a lost race never fires
	# the branch and the stand below holds.
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
	# Keep-in insurance is NOT in this argmax: the walk picks the best shot lane,
	# and offensive_station_target below decides whether that stand is holdable.
	#
	# The strong point sinks a row down his wall when the cycle is low — puck
	# depth measured off the ATTACKED goal line, which is what opp_net names.
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
					c, opp_net, opp_positions, shot_speed,
					AIActionScoring.EMPTY_VEC3, ctx.scratch_opp_caps)
			var score: float = lane + AIRoleHelpers.incumbent_bonus(ctx, c)
			if score > best_score:
				best_score = score
				best_pos = c
	if best_score == -INF:
		best_pos = base_stand
	# The pinch read: hold the line while there is support behind us or nobody
	# behind us; otherwise back off only as far as restores the numbers, and
	# either way stay inside feedable range — a point 30 m from the play is not a
	# point.
	d.target_position = AIRoleHelpers.offensive_station_target(
			ctx, best_pos, ctx.prev_held_forward_stand)
	d.held_forward_stand = d.target_position.distance_to(best_pos) < 0.5
	return d


# The keep-in intercept stand for a rim coming up this point's wall, or
# Vector3.INF when there is none / the race is lost. Classified by the shared
# rim-flight read (loose puck, inside the wall band on MY side, fired at rim pace
# toward our end); the stand is my wall at the blue line, just inside the zone.
# The puck's time to the line uses its undecayed pace — underestimating it only
# makes the read bail earlier, which is the conservative direction.
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


# ── FORECHECK: hold the line on the lane, or go home ────────────────────────
# The shared offensive-station read applied per lane for the D pair: hold the
# blue line on the lane while the read allows it, abandon it for the defensive
# home post the moment their breakout is genuinely under way. No intermediate
# stand — the read is categorical.
#
# THE PAIR DOES NOT PINCH, and that is the doctrine rather than a limitation. In
# a 1-2-2 the D are the back layer: three forwards press, and if the puck beats
# them the pair is what stands between it and a rush the other way. A pinch is a
# per-puck read — my winger owns the wall, the puck is coming to me, a forward is
# covering behind me — and the weak-side D categorically does not make it.
# Pinching BOTH, unconditionally, turns every failed forecheck into an odd-man
# rush. The situational strong-side pinch is its own work (5v5 plan §10);
# _wall_rim_keepin below is the model for the "can I win this puck" gate it
# needs.
static func _decide_line_hold(ctx: RoleContext, lane_x: float) -> RoleDecision:
	var d := RoleDecision.new()
	var own_dir: float = ctx.own_goal_dir
	var line_z: float = -own_dir * (GameRules.BLUE_LINE_Z + DP_LINE_INSET_M)

	var line_stand := Vector3(lane_x, 0.0, line_z)
	d.target_position = AIRoleHelpers.offensive_station_target(
			ctx, line_stand, ctx.prev_held_forward_stand)
	d.held_forward_stand = d.target_position.distance_to(line_stand) < 0.5
	return d


# ── TRANS_OFFENSE: the safety valve ───────────────────────────────────────────────
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
	# Last-man cap: the valve's whole job is to never be beaten home. A lurker
	# already behind the trail point, with nobody covering, pulls the valve back
	# to its post.
	var valve_stand: Vector3 = target
	target = AIRoleHelpers.offensive_station_target(
			ctx, valve_stand, ctx.prev_held_forward_stand)
	d.held_forward_stand = target.distance_to(valve_stand) < 0.5
	d.target_position = target
	# The rush advances every tick — pace the waypoint, don't brake at it.
	d.arrive_at_speed = true
	return d


# ── NEUTRAL: the goal-side back pair ─────────────────────────────────────────
# The blue-line stand is numbers-bounded like every other station in this file.
# Unbounded it is the puckwatching last man who holds his own blue line into a
# guaranteed breakaway. Nobody behind the pair leaves the stand exactly where it
# was, so the NZ back wall is unchanged in ordinary play; a stretch threat
# already past it sags the pair down the retreat line to the layer covering him.
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
	d.target_position = AIRoleHelpers.neutral_station_target(
			ctx, stand, ctx.prev_held_forward_stand)
	d.held_forward_stand = d.target_position.distance_to(stand) < 0.5
	return d
