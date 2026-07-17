class_name AIRoleContain

# CONTAIN role behavior — TRANS_OD only. The last man back: gap control on
# the puck carrier as a rush develops toward our net.
#
# CONTAIN is assigned to the LAST MAN BACK — the peer soonest to our own net
# (momentum-aware), the deepest line of defense. Its one job
# is to stay between the carrier and our net at a CONTROLLED GAP — close enough
# to challenge, far enough not to get beaten wide — and let the rush come to it,
# rather than lunging up-ice at the carrier (the old "engage forward" behavior,
# which took bad angles and gave up breakaways). The two BACKCHECK peers sprint
# home to cover the carrier's receivers; CONTAIN owns the carrier.
#
# Geometry: target = a point on the carrier→our-net line, goal-side of the
# carrier, at a gap that TIGHTENS as the carrier nears the net:
#
#     gap = clamp(carrier_dist_to_net × GAP_FRACTION, GAP_MIN_M, GAP_MAX_M)
#     target = carrier + (our_net - carrier).normalized() × gap
#
# Far out (rush at the blue line) the gap is loose — CONTAIN stands off and
# skates backward, mirroring the carrier without committing. Near the net the
# gap collapses to a stick's length — CONTAIN is right on the carrier at the
# doorstep. Because the target is always goal-side of the carrier and a fixed
# distance IN FRONT of the net, CONTAIN never retreats behind its own goal line
# (the old BACKCHECK failure) and never lunges past the carrier (the old
# CONTAIN failure). Sprint-home to re-establish the gap is emergent from the
# state machine's _resolve_sprint on this target.
#
# ── Odd-man pass-lane read ("play the pass") ─────────────────────────────────
# The gap machinery above fixes the DEPTH; the DIRECTION is no longer pinned
# to the carrier→net line. At the chosen gap distance from the carrier,
# CONTAIN argmaxes a small fan of directions between the retreat line and
# each receiver's feed lane, scored with the shared rush scorer
# (AIRoleHelpers.carrier_live_option — the carrier's best of direct-shot vs
# one-timer-feed with us hypothetically at the candidate). The 2-on-1
# doctrine emerges from the evaluators rather than being scripted:
#   • The goalie is IN both terms: squared to the known shooter he prices
#     the carrier's direct shot low, while the cross-crease one-timer must
#     catch him traversing (predict_goalie_pos + goalie_unsettled over the
#     feed's flight) and prices high — "the goalie takes the shooter,
#     I take the pass" falls out of the max().
#   • Teammates ride into both surfaces, so a marker already home on a
#     receiver suppresses that lane CONTINUOUSLY — no boolean "is this an
#     odd-man rush" count. A nominal 2-on-2 with a hopelessly trailing
#     marker reads exactly like the 2-on-1 it really is.
#   • The late commit is emergent too: as the carrier walks in, his shot
#     threat overtakes the residual pass threat and the argmax steps back
#     out to the carrier line.
# The on-line point keeps a hold margin (LINE_HOLD_MARGIN) so CONTAIN leaves
# the classic retreat line only when the lane genuinely pays, and each lane
# candidate passes a race-home check that EXCLUDES the receiver whose lane it
# contests — standing in his feed lane owns him; the race is only against the
# remaining opponents (racing the man you're guarding home is the exact
# mistake the doctrine exists to avoid). Gated by the plays_rush_pass_lanes
# cognition tier knob (Easy retreats purely on the carrier line, so the
# newcomer cross-crease feed connects).
#
# Falls back to the loose-puck spot when no skater carries the puck (so it keeps
# containing the developing play), and to self_pos only when there's no puck.

# Gap as a fraction of the carrier's distance to our net, then clamped. The
# fraction gives the "tighten as they close" ramp; the clamps bound it to a
# real challenge distance at both extremes.
const GAP_FRACTION: float = 0.3
const GAP_MIN_M: float = 1.6
const GAP_MAX_M: float = 6.0

# Where CONTAIN plants for the line stand: this far inside OUR blue line, so
# the carrier meets a set defender exactly at the entry moment. One stride of
# depth — enough to pivot with a wide cut, not so much that the line is
# conceded before contact.
const LINE_STAND_INSIDE_M: float = 1.0

# Directions sampled between the carrier→net retreat line (fraction 0, always
# scored as the baseline) and each receiver's feed lane (fraction 1 = standing
# ON the lane at the gap distance). Sampling parameter — adjacent fractions
# are close enough that a near-tie flip moves the target a small step, not a
# jump across the fan.
const RUSH_LANE_FAN_FRACTIONS: Array[float] = [0.25, 0.5, 0.75, 1.0]

# The carrier→net retreat point must be beaten by at least this much
# (threat-surface units, same 0..1 currency as score_shoot / score_pass)
# before CONTAIN leaves the classic line — a stateless bias toward the
# textbook gap that also damps flicker between the line and a marginal lane.
# Same magnitude rationale as AIRoleHelpers.TARGET_SWITCH_MARGIN.
const LINE_HOLD_MARGIN: float = 0.04

# Finish-danger floor a receiver must clear before CONTAIN will leave the
# carrier (the immediate shooter) to shade that receiver's feed lane. The lane
# fan scores each feed as a one-timer with a traversing, unsettled goalie
# (carrier_live_option), which prices EVERY cross-ice feed high — so without a
# gate an ordinary trailing winger reads as a lethal one-timer and CONTAIN
# abandons the shooter for a harmless pass lane. The bar is the receiver's
# finish-if-fed with the keeper PREDICTED OVER THE FEED'S FLIGHT
# (predict_goalie_pos + goalie_unsettled, no field defenders): a short-flight
# backdoor feed arrives before he can traverse (near-certain finish), while a
# long trailing feed hands him the whole flight to re-square (a dead look).
# Under the make-probability currency this reads directly as P(goal | clean
# feed): the canonical 2-on-1 backdoor partner measures ~1.0 (PLAY it), the
# distant trailer ~0.0 (HOLD the carrier); the bar is "more likely than not".
#
# KNOWN GAP: a wide-but-DEEP receiver (sharp angle, several metres off the
# goal line) also reads ~1.0, because the planning keeper has no sharp-angle
# post-play outside the 2 m seal zone (the live goalie's VH/pads-first slide
# would wall that shot). Until the planning model grows that read, CONTAIN
# will respect wide-deep feed lanes more than the textbook says to — see the
# pending() doctrine test in test_role_contain.
const LANE_PLAY_DANGER_BAR: float = 0.5


static func decide(ctx: RoleContext) -> RoleDecision:
	var d := RoleDecision.new()

	var carrier_pos: Vector3 = AIRoleHelpers.resolve_defensive_play_ref(ctx)
	if not carrier_pos.is_finite():
		d.target_position = ctx.self_pos
		return d

	# Lead the carrier the same clamped half-step the backline leads its
	# men (lead_threat) — the gap point is defined off where the rush is
	# GOING, not the freeze-frame. Without this, a carrier cutting
	# laterally had CONTAIN back-pedalling along a stale carrier→net line
	# and re-correcting every tick. Velocity-based, so it shrinks to
	# nothing the moment the carrier slows — no phantom to overshoot.
	carrier_pos = AIRoleHelpers.lead_threat(
			carrier_pos, AIRoleHelpers.resolve_play_ref_velocity(ctx),
			ctx.defensive_anticipation_scale)

	var our_net: Vector3 = ctx.defending_goal_pos
	var to_net: Vector3 = our_net - carrier_pos
	var dist: float = to_net.length()
	if dist < 0.001:
		# Carrier sitting on our goal line — just hold the doorstep.
		d.target_position = carrier_pos
		return d

	var gap: float = clampf(dist * GAP_FRACTION, GAP_MIN_M, GAP_MAX_M)
	# STAND UP AT THE BLUE LINE — but only with a safety layer home behind us.
	# The raw distance-fraction gap concedes the entry by construction: at the
	# moment the carrier reaches our blue line the gap is ~maxed, so CONTAIN is
	# six metres behind the line retreating at the carrier's pace and the zone is
	# gained untouched every rush. The line is where the defence makes its stand —
	# entry-with-possession is the thing to deny — so while the carrier is still
	# OUTSIDE our zone, the gap is capped by the ice remaining to the line (+ the
	# plant depth): the gap-surf lands CONTAIN set one stride inside the line
	# exactly as the carrier arrives. Once the zone is gained the cap vanishes and
	# the normal protect-the-net ramp resumes.
	#
	# The stand is only safe when there IS a safety layer home behind us: its own
	# rationale is "losing the stand wide is acceptable because a teammate is home."
	# When CONTAIN is genuinely the LAST man back (nobody deeper), stepping up to
	# the line trades a denied entry for a possible breakaway — a bad trade. So
	# gate the stand on defensive support behind; as the true last man, skip it and
	# hold the deeper contain gap instead (contain, don't challenge). The MARK pair
	# recovering from up-ice flips this on the instant one gets home behind the
	# stand, so the aggressive line stand returns exactly when it's backed.
	var ice_to_line: float = GameRules.BLUE_LINE_Z - ctx.own_goal_dir * carrier_pos.z
	if ice_to_line > 0.0 and _has_support_behind(ctx):
		gap = maxf(minf(gap, ice_to_line + LINE_STAND_INSIDE_M), GAP_MIN_M)
	# Never project past the net — a gap wider than the carrier's own distance
	# to the net would place the target behind the goal line.
	gap = minf(gap, dist)
	# NEVER ADVANCE PAST RECOVERY. The gap point is carrier-relative, so a
	# carrier still deep in his own end pulls it far up-ice — and a center-ice
	# CONTAIN would skate FORWARD 15 m to "establish the gap" on a rush that
	# hasn't come yet, vacating the middle while a trailer makes it a 2-on-1
	# behind him (the forecheck-F3 bug's TRANS_OD twin). Gap control means the
	# rush comes to YOU: the stand must contain the TRAILERS' counter paths
	# (fill_counter_channels — feed flight + carry, raced to the first path
	# station CONTAIN can reach set) — the CARRIER is excluded because gap
	# control already owns him (you cannot be beaten home by the man you
	# retreat in front of; the trailer is who burns you). Each trailer races
	# at ITS real Speed cap — states and caps are filled together so the
	# parallel arrays stay index-aligned (a hand-filled state list over a stale
	# caps buffer used to size-mismatch and silently demote every trailer to
	# league-reference speed, so a plodding trailer forced a deep sag and a
	# burner was under-feared).
	var opp_states: Array[SkaterNetworkState] = ctx.scratch_opp_states
	var opp_caps: Array[AISkaterCaps] = ctx.scratch_opp_caps
	var receivers: Array[Vector3] = ctx.scratch_opp_receivers
	opp_states.clear()
	opp_caps.clear()
	receivers.clear()
	var carrier_pid: int = ctx.snapshot.puck_state.carrier_peer_id 			if ctx.snapshot.puck_state != null else -1
	for pid: int in ctx.snapshot.skater_states:
		if ctx.team_id_by_peer.get(pid, -1) == ctx.team_id or pid == carrier_pid:
			continue
		var s: SkaterNetworkState = ctx.snapshot.skater_states[pid]
		opp_states.append(s)
		opp_caps.append(ctx.caps_by_peer.get(pid))
		# The same bodies are the carrier's receivers for the lane fan below —
		# velocity-led so the fan guards where each feed is going.
		receivers.append(AIRoleHelpers.lead_threat(
				s.position, s.velocity, ctx.defensive_anticipation_scale))
	AIRoleHelpers.fill_counter_channels(ctx, opp_states, our_net)
	var dir_net: Vector3 = to_net / dist
	var stand: Vector3 = AIRoleHelpers.most_forward_feasible(
			carrier_pos + dir_net * gap, ctx.self_max_speed, ctx.self_max_accel)
	# The stand stays on the carrier→net line (net, stand, and the gap point
	# are collinear), so the lane fan's gap distance updates with it.
	gap = carrier_pos.distance_to(stand)
	d.target_position = stand

	# Odd-man pass-lane fan (see the header doc): rotate the stand off the
	# retreat line toward an uncovered receiver's feed lane when that deflates
	# the carrier's best option more. Needs a live OPPONENT carrier — a loose
	# puck has no feed source, and the cognition gate keeps lower tiers on the
	# classic line.
	if ctx.plays_rush_pass_lanes and not receivers.is_empty() \
			and carrier_pid != -1 \
			and ctx.team_id_by_peer.get(carrier_pid, -1) != ctx.team_id:
		d.target_position = _lane_fan_target(
				ctx, carrier_pos, our_net, dir_net, gap,
				receivers, opp_states, opp_caps)
	return d


# True when a teammate is home BEHIND CONTAIN — deeper toward our net (larger
# own_goal_dir * z) than we are — i.e. there's a safety layer that can pick up
# the carrier if our blue-line stand gets beaten wide. When false, CONTAIN is
# the genuine last man back and must contain rather than challenge the entry.
# Depth-axis read (not a race): the stand's risk is specifically "beaten wide,
# nobody home," which is a positional question. Excludes self.
static func _has_support_behind(ctx: RoleContext) -> bool:
	if ctx.snapshot == null:
		return false
	var my_depth: float = ctx.own_goal_dir * ctx.self_pos.z
	for pid: int in ctx.snapshot.skater_states:
		if pid == ctx.peer_id:
			continue
		if ctx.team_id_by_peer.get(pid, -1) != ctx.team_id:
			continue
		if ctx.own_goal_dir * ctx.snapshot.skater_states[pid].position.z > my_depth:
			return true
	return false


# Argmax over the retreat-line point plus fan candidates toward each
# receiver's feed lane, all at `gap` distance from the (led) carrier so the
# gap machinery's depth discipline is preserved. Scored with the shared
# carrier-best-option surface; the on-line point starts with LINE_HOLD_MARGIN
# in hand. Candidates outside ±90° of the retreat line (goal-side), outside
# the rink/creases, or beyond the per-lane race-home radius are dropped.
static func _lane_fan_target(
		ctx: RoleContext,
		carrier_pos: Vector3,
		our_net: Vector3,
		dir_net: Vector3,
		gap: float,
		receivers: Array[Vector3],
		opp_states: Array[SkaterNetworkState],
		opp_caps: Array[AISkaterCaps]) -> Vector3:
	var teammates: Array[Vector3] = ctx.scratch_teammates
	AIRoleHelpers.collect_teammates_excluding_self(ctx, teammates)
	var our_goalie_pos: Vector3 = AIRoleHelpers.resolve_our_goalie_pos(ctx)

	var on_line: Vector3 = carrier_pos + dir_net * gap
	var best_pos: Vector3 = on_line
	var best_score: float = LINE_HOLD_MARGIN - AIRoleHelpers.carrier_live_option(
			on_line, carrier_pos, our_net, our_goalie_pos, teammates, receivers)

	# Momentum-aware time home per opponent (aligned with opp_states/opp_caps),
	# for the per-lane race exclusions below.
	var t_home: PackedFloat64Array = PackedFloat64Array()
	t_home.resize(opp_states.size())
	for i: int in opp_states.size():
		var caps: AISkaterCaps = opp_caps[i]
		var speed: float = caps.max_speed if caps != null \
				else AIActionScoring.SKATER_REF_SPEED_M_S
		t_home[i] = AIActionScoring.time_to_arrive(
				opp_states[i].position, our_net, opp_states[i].velocity, speed)
	var brake_margin_s: float = GameRules.DEFAULT_SKATER_MAX_SPEED_M_S \
			/ AISteering.ARRIVAL_BRAKE_DECEL_M_S2

	# Empty defender list for the receiver's finish-if-fed read (goalie only,
	# no field defenders). One typed array reused across the receiver loop.
	var no_defenders: Array[Vector3] = []
	var a_net: float = atan2(dir_net.z, dir_net.x)
	for i: int in receivers.size():
		# Only leave the carrier for a receiver who's a genuine immediate threat:
		# his finish-if-fed must clear the danger bar — the keeper predicted
		# over the FEED'S flight (see LANE_PLAY_DANGER_BAR), no field
		# defenders. A trailing, low-danger receiver doesn't pull CONTAIN off
		# the shooter, no matter how open his lane; that's the "only play the
		# pass in a real 2v1" discipline. The on-line retreat point (scored
		# above against ALL receivers) stays the baseline, so a conceded
		# low-danger feed is still priced there.
		var feed_speed: float = AIActionScoring.expected_pass_speed(
				carrier_pos, receivers[i])
		var feed_flight: float = carrier_pos.distance_to(receivers[i]) \
				/ maxf(feed_speed, 1.0)
		var recv_goalie: Vector3 = AIActionScoring.predict_goalie_pos(
				our_goalie_pos, our_net, feed_flight, receivers[i])
		var recv_unsettled: float = AIActionScoring.goalie_unsettled(
				our_goalie_pos, our_net, feed_flight, receivers[i])
		var recv_danger: float = AIActionScoring.score_shoot(
				receivers[i], our_net, recv_goalie, GameRules.NET_HALF_WIDTH,
				no_defenders, AIActionScoring.WRISTER_SHOT_SPEED_M_S,
				recv_unsettled)
		if recv_danger < LANE_PLAY_DANGER_BAR:
			continue
		var lane_x: float = receivers[i].x - carrier_pos.x
		var lane_z: float = receivers[i].z - carrier_pos.z
		if lane_x * lane_x + lane_z * lane_z < 0.25:
			continue  # receiver on top of the carrier — no lane to play
		var a_delta: float = wrapf(atan2(lane_z, lane_x) - a_net, -PI, PI)
		# Race-home radius EXCLUDING this receiver: standing in his feed lane
		# owns him, so the race is only against the remaining opponents.
		var t_others: float = INF
		for j: int in t_home.size():
			if j != i and t_home[j] < t_others:
				t_others = t_home[j]
		var r_lane: float = INF
		if t_others < INF:
			r_lane = maxf(t_others - brake_margin_s, 0.0) * maxf(ctx.self_max_speed, 1.0)
		for f: float in RUSH_LANE_FAN_FRACTIONS:
			var a_off: float = a_delta * f
			if absf(a_off) >= PI * 0.5:
				continue  # never rotate past goal-side of the carrier
			var a: float = a_net + a_off
			var c := Vector3(
					carrier_pos.x + cos(a) * gap, 0.0,
					carrier_pos.z + sin(a) * gap)
			if not AIRoleHelpers.is_legal_position(c):
				continue
			if c.distance_to(our_net) > r_lane + 0.01:
				continue
			var score: float = -AIRoleHelpers.carrier_live_option(
					c, carrier_pos, our_net, our_goalie_pos, teammates, receivers)
			if score > best_score:
				best_score = score
				best_pos = c
	return best_pos
