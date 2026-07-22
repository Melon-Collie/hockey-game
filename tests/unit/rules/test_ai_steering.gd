extends GutTest

# AISteering is a pure function — these tests cover anchor pull, the
# four repel forces (teammate, opponent, board, shot-lane), and the
# unit-magnitude clamp.

const RINK_X: float = 13.0
const RINK_Z: float = 30.0
const NO_OPS: Array[Vector3] = []
const NO_LANE := Vector3.ZERO


func _move(self_pos: Vector3, anchor: Vector3,
		teammates: Array[Vector3] = NO_OPS,
		opponents: Array[Vector3] = NO_OPS,
		lane_a: Vector3 = NO_LANE,
		lane_b: Vector3 = NO_LANE) -> Vector2:
	return AISteering.compute_move_vector(
			self_pos, anchor, teammates, opponents, lane_a, lane_b, RINK_X, RINK_Z)


func test_no_movement_when_at_anchor() -> void:
	var pos := Vector3(0, 0, 0)
	var v := _move(pos, pos)
	assert_almost_eq(v.length(), 0.0, 0.01, "no force when self is on the anchor")


func test_attracts_toward_anchor_along_z() -> void:
	var pos := Vector3(0, 0, 0)
	var anchor := Vector3(0, 0, 5)
	var v := _move(pos, anchor)
	assert_almost_eq(v.x, 0.0, 0.05)
	assert_gt(v.y, 0.5, "Vector2.y maps to world Z; should be positive toward anchor")


func test_teammate_repel_pushes_away() -> void:
	var pos := Vector3(0, 0, 0)
	var anchor := Vector3(0, 0, 5)
	var teammate_at_anchor: Array[Vector3] = [Vector3(0, 0, 1)]  # blocking the path
	var v_solo := _move(pos, anchor)
	var v_blocked := _move(pos, anchor, teammate_at_anchor)
	assert_lt(v_blocked.y, v_solo.y, "teammate ahead should reduce the +Z pull")


func test_opponent_repel_stronger_than_teammate() -> void:
	# Opponent repel weight 0.6 vs teammate 0.55 — same configuration
	# should push the bot back harder when the obstacle is an opponent.
	var pos := Vector3(0, 0, 0)
	var anchor := Vector3(0, 0, 5)
	var teammate_block: Array[Vector3] = [Vector3(0, 0, 1)]
	var opponent_block: Array[Vector3] = [Vector3(0, 0, 1)]
	var v_team := _move(pos, anchor, teammate_block)
	var v_opp := _move(pos, anchor, NO_OPS, opponent_block)
	assert_lt(v_opp.y, v_team.y, "opponent repel should push back harder than teammate at the same distance")


func test_board_repel_pushes_inward_at_x_wall() -> void:
	var pos := Vector3(RINK_X - 0.5, 0, 0)  # very close to +X board
	var anchor := Vector3(RINK_X - 0.5, 0, 0)
	var v := _move(pos, anchor)
	assert_lt(v.x, 0.0, "should be pushed toward -X (inward)")


func test_shot_lane_repel_pushes_perpendicular() -> void:
	# Lane along +Z from (0,0,0) to (0,0,10). Bot 1 m off the lane to +X
	# should be pushed away from the lane (toward more +X).
	var pos := Vector3(1.0, 0.0, 5.0)  # mid-lane, 1m off in +X
	var anchor := Vector3(1.0, 0.0, 5.0)  # anchor at self → no pull
	var lane_a := Vector3(0, 0, 0)
	var lane_b := Vector3(0, 0, 10)
	var v := _move(pos, anchor, NO_OPS, NO_OPS, lane_a, lane_b)
	assert_gt(v.x, 0.0, "perpendicular force should push away from the lane")


func test_output_magnitude_clamped_to_unit() -> void:
	var pos := Vector3(RINK_X - 0.1, 0, RINK_Z - 0.1)  # corner; many forces stack
	var anchor := Vector3(0, 0, 0)
	var v := _move(pos, anchor)
	assert_lte(v.length(), 1.0001, "move_vector must not exceed unit length")


func test_crease_repel_pushes_outward_inside_arc() -> void:
	# Bot inside the +Z crease, slightly off-center toward +X. Should be
	# pushed outward (–Z back toward center ice, +X is fine — it's already
	# off-axis but the dominant push is away from the goal center).
	var crease_pos := Vector3(0.5, 0, GameRules.GOAL_LINE_Z - 0.5)
	var anchor := crease_pos  # anchor at self → no attract pull
	var v := _move(crease_pos, anchor)
	assert_lt(v.y, 0.0, "should be pushed in -Z away from +Z goal")


func test_no_crease_force_at_center_ice() -> void:
	# Origin straddles the half-space split (signf(0)=0). No crease force.
	var v := _move(Vector3.ZERO, Vector3(0, 0, 5))
	# v should match the no-crease behavior — the +Z anchor pulls along +y.
	assert_gt(v.y, 0.5, "no crease repel at center ice; only anchor pull remains")


func test_no_crease_force_at_neutral_zone() -> void:
	# Bot in the neutral zone (z=0). No crease force.
	var pos := Vector3(2.0, 0, 0.0)
	var v := _move(pos, pos)  # anchor at self
	assert_almost_eq(v.length(), 0.0, 0.01, "no force at neutral zone")


func test_ignores_teammates_outside_repel_radius() -> void:
	var pos := Vector3(0, 0, 0)
	var anchor := Vector3(0, 0, 5)
	var far_teammate: Array[Vector3] = [Vector3(0, 0, 1.0 + AISteering.TEAMMATE_REPEL_RADIUS + 0.1)]
	var v_with := _move(pos, anchor, far_teammate)
	var v_solo := _move(pos, anchor)
	assert_almost_eq(v_with.x, v_solo.x, 0.001)
	assert_almost_eq(v_with.y, v_solo.y, 0.001)


# ── Carrier threat-gated repel (velocities supplied) ─────────────────────────
# With opponent velocities the carrier's avoidance reads defender MOMENTUM and
# routes AROUND: a defender who can't get his swept reach on the carrier exerts
# nothing, a threatening one bends the carry line but never reverses it, and a
# charger sweeping through the carrier's spot produces a perpendicular sidestep.

func _carrier_move(self_pos: Vector3, anchor: Vector3,
		opponents: Array[Vector3], opp_vels: Array[Vector3]) -> Vector2:
	return AISteering.compute_move_vector(
			self_pos, anchor, NO_OPS, opponents, NO_LANE, NO_LANE, RINK_X, RINK_Z,
			AISteering.OPPONENT_REPEL_WEIGHT_CARRY, opp_vels)


func test_carrier_not_pushed_backwards_by_defender_on_the_line() -> void:
	# Stationary defender parked dead on the carry line: his push is pure
	# anti-anchor, which the route-around shaping strips — the carrier keeps
	# driving at its spot (the deke layer owns beating him) instead of being
	# corralled backwards. The plain proximity field (no velocities) shows the
	# old herding for contrast.
	var anchor := Vector3(0, 0, 8)
	var opps: Array[Vector3] = [Vector3(0, 0, 3)]
	var vels: Array[Vector3] = [Vector3.ZERO]
	var gated := _carrier_move(Vector3.ZERO, anchor, opps, vels)
	var old := AISteering.compute_move_vector(
			Vector3.ZERO, anchor, NO_OPS, opps, NO_LANE, NO_LANE, RINK_X, RINK_Z,
			AISteering.OPPONENT_REPEL_WEIGHT_CARRY)
	assert_gt(gated.y, 0.95, "full drive at the anchor — pressure never reverses the line")
	assert_lt(old.y, gated.y - 0.2, "the proximity field was pushed off the line (the corral)")


func test_carrier_ignores_defender_outside_swept_reach() -> void:
	# A defender well outside his momentum-reach (stationary, ~3.6 m off) is no
	# threat to the puck this horizon — zero repel, pure anchor pull.
	var anchor := Vector3(0, 0, 8)
	var opps: Array[Vector3] = [Vector3(3.6, 0, 0)]
	var vels: Array[Vector3] = [Vector3.ZERO]
	var v := _carrier_move(Vector3.ZERO, anchor, opps, vels)
	assert_almost_eq(v.x, 0.0, 0.01, "out of reach → no repel at all")
	assert_gt(v.y, 0.95, "pure anchor pull remains")


func test_carrier_sidesteps_a_charger_sweeping_through() -> void:
	# A committed charger whose sweep passes straight through the carrier's
	# spot: the puck-level seam handles the puck, but the BODY still needs to
	# move — perpendicular off his line (the matador), while the anchor pull
	# keeps the carrier advancing.
	var anchor := Vector3(0, 0, 8)
	var opps: Array[Vector3] = [Vector3(0, 0, 2.5)]
	var vels: Array[Vector3] = [Vector3(0, 0, -8)]
	var v := _carrier_move(Vector3.ZERO, anchor, opps, vels)
	assert_gt(absf(v.x), 0.3, "sidestep perpendicular to the charge line")
	assert_gt(v.y, 0.3, "still advancing toward the anchor through the sidestep")


func test_carrier_bends_around_a_flanking_threat_without_retreating() -> void:
	# Defender ahead-left within reach of the lane: the carrier bends right
	# AROUND him while keeping its forward drive — never a net push backwards.
	var anchor := Vector3(0, 0, 8)
	var opps: Array[Vector3] = [Vector3(-0.6, 0, 2.5)]
	var vels: Array[Vector3] = [Vector3.ZERO]
	var v := _carrier_move(Vector3.ZERO, anchor, opps, vels)
	assert_gt(v.x, 0.05, "bends to the open side of the threat")
	assert_gt(v.y, 0.8, "forward drive survives the bend")


# ── Teammate swept-path repel (teammate velocities supplied) ─────────────────
# With teammate velocities the spacing field repels from each teammate's
# momentum-swept path, so bots anticipate a crossing route before the bodies
# meet. Zero velocity collapses the sweep to the body point (unchanged field).

func _move_tm_vel(self_pos: Vector3, anchor: Vector3,
		teammates: Array[Vector3], tm_vels: Array[Vector3]) -> Vector2:
	return AISteering.compute_move_vector(
			self_pos, anchor, teammates, NO_OPS, NO_LANE, NO_LANE, RINK_X, RINK_Z,
			AISteering.OPPONENT_REPEL_WEIGHT, NO_OPS, tm_vels)


func test_teammate_swept_path_anticipates_a_teammate_closing_ahead() -> void:
	# Teammate parked just OUTSIDE the point radius (no effect as a body) but
	# skating straight at us: its swept path reaches into our space, so the
	# field pushes back where the freeze-frame field felt nothing.
	var anchor := Vector3(0, 0, 5)
	var far := Vector3(0, 0, AISteering.TEAMMATE_REPEL_RADIUS + 0.5)
	var tm: Array[Vector3] = [far]
	var closing: Array[Vector3] = [Vector3(0, 0, -8)]  # sweeping toward us
	var v_point := _move_tm_vel(Vector3.ZERO, anchor, tm, [Vector3.ZERO] as Array[Vector3])
	var v_swept := _move_tm_vel(Vector3.ZERO, anchor, tm, closing)
	assert_almost_eq(v_point.y, 1.0, 0.02, "body outside the radius exerts nothing")
	assert_lt(v_swept.y, v_point.y - 0.1, "the swept path is felt and pushes back before contact")


func test_teammate_swept_path_bends_off_a_crossing_route() -> void:
	# Teammate parked outside the point radius on the +X side, cutting toward us
	# along -X: its swept path stays on the +X side, so we bend to the OPEN -X
	# side. The freeze-frame body (too far to matter) exerts nothing.
	var anchor := Vector3(0, 0, 5)
	var crosser := Vector3(5.0, 0, 0)
	var tm: Array[Vector3] = [crosser]
	var vel: Array[Vector3] = [Vector3(-8, 0, 0)]  # cutting toward -X into our space
	var v_point := _move_tm_vel(Vector3.ZERO, anchor, tm, [Vector3.ZERO] as Array[Vector3])
	var v := _move_tm_vel(Vector3.ZERO, anchor, tm, vel)
	assert_almost_eq(v_point.x, 0.0, 0.02, "the far body alone exerts nothing")
	assert_lt(v.x, -0.05, "bend to the open side, away from the teammate's crossing path")


func test_teammate_zero_velocity_matches_point_repel() -> void:
	# A stationary teammate with velocities supplied must repel exactly as the
	# plain proximity field (sweep collapses to the body point).
	var anchor := Vector3(0, 0, 5)
	var tm: Array[Vector3] = [Vector3(0, 0, 1.5)]
	var v_point := _move(Vector3.ZERO, anchor, tm)
	var v_zero := _move_tm_vel(Vector3.ZERO, anchor, tm, [Vector3.ZERO] as Array[Vector3])
	assert_almost_eq(v_zero.x, v_point.x, 0.001, "zero-velocity sweep = point repel (x)")
	assert_almost_eq(v_zero.y, v_point.y, 0.001, "zero-velocity sweep = point repel (y)")


# ── Velocity-matched seek ────────────────────────────────────────────────────
# With velocity_match_speed supplied the anchor pull cancels cross-momentum so
# the bot redirects ONTO the line to the anchor instead of pure-seeking (which
# orbits/overshoots). No deceleration ramp — carry waypoints are driven at pace.

const MATCH_SPEED: float = 9.0


func _match_move(self_pos: Vector3, anchor: Vector3, self_vel: Vector3) -> Vector2:
	return AISteering.compute_move_vector(
			self_pos, anchor, NO_OPS, NO_OPS, NO_LANE, NO_LANE, RINK_X, RINK_Z,
			AISteering.OPPONENT_REPEL_WEIGHT, NO_OPS, NO_OPS, self_vel, MATCH_SPEED)


func test_velocity_match_redirects_cross_momentum_toward_the_spot() -> void:
	# Anchor dead ahead (+Z), but the carrier is drifting hard cross-ice (+X).
	# A pure seek points straight +Z and ignores the drift; the velocity-matched
	# steer adds a -X component to CANCEL the cross-momentum and get onto the line.
	var anchor := Vector3(0, 0, 8)
	var drift := Vector3(8, 0, 0)
	var seek := _move(Vector3.ZERO, anchor)                     # pure seek
	var matched := _match_move(Vector3.ZERO, anchor, drift)     # velocity-matched
	assert_almost_eq(seek.x, 0.0, 0.02, "pure seek ignores the cross-drift")
	assert_lt(matched.x, -0.2, "velocity match steers against the drift onto the line")
	assert_gt(matched.y, 0.0, "still advancing toward the anchor")


func test_velocity_match_does_not_decelerate_into_a_near_waypoint() -> void:
	# Closing straight at a NEAR anchor (2 m) below top speed: with no slowing
	# ramp the steer keeps driving forward (waypoints are skated through), where
	# a decelerating arrival would brake into it.
	var anchor := Vector3(0, 0, 2)
	var closing := Vector3(0, 0, 6)   # toward the anchor, under MATCH_SPEED
	var matched := _match_move(Vector3.ZERO, anchor, closing)
	assert_gt(matched.y, 0.1, "drives through the waypoint — no deceleration ramp")


func test_velocity_match_matches_seek_on_a_straight_approach() -> void:
	# Velocity already pointing at the anchor below top speed: nothing to cancel,
	# so the steer is the same +Z direction a pure seek gives.
	var anchor := Vector3(0, 0, 8)
	var on_line := Vector3(0, 0, 4)   # toward the anchor, under MATCH_SPEED
	var matched := _match_move(Vector3.ZERO, anchor, on_line)
	assert_almost_eq(matched.x, 0.0, 0.02, "no lateral correction on a straight approach")
	assert_gt(matched.y, 0.5, "still driving toward the anchor")


# net detour tests — route a bot pinned behind a goal line out around
# the post. The +Z net sits at +GOAL_LINE_Z; "behind" it is z > GOAL_LINE_Z.
# A post-span bot (|x| < NET_HALF_WIDTH + margin) with an anchor on the
# rink side should be pushed laterally past the post.

func test_net_detour_pushes_lateral_when_behind_own_net() -> void:
	# Bot dead-behind the +Z net with the anchor up-ice (rink side). The
	# straight pull is -Z (through the net); the detour should add a
	# dominant lateral push so the body rounds the post.
	var pos := Vector3(0.0, 0.0, GameRules.GOAL_LINE_Z + 0.5)
	var anchor := Vector3(0.0, 0.0, 0.0)  # center ice, rink side
	var v := _move(pos, anchor)
	assert_gt(absf(v.x), absf(v.y), "lateral detour should dominate the inward pull behind the net")


func test_net_detour_picks_side_toward_anchor_at_center() -> void:
	# Dead-center behind the net, anchor offset to +X → go around the +X post.
	var pos := Vector3(0.0, 0.0, GameRules.GOAL_LINE_Z + 0.5)
	var anchor := Vector3(5.0, 0.0, 0.0)
	var v := _move(pos, anchor)
	assert_gt(v.x, 0.0, "should round the post on the side the anchor is on")


func test_net_detour_releases_when_clear_of_post() -> void:
	# Behind the line but already wide of the post (|x| past the span) →
	# no detour; the anchor pull brings the bot around normally.
	var clear_x: float = GameRules.NET_HALF_WIDTH + AISteering.NET_DETOUR_POST_MARGIN + 0.2
	var pos := Vector3(clear_x, 0.0, GameRules.GOAL_LINE_Z + 1.0)
	var anchor := Vector3(0.0, 0.0, 0.0)
	var v := _move(pos, anchor)
	# Pure anchor pull is toward (-x, -z); no lateral detour added, so the
	# x-component stays negative (toward the anchor) rather than pushed +x.
	assert_lt(v.x, 0.0, "wide of the post, the bot is pulled toward the anchor, not detoured")


func test_net_detour_noop_when_anchor_behind_line() -> void:
	# Loose-puck retrieval: bot behind the net, anchor ALSO behind the line
	# (a real destination back there) → no detour, let it go.
	var pos := Vector3(0.0, 0.0, GameRules.GOAL_LINE_Z + 0.3)
	var anchor := Vector3(2.0, 0.0, GameRules.GOAL_LINE_Z + 1.0)  # deeper behind
	var v := _move(pos, anchor)
	assert_gt(v.y, 0.0, "anchor deeper behind the net pulls +Z; no lateral override")


func test_net_detour_noop_in_front_of_line() -> void:
	# Well in front of the goal line (slot) — detour must not engage; only
	# the crease repel governs near the net front.
	var pos := Vector3(0.0, 0.0, GameRules.GOAL_LINE_Z - 3.0)
	var anchor := Vector3(0.0, 0.0, 0.0)
	var v := _move(pos, anchor)
	assert_almost_eq(v.x, 0.0, 0.05, "no lateral detour in front of the goal line")


# should_brake tests — the brake-pivot decision (real brake key) layered on
# top of the potential-field steering output. Angular hysteresis: engages
# past BRAKE_PIVOT_ANGLE_DEG, holds until BRAKE_PIVOT_RELEASE_ANGLE_DEG.

func _dir_at(angle_deg: float) -> Vector2:
	# Desired direction at angle_deg from +X (the velocity direction used below).
	return Vector2(cos(deg_to_rad(angle_deg)), sin(deg_to_rad(angle_deg)))


func test_should_brake_off_below_min_speed() -> void:
	var slow_velocity := Vector2(AISteering.BRAKE_PIVOT_MIN_SPEED - 0.5, 0.0)
	assert_false(AISteering.should_brake(Vector2(-1.0, 0.0), slow_velocity, false),
			"below min speed, never brake")
	assert_false(AISteering.should_brake(Vector2(-1.0, 0.0), slow_velocity, true),
			"speed floor also releases a held brake")


func test_should_brake_off_for_small_angle() -> void:
	assert_false(AISteering.should_brake(Vector2(1.0, 0.0), Vector2(8.0, 0.0), false),
			"aligned velocity does not trigger brake")


func test_should_brake_on_reversal() -> void:
	assert_true(AISteering.should_brake(Vector2(-1.0, 0.0), Vector2(8.0, 0.0), false),
			"180° opposition brakes")


func test_should_brake_off_at_perpendicular() -> void:
	assert_false(AISteering.should_brake(Vector2(0.0, 1.0), Vector2(8.0, 0.0), false),
			"90° is below the 120° engage threshold")


func test_should_brake_hysteresis_band() -> void:
	# 110° sits between release (100°) and engage (120°): not enough to
	# start a brake, enough to keep one held.
	var desired: Vector2 = _dir_at(110.0)
	var velocity := Vector2(8.0, 0.0)
	assert_false(AISteering.should_brake(desired, velocity, false),
			"110° does not engage a fresh brake")
	assert_true(AISteering.should_brake(desired, velocity, true),
			"110° holds an already-engaged brake")


func test_should_brake_releases_past_release_angle() -> void:
	assert_false(AISteering.should_brake(_dir_at(95.0), Vector2(8.0, 0.0), true),
			"opposition relaxed below 100° releases the brake")


func test_should_brake_off_for_zero_desired() -> void:
	assert_false(AISteering.should_brake(Vector2.ZERO, Vector2(8.0, 0.0), false),
			"no desired direction, no brake")


# offside_brake tests — body-level guard against skating across the
# attacking blue line before the puck. Team 0 (own_goal_dir = +1)
# attacks -Z, so its attacking blue line is at -BLUE_LINE_Z and "toward
# the zone" is -Z. The puck is "near side" (offside risk) while
# puck_z >= -BLUE_LINE_Z.

const TEAM0_DIR: float = 1.0   # own net +Z, attacks -Z
const TEAM1_DIR: float = -1.0  # own net -Z, attacks +Z
const NEAR_PUCK_Z: float = 0.0 # center ice — near side for both teams


func test_offside_brake_noop_for_carrier() -> void:
	# Carrier is never offside — even barreling across, no brake.
	var desired := Vector2(0.0, -1.0)
	var pos := Vector3(0.0, 0.0, -7.0)
	var vel := Vector3(0.0, 0.0, -8.0)
	var v := AISteering.offside_brake(desired, pos, vel, TEAM0_DIR, NEAR_PUCK_Z, true)
	assert_eq(v, desired, "carrier is exempt from the offside brake")


func test_offside_brake_noop_when_puck_already_across() -> void:
	# Puck already in the attacking zone (z < -BLUE_LINE_Z) → entering is
	# legal, no brake even at speed toward the line.
	var desired := Vector2(0.0, -1.0)
	var pos := Vector3(0.0, 0.0, -7.0)
	var vel := Vector3(0.0, 0.0, -8.0)
	var puck_across: float = -GameRules.BLUE_LINE_Z - 2.0
	var v := AISteering.offside_brake(desired, pos, vel, TEAM0_DIR, puck_across, false)
	assert_eq(v, desired, "no brake once the puck has entered the zone")


func test_offside_brake_noop_when_moving_away_from_line() -> void:
	# Retreating toward our own end (v toward zone <= 0) → leave the
	# steering alone so the bot can tag back / recover.
	var desired := Vector2(0.0, 1.0)
	var pos := Vector3(0.0, 0.0, -7.0)
	var vel := Vector3(0.0, 0.0, 5.0)  # +Z, away from the -Z zone
	var v := AISteering.offside_brake(desired, pos, vel, TEAM0_DIR, NEAR_PUCK_Z, false)
	assert_eq(v, desired, "no brake when already moving away from the line")


func test_offside_brake_noop_with_room_to_stop() -> void:
	# Far from the line and slow — stopping distance clears the line by
	# more than the margin, so the bot is free to keep its target.
	var desired := Vector2(0.0, -1.0)
	var pos := Vector3(0.0, 0.0, 0.0)   # center ice, ~7.3 m from the line
	var vel := Vector3(0.0, 0.0, -2.0)  # slow toward the zone
	var v := AISteering.offside_brake(desired, pos, vel, TEAM0_DIR, NEAR_PUCK_Z, false)
	assert_eq(v, desired, "plenty of room to stop → no brake")


func test_offside_brake_engages_on_fast_approach() -> void:
	# Near the line and fast toward the zone — stopping distance would
	# carry the body across, so brake away from the line (+Z for team 0).
	var desired := Vector2(0.0, -1.0)  # bot wants to keep driving into the zone
	var pos := Vector3(0.0, 0.0, -5.0) # ~2.3 m from the -7.29 line
	var vel := Vector3(0.0, 0.0, -8.0) # 8 m/s toward the zone
	var v := AISteering.offside_brake(desired, pos, vel, TEAM0_DIR, NEAR_PUCK_Z, false)
	assert_gt(v.y, 0.0, "team 0 should brake back toward +Z to avoid crossing the -Z blue line")


func test_offside_brake_engages_team1_mirrored() -> void:
	# Mirror for team 1 (attacks +Z, line at +BLUE_LINE_Z): brake toward -Z.
	var desired := Vector2(0.0, 1.0)
	var pos := Vector3(0.0, 0.0, 5.0)
	var vel := Vector3(0.0, 0.0, 8.0)  # toward the +Z zone
	var v := AISteering.offside_brake(desired, pos, vel, TEAM1_DIR, NEAR_PUCK_Z, false)
	assert_lt(v.y, 0.0, "team 1 should brake back toward -Z to avoid crossing the +Z blue line")


func test_offside_brake_preserves_lateral_intent() -> void:
	# When braking, the lateral (x) component of the desired move is kept
	# so the bot can still adjust its width along the line.
	var desired := Vector2(0.6, -1.0)
	var pos := Vector3(0.0, 0.0, -5.0)
	var vel := Vector3(0.0, 0.0, -8.0)
	var v := AISteering.offside_brake(desired, pos, vel, TEAM0_DIR, NEAR_PUCK_Z, false)
	assert_gt(v.x, 0.0, "lateral intent is preserved through the brake")
	assert_gt(v.y, 0.0, "depth component still brakes back from the line")


# ── Arrival brake (station-keeping overshoot guard) ─────────────────────────
# When the closing speed toward a point anchor can no longer be shed
# inside the remaining distance, press the real brake — a bot whose
# station target slowed down must stop AT it, not blow through and
# double back off the brake-pivot.

func test_arrival_brake_engages_inside_stopping_distance() -> void:
	# 9 m/s at an anchor 3 m ahead: stopping distance ≈ 4.05 m > 3 m.
	assert_true(AISteering.should_arrival_brake(
			Vector3.ZERO, Vector3(0, 0, 3), Vector2(0, 9), false),
			"cannot stop in 3 m from 9 m/s — brake now")


func test_arrival_brake_stays_off_with_room_to_stop() -> void:
	# Same speed, anchor 12 m out: plenty of room — keep skating.
	assert_false(AISteering.should_arrival_brake(
			Vector3.ZERO, Vector3(0, 0, 12), Vector2(0, 9), false),
			"12 m of room from 9 m/s — no brake")


func test_arrival_brake_ignores_slow_speeds() -> void:
	# Below the speed floor, friction + the anchor deadband settle it.
	assert_false(AISteering.should_arrival_brake(
			Vector3.ZERO, Vector3(0, 0, 0.4), Vector2(0, 2), false),
			"slow arrivals settle on friction, no brake key")


func test_arrival_brake_ignores_receding_motion() -> void:
	# Moving AWAY from the anchor — reversals are the pivot brake's job.
	assert_false(AISteering.should_arrival_brake(
			Vector3.ZERO, Vector3(0, 0, 3), Vector2(0, -9), false),
			"no closing speed toward the anchor — nothing to overshoot")


func test_arrival_brake_uses_closing_component_not_raw_speed() -> void:
	# Fast but tangential: the closing component toward the anchor is
	# small, so there is no overshoot to brake for.
	assert_false(AISteering.should_arrival_brake(
			Vector3.ZERO, Vector3(0, 0, 4), Vector2(9, 1), false),
			"tangential speed doesn't overshoot the point")


func test_arrival_brake_hysteresis_holds_the_brake_longer() -> void:
	# Borderline geometry sits between the engage and release margins:
	# not braking → stays off; already braking → holds on.
	var vel := Vector2(0, 8)           # stop_dist = 3.2 m
	var anchor := Vector3(0, 0, 4.0)   # engage needs 3.7 ≥ 4 (no); release needs 4.7 ≥ 4 (yes)
	assert_false(AISteering.should_arrival_brake(Vector3.ZERO, anchor, vel, false),
			"outside the engage margin — don't start braking")
	assert_true(AISteering.should_arrival_brake(Vector3.ZERO, anchor, vel, true),
			"inside the release margin — hold an in-progress brake")


func test_board_repel_yields_to_a_deliberate_wall_anchor() -> void:
	# A rim-reception / wall-retrieval anchor sits AT the boards on purpose —
	# the anti-hug field must not hold the body an equilibrium step inside the
	# wall (the blade never reached the rim line). Holding the wall stance:
	# near-zero net force. Same body position with a mid-ice anchor: the full
	# inward field (pull + repel) still applies.
	var stance := Vector3(RINK_X - 0.05, 0, 0)
	var v_hold := _move(stance, stance)
	assert_almost_eq(v_hold.x, 0.0, 0.05,
			"anchor at the wall: repel yields, the stance is holdable")
	var v_leave := _move(stance, Vector3(0, 0, 0))
	assert_lt(v_leave.x, -0.9,
			"mid-ice anchor from the same spot: full inward pull + repel")
