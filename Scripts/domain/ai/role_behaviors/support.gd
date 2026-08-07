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
#     score_pass(carrier, candidate) − counter_cost(candidate)
#
# `score_pass` (existing AIActionScoring primitive) handles
# "available for a pass + good shot if I receive": it factors lane
# clearance from carrier through projected opponents and recursively
# evaluates the candidate's own future-action value via score_at.
#
# `counter_cost` is the COVERING-SET exposure (AIActionScoring.
# counter_rush_cost — the same grounded model the carrier's transition-
# exposure term runs): IF possession flips at the carrier, the fastest
# opponent collects the loss and drives the counter point, and the threat
# he generates there survives only the bodies that beat him home with time
# to set — teammates, and SUPPORT ITSELF racing back from the candidate
# being priced. Standing somewhere recoverable literally erases the
# counter (self joins the covering set → the counter shot is a blocked
# look); standing somewhere deep leaves it live. The whole thing is
# weighted by a REAL turnover probability: the CARRIER's live stand
# safety (1 − carry_safety at his spot) — a pressured cycle carrier makes
# recoverability worth paying for, an unpressured rush frees the trailer
# to play offense. This replaced a frozen body-ETA time ramp
# (my_time/safe_time − 1) whose canonical failure was the crease-lurker: a
# beaten forechecker parked at our crease zeroed every up-ice spot, paying
# SUPPORT to strand home — under the covering-set read that lurker must
# skate all the way UP to collect a loss and all the way BACK, so the
# covering set beats him trivially and the trailer joins the rush.
#
# Search center is derived from in-game references (the carrier's
# position) rather than ctx.anchor. Polar samples around the carrier
# feed the score function; the counter cost penalizes candidates that
# leave the counter uncovered, biasing toward recoverable depth.
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

# Scratch buffers for the covering-set exposure (caller-owned pattern —
# refilled once per decide, no per-candidate allocation).
static var _scratch_opp_vels: Array[Vector3] = []
# Sprint pools index-matched to the opponent list, lockout folded in as 0.0
# (the counter-rush racer's stamina-gated race cap).
static var _scratch_opp_stamina: Array[float] = []
static var _scratch_mate_etas: Array[float] = []
static var _scratch_threat_by_cover: Array[float] = []


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

	# Covering-set exposure inputs — all candidate-invariant, computed once
	# (see the header): the turnover prior is the CARRIER's live stand
	# safety, the counter collects at the carrier, and each teammate's race
	# to the counter point is pre-solved. Only SUPPORT's own recovery race
	# (self from the candidate) varies per candidate, inside
	# counter_rush_cost. An unpressured carrier → prior 0 → the cost
	# short-circuits and the argmax is pure pass value.
	_scratch_opp_vels.clear()
	_scratch_opp_stamina.clear()
	for s: SkaterNetworkState in opp_states:
		_scratch_opp_vels.append(s.velocity)
		_scratch_opp_stamina.append(0.0 if s.sprint_locked else s.stamina)
	var turnover_prior: float = 0.0
	if not opp_positions.is_empty():
		turnover_prior = 1.0 - AIActionScoring.carry_safety(
				carrier_pos, carrier_pos, AIActionScoring.EVADE_HORIZON_S,
				opp_positions, _scratch_opp_vels, ctx.scratch_opp_caps)
	AIActionScoring.fill_counter_cover_etas(
			our_net, teammate_positions, _scratch_mate_etas)
	_scratch_threat_by_cover.clear()
	for _i: int in teammate_positions.size() + 2:
		_scratch_threat_by_cover.append(-1.0)
	var our_goalie: Vector3 = AIRoleHelpers.resolve_our_goalie_pos(ctx)

	# Far from the station, skate at the CALCULATED post directly — the
	# openness argmax refines a read that will be re-taken from closer before
	# arrival (see STATION_ARGMAX_LOD_M). In the OZ the station is the high
	# post; in transit it's the goal-side trail a step behind the carrier
	# (always passes the goal-side valve by construction).
	var station: Vector3
	if AIActionScoring.in_offensive_zone(carrier_pos, ctx.attacking_goal_pos):
		station = Vector3(
				carrier_pos.x * 0.5, 0.0,
				-ctx.own_goal_dir * GameRules.BLUE_LINE_Z
						- ctx.own_goal_dir * HIGH_POST_INSET_M)
	else:
		station = carrier_pos + Vector3(
				0.0, 0.0, ctx.own_goal_dir * AIRoleHelpers.SEARCH_STEP_M)
	if not AIRoleHelpers.station_needs_refinement(ctx.self_pos, station):
		d.target_position = station
		return d

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
		# Pre-armed feed keeper (backdoor_depth_cap on v3's predicted pose):
		# a candidate the keeper can pre-arm against prices merely-strong
		# instead of phantom-certain, so structural stations genuinely
		# compete with the seam (the SUPPORT flank pend).
		var cand_flight: float = carrier_pos.distance_to(c) / maxf(pass_speed, 1.0)
		AIActionScoring.resolve_feed_keeper(
				goalie_pos, ctx.attacking_goal_pos, cand_flight, c, carrier_pos,
				AIRoleHelpers.opp_goalie_hands(ctx), pass_speed, opp_positions)
		var pass_value: float = AIActionScoring.score_pass(
				carrier_pos, c, ctx.attacking_goal_pos,
				AIActionScoring.feed_keeper_pos, GameRules.NET_HALF_WIDTH,
				opp_positions, pass_speed, AIActionScoring.feed_keeper_unsettled,
				-1.0, AIActionScoring.feed_keeper_hands, Vector4.INF,
				ctx.scratch_opp_caps)
		var counter_cost: float = AIActionScoring.counter_rush_cost(
				carrier_pos, turnover_prior, our_net, our_goalie,
				GameRules.NET_HALF_WIDTH, teammate_positions, c,
				ctx.self_max_speed, opp_positions, _scratch_opp_vels,
				ctx.scratch_opp_caps, _scratch_mate_etas, _scratch_threat_by_cover,
				_scratch_opp_stamina)
		var score: float = pass_value - counter_cost + AIRoleHelpers.incumbent_bonus(ctx, c)
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
		# NAMED third-man-high stations — the OZ zone-keeper geography, not a
		# blind ring around one center (same conversion as the finisher's
		# one-timer stations). Each is a structural cycle spot; the scoring
		# (pass value × recoverability) arbitrates per the live coverage:
		var blue_z: float = -ctx.own_goal_dir * GameRules.BLUE_LINE_Z
		var post_z: float = blue_z - ctx.own_goal_dir * HIGH_POST_INSET_M
		var wall_sign: float = signf(carrier_pos.x) if absf(carrier_pos.x) > 0.1 \
				else ctx.strong_x
		# HIGH POST — top of the zone shaded to the carrier's side: the
		# point outlet / zone keeper / first man back.
		var high_post := Vector3(carrier_pos.x * 0.5, 0.0, post_z)
		result.append(high_post)
		# HALF-WALL BUMP — the classic cycle bump spot between the high post
		# and the carrier's wall.
		result.append((high_post + carrier_pos) * 0.5)
		# CENTER POINT — the middle of the line: the cross-ice outlet when
		# the strong-side lane is walled off.
		result.append(Vector3(0.0, 0.0, post_z))
		# WEAK FLANK — the far dot lane at the top of the circles: the
		# cross-seam outlet that flips the point of attack.
		result.append(Vector3(
				-wall_sign * GameRules.END_ZONE_FACEOFF_DOT_X, 0.0,
				ctx.attacking_goal_pos.z + ctx.own_goal_dir
						* (GameRules.GOAL_LINE_Z - GameRules.ICING_FACEOFF_DOT_Z + 3.0)))
		return result
	result.append(carrier_pos)
	for angle: float in AIRoleHelpers.POLAR_ANGLES:
		result.append(Vector3(
				carrier_pos.x + SEARCH_RADIUS_M * cos(angle),
				0.0,
				carrier_pos.z + SEARCH_RADIUS_M * sin(angle)))
	return result


