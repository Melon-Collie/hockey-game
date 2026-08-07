class_name AIRolePressure

# PRESSURE role behavior — DZONE + TRANS_OD. The puck pressurer:
# get goal-side of the carrier and take away their best option.
#
# Inverse scoring. PRESSURE's value isn't an intrinsic positional
# metric — it's how much OUR body deflates the CARRIER's options.
# For each candidate position c we hypothetically place ourselves
# at c, then evaluate what the carrier could do (shoot at our net
# OR pass to a teammate) with us as a defender at c. The candidate
# that minimizes the carrier's best option wins.
#
# Algorithm: argmax over a goal-side candidate set of
#
#     -max(
#         score_shoot(carrier → our_net, our_goalie, our_team_with_us_at_c),
#         max over opp_teammates of
#             score_pass(carrier → opp_teammate, our_goalie,
#                        our_team_with_us_at_c)
#     )
#
# Both scoring primitives reused symmetrically: we use the same
# score_shoot / score_pass that the CARRIER would use to evaluate
# their own options, but applied from the carrier's perspective with
# our team (including our hypothetical position) as the defenders.
#
# The goal-side filter (`(c - carrier) · (our_net - carrier) > 0`)
# rejects candidates between the carrier and the opp net — losing
# inside position is the cardinal sin. With this filter the polar
# samples cover only the half-disc on our-net side of the carrier;
# argmax picks the point on that half-disc that worst-cases the
# carrier's options.
#
# Search center is offset from the carrier rather than centred on
# them so the candidate set lives in cut-off territory instead of
# chase territory:
#   center = carrier + carrier_velocity * BOT_WRISTER_LOOKAHEAD_S
#                    + (our_net - lead).normalized() * BLADE_REACH_M
# Both offsets are real in-game quantities (the action horizon the
# carrier uses for its own scoring, and one stick-length of poke
# range), so the cut-off geometry scales with the carrier's actual
# motion and our actual reach.
#
# No exposure factor — PRESSURE is by definition the bot pressuring
# the puck; "getting caught up-ice" isn't applicable. The MARK
# defenders own defensive recovery for this team.
#
# One bound on that pressure: when NOBODY is home behind us (we are the last man
# back, the normal case once a rush gains the zone and the markers are still
# recovering), the cut-off is only taken as fast as it can be taken SET — the
# last-man approach limit (AIRoleHelpers.settable_stand_depth). RUSH_D1 bounds
# its own gap stand with the same read — the ladder sizes the gap, not the trip
# to it. A lunge into a rush at pace ends with the pressurer's momentum pointing
# the wrong way and the carrier walking around him, which is worse than the space
# the limit concedes.

# Engaged/closing boundary: within ~1.5 search steps of the cut-off the
# argmax runs the full polar ring incl. half-step samples (fine corrections
# while engaged); beyond it the candidates are the CALCULATED closing stands
# (shot cut-off / best-pass-lane cut-off / midpoint — see decide) — steering
# is consuming the target at full stride, where ring resolution is
# invisible. Physical scale: the outer ring's own step distance.
const PRESSURE_INNER_RING_RANGE_M: float = 4.5

# Switch-hysteresis on the chosen cut-off point is the shared off-puck mechanism
# (AIRoleHelpers.append_incumbent / incumbent_bonus / TARGET_SWITCH_MARGIN): the
# standing target is injected into the candidate set and given a stickiness bonus,
# so it's re-scored live and kept unless a fresh candidate deflates the carrier's
# best option by at least the margin more. Without it, "block the shot" and
# "block the best pass" trade places on near-equal scores every dispatch and the
# pressurer oscillates between two spots metres apart, covering neither.


static func decide(ctx: RoleContext) -> RoleDecision:
	var d := RoleDecision.new()

	# No live carrier (loose puck / pass in flight) — pressure the puck
	# itself instead of freezing, so PRESSURE keeps closing the play.
	# Only stand still if there's no puck at all.
	# (NEUTRAL has no carrier and uses CHASE/FLANK roles instead.)
	var carrier_pos: Vector3 = AIRoleHelpers.resolve_defensive_play_ref(ctx)
	if not carrier_pos.is_finite():
		d.target_position = ctx.self_pos
		return d

	# Commit to a body check on the carrier when it's a real, reachable,
	# separating hit (AIBodyCheck). PRESSURE always has support behind it —
	# the MARK pair in DZONE, F2/F3 on the forecheck (F1 dispatches here) — so
	# the commit risk is acceptable. (The transition gap defender, RUSH_D1, never
	# hunts hits either; only TRACK_PUCK does, once it is goal-side.) When committed, drive at the body intercept; the state machine
	# forces sprint so the closing collision delivers the hit.
	var check: AIBodyCheck.Result = AIRoleHelpers.evaluate_body_check(ctx)
	if check.commit:
		d.commit_check = true
		d.check_target = check.target
		d.target_position = check.target
		return d

	var our_net: Vector3 = ctx.defending_goal_pos
	var our_goalie_pos: Vector3 = AIRoleHelpers.resolve_our_goalie_pos(ctx)

	# Our team excluding self — the base list of "defenders" the
	# carrier sees. We'll append our candidate position to this
	# list when evaluating each candidate.
	var our_team_excluding_self: Array[Vector3] = ctx.scratch_teammates
	AIRoleHelpers.collect_teammates_excluding_self(ctx, our_team_excluding_self)

	# Opp peers other than the carrier — the carrier's potential
	# pass receivers. PRESSURE scores how much each candidate
	# deflates those pass options.
	var opp_teammates: Array[Vector3] = ctx.scratch_opp_receivers
	# Anticipate: lead the receivers so PRESSURE shades to where a feed is going.
	AIRoleHelpers.collect_opp_team_excluding_carrier(ctx, opp_teammates, true)

	# ── The cut-off distance is the GAP LADDER ─────────────────────────────────
	# Doctrine is a distance ladder on ICE REMAINING, not a constant: ~3 sticks at
	# their blue line, 2 at the red line, 1 stick at ours, and inside our own zone
	# "1 stick / contact — you are on him" (docs/transition-defense-plan.md §6,
	# docs/5v5-ai-plan.md "Rush defense / gap control"). PRESSURE never had it.
	# RUSH_D1 was given the ladder and PRESSURE kept a fixed one-stick stand-off
	# measured off the carrier's LED position, which is not the same thing at all:
	# the lead is proportional to his pace, so at a rush pace the real cushion came
	# out at 3+ sticks — which is the transition plan's §2.4 defect verbatim, "the
	# correct gap for the offensive blue line, applied at the defensive blue line",
	# arriving in the one role that never got the fix.
	#
	# Measured: the pressurer rode a constant ~6 m cushion from the tops of the
	# circles to his own GOAL LINE (depth off our net 11.6 m -> 0.4 m), contesting
	# nothing, and you could walk him into his own net just by skating at him.
	#
	# THE LEAD IS GONE, and that is the other half. It existed because the anchor
	# used to be a parked point that had to be aimed ahead of a moving man. The
	# route now carries the man's own velocity as a feed-forward (AISteering's
	# moving-frame pursuit), so leading the anchor as well double-counts his motion
	# and inflates the frame-relative gap by exactly `pace x lookahead`. Built off
	# his real position, the gap the bot holds IS the gap the ladder asked for.
	#
	# §2.5 of the plan is the sentence this restores: "the D who gapped a carrier
	# through the neutral zone KEEPS HIM into the zone; there is no handoff at the
	# line." RUSH_D1 and PRESSURE now size the same gap off the same ladder, so the
	# TRANS_OD -> DZONE re-election stops being a geometry discontinuity.
	var carrier_velocity: Vector3 = AIRoleHelpers.resolve_play_ref_velocity(ctx)
	var to_net: Vector3 = our_net - carrier_pos
	var net_dist: float = sqrt(to_net.x * to_net.x + to_net.z * to_net.z)
	var closing_now: float = 0.0
	if net_dist > 0.001:
		closing_now = maxf((carrier_velocity.x * to_net.x
				+ carrier_velocity.z * to_net.z) / net_dist, 0.0)
	# Difficulty pace knob: ctx.pursuit_standoff_m widens the ladder so easier bots
	# sag off the carrier and concede time/space (0.0 = the doctrine gap).
	var gap: float = AIRoleRushD.ladder_gap_m(
			carrier_pos, ctx.own_goal_dir, ctx.self_blade_reach, closing_now) \
			+ ctx.pursuit_standoff_m
	var search_center: Vector3 = carrier_pos
	if net_dist > 0.001:
		search_center += (to_net / net_dist) * minf(gap, net_dist)
	# The lead survives for the PASS-LANE read below, which is about where a feed
	# would be thrown from rather than how close to stand.
	var lead: Vector3 = carrier_pos \
			+ carrier_velocity * SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S

	# LAST MAN: TAKE THE CUT-OFF SET, NEVER LUNGE INTO IT. The cut-off above is
	# one stick-length goal-side of where the carrier is GOING — a challenge
	# position, and the right one while there's a layer home behind us to answer
	# a beaten challenge. As the genuine last man it is also a step-up, and a
	# rush at pace is exactly when that step-up can't be made: measured in the
	# harness, a properly-gapped defender took the transition → PRESSURE handoff at
	# the blue line, saw the cut-off jump 6 m up-ice, charged it at 6 m/s, met
	# the carrier once, and was then blown by and left 10 m behind the play. So
	# bound the approach to the speed the rendezvous leaves room for
	# (AIRoleHelpers.settable_stand_depth). Inert whenever it should be: a carrier who isn't
	# closing on our net (a cycle, a walk-out, an in-zone battle) lifts the
	# limit entirely, and any teammate home behind us skips it — which
	# is every forecheck (F2/F3 are between F1 and our net by construction) and
	# any in-zone look where a MARK is covering the house.
	# The approach bound below is the ICE-frame read, and it is retired for a live
	# carrier for the same reason RUSH_D1's was (AIRoleRushD._settable_gap): it
	# exists because a parked-point seek could only reach a stand by charging it
	# and braking to zero, and the moving-frame route makes that structurally
	# impossible instead — its commanded velocity is the stand's own plus a
	# closing term that decays to nothing on arrival. Running both is two
	# controllers on one axis, and the second one wins in the worst place: it
	# names a stand at wherever the body already is, so the pressurer being walked
	# toward his own net is forbidden from closing on the man walking him there.
	# That is exactly the space this whole read is trying to take away.
	#
	# A loose puck keeps it — there is no man to ride, so the route is a point
	# seek again and the trip genuinely needs bounding.
	var min_depth: float = -INF
	var depth_dir: Vector3 = Vector3.ZERO
	if AIRoleHelpers.stand_ride_velocity(ctx) == Vector3.ZERO \
			and not AIRoleHelpers.has_support_behind(ctx):
		if net_dist > 0.001:
			var net_dir: Vector3 = to_net / net_dist
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

	# Upper bounds for the per-candidate max() early-out: the carrier's
	# option values with the current defenders only. One extra surface pass
	# here lets every candidate below skip the pass lanes that can't matter
	# (identical argmax — see carrier_option_bases). Also the data the
	# CALCULATED closing stands below are built from.
	var bases: Array[float] = ctx.scratch_option_bases
	AIRoleHelpers.carrier_option_bases(
			carrier_pos, our_net, our_goalie_pos,
			our_team_excluding_self, opp_teammates, bases,
			ctx.scratch_teammate_caps)

	# Candidate set. ENGAGED (within the inner-ring range of the cut-off):
	# the full polar ring incl. half-step samples — a pressurer standing at
	# the cut-off expresses small live corrections. CLOSING (the common
	# case): the ring's argmax reduces to a choice between COMPUTABLE
	# stands — its own hysteresis note says the near-tied pair is "block
	# the shot" vs "block the best pass" — so score exactly those directly:
	# the shot-line cut-off (the search center), the same stick-length
	# stand-off dropped onto the carrier's best pass lane (from the bases,
	# already computed), and their midpoint (the split stand). Steering
	# consumes the target at full stride while closing, so the ring's ±3 m
	# refinements were indistinguishable en route.
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
	# Switch-hysteresis: inject the standing cut-off point so it's re-scored live
	# and held (via incumbent_bonus) unless a fresh candidate is clearly better.
	# It runs the same legality / goal-side / anti-crowd filters below, so a
	# now-illegal or wrong-side incumbent is dropped outright.
	AIRoleHelpers.append_incumbent(ctx, candidates)

	var best_pos: Vector3 = ctx.self_pos
	var best_score: float = -INF
	var found: bool = false
	# THE LADDER IS A FLOOR ON THE GAP, not just where the ring is centred. The
	# polar ring spans +/-SEARCH_STEP_M about the centre, so it always contains
	# samples nearer the carrier than the gap — and the score is "how much does my
	# body deflate his options", which is monotonically better the closer you get.
	# Left free the argmax therefore collapses onto him every time and the stand-off
	# is whatever the ring's inner edge happens to be. That is what a fixed lead was
	# quietly preventing: remove the lead without adding this and the separation at
	# the meet falls to 0.35 m over the gap sweep, which is a body-check, not a gap.
	# With the floor the argmax does its real job — the DISTANCE is doctrine, and it
	# picks the BEARING to take the carrier's best option away from.
	var min_gap_sq: float = gap * gap
	for raw: Vector3 in candidates:
		# A CLAMP, not a filter. Dropping the candidates inside the gap empties the
		# set exactly when the ring has closed onto the man — which is the moment
		# that matters — and the argmax then falls through to "stand where you
		# are", so the defender freezes and the carrier walks past him. Pushing
		# each one out onto the gap ring keeps the set non-empty and leaves the
		# argmax its real job: the DISTANCE is doctrine, and it picks the BEARING.
		var c: Vector3 = raw
		var gx: float = raw.x - carrier_pos.x
		var gz: float = raw.z - carrier_pos.z
		var gd_sq: float = gx * gx + gz * gz
		if gd_sq < min_gap_sq:
			if gd_sq > 0.0001:
				var k: float = gap / sqrt(gd_sq)
				c = Vector3(carrier_pos.x + gx * k, 0.0, carrier_pos.z + gz * k)
			elif net_dist > 0.001:
				c = carrier_pos + (to_net / net_dist) * gap
		if not AIRoleHelpers.is_legal_position(c):
			continue
		if not _is_goal_side(c, carrier_pos, our_net):
			continue
		if min_depth > -INF and (c.x - carrier_pos.x) * depth_dir.x \
				+ (c.z - carrier_pos.z) * depth_dir.z < min_depth - 0.01:
			continue  # up-ice of the settable stand — a lunge (see above)
		if AIRoleHelpers.too_close_to_teammate(c, our_team_excluding_self):
			continue

		# Score = -carrier_best_option(with me at c). Higher = better
		# for us (lower for the carrier).
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
	# The cut-off rides the carrier (its whole geometry is built off his led
	# position), so the route is flown in his frame — see AISteering's
	# moving-frame pursuit. This is what makes the last-man bound above
	# executable: it places the stand as a brake trigger for an approach that
	# ends MATCHED to the rush, and an ice-frame seek could only end stopped.
	#
	# ONLY when a candidate actually survived the filters. Every candidate being
	# rejected (the pressurer chased the play off the legal surface, so the whole
	# ring is illegal) leaves `best_pos` at our own feet, which means HOLD — and a
	# hold that rides a man is not a hold, it is "match his velocity forever". Left
	# unguarded that walked a pressurer out through the end boards behind his own
	# net, perfectly gapped 7.5 m off a carrier who was also leaving.
	if found:
		d.target_velocity = AIRoleHelpers.stand_ride_velocity(ctx)
		# And the gap we just sized is ours to hold — see engaged_peer_id.
		if ctx.snapshot != null and ctx.snapshot.puck_state != null:
			var pid: int = ctx.snapshot.puck_state.carrier_peer_id
			if pid != -1 and ctx.team_id_by_peer.get(pid, -1) != ctx.team_id:
				d.engaged_peer_id = pid
	return d


# True if `c` is on the our-net side of the carrier — i.e., between
# the carrier and our defending goal. Encodes the hockey invariant
# *don't lose inside position*: candidates on the wrong side of the
# carrier (toward opp net) get filtered before scoring.
#
# Math: (c - carrier) · (our_net - carrier) > 0 means the candidate
# vector projects positively along the carrier→our-net direction,
# i.e., the candidate is on that side.
static func _is_goal_side(c: Vector3, carrier_pos: Vector3,
		our_net: Vector3) -> bool:
	var to_net: Vector3 = our_net - carrier_pos
	if to_net.length_squared() < 0.001:
		# Carrier sitting on our goal — degenerate, no filter applies.
		return true
	var to_c: Vector3 = c - carrier_pos
	return to_net.x * to_c.x + to_net.z * to_c.z > 0.0
