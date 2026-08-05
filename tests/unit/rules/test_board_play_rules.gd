extends GutTest

# BoardPlayRules — the carrier's board-shield stance — plus
# GameRules.ray_to_rink_inner, the reach geometry it and the blade IK share.

const EPS: float = 0.001

# ── ray_to_rink_inner ────────────────────────────────────────────────────

func test_ray_from_center_hits_the_side_wall_at_half_width() -> void:
	var d: float = GameRules.ray_to_rink_inner(Vector2.ZERO, Vector2(1.0, 0.0))
	assert_almost_eq(d, GameRules.INNER_HALF_WIDTH, EPS, "straight to the side boards")

func test_ray_from_center_hits_the_end_wall_at_half_length() -> void:
	var d: float = GameRules.ray_to_rink_inner(Vector2.ZERO, Vector2(0.0, 1.0))
	assert_almost_eq(d, GameRules.INNER_HALF_LENGTH, EPS, "straight to the end boards")

func test_ray_agrees_with_the_boundary_clamp_everywhere() -> void:
	# The single property that matters: the point the ray lands on must be ON
	# the boundary clamp_to_rink_inner projects onto, so a reach limited by this
	# stops exactly where the blade clamp would have caught it.
	for ox: float in [-11.0, -4.0, 0.0, 4.0, 11.0]:
		for oz: float in [-27.0, -10.0, 0.0, 10.0, 27.0]:
			var origin := Vector2(ox, oz)
			if GameRules.clamp_to_rink_inner(origin) != origin:
				continue  # seeded outside the rink; not an interior ray
			for deg: int in range(0, 360, 15):
				var rad: float = deg_to_rad(float(deg))
				var dir := Vector2(cos(rad), sin(rad))
				var t: float = GameRules.ray_to_rink_inner(origin, dir)
				var hit: Vector2 = origin + dir * t
				assert_almost_eq(GameRules.clamp_to_rink_inner(hit).distance_to(hit), 0.0, 0.01,
						"exit lands on the boundary from (%.0f, %.0f) at %d°" % [ox, oz, deg])
				# A hair short is strictly inside; a hair long is strictly outside.
				var inside: Vector2 = origin + dir * (t - 0.05)
				assert_almost_eq(GameRules.clamp_to_rink_inner(inside).distance_to(inside), 0.0, EPS,
						"just short of the exit is still inside from (%.0f, %.0f) at %d°"
								% [ox, oz, deg])

func test_ray_into_a_corner_stops_at_the_arc_not_the_box_corner() -> void:
	# Aimed at the corner from center ice: the rounded boards are nearer than the
	# rectangle's corner would be.
	var corner := Vector2(GameRules.INNER_HALF_WIDTH, GameRules.INNER_HALF_LENGTH)
	var dir: Vector2 = corner.normalized()
	var t: float = GameRules.ray_to_rink_inner(Vector2.ZERO, dir)
	assert_lt(t, corner.length(), "arc is nearer than the square corner")
	var hit: Vector2 = dir * t
	var arc_center := Vector2(GameRules.CORNER_CENTER_X, GameRules.CORNER_CENTER_Z)
	assert_almost_eq(hit.distance_to(arc_center), GameRules.INNER_CORNER_RADIUS, 0.01,
			"exit sits on the corner arc")

func test_ray_with_a_margin_stops_short_by_that_margin() -> void:
	var plain: float = GameRules.ray_to_rink_inner(Vector2.ZERO, Vector2(1.0, 0.0))
	var inset: float = GameRules.ray_to_rink_inner(Vector2.ZERO, Vector2(1.0, 0.0), 0.5)
	assert_almost_eq(plain - inset, 0.5, EPS, "margin insets the boundary uniformly")

func test_degenerate_direction_is_unconstrained() -> void:
	assert_true(is_inf(GameRules.ray_to_rink_inner(Vector2.ZERO, Vector2.ZERO)),
			"no direction, no limit")

func test_ray_from_against_the_boards_is_near_zero() -> void:
	var origin := Vector2(GameRules.INNER_HALF_WIDTH - 0.01, 0.0)
	var t: float = GameRules.ray_to_rink_inner(origin, Vector2(1.0, 0.0))
	assert_almost_eq(t, 0.01, EPS, "nowhere left to reach")

# ── board_proximity ──────────────────────────────────────────────────────

func test_center_ice_is_clear_of_the_boards() -> void:
	assert_eq(BoardPlayRules.board_proximity(Vector2.ZERO, 1.1), Vector2.ZERO,
			"nothing within the probe")

func test_proximity_normal_points_inward_off_the_side_wall() -> void:
	var pos := Vector2(GameRules.INNER_HALF_WIDTH - 0.4, 0.0)
	var p: Vector2 = BoardPlayRules.board_proximity(pos, 1.1)
	assert_almost_eq(p.normalized().x, -1.0, EPS, "normal points back toward center ice")
	assert_almost_eq(p.length(), (1.1 - 0.4) / 1.1, EPS, "closeness ramps with the gap")

func test_proximity_saturates_against_the_wall() -> void:
	var pos := Vector2(GameRules.INNER_HALF_WIDTH, 0.0)
	assert_almost_eq(BoardPlayRules.board_proximity(pos, 1.1).length(), 1.0, EPS,
			"flush on the boards is full closeness")

func test_proximity_follows_the_rounded_corner() -> void:
	# In a corner the normal is radial from the arc center, not axis-aligned.
	var arc_center := Vector2(GameRules.CORNER_CENTER_X, GameRules.CORNER_CENTER_Z)
	var radial: Vector2 = Vector2(1.0, 1.0).normalized()
	var pos: Vector2 = arc_center + radial * (GameRules.INNER_CORNER_RADIUS - 0.3)
	var p: Vector2 = BoardPlayRules.board_proximity(pos, 1.1)
	assert_almost_eq(p.normalized().angle_to(-radial), 0.0, 0.01,
			"corner normal is radial from the arc center")

# ── board_shield_facing ──────────────────────────────────────────────────

func _side_wall_proximity(closeness: float) -> Vector2:
	return Vector2(-1.0, 0.0) * closeness  # +X boards, inward = −X

func test_facing_into_the_boards_turns_toward_parallel() -> void:
	var desired := Vector2(1.0, 0.0)  # straight into the +X boards
	var out: Vector2 = BoardPlayRules.board_shield_facing(
			desired, _side_wall_proximity(1.0), deg_to_rad(55.0))
	assert_almost_eq(absf(out.angle_to(Vector2(1.0, 0.0))), deg_to_rad(55.0), 0.01,
			"turns by the full cap when flush on the wall")

func test_shield_stops_at_parallel() -> void:
	# Cap wide enough to overshoot: the turn must still stop square to the wall,
	# never rotate the skater to face away from the play.
	var desired := Vector2(1.0, 0.05).normalized()
	var out: Vector2 = BoardPlayRules.board_shield_facing(
			desired, _side_wall_proximity(1.0), deg_to_rad(180.0))
	assert_almost_eq(out.x, 0.0, 0.01, "ends parallel to the boards")
	assert_gt(out.y, 0.0, "keeps the along-wall side it already leaned to")

func test_shield_picks_the_near_along_wall_direction() -> void:
	var up: Vector2 = BoardPlayRules.board_shield_facing(
			Vector2(1.0, 0.3).normalized(), _side_wall_proximity(1.0), deg_to_rad(180.0))
	var down: Vector2 = BoardPlayRules.board_shield_facing(
			Vector2(1.0, -0.3).normalized(), _side_wall_proximity(1.0), deg_to_rad(180.0))
	assert_gt(up.y, 0.0, "leaning +Z shields facing +Z")
	assert_lt(down.y, 0.0, "leaning −Z shields facing −Z")

func test_facing_away_from_the_boards_is_never_fought() -> void:
	var desired := Vector2(-1.0, 0.0)  # skating out of the corner
	var out: Vector2 = BoardPlayRules.board_shield_facing(
			desired, _side_wall_proximity(1.0), deg_to_rad(55.0))
	assert_eq(out, desired, "escape route is left alone")

func test_shield_ramps_with_closeness() -> void:
	var desired := Vector2(1.0, 0.0)
	var far: Vector2 = BoardPlayRules.board_shield_facing(
			desired, _side_wall_proximity(0.25), deg_to_rad(55.0))
	var near: Vector2 = BoardPlayRules.board_shield_facing(
			desired, _side_wall_proximity(0.75), deg_to_rad(55.0))
	assert_lt(absf(far.angle_to(desired)), absf(near.angle_to(desired)),
			"closer to the wall turns further")

func test_shield_is_inert_with_no_proximity_or_no_cap() -> void:
	var desired := Vector2(1.0, 0.0)
	assert_eq(BoardPlayRules.board_shield_facing(desired, Vector2.ZERO, deg_to_rad(55.0)),
			desired, "open ice leaves facing alone")
	assert_eq(BoardPlayRules.board_shield_facing(desired, _side_wall_proximity(1.0), 0.0),
			desired, "a zero cap disables the shield")

func test_shield_output_stays_normalized() -> void:
	for deg: int in range(0, 360, 20):
		var rad: float = deg_to_rad(float(deg))
		var out: Vector2 = BoardPlayRules.board_shield_facing(
				Vector2(cos(rad), sin(rad)), _side_wall_proximity(0.6), deg_to_rad(55.0))
		assert_almost_eq(out.length(), 1.0, EPS, "unit facing at %d°" % deg)
