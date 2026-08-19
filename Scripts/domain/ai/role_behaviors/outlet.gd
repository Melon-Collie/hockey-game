class_name AIRoleOutlet

# OUTLET role behavior — TRANS_OFFENSE only. The stretch-pass option waiting
# NZ-side of the opp blue line. Same candidate-set argmax as AIRoleSupport minus
# the exposure half: OUTLET is intentionally up-ice and accepts being past the
# play, and defensive responsibility falls to SUPPORT.
#
# Argmax over `max(lane_clear(carrier → c), BLOCKED_LANE_FLOOR) ×
# position_potential(c)` — the same primitive pair the BREAKOUT outlets use, and
# for the same reason. Every legal OUTLET candidate is far enough from the opp
# goal that score_shoot foreshortens to ~0, so a score_pass argmax reads ~0 for
# EVERY candidate and degenerates to "first in the list", blind to a defender
# standing on the stretch spot or in the feed lane. lane × potential keeps a live
# gradient out here: reachable-by-the-carrier gates the spot, open-ice / up-ice
# value ranks it.
#
# The search center is derived from in-game references — the opp blue line on Z,
# the mirrored puck X on X — and an offside filter rejects any sample that drifts
# past the line into the OZ, where the bot would ghost until tag-up.

# Margin from the opp blue line that the search center sits on the
# NZ side. Sampling parameter — keeps most polar samples in legal
# territory; the offside filter is the actual game-rule guard.
const BLUE_LINE_BUFFER_M: float = 2.5

# Inset from the rink boards when mirroring puck X to weak side.
# Geometric — keeps OUTLET off the boards so polar samples don't
# all clamp against the wall.
const WEAK_SIDE_INSET_M: float = 2.0

# Floor on the lane term so dead pass lanes rank candidates instead of erasing
# them — a stretch pass is long enough that one defender's closing reach can
# blanket the whole candidate ring, and without the floor the argmax loses all
# signal exactly when positioning matters most. Mirrors
# AIRoleBreakout.BLOCKED_LANE_FLOOR; each role module stays self-contained.
const BLOCKED_LANE_FLOOR: float = 0.15

# ── In-stride rush entry ─────────────────────────────────────────────────────
# On a rush the staging depth is PACED to the carrier — a fixed lead ahead of his
# depth, capped at the line — so the OUTLET reaches the line as he crosses,
# moving. Driving to the line and parking there leaves the second attacker
# standing still, accelerating from zero exactly when the entry happens. The
# depth blends from the line (set play / stretch option) to the paced spot (full
# rush) by the carrier's closing speed, and arrive_at_speed makes the state
# machine treat the advancing target as a waypoint rather than a station. The
# offside filter and the body-level offside brake still keep it onside.

# Carrier closing-speed band (m/s, toward the opp net) mapping to the rush
# blend. Below LO reads as a set play (stretch option at the line); at/above
# HI as a full rush (pace the carrier). Matches AIRoleFinisher's band so the
# two offensive roles read the same rush the same way.
const RUSH_SPEED_LO_M_S: float = 2.5
const RUSH_SPEED_HI_M_S: float = 6.5

# How far ahead of the carrier's depth (toward the opp net) the OUTLET stages
# on a rush — enough to be the advanced entry option without stretching so far
# it parks at the line. Capped so the staging never crosses to the OZ side of
# the line (offside).
const RUSH_ENTRY_LEAD_M: float = 4.0

# Rush blend above which the OUTLET arrives at speed (skips the arrival brake)
# AND the pace cap engages. Below it the OUTLET is a set-play stretch option:
# it holds the line and brakes to a stop, exactly as before.
const ARRIVE_AT_SPEED_RUSH: float = 0.25

# Pace cap slack (m). On a rush, candidates more than this far net-ward of the
# paced depth are rejected — position_potential's pull toward the net would
# otherwise stretch the OUTLET straight up to the line to park, defeating the
# pacing. The small slack lets it take an open lane a touch ahead of the pace
# without running away from the carrier.
const PACE_TOLERANCE_M: float = 1.0


static func decide(ctx: RoleContext) -> RoleDecision:
	var d := RoleDecision.new()

	# No live teammate carrier (loose puck / pass in flight) — the read orients off
	# the puck, so OUTLET keeps presenting the stretch option. Stand still only
	# when there is no puck at all.
	var carrier_pos: Vector3 = AIRoleHelpers.resolve_offensive_play_ref(ctx)
	if not carrier_pos.is_finite():
		d.target_position = ctx.self_pos
		return d

	var opp_positions: Array[Vector3] = ctx.scratch_opp_positions
	var opp_states: Array[SkaterNetworkState] = ctx.scratch_opp_states
	AIRoleHelpers.collect_opponents(ctx, opp_positions, opp_states)

	var teammate_positions: Array[Vector3] = ctx.scratch_teammates
	AIRoleHelpers.collect_teammates_excluding_self(ctx, teammate_positions)

	# How hard our carrier is driving the net: paces the staging depth and gates
	# arriving at speed.
	var rush: float = clampf(
			(AIRoleHelpers.carrier_closing_speed(ctx) - RUSH_SPEED_LO_M_S)
					/ (RUSH_SPEED_HI_M_S - RUSH_SPEED_LO_M_S),
			0.0, 1.0)
	var rushing: bool = rush > ARRIVE_AT_SPEED_RUSH
	d.arrive_at_speed = rushing

	# The "don't advance past here yet" line — both the search-center Z and, on a
	# rush, a hard pace cap in the loop below.
	var paced_z: float = _paced_depth_z(ctx, carrier_pos, rush)
	# Weak side comes from the brain's HYSTERETIC strong side, never a raw mirror
	# of the carrier's live x. The magnitude still mirrors how wide he is, but the
	# SIDE holds through a carrier wheeling across centre: a raw -carrier.x flips
	# the stretch spot the instant the puck crosses the middle, which sends this
	# bot cutting across the SUPPORT trailer's path. strong_x is the side the
	# BREAKOUT outlets and SUPPORT already use, so the whole rotation agrees.
	var weak_x: float = clampf(-ctx.strong_x * absf(carrier_pos.x),
			-GameRules.RINK_HALF_WIDTH + WEAK_SIDE_INSET_M,
			GameRules.RINK_HALF_WIDTH - WEAK_SIDE_INSET_M)
	var search_center := Vector3(weak_x, 0.0, paced_z)
	var candidates: Array[Vector3] = AIRoleHelpers.generate_candidates_around(
			ctx.self_pos, search_center)
	# Switch-hysteresis: hold the stretch spot unless a fresh one is clearly
	# better, so the cursor (which snaps to this target) stays steady.
	AIRoleHelpers.append_incumbent(ctx, candidates)

	var best_pos: Vector3 = ctx.self_pos
	var best_score: float = -INF
	for c: Vector3 in candidates:
		if not AIRoleHelpers.is_legal_position(c):
			continue
		if _is_offside(c, ctx):
			continue
		# Pace cap (rush only): reject candidates net-ward of the paced depth
		# so the OUTLET stays level with the carrier's rush instead of being
		# dragged up to park at the line. own_goal_dir * z is SMALLER on the
		# net-ward (OZ) side, so "too far net-ward" is a strict-less-than.
		if rushing and ctx.own_goal_dir * c.z \
				< ctx.own_goal_dir * paced_z - PACE_TOLERANCE_M:
			continue
		if AIRoleHelpers.too_close_to_teammate(c, teammate_positions):
			continue
		# The speed our carrier would actually fire at. Outlet candidates are the
		# long-pass receivers by definition, so the charged-pass lane math matters
		# more here than anywhere.
		var pass_speed: float = AIActionScoring.expected_pass_speed(carrier_pos, c)
		var lane: float = AIActionScoring.lane_clear(
				carrier_pos, c, opp_positions, pass_speed,
				AIActionScoring.EMPTY_VEC3, ctx.scratch_opp_caps)
		var potential: float = AIActionScoring.position_potential(
				c, ctx.attacking_goal_pos, opp_positions, ctx.scratch_opp_caps)
		var score: float = maxf(lane, BLOCKED_LANE_FLOOR) * potential \
				+ AIRoleHelpers.incumbent_bonus(ctx, c)
		if score > best_score:
			best_score = score
			best_pos = c

	d.target_position = best_pos
	return d


# Paced staging depth (Z) for the OUTLET, blending line -> lead-the-carrier
# by `rush`:
#   set play (rush 0)  → BLUE_LINE_BUFFER_M NZ-side of the opp blue line
#                        (the stretch option waits at the line).
#   full rush (rush 1) → RUSH_ENTRY_LEAD_M ahead of the carrier's depth
#                        (toward the opp net), so the OUTLET paces the rush.
# The lead spot is capped NZ-side of the line (own_goal_dir * z is smaller on
# the OZ side) so it never stages offside; the lerp keeps the transition
# continuous as the carrier winds up.
static func _paced_depth_z(ctx: RoleContext, carrier_pos: Vector3,
		rush: float) -> float:
	var line_z: float = -ctx.own_goal_dir * (GameRules.BLUE_LINE_Z - BLUE_LINE_BUFFER_M)
	var lead_z: float = carrier_pos.z - ctx.own_goal_dir * RUSH_ENTRY_LEAD_M
	if ctx.own_goal_dir * lead_z < ctx.own_goal_dir * line_z:
		lead_z = line_z
	return lerpf(line_z, lead_z, rush)


# Offside filter: in TRANS_OFFENSE the puck is NZ-side of the opp blue line by
# definition, so a candidate past that line would put OUTLET in the OZ and ghost
# it.
#
# Velocity-corrected — a candidate is "effectively offside" when the bot's
# projected position one SKATER_BRAKE_TIME_S out is already past the line, so a
# bot flying at the opp net needs more buffer while one at rest can sit right on
# it. Pure kinematics, no behavioral knob.
static func _is_offside(c: Vector3, ctx: RoleContext) -> bool:
	var opp_blue_z: float = -ctx.own_goal_dir * GameRules.BLUE_LINE_Z
	var future_z: float = c.z + ctx.self_velocity.z * AIActionScoring.SKATER_BRAKE_TIME_S
	return -ctx.own_goal_dir * future_z > -ctx.own_goal_dir * opp_blue_z
