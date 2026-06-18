class_name AIRoleFinisher

# FINISHER role behavior (OZONE — `AIRoleSlots.Slot.FINISHER`).
# Two-mode decision:
#
#   1. REACTIVE: an incoming shot is detected (puck heading at our
#      offensive goal at speed) — the off-puck deflection routine.
#      Always TIP: move onto the puck path and point the blade at net
#      for the redirect (works for on- and off-target shots). When the
#      incoming shot is ELEVATED, also raise the blade (lift_blade) so
#      it can reach the airborne puck — a grounded stick flies under it.
#      Reactive overrides positioning when active.
#
#   2. POSITIONING: no incoming shot. FINISHER cares about exactly
#      two things — being open for a shot, being open for a pass.
#      score_pass(carrier, candidate) bundles both:
#
#         path_clearance(carrier, candidate)   ← open for a pass
#       × score_shoot(candidate, ...)          ← open for a shot
#       × time_decay(flight_time)              ← ~1 for in-OZ passes
#
#      For near-net FINISHER candidates the shot-quality term
#      (score_shoot) dominates the gradient — small differences in
#      angle to net, goalie position, and forward-cone pressure
#      drive the argmax toward whichever spot has the cleanest open
#      look. Pass-lane openness gates which of those spots are
#      actually reachable from the current carrier position.
#
#      No exposure factor — FINISHER is committed to crashing the
#      net by role definition. Defensive recovery is SUPPORT's job.
#
# Stateless. Reactive logic is unchanged from the original
# `_backdoor_decision`; positioning is new in Phase 4c.

# Speed gate: pucks slower than this are passes / rolling, not shots.
const INCOMING_SHOT_SPEED_M_S: float = 12.0

# How far in front of the opp goal the positioning search center
# sits. Sourced from GameRules.SLOT_DIST_M — the faceoff-hash slot,
# the prime scoring area. Keeps every polar sample (radius
# SEARCH_STEP_M = 3) on the legal side of the goal line
# (GOAL_LINE_BUFFER_M = 1).


static func decide(ctx: RoleContext) -> RoleDecision:
	# Reactive mode wins when a shot is incoming. _try_reactive
	# returns null when no shot threat is detected; we then run
	# positioning.
	var reactive: RoleDecision = _try_reactive_decision(ctx)
	if reactive != null:
		return reactive
	return _positioning_decision(ctx)


# ── Reactive (incoming shot) ─────────────────────────────────────────────────

# Returns a TIP or STEP_OUT decision when an incoming shot is
# detected; null when no shot threat (caller falls through to
# positioning). All gates produce null on miss so positioning
# takes over instead of holding at the anchor.
static func _try_reactive_decision(ctx: RoleContext) -> RoleDecision:
	var puck_state: PuckNetworkState = ctx.snapshot.puck_state
	if puck_state == null:
		return null

	var puck_pos: Vector3 = puck_state.position
	var puck_vel: Vector3 = puck_state.velocity
	var puck_speed: float = sqrt(puck_vel.x * puck_vel.x + puck_vel.z * puck_vel.z)

	# Speed gate: too slow → pass / rolling, not a shot.
	if puck_speed < INCOMING_SHOT_SPEED_M_S:
		return null

	# Direction gate: must be heading at our offensive goal.
	var opp_goal_z: float = -ctx.own_goal_dir * GameRules.GOAL_LINE_Z
	var to_goal_z: float = opp_goal_z - puck_pos.z
	if puck_vel.z * to_goal_z <= 0.0:
		return null

	# Predict where puck path crosses our z plane (lateral anchor pos).
	if absf(puck_vel.z) < 0.001:
		return null
	var t_to_my_z: float = (ctx.self_pos.z - puck_pos.z) / puck_vel.z
	if t_to_my_z <= 0.0 or t_to_my_z > 2.0:
		return null
	var path_x_at_my_z: float = puck_pos.x + puck_vel.x * t_to_my_z

	# TIP. Shift target onto the puck path at our current z plane, aim
	# mouse at goal so the blade angles toward net for a deflection /
	# redirect. Works for both on-target shots (steers the puck through a
	# different angle past the goalie) and off-target shots (redirects
	# toward net).
	#
	# Reactive references the FINISHER's CURRENT position (self_pos)
	# rather than a static anchor — under the no-anchors refactor
	# FINISHER roams, so reactive responses are anchored to where
	# the bot actually is when the puck arrives.
	var d := RoleDecision.new()
	d.target_position = Vector3(path_x_at_my_z, 0.0, ctx.self_pos.z)
	d.aim_world_pos = Vector3(0.0, 0.0, opp_goal_z)
	d.has_aim_override = true
	# Elevated check: read the most-recent shooter's `is_elevated` flag
	# directly from their network state (cleaner than projecting puck y
	# velocity through gravity math). Closest teammate to the puck is the
	# proxy for "shooter" since once the puck is in flight there's no
	# carrier — but the bot that just released is typically still nearest.
	# When the incoming on-net puck is airborne, raise the blade so we can
	# actually tip it — a grounded blade flies under an elevated puck.
	if _last_shooter_is_elevated(ctx):
		d.lift_blade = true
	return d


# Returns the is_elevated flag of the most recent likely shooter on
# our team. Used to detect elevated shots without doing gravity math
# on the puck. We pick the closest teammate to the puck as the proxy
# — once the puck is in flight there's no carrier, but the bot that
# just released is typically still nearby.
static func _last_shooter_is_elevated(ctx: RoleContext) -> bool:
	if ctx.snapshot.puck_state == null:
		return false
	var puck_pos: Vector3 = ctx.snapshot.puck_state.position
	var best_pid: int = 0
	var best_d2: float = INF
	for pid: int in ctx.snapshot.skater_states:
		if ctx.team_id_by_peer.get(pid, -1) != ctx.team_id:
			continue
		var pos: Vector3 = ctx.snapshot.skater_states[pid].position
		var dx: float = pos.x - puck_pos.x
		var dz: float = pos.z - puck_pos.z
		var d2: float = dx * dx + dz * dz
		if d2 < best_d2:
			best_d2 = d2
			best_pid = pid
	if best_pid == 0:
		return false
	return ctx.snapshot.skater_states[best_pid].is_elevated


# ── Positioning (no incoming shot) ──────────────────────────────────────────

# Argmax over the candidate set scored with score_pass(carrier,
# candidate). Search center sits SLOT_DIST_M in front of
# the opp goal at center ice — the slot. Polar samples around this
# center cover the high-slot, low-slot, and weak/strong-side post
# regions. Falls back to self_pos when no teammate carrier (brain
# re-tick will re-route this peer within a frame).
static func _positioning_decision(ctx: RoleContext) -> RoleDecision:
	var d := RoleDecision.new()

	var carrier_pos: Vector3 = AIRoleHelpers.resolve_teammate_carrier_pos(ctx)
	if not carrier_pos.is_finite():
		d.target_position = ctx.self_pos
		return d

	var goalie_pos: Vector3 = AIRoleHelpers.resolve_opp_goalie_pos(ctx)

	var opp_positions: Array[Vector3] = []
	var opp_states: Array[SkaterNetworkState] = []
	AIRoleHelpers.collect_opponents(ctx, opp_positions, opp_states)

	var teammate_positions: Array[Vector3] = AIRoleHelpers.collect_teammates_excluding_self(ctx)

	# Search center: the slot, SLOT_DIST_M in front of opp goal at
	# center ice. Pure in-game ref (opp net + slot depth).
	var search_center := Vector3(
			0.0,
			0.0,
			ctx.attacking_goal_pos.z + ctx.own_goal_dir * GameRules.SLOT_DIST_M)
	var candidates: Array[Vector3] = AIRoleHelpers.generate_candidates_around(
			ctx.self_pos, search_center)

	var best_pos: Vector3 = ctx.self_pos
	var best_score: float = -INF
	for c: Vector3 in candidates:
		if not AIRoleHelpers.is_legal_position(c):
			continue
		if AIRoleHelpers.too_close_to_teammate(c, teammate_positions):
			continue
		# Match the speed our carrier would actually fire at — long
		# passes get the charged-wrister speed, short ones the quick-
		# shot speed. Without this the lane-clear math assumes 14 m/s
		# universally and a 12 m feed scores as if defenders had 36%
		# more reaction time than they actually do.
		var pass_speed: float = AIActionScoring.expected_pass_speed(carrier_pos, c)
		var score: float = AIActionScoring.score_pass(
				carrier_pos, c, ctx.attacking_goal_pos,
				goalie_pos, GameRules.NET_HALF_WIDTH,
				opp_positions, Vector3.INF, pass_speed)
		if score > best_score:
			best_score = score
			best_pos = c

	d.target_position = best_pos
	# One-timer ready: positioning argmax already encoded "this is a
	# high-value pass-and-shoot spot via score_pass." Once we've
	# arrived at it, signal ready. No separate quality gate — if the
	# spot is weak, score_pass(carrier, here) is low and the carrier
	# won't pass, so the ready flag never gets consumed.
	#
	# Arrival tolerance = half a polar search step. The candidates
	# are spaced SEARCH_STEP_M apart, so within half a step the bot
	# is closer to the chosen anchor than to any neighbor candidate;
	# they've effectively reached the spot.
	if ctx.self_pos.distance_to(best_pos) < AIRoleHelpers.SEARCH_STEP_M * 0.5:
		d.is_one_timer_ready = true
	return d
