class_name AIRoleContain

# CONTAIN role behavior — TRANS_OD only. The last man back: gap control on
# the puck carrier as a rush develops toward our net.
#
# CONTAIN is assigned to the DEEPEST defender (closest to our net). Its one job
# is to stay between the carrier and our net at a CONTROLLED GAP — close enough
# to challenge, far enough not to get beaten wide — and let the rush come to it,
# rather than lunging up-ice at the carrier (the old "engage forward" behavior,
# which took bad angles and gave up breakaways). The two BACKCHECK peers sprint
# home to cover the carrier's receivers; CONTAIN owns the carrier.
#
# Geometry: target = a point on the carrier→our-net line, goal-side of the
# carrier, at a gap that TIGHTENS as the carrier nears the net:
#
#     gap = clamp(carrier_dist_to_net × GAP_FRACTION, GAP_MIN_M, GAP_MAX_M)
#     target = carrier + (our_net - carrier).normalized() × gap
#
# Far out (rush at the blue line) the gap is loose — CONTAIN stands off and
# skates backward, mirroring the carrier without committing. Near the net the
# gap collapses to a stick's length — CONTAIN is right on the carrier at the
# doorstep. Because the target is always goal-side of the carrier and a fixed
# distance IN FRONT of the net, CONTAIN never retreats behind its own goal line
# (the old BACKCHECK failure) and never lunges past the carrier (the old
# CONTAIN failure). Sprint-home to re-establish the gap is emergent from the
# state machine's _resolve_sprint on this target.
#
# Falls back to the loose-puck spot when no skater carries the puck (so it keeps
# containing the developing play), and to self_pos only when there's no puck.

# Gap as a fraction of the carrier's distance to our net, then clamped. The
# fraction gives the "tighten as they close" ramp; the clamps bound it to a
# real challenge distance at both extremes.
const GAP_FRACTION: float = 0.3
const GAP_MIN_M: float = 1.6
const GAP_MAX_M: float = 6.0

# Where CONTAIN plants for the line stand: this far inside OUR blue line, so
# the carrier meets a set defender exactly at the entry moment. One stride of
# depth — enough to pivot with a wide cut, not so much that the line is
# conceded before contact.
const LINE_STAND_INSIDE_M: float = 1.0


static func decide(ctx: RoleContext) -> RoleDecision:
	var d := RoleDecision.new()

	var carrier_pos: Vector3 = AIRoleHelpers.resolve_defensive_play_ref(ctx)
	if not carrier_pos.is_finite():
		d.target_position = ctx.self_pos
		return d

	# Lead the carrier the same clamped half-step the backline leads its
	# men (lead_threat) — the gap point is defined off where the rush is
	# GOING, not the freeze-frame. Without this, a carrier cutting
	# laterally had CONTAIN back-pedalling along a stale carrier→net line
	# and re-correcting every tick. Velocity-based, so it shrinks to
	# nothing the moment the carrier slows — no phantom to overshoot.
	carrier_pos = AIRoleHelpers.lead_threat(
			carrier_pos, AIRoleHelpers.resolve_play_ref_velocity(ctx),
			ctx.defensive_anticipation_scale)

	var our_net: Vector3 = ctx.defending_goal_pos
	var to_net: Vector3 = our_net - carrier_pos
	var dist: float = to_net.length()
	if dist < 0.001:
		# Carrier sitting on our goal line — just hold the doorstep.
		d.target_position = carrier_pos
		return d

	var gap: float = clampf(dist * GAP_FRACTION, GAP_MIN_M, GAP_MAX_M)
	# STAND UP AT THE BLUE LINE. The raw distance-fraction gap concedes the
	# entry by construction: at the moment the carrier reaches our blue line the
	# gap is ~maxed, so CONTAIN is six metres behind the line retreating at the
	# carrier's pace and the zone is gained untouched every rush. The line is
	# where the defence makes its stand — entry-with-possession is the thing to
	# deny — so while the carrier is still OUTSIDE our zone, the gap is capped
	# by the ice remaining to the line (+ the plant depth): the gap-surf lands
	# CONTAIN set one stride inside the line exactly as the carrier arrives.
	# Once the zone is gained the cap vanishes and the normal protect-the-net
	# ramp resumes. The MARK pair is home behind, so losing the stand wide is
	# the acceptable outcome — the free entry was not.
	var ice_to_line: float = GameRules.BLUE_LINE_Z - ctx.own_goal_dir * carrier_pos.z
	if ice_to_line > 0.0:
		gap = maxf(minf(gap, ice_to_line + LINE_STAND_INSIDE_M), GAP_MIN_M)
	# Never project past the net — a gap wider than the carrier's own distance
	# to the net would place the target behind the goal line.
	gap = minf(gap, dist)
	# NEVER ADVANCE PAST RECOVERY. The gap point is carrier-relative, so a
	# carrier still deep in his own end pulls it far up-ice — and a center-ice
	# CONTAIN would skate FORWARD 15 m to "establish the gap" on a rush that
	# hasn't come yet, vacating the middle while a trailer makes it a 2-on-1
	# behind him (the forecheck-F3 bug's TRANS_OD twin). Gap control means the
	# rush comes to YOU: the stand's distance from our net is capped by the
	# race-home radius against the OTHER opponents — the CARRIER is excluded
	# because gap control already owns him (you cannot be beaten home by the
	# man you retreat in front of; the trailer is who burns you). Each trailer
	# races at ITS real Speed cap — states and caps are filled together so the
	# parallel arrays stay index-aligned (a hand-filled state list over a stale
	# caps buffer used to size-mismatch and silently demote every trailer to
	# league-reference speed, so a plodding trailer forced a deep sag and a
	# burner was under-feared).
	var stand_from_net: float = dist - gap
	var opp_states: Array[SkaterNetworkState] = ctx.scratch_opp_states
	var opp_caps: Array[AISkaterCaps] = ctx.scratch_opp_caps
	opp_states.clear()
	opp_caps.clear()
	var carrier_pid: int = ctx.snapshot.puck_state.carrier_peer_id 			if ctx.snapshot.puck_state != null else -1
	for pid: int in ctx.snapshot.skater_states:
		if ctx.team_id_by_peer.get(pid, -1) == ctx.team_id or pid == carrier_pid:
			continue
		opp_states.append(ctx.snapshot.skater_states[pid])
		opp_caps.append(ctx.caps_by_peer.get(pid))
	var r: float = AIRoleHelpers.race_home_radius(ctx, opp_states, our_net)
	if stand_from_net > r:
		gap = dist - r
	d.target_position = carrier_pos + (to_net / dist) * gap
	return d
