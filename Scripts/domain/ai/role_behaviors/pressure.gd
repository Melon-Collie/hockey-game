class_name AIRolePressure

# PRESSURE role behavior — DZONE + TRANS_DEFENSE, and the forecheck's F1. The
# puck pressurer: get goal-side of the carrier and take away his best option.
#
# INVERSE SCORING. The value of a spot is not intrinsic — it is how much OUR
# body deflates the CARRIER's options. Each candidate c is scored by placing us
# hypothetically at c and evaluating what he could still do (shoot at our net,
# or feed any teammate) with that extra defender in the way; the candidate that
# minimizes his best option wins. Both primitives are the same score_shoot /
# score_pass HE would use, read from his perspective with our team as defenders.
#
# The argmax sits between the shared closing verb and the answer: it consumes
# carrier_stand as the ring's centre and inside_dir / inside_shade_m as a FLOOR
# on the candidates, then picks the bearing itself.
#
# The goal-side filter rejects candidates between the carrier and the opp net —
# losing inside position is the cardinal sin — so the samples cover only the
# half-disc on our-net side of him.
#
# No exposure factor: PRESSURE is by definition the bot pressuring the puck, so
# "getting caught up-ice" doesn't apply. MARK owns defensive recovery.

# Engaged/closing boundary — inside it the argmax runs the full polar ring, and
# outside it the CALCULATED closing stands (see decide). Physical scale: ~1.5
# search steps, the outer ring's own step distance.
const PRESSURE_INNER_RING_RANGE_M: float = 4.5


static func decide(ctx: RoleContext) -> RoleDecision:
	var d := RoleDecision.new()

	# No live carrier (loose puck / pass in flight) — the read falls back to the
	# puck itself, so PRESSURE keeps closing the play. Stand still only when
	# there is no puck at all.
	var ap: AICarrierApproach = ctx.scratch_carrier_approach
	if not AIRoleHelpers.read_carrier_approach(ctx, ap):
		d.target_position = ctx.self_pos
		return d
	var carrier_pos: Vector3 = ap.carrier_pos

	# Commit to a body check when it is a real, reachable, separating hit.
	# PRESSURE always has support behind it — the MARK pair in DZONE, F2/F3 on
	# the forecheck — so the commit risk is acceptable. Driving at the body
	# intercept is the whole input; the state machine forces sprint so the
	# closing collision delivers the hit.
	var check: AIBodyCheck.Result = AIRoleHelpers.evaluate_body_check(ctx)
	if check.commit:
		d.commit_check = true
		d.check_target = check.target
		d.target_position = check.target
		return d

	var our_net: Vector3 = ctx.defending_goal_pos
	var our_goalie_pos: Vector3 = AIRoleHelpers.resolve_our_goalie_pos(ctx)

	# The base list of "defenders" the carrier sees; each candidate is appended to
	# it in turn during scoring.
	var our_team_excluding_self: Array[Vector3] = ctx.scratch_teammates
	AIRoleHelpers.collect_teammates_excluding_self(ctx, our_team_excluding_self)

	# The carrier's potential receivers. Anticipated, so PRESSURE shades toward
	# where a feed is going rather than where the receiver stands.
	var opp_teammates: Array[Vector3] = ctx.scratch_opp_receivers
	AIRoleHelpers.collect_opp_team_excluding_carrier(ctx, opp_teammates, true)

	# The cut-off distance is the shared GAP LADDER, sized off the carrier's REAL
	# position — never a led one. The route already carries his velocity as a
	# feed-forward, so leading the anchor as well double-counts his motion and
	# inflates the frame-relative gap by pace × lookahead.
	var carrier_velocity: Vector3 = ap.carrier_vel
	var closing_now: float = ap.closing
	# ── AND THE LADDER HAS A DOMAIN: HE HAS TO BE COMING AT US ────────────────
	# The ladder measures ICE REMAINING before the carrier reaches our blue line,
	# which is a RETREAT quantity: it prices how much room he has to beat you with
	# speed before there is nothing behind you. Deep in the ATTACKING zone that
	# quantity is at its maximum and means nothing — this role is also the
	# forecheck's F1, and a forechecker is not managing a gap, he is closing on a
	# man pinned in his own end with four teammates between him and our net.
	# Unbounded there the ladder saturates at its 3-stick ceiling, held as a hard
	# FLOOR by the clamp below, so the forechecker cannot close even in principle
	# — his own poke jab reaches ~1.9 m, leaving a committed body check as the
	# only engagement, and the easiest tier disables that outright.
	#
	# The domain read is the shared should_gap_up ("his speed advantage is gone,
	# so stop retreating and take the ice") rather than a zone test bolted on
	# here: its closing < 3 m/s trigger is satisfied by construction by a D
	# retrieving behind his own goal line, so the two carrier-owning roles agree
	# at the TRANS_DEFENSE → DZONE handoff as they already do on the ladder.
	var gapping_up: bool = AIRoleRushD.should_gap_up(
			ctx, ctx.rush_read, carrier_pos, closing_now)
	# Difficulty pace knob: ctx.pursuit_standoff_m widens the gap so easier bots
	# sag off the carrier and concede time/space (0.0 = the doctrine gap). It
	# still applies while gapping up — conceding physicality is the pace axis's
	# job on every stand, not just the retreating ones.
	var gap: float = ctx.pursuit_standoff_m
	if gapping_up:
		gap += AIRoleRushD.GAP_MIN_STICKS * AIRoleRushD.stick_m(ctx)
	else:
		gap += AIRoleRushD.ladder_gap_m(
				carrier_pos, ctx.own_goal_dir, ctx.self_blade_reach, closing_now)
	# ── AND THE STAND IS ANGLED ───────────────────────────────────────────────
	# The same shared closing geometry RUSH_D1 uses: the gap up the carrier→our
	# -net line, shaded to the INSIDE so his retreat path is steered to the
	# boards. Without it the argmax stands wherever his options are deflated most,
	# which is a defender offering both lanes equally — the thing angling exists
	# to stop, and it hands the middle back at exactly the line it is worth most.
	var inside_dir := Vector3.ZERO
	var inside_shade: float = 0.0
	var search_center: Vector3 = carrier_pos
	if ap.dir_net != Vector3.ZERO:
		search_center = AIRoleHelpers.carrier_stand(ap, gap)
		inside_dir = AIRoleHelpers.inside_dir(carrier_pos, ap.dir_net)
		inside_shade = AIRoleHelpers.inside_shade_m(carrier_pos)
	# The lead survives for the PASS-LANE read below, which is about where a feed
	# would be thrown from rather than how close to stand.
	var lead: Vector3 = carrier_pos \
			+ carrier_velocity * SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S

	# LAST MAN: TAKE THE CUT-OFF SET, NEVER LUNGE INTO IT — an ICE-FRAME bound,
	# so it applies to a LOOSE PUCK only. There is no man to ride there, the route
	# is a plain point seek, and the trip to the stand genuinely needs bounding.
	#
	# Never restore it for a live carrier. The moving-frame route already
	# regulates its own approach (its commanded velocity is the stand's plus a
	# closing term that decays to nothing on arrival), so a placement bound on top
	# is two controllers on one axis — and this one wins in the worst place, by
	# naming a stand at wherever the body already is: the pressurer being walked
	# toward his own net would be forbidden from closing on the man walking him.
	#
	# The gap-up is exempt for the same reason RUSH_D1's is: the bound prices
	# being beaten by pace you cannot match, and the gap-up's triggers are the
	# observation that he has no such pace right now.
	var min_depth: float = -INF
	var depth_dir: Vector3 = Vector3.ZERO
	if not gapping_up and AIRoleHelpers.stand_ride_velocity(ctx) == Vector3.ZERO \
			and not AIRoleHelpers.has_support_behind(ctx):
		if ap.dir_net != Vector3.ZERO:
			var net_dir: Vector3 = ap.dir_net
			var want: float = (search_center.x - carrier_pos.x) * net_dir.x \
					+ (search_center.z - carrier_pos.z) * net_dir.z
			var settable: float = AIRoleHelpers.settable_stand_depth(
					ctx, carrier_pos, net_dir, want, closing_now)
			if settable > want:
				# Push the whole candidate ring back onto the settable line, so
				# the argmax still picks the lateral angle — it just picks it
				# from a stand this body can actually be planted at. The ring
				# spans ±SEARCH_STEP_M, so the depth is also filtered per
				# candidate below rather than only re-centred.
				search_center += net_dir * (settable - want)
				min_depth = settable
				depth_dir = net_dir

	# Upper bounds for the per-candidate early-out (see carrier_option_bases) —
	# one extra surface pass here lets every candidate below skip the pass lanes
	# that cannot matter. Also the data the CALCULATED closing stands are built
	# from.
	var bases: Array[float] = ctx.scratch_option_bases
	AIRoleHelpers.carrier_option_bases(
			carrier_pos, our_net, our_goalie_pos,
			our_team_excluding_self, opp_teammates, bases,
			ctx.scratch_teammate_caps)

	# ENGAGED (within the inner-ring range of the cut-off): the full polar ring
	# including half-step samples, so a pressurer standing at the cut-off can
	# express small live corrections. CLOSING (the common case): the ring's argmax
	# reduces to a choice between COMPUTABLE stands — "block the shot" vs "block
	# the best pass" — so score exactly those three directly: the shot-line
	# cut-off, the same stand-off dropped onto the carrier's best pass lane, and
	# their midpoint. Steering consumes the target at full stride while closing,
	# where the ring's ±3 m refinements are invisible.
	var near_cutoff: bool = ctx.self_pos.distance_squared_to(search_center) \
			< PRESSURE_INNER_RING_RANGE_M * PRESSURE_INNER_RING_RANGE_M
	var candidates: Array[Vector3] = []
	if near_cutoff:
		candidates = AIRoleHelpers.generate_candidates_around(
				ctx.self_pos, search_center, true)
	else:
		candidates.append(search_center)
		var worst_pass: int = -1
		for i: int in range(1, bases.size()):
			if worst_pass == -1 or bases[i] > bases[worst_pass]:
				worst_pass = i
		if worst_pass != -1 and bases[worst_pass] > 0.0:
			var lane: Vector3 = opp_teammates[worst_pass - 1] - lead
			var lane_len: float = sqrt(lane.x * lane.x + lane.z * lane.z)
			if lane_len > 0.001:
				var pass_stand: Vector3 = lead + lane * (
						(SkaterAgentStateMachine.BLADE_REACH_M
								+ ctx.pursuit_standoff_m) / lane_len)
				candidates.append(pass_stand)
				candidates.append((search_center + pass_stand) * 0.5)
	# Switch-hysteresis. Without it "block the shot" and "block the best pass"
	# trade places on near-equal scores every dispatch and the pressurer
	# oscillates between two spots metres apart, covering neither.
	AIRoleHelpers.append_incumbent(ctx, candidates)

	var best_pos: Vector3 = ctx.self_pos
	var best_score: float = -INF
	var found: bool = false
	# THE LADDER IS A FLOOR ON THE GAP, not just where the ring is centred. The
	# ring spans ±SEARCH_STEP_M about the centre, so it always holds samples
	# nearer the carrier than the gap, and the score — how much my body deflates
	# his options — improves monotonically as you close. Left free the argmax
	# collapses onto him every time and the stand-off is whatever the ring's inner
	# edge happens to be (0.35 m separation at the meet over the gap sweep, which
	# is a body-check, not a gap).
	var min_gap_sq: float = gap * gap
	for raw: Vector3 in candidates:
		# A CLAMP, not a filter: dropping the inside candidates empties the set
		# exactly when the ring has closed onto the man, and the argmax then falls
		# through to "stand where you are" while the carrier walks past. Pushed out
		# onto the gap ring the set stays non-empty and the argmax keeps its real
		# job — the DISTANCE is doctrine, it picks the BEARING.
		var c: Vector3 = raw
		var gx: float = raw.x - carrier_pos.x
		var gz: float = raw.z - carrier_pos.z
		var gd_sq: float = gx * gx + gz * gz
		if gd_sq < min_gap_sq:
			if gd_sq > 0.0001:
				var k: float = gap / sqrt(gd_sq)
				c = Vector3(carrier_pos.x + gx * k, 0.0, carrier_pos.z + gz * k)
			elif ap.dir_net != Vector3.ZERO:
				c = carrier_pos + ap.dir_net * gap
		# THE SHADE IS A FLOOR TOO, for the same reason the gap is: the ring spans
		# ±SEARCH_STEP_M about a centre the shade moves by at most ANGLE_INSIDE_M,
		# so re-centring alone is invisible to the argmax — it can pick the outside
		# sample and undo the angle completely. Nudged along the inside axis rather
		# than rejected, so the set can never empty.
		if inside_shade > 0.001:
			var off: float = (c.x - carrier_pos.x) * inside_dir.x \
					+ (c.z - carrier_pos.z) * inside_dir.z
			if off < inside_shade:
				c += inside_dir * (inside_shade - off)
		if not AIRoleHelpers.is_legal_position(c):
			continue
		if not _is_goal_side(c, carrier_pos, our_net):
			continue
		if min_depth > -INF and (c.x - carrier_pos.x) * depth_dir.x \
				+ (c.z - carrier_pos.z) * depth_dir.z < min_depth - 0.01:
			continue  # up-ice of the settable stand — a lunge (see above)
		if AIRoleHelpers.too_close_to_teammate(c, our_team_excluding_self):
			continue

		# Higher = better for us, i.e. lower for the carrier.
		var pressure_score: float = -AIRoleHelpers.carrier_best_option(
				c, carrier_pos, our_net, our_goalie_pos,
				our_team_excluding_self, opp_teammates, bases,
				ctx.scratch_teammate_caps, ctx.caps_by_peer.get(ctx.peer_id)) \
				+ AIRoleHelpers.incumbent_bonus(ctx, c)
		if pressure_score > best_score:
			best_score = pressure_score
			best_pos = c
			found = true

	d.target_position = best_pos
	# The arrival brake deliberately stays ON even while gapping up, which is where
	# this differs from RUSH_D1: that role's stand is a moving waypoint it must not
	# read as a station, while a carrier gapped up on is by definition one who
	# ISN'T coming at pace, so his stand is a spot and braking onto it is how you
	# settle on a man rather than skate through him. Unbraked, the D-zone shape
	# lost 0.3 distinct men covered per tick and a third of its settled coverage
	# ticks, because the pressurer orbited the man instead of standing on him.
	#
	# The ride velocity is published ONLY when a candidate survived the filters.
	# Every candidate being rejected leaves `best_pos` at our own feet, which means
	# HOLD — and a hold that rides a man is not a hold, it is "match his velocity
	# forever", which walks a pressurer out through the end boards behind his own
	# net while perfectly gapped off a carrier who is also leaving.
	if found:
		d.target_velocity = AIRoleHelpers.stand_ride_velocity(ctx)
		# And the gap we just sized is ours to hold — see engaged_peer_id.
		if ctx.snapshot != null and ctx.snapshot.puck_state != null:
			var pid: int = ctx.snapshot.puck_state.carrier_peer_id
			if pid != -1 and ctx.team_id_by_peer.get(pid, -1) != ctx.team_id:
				d.engaged_peer_id = pid
	return d


# True if `c` is between the carrier and our defending goal — the hockey
# invariant *don't lose inside position*, applied as a filter before scoring.
static func _is_goal_side(c: Vector3, carrier_pos: Vector3,
		our_net: Vector3) -> bool:
	var to_net: Vector3 = our_net - carrier_pos
	if to_net.length_squared() < 0.001:
		# Carrier sitting on our goal — degenerate, no filter applies.
		return true
	var to_c: Vector3 = c - carrier_pos
	return to_net.x * to_c.x + to_net.z * to_c.z > 0.0
