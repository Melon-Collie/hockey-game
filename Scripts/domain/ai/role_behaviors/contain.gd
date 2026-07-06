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
	# Never project past the net — a gap wider than the carrier's own distance
	# to the net would place the target behind the goal line.
	gap = minf(gap, dist)
	d.target_position = carrier_pos + (to_net / dist) * gap
	return d
