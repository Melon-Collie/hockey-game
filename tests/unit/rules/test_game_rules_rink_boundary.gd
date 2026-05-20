extends GutTest

# GameRules.clamp_to_rink_inner — analytic rink boundary projection.
#
# Constants under test:
#   INNER_HALF_WIDTH    = 12.85  (13.0 - 0.15)
#   INNER_HALF_LENGTH   = 29.85  (30.0 - 0.15)
#   INNER_CORNER_RADIUS =  8.35  ( 8.5 - 0.15)
#   CORNER_CENTER_X     =  4.5   (12.85 - 8.35)
#   CORNER_CENTER_Z     = 21.5   (29.85 - 8.35)

const TOLERANCE: float = 0.001

# ── Points already inside ─────────────────────────────────────────────────────

func test_center_ice_unchanged() -> void:
	var result: Vector2 = GameRules.clamp_to_rink_inner(Vector2(0.0, 0.0))
	assert_almost_eq(result.x, 0.0, TOLERANCE, "center x")
	assert_almost_eq(result.y, 0.0, TOLERANCE, "center z")

func test_point_well_inside_straight_region_unchanged() -> void:
	var result: Vector2 = GameRules.clamp_to_rink_inner(Vector2(5.0, 10.0))
	assert_almost_eq(result.x, 5.0, TOLERANCE, "x unchanged")
	assert_almost_eq(result.y, 10.0, TOLERANCE, "z unchanged")

func test_point_inside_corner_arc_unchanged() -> void:
	# (10, 25) is in the corner quadrant (|x|>4.5, |z|>21.5).
	# dist from corner center (4.5, 21.5) = sqrt(5.5^2 + 3.5^2) ≈ 6.52 < 8.35
	var result: Vector2 = GameRules.clamp_to_rink_inner(Vector2(10.0, 25.0))
	assert_almost_eq(result.x, 10.0, TOLERANCE, "x unchanged")
	assert_almost_eq(result.y, 25.0, TOLERANCE, "z unchanged")

# ── Side wall (X axis) ────────────────────────────────────────────────────────

func test_outside_positive_side_wall_clamped() -> void:
	var result: Vector2 = GameRules.clamp_to_rink_inner(Vector2(15.0, 0.0))
	assert_almost_eq(result.x, GameRules.INNER_HALF_WIDTH, TOLERANCE, "x clamped to inner wall")
	assert_almost_eq(result.y, 0.0, TOLERANCE, "z unchanged")

func test_outside_negative_side_wall_clamped() -> void:
	var result: Vector2 = GameRules.clamp_to_rink_inner(Vector2(-15.0, 0.0))
	assert_almost_eq(result.x, -GameRules.INNER_HALF_WIDTH, TOLERANCE, "x clamped to inner wall")
	assert_almost_eq(result.y, 0.0, TOLERANCE, "z unchanged")

func test_on_side_wall_boundary_unchanged() -> void:
	var result: Vector2 = GameRules.clamp_to_rink_inner(Vector2(GameRules.INNER_HALF_WIDTH, 0.0))
	assert_almost_eq(result.x, GameRules.INNER_HALF_WIDTH, TOLERANCE, "x on boundary")
	assert_almost_eq(result.y, 0.0, TOLERANCE, "z unchanged")

# ── End wall (Z axis) ─────────────────────────────────────────────────────────

func test_outside_positive_end_wall_clamped() -> void:
	var result: Vector2 = GameRules.clamp_to_rink_inner(Vector2(0.0, 35.0))
	assert_almost_eq(result.x, 0.0, TOLERANCE, "x unchanged")
	assert_almost_eq(result.y, GameRules.INNER_HALF_LENGTH, TOLERANCE, "z clamped to inner wall")

func test_outside_negative_end_wall_clamped() -> void:
	var result: Vector2 = GameRules.clamp_to_rink_inner(Vector2(0.0, -35.0))
	assert_almost_eq(result.x, 0.0, TOLERANCE, "x unchanged")
	assert_almost_eq(result.y, -GameRules.INNER_HALF_LENGTH, TOLERANCE, "z clamped to inner wall")

# ── Corner arc ────────────────────────────────────────────────────────────────

func test_outside_corner_arc_projected_onto_arc() -> void:
	# (11, 27): dx=6.5, dz=5.5 from corner center (4.5, 21.5),
	# dist ≈ 8.51 > INNER_CORNER_RADIUS (8.35) → outside
	var result: Vector2 = GameRules.clamp_to_rink_inner(Vector2(11.0, 27.0))
	var dist_from_center: float = result.distance_to(
		Vector2(GameRules.CORNER_CENTER_X, GameRules.CORNER_CENTER_Z))
	assert_almost_eq(dist_from_center, GameRules.INNER_CORNER_RADIUS, TOLERANCE,
		"result lies on the arc")
	assert_gt(result.x, 0.0, "result in positive X quadrant")
	assert_gt(result.y, 0.0, "result in positive Z quadrant")

func test_outside_corner_arc_negative_quadrant_projected() -> void:
	var result: Vector2 = GameRules.clamp_to_rink_inner(Vector2(-11.0, -27.0))
	var dist_from_center: float = result.distance_to(
		Vector2(-GameRules.CORNER_CENTER_X, -GameRules.CORNER_CENTER_Z))
	assert_almost_eq(dist_from_center, GameRules.INNER_CORNER_RADIUS, TOLERANCE,
		"result lies on the arc in negative quadrant")

func test_outside_corner_arc_mixed_quadrant_projected() -> void:
	var result: Vector2 = GameRules.clamp_to_rink_inner(Vector2(-11.0, 27.0))
	var dist_from_center: float = result.distance_to(
		Vector2(-GameRules.CORNER_CENTER_X, GameRules.CORNER_CENTER_Z))
	assert_almost_eq(dist_from_center, GameRules.INNER_CORNER_RADIUS, TOLERANCE,
		"result lies on the arc")

func test_point_on_corner_arc_boundary_unchanged() -> void:
	# Point exactly on the arc: corner_center + (1, 0) * INNER_CORNER_RADIUS
	var on_arc := Vector2(
		GameRules.CORNER_CENTER_X + GameRules.INNER_CORNER_RADIUS,
		GameRules.CORNER_CENTER_Z)
	var result: Vector2 = GameRules.clamp_to_rink_inner(on_arc)
	assert_almost_eq(result.x, on_arc.x, TOLERANCE, "x on arc boundary unchanged")
	assert_almost_eq(result.y, on_arc.y, TOLERANCE, "z on arc boundary unchanged")

func test_corner_projection_preserves_direction() -> void:
	# The projected point should be along the same radial from the corner center.
	var p := Vector2(11.0, 27.0)
	var result: Vector2 = GameRules.clamp_to_rink_inner(p)
	var center := Vector2(GameRules.CORNER_CENTER_X, GameRules.CORNER_CENTER_Z)
	var dir_in: Vector2 = (p - center).normalized()
	var dir_out: Vector2 = (result - center).normalized()
	assert_almost_eq(dir_out.x, dir_in.x, TOLERANCE, "projection direction preserved x")
	assert_almost_eq(dir_out.y, dir_in.y, TOLERANCE, "projection direction preserved z")


# ── nearest_faceoff_dot ─────────────────────────────────────────────────────
# Five dots total: center ice plus four end-zone dots at NHL spec positions
# (END_ZONE_FACEOFF_DOT_X by ±ICING_FACEOFF_DOT_Z). For any rink-interior point
# we expect the dot in the same quadrant (or center if the point is closer to
# it than to any corner dot).

func test_nearest_dot_at_center_returns_center() -> void:
	assert_eq(GameRules.nearest_faceoff_dot(Vector2.ZERO), GameRules.CENTER_ICE_DOT)

func test_nearest_dot_for_each_corner() -> void:
	# Pick a point inside each end-zone quadrant and assert we get that dot.
	var x: float = GameRules.END_ZONE_FACEOFF_DOT_X
	var z: float = GameRules.ICING_FACEOFF_DOT_Z
	assert_eq(GameRules.nearest_faceoff_dot(Vector2( 5.0,  25.0)), Vector2( x,  z))
	assert_eq(GameRules.nearest_faceoff_dot(Vector2(-5.0,  25.0)), Vector2(-x,  z))
	assert_eq(GameRules.nearest_faceoff_dot(Vector2( 5.0, -25.0)), Vector2( x, -z))
	assert_eq(GameRules.nearest_faceoff_dot(Vector2(-5.0, -25.0)), Vector2(-x, -z))

func test_nearest_dot_near_center_returns_center() -> void:
	# A point in the neutral zone is closer to center than to any end-zone dot.
	assert_eq(GameRules.nearest_faceoff_dot(Vector2(3.0, 5.0)), GameRules.CENTER_ICE_DOT)
