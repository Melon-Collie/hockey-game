class_name AIRoleChase

# CHASE role behavior — NEUTRAL only. The closest peer to a loose
# puck. Job: race to the puck for retrieval — WHEN the race is alive.
#
# The bot's state machine transitions to CHASE_PUCK once they're
# closest to a loose puck, taking over actual retrieval (lead-intercept
# math, blade gate, contest drive-through). This role provides the
# "where to be" hint while the brain re-tick is pending.
#
# Racing is NOT the right answer regardless of game state: when an
# opponent reaches the puck a clear contest-band ahead (the shared
# lost-race read), pushing after it just skates the chaser out of the
# play while the counter develops — the missed-pass "third man keeps
# pushing" failure. A lost race retreats to the PRE-CONTAIN point
# instead: the gap position between the imminent pickup and our net
# (CONTAIN's own geometry), so when the opponent collects and the
# possession state flips to TRANS_OD, the gap defender is already
# standing where CONTAIN wants him.

static func decide(ctx: RoleContext) -> RoleDecision:
	var d := RoleDecision.new()
	if ctx.snapshot == null or ctx.snapshot.puck_state == null:
		d.target_position = ctx.self_pos
		return d
	var puck_pos: Vector3 = ctx.snapshot.puck_state.position
	if AIRoleHelpers.loose_puck_race_lost(
			ctx.snapshot, ctx.self_pos, ctx.self_velocity, ctx.self_max_speed,
			ctx.team_id, ctx.team_id_by_peer, ctx.caps_by_peer):
		# Pre-contain the collector: CONTAIN's gap formula on the pickup spot.
		var our_net: Vector3 = ctx.defending_goal_pos
		var to_net: Vector3 = our_net - puck_pos
		var dist: float = to_net.length()
		if dist > 0.001:
			var gap: float = clampf(dist * AIRoleContain.GAP_FRACTION,
					AIRoleContain.GAP_MIN_M, AIRoleContain.GAP_MAX_M)
			d.target_position = puck_pos + (to_net / dist) * minf(gap, dist)
			return d
	d.target_position = puck_pos
	return d
