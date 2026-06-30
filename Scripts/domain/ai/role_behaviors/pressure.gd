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
# the puck; "getting caught up-ice" isn't applicable. ANCHOR / COVER
# own defensive recovery for this team.

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
	# ANCHOR/COVER in DZONE, F2/F3 on the forecheck (F1 dispatches here) — so
	# the commit risk is acceptable; the last-man gap defender (CONTAIN) never
	# hunts hits. When committed, drive at the body intercept; the state machine
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

	# Search center = "where the carrier will be at the next action
	# horizon, shifted one stick-length back toward our net". Both
	# offsets are real game quantities:
	#   - BOT_WRISTER_LOOKAHEAD_S is the same action horizon the
	#     carrier uses to score its own shots, so leading by it
	#     positions us at the carrier's next decision point rather
	#     than chasing their current footprint.
	#   - BLADE_REACH_M shifts toward our net by exactly the distance
	#     our stick can poke-check, putting candidates inside contest
	#     range on the defensive side — the cut-off line — instead of
	#     on top of the carrier.
	# Goal-side filter below still trims wrong-side polar samples.
	# Lead off the carrier's velocity, or the puck's when it's loose /
	# in flight (carrier_pid == -1 → no skater_states entry to index).
	var carrier_velocity: Vector3 = AIRoleHelpers.resolve_play_ref_velocity(ctx)
	var lead: Vector3 = carrier_pos + carrier_velocity * SkaterAgentStateMachine.BOT_WRISTER_LOOKAHEAD_S
	var to_net: Vector3 = our_net - lead
	var search_center: Vector3 = lead
	if to_net.length_squared() > 0.0001:
		search_center += to_net.normalized() * SkaterAgentStateMachine.BLADE_REACH_M

	# Search around the cut-off point; goal-side filter rejects the
	# half-disc on the wrong side of the carrier (toward opp net).
	var candidates: Array[Vector3] = AIRoleHelpers.generate_candidates_around(
			ctx.self_pos, search_center)

	var best_pos: Vector3 = ctx.self_pos
	var best_score: float = -INF
	for c: Vector3 in candidates:
		if not AIRoleHelpers.is_legal_position(c):
			continue
		if not _is_goal_side(c, carrier_pos, our_net):
			continue
		if AIRoleHelpers.too_close_to_teammate(c, our_team_excluding_self):
			continue

		# Score = -carrier_best_option(with me at c). Higher = better
		# for us (lower for the carrier).
		var pressure_score: float = -_carrier_best_option(
				c, carrier_pos, our_net, our_goalie_pos,
				our_team_excluding_self, opp_teammates)
		if pressure_score > best_score:
			best_score = pressure_score
			best_pos = c

	d.target_position = best_pos
	return d


# Computes the carrier's best option (shoot or pass to any teammate)
# with our hypothetical defender position included. Returns the max
# over all options — that's what PRESSURE wants to minimize.
#
# Uses the threat-surface helpers so the gradient survives when
# score_shoot / score_pass collapse to 0 (carrier far from net or
# all receivers far from net). The position_potential floor pulls
# PRESSURE tight to the carrier in TRANS_OD scenarios where there's
# no immediate scoring threat to defend — without it the score is
# flat across goal-side candidates and PRESSURE picks arbitrarily.
static func _carrier_best_option(
		candidate: Vector3,
		carrier_pos: Vector3,
		our_net: Vector3,
		our_goalie_pos: Vector3,
		our_team_excluding_self: Array[Vector3],
		opp_teammates: Array[Vector3]) -> float:
	# Build the carrier's view of defenders: our team + me at c.
	var carrier_view_defenders: Array[Vector3] = our_team_excluding_self.duplicate()
	carrier_view_defenders.append(candidate)

	# Carrier's best shot at our net (with positional fallback floor).
	var shoot_value: float = AIActionScoring.threat_surface_shoot(
			carrier_pos, our_net, our_goalie_pos,
			GameRules.NET_HALF_WIDTH, carrier_view_defenders)

	# Carrier's best pass to any teammate (with positional fallback).
	# Use our_net as `attacking_goal` — the carrier is shooting at OUR
	# net, so the receiver's threat is evaluated against our goalie.
	var pass_value: float = 0.0
	for opp_pos: Vector3 in opp_teammates:
		var pass_score: float = AIActionScoring.threat_surface_pass(
				carrier_pos, opp_pos, our_net, our_goalie_pos,
				GameRules.NET_HALF_WIDTH, carrier_view_defenders)
		if pass_score > pass_value:
			pass_value = pass_score

	return maxf(shoot_value, pass_value)


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
