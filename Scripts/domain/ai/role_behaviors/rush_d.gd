class_name AIRoleRushD

# RUSH_D1 / RUSH_D2 — the two defensemen defending a rush (5v5 TRANS_DEFENSE).
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
# The gap is a LADDER ON ICE REMAINING, and pace is a small correction on top of
# it — never the other way around: sizing the gap off the carrier's pace alone
# holds the offensive blue line's gap all the way back to your own net, which is
# the sag.
#
# Modifiers must be able to run BOTH ways — something has to be able to say
# CLOSE THE GAP, not just widen it — and they read the team's shared numbers
# rather than each defender's private depth scan, which on a rush sees nobody
# home and disables the blue-line stand for everyone.
#
# THE GAP IS MEASURED OFF HIS REAL POSITION, never a velocity-led one. The route
# carries his velocity as a feed-forward, so a lead on top of it double-counts
# his motion: at a 7.7 m/s rush that is 2.67 m of doctrine plus 2.31 m of lead,
# 86% wider than the ladder asks for. Note test_role_rush_d measures against the
# LED point on purpose to isolate the ladder — the carrier is beaten off his real
# body, so that difference is an artifact of the test, not of the doctrine.

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

# ── Odd-man lane fan ─────────────────────────────────────────────────────────
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

	var ap: AICarrierApproach = ctx.scratch_carrier_approach
	if not AIRoleHelpers.read_carrier_approach(ctx, ap):
		d.target_position = ctx.self_pos
		return d
	var carrier_pos: Vector3 = ap.carrier_pos
	var our_net: Vector3 = ctx.defending_goal_pos
	if ap.dir_net == Vector3.ZERO:
		d.target_position = carrier_pos   # on top of our net — no line to hold
		return d
	var dir_net: Vector3 = ap.dir_net
	var dist: float = ap.net_dist
	var closing: float = ap.closing

	var gap: float = _gap_for(ctx, read, carrier_pos, closing)
	gap = minf(gap, dist)   # never project the stand past the net

	# GAP UP: his speed advantage is gone, so stop retreating and take the ice.
	# Closing to stick range on an angle IS the attack. It is exempt from the
	# step-up bound below, because the bound prices exactly the risk the gap-up's
	# triggers rule out — being beaten by pace you cannot match.
	var gapping_up: bool = should_gap_up(ctx, read, carrier_pos, closing)
	# The stand rides him, so the trip ends with this body already travelling at
	# the rush's pace at the ladder's gap. That is what gap control IS, and it is
	# also what stands the approach bound down — see _settable_gap.
	var ride: Vector3 = AIRoleHelpers.stand_ride_velocity(ctx)
	if gapping_up:
		gap = minf(stick_m(ctx) * GAP_MIN_STICKS, dist)
	elif ride == Vector3.ZERO:
		gap = minf(_settable_gap(ctx, carrier_pos, dir_net, gap, closing), dist)
	# Stepping UP into the stand, or retreating with it? Measured off the carrier
	# on the same axis the gap is, so the comparison is exact and carries no dead
	# band of its own — the arrival brake it selects (below) has its own
	# engage/release hysteresis and a speed floor, so the one regime where this
	# can flicker is a near-stationary body, where the brake is inert anyway.
	var stepping_up: bool = _depth_along(ctx, carrier_pos, dir_net) > gap

	var stand: Vector3 = AIRoleHelpers.carrier_stand(ap, gap)

	# Odd-man: play the pass. The lane fan finds the feed lane from the
	# evaluators; the numbers read decides WHEN that doctrine applies, rather
	# than the fan inferring it from receiver danger alone.
	if read.numbers != AIRushRead.Numbers.EVEN_OR_UP and ctx.plays_rush_pass_lanes:
		var fan: Vector3 = _lane_fan_target(ctx, read, carrier_pos, our_net,
				dir_net, carrier_pos.distance_to(stand))
		if fan.is_finite():
			stand = fan

	d.target_position = _clamp_to_house(ctx, stand)
	d.target_velocity = ride
	# The arrival brake is an ICE-frame read, so it only reaches this role when
	# there is no man to ride (a loose puck) — a moving stand stands it down
	# outright. There a stand sweeping toward us at the play's pace is not a
	# station, so braking at it parks us short and the play arrives while we are
	# stopped: a RETREAT is paced, and a step-UP wants the brake because the
	# approach bound placed that stand precisely as its trigger. The gap-up drives
	# through either way — against a carrier with no speed to beat us with, taking
	# the ice IS the attack.
	d.arrive_at_speed = gapping_up or not stepping_up
	return d


# How far goal-side of `threat_pos` this bot currently stands, along `dir_net` —
# the same axis and origin the gap is expressed in, so the two are comparable.
static func _depth_along(ctx: RoleContext, threat_pos: Vector3,
		dir_net: Vector3) -> float:
	return (ctx.self_pos.x - threat_pos.x) * dir_net.x \
			+ (ctx.self_pos.z - threat_pos.z) * dir_net.z


# The BASE ladder, in stick lengths: ice remaining to OUR blue line gives 3
# sticks at their blue line, 2 at the red line, 1 at ours. Zero ice left (he is
# in the zone) means you are on him.
#
# The divisor is BLUE_LINE_Z — one zone-to-centre span — because that is the ice
# between consecutive rungs: their blue line is 2·BLUE_LINE_Z of remaining ice,
# the red line is 1·, ours is 0·, so `1 + ice / BLUE_LINE_Z` lands the table
# above exactly. Doubling it (the §6 prose reads "2 zones", which is the same
# distance said differently) halves the ramp to 2 / 1.5 / 1 and leaves
# GAP_MAX_STICKS unreachable from the base term, while still tightening with
# depth — which is all a monotonicity test can see.
static func _ladder_sticks(threat_pos: Vector3, own_goal_dir: float) -> float:
	var ice_to_line: float = maxf(
			GameRules.BLUE_LINE_Z - own_goal_dir * threat_pos.z, 0.0)
	return clampf(GAP_MIN_STICKS + ice_to_line / GameRules.BLUE_LINE_Z,
			GAP_MIN_STICKS, GAP_MAX_STICKS)


# The pace correction, in stick lengths — capped, so it can never be the driver.
static func _pace_sticks(closing: float) -> float:
	return PACE_CORRECTION_MAX_STICKS * clampf(closing / PACE_FULL_M_S, 0.0, 1.0)


# The ladder gap in metres WITHOUT the shared read's numbers/backpressure rungs.
# Public so the lost-race pre-contain can stand where RUSH_D1 is going to want
# it: two different formulas leave the declining chaser planted somewhere the gap
# defender has to correct off the moment possession flips. The rungs are
# deliberately excluded — a NEUTRAL chaser has no rush posture to read yet.
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
	return (sticks + _pace_sticks(closing)) * stick_m(ctx)


# Is his speed advantage gone? Any of the three observable triggers.
#
# Public because AIRolePressure asks the identical question. The two roles that
# own a carrier already share the gap LADDER; they have to share the read that
# says when the ladder stops applying, or the answer changes at the handoff —
# and for the forechecking F1 (which dispatches into PRESSURE) the ladder never
# applied in the first place. See AIRolePressure.decide.
static func should_gap_up(ctx: RoleContext, read: AIRushRead,
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


# ── Step-up discipline ───────────────────────────────────────────────────────
# The ladder says WHERE the stand is; it does not say whether this body can GET
# there and still be a defender when the rush arrives. That bites in one regime:
# a defender already DEEPER than the stand — a D at home with the rush still in
# the neutral zone — where the ladder names a stand 10–18 m up-ice, past the
# sprint engage gap, so he arrives carrying a full stride of up-ice momentum and
# any cut leaves him reversing while the rush is gone (unbounded, 4.2 m/s of
# up-ice speed at the meet, a mean 10.9 m off his own net).
#
# So an ICE-FRAME approach is bounded by the speed the rendezvous leaves room
# for: close on the rush no faster than you can still be travelling WITH it by
# the time it arrives. Skipped with a layer home behind us — a beaten challenge
# is then a scoring chance rather than a breakaway, which is what licenses D1 to
# step into the rush while D2 holds mid-ice behind him.
#
# Never apply it while the stand RIDES a man, which on a live rush is always.
# The moving-frame route already regulates its own approach, so a bound on top is
# two controllers on one axis: it charges `closing²/2a` for a PIVOT the route no
# longer performs (≈3.8 m of the ≈6 m spare against a 7.5 m/s rush) and places
# the stand within 0.3 m of wherever the defender already stands. A defender
# whose stand is always where he is has no error to close, and the pair produces
# a D backing up 7 m in front of a rush for the length of the ice.
static func _settable_gap(ctx: RoleContext, carrier_pos: Vector3,
		dir_net: Vector3, gap: float, closing: float) -> float:
	if AIRoleHelpers.has_support_behind(ctx):
		return gap
	return AIRoleHelpers.settable_stand_depth(
			ctx, carrier_pos, dir_net, gap, closing)


# ── RUSH_D2: hold mid-ice, take the mid-lane drive ───────────────────────────

static func _decide_d2(ctx: RoleContext) -> RoleDecision:
	var d := RoleDecision.new()
	var read: AIRushRead = ctx.rush_read
	var our_net: Vector3 = ctx.defending_goal_pos

	# The mid-lane drive man: the attacker closest to the middle of the ice who
	# isn't the carrier. He is the one D2 exists to take.
	if AIRoleHelpers.cover_threat(ctx, d, _mid_lane_man_peer(read),
			AIRoleHelpers.resolve_defensive_play_ref(ctx)):
		d.target_position = _clamp_to_house(ctx, d.target_position)
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
# inside the mid-lane band, as a peer id. -1 when nobody is in the middle, which
# is D2's cue to hold his post rather than chase a wide man (see
# D2_MID_LANE_HALF_WIDTH_M).
static func _mid_lane_man_peer(read: AIRushRead) -> int:
	var i: int = _mid_lane_man_index(read)
	return read.attackers[i] if i != -1 else -1


static func _mid_lane_man_index(read: AIRushRead) -> int:
	var best: int = -1
	var best_x: float = D2_MID_LANE_HALF_WIDTH_M
	for i: int in read.attackers.size():
		if read.attackers[i] == read.carrier_peer:
			continue
		var lead: Vector3 = read.attacker_leads[i]
		if absf(lead.x) < best_x:
			best_x = absf(lead.x)
			best = i
	return best


# ── Shared ───────────────────────────────────────────────────────────────────

# This bot's stick length — the ladder's unit. Public for the same reason
# should_gap_up is: PRESSURE sizes a gapped-up stand in the same unit, and two
# roles holding "one stick" must not compute two different metres.
static func stick_m(ctx: RoleContext) -> float:
	return maxf(ctx.self_blade_reach, 0.5)


# No rush role ever stands deeper than the house gate (top of the circles) — the
# doorstep belongs to in-zone coverage, which is a different state.
static func _clamp_to_house(ctx: RoleContext, pos: Vector3) -> Vector3:
	return AIRoleHelpers.hold_out_to_house_gate(ctx.defending_goal_pos, pos)


# Argmax over the retreat-line point plus fan candidates toward each receiver's
# feed lane, all at `gap` distance from the carrier. 2-on-1 doctrine is DERIVED
# rather than scripted: the goalie is in both terms, so "the goalie takes the
# shooter, I take the pass" falls out of the max. The numbers read decides when
# the doctrine applies; the fan never infers an odd-man rush from receiver
# danger alone.
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
				AIRoleHelpers.our_goalie_hands(ctx), feed_speed, teammates)
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
