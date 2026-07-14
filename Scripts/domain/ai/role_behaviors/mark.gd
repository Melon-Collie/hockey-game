class_name AIRoleMark

# MARK role behavior — the off-puck man-marker. Used by DZONE and TRANS_OD:
# the defenders NOT engaging the puck carrier (PRESSURE in DZONE, CONTAIN on a
# rush) each MARK a distinct assigned opponent — pick up a MAN, not a patch of
# ice.
#
# Unifies the old ANCHOR / COVER (DZONE) and BACKCHECK (TRANS_OD) roles, which
# had converged: when TeamBrain's threat partition assigns a man (the normal
# case) all three ran byte-for-byte identical code — cover the assigned man
# goal-side, in the carrier→man feed lane. They differed only in a rarely-run
# unassigned fallback (two of the three were a literal copy-paste). Net-front
# vs. weak-side vs. sprint-home positioning is emergent: it falls out of WHICH
# man the optimal matcher (AIThreatAssignment) hands this defender, plus the
# shared cover_man_target geometry and the state machine's sprint resolver — not
# separate role code. One marker per man is the matcher's guarantee, so two
# defenders never stack on the same opponent.
#
# ── Primary (assigned a man) ─────────────────────────────────────────────────
# Cover the assigned opponent: set up goal-side of where he's cutting (his
# velocity-led position), in the carrier→man feed lane. A defender already
# skating the right way wins the pairing upstream, so this is pure positioning.
#
# ── Fallback (unassigned) ────────────────────────────────────────────────────
# No man assigned — more markers than the carrier has receivers, a loose puck,
# or no brain. Recover to the most dangerous ice: argmax over a slot-region
# candidate set of
#
#     -max over opps of threat_surface_shoot(
#         opp, our_net, our_goalie, our_team_with_us_at_c)
#
# so an extra marker with no man still races home and helps at the net. The
# search center is the midpoint between the puck and our net, which interpolates
# correctly across both states this role serves — puck NZ-side (TRANS_OD) pulls
# the center out toward our blue line, puck deep (DZONE) pulls it to the slot —
# so one fallback covers both zones without a per-state branch.


static func decide(ctx: RoleContext) -> RoleDecision:
	var d := RoleDecision.new()

	# Man-on-threat: when the brain assigns us a specific opponent, cover HIM
	# (deny the carrier's feed to him). Needs a live carrier (the feed source);
	# resolve_defensive_play_ref returns INF when there's no puck, dropping us
	# to the recovery fallback below.
	var man_pid: int = ctx.assigned_threat_peer
	if man_pid != -1 and ctx.snapshot != null \
			and ctx.snapshot.skater_states.has(man_pid):
		var carrier_pos: Vector3 = AIRoleHelpers.resolve_defensive_play_ref(ctx)
		if carrier_pos.is_finite():
			# Anticipate: cover where the man is cutting, not his current spot.
			var man: SkaterNetworkState = ctx.snapshot.skater_states[man_pid]
			var man_pos: Vector3 = AIRoleHelpers.lead_threat(
					man.position, man.velocity, ctx.defensive_anticipation_scale)
			d.target_position = AIRoleHelpers.cover_man_target(ctx, man_pos, carrier_pos)
			return d

	var opp_positions: Array[Vector3] = ctx.scratch_opp_positions
	var opp_states: Array[SkaterNetworkState] = ctx.scratch_opp_states
	AIRoleHelpers.collect_opponents(ctx, opp_positions, opp_states, true)
	if opp_positions.is_empty():
		# No opps to defend against.
		d.target_position = ctx.self_pos
		return d

	var our_net: Vector3 = ctx.defending_goal_pos
	var our_goalie_pos: Vector3 = AIRoleHelpers.resolve_our_goalie_pos(ctx)
	var our_team_excluding_self: Array[Vector3] = ctx.scratch_teammates
	AIRoleHelpers.collect_teammates_excluding_self(ctx, our_team_excluding_self)

	# Search center: midpoint between puck and our net. Pure in-game refs — the
	# region interpolates between TRANS_OD (puck NZ-side → midpoint at our blue
	# line) and DZONE (puck deep → midpoint near net). Falls back to slot when
	# puck_state is unavailable so a missing snapshot doesn't strand MARK at
	# (0, 0, 0).
	var search_center: Vector3
	if ctx.snapshot != null and ctx.snapshot.puck_state != null:
		search_center = (ctx.snapshot.puck_state.position + our_net) * 0.5
	else:
		search_center = Vector3(
				0.0,
				0.0,
				our_net.z - ctx.own_goal_dir * GameRules.SLOT_DIST_M)
	var candidates: Array[Vector3] = AIRoleHelpers.generate_candidates_around(
			ctx.self_pos, search_center)
	# Switch-hysteresis: hold the recovery spot unless a fresh one covers clearly
	# more dangerous ice, so the cursor (which snaps to this target) stays steady.
	AIRoleHelpers.append_incumbent(ctx, candidates)

	var best_pos: Vector3 = ctx.self_pos
	var best_score: float = -INF
	for c: Vector3 in candidates:
		if not AIRoleHelpers.is_legal_position(c):
			continue
		if AIRoleHelpers.too_close_to_teammate(c, our_team_excluding_self):
			continue

		var mark_score: float = -_max_shot_threat(
				c, opp_positions, our_net, our_goalie_pos,
				our_team_excluding_self) + AIRoleHelpers.incumbent_bonus(ctx, c)
		if mark_score > best_score:
			best_score = mark_score
			best_pos = c

	d.target_position = best_pos
	return d


# Returns the highest threat surface any opp could extract from their current
# position with our hypothetical defender at `candidate` in the threat's
# "opponents" list. Uses threat_surface_shoot, which falls back to
# position_potential when score_shoot returns 0 — gives the fallback a non-zero
# gradient across opp positions even when no opp is in immediate shooting range,
# so an unassigned marker pulls into the dominant opp's pressure cone instead of
# sitting flat at slot.
static func _max_shot_threat(
		candidate: Vector3,
		opp_positions: Array[Vector3],
		our_net: Vector3,
		our_goalie_pos: Vector3,
		our_team_excluding_self: Array[Vector3]) -> float:
	# Opp's view of defenders = our team + me at c. Append-and-restore the
	# caller's array in place instead of duplicating it per candidate (10×/decide
	# in the unassigned-marker fallback); the array is left exactly as passed and
	# keeps its capacity across the push/pop, so steady-state calls don't alloc.
	our_team_excluding_self.push_back(candidate)

	var max_threat: float = 0.0
	for opp_pos: Vector3 in opp_positions:
		var threat: float = AIActionScoring.threat_surface_shoot(
				opp_pos, our_net, our_goalie_pos,
				GameRules.NET_HALF_WIDTH, our_team_excluding_self)
		if threat > max_threat:
			max_threat = threat
	our_team_excluding_self.pop_back()
	return max_threat
