class_name AIRoleSupport

# SUPPORT role behavior — OZONE + TRANS_DO. The off-puck teammate
# whose job is "be a pass option AND be in a recoverable position."
# In the OZ that means the THIRD MAN HIGH of the 3v3 F1-F2-1 shape:
# stationed at the top of the zone (see HIGH_POST_INSET_M), a point
# outlet who keeps squirting pucks in and is the first man back on a
# turnover. In transition it trails the carrier (goal-side orbit).
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
# the fastest opp's momentum-aware ETA via time_to_arrive. It's a SOFT
# depth bias (clamped to [0, EXPOSURE_MAX]), never a veto — the hard
# goal-side-of-carrier constraint below is the real safety, so exposure
# only shades SUPPORT toward the recoverable side of the band without
# ever zeroing out the up-ice option and stranding it off the play.
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

# The third man's OZ station: this far inside the attacking blue line. Close
# enough to the line to hold the zone (a squirting puck is kept in) and to be
# the first man back the instant possession flips; inside enough to stay
# comfortably onside and be a real point outlet. The 3v3 F1-F2-1 shape: puck
# man, net man (FINISHER), third man HIGH. Sampling the third man around the
# CARRIER instead (the old set) glued him to within SEARCH_RADIUS_M of the
# play by construction — the "third man pinches" failure: no high candidate
# ever existed to choose.
const HIGH_POST_INSET_M: float = 3.0

# Safety-valve constraint. SUPPORT is the conservative trailer: it stays
# goal-side of (no further toward the opp net than) the carrier so the
# carrier is never the last man back — if the carrier is stripped,
# SUPPORT is already the recovery layer for the rush the other way. The
# tolerance lets SUPPORT sit roughly EVEN with the carrier (a weak-side
# option even with the puck) without drifting into a true stretch
# position ahead of it; ~one stick-length of slack, not a behavioral
# knob to open up the offense. Raise OUTLET's role for the up-ice option.
const GOAL_SIDE_TOLERANCE_M: float = 1.5

# Ceiling on the exposure penalty in TRANSITION only (the OZ point keeps a full
# 1.0 veto — see decide()). In transition the HARD goal-side-of-carrier
# constraint already guarantees SUPPORT is the first man back: the carrier is
# near the NZ, so "goal-side of the carrier" keeps SUPPORT recoverable by
# construction. Letting exposure saturate to 1.0 there double-counts that safety,
# and its only effect is to zero out EVERY up-ice candidate the moment any
# opponent sits deep near our net (a beaten forechecker) — stranding the trailer
# deep in our own zone instead of tracking the rush up behind the carrier (the
# "furthest player never joins the transition" failure). Capping it keeps a floor
# of pass value on the up-ice option so SUPPORT still follows the play, while the
# residual penalty keeps biasing it to the deeper side of the goal-side band.
# Feel-tunable; the hard constraint is the real safety.
const EXPOSURE_MAX: float = 0.6


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

	# Exposure is only a SOFT bias in TRANSITION, where the hard goal-side-of-
	# carrier constraint (carrier near the NZ) already keeps SUPPORT recoverable,
	# so a saturating penalty just strands the trailer deep off the rush (#2). In
	# the OFFENSIVE ZONE the carrier is deep, so "goal-side of the carrier" still
	# permits a deep, genuinely-exposed point position — there the recovery race
	# is real, so exposure keeps its full veto to stop the point man pinching into
	# a turnover (#3).
	var exposure_cap: float = 1.0 if AIActionScoring.in_offensive_zone(
			carrier_pos, ctx.attacking_goal_pos) else EXPOSURE_MAX

	# Search around the carrier. Polar samples cover the cycle space;
	# anti-crowd filter rejects the carrier-overlap candidate.
	var candidates: Array[Vector3] = _generate_candidates(ctx, carrier_pos)
	# Switch-hysteresis: hold the chosen station unless a fresh spot is clearly
	# better, so the cursor (which snaps to this target) stays steady.
	AIRoleHelpers.append_incumbent(ctx, candidates)

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
		var exposure: float = _exposure(
				c, our_net, min_opp_time_home, ctx.self_max_speed, exposure_cap)
		var score: float = pass_value * (1.0 - exposure) + AIRoleHelpers.incumbent_bonus(ctx, c)
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

# Zone-dependent station:
#   Carrier IN the offensive zone → sample around the HIGH POST (top of the
#     zone, x shaded to the carrier's side — the same strong-side read F2 uses
#     on the forecheck), plus the half-wall midpoint toward the carrier (the
#     classic cycle bump spot) and self. The third man plays HIGH: point
#     outlet, zone-keeper, first man back.
#   Carrier still in transit (TRANS_DO / NZ) → the old carrier-orbit samples;
#     the high post would be AHEAD of the play there and the goal-side filter
#     would reject the whole set (SUPPORT is the trailer in transition).
# The score function (pass value × recoverability) picks within the station.
static func _generate_candidates(ctx: RoleContext, carrier_pos: Vector3) -> Array[Vector3]:
	var result: Array[Vector3] = []
	result.append(ctx.self_pos)
	if AIActionScoring.in_offensive_zone(carrier_pos, ctx.attacking_goal_pos):
		var blue_z: float = -ctx.own_goal_dir * GameRules.BLUE_LINE_Z
		var high_post := Vector3(
				carrier_pos.x * 0.5,
				0.0,
				blue_z - ctx.own_goal_dir * HIGH_POST_INSET_M)
		for angle: float in AIRoleHelpers.POLAR_ANGLES:
			result.append(Vector3(
					high_post.x + SEARCH_RADIUS_M * cos(angle),
					0.0,
					high_post.z + SEARCH_RADIUS_M * sin(angle)))
		result.append(high_post)
		# Half-wall cycle option between the high post and the carrier.
		result.append((high_post + carrier_pos) * 0.5)
		return result
	result.append(carrier_pos)
	for angle: float in AIRoleHelpers.POLAR_ANGLES:
		result.append(Vector3(
				carrier_pos.x + SEARCH_RADIUS_M * cos(angle),
				0.0,
				carrier_pos.z + SEARCH_RADIUS_M * sin(angle)))
	return result


# ── Role-specific scoring ────────────────────────────────────────────────────

# Min over opponents of momentum-aware ETA back to our net. Shared race-home
# primitive (AIRoleHelpers.min_opp_time_home) — also the forecheck safety's
# pinch read.
static func _min_opp_time_home(opp_states: Array[SkaterNetworkState],
		opp_caps: Array, our_net: Vector3) -> float:
	return AIRoleHelpers.min_opp_time_home(opp_states, opp_caps, our_net)


# Foot-race-home exposure in [0, cap]. 0 when I beat every opp back to our net;
# ramps up as my ETA exceeds the fastest opp's. `cap` bounds the penalty: the
# OZ point passes 1.0 (a full veto — the recovery race there is real), the
# transition trailer passes EXPOSURE_MAX (a soft bias, since the hard goal-side
# constraint already keeps it recoverable — see the decide() note). The lower
# clamp at 0 keeps the factor non-negative so a deeply-exposed candidate can't
# invert the argmax (small pass_value × large negative beating big pass_value ×
# less-negative).
static func _exposure(candidate: Vector3, our_net: Vector3,
		min_opp_time_home: float, self_max_speed: float = AIActionScoring.SKATER_REF_SPEED_M_S,
		cap: float = 1.0) -> float:
	var safe_time: float = maxf(min_opp_time_home, 0.001)
	var dist: float = candidate.distance_to(our_net)
	# My own foot-race home at MY real top speed (Speed) — a fast defender is less
	# exposed from the same spot.
	var my_time: float = dist / maxf(self_max_speed, 0.001)
	return clampf(my_time / safe_time - 1.0, 0.0, cap)
