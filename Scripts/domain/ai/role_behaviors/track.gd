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
#   TRACK_MID — the same job with only ONE mid tracker (3v3, where there is no D
#     pair to split around): he holds the CENTRE lane rather than a side of it,
#     and owns whoever enters the middle from either half.
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
#
# Measured off his REAL position, not a velocity-led one. The lead used to be
# applied here as well, which double-counted his motion: the route already
# carries his velocity as a feed-forward (RoleDecision.target_velocity), so the
# hip sat `pace x anticipation` further goal-side than the offset asked for and
# the tracker never actually closed to it. Same defect, same fix, as the gap in
# AIRoleRushD — see its header.
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
	# Side sign of this tracker's recovery lane: +1 / -1 for the 5v5 pair,
	# 0 for the lone 3v3 tracker (dead centre, and no half-ice filter on the
	# man he picks up — with one body in the middle, everyone in the middle is
	# his).
	var side: float = 0.0
	if slot == AIRoleSlots.Slot.TRACK_MID_STRONG:
		side = ctx.strong_x
	elif slot == AIRoleSlots.Slot.TRACK_MID_WEAK:
		side = -ctx.strong_x
	return _decide_mid(ctx, side)


# ── TRACK_PUCK: run the carrier down ─────────────────────────────────────────

static func _decide_puck(ctx: RoleContext) -> RoleDecision:
	var d := RoleDecision.new()
	var read: AIRushRead = ctx.rush_read

	var carrier_pos: Vector3 = AIRoleHelpers.resolve_defensive_play_ref(ctx)
	if not carrier_pos.is_finite():
		d.target_position = ctx.self_pos
		return d
	var carrier_vel: Vector3 = AIRoleHelpers.resolve_play_ref_velocity(ctx)

	var our_net: Vector3 = ctx.defending_goal_pos
	var to_net: Vector3 = our_net - carrier_pos
	var dist: float = sqrt(to_net.x * to_net.x + to_net.z * to_net.z)
	var hip: Vector3 = carrier_pos
	var inside: bool = _is_inside(ctx, read)
	if dist > 0.001:
		# The hip, goal-side: arrive between him and the net, not beside him.
		var dir_net := Vector3(to_net.x / dist, 0.0, to_net.z / dist)
		hip = carrier_pos + dir_net * _hip_gap(ctx, carrier_pos, dir_net, carrier_vel, dist)

	# Caught him: finish the check if it is a real, separating one. Gated on
	# already being goal-side — see CHECK_GOAL_SIDE_MARGIN_M.
	if _is_goal_side_of(ctx, carrier_pos, CHECK_GOAL_SIDE_MARGIN_M):
		var check: AIBodyCheck.Result = AIRoleHelpers.evaluate_body_check(ctx)
		if check.commit:
			d.commit_check = true
			d.check_target = check.target
			d.target_position = check.target
			return d

	d.target_position = hip
	# The hip rides him, so the route is flown in his frame (AISteering,
	# "moving-frame pursuit"): a backchecker's target velocity IS the carrier's,
	# and closing the last metres is a relative problem, not a trip to a spot.
	d.target_velocity = AIRoleHelpers.stand_ride_velocity(ctx)
	# Track at full pace and don't brake at the target: the carrier is moving,
	# and a backchecker who eases up at his hip has not caught him. (Riding a man,
	# the closing profile already expresses that — it spends the closing speed and
	# leaves him matched; the flag still covers the loose-puck fallback.)
	# A backchecker is behind the play by definition and the whole job is closing
	# that distance, which is what licenses the sprint override past both gap
	# gates. A tracker the shared read already calls INSIDE is not doing that job
	# — sprinting him at a carrier he is in front of is a step-up, not a recovery.
	d.sprint_override = not inside
	d.arrive_at_speed = true
	# Stick on the puck: aim at the carrier's blade side so the poke/lift is
	# live the moment he's in reach, rather than the ready stance pointing at
	# open ice.
	if read.mode != AIRushRead.Mode.NONE:
		d.aim_world_pos = carrier_pos
		d.has_aim_override = true
	return d


# How far goal-side of the carrier the tracker actually stands, and therefore
# what the hip is allowed to ask of him.
#
# THE HIP IS A CATCH-UP TARGET. Arriving 0.8 m goal-side of a carrier is the
# right errand for a man chasing him from behind — it is the spot where you take
# the puck rather than ride alongside. It is the wrong errand for a tracker who
# is ALREADY goal-side, and the election hands this slot to whoever of the
# non-RUSH_D1 bodies reaches the puck soonest, which in a shape that is home
# means somebody in front of the play: measured, a tracker 16.5 m off our own net
# was sent to a hip 30 m out, with the sprint override on, to become a second
# challenger on a carrier RUSH_D1 already owns.
#
# So the gap the hip asks for is bounded by the depth this body already owns,
# itself capped by the GAP LADDER (AIRoleRushD.ladder_gap_m — the shared answer
# for how far goal-side of a threat a defender should stand, the same one
# AIRoleChase's lost-race pre-contain uses). The three regimes fall out:
#   · behind him — the depth term is nil, the hip is the hip, nothing changes;
#   · goal-side inside the ladder — hold exactly what you have, give up no depth
#     to go and meet him;
#   · goal-side by more than the ladder — close to the ladder's gap and no
#     further, which is a defender's gap rather than a run at the puck.
static func _hip_gap(ctx: RoleContext, lead: Vector3, dir_net: Vector3,
		carrier_vel: Vector3, dist: float) -> float:
	var own_depth: float = (ctx.self_pos.x - lead.x) * dir_net.x \
			+ (ctx.self_pos.z - lead.z) * dir_net.z
	if own_depth <= HIP_GOAL_SIDE_M:
		return HIP_GOAL_SIDE_M
	var closing: float = maxf(
			carrier_vel.x * dir_net.x + carrier_vel.z * dir_net.z, 0.0)
	var ladder: float = AIRoleRushD.ladder_gap_m(
			lead, ctx.own_goal_dir, ctx.self_blade_reach, closing)
	return minf(minf(own_depth, maxf(ladder, HIP_GOAL_SIDE_M)), dist)


# ── TRACK_MID: back through the middle, stop at the circle tops ──────────────

static func _decide_mid(ctx: RoleContext, side: float) -> RoleDecision:
	var d := RoleDecision.new()
	var read: AIRushRead = ctx.rush_read

	# RECOVERING: no argmax, no man — just get back through the middle, hard.
	# This is the whole of the urgency fix (§7). The destination is the same
	# post he will hold once home: it already rides `read.threat_axis`, so it
	# rotates with the rush's bearing and the tracker converges on the lane the
	# rush is actually using rather than a fixed spot. (A branch here once tried
	# to aim further up-ice at the rush's own depth; it projected at the POST's
	# depth instead, which measured a 0.3 m difference — it never did anything.
	# Reinstating that idea means deciding whether a recovering tracker should
	# CUT INSIDE to the circles, as he does now, or run a pursuit curve at the
	# rush's shoulder. The post is the researched answer.)
	if not _is_inside(ctx, read):
		d.target_position = _post(ctx, read, side)
		d.sprint_override = true
		d.arrive_at_speed = true
		return d

	# HOME: pick up the most dangerous man who has entered my lane, goal-side in
	# the feed lane — the same cover geometry the zone soft-lock uses. No man in
	# my ice means hold the post; never chase out of the structure.
	var man_pid: int = _man_in_my_lane_peer(ctx, read, side)
	var man_lead: Vector3 = _man_in_my_lane(ctx, read, side)
	if man_lead.is_finite():
		var play_ref: Vector3 = AIRoleHelpers.resolve_defensive_play_ref(ctx)
		if play_ref.is_finite():
			d.target_position = AIRoleHelpers.cover_man_target(
					ctx, man_lead, play_ref)
			# The cover point rides the man in my lane, not the puck.
			d.target_velocity = AIRoleHelpers.man_ride_velocity(ctx, man_pid)
			return d
	d.target_position = _post(ctx, read, side)
	return d


# The mid tracker's post: just inside the tops of the circles, split off centre.
static func _post(ctx: RoleContext, read: AIRushRead, side: float) -> Vector3:
	var our_net: Vector3 = ctx.defending_goal_pos
	var depth: float = _post_depth()
	var axis: Vector3 = read.threat_axis
	if axis == Vector3.ZERO or not axis.is_finite():
		axis = Vector3(0.0, 0.0, -ctx.own_goal_dir)
	var p: Vector3 = our_net - axis * depth
	p.x += side * MID_LANE_SPLIT_M
	return p if AIRoleHelpers.is_legal_position(p) else our_net - axis * depth


# The attacker (excluding the carrier) nearest our net on my side of centre, AND
# INSIDE MY ICE. Lane ownership, not man-marking: whoever enters my ice is mine
# while he is in it, and the deepest man in it is the one who gets covered.
#
# "Enters my ice" was missing, and the role's own rule — hold the post, never
# chase out of the structure — cannot hold without it: the pick was the deepest
# attacker on my half of the RINK, however far up-ice, and the cover geometry
# then put the target goal-side of *him*. Measured, that sent a mid tracker at a
# point 37 m off our own net — past the far blue line — to cover a trailer who
# was himself 40 m out and no part of anything yet.
#
# The bound is the tracker's own post plus a cover envelope (the span within
# which one body owns another, AIRushRead.cover_envelope_m — the same quantity
# the numbers reads use for "meaningfully behind"). Inside it a man has arrived
# and is the tracker's to pick up; outside it he has not, and the answer is the
# post. It is expressed off _post_depth so the two cannot drift apart. No clamp
# on the resulting target is needed: cover_man_target sits goal-side of the man
# it covers, so bounding the man bounds the stand.
static func _pickup_depth_m() -> float:
	return _post_depth() + AIRushRead.cover_envelope_m()


# Depth of the mid tracker's post off our own goal line.
static func _post_depth() -> float:
	return AIZoneCoverage.HOUSE_TOP_DEPTH_M - CIRCLE_TOP_INSET_M


static func _man_in_my_lane(ctx: RoleContext, read: AIRushRead,
		side: float) -> Vector3:
	var i: int = _man_in_my_lane_index(ctx, read, side)
	return read.attacker_leads[i] if i != -1 else Vector3.INF


# That man's peer id — the cover point rides HIS velocity, so both reads have to
# name the same body.
static func _man_in_my_lane_peer(ctx: RoleContext, read: AIRushRead,
		side: float) -> int:
	var i: int = _man_in_my_lane_index(ctx, read, side)
	return read.attackers[i] if i != -1 else -1


static func _man_in_my_lane_index(ctx: RoleContext, read: AIRushRead,
		side: float) -> int:
	var best: int = -1
	var best_depth: float = _pickup_depth_m()
	var our_net: Vector3 = ctx.defending_goal_pos
	for i: int in read.attackers.size():
		if read.attackers[i] == read.carrier_peer:
			continue
		var lead: Vector3 = read.attacker_leads[i]
		# Half-ice filter — but only when there IS a neighbour to hand off to.
		# A lone mid tracker (side 0) owns the whole middle; filtering him to
		# half of it would leave the other half to nobody.
		if side != 0.0 and lead.x * side < 0.0:
			continue  # other half of the ice — the neighbour's man
		# Seeded at the pickup bound, so a man who has not entered my ice never
		# wins the argmin and the caller falls through to the post.
		var depth: float = lead.distance_to(our_net)
		if depth < best_depth:
			best_depth = depth
			best = i
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
