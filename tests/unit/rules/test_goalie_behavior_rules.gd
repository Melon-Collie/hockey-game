extends GutTest

# GoalieBehaviorRules — shot detection, defensive zone, Buckley depth chart,
# lateral X projection.

func _shot_cfg() -> GoalieBehaviorRules.ShotDetectionConfig:
	var cfg := GoalieBehaviorRules.ShotDetectionConfig.new()
	cfg.shot_speed_threshold = 5.0
	cfg.net_half_width = 0.915
	cfg.net_margin = 1.0
	cfg.reaction_delay = 0.10
	cfg.low_shot_threshold = 0.45
	cfg.elevated_threshold = 0.45
	return cfg

func _zone_cfg() -> GoalieBehaviorRules.DefensiveZoneConfig:
	var cfg := GoalieBehaviorRules.DefensiveZoneConfig.new()
	cfg.zone_post_z = 2.0
	cfg.rvh_early_angle = 60.0
	return cfg

func _depth_cfg() -> GoalieBehaviorRules.DepthConfig:
	var cfg := GoalieBehaviorRules.DepthConfig.new()
	cfg.zone_post_z = 2.0
	cfg.zone_aggressive_z = 8.0
	cfg.zone_base_z = 12.0
	cfg.zone_conservative_z = 20.0
	cfg.depth_aggressive = 1.2
	cfg.depth_base = 0.6
	cfg.depth_conservative = 0.3
	cfg.depth_defensive = 0.1
	return cfg

# ── detect_shot ──────────────────────────────────────────────────────────────

func test_slow_puck_not_a_shot() -> void:
	var result: GoalieBehaviorRules.ShotResult = GoalieBehaviorRules.detect_shot(
		Vector3(0, 0, 10), Vector3(0, 0, -1),   # below threshold
		26.6, 0.0, _shot_cfg())
	assert_false(result.is_shot)

func test_fast_puck_on_target_is_shot() -> void:
	var result: GoalieBehaviorRules.ShotResult = GoalieBehaviorRules.detect_shot(
		Vector3(0, 0, 10), Vector3(0, 0, 20),   # heading toward +Z goal
		26.6, 0.0, _shot_cfg())
	assert_true(result.is_shot)
	assert_almost_eq(result.reaction_delay, 0.10, 0.001)

# time_to_impact is exposed so callers can gate on imminence. Puck at z=10,
# vz=20, goal line at z=26.6 → (26.6 - 10) / 20 = 0.83s.
func test_shot_exposes_time_to_impact() -> void:
	var result: GoalieBehaviorRules.ShotResult = GoalieBehaviorRules.detect_shot(
		Vector3(0, 0, 10), Vector3(0, 0, 20),
		26.6, 0.0, _shot_cfg())
	assert_true(result.is_shot)
	assert_almost_eq(result.time_to_impact, 0.83, 0.01)

func test_fast_puck_moving_away_not_a_shot() -> void:
	var result: GoalieBehaviorRules.ShotResult = GoalieBehaviorRules.detect_shot(
		Vector3(0, 0, 10), Vector3(0, 0, -20),  # away from +Z goal
		26.6, 0.0, _shot_cfg())
	assert_false(result.is_shot)

func test_fast_puck_wide_of_post_not_a_shot() -> void:
	var result: GoalieBehaviorRules.ShotResult = GoalieBehaviorRules.detect_shot(
		Vector3(10, 0, 10), Vector3(10, 0, 5),  # drifting wider as it travels
		26.6, 0.0, _shot_cfg())
	assert_false(result.is_shot)

func test_shot_classifies_low() -> void:
	# Puck at z=10, velocity (0, 0, 20) — no Y component, impact_y ≈ 0
	var result: GoalieBehaviorRules.ShotResult = GoalieBehaviorRules.detect_shot(
		Vector3(0, 0, 10), Vector3(0, 0, 20),
		26.6, 0.0, _shot_cfg())
	assert_true(result.is_shot)
	assert_true(result.is_low)
	assert_false(result.is_elevated)

func test_shot_classifies_elevated() -> void:
	# Puck with upward velocity — impact_y should be > 0.45
	var result: GoalieBehaviorRules.ShotResult = GoalieBehaviorRules.detect_shot(
		Vector3(0, 0.05, 10), Vector3(0, 6.0, 20),
		26.6, 0.0, _shot_cfg())
	assert_true(result.is_shot)
	assert_false(result.is_low)
	assert_true(result.is_elevated)

func test_long_range_elevated_arcs_to_low() -> void:
	# Puck at z=0 with vy=6 m/s, vz=20 m/s. t_to_goal = 26.6/20 = 1.33s.
	# Linear impact_y = 0.05 + 6*1.33 ≈ 8m (would classify elevated).
	# Ballistic impact_y = 0.05 + 6*1.33 - 0.5*9.8*1.33² ≈ -0.63 → clamped 0.
	# Long-range arcing shots should arrive low and trigger butterfly drop.
	var result: GoalieBehaviorRules.ShotResult = GoalieBehaviorRules.detect_shot(
		Vector3(0, 0.05, 0), Vector3(0, 6.0, 20),
		26.6, 0.0, _shot_cfg())
	assert_true(result.is_shot)
	assert_true(result.is_low, "long-range elevated should land low after gravity arc")
	assert_false(result.is_elevated)

func test_short_range_elevated_stays_elevated() -> void:
	# Same vy=6 but starting much closer (z=22, t_to_goal=0.23s): puck hasn't
	# had time to arc back down. Should still classify as elevated.
	var result: GoalieBehaviorRules.ShotResult = GoalieBehaviorRules.detect_shot(
		Vector3(0, 0.05, 22), Vector3(0, 6.0, 20),
		26.6, 0.0, _shot_cfg())
	assert_true(result.is_shot)
	assert_true(result.is_elevated, "short-range elevated should still arrive elevated")

func test_legacy_zero_gravity_matches_linear_behavior() -> void:
	# With gravity=0 the prediction reverts to the previous linear extrapolation.
	# Useful for callers that don't want ballistic correction.
	var cfg: GoalieBehaviorRules.ShotDetectionConfig = _shot_cfg()
	cfg.gravity = 0.0
	var result: GoalieBehaviorRules.ShotResult = GoalieBehaviorRules.detect_shot(
		Vector3(0, 0.05, 0), Vector3(0, 6.0, 20),
		26.6, 0.0, cfg)
	assert_true(result.is_shot)
	# Linear impact_y ≈ 8m — classified elevated under legacy math.
	assert_true(result.is_elevated)

func test_shot_impact_x_projects_correctly() -> void:
	# Puck at x=0, z=10; velocity (5, 0, 20) — drifting right.
	# t_to_goal = (26.6 - 10) / 20 = 0.83s; impact_x = 0 + 5 * 0.83 = 4.15 → wide, not a shot
	# Use smaller X drift to stay on net:
	var result: GoalieBehaviorRules.ShotResult = GoalieBehaviorRules.detect_shot(
		Vector3(0, 0, 10), Vector3(0.5, 0, 20),
		26.6, 0.0, _shot_cfg())
	assert_true(result.is_shot)
	# impact_x = 0 + 0.5 * (16.6/20) = 0.415
	assert_almost_eq(result.impact_x, 0.415, 0.01)

# ── is_puck_in_defensive_zone ────────────────────────────────────────────────
# direction_sign = sign(-goal_line_z), so for goalie at +Z (goal_line=+26.6)
# direction_sign = -1. Puck "behind" the goalie means z > goal_line_z.

func test_puck_behind_goal_in_defensive_zone() -> void:
	# Goalie defends +Z goal, puck past the goal line at z=28
	assert_true(GoalieBehaviorRules.is_puck_in_defensive_zone(
		Vector3(0, 0, 28), 26.6, 0.0, -1, _zone_cfg()))

func test_puck_far_from_goal_not_in_defensive_zone() -> void:
	assert_false(GoalieBehaviorRules.is_puck_in_defensive_zone(
		Vector3(0, 0, 10), 26.6, 0.0, -1, _zone_cfg()))

func test_puck_near_post_sharp_angle_in_defensive_zone() -> void:
	# Close in z (puck_z_dist = 1.1), offset in x (3) → angle ≈ 70° > 60°
	assert_true(GoalieBehaviorRules.is_puck_in_defensive_zone(
		Vector3(3, 0, 25.5), 26.6, 0.0, -1, _zone_cfg()))

func test_puck_near_post_shallow_angle_not_in_defensive_zone() -> void:
	# Close in z (1.1), small X offset (0.3) → angle ≈ 15° < 60°
	assert_false(GoalieBehaviorRules.is_puck_in_defensive_zone(
		Vector3(0.3, 0, 25.5), 26.6, 0.0, -1, _zone_cfg()))

func test_puck_behind_negative_z_goal() -> void:
	# Opposite-side goalie: defends -Z (goal_line=-26.6), direction_sign=+1.
	# Puck "behind" means z < -26.6.
	assert_true(GoalieBehaviorRules.is_puck_in_defensive_zone(
		Vector3(0, 0, -28), -26.6, 0.0, 1, _zone_cfg()))

# ── target_depth_for_puck_distance ───────────────────────────────────────────

func test_depth_at_zone_post_reaches_aggressive() -> void:
	var d: float = GoalieBehaviorRules.target_depth_for_puck_distance(
		_depth_cfg().zone_post_z, _depth_cfg())
	assert_almost_eq(d, _depth_cfg().depth_aggressive, 0.001)

func test_depth_inside_aggressive_zone_stays_aggressive() -> void:
	var d: float = GoalieBehaviorRules.target_depth_for_puck_distance(
		5.0,  # between zone_post_z and zone_aggressive_z
		_depth_cfg())
	assert_almost_eq(d, _depth_cfg().depth_aggressive, 0.001)

func test_depth_far_away_is_defensive() -> void:
	var d: float = GoalieBehaviorRules.target_depth_for_puck_distance(
		100.0, _depth_cfg())
	assert_almost_eq(d, _depth_cfg().depth_defensive, 0.001)

func test_depth_at_origin_is_defensive() -> void:
	# puck_z_dist = 0 → t = 0 → lerp(defensive, aggressive, 0) = defensive
	var d: float = GoalieBehaviorRules.target_depth_for_puck_distance(
		0.0, _depth_cfg())
	assert_almost_eq(d, _depth_cfg().depth_defensive, 0.001)

# ── target_lateral_x ─────────────────────────────────────────────────────────
# Goalie defends +Z goal: direction_sign = sign(-26.6) = -1

func test_lateral_x_clamps_to_net_width() -> void:
	var x: float = GoalieBehaviorRules.target_lateral_x(
		Vector3(100, 0, 10), 26.6, 0.0, 0.5, 0.915, -1)
	assert_true(x <= 0.916, "x=%f should be clamped to net_half_width" % x)

func test_lateral_x_centered_puck_returns_center() -> void:
	# Puck directly in front of goal, centred — bisector is straight ahead, target = 0.
	var x: float = GoalieBehaviorRules.target_lateral_x(
		Vector3(0, 0, 10), 26.6, 0.0, 1.0, 0.915, -1)
	assert_almost_eq(x, 0.0, 0.05)

func test_lateral_x_bisector_closer_to_near_post_on_angle() -> void:
	# Puck far to the right at (4, 0, 16) — bisector should place goalie
	# closer to the right post than simple X-projection would.
	var bisect_x: float = GoalieBehaviorRules.target_lateral_x(
		Vector3(4, 0, 16), 26.6, 0.0, 1.0, 0.915, -1)
	var simple_x: float = 0.0 + (4.0 - 0.0) * (1.0 / absf(16.0 - 26.6))  # old formula
	# Angle bisector pulls goalie further toward the near post than simple projection.
	assert_true(bisect_x > simple_x, "bisect=%f should exceed simple=%f on sharp angle" % [bisect_x, simple_x])
	assert_true(bisect_x <= 0.916)

func test_lateral_x_puck_at_goal_line_clamps_to_post() -> void:
	# Puck sitting at the goal line far to the right — goalie should hug that post.
	var x: float = GoalieBehaviorRules.target_lateral_x(
		Vector3(5, 0, 26.6), 26.6, 0.0, 1.0, 0.915, -1)
	assert_almost_eq(x, 0.915, 0.01)

# ── compute_threat_position ──────────────────────────────────────────────────

func test_threat_no_carrier_returns_puck() -> void:
	var t: Vector3 = GoalieBehaviorRules.compute_threat_position(
		Vector3(2.0, 0.1, 10.0), Vector3(5.0, 0.0, 8.0),
		false, 0.75)
	assert_almost_eq(t.x, 2.0, 0.001)
	assert_almost_eq(t.z, 10.0, 0.001)

func test_threat_with_carrier_blends_toward_body() -> void:
	# weight 0.75 → 75% body, 25% puck.
	var t: Vector3 = GoalieBehaviorRules.compute_threat_position(
		Vector3(2.0, 0.1, 10.0), Vector3(0.0, 0.0, 12.0),
		true, 0.75)
	assert_almost_eq(t.x, 0.5, 0.001)   # 0.25*2 + 0.75*0 = 0.5
	assert_almost_eq(t.z, 11.5, 0.001)  # 0.25*10 + 0.75*12 = 11.5

func test_threat_weight_clamps() -> void:
	# Weight > 1 should clamp to pure body.
	var t: Vector3 = GoalieBehaviorRules.compute_threat_position(
		Vector3(2.0, 0.0, 10.0), Vector3(0.0, 0.0, 12.0),
		true, 5.0)
	assert_almost_eq(t.x, 0.0, 0.001)
	assert_almost_eq(t.z, 12.0, 0.001)

func test_threat_weight_zero_returns_puck_even_with_carrier() -> void:
	# Pure puck mode (e.g. shot in flight).
	var t: Vector3 = GoalieBehaviorRules.compute_threat_position(
		Vector3(2.0, 0.1, 10.0), Vector3(0.0, 0.0, 12.0),
		true, 0.0)
	assert_almost_eq(t.x, 2.0, 0.001)
	assert_almost_eq(t.z, 10.0, 0.001)

# ── target_arc_position ──────────────────────────────────────────────────────
# Conventions: goal at +Z (goal_line_z=26.6), direction_sign=-1 means goalie
# stands on the negative-Z side of the goal line (in front of the net).

func test_arc_centered_threat_places_goalie_dead_center() -> void:
	# Threat directly in front of net at z=20. Arc puts goalie at depth=radius
	# perpendicular to goal line, centered.
	var p: Vector2 = GoalieBehaviorRules.target_arc_position(
		Vector3(0, 0, 20), 26.6, 0.0, -1, 0.6, 0.915)
	assert_almost_eq(p.x, 0.0, 0.001)
	assert_almost_eq(p.y, 26.0, 0.001)  # 26.6 - 0.6

func test_arc_wide_threat_pulls_goalie_off_center_and_back() -> void:
	# Threat to the right and in front. Goalie should end up on the right
	# side and at a perpendicular depth shallower than the radius (because
	# the radius is consumed by lateral motion).
	var p: Vector2 = GoalieBehaviorRules.target_arc_position(
		Vector3(5, 0, 21.6), 26.6, 0.0, -1, 1.2, 0.915)
	assert_true(p.x > 0.0, "goalie should be on right side, got x=%f" % p.x)
	# perp depth = 26.6 - p.y; should be < radius (1.2) because the arc
	# spends some of the radius on lateral position.
	var perp_depth: float = 26.6 - p.y
	assert_true(perp_depth < 1.2, "perp depth=%f should be shallower than radius 1.2" % perp_depth)
	assert_true(perp_depth > 0.0, "perp depth=%f should still be in front of goal" % perp_depth)

func test_arc_clamps_x_to_post_on_extreme_angle() -> void:
	# Threat at the goal line, way to the right. Direction is purely lateral,
	# arc would put goalie at x=radius which exceeds net half-width — clamp.
	var p: Vector2 = GoalieBehaviorRules.target_arc_position(
		Vector3(20, 0, 26.6), 26.6, 0.0, -1, 1.5, 0.915)
	assert_almost_eq(p.x, 0.915, 0.001)  # clamped to right post

func test_arc_threat_behind_goal_flattens_to_goal_line() -> void:
	# Threat behind the net at z > goal_line_z. The arc would put the goalie
	# behind the goal line; flatten z to the goal line itself.
	var p: Vector2 = GoalieBehaviorRules.target_arc_position(
		Vector3(0, 0, 28.0), 26.6, 0.0, -1, 0.5, 0.915)
	assert_almost_eq(p.y, 26.6, 0.001)

func test_arc_negative_z_goal_orientation() -> void:
	# Opposite-side goalie: defends -Z, direction_sign = +1. Threat at z=-20.
	var p: Vector2 = GoalieBehaviorRules.target_arc_position(
		Vector3(0, 0, -20), -26.6, 0.0, 1, 0.6, 0.915)
	assert_almost_eq(p.x, 0.0, 0.001)
	assert_almost_eq(p.y, -26.0, 0.001)  # -26.6 + 0.6

# ── compute_slide_destination ────────────────────────────────────────────────

func test_slide_destination_matches_arc_at_butterfly_depth() -> void:
	# Slide destination should equal target_arc_position at the butterfly
	# radius (currently a thin alias).
	var threat := Vector3(2, 0, 22)
	var slide: Vector2 = GoalieBehaviorRules.compute_slide_destination(
		threat, 26.6, 0.0, -1, 0.4, 0.915)
	var arc: Vector2 = GoalieBehaviorRules.target_arc_position(
		threat, 26.6, 0.0, -1, 0.4, 0.915)
	assert_almost_eq(slide.x, arc.x, 0.001)
	assert_almost_eq(slide.y, arc.y, 0.001)

# ── threat_distance_to_goal ──────────────────────────────────────────────────

func test_threat_distance_euclidean() -> void:
	var d: float = GoalieBehaviorRules.threat_distance_to_goal(
		Vector3(3, 0, 22.6), 26.6, 0.0)
	# dx=3, dz=-4 → sqrt(9+16) = 5
	assert_almost_eq(d, 5.0, 0.001)

# ── should_react_to_puck ─────────────────────────────────────────────────────

func _reaction_cfg() -> GoalieBehaviorRules.UniversalReactionConfig:
	var cfg := GoalieBehaviorRules.UniversalReactionConfig.new()
	cfg.min_speed = 1.0  # anti-jitter floor only
	cfg.max_time_to_impact = 0.6
	cfg.net_half_width = 0.915
	cfg.net_margin = 0.5
	return cfg

func test_react_to_fast_puck_on_target() -> void:
	# Puck at (0, 0, 20) heading +Z fast → on track for goal at z=26.6.
	assert_true(GoalieBehaviorRules.should_react_to_puck(
		Vector3(0, 0, 20), Vector3(0, 0, 20),
		26.6, 0.0, _reaction_cfg()))

func test_react_to_slow_trickler_at_doorstep() -> void:
	# The case that motivated removing the speed gate: a puck oozing at 2 m/s
	# from 0.6m out (t = 0.3s < 0.6) on a line into the net MUST trigger a
	# reaction — standing there while it trickles between the legs is the bug.
	assert_true(GoalieBehaviorRules.should_react_to_puck(
		Vector3(0, 0, 26.0), Vector3(0, 0, 2),
		26.6, 0.0, _reaction_cfg()))

func test_react_skips_essentially_stationary_puck() -> void:
	# Below the anti-jitter floor (0.3 m/s < 1.0) — a near-dead puck whose
	# direction wobbles shouldn't twitch the goalie into a reaction.
	assert_false(GoalieBehaviorRules.should_react_to_puck(
		Vector3(0, 0, 26.2), Vector3(0, 0, 0.3),
		26.6, 0.0, _reaction_cfg()))

func test_react_skips_slow_puck_far_away() -> void:
	# Slow AND far → long ETA, correctly ignored. 4 m/s from z=20 is 1.65s out,
	# past the max_time_to_impact window. The ETA gate (not a speed gate) is
	# what filters this — the goalie has time to track it normally first.
	assert_false(GoalieBehaviorRules.should_react_to_puck(
		Vector3(0, 0, 20), Vector3(0, 0, 4),
		26.6, 0.0, _reaction_cfg()))

func test_react_skips_puck_moving_away() -> void:
	# Negative vz away from the goal.
	assert_false(GoalieBehaviorRules.should_react_to_puck(
		Vector3(0, 0, 20), Vector3(0, 0, -15),
		26.6, 0.0, _reaction_cfg()))

func test_react_skips_puck_off_target() -> void:
	# Fast and arriving within max_time_to_impact, but landing wide of the net.
	# t = (26.6 - 20) / 15 = 0.44s; impact_x = 5 × 0.44 = 2.2m, outside the
	# (0.915 + 0.5) = 1.415m allowed window. Filter must catch the lateral
	# miss specifically, not bounce on the eta gate.
	assert_false(GoalieBehaviorRules.should_react_to_puck(
		Vector3(0, 0, 20), Vector3(5, 0, 15),
		26.6, 0.0, _reaction_cfg()))

func test_react_skips_far_puck_with_long_eta() -> void:
	# Fast puck but very far away → t_to_impact > max_time_to_impact.
	assert_false(GoalieBehaviorRules.should_react_to_puck(
		Vector3(0, 0, 0), Vector3(0, 0, 10),  # t = 26.6 / 10 = 2.66s > 0.6
		26.6, 0.0, _reaction_cfg()))

func test_react_fires_on_bounced_puck() -> void:
	# Off-board bounce — puck coming at the net from a sharp angle, fast.
	# Velocity vector blends X + Z components; check we still react.
	assert_true(GoalieBehaviorRules.should_react_to_puck(
		Vector3(2, 0, 22), Vector3(-3, 0, 15),
		26.6, 0.0, _reaction_cfg()))

# ── lateral_puck_velocity_in_slot ────────────────────────────────────────────

func test_cross_crease_pass_detected_in_slot() -> void:
	# Puck in slot zone, moving primarily sideways (vx = 8, vz = 1, ratio 8.0).
	# direction_sign = -1 (defends +Z goal at z=26.6, slot 5m in front).
	var vx: float = GoalieBehaviorRules.lateral_puck_velocity_in_slot(
		Vector3(0, 0, 23.5), Vector3(8, 0, 1),
		26.6, -1, 5.0, 1.5)
	assert_almost_eq(vx, 8.0, 0.001)

func test_cross_crease_returns_zero_when_puck_moves_forward() -> void:
	# Puck in slot but heading toward net (forward dominates lateral).
	var vx: float = GoalieBehaviorRules.lateral_puck_velocity_in_slot(
		Vector3(0, 0, 23.5), Vector3(2, 0, 10),
		26.6, -1, 5.0, 1.5)
	assert_eq(vx, 0.0)

func test_cross_crease_returns_zero_outside_slot() -> void:
	# Puck way back, even if moving sideways fast — not a slot pass yet.
	var vx: float = GoalieBehaviorRules.lateral_puck_velocity_in_slot(
		Vector3(0, 0, 18), Vector3(10, 0, 1),
		26.6, -1, 5.0, 1.5)
	assert_eq(vx, 0.0)

func test_cross_crease_returns_zero_when_puck_behind_goal_line() -> void:
	# Puck behind the goal — not in front, no reaction.
	var vx: float = GoalieBehaviorRules.lateral_puck_velocity_in_slot(
		Vector3(0, 0, 27.5), Vector3(8, 0, 0),
		26.6, -1, 5.0, 1.5)
	assert_eq(vx, 0.0)

func test_cross_crease_signed_velocity() -> void:
	# Pass going LEFT should return negative.
	var vx: float = GoalieBehaviorRules.lateral_puck_velocity_in_slot(
		Vector3(0, 0, 23.5), Vector3(-8, 0, 1),
		26.6, -1, 5.0, 1.5)
	assert_almost_eq(vx, -8.0, 0.001)

func test_cross_crease_works_for_other_team() -> void:
	# Team that defends -Z goal: direction_sign = +1, goal_line_z = -26.6.
	# Slot is in front of THAT goal (puck.z near goal at z=-26.6).
	var vx: float = GoalieBehaviorRules.lateral_puck_velocity_in_slot(
		Vector3(0, 0, -23.5), Vector3(8, 0, -1),
		-26.6, 1, 5.0, 1.5)
	assert_almost_eq(vx, 8.0, 0.001)
