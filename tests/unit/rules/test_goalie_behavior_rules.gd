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
	cfg.depth_aggressive = 1.75
	cfg.depth_base = 1.30
	cfg.depth_conservative = 0.70
	cfg.depth_defensive = 0.10
	return cfg

# ── detect_shot ──────────────────────────────────────────────────────────────

func test_slow_puck_not_a_shot() -> void:
	var result: GoalieBehaviorRules.ShotResult = GoalieBehaviorRules.detect_shot(
		Vector3(0, 0, 10), Vector3(0, 0, -1),   # below threshold
		26.6, 0.0, _shot_cfg())
	assert_false(result.is_shot)

# The universal-reaction path (board bounces, dying rebounds, slow tricklers)
# classifies impact with the shot_speed_threshold set to 0 — should_react_to_puck
# already owns the urgency decision (imminence + on-net), so the speed floor that
# filters slow dribbled passes on the RELEASE path must NOT re-reject a slow puck
# oozing at the doorstep here. This locks that contract: a 2 m/s on-net puck is a
# (low) shot when the floor is removed, so the goalie actually drops for it.
func test_slow_on_net_puck_classifies_without_speed_floor() -> void:
	var cfg := _shot_cfg()
	cfg.shot_speed_threshold = 0.0
	var result: GoalieBehaviorRules.ShotResult = GoalieBehaviorRules.detect_shot(
		Vector3(0, 0, 25), Vector3(0, 0, 2),   # 2 m/s, ~0.8s from the +Z goal line
		26.6, 0.0, cfg)
	assert_true(result.is_shot, "slow on-net puck should classify once the speed floor is removed")
	assert_true(result.is_low, "a grounded trickler is a low shot → butterfly drop")

# The RELEASE path keeps the speed floor — the SAME slow puck is NOT a shot with
# the default threshold, so slow dribbled passes don't fire a release reaction
# from across the rink. This is the guard the universal path deliberately bypasses.
func test_slow_on_net_puck_rejected_with_speed_floor() -> void:
	var result: GoalieBehaviorRules.ShotResult = GoalieBehaviorRules.detect_shot(
		Vector3(0, 0, 25), Vector3(0, 0, 2),
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

func test_depth_far_away_floors_at_conservative() -> void:
	# A puck far away IN FRONT leaves the goalie resting at conservative depth
	# (watching the play from the paint) — goal-line depth is for behind-net /
	# post play only (audit F8; USA Hockey D-zone = behind-net tracking).
	var d: float = GoalieBehaviorRules.target_depth_for_puck_distance(
		100.0, _depth_cfg())
	assert_almost_eq(d, _depth_cfg().depth_conservative, 0.001)

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

func _arc_cfg() -> GoalieBehaviorRules.ArcConfig:
	var cfg := GoalieBehaviorRules.ArcConfig.new()
	cfg.net_half_width = 0.915
	cfg.seal_inset = 0.38
	cfg.seal_depth = 0.10
	cfg.post_integration_angle_deg = 80.0
	return cfg

func test_arc_centered_threat_places_goalie_dead_center() -> void:
	# Threat directly in front of net at z=20. Arc puts goalie at depth=radius
	# perpendicular to goal line, centered.
	var p: Vector2 = GoalieBehaviorRules.target_arc_position(
		Vector3(0, 0, 20), 26.6, 0.0, -1, 0.6, _arc_cfg())
	assert_almost_eq(p.x, 0.0, 0.001)
	assert_almost_eq(p.y, 26.0, 0.001)  # 26.6 - 0.6

func test_arc_wide_threat_pulls_goalie_off_center_and_back() -> void:
	# Threat to the right and in front. Goalie should end up on the right
	# side and at a perpendicular depth shallower than the radius (because
	# the radius is consumed by lateral motion).
	var p: Vector2 = GoalieBehaviorRules.target_arc_position(
		Vector3(5, 0, 21.6), 26.6, 0.0, -1, 1.2, _arc_cfg())
	assert_true(p.x > 0.0, "goalie should be on right side, got x=%f" % p.x)
	# perp depth = 26.6 - p.y; should be < radius (1.2) because the arc
	# spends some of the radius on lateral position.
	var perp_depth: float = 26.6 - p.y
	assert_true(perp_depth < 1.2, "perp depth=%f should be shallower than radius 1.2" % perp_depth)
	assert_true(perp_depth > 0.0, "perp depth=%f should still be in front of goal" % perp_depth)

func test_arc_converges_on_the_post_seal_past_the_exit_angle() -> void:
	# Threat on the goal line, way to the right: purely lateral, so the challenge
	# line left the mouth long ago. He must be AT the post-seal spot — inboard of
	# the pipe and on his line — which is exactly where post integration parks
	# him, so the handoff at the trigger angle is continuous.
	var cfg: GoalieBehaviorRules.ArcConfig = _arc_cfg()
	var p: Vector2 = GoalieBehaviorRules.target_arc_position(
		Vector3(20, 0, 26.6), 26.6, 0.0, -1, 1.5, cfg)
	assert_almost_eq(p.x, 0.915 - 0.38, 0.001, "inboard of the post, not on it")
	assert_almost_eq(26.6 - p.y, 0.10, 0.001, "on his line at the seal depth")
	assert_almost_eq(cfg.out_seal_blend, 1.0, 0.001)

func test_arc_never_leaves_the_mouth_and_blend_is_monotonic() -> void:
	# Sweeping the angle from straight on to the post: he stays inside the pipes
	# at every angle, and the seal blend only ever increases.
	var cfg: GoalieBehaviorRules.ArcConfig = _arc_cfg()
	var prev_blend: float = -1.0
	for i: int in 19:
		var theta: float = deg_to_rad(float(i) * 5.0)
		var threat := Vector3(6.0 * sin(theta), 0.0, 26.6 - 6.0 * cos(theta))
		var p: Vector2 = GoalieBehaviorRules.target_arc_position(
			threat, 26.6, 0.0, -1, 1.5, cfg)
		assert_lte(absf(p.x), 0.915 + 0.001,
				"goalie outside the post at %.0f deg (x=%f)" % [rad_to_deg(theta), p.x])
		assert_gte(cfg.out_seal_blend, prev_blend - 0.001,
				"seal blend went backwards at %.0f deg" % [rad_to_deg(theta)])
		prev_blend = cfg.out_seal_blend

func test_arc_inside_the_mouth_is_the_untouched_challenge_arc() -> void:
	# Below the exit angle nothing changes: the blend stays at zero and the point
	# is the plain radius-along-the-ray solve.
	var cfg: GoalieBehaviorRules.ArcConfig = _arc_cfg()
	var p: Vector2 = GoalieBehaviorRules.target_arc_position(
		Vector3(0.5, 0, 21.6), 26.6, 0.0, -1, 1.2, cfg)
	assert_almost_eq(cfg.out_seal_blend, 0.0, 0.0001)
	assert_almost_eq(Vector2(p.x, 26.6 - p.y).length(), 1.2, 0.001,
			"still exactly `radius` from goal centre")

func test_arc_threat_behind_goal_flattens_to_goal_line() -> void:
	# Threat behind the net at z > goal_line_z. The arc would put the goalie
	# behind the goal line; flatten z to the goal line itself.
	var p: Vector2 = GoalieBehaviorRules.target_arc_position(
		Vector3(0, 0, 28.0), 26.6, 0.0, -1, 0.5, _arc_cfg())
	assert_almost_eq(p.y, 26.6, 0.001)

func test_arc_negative_z_goal_orientation() -> void:
	# Opposite-side goalie: defends -Z, direction_sign = +1. Threat at z=-20.
	var p: Vector2 = GoalieBehaviorRules.target_arc_position(
		Vector3(0, 0, -20), -26.6, 0.0, 1, 0.6, _arc_cfg())
	assert_almost_eq(p.x, 0.0, 0.001)
	assert_almost_eq(p.y, -26.0, 0.001)  # -26.6 + 0.6

# ── compute_slide_destination ────────────────────────────────────────────────

func test_slide_destination_matches_arc_at_butterfly_depth() -> void:
	# Slide destination should equal target_arc_position at the butterfly
	# radius (currently a thin alias).
	var threat := Vector3(2, 0, 22)
	var slide: Vector2 = GoalieBehaviorRules.compute_slide_destination(
		threat, 26.6, 0.0, -1, 0.4, _arc_cfg())
	var arc: Vector2 = GoalieBehaviorRules.target_arc_position(
		threat, 26.6, 0.0, -1, 0.4, _arc_cfg())
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

# ── compute_clear_velocity ────────────────────────────────────────────────────
# Goal at +Z (goal_line_z = +26.6, direction_sign = -1). Forward (out of the
# crease, into the rink) is therefore the -Z direction.

func test_clear_sweeps_to_the_side_the_puck_sits() -> void:
	# Puck offset to +X → swept toward +X (that corner), and forward (-Z).
	var vel: Vector3 = GoalieBehaviorRules.compute_clear_velocity(
		Vector3(0.5, 0, 25.8), 0.0, -1, 1.0, 0.5, 7.0, 0.15, 1.0)
	assert_gt(vel.x, 0.0)
	assert_lt(vel.z, 0.0)        # forward = -Z for the +Z goal
	assert_almost_eq(vel.y, 0.0, 0.0001)
	assert_almost_eq(vel.length(), 7.0, 0.001)

func test_clear_lateral_dominates_forward() -> void:
	# Lateral weight > forward weight → cleared cornerward, not back up the slot.
	var vel: Vector3 = GoalieBehaviorRules.compute_clear_velocity(
		Vector3(0.5, 0, 25.8), 0.0, -1, 1.0, 0.5, 7.0, 0.15, 1.0)
	assert_gt(absf(vel.x), absf(vel.z))

func test_clear_dead_centre_uses_default_side() -> void:
	# Puck dead centre (within deadband) → pushed toward default_side (-1 here).
	var vel: Vector3 = GoalieBehaviorRules.compute_clear_velocity(
		Vector3(0.05, 0, 25.8), 0.0, -1, 1.0, 0.5, 7.0, 0.15, -1.0)
	assert_lt(vel.x, 0.0)

func test_clear_forward_flips_for_other_goal() -> void:
	# Goal at -Z (direction_sign = +1): forward is +Z.
	var vel: Vector3 = GoalieBehaviorRules.compute_clear_velocity(
		Vector3(0.5, 0, -25.8), 0.0, 1, 1.0, 0.5, 7.0, 0.15, 1.0)
	assert_gt(vel.z, 0.0)

# ── screen_occlusion_delay ────────────────────────────────────────────────────
# Puck (shooter) at origin, goalie 10m down +Z, shot flying +Z at 10 m/s so for a
# body ON that line the delay = its along-shot distance / 10. Defaults: radius
# 0.6, min_along 0.6. Two halves to the model: the RELEASE has to be hidden (a
# release the goalie saw is a read he keeps), and the occlusion ends when the puck
# leaves the body's shadow — which for a dead-on shot is when it draws level with
# it, so a NET-FRONT (doorstep) body hides longest and a shooter-side body least.

func _screen_cfg() -> GoalieBehaviorRules.ScreenConfig:
	var cfg := GoalieBehaviorRules.ScreenConfig.new()
	cfg.screener_radius = 0.6
	cfg.min_along = 0.6
	return cfg

func test_screen_no_bodies_is_clear() -> void:
	var d: float = GoalieBehaviorRules.screen_occlusion_delay(
		Vector3.ZERO, Vector3(0, 0, 10), Vector3(0, 0, 10),
		PackedVector3Array(), _screen_cfg())
	assert_eq(d, 0.0)

func test_screen_dead_on_midway() -> void:
	# Screener 5m along the shot; puck at 10 m/s reaches it — emerges — at 0.5s.
	var d: float = GoalieBehaviorRules.screen_occlusion_delay(
		Vector3.ZERO, Vector3(0, 0, 10), Vector3(0, 0, 10),
		PackedVector3Array([Vector3(0, 0, 5)]), _screen_cfg())
	assert_almost_eq(d, 0.5, 0.001)

func test_screen_off_to_the_side_clears() -> void:
	# 1.0 m off the eye→release line at half range (shadow half-width there is
	# 0.6·5/10 = 0.3) → the goalie sees the release → no occlusion.
	var d: float = GoalieBehaviorRules.screen_occlusion_delay(
		Vector3.ZERO, Vector3(0, 0, 10), Vector3(0, 0, 10),
		PackedVector3Array([Vector3(1.0, 0, 5)]), _screen_cfg())
	assert_eq(d, 0.0)

func test_screen_needs_the_release_hidden_not_the_flight_path() -> void:
	# Shot from the origin aimed 2 m wide of the goalie, with a body sitting
	# exactly ON that flight path 6 m along — but 1.18 m off the goalie's
	# eye→release line, so he watched the puck leave the blade in the clear. He
	# HAS the trajectory; a body it flies behind afterwards cannot take the read
	# back. The old shot-line test charged him 0.6 s for this.
	var vel: Vector3 = Vector3(2, 0, 10).normalized() * 10.0
	var on_path: Vector3 = vel.normalized() * 6.0
	var d: float = GoalieBehaviorRules.screen_occlusion_delay(
		Vector3.ZERO, vel, Vector3(0, 0, 10),
		PackedVector3Array([on_path]), _screen_cfg())
	assert_eq(d, 0.0, "a release the goalie saw is a read he keeps")

func test_screen_angled_shot_leaves_the_shadow_early() -> void:
	# Screener dead in front of the goalie (0, 8) with the shooter behind him at
	# the origin — the release IS hidden. But the shot is angled 1.5 m across, so
	# the puck slides out of the body's silhouette before it ever draws level
	# with him: shorter blind window than the same screen taken dead-on.
	var vel: Vector3 = (Vector3(1.5, 0, 10) - Vector3.ZERO).normalized() * 10.0
	var angled: float = GoalieBehaviorRules.screen_occlusion_delay(
		Vector3.ZERO, vel, Vector3(0, 0, 10),
		PackedVector3Array([Vector3(0, 0, 8)]), _screen_cfg())
	var dead_on: float = GoalieBehaviorRules.screen_occlusion_delay(
		Vector3.ZERO, Vector3(0, 0, 10), Vector3(0, 0, 10),
		PackedVector3Array([Vector3(0, 0, 8)]), _screen_cfg())
	assert_gt(angled, 0.0, "the release was hidden, so there is a real delay")
	assert_lt(angled, dead_on, "angling off the sightline clears the screen sooner")

func test_screen_behind_goalie_clears() -> void:
	# Body past the goalie (along 12 >= goalie_along 10) can't hide an incoming puck.
	var d: float = GoalieBehaviorRules.screen_occlusion_delay(
		Vector3.ZERO, Vector3(0, 0, 10), Vector3(0, 0, 10),
		PackedVector3Array([Vector3(0, 0, 12)]), _screen_cfg())
	assert_eq(d, 0.0)

func test_screen_at_shooter_clears() -> void:
	# along 0.3 < min_along 0.6 → the shooter doesn't screen their own shot.
	var d: float = GoalieBehaviorRules.screen_occlusion_delay(
		Vector3.ZERO, Vector3(0, 0, 10), Vector3(0, 0, 10),
		PackedVector3Array([Vector3(0, 0, 0.3)]), _screen_cfg())
	assert_eq(d, 0.0)

func test_screen_net_front_hides_longer_than_shooter_side() -> void:
	# Doorstep body (near goalie) hides the puck until it's almost in; shooter-side
	# body is passed early. Net-front screen is the deadly one.
	var net_front: float = GoalieBehaviorRules.screen_occlusion_delay(
		Vector3.ZERO, Vector3(0, 0, 10), Vector3(0, 0, 10),
		PackedVector3Array([Vector3(0, 0, 8)]), _screen_cfg())
	var shooter_side: float = GoalieBehaviorRules.screen_occlusion_delay(
		Vector3.ZERO, Vector3(0, 0, 10), Vector3(0, 0, 10),
		PackedVector3Array([Vector3(0, 0, 2)]), _screen_cfg())
	assert_almost_eq(net_front, 0.8, 0.001)
	assert_almost_eq(shooter_side, 0.2, 0.001)
	assert_gt(net_front, shooter_side)

func test_screen_faster_shot_hides_less() -> void:
	# Same screener; a faster shot reaches (and clears) it sooner → shorter delay.
	var slow: float = GoalieBehaviorRules.screen_occlusion_delay(
		Vector3.ZERO, Vector3(0, 0, 10), Vector3(0, 0, 10),
		PackedVector3Array([Vector3(0, 0, 6)]), _screen_cfg())
	var fast: float = GoalieBehaviorRules.screen_occlusion_delay(
		Vector3.ZERO, Vector3(0, 0, 30), Vector3(0, 0, 10),
		PackedVector3Array([Vector3(0, 0, 6)]), _screen_cfg())
	assert_almost_eq(slow, 0.6, 0.001)
	assert_almost_eq(fast, 0.2, 0.001)

func test_screen_takes_worst_of_many() -> void:
	# A shooter-side body (short hide) and a net-front body (long hide) → the
	# longest-hiding screener wins.
	var d: float = GoalieBehaviorRules.screen_occlusion_delay(
		Vector3.ZERO, Vector3(0, 0, 10), Vector3(0, 0, 10),
		PackedVector3Array([Vector3(0.5, 0, 3), Vector3(0, 0, 8)]), _screen_cfg())
	assert_almost_eq(d, 0.8, 0.001)

func test_screen_stationary_puck_no_delay() -> void:
	# No shot velocity → no trajectory to occlude.
	var d: float = GoalieBehaviorRules.screen_occlusion_delay(
		Vector3.ZERO, Vector3.ZERO, Vector3(0, 0, 10),
		PackedVector3Array([Vector3(0, 0, 5)]), _screen_cfg())
	assert_eq(d, 0.0)

# ── unset_fraction / movement_read_penalty ────────────────────────────────────
# A set (stopped) goalie reads at the base delay; a moving / scrambling one reads
# late — and the two pay DIFFERENT costs (see movement_read_penalty). Test-local
# config: reference_speed 2.5, speed_delay 0.12, scramble_delay 0.12.

func _move_read_cfg() -> GoalieBehaviorRules.MovementReadConfig:
	var cfg := GoalieBehaviorRules.MovementReadConfig.new()
	cfg.reference_speed = 2.5
	cfg.speed_delay = 0.12
	cfg.scramble_delay = 0.12
	cfg.scramble_unset = 1.0
	return cfg

func test_move_read_set_goalie_no_penalty() -> void:
	var d: float = GoalieBehaviorRules.movement_read_penalty(0.0, false, _move_read_cfg())
	assert_eq(d, 0.0)

func test_move_read_scales_with_speed() -> void:
	# Half reference speed → half the max delay.
	var d: float = GoalieBehaviorRules.movement_read_penalty(1.25, false, _move_read_cfg())
	assert_almost_eq(d, 0.06, 0.001)

func test_move_read_caps_at_max() -> void:
	# Well over reference speed → clamped to speed_delay.
	var d: float = GoalieBehaviorRules.movement_read_penalty(6.0, false, _move_read_cfg())
	assert_almost_eq(d, 0.12, 0.001)

func test_move_read_scrambling_floors_unset() -> void:
	# Standing-up posture: full scramble penalty even when barely moving.
	var d: float = GoalieBehaviorRules.movement_read_penalty(0.1, true, _move_read_cfg())
	assert_almost_eq(d, 0.12, 0.001)

func test_move_read_scramble_and_speed_are_separate_costs() -> void:
	# A goalie travelling on his feet pays the (small) speed residual; one standing
	# up pays the scramble cost, which the drift model can't carry for him.
	var cfg: GoalieBehaviorRules.MovementReadConfig = _move_read_cfg()
	cfg.speed_delay = 0.04
	cfg.scramble_delay = 0.12
	assert_almost_eq(GoalieBehaviorRules.movement_read_penalty(6.0, false, cfg),
			0.04, 0.001, "fully travelling, on his feet")
	assert_almost_eq(GoalieBehaviorRules.movement_read_penalty(0.0, true, cfg),
			0.12, 0.001, "scrambling from a standstill")
	assert_almost_eq(GoalieBehaviorRules.movement_read_penalty(6.0, true, cfg),
			0.12, 0.001, "the larger of the two wins, they don't stack")

func test_move_read_faster_is_later() -> void:
	var slow: float = GoalieBehaviorRules.movement_read_penalty(0.5, false, _move_read_cfg())
	var fast: float = GoalieBehaviorRules.movement_read_penalty(2.0, false, _move_read_cfg())
	assert_gt(fast, slow)

func test_unset_fraction_is_the_normalized_penalty() -> void:
	# The travelling penalty is unset_fraction scaled by speed_delay — one shared
	# definition, so the prime gate and the read penalty can't disagree about the
	# same body.
	var cfg: GoalieBehaviorRules.MovementReadConfig = _move_read_cfg()
	assert_eq(GoalieBehaviorRules.unset_fraction(0.0, false, cfg), 0.0)
	assert_almost_eq(GoalieBehaviorRules.unset_fraction(1.25, false, cfg), 0.5, 0.001)
	assert_eq(GoalieBehaviorRules.unset_fraction(6.0, false, cfg), 1.0)
	assert_eq(GoalieBehaviorRules.unset_fraction(0.1, true, cfg), 1.0)
	assert_almost_eq(
			GoalieBehaviorRules.unset_fraction(1.25, false, cfg) * cfg.speed_delay,
			GoalieBehaviorRules.movement_read_penalty(1.25, false, cfg), 0.0001)

# ── chest_tracking_factor ─────────────────────────────────────────────────────

func test_chest_tracking_zero_in_tight() -> void:
	# At/under the near distance the goalie tracks the puck fully (factor 0).
	assert_almost_eq(GoalieBehaviorRules.chest_tracking_factor(2.5, 2.5, 7.0), 0.0, 0.0001)
	assert_almost_eq(GoalieBehaviorRules.chest_tracking_factor(1.0, 2.5, 7.0), 0.0, 0.0001)

func test_chest_tracking_full_at_range() -> void:
	# At/over the far distance the goalie plays the chest (factor 1).
	assert_almost_eq(GoalieBehaviorRules.chest_tracking_factor(7.0, 2.5, 7.0), 1.0, 0.0001)
	assert_almost_eq(GoalieBehaviorRules.chest_tracking_factor(12.0, 2.5, 7.0), 1.0, 0.0001)

func test_chest_tracking_ramps_linearly() -> void:
	# Midway between near and far → half.
	assert_almost_eq(GoalieBehaviorRules.chest_tracking_factor(4.75, 2.5, 7.0), 0.5, 0.0001)

func test_chest_tracking_degenerate_range_is_zero() -> void:
	# far <= near → no ramp, stay on full puck tracking.
	assert_almost_eq(GoalieBehaviorRules.chest_tracking_factor(10.0, 5.0, 5.0), 0.0, 0.0001)

# ── sealed_pad_toe_out ────────────────────────────────────────────────────────

func test_sealed_pad_full_toe_out_when_off_post() -> void:
	# Pad edge well short of the post → keep full toe-out for rebound steering.
	assert_almost_eq(GoalieBehaviorRules.sealed_pad_toe_out(0.20, 18.0, 0.06), 18.0, 0.0001)

func test_sealed_pad_squares_flat_on_post() -> void:
	# Edge on the post (shortfall 0) → toe-out fully squared to 0.
	assert_almost_eq(GoalieBehaviorRules.sealed_pad_toe_out(0.0, 18.0, 0.06), 0.0, 0.0001)

func test_sealed_pad_squares_past_post() -> void:
	# Edge past the post (negative shortfall) still fully squared, not negative.
	assert_almost_eq(GoalieBehaviorRules.sealed_pad_toe_out(-0.05, 18.0, 0.06), 0.0, 0.0001)

func test_sealed_pad_ramps_within_range() -> void:
	# Halfway into the square range → half the toe-out.
	assert_almost_eq(GoalieBehaviorRules.sealed_pad_toe_out(0.03, 18.0, 0.06), 9.0, 0.0001)

func test_sealed_pad_disabled_range_keeps_toe_out() -> void:
	# square_range 0 disables squaring entirely.
	assert_almost_eq(GoalieBehaviorRules.sealed_pad_toe_out(0.0, 18.0, 0.0), 18.0, 0.0001)

# ── reachable_lateral_distance ────────────────────────────────────────────────
# Standing-push kinematics: accelerate from rest at `accel` to `max_speed`,
# then hold. Mirrors _move_along_arc's move_toward ramp.

func test_reachable_distance_zero_time_is_zero() -> void:
	assert_almost_eq(GoalieBehaviorRules.reachable_lateral_distance(3.8, 14.0, 0.0), 0.0, 0.0001)

func test_reachable_distance_ramp_phase() -> void:
	# t=0.1s is inside the ramp (t_ramp = 3.8/14 ≈ 0.271): d = ½·14·0.1² = 0.07.
	assert_almost_eq(GoalieBehaviorRules.reachable_lateral_distance(3.8, 14.0, 0.1), 0.07, 0.0001)

func test_reachable_distance_past_ramp() -> void:
	# t=0.5s: d = v·t − v²/(2a) = 1.9 − 0.5157 ≈ 1.3843.
	assert_almost_eq(GoalieBehaviorRules.reachable_lateral_distance(3.8, 14.0, 0.5), 1.3843, 0.001)

func test_reachable_distance_zero_accel_is_instant_speed() -> void:
	# accel <= 0 → legacy instant-speed model (v·t).
	assert_almost_eq(GoalieBehaviorRules.reachable_lateral_distance(3.8, 0.0, 0.5), 1.9, 0.0001)

# ── is_beaten_wide ────────────────────────────────────────────────────────────
# Race to the tuck point (the post on the side the PUCK is being taken):
# beaten when the goalie's pad can't reach the seal spot before the puck's own
# lateral travel gets there — and only once the puck is past the goalie's
# standing sealing reach (the point of no return; a trailing puck commits
# nothing). Every velocity below is the PUCK's lateral velocity, not the
# carrier's body. Goal at z=+26.6 → direction_sign −1.

func _beaten_cfg() -> GoalieBehaviorRules.BeatenWideConfig:
	var cfg := GoalieBehaviorRules.BeatenWideConfig.new()
	cfg.goalie_lateral_speed = 3.8
	cfg.goalie_lateral_accel = 14.0
	cfg.reach_half_width = 0.42
	cfg.min_lateral_speed = 2.5
	cfg.max_threat_distance = 4.0
	return cfg

func test_beaten_by_fast_crease_cut_with_puck_leading() -> void:
	# Carrier at (0, 25.3) with the puck LED out at (0.9, 25.5) travelling
	# across at 6 m/s — past the centred goalie's 0.42 seal edge, essentially at
	# the post. The goalie needs ~1.55m of travel with no time left: the
	# genuine reach-around tuck in progress → sell out pads-first.
	assert_true(GoalieBehaviorRules.is_beaten_wide(
			Vector3(0.0, 0, 25.3), Vector3(0.9, 0, 25.5), 6.0,
			Vector3(0, 0, 24.85), 26.6, 0.0, -1, 0.915, _beaten_cfg()))

func test_beaten_by_forehand_backhand_on_a_straight_rush() -> void:
	# THE move this rule exists for, and the one a body-velocity read missed
	# entirely: the shooter drives STRAIGHT at the net (body barely moving
	# laterally) and pulls the puck forehand→backhand across the goalie at
	# 5 m/s. Nothing about the body says "drive"; the puck is past the sealing
	# reach and going around him, which is the only thing that scores.
	assert_true(GoalieBehaviorRules.is_beaten_wide(
			Vector3(0.1, 0, 25.4), Vector3(-0.7, 0, 25.6), -5.0,
			Vector3(0, 0, 24.85), 26.6, 0.0, -1, 0.915, _beaten_cfg()))

func test_puck_trailing_drive_is_not_beaten() -> void:
	# THE forehand-drag drive (the playtest exploit): the whole play cuts across
	# at 4 m/s but the puck trails on the far side at (−0.8). The wrap/cut-back
	# is still free — the goalie must stay up and shuffle across, not sell
	# out to the body.
	assert_false(GoalieBehaviorRules.is_beaten_wide(
			Vector3(0.2, 0, 25.5), Vector3(-0.8, 0, 25.6), 4.0,
			Vector3(0, 0, 24.85), 26.6, 0.0, -1, 0.915, _beaten_cfg()))

func test_not_beaten_below_drive_speed() -> void:
	# Puck past the seal edge but barely drifting across (2.0 < 2.5 m/s floor) —
	# a wide carry, not a puck being taken around him; stay up.
	assert_false(GoalieBehaviorRules.is_beaten_wide(
			Vector3(0.0, 0, 25.3), Vector3(0.9, 0, 25.5), 2.0,
			Vector3(0, 0, 24.85), 26.6, 0.0, -1, 0.915, _beaten_cfg()))

func test_not_beaten_when_already_sealing_post() -> void:
	# Goalie already at the post shoulder — his seal edge sits outside any
	# reachable puck line, and the pad covers the tuck point.
	assert_false(GoalieBehaviorRules.is_beaten_wide(
			Vector3(-1.5, 0, 25.3), Vector3(-0.5, 0, 25.4), 6.0,
			Vector3(0.8, 0, 26.35), 26.6, 0.0, -1, 0.915, _beaten_cfg()))

func test_beaten_by_reach_around_in_tight() -> void:
	# Doorstep carrier (0.3, 25.6) sliding across at 3.5 m/s, puck led to
	# (0.8, 25.8): 0.03s of puck travel to the post while the out-challenging
	# goalie is still ramping — the reach-around tuck.
	assert_true(GoalieBehaviorRules.is_beaten_wide(
			Vector3(0.3, 0, 25.6), Vector3(0.8, 0, 25.8), 3.5,
			Vector3(0, 0, 24.85), 26.6, 0.0, -1, 0.915, _beaten_cfg()))

func test_parked_wide_puck_does_not_drop_goalie() -> void:
	# Puck held out wide but not going anywhere (0.5 < 2.5 m/s) — stay up and
	# force the release. Note what does NOT protect him here: a dangle that
	# swings the puck across FAST does satisfy this rule, by design. Being
	# un-committed against a stickhandle is the caller's quiet-eye window
	# (lateral_commit_confirm_s), not a velocity floor — see the rule header.
	assert_false(GoalieBehaviorRules.is_beaten_wide(
			Vector3(0.3, 0, 25.6), Vector3(0.9, 0, 25.7), 0.5,
			Vector3(0, 0, 24.85), 26.6, 0.0, -1, 0.915, _beaten_cfg()))

func test_puck_inside_sealing_reach_is_not_beaten() -> void:
	# The transient a deke produces every time it starts: the puck is moving
	# fast across but is still inside the goalie's standing sealing reach
	# (0.3 < 0.42). Nothing has been taken around him yet — the point of no
	# return is what stops the first move of a stickhandle from committing him.
	assert_false(GoalieBehaviorRules.is_beaten_wide(
			Vector3(0.3, 0, 25.6), Vector3(0.3, 0, 25.7), 6.0,
			Vector3(0, 0, 24.85), 26.6, 0.0, -1, 0.915, _beaten_cfg()))

func test_fast_cut_far_from_goal_is_not_beaten() -> void:
	# A winger flying across the top of the slot (5.7m out) isn't a tuck threat.
	assert_false(GoalieBehaviorRules.is_beaten_wide(
			Vector3(-4.0, 0, 22.5), Vector3(-3.2, 0, 22.6), 8.0,
			Vector3(0, 0, 24.85), 26.6, 0.0, -1, 0.915, _beaten_cfg()))

func test_behind_goal_line_is_rvh_not_beaten() -> void:
	assert_false(GoalieBehaviorRules.is_beaten_wide(
			Vector3(1.5, 0, 27.0), Vector3(1.0, 0, 27.1), 6.0,
			Vector3(0, 0, 24.85), 26.6, 0.0, -1, 0.915, _beaten_cfg()))

func test_beaten_symmetric_for_minus_z_goal() -> void:
	# Mirror of the puck-leading fast cut on the −Z goal (direction_sign +1).
	assert_true(GoalieBehaviorRules.is_beaten_wide(
			Vector3(0.0, 0, -25.3), Vector3(-0.9, 0, -25.5), -6.0,
			Vector3(0, 0, -24.85), -26.6, 0.0, 1, 0.915, _beaten_cfg()))

# ── backdoor_depth_cap ────────────────────────────────────────────────────────
# Anticipatory depth: with a one-timer threat on the weak side, cap the
# challenge radius so the goalie can re-square to the new shot line within
# pass flight + release − react time. INF = no cap.

func _backdoor_cfg() -> GoalieBehaviorRules.BackdoorThreatConfig:
	var cfg := GoalieBehaviorRules.BackdoorThreatConfig.new()
	cfg.pass_speed = 14.0
	cfg.release_time = 0.15
	cfg.react_delay = 0.12
	cfg.goalie_lateral_speed = 3.8
	cfg.goalie_lateral_accel = 14.0
	cfg.max_shooter_distance = 9.0
	return cfg

func test_backdoor_shooter_caps_challenge_depth() -> void:
	# Carrier wide left (−4, 23), one-timer man at the right post (1.2, 25.2):
	# 5.65m pass → 0.43s of goalie movement → ~1.13m coverable, nearly
	# perpendicular lines → cap ≈ 1.13, well under the 1.75 aggressive chart.
	var cap: float = GoalieBehaviorRules.backdoor_depth_cap(
			Vector3(-4, 0, 23), Vector3(-4, 0, 23), Vector3(1.2, 0, 25.2),
			26.6, 0.0, -1, _backdoor_cfg())
	assert_almost_eq(cap, 1.131, 0.02)

func test_no_cap_without_live_shooter_behind_goal_line() -> void:
	var cap: float = GoalieBehaviorRules.backdoor_depth_cap(
			Vector3(-4, 0, 23), Vector3(-4, 0, 23), Vector3(1.2, 0, 27.2),
			26.6, 0.0, -1, _backdoor_cfg())
	assert_true(is_inf(cap), "shooter behind the goal line can't one-time — no cap")

func test_no_cap_for_shooter_outside_scoring_area() -> void:
	var cap: float = GoalieBehaviorRules.backdoor_depth_cap(
			Vector3(-4, 0, 23), Vector3(-4, 0, 23), Vector3(0, 0, 15.0),
			26.6, 0.0, -1, _backdoor_cfg())
	assert_true(is_inf(cap), "shooter 11.6m out is not a backdoor threat")

func test_no_cap_for_shooter_on_same_shot_line() -> void:
	# Shooter directly on the carrier's shot line (goal→(−2,24.8) is parallel
	# to goal→(−4,23)): challenging the carrier already covers him.
	var cap: float = GoalieBehaviorRules.backdoor_depth_cap(
			Vector3(-4, 0, 23), Vector3(-4, 0, 23), Vector3(-2, 0, 24.8),
			26.6, 0.0, -1, _backdoor_cfg())
	assert_true(is_inf(cap), "same-angle shooter needs no re-square — no cap")

func test_doorstep_criss_cross_pins_goalie_deep() -> void:
	# Royal-road pair at the doorstep: puck at (−1.5, 25.3), one-timer man at
	# (1.2, 25.2). 2.7m pass → goalie still ramping → cap ≈ 0.35.
	var cap: float = GoalieBehaviorRules.backdoor_depth_cap(
			Vector3(-1.5, 0, 25.3), Vector3(-1.5, 0, 25.3), Vector3(1.2, 0, 25.2),
			26.6, 0.0, -1, _backdoor_cfg())
	assert_almost_eq(cap, 0.348, 0.02)

func test_faster_assumed_pass_caps_deeper() -> void:
	var slow_cap: float = GoalieBehaviorRules.backdoor_depth_cap(
			Vector3(-4, 0, 23), Vector3(-4, 0, 23), Vector3(1.2, 0, 25.2),
			26.6, 0.0, -1, _backdoor_cfg())
	var fast_cfg: GoalieBehaviorRules.BackdoorThreatConfig = _backdoor_cfg()
	fast_cfg.pass_speed = 20.0
	var fast_cap: float = GoalieBehaviorRules.backdoor_depth_cap(
			Vector3(-4, 0, 23), Vector3(-4, 0, 23), Vector3(1.2, 0, 25.2),
			26.6, 0.0, -1, fast_cfg)
	assert_lt(fast_cap, slow_cap)

func test_unwinnable_race_caps_to_zero() -> void:
	# React delay longer than the whole play → no movement time → cap 0
	# (caller floors at depth_defensive).
	var cfg: GoalieBehaviorRules.BackdoorThreatConfig = _backdoor_cfg()
	cfg.react_delay = 0.5
	var cap: float = GoalieBehaviorRules.backdoor_depth_cap(
			Vector3(-1.5, 0, 25.3), Vector3(-1.5, 0, 25.3), Vector3(1.2, 0, 25.2),
			26.6, 0.0, -1, cfg)
	assert_almost_eq(cap, 0.0, 0.0001)

func test_backdoor_cap_symmetric_for_minus_z_goal() -> void:
	var cap: float = GoalieBehaviorRules.backdoor_depth_cap(
			Vector3(-4, 0, -23), Vector3(-4, 0, -23), Vector3(1.2, 0, -25.2),
			-26.6, 0.0, 1, _backdoor_cfg())
	assert_almost_eq(cap, 1.131, 0.02)

# ── rush_retreat (speed-matched backflow) ─────────────────────────────────────

func _rush_cfg() -> GoalieBehaviorRules.RushRetreatConfig:
	var cfg := GoalieBehaviorRules.RushRetreatConfig.new()
	cfg.engage_distance = 8.0
	cfg.mid_distance = 4.5
	cfg.arrive_distance = 1.5
	cfg.depth_engage = 1.75
	cfg.depth_mid = 1.30
	cfg.depth_arrive = 0.10
	return cfg

func test_rush_depth_holds_engage_depth_outside_range() -> void:
	assert_almost_eq(GoalieBehaviorRules.rush_retreat_depth(8.0, _rush_cfg()), 1.75, 0.0001)
	assert_almost_eq(GoalieBehaviorRules.rush_retreat_depth(12.0, _rush_cfg()), 1.75, 0.0001)

func test_rush_depth_hits_crease_top_at_hash_marks() -> void:
	# Mid anchor: attacker at the hash marks → heels back at crease-top depth.
	assert_almost_eq(GoalieBehaviorRules.rush_retreat_depth(4.5, _rush_cfg()), 1.30, 0.0001)

func test_rush_depth_reaches_arrive_depth_at_crease() -> void:
	assert_almost_eq(GoalieBehaviorRules.rush_retreat_depth(1.5, _rush_cfg()), 0.10, 0.0001)
	assert_almost_eq(GoalieBehaviorRules.rush_retreat_depth(0.5, _rush_cfg()), 0.10, 0.0001)

func test_rush_depth_interpolates_between_anchors() -> void:
	# Halfway through each segment sits halfway between its anchor depths.
	assert_almost_eq(GoalieBehaviorRules.rush_retreat_depth(6.25, _rush_cfg()), 1.525, 0.0001)
	assert_almost_eq(GoalieBehaviorRules.rush_retreat_depth(3.0, _rush_cfg()), 0.70, 0.0001)

func test_rush_rate_is_slope_times_closing_speed() -> void:
	# Far segment slope: (1.75-1.30)/3.5 per metre; at 8 m/s closing the
	# retreat rate tracks the curve exactly.
	var expected_far: float = (1.75 - 1.30) / 3.5 * 8.0
	assert_almost_eq(GoalieBehaviorRules.rush_retreat_rate(6.0, 8.0, _rush_cfg()), expected_far, 0.0001)
	# Near segment is steeper: (1.30-0.10)/3.0 per metre.
	var expected_near: float = (1.30 - 0.10) / 3.0 * 8.0
	assert_almost_eq(GoalieBehaviorRules.rush_retreat_rate(3.0, 8.0, _rush_cfg()), expected_near, 0.0001)

func test_rush_rate_scales_with_closing_speed() -> void:
	var slow: float = GoalieBehaviorRules.rush_retreat_rate(3.0, 2.0, _rush_cfg())
	var fast: float = GoalieBehaviorRules.rush_retreat_rate(3.0, 8.0, _rush_cfg())
	assert_almost_eq(fast, slow * 4.0, 0.0001)

func test_rush_rate_zero_outside_curve_or_not_closing() -> void:
	assert_almost_eq(GoalieBehaviorRules.rush_retreat_rate(9.0, 8.0, _rush_cfg()), 0.0, 0.0001)
	assert_almost_eq(GoalieBehaviorRules.rush_retreat_rate(1.0, 8.0, _rush_cfg()), 0.0, 0.0001)
	assert_almost_eq(GoalieBehaviorRules.rush_retreat_rate(3.0, -1.0, _rush_cfg()), 0.0, 0.0001)

# ── cross_crease_race_lost (drive vs drop-and-slide fork) ─────────────────────

func test_cross_crease_race_won_when_already_covering() -> void:
	# Crossing point inside standing pad coverage → nothing to race.
	assert_false(GoalieBehaviorRules.cross_crease_race_lost(
			0.3, -2.0, 12.0, 0.0, 0.42, 0.15, 3.8, 14.0))

func test_cross_crease_race_lost_on_hard_royal_road_pass() -> void:
	# Hard pass (16 m/s) crossing 3 m to the far post while the goalie sits a
	# full net-width away: flight ~0.19 s + 0.15 s swing covers only ~0.77 m
	# from rest against ~1.28 m of needed travel → pads-first slide.
	assert_true(GoalieBehaviorRules.cross_crease_race_lost(
			0.9, -2.1, 16.0, -0.8, 0.42, 0.15, 3.8, 14.0))

func test_cross_crease_race_won_against_slow_telegraphed_feed() -> void:
	# Same geometry but a soft 6 m/s feed: flight ~0.5 s + swing buys the
	# standing push time to arrive set → stay on the feet.
	assert_false(GoalieBehaviorRules.cross_crease_race_lost(
			0.9, -2.1, 6.0, -0.8, 0.42, 0.15, 3.8, 14.0))

func test_cross_crease_received_pass_races_on_release_swing_alone() -> void:
	# Puck already at the crossing (received — vx decayed): only the release
	# swing remains. A goalie across the crease loses; one on top of it wins.
	assert_true(GoalieBehaviorRules.cross_crease_race_lost(
			0.9, 0.9, 0.5, -0.8, 0.42, 0.15, 3.8, 14.0))
	assert_false(GoalieBehaviorRules.cross_crease_race_lost(
			0.9, 0.9, 0.5, 0.6, 0.42, 0.15, 3.8, 14.0))

# ── sweep_lane_blocked (lane-aware clear) ─────────────────────────────────────

func _lane_cfg() -> GoalieBehaviorRules.SweepLaneConfig:
	var cfg := GoalieBehaviorRules.SweepLaneConfig.new()
	cfg.stick_reach = 1.3
	cfg.reaction_delay = 0.08
	cfg.close_speed = 4.5
	cfg.max_flight_time = 1.0
	return cfg

func test_lane_clear_with_no_opponents() -> void:
	assert_false(GoalieBehaviorRules.sweep_lane_blocked(
			Vector3(0, 0, 25), Vector3(7, 0, -3.5), PackedVector3Array(), _lane_cfg()))

func test_opponent_on_the_exit_lane_blocks() -> void:
	# Body dead on the sweep line 2 m downrange — a stick gets on it easily.
	var opps := PackedVector3Array([Vector3(2.0, 0, 25.0)])
	assert_true(GoalieBehaviorRules.sweep_lane_blocked(
			Vector3(0, 0, 25), Vector3(7, 0, 0), opps, _lane_cfg()))

func test_opponent_behind_the_exit_cannot_block() -> void:
	var opps := PackedVector3Array([Vector3(-2.0, 0, 25.0)])
	assert_false(GoalieBehaviorRules.sweep_lane_blocked(
			Vector3(0, 0, 25), Vector3(7, 0, 0), opps, _lane_cfg()))

func test_opponent_beside_the_lane_needs_time_to_close() -> void:
	# 2.4 m off the line at 1 m downrange: the puck passes in ~0.14 s — reach
	# 1.3 + 4.5·(0.14−0.08) ≈ 1.57 < 2.4 → clear. The same opponent at 6 m
	# downrange has ~0.86 s to close (reach ≈ 4.8) → blocked.
	var near_opp := PackedVector3Array([Vector3(1.0, 0, 27.4)])
	assert_false(GoalieBehaviorRules.sweep_lane_blocked(
			Vector3(0, 0, 25), Vector3(7, 0, 0), near_opp, _lane_cfg()))
	var far_opp := PackedVector3Array([Vector3(6.0, 0, 27.4)])
	assert_true(GoalieBehaviorRules.sweep_lane_blocked(
			Vector3(0, 0, 25), Vector3(7, 0, 0), far_opp, _lane_cfg()))

func test_opponent_beyond_flight_window_ignored() -> void:
	# 10 m downrange at 7 m/s ≈ 1.4 s > max_flight_time — out of the window.
	var opps := PackedVector3Array([Vector3(10.0, 0, 25.0)])
	assert_false(GoalieBehaviorRules.sweep_lane_blocked(
			Vector3(0, 0, 25), Vector3(7, 0, 0), opps, _lane_cfg()))

# ── compute_clear_velocity forced_side ────────────────────────────────────────

func test_clear_forced_side_overrides_natural_pick() -> void:
	# Puck on +x would naturally sweep +x; forcing -1 flips the corner.
	var v: Vector3 = GoalieBehaviorRules.compute_clear_velocity(
			Vector3(1.0, 0, 25), 0.0, -1, 1.0, 0.5, 7.0, 0.15, 1.0, -1.0)
	assert_lt(v.x, 0.0, "forced side wins over the puck-offset pick")
	assert_almost_eq(v.length(), 7.0, 0.001)

func test_clear_unforced_keeps_natural_pick() -> void:
	var v: Vector3 = GoalieBehaviorRules.compute_clear_velocity(
			Vector3(1.0, 0, 25), 0.0, -1, 1.0, 0.5, 7.0, 0.15, 1.0, 0.0)
	assert_gt(v.x, 0.0)

# ── Behind-net puck play (tier-1 conservative rim stop) ───────────────────────

func test_travel_time_inverts_reachable_distance() -> void:
	# travel_time_from_rest is the inverse of reachable_lateral_distance: the
	# distance reachable in t takes exactly t to travel.
	var t_mid: float = 0.2   # inside the accel ramp (ramp ends at 3.8/14 ≈ 0.27)
	var d_mid: float = GoalieBehaviorRules.reachable_lateral_distance(3.8, 14.0, t_mid)
	assert_almost_eq(GoalieBehaviorRules.travel_time_from_rest(d_mid, 3.8, 14.0), t_mid, 0.001)
	var t_long: float = 1.5  # past the ramp, cruising
	var d_long: float = GoalieBehaviorRules.reachable_lateral_distance(3.8, 14.0, t_long)
	assert_almost_eq(GoalieBehaviorRules.travel_time_from_rest(d_long, 3.8, 14.0), t_long, 0.001)

func test_puck_play_race_needs_full_trip_plus_margin() -> void:
	# t_play = 1.0 out + 0.25 beat + 1.0 back = 2.25 s; margin 0.9 → the
	# sprinting opponent must be > 3.15 s away (34.7 m at 11 m/s).
	assert_true(GoalieBehaviorRules.puck_play_race_clear(
			1.0, 1.0, 0.25, 40.0, 11.0, 0.9), "distant forecheck → safe to go")
	assert_false(GoalieBehaviorRules.puck_play_race_clear(
			1.0, 1.0, 0.25, 30.0, 11.0, 0.9), "forecheck inside the margin → stay home")

func test_puck_play_abort_margin_is_a_real_hysteresis() -> void:
	# A pressure distance that passes the smaller abort margin but fails the
	# go margin: mid-trip the goalie continues, but he would never have LEFT
	# for it — bail-early hysteresis in the safe direction.
	var t_out: float = 1.0
	var t_back: float = 1.0
	assert_false(GoalieBehaviorRules.puck_play_race_clear(
			t_out, t_back, 0.25, 31.0, 11.0, 0.9), "wouldn't GO at this pressure")
	assert_true(GoalieBehaviorRules.puck_play_race_clear(
			t_out, t_back, 0.25, 31.0, 11.0, 0.45), "…but mid-trip it isn't a bail yet")

func test_cannot_beat_the_rim_means_no_go() -> void:
	# The stop only works if the goalie arrives SET before the puck: a rim
	# 4 m out at 10 m/s (0.4 s) vs a 0.5 s skate + 0.15 s set → no-go.
	assert_false(GoalieBehaviorRules.can_beat_puck_to_stop(0.5, 4.0, 10.0, 0.15))
	assert_true(GoalieBehaviorRules.can_beat_puck_to_stop(0.5, 8.0, 10.0, 0.15))


# ── Puck at rest ON the goalie (the pad-shelf smother) ────────────────────────
# Window: off the sweepable ice (min_height) but inside the pad/lap shelf
# envelope (max_height), within the butterfly's horizontal span, not clearly
# live. Args: puck_pos, puck_speed, goalie_pos, min_height, max_height,
# body_radius, max_speed — the controller passes clear_max_height 0.12,
# 0.6, 0.7, clear_max_puck_speed 4.0.

func test_puck_on_pad_shelf_reads_as_resting() -> void:
	# The observed bug case: a deadened save sitting on a butterfly pad top
	# (~0.3 m up, ~0.3 m off-center), dead still.
	assert_true(GoalieBehaviorRules.puck_resting_on_goalie(
			Vector3(0.3, 0.3, 24.0), 0.0, Vector3(0.0, 0.0, 24.0),
			0.12, 0.6, 0.7, 4.0))

func test_puck_on_the_ice_is_the_sweeps_job() -> void:
	# On-ice pucks stay with the crease sweep — below min_height is not a rest.
	assert_false(GoalieBehaviorRules.puck_resting_on_goalie(
			Vector3(0.3, 0.0175, 24.0), 0.0, Vector3(0.0, 0.0, 24.0),
			0.12, 0.6, 0.7, 4.0))

func test_puck_above_the_shelf_envelope_is_not_pinnable() -> void:
	assert_false(GoalieBehaviorRules.puck_resting_on_goalie(
			Vector3(0.0, 0.8, 24.0), 0.0, Vector3(0.0, 0.0, 24.0),
			0.12, 0.6, 0.7, 4.0))

func test_puck_outside_the_body_footprint_is_not_supported() -> void:
	# Off the ice but a meter to the side — nothing there to rest on; this is
	# a flying puck, not a supported one.
	assert_false(GoalieBehaviorRules.puck_resting_on_goalie(
			Vector3(1.0, 0.3, 24.0), 0.0, Vector3(0.0, 0.0, 24.0),
			0.12, 0.6, 0.7, 4.0))

func test_live_puck_crossing_the_body_is_not_resting() -> void:
	assert_false(GoalieBehaviorRules.puck_resting_on_goalie(
			Vector3(0.0, 0.3, 24.0), 6.0, Vector3(0.0, 0.0, 24.0),
			0.12, 0.6, 0.7, 4.0))
