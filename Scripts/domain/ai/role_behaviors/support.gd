class_name AIRoleSupport

# SUPPORT role behavior — OZONE + TRANS_DO. The off-puck teammate
# whose job is "be a pass option AND be in a recoverable position."
#
# Algorithm: argmax over a candidate set of
#
#     score_pass(carrier, candidate) × (1 - exposure(candidate))
#
# `score_pass` (existing AIActionScoring primitive) handles
# "available for a pass + good shot if I receive": it factors lane
# clearance from carrier through projected opponents and recursively
# evaluates the candidate's own future-action value via score_at.
#
# `exposure` is the foot-race-home consideration so SUPPORT doesn't
# get caught past the play. Compares my sprint ETA to our net against
# the fastest opp's momentum-aware ETA via time_to_arrive. Floored
# at 0; the (1 - exposure) factor goes negative when opps clearly
# beat me home, naturally rejecting unrecoverable candidates.
#
# Search center is derived from in-game references (the carrier's
# position) rather than ctx.anchor. Polar samples around the carrier
# feed the score function; exposure penalizes candidates the opp would
# beat us back from, biasing toward recoverable depth.
#
# On top of that soft bias, SUPPORT enforces a HARD goal-side
# constraint (GOAL_SIDE_TOLERANCE_M): candidates up-ice of the carrier
# are rejected outright. SUPPORT is the conservative trailer / safety
# valve — the carrier must never be the last man back, so if they're
# stripped SUPPORT is already the recovery layer. The up-ice stretch
# option is OUTLET's job, not SUPPORT's. Without the hard constraint
# the pass-quality term would sometimes pull SUPPORT even with or ahead
# of the carrier on a clean breakout, leaving no one home.

# Polar sampling radius around the search center. Same scale as
# AIRoleCarrier.CARRY_SEARCH_STEP_M (3.0 m) — sampling parameter,
# not a behavioral knob. The carrier itself is excluded by the
# anti-crowding filter; samples at the rim of the circle remain.
const SEARCH_RADIUS_M: float = 5.0

# Safety-valve constraint. SUPPORT is the conservative trailer: it stays
# goal-side of (no further toward the opp net than) the carrier so the
# carrier is never the last man back — if the carrier is stripped,
# SUPPORT is already the recovery layer for the rush the other way. The
# tolerance lets SUPPORT sit roughly EVEN with the carrier (a weak-side
# option even with the puck) without drifting into a true stretch
# position ahead of it; ~one stick-length of slack, not a behavioral
# knob to open up the offense. Raise OUTLET's role for the up-ice option.
const GOAL_SIDE_TOLERANCE_M: float = 1.5


static func decide(ctx: RoleContext) -> RoleDecision:
	var d := RoleDecision.new()

	# No live teammate carrier (loose puck / pass in flight) — orient
	# off the puck instead of freezing, so SUPPORT keeps flowing into
	# the developing play. Only truly stand still if there's no puck.
	var carrier_pos: Vector3 = AIRoleHelpers.resolve_offensive_play_ref(ctx)
	if not carrier_pos.is_finite():
		d.target_position = ctx.self_pos
		return d

	var our_net: Vector3 = ctx.defending_goal_pos
	var goalie_pos: Vector3 = AIRoleHelpers.resolve_opp_goalie_pos(ctx)

	var opp_positions: Array[Vector3] = ctx.scratch_opp_positions
	var opp_states: Array[SkaterNetworkState] = ctx.scratch_opp_states
	AIRoleHelpers.collect_opponents(ctx, opp_positions, opp_states)

	var teammate_positions: Array[Vector3] = ctx.scratch_teammates
	AIRoleHelpers.collect_teammates_excluding_self(ctx, teammate_positions)
	var min_opp_time_home: float = _min_opp_time_home(opp_states, ctx.scratch_opp_caps, our_net)

	# Search around the carrier. Polar samples cover the cycle space;
	# anti-crowd filter rejects the carrier-overlap candidate.
	var candidates: Array[Vector3] = _generate_candidates(ctx, carrier_pos)

	var best_pos: Vector3 = ctx.self_pos
	var best_score: float = -INF
	for c: Vector3 in candidates:
		if not AIRoleHelpers.is_legal_position(c):
			continue
		if AIRoleHelpers.too_close_to_teammate(c, teammate_positions):
			continue
		# Safety-valve: reject candidates up-ice of the carrier so
		# SUPPORT stays the goal-side recovery layer (see
		# GOAL_SIDE_TOLERANCE_M). Carrier never the last man back.
		if not _is_goal_side_of_carrier(c, carrier_pos, ctx.own_goal_dir):
			continue
		# Match the speed our carrier would actually fire at (see
		# finisher.gd for rationale).
		var pass_speed: float = AIActionScoring.expected_pass_speed(carrier_pos, c)
		var pass_value: float = AIActionScoring.score_pass(
				carrier_pos, c, ctx.attacking_goal_pos,
				goalie_pos, GameRules.NET_HALF_WIDTH,
				opp_positions, pass_speed)
		var exposure: float = _exposure(c, our_net, min_opp_time_home, ctx.self_max_speed)
		var score: float = pass_value * (1.0 - exposure)
		if score > best_score:
			best_score = score
			best_pos = c

	d.target_position = best_pos
	return d


# True if candidate `c` is goal-side of (or roughly even with) the
# carrier on the rink's depth axis — i.e., no further toward the opp
# net than the carrier, within GOAL_SIDE_TOLERANCE_M. own_goal_dir is
# +1 when our net is at +Z and -1 when at -Z, so own_goal_dir * z grows
# toward our net; a larger value is "deeper / more goal-side".
static func _is_goal_side_of_carrier(c: Vector3, carrier_pos: Vector3,
		own_goal_dir: float) -> bool:
	return own_goal_dir * c.z >= own_goal_dir * carrier_pos.z - GOAL_SIDE_TOLERANCE_M


# ── Candidate generation (in-game-ref) ──────────────────────────────────────

# 8 polar samples at SEARCH_RADIUS_M around the carrier, plus self
# (stand-still) and the carrier's own position (which the anti-crowd
# filter rejects but is included for symmetry with other roles).
# No "search center" or "trail depth" formulas — the carrier is the
# ref, and the score function picks the best direction.
static func _generate_candidates(ctx: RoleContext, carrier_pos: Vector3) -> Array[Vector3]:
	var result: Array[Vector3] = []
	result.append(carrier_pos)
	result.append(ctx.self_pos)
	for angle: float in AIRoleHelpers.POLAR_ANGLES:
		result.append(Vector3(
				carrier_pos.x + SEARCH_RADIUS_M * cos(angle),
				0.0,
				carrier_pos.z + SEARCH_RADIUS_M * sin(angle)))
	return result


# ── Role-specific scoring ────────────────────────────────────────────────────

# Min over opponents of momentum-aware ETA back to our net. INF
# when there are no opponents (no recovery threat).
static func _min_opp_time_home(opp_states: Array[SkaterNetworkState],
		opp_caps: Array, our_net: Vector3) -> float:
	var has_caps: bool = opp_caps.size() == opp_states.size()
	var best: float = INF
	for i: int in opp_states.size():
		var s: SkaterNetworkState = opp_states[i]
		# Each opponent races home at ITS real top speed (Speed) — a fast opponent
		# recovers sooner, so SUPPORT correctly reads it as harder to beat back.
		var ref_speed: float = AIActionScoring.SKATER_REF_SPEED_M_S
		if has_caps:
			var caps: AISkaterCaps = opp_caps[i]
			if caps != null:
				ref_speed = caps.max_speed
		var t: float = AIActionScoring.time_to_arrive(s.position, our_net, s.velocity, ref_speed)
		if t < best:
			best = t
	return best


# Foot-race-home exposure in [0, 1]. 0 when I beat every opp back
# to our net; ramps to 1 (full unrecoverable) as my ETA exceeds the
# fastest opp's. CLAMPED to 1 so (1 - exposure) stays non-negative —
# without the upper clamp, the factor goes negative for deeply-
# exposed candidates, and multiplying score_pass by a large negative
# INVERTS the argmax preference (small pass_value × large negative
# wins over big pass_value × less-negative, picking the most exposed
# candidate). Clamp pushes all-exposed-equally candidates to score 0
# so the loop falls back to self_pos.
static func _exposure(candidate: Vector3, our_net: Vector3,
		min_opp_time_home: float, self_max_speed: float = AIActionScoring.SKATER_REF_SPEED_M_S) -> float:
	var safe_time: float = maxf(min_opp_time_home, 0.001)
	var dist: float = candidate.distance_to(our_net)
	# My own foot-race home at MY real top speed (Speed) — a fast defender is less
	# exposed from the same spot.
	var my_time: float = dist / maxf(self_max_speed, 0.001)
	return clampf(my_time / safe_time - 1.0, 0.0, 1.0)
