class_name AIRoleRushD

# RUSH_D1 / RUSH_D2 — the two defensemen defending a rush (5v5 TRANS_OD).
# Design: docs/transition-defense-plan.md §5–§6.
#
#   RUSH_D1 — the strong-side D. He OWNS THE CARRIER: hold a gap sized by the
#     ice remaining, angle him off the middle, and attack the moment his speed
#     advantage is gone. He keeps the carrier across the blue line (the state
#     does not flip there — see the coverage gate), so there is no handoff and
#     no target discontinuity mid-rush.
#   RUSH_D2 — the weak-side D. He holds MID-ICE and takes the mid-lane drive
#     ("the mid-lane drive is fed to D2"). On a DOWN_ONE read he is the man in
#     the passing lane; with only one D back, RUSH_D1 inherits that job.
#
# ── Gap control ──────────────────────────────────────────────────────────────
# The gap is a LADDER ON ICE REMAINING — doctrine is ~3 stick lengths at the
# offensive blue line, 2 at the red line, 1 stick at your own blue line. The
# ladder is the driver and pace is a small correction, NOT the other way around:
# sizing the gap off the carrier's pace alone holds the offensive blue line's
# gap all the way back to your own net, which is the sag.
#
# Modifiers must be able to run BOTH ways — something has to be able to say
# CLOSE THE GAP, not just widen it — and they read the team's shared numbers
# (`has_support_behind` and the rendezvous read) rather than each defender's
# private depth scan, which on a rush sees nobody home and disables the
# blue-line stand for everyone.

# The gap ladder, in stick lengths (BLADE_REACH_M — the honest physical unit,
# already attribute-scaled, so a long-stick D legitimately plays a hair wider).
const GAP_MIN_STICKS: float = 1.0
const GAP_MAX_STICKS: float = 3.0
# One rung of the ladder: the step every modifier moves the gap by.
const GAP_RUNG_STICKS: float = 1.0

# Backpressure that lets the D tighten and stand up (the repo's own doctrine,
# docs/5v5-ai-plan.md:548 — "a backchecker within ~1-2 s of the carrier lets the
# D tighten the gap and stand up; without it, default conservative").
const BACKPRESSURE_TIGHTEN_S: float = 1.5

# Pace correction ceiling: a carrier genuinely flying earns a little cushion,
# but never more than half a stick. Demoted from driver to correction.
const PACE_CORRECTION_MAX_STICKS: float = 0.5
# Closing speed at which the pace correction is fully applied — a hard NHL
# stride, so anything short of full flight buys proportionally less.
const PACE_FULL_M_S: float = 8.0

# ── Gap-up trigger ───────────────────────────────────────────────────────────
# When the carrier's speed advantage is gone, ATTACK — close to stick range on
# an angle, skating forward. This is the modern read ("defend by skating
# forward, kill the rush early") and the single concept the pace model could not
# express: it treated a slow carrier as merely less dangerous, never as an
# opportunity.
#
# Three observable triggers, any of which means he cannot beat us wide right now:
const GAP_UP_CLOSING_M_S: float = 3.0    # he isn't coming at pace
# He just received it and hasn't built speed — the classic moment to step up.
const GAP_UP_FRESH_RECEIVE_M_S: float = 4.5
# Steered inside this of the boards: no room left to take outside.
const GAP_UP_WALL_M: float = 2.0

# ── Angling ──────────────────────────────────────────────────────────────────
# The stand is NOT on the carrier→net line. It shades to the INSIDE (the middle
# of the ice) so the retreat path steers him toward the boards: take away the
# middle, give the outside. A defender sitting dead on the retreat line offers
# both lanes equally, which is how a carrier walks straight into the slot.
#
# The DEPTH of that shade scales with how far off centre the carrier already is:
# none at centre ice, full at the end-zone dot lane and beyond. A carrier in the
# middle has no inside to take away — both lanes are the same lane — so a fixed
# shade there had to pick a side arbitrarily, and it flipped a full 2×
# ANGLE_INSIDE_M the instant he crossed x = 0. That discontinuity landed exactly
# on the mid-lane drive, and with no incumbent hysteresis on this target the
# stand jumped side to side under a carrier driving straight at the net. Scaling
# it to zero at centre removes the jump rather than damping it: where the sign is
# ambiguous the magnitude is nil, so the two sides meet continuously.
const ANGLE_INSIDE_M: float = 1.5
# Lateral offset at which the shade reaches full depth — the end-zone dot lane.
# Inside the dots a carrier is still IN the middle and there is no outside to
# concede yet; at the dots the inside/outside split is real.
const ANGLE_INSIDE_FULL_X_M: float = GameRules.END_ZONE_FACEOFF_DOT_X

# ── Odd-man lane fan (moved from AIRoleContain, unchanged in substance) ──────
const RUSH_LANE_FAN_FRACTIONS: Array[float] = [0.25, 0.5, 0.75, 1.0]
const LINE_HOLD_MARGIN: float = 0.04
const LANE_PLAY_DANGER_BAR: float = 0.5

# RUSH_D2's mid-ice post: how far off the net he holds when there is no mid-lane
# man to pick up, measured along the threat axis. Just above the house gate —
# he is the layer behind RUSH_D1, not a second body on the puck.
const D2_MID_DEPTH_M: float = 12.0
# How far off centre an attacker may be and still count as the MID-LANE drive
# D2 exists to take: the end-zone dot lane, which is what bounds the middle of
# the ice. Without this the pick was argmin|x| over the whole rush, so a lone
# second attacker hugging the boards read as "the mid-lane man" and pulled D2
# off mid-ice — vacating the exact lane the layered defense keeps him in. A wide
# man is the mid trackers' pickup as he cuts in, not D2's to chase.
const D2_MID_LANE_HALF_WIDTH_M: float = GameRules.END_ZONE_FACEOFF_DOT_X
# How far weak-side of centre D2 shades while holding mid-ice.
const D2_WEAK_SHADE_M: float = 2.0


static func decide(ctx: RoleContext, slot: int) -> RoleDecision:
	if slot == AIRoleSlots.Slot.RUSH_D2:
		return _decide_d2(ctx)
	return _decide_d1(ctx)


# ── RUSH_D1: own the carrier ─────────────────────────────────────────────────

static func _decide_d1(ctx: RoleContext) -> RoleDecision:
	var d := RoleDecision.new()
	var read: AIRushRead = ctx.rush_read

	var carrier_pos: Vector3 = AIRoleHelpers.resolve_defensive_play_ref(ctx)
	if not carrier_pos.is_finite():
		d.target_position = ctx.self_pos
		return d
	var carrier_vel: Vector3 = AIRoleHelpers.resolve_play_ref_velocity(ctx)
	carrier_pos = AIRoleHelpers.lead_threat(
			carrier_pos, carrier_vel, ctx.defensive_anticipation_scale)

	var our_net: Vector3 = ctx.defending_goal_pos
	var to_net: Vector3 = our_net - carrier_pos
	var dist: float = sqrt(to_net.x * to_net.x + to_net.z * to_net.z)
	if dist < 0.001:
		d.target_position = carrier_pos
		return d
	var dir_net: Vector3 = Vector3(to_net.x / dist, 0.0, to_net.z / dist)

	# The rush's pace along its own attack line. Lateral drift buys no burst
	# toward our net — the turn radius pays for that conversion first.
	var closing: float = maxf(
			carrier_vel.x * dir_net.x + carrier_vel.z * dir_net.z, 0.0)

	var gap: float = _gap_for(ctx, read, carrier_pos, closing)
	gap = minf(gap, dist)   # never project the stand past the net

	# GAP UP: his speed advantage is gone, so stop retreating and take the ice.
	# Closing to stick range on an angle IS the attack — the steering drives us
	# through it at pace, which is what "defend by skating forward" means here.
	if _should_gap_up(ctx, read, carrier_pos, closing):
		gap = minf(_stick(ctx) * GAP_MIN_STICKS, dist)

	var stand: Vector3 = carrier_pos + dir_net * gap
	stand = _angle_inside(stand, carrier_pos, dir_net)

	# Odd-man: play the pass. The lane fan finds the feed lane from the
	# evaluators; the numbers read decides WHEN that doctrine applies, rather
	# than the fan inferring it from receiver danger alone.
	if read.numbers != AIRushRead.Numbers.EVEN_OR_UP and ctx.plays_rush_pass_lanes:
		var fan: Vector3 = _lane_fan_target(ctx, read, carrier_pos, our_net,
				dir_net, carrier_pos.distance_to(stand))
		if fan.is_finite():
			stand = fan

	d.target_position = _clamp_to_house(ctx, stand)
	# The rush advances every tick — pace the stand, don't brake at it.
	d.arrive_at_speed = true
	return d


# The BASE ladder, in stick lengths: ice remaining to OUR blue line gives 3
# sticks at their blue line, 2 at the red line, 1 at ours. Zero ice left (he is
# in the zone) means you are on him.
static func _ladder_sticks(threat_pos: Vector3, own_goal_dir: float) -> float:
	var ice_to_line: float = maxf(
			GameRules.BLUE_LINE_Z - own_goal_dir * threat_pos.z, 0.0)
	return clampf(GAP_MIN_STICKS + ice_to_line / (GameRules.BLUE_LINE_Z * 2.0),
			GAP_MIN_STICKS, GAP_MAX_STICKS)


# The pace correction, in stick lengths — capped, so it can never be the driver.
static func _pace_sticks(closing: float) -> float:
	return PACE_CORRECTION_MAX_STICKS * clampf(closing / PACE_FULL_M_S, 0.0, 1.0)


# The ladder gap in metres WITHOUT the shared read's numbers/backpressure rungs.
# Public so AIRoleChase's lost-race pre-contain can stand where RUSH_D1 is going
# to want it: the chaser who declines a lost race retreats into the gap stand,
# and if the two read different formulas he plants somewhere the gap defender
# then has to correct off the moment possession flips. (The old
# AIRoleContain.gap_for_pace served exactly this shared purpose; the ladder
# replaces it.) The rungs are deliberately excluded — a NEUTRAL chaser has no
# rush posture to read yet.
static func ladder_gap_m(threat_pos: Vector3, own_goal_dir: float,
		stick: float, closing: float) -> float:
	return (_ladder_sticks(threat_pos, own_goal_dir) + _pace_sticks(closing)) \
			* maxf(stick, 0.5)


# The gap ladder plus its modifiers, in metres.
static func _gap_for(ctx: RoleContext, read: AIRushRead, carrier_pos: Vector3,
		closing: float) -> float:
	var sticks: float = _ladder_sticks(carrier_pos, ctx.own_goal_dir)

	# Numbers. EVEN_OR_UP is licence to challenge; DOWN_TWO_PLUS buys time for
	# the backcheck. DOWN_ONE deliberately does NOT widen — an odd-man
	# concession is LATERAL (into the pass lane, below), never deeper. Conceding
	# depth on a 2-on-1 is how it turns into a breakaway.
	if read.numbers == AIRushRead.Numbers.EVEN_OR_UP:
		sticks -= GAP_RUNG_STICKS
	elif read.numbers == AIRushRead.Numbers.DOWN_TWO_PLUS:
		sticks += GAP_RUNG_STICKS

	# Live backpressure lets us stand up (see BACKPRESSURE_TIGHTEN_S).
	if read.backpressure_s < BACKPRESSURE_TIGHTEN_S:
		sticks -= GAP_RUNG_STICKS

	sticks = clampf(sticks, GAP_MIN_STICKS, GAP_MAX_STICKS)
	return (sticks + _pace_sticks(closing)) * _stick(ctx)


# Is his speed advantage gone? Any of the three observable triggers.
static func _should_gap_up(ctx: RoleContext, read: AIRushRead,
		carrier_pos: Vector3, closing: float) -> bool:
	# Never step up into a rush we're outnumbered against — that is the one case
	# where being beaten is a goal rather than a scoring chance.
	if read.numbers == AIRushRead.Numbers.DOWN_TWO_PLUS:
		return false
	if closing < GAP_UP_CLOSING_M_S:
		return true
	# Steered to the wall: no outside left to give him.
	if GameRules.INNER_HALF_WIDTH - absf(carrier_pos.x) < GAP_UP_WALL_M:
		return true
	# Fresh reception — he has the puck but not his legs yet. Requires REAL
	# acceleration data: a missing entry defaults to zero, which would read as
	# "he isn't accelerating" and fire the trigger on no evidence at all. An
	# unknown carrier is treated as up to speed, which is the safe direction.
	if read.carrier_peer != -1 and closing < GAP_UP_FRESH_RECEIVE_M_S \
			and ctx.acceleration_by_peer.has(read.carrier_peer):
		var acc: Vector3 = ctx.acceleration_by_peer[read.carrier_peer]
		if acc.length_squared() < 1.0:
			return true
	return false


# Shade the stand to the INSIDE of the carrier — toward the middle of the ice —
# so the lane we leave open is the outside one. Perpendicular to the retreat
# line, signed toward centre.
static func _angle_inside(stand: Vector3, carrier_pos: Vector3,
		dir_net: Vector3) -> Vector3:
	# Depth first: nil at centre, full at the dot lane (see ANGLE_INSIDE_M).
	var depth: float = ANGLE_INSIDE_M * minf(
			absf(carrier_pos.x) / ANGLE_INSIDE_FULL_X_M, 1.0)
	if depth < 0.001:
		return stand   # dead centre — no inside to take, and no side to pick
	# Perpendicular to the retreat line, in XZ.
	var perp := Vector3(-dir_net.z, 0.0, dir_net.x)
	# Point it toward the middle of the ice (x = 0) relative to the carrier.
	if perp.x * -signf(carrier_pos.x) < 0.0:
		perp = -perp
	var shaded: Vector3 = stand + perp * depth
	return shaded if AIRoleHelpers.is_legal_position(shaded) else stand


# ── RUSH_D2: hold mid-ice, take the mid-lane drive ───────────────────────────

static func _decide_d2(ctx: RoleContext) -> RoleDecision:
	var d := RoleDecision.new()
	var read: AIRushRead = ctx.rush_read
	var our_net: Vector3 = ctx.defending_goal_pos

	# The mid-lane drive man: the attacker closest to the middle of the ice who
	# isn't the carrier. He is the one D2 exists to take.
	var man_lead: Vector3 = _mid_lane_man(read)
	if man_lead.is_finite():
		var play_ref: Vector3 = AIRoleHelpers.resolve_defensive_play_ref(ctx)
		if play_ref.is_finite():
			d.target_position = _clamp_to_house(
					ctx, AIRoleHelpers.cover_man_target(ctx, man_lead, play_ref))
			d.arrive_at_speed = true
			return d

	# Nobody driving the middle: hold the mid-ice post behind RUSH_D1, shaded
	# weak side. Depth is paced off the rush so he stays a layer, not a chaser.
	var axis: Vector3 = read.threat_axis
	if axis == Vector3.ZERO:
		axis = Vector3(0.0, 0.0, -ctx.own_goal_dir)
	var post: Vector3 = our_net - axis * D2_MID_DEPTH_M
	post.x -= ctx.strong_x * D2_WEAK_SHADE_M
	d.target_position = _clamp_to_house(ctx, post)
	return d


# The attacker (excluding the carrier) driving the MIDDLE — the most central one
# inside the mid-lane band, as his velocity-led point. Vector3.INF when nobody is
# in the middle, which is D2's cue to hold his post rather than chase a wide man
# (see D2_MID_LANE_HALF_WIDTH_M).
static func _mid_lane_man(read: AIRushRead) -> Vector3:
	var best: Vector3 = Vector3.INF
	var best_x: float = D2_MID_LANE_HALF_WIDTH_M
	for i: int in read.attackers.size():
		if read.attackers[i] == read.carrier_peer:
			continue
		var lead: Vector3 = read.attacker_leads[i]
		if absf(lead.x) < best_x:
			best_x = absf(lead.x)
			best = lead
	return best


# ── Shared ───────────────────────────────────────────────────────────────────

# This bot's stick length — the ladder's unit.
static func _stick(ctx: RoleContext) -> float:
	return maxf(ctx.self_blade_reach, 0.5)


# No rush role ever stands deeper than the house gate (top of the circles). Past
# it a field skater duplicates the goalie, fights his own crease repel, and gets
# beaten to the outside of a net he's standing on top of. The doorstep belongs
# to in-zone coverage, which is a different state.
static func _clamp_to_house(ctx: RoleContext, pos: Vector3) -> Vector3:
	var our_net: Vector3 = ctx.defending_goal_pos
	var dx: float = pos.x - our_net.x
	var dz: float = pos.z - our_net.z
	var dsq: float = dx * dx + dz * dz
	var gate: float = AIZoneCoverage.HOUSE_TOP_DEPTH_M
	if dsq >= gate * gate:
		return pos
	var dl: float = sqrt(dsq)
	if dl < 0.001:
		return Vector3(our_net.x, 0.0, our_net.z - signf(our_net.z) * gate)
	return Vector3(our_net.x + dx * (gate / dl), 0.0, our_net.z + dz * (gate / dl))


# Argmax over the retreat-line point plus fan candidates toward each receiver's
# feed lane, all at `gap` distance from the (led) carrier. Moved from
# AIRoleContain with its substance intact — it derives 2-on-1 doctrine from the
# evaluators (the goalie is in both terms, so "the goalie takes the shooter, I
# take the pass" falls out of the max) rather than scripting it, and the
# research agrees with the result. What changed is the TRIGGER: the numbers read
# now decides when the doctrine applies, instead of the fan inferring an
# odd-man rush from receiver danger alone.
#
# KNOWN GAP (carried over): a wide-but-DEEP receiver reads as near-certain
# because the planning keeper has no sharp-angle post play outside the 2 m seal
# zone, so RUSH_D1 respects wide-deep feed lanes more than the textbook says to.
static func _lane_fan_target(ctx: RoleContext, read: AIRushRead,
		carrier_pos: Vector3, our_net: Vector3, dir_net: Vector3,
		gap: float) -> Vector3:
	var receivers: Array[Vector3] = ctx.scratch_opp_receivers
	receivers.clear()
	for i: int in read.attackers.size():
		if read.attackers[i] == read.carrier_peer:
			continue
		receivers.append(read.attacker_leads[i])
	if receivers.is_empty():
		return Vector3.INF

	var teammates: Array[Vector3] = ctx.scratch_teammates
	AIRoleHelpers.collect_teammates_excluding_self(ctx, teammates)
	var our_goalie_pos: Vector3 = AIRoleHelpers.resolve_our_goalie_pos(ctx)

	var self_caps: AISkaterCaps = ctx.caps_by_peer.get(ctx.peer_id)
	var on_line: Vector3 = carrier_pos + dir_net * gap
	var best_pos: Vector3 = on_line
	var best_score: float = LINE_HOLD_MARGIN - AIRoleHelpers.carrier_live_option(
			on_line, carrier_pos, our_net, our_goalie_pos, teammates, receivers,
			INF, ctx.scratch_teammate_caps, self_caps)

	var no_defenders: Array[Vector3] = []
	var a_net: float = atan2(dir_net.z, dir_net.x)
	for i: int in receivers.size():
		# Only leave the shooter for a receiver who is a genuine immediate
		# threat: his finish-if-fed must clear the bar with the keeper predicted
		# over the FEED'S flight. A trailing, low-danger receiver never pulls us
		# off the carrier however open his lane.
		var feed_speed: float = AIActionScoring.expected_pass_speed(
				carrier_pos, receivers[i])
		var feed_flight: float = carrier_pos.distance_to(receivers[i]) \
				/ maxf(feed_speed, 1.0)
		AIActionScoring.resolve_feed_keeper(
				our_goalie_pos, our_net, feed_flight, receivers[i], carrier_pos,
				AIRoleHelpers.our_goalie_hands(ctx), feed_speed)
		var recv_seal: float = AIActionScoring.derive_post_seal_x_sign(
				receivers[i], our_net)
		var recv_danger: float = AIActionScoring.score_shoot(
				receivers[i], our_net, AIActionScoring.feed_keeper_pos,
				GameRules.NET_HALF_WIDTH,
				no_defenders, AIActionScoring.WRISTER_SHOT_SPEED_M_S,
				AIActionScoring.feed_keeper_unsettled, [], -1.0, false,
				recv_seal, recv_seal != 0.0, 0.0, [],
				AIActionScoring.feed_keeper_hands)
		if recv_danger < LANE_PLAY_DANGER_BAR:
			continue
		var lane_x: float = receivers[i].x - carrier_pos.x
		var lane_z: float = receivers[i].z - carrier_pos.z
		if lane_x * lane_x + lane_z * lane_z < 0.25:
			continue  # receiver on top of the carrier — no lane to play
		var a_delta: float = wrapf(atan2(lane_z, lane_x) - a_net, -PI, PI)
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
			var score: float = -AIRoleHelpers.carrier_live_option(
					c, carrier_pos, our_net, our_goalie_pos, teammates, receivers,
					-best_score, ctx.scratch_teammate_caps, self_caps)
			if score > best_score:
				best_score = score
				best_pos = c
	return best_pos
