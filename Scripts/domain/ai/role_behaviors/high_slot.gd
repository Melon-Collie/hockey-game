class_name AIRoleHighSlot

# HIGH_SLOT role behavior — OZONE, 5v5 only. The third forward ("F3"): floats
# the soft ice between the dots at the top of the house, stays ABOVE the puck
# (own-goal-side of it — "F3 keeps the puck and all four teammates in front
# of him"), is the seam/one-timer option on the low-to-high or cross-ice
# feed, and is the designated first man back on a turnover. Design: plan §2
# (OZONE) + the appendix's F3 rules.
#
# Positioning is a small argmax over the high-slot band: candidates score
# their ONE-TIMER LOOK (feed lane from the carrier × shot lane to the net —
# the seam read), with the above-the-puck rule as a hard filter and the
# race home as the depth bound (the F3-conscience half: sag when a counter
# threat looms, exactly the forecheck-F3 read applied inside the zone).

# The float band: depths off the attacked goal line and lateral samples
# (weak-side shaded — the seam is usually back across the grain).
const BAND_DEPTHS_M: Array[float] = [8.0, 9.5, 11.0]
const BAND_LATERAL_M: Array[float] = [-3.0, -1.5, 0.0, 1.5, 3.0]
# Stay this far above (own-goal-side of) the puck.
const ABOVE_PUCK_MARGIN_M: float = 1.0


static func decide(ctx: RoleContext) -> RoleDecision:
	var d := RoleDecision.new()
	var own_dir: float = ctx.own_goal_dir
	var opp_net: Vector3 = ctx.attacking_goal_pos

	var carrier_pos: Vector3 = AIRoleHelpers.resolve_offensive_play_ref(ctx)
	if not carrier_pos.is_finite():
		d.target_position = ctx.self_pos
		return d

	var opp_positions: Array[Vector3] = ctx.scratch_opp_positions
	var opp_states: Array[SkaterNetworkState] = ctx.scratch_opp_states
	AIRoleHelpers.collect_opponents(ctx, opp_positions, opp_states)
	var teammates: Array[Vector3] = ctx.scratch_teammates
	AIRoleHelpers.collect_teammates_excluding_self(ctx, teammates)
	var our_net: Vector3 = ctx.defending_goal_pos
	# First-man-back bound: never float where the counter paths aren't
	# contained (fill_counter_channels — the path-intercept race-home read).
	AIRoleHelpers.fill_counter_channels(ctx, opp_states, our_net)

	# Far from the band, skate at the CALCULATED float spot directly — the
	# seam argmax refines a look that gets re-read from closer before arrival
	# (see STATION_ARGMAX_LOD_M). The first-man-back race bound still applies
	# to the direct spot (the channel fill above is memoized, so this is a
	# handful of squared compares).
	var band_center := Vector3(
			0.0, 0.0, opp_net.z + own_dir * BAND_DEPTHS_M[1])
	if not AIRoleHelpers.station_needs_refinement(ctx.self_pos, band_center):
		d.target_position = AIRoleHelpers.most_forward_feasible(
				band_center, ctx.self_max_speed, ctx.self_max_accel)
		return d

	var pass_speed_ref: float = AIActionScoring.expected_pass_speed(
			carrier_pos, opp_net)
	var best_pos: Vector3 = ctx.self_pos
	var best_score: float = -INF
	for depth: float in BAND_DEPTHS_M:
		var z: float = opp_net.z + own_dir * depth
		for x: float in BAND_LATERAL_M:
			var c := Vector3(x, 0.0, z)
			# Above the puck, always: own-goal-side of the carrier.
			if own_dir * c.z < own_dir * carrier_pos.z + ABOVE_PUCK_MARGIN_M:
				continue
			if not AIRoleHelpers.is_legal_position(c):
				continue
			if not AIRoleHelpers.race_home_feasible(
					c, ctx.self_max_speed, ctx.self_max_accel):
				continue
			if AIRoleHelpers.too_close_to_teammate(c, teammates):
				continue
			# The seam look: can the carrier feed me here (lane_clear at a
			# real pass speed), and can I shoot from here (lane to the net)?
			var feed: float = AIActionScoring.lane_clear(
					carrier_pos, c, opp_positions, pass_speed_ref)
			var shot: float = AIActionScoring.lane_clear(
					c, opp_net, opp_positions, ctx.self_wrister_shot_speed)
			var score: float = feed * shot + AIRoleHelpers.incumbent_bonus(ctx, c)
			if score > best_score:
				best_score = score
				best_pos = c
	if best_score == -INF:
		# Whole band filtered (deep carrier + heavy counter threat): sag from
		# the top of the zone down the retreat line as far as the counter
		# paths demand.
		best_pos = AIRoleHelpers.most_forward_feasible(
				Vector3(0.0, 0.0,
						opp_net.z + own_dir * (GameRules.GOAL_LINE_Z - GameRules.BLUE_LINE_Z - 1.0)),
				ctx.self_max_speed, ctx.self_max_accel)
	d.target_position = best_pos
	return d
