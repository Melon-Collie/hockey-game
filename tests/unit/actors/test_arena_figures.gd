extends GutTest

# The people in the building and the boxes the renderer is told they fit inside.
#
# Two unrelated things a display-less run can still check, and both have already
# shipped a bug:
#
#   · Stature. A seated spectator and a standing coach are the same two boxes at
#     different scales, joined only by ArenaFigureMesh's arithmetic — a body that
#     stretches when it should not is a coach standing at a desk they should be
#     sitting at, and a uniform scale to standing height is a giant beside the
#     crowd.
#   · Cull bounds. Every MultiMesh here declares a custom_aabb, because Godot's
#     auto-AABB mis-culls instances pushed one transform at a time. That makes
#     the box a hand-written claim about geometry the renderer never re-checks:
#     declare one smaller than its instances and they vanish the moment the
#     shortfall leaves the screen, from some camera angles and not others.
#     Instance transforms come back empty under the headless renderer, so these
#     test the growth RULE instead — that a box seeded with instance ORIGINS
#     grows enough to hold the largest figure standing at any corner of it.


func _spec() -> ArenaBowlSpec:
	return ArenaBowlSpec.new()


func _rinkside(spec: ArenaBowlSpec) -> ArenaRinkside:
	return ArenaRinkside.new(spec, ArenaBowlRake.new(spec, ArenaBowlPath.new(spec)))


# ── Stature ──────────────────────────────────────────────────────────────────

func test_standing_staff_reach_full_stature() -> void:
	# Body and head ride separate transforms — only a standing body stretches —
	# so nothing but this arithmetic keeps the two joined. The crown has to land
	# at the staffer's stature above the tread they stand on, with the head
	# resting on the body rather than sunk into it.
	var body_box: AABB = ArenaFigureMesh.body_mesh().get_aabb()
	var head_box: AABB = ArenaFigureMesh.head_mesh().get_aabb()
	var post := Vector3(6.0, 1.5, 2.0)
	for stature: float in [1.52, 1.75, 1.88]:
		var girth: float = ArenaFigureMesh.girth_scale(stature)
		var lift: float = ArenaFigureMesh.hip_height(stature)
		var body: Transform3D = ArenaFigureMesh.body_transform(post, 0.0, girth, lift)
		var head: Transform3D = ArenaFigureMesh.head_transform(post, 0.0, girth, lift)
		var body_top: float = body.origin.y + body_box.end.y * body.basis.get_scale().y
		var head_bottom: float = head.origin.y \
				+ head_box.position.y * head.basis.get_scale().y
		var head_top: float = head.origin.y + head_box.end.y * head.basis.get_scale().y
		assert_almost_eq(head_top - post.y, stature, 0.001,
				"a %.2f m staffer's crown should sit %.2f m over their post"
						% [stature, stature])
		assert_gt(head_bottom, body_top, "the head should rest above the body")
		assert_lt(head_bottom - body_top, 0.05,
				"the neck gap should stay a gap, not open into a floating head")


func test_seated_staff_are_the_spectator_figure() -> void:
	# Sitting is the unscaled figure, so a seated staffer (no hip lift) must come
	# out as one uniformly scaled box — the same pose the crowd is drawn in. A
	# stretched body here is someone standing at a desk they should be sitting at.
	var head_box: AABB = ArenaFigureMesh.head_mesh().get_aabb()
	var post := Vector3(-6.0, 1.2, 0.0)
	var girth: float = ArenaFigureMesh.girth_scale(1.75)
	var body: Transform3D = ArenaFigureMesh.body_transform(post, 0.0, girth, 0.0)
	var head: Transform3D = ArenaFigureMesh.head_transform(post, 0.0, girth, 0.0)
	assert_almost_eq(body.basis.get_scale().y, girth, 0.0001,
			"a seated body should not stretch")
	assert_eq(head.origin, post, "a seated head rides the body's own origin")
	assert_almost_eq(head.origin.y + head_box.end.y * girth - post.y,
			1.75 * ArenaFigureMesh.SITTING_HEIGHT_FRACTION, 0.001,
			"a seated staffer stands only their sitting height above the seat")


func test_a_seated_spectator_is_their_own_stature_tall() -> void:
	# The crowd's own scale is the other end of the same bridge: a spectator's
	# whole figure IS sitting height, so the crown lands at the rolled stature.
	var head_box: AABB = ArenaFigureMesh.head_mesh().get_aabb()
	for stature: float in [ArenaFigureMesh.SEATED_STATURE_MIN, 0.88,
			ArenaFigureMesh.SEATED_STATURE_MAX]:
		var scale: float = ArenaFigureMesh.seated_scale(stature)
		assert_almost_eq(head_box.end.y * scale, stature, 0.0001,
				"a %.2f m seated figure should stand %.2f m over the tread"
						% [stature, stature])


# ── Postings ─────────────────────────────────────────────────────────────────

func test_only_the_coaches_stand() -> void:
	# Off-ice officials and box attendants work sitting down; the bench is the one
	# post staffed on its feet. Read through staff_postings because a MultiMesh's
	# instance transforms come back empty under the headless renderer.
	var posts: Array[Vector3] = []
	var jackets: Array[Color] = []
	var standing: Array[bool] = []
	_rinkside(_spec()).staff_postings(posts, jackets, standing)
	assert_eq(posts.size(), 9, "four coaches, two attendants, three at the table")
	assert_eq(jackets.size(), posts.size(), "every post should be dressed")
	assert_eq(standing.count(true), 4,
			"only the four bench coaches should be on their feet")
	assert_eq(standing.count(false), 5,
			"the timekeeping crew and both box attendants should be seated")


func test_seated_staff_sit_on_the_furniture_they_work_at() -> void:
	# The bug the render caught: staff placed on the terrace tread behind the
	# furniture stand a riser above the floor that furniture sits on, so they read
	# as standing ON the scorer's table. Attendants sit on the penalty bench
	# itself, and the crew's heads must clear the table without towering over it.
	var spec: ArenaBowlSpec = _spec()
	var posts: Array[Vector3] = []
	var jackets: Array[Color] = []
	var standing: Array[bool] = []
	_rinkside(spec).staff_postings(posts, jackets, standing)
	var head_box: AABB = ArenaFigureMesh.head_mesh().get_aabb()
	var table_top: float = spec.stands_base_y + ArenaRinksideLayout.OFFICIALS_HEIGHT
	var seat_top: float = spec.stands_base_y + ArenaRinksideLayout.BENCH_SEAT_HEIGHT
	for i: int in posts.size():
		if standing[i]:
			continue
		var girth: float = ArenaFigureMesh.girth_scale(
				ArenaFigureMesh.STANDING_STATURE_MIN)
		assert_gt(posts[i].y + head_box.end.y * girth, table_top + 0.2,
				"a seated staffer's head should clear the counter in front of them")
		assert_lt(posts[i].y, table_top,
				"nobody should be seated above the surface they work at")
		if absf(posts[i].z) > ArenaRinksideLayout.PENALTY_BOX_CENTER_Z:
			assert_almost_eq(posts[i].y, seat_top, 0.001,
					"box attendants sit on the box's own seat block")


func test_staff_and_their_furniture_share_a_floor() -> void:
	# The whole point: nobody works a riser above the thing they work at.
	var spec: ArenaBowlSpec = _spec()
	var posts: Array[Vector3] = []
	var jackets: Array[Color] = []
	var standing: Array[bool] = []
	_rinkside(spec).staff_postings(posts, jackets, standing)
	var seat_top: float = spec.stands_base_y + ArenaRinksideLayout.BENCH_SEAT_HEIGHT
	for i: int in posts.size():
		var expected: float = spec.stands_base_y if standing[i] else seat_top
		assert_almost_eq(posts[i].y, expected, 0.0001,
				"staffer %d should stand on the furniture's own floor" % i)


# ── Cull bounds ──────────────────────────────────────────────────────────────

func _worst_case_figure(foot: Vector3, girth: float, height: float) -> AABB:
	# Widest footprint a figure can present: the body box turned 45°, so its
	# diagonal faces the camera rather than a face.
	var half: float = maxf(ArenaFigureMesh.BODY_SIZE.x, ArenaFigureMesh.BODY_SIZE.z) \
			* girth * sqrt(2.0) * 0.5
	return AABB(foot - Vector3(half, 0.0, half),
			Vector3(half * 2.0, height, half * 2.0))


func _assert_bounds_hold(grown: AABB, seed: AABB, girth: float, height: float,
		what: String) -> void:
	for dx: float in [0.0, 1.0]:
		for dy: float in [0.0, 1.0]:
			for dz: float in [0.0, 1.0]:
				var foot: Vector3 = seed.position + seed.size * Vector3(dx, dy, dz)
				assert_true(grown.encloses(_worst_case_figure(foot, girth, height)),
						"%s at %v should sit inside the declared bounds" % [what, foot])


func test_crowd_section_bounds_hold_the_tallest_spectator() -> void:
	var spec: ArenaBowlSpec = _spec()
	var crowd := ArenaCrowd.new(spec, ArenaBowlPath.new(spec),
			ArenaBowlRake.new(spec, ArenaBowlPath.new(spec)))
	var seed := AABB(Vector3(-4.0, 1.0, -3.0), Vector3(8.0, 2.4, 6.0))
	_assert_bounds_hold(crowd.grow_section_aabb(seed), seed,
			ArenaFigureMesh.CROWD_SCALE_MAX,
			ArenaFigureMesh.FIGURE_HEIGHT * ArenaFigureMesh.CROWD_SCALE_MAX,
			"a spectator")


func test_staff_bounds_hold_the_tallest_coach() -> void:
	# The standing figure is the tall one, so the box is sized off full stature
	# rather than the seated crowd's sitting height.
	var seed := AABB(Vector3(-14.1, 1.2, -5.6), Vector3(28.2, 0.06, 11.2))
	_assert_bounds_hold(_rinkside(_spec()).grow_staff_aabb(seed), seed,
			ArenaFigureMesh.girth_scale(ArenaFigureMesh.STANDING_STATURE_MAX),
			ArenaFigureMesh.STANDING_STATURE_MAX, "a coach")


func test_seat_bounds_hold_the_furniture() -> void:
	var spec: ArenaBowlSpec = _spec()
	var seating := ArenaSeating.new(spec, ArenaBowlPath.new(spec),
			ArenaBowlRake.new(spec, ArenaBowlPath.new(spec)))
	var seed := AABB(Vector3(-4.0, 1.0, -3.0), Vector3(8.0, 2.4, 6.0))
	var grown: AABB = seating.grow_seat_aabb(seed)
	var half: float = Vector2(ArenaSeating.WIDTH,
			ArenaSeating.BACK_OFFSET + ArenaSeating.BACK_THICKNESS).length() * 0.5
	for dx: float in [0.0, 1.0]:
		for dz: float in [0.0, 1.0]:
			var foot: Vector3 = seed.position + seed.size * Vector3(dx, 1.0, dz)
			assert_true(grown.encloses(AABB(foot - Vector3(half, 0.0, half),
					Vector3(half * 2.0, ArenaSeating.BACK_HEIGHT, half * 2.0))),
					"a seat at %v should sit inside the declared bounds" % foot)


func test_a_seat_clears_the_largest_occupant() -> void:
	# The seat's dimensions are all bounded by the body they have to show around,
	# and that body is the LARGEST stature roll, not the mesh's nominal size.
	var widest: float = maxf(ArenaFigureMesh.BODY_SIZE.x, ArenaFigureMesh.BODY_SIZE.z) \
			* ArenaFigureMesh.CROWD_SCALE_MAX
	assert_gt(ArenaSeating.WIDTH, widest,
			"a seat shows either side of its occupant")
	assert_lt(ArenaSeating.WIDTH, ArenaBowlSpec.new().spectator_spacing,
			"and stops short of its neighbour, or the row reads as one bench")
	assert_gt(ArenaSeating.BACK_OFFSET, widest * 0.5,
			"the backrest clears the deepest body a roll can produce")
