extends GutTest

# ShotArcRules is a pure function. Calibration checks: a lofted arc peaks at
# v_y²/2g above the launch height and comes back to the ice, a FLAT shot stays
# grounded and decelerates at the Coulomb rate, the path truncates at the
# boards, and the buffer bound / degenerate inputs hold.

const ICE_Y: float = 0.0175


func _fill(origin: Vector3, vel: Vector3, capacity: int = 256) -> Dictionary:
	var buf := PackedVector3Array()
	buf.resize(capacity)
	var n: int = ShotArcRules.fill_arc(origin, vel, buf, ICE_Y)
	return {"points": buf, "count": n}


func test_lofted_apex_matches_ballistics() -> void:
	# HIGH loft's fixed vertical launch speed (loft_vertical_speed_high default).
	var vy: float = 4.65
	var arc: Dictionary = _fill(Vector3(0, ICE_Y, 0), Vector3(20.0, vy, 0.0))
	var points: PackedVector3Array = arc.points
	var max_y: float = -INF
	for i: int in range(arc.count):
		max_y = maxf(max_y, points[i].y)
	var expected_apex: float = ICE_Y + vy * vy / (2.0 * GameRules.GRAVITY_M_S2)
	# Discrete semi-implicit Euler samples a hair under the closed-form apex.
	assert_almost_eq(max_y, expected_apex, 0.06,
			"apex must sit at v_y²/2g above the launch height")


func test_lofted_shot_returns_to_ice_at_ballistic_range() -> void:
	# LOW loft (saucer) at pass pace: flight time 2·v_y/g, range = v_xz · t.
	var vy: float = 2.2
	var vxz: float = 15.0
	var arc: Dictionary = _fill(Vector3(0, ICE_Y, 0), Vector3(vxz, vy, 0.0))
	var points: PackedVector3Array = arc.points
	var landing_x: float = -1.0
	for i: int in range(1, arc.count):
		if points[i].y <= ICE_Y + 0.0001:
			landing_x = points[i].x
			break
	var expected_range: float = vxz * (2.0 * vy / GameRules.GRAVITY_M_S2)
	assert_gt(landing_x, 0.0, "a lofted shot must come back down to the ice")
	assert_almost_eq(landing_x, expected_range, 0.5,
			"touchdown must land at the ballistic range")


func test_flat_shot_stays_grounded_and_decelerates() -> void:
	var arc: Dictionary = _fill(Vector3(0, ICE_Y, 0), Vector3(14.0, 0.0, 0.0))
	var points: PackedVector3Array = arc.points
	assert_gt(arc.count, 10, "a flat shot must produce a slide tail")
	for i: int in range(arc.count):
		assert_almost_eq(points[i].y, ICE_Y, 0.0001,
				"FLAT never leaves the ice")
	# Segment lengths shrink as Coulomb friction bleeds speed.
	var first_seg: float = points[0].distance_to(points[1])
	var last_seg: float = points[arc.count - 2].distance_to(points[arc.count - 1])
	assert_lt(last_seg, first_seg, "the slide must decelerate")


func test_slide_tail_is_time_bounded() -> void:
	# 0.6 s at 60 Hz = 36 slide steps (+ origin). A fast flat shot must not
	# fill the whole buffer — the tail is a hint, not a route.
	var arc: Dictionary = _fill(Vector3(0, ICE_Y, 0), Vector3(20.0, 0.0, 0.0))
	var expected_steps: int = int(ShotArcRules.DEFAULT_SLIDE_TAIL_S / ShotArcRules.DEFAULT_DT)
	assert_lte(arc.count, expected_steps + 2, "slide tail must cut off after its budget")


func test_truncates_at_boards() -> void:
	# Fired point-blank into the +X boards: the path must end ON the boundary,
	# not pass through or pile up outside it.
	var start_x: float = GameRules.INNER_HALF_WIDTH - 1.0
	var arc: Dictionary = _fill(Vector3(start_x, ICE_Y, 0), Vector3(25.0, 0.0, 0.0))
	var points: PackedVector3Array = arc.points
	var last: Vector3 = points[arc.count - 1]
	assert_lte(last.x, GameRules.INNER_HALF_WIDTH + 0.001,
			"path must not exit the rink")
	assert_gt(last.x, start_x, "path must reach the boards before stopping")
	assert_lt(arc.count, 30, "board contact must end the path early")


func test_respects_buffer_capacity() -> void:
	var arc: Dictionary = _fill(Vector3(0, ICE_Y, 0), Vector3(20.0, 4.65, 0.0), 8)
	assert_eq(arc.count, 8, "a long flight fills exactly the caller's buffer")


func test_zero_velocity_returns_origin_only() -> void:
	var origin := Vector3(1.0, ICE_Y, 2.0)
	var arc: Dictionary = _fill(origin, Vector3.ZERO)
	assert_eq(arc.count, 1)
	var points: PackedVector3Array = arc.points
	assert_eq(points[0], origin)


func test_empty_buffer_returns_zero() -> void:
	var buf := PackedVector3Array()
	assert_eq(ShotArcRules.fill_arc(Vector3.ZERO, Vector3(10, 0, 0), buf, ICE_Y), 0)
