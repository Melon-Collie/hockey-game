class_name AIRoleTrack

# TRACK_PUCK / TRACK_MID_STRONG / TRACK_MID_WEAK — the backcheck
# (5v5 TRANS_OD). Design: docs/transition-defense-plan.md §5, §7.
#
#   TRACK_PUCK — F1 back. Tracks the CARRIER through mid-ice, all the way to the
#     net, then drops into low support. When he catches him he attacks the puck,
#     and he is allowed to finish a check (goal-side only — see below).
#   TRACK_MID_STRONG / _WEAK — F2 and F3. Come back through MID-ICE and stop
#     just inside the tops of the circles, sticks on the ice, then pick up
#     whoever enters their lane.
#
# ── Why this is a MODE, not just another position ────────────────────────────
# The old TRANS_OD had two MARK defenders running a cover-position argmax from
# wherever they happened to be — including 20 m up-ice, mid-backcheck. A marker
# in that state is computing where to stand relative to a man he is nowhere near,
# and the argmax's whole supporting apparatus (arrival brake, anti-crowd
# rejection, incumbent hysteresis) exists to make a STATIONARY POST stable. Run
# while you are behind the play, it reads exactly as it looked: lazy escorting,
# no urgency, a human skating straight past.
#
# Real backcheckers sprint until they are back, THEN pick up. So a peer the
# shared read classifies as not-yet-inside gets NO argmax at all — just a lane
# recovery point and a hard sprint (RoleDecision.sprint_override). He converts to
# coverage on the tick he crosses goal-side of the puck, and the switch is what
# produces visible urgency.

# How far off centre the two mid trackers split as they come back, so F2 and F3
# recover through mid-ice without stacking on one point. Roughly a body plus a
# stick — they are both "in the middle", just not on top of each other.
const MID_LANE_SPLIT_M: float = 2.5

# Where a mid tracker stops: just INSIDE the tops of the circles, the depth the
# research names. Expressed as a small inset off the house gate so "just inside"
# is literal rather than "on the line".
const CIRCLE_TOP_INSET_M: float = 0.5

# TRACK_PUCK's target on the carrier: his hip, not his body centre. Offset to
# the defensive side of him so the tracker arrives goal-side and takes the puck,
# rather than riding alongside and pushing him toward the net.
const HIP_GOAL_SIDE_M: float = 0.8

# A tracker may commit a check only once he is genuinely goal-side of the
# carrier by this margin. Hunting a hit from up-ice is how a backchecker takes a
# run at the play, misses, and removes himself from it entirely; catching a
# carrier from behind and finishing is the legitimate version, and the only one
# this allows. The hit itself still has to clear AIBodyCheck's ordinary
# separating-impulse bar, so nothing here makes bots hit more often — it makes
# the hits they were already allowed to want reachable from one more role.
const CHECK_GOAL_SIDE_MARGIN_M: float = 0.5


static func decide(ctx: RoleContext, slot: int) -> RoleDecision:
	if slot == AIRoleSlots.Slot.TRACK_PUCK:
		return _decide_puck(ctx)
	return _decide_mid(ctx, slot == AIRoleSlots.Slot.TRACK_MID_STRONG)


# ── TRACK_PUCK: run the carrier down ─────────────────────────────────────────

static func _decide_puck(ctx: RoleContext) -> RoleDecision:
	var d := RoleDecision.new()
	var read: AIRushRead = ctx.rush_read

	var carrier_pos: Vector3 = AIRoleHelpers.resolve_defensive_play_ref(ctx)
	if not carrier_pos.is_finite():
		d.target_position = ctx.self_pos
		return d
	var carrier_vel: Vector3 = AIRoleHelpers.resolve_play_ref_velocity(ctx)
	var lead: Vector3 = AIRoleHelpers.lead_threat(
			carrier_pos, carrier_vel, ctx.defensive_anticipation_scale)

	var our_net: Vector3 = ctx.defending_goal_pos
	var to_net: Vector3 = our_net - lead
	var dist: float = sqrt(to_net.x * to_net.x + to_net.z * to_net.z)
	var hip: Vector3 = lead
	if dist > 0.001:
		# The hip, goal-side: arrive between him and the net, not beside him.
		hip = lead + Vector3(to_net.x / dist, 0.0, to_net.z / dist) * HIP_GOAL_SIDE_M

	# Caught him: finish the check if it is a real, separating one. Gated on
	# already being goal-side — see CHECK_GOAL_SIDE_MARGIN_M.
	if _is_goal_side_of(ctx, lead, CHECK_GOAL_SIDE_MARGIN_M):
		var check: AIBodyCheck.Result = AIRoleHelpers.evaluate_body_check(ctx)
		if check.commit:
			d.commit_check = true
			d.check_target = check.target
			d.target_position = check.target
			return d

	d.target_position = hip
	# Track at full pace and don't brake at the target: the carrier is moving,
	# and a backchecker who eases up at his hip has not caught him.
	d.sprint_override = true
	d.arrive_at_speed = true
	# Stick on the puck: aim at the carrier's blade side so the poke/lift is
	# live the moment he's in reach, rather than the ready stance pointing at
	# open ice.
	if read.mode != AIRushRead.Mode.NONE:
		d.aim_world_pos = lead
		d.has_aim_override = true
	return d


# ── TRACK_MID: back through the middle, stop at the circle tops ──────────────

static func _decide_mid(ctx: RoleContext, is_strong: bool) -> RoleDecision:
	var d := RoleDecision.new()
	var read: AIRushRead = ctx.rush_read
	var our_net: Vector3 = ctx.defending_goal_pos
	var side: float = ctx.strong_x if is_strong else -ctx.strong_x

	# RECOVERING: no argmax, no post — just get back through the middle, hard.
	# This is the whole of the urgency fix (§7).
	if not _is_inside(ctx, read):
		d.target_position = _recovery_point(ctx, read, side)
		d.sprint_override = true
		d.arrive_at_speed = true
		return d

	# HOME: pick up the most dangerous man who has entered my lane, goal-side in
	# the feed lane — the same cover geometry the zone soft-lock uses. No man in
	# my ice means hold the post; never chase out of the structure.
	var man_lead: Vector3 = _man_in_my_lane(ctx, read, side)
	if man_lead.is_finite():
		var play_ref: Vector3 = AIRoleHelpers.resolve_defensive_play_ref(ctx)
		if play_ref.is_finite():
			d.target_position = AIRoleHelpers.cover_man_target(
					ctx, man_lead, play_ref)
			return d
	d.target_position = _post(ctx, read, side)
	return d


# The recovery lane point: mid-ice on my side of centre, at the depth the rush
# has reached — so the tracker comes back THROUGH the middle (the researched
# lane) rather than up his own wall behind the play, and keeps converging as the
# rush advances instead of running to a fixed spot.
static func _recovery_point(ctx: RoleContext, read: AIRushRead,
		side: float) -> Vector3:
	var post: Vector3 = _post(ctx, read, side)
	if read.mode == AIRushRead.Mode.NONE or not read.threat_axis.is_finite():
		return post
	# Aim at the deeper of (the post, the rush's current depth on my lane) so a
	# tracker still up-ice heads for the ice in FRONT of the rush, not behind it.
	var our_net: Vector3 = ctx.defending_goal_pos
	var rush_depth: float = read.rush_origin.distance_to(our_net)
	var post_depth: float = post.distance_to(our_net)
	if rush_depth <= post_depth:
		return post
	var axis: Vector3 = read.threat_axis
	return Vector3(our_net.x - axis.x * post_depth + side * MID_LANE_SPLIT_M,
			0.0, our_net.z - axis.z * post_depth)


# The mid tracker's post: just inside the tops of the circles, split off centre.
static func _post(ctx: RoleContext, read: AIRushRead, side: float) -> Vector3:
	var our_net: Vector3 = ctx.defending_goal_pos
	var depth: float = AIZoneCoverage.HOUSE_TOP_DEPTH_M - CIRCLE_TOP_INSET_M
	var axis: Vector3 = read.threat_axis
	if axis == Vector3.ZERO or not axis.is_finite():
		axis = Vector3(0.0, 0.0, -ctx.own_goal_dir)
	var p: Vector3 = our_net - axis * depth
	p.x += side * MID_LANE_SPLIT_M
	return p if AIRoleHelpers.is_legal_position(p) else our_net - axis * depth


# The most dangerous attacker (excluding the carrier) on my side of centre and
# not already owned goal-side by a teammate. Lane ownership, not man-marking:
# whoever enters my ice is mine while he is in it.
static func _man_in_my_lane(ctx: RoleContext, read: AIRushRead,
		side: float) -> Vector3:
	var best: Vector3 = Vector3.INF
	var best_depth: float = INF
	var our_net: Vector3 = ctx.defending_goal_pos
	for i: int in read.attackers.size():
		if read.attackers[i] == read.carrier_peer:
			continue
		var lead: Vector3 = read.attacker_leads[i]
		if lead.x * side < 0.0:
			continue  # other half of the ice — the neighbour's man
		var depth: float = lead.distance_to(our_net)
		if depth < best_depth:
			best_depth = depth
			best = lead
	return best


# Have I got back goal-side of the rush? Radial, matching AIRushRead's own
# recovery test, so the mode switch agrees with the read that classified me.
static func _is_inside(ctx: RoleContext, read: AIRushRead) -> bool:
	if read.mode == AIRushRead.Mode.NONE:
		return true
	return read.recovery_by_peer.get(ctx.peer_id, AIRushRead.Recovery.INSIDE) \
			== AIRushRead.Recovery.INSIDE


# Am I goal-side of `them` by at least `margin`, radially off our net?
static func _is_goal_side_of(ctx: RoleContext, them: Vector3,
		margin: float) -> bool:
	var our_net: Vector3 = ctx.defending_goal_pos
	return ctx.self_pos.distance_to(our_net) + margin < them.distance_to(our_net)
