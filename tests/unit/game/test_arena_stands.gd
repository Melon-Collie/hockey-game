extends GutTest

# ArenaStands procedural build — the invariants a display-less run can still
# check: the rebuild's child inventory (terraces + shell + crowd + benches),
# the upper deck actually adding spectators, set_crowd_rows collapsing to one
# geometry, and the per-section crowd AABBs (sections must exist for frustum
# culling to bite, stay strict slices of the bowl, and grow to cover the
# upper deck — a too-small AABB re-introduces the mis-culling bug the custom
# AABBs exist to prevent).
#
# Row counts are kept small — the invariants don't depend on bowl size and the
# full 15+10 default builds a ~10k-instance crowd per test.


func _make_stands(lower: int, upper: int) -> ArenaStands:
	var stands: ArenaStands = ArenaStands.new()
	# Configure BEFORE entering the tree: _request_rebuild no-ops outside it,
	# so _ready() builds this geometry directly instead of the default bowl.
	stands.set_crowd_rows(lower, upper)
	add_child_autofree(stands)
	return stands


func _crowd_sections(stands: ArenaStands) -> Array[MultiMesh]:
	var sections: Array[MultiMesh] = []
	for child: Node in stands.get_children():
		if child.name.begins_with("SpectatorBodies"):
			sections.append((child as MultiMeshInstance3D).multimesh)
	return sections


func _crowd_count(stands: ArenaStands) -> int:
	var total: int = 0
	for mm: MultiMesh in _crowd_sections(stands):
		total += mm.instance_count
	return total


func test_rebuild_child_inventory() -> void:
	var stands: ArenaStands = _make_stands(3, 2)
	for expected: String in ["Terraces", "Shell", "SpectatorBodies*",
			"SpectatorHeads*", "BenchSeatHome", "BenchSeatAway",
			"StaffBodies", "StaffHeads"]:
		assert_not_null(stands.find_child(expected, false, false),
				"rebuild should produce a %s child" % expected)


func test_crowd_splits_into_multiple_cullable_sections() -> void:
	# The angular split exists so the renderer can frustum-cull off-screen
	# crowd; one whole-bowl MultiMesh would defeat that. Every section's AABB
	# must also be a strict slice of the union, not a copy of it.
	var stands: ArenaStands = _make_stands(3, 2)
	var sections: Array[MultiMesh] = _crowd_sections(stands)
	assert_gt(sections.size(), 1, "crowd should split into multiple sections")
	var union: AABB = _crowd_aabb(stands)
	var union_area: float = union.size.x * union.size.z
	for mm: MultiMesh in sections:
		var area: float = mm.custom_aabb.size.x * mm.custom_aabb.size.z
		assert_lt(area, union_area,
				"each section AABB should cover only a slice of the bowl")


func test_shell_mesh_has_geometry_without_upper_deck() -> void:
	# LOW density disables the deck; the shell wall must still enclose the bowl.
	var stands: ArenaStands = _make_stands(3, 0)
	var shell: MeshInstance3D = stands.find_child("Shell", false, false)
	assert_not_null(shell)
	var mesh: ArrayMesh = shell.mesh as ArrayMesh
	assert_gt(mesh.surface_get_array_len(0), 0, "shell wall should have triangles")


func test_upper_deck_adds_spectators() -> void:
	var without_deck: int = _crowd_count(_make_stands(3, 0))
	var with_deck: int = _crowd_count(_make_stands(3, 2))
	assert_gt(without_deck, 0, "lower bowl should seat spectators")
	assert_gt(with_deck, without_deck,
			"upper deck rows should add spectators beyond the lower bowl's")


func test_crowd_aabb_covers_upper_deck() -> void:
	# The custom AABB exists because Godot's auto-AABB mis-culls the crowd; if
	# the upper deck isn't folded into it, its whole sections vanish at some
	# camera angles. Instance transforms aren't readable under the headless
	# dummy renderer, so compare the AABBs analytically: adding deck rows must
	# grow the bounds both outward and upward. The deck's first row sits above
	# an upper_deck_rise balcony, so its top face must clear that rise too.
	var flat: AABB = _crowd_aabb(_make_stands(3, 0))
	var decked: AABB = _crowd_aabb(_make_stands(3, 2))
	assert_gt(decked.size.x, flat.size.x, "deck should widen the crowd AABB")
	assert_gt(decked.size.z, flat.size.z, "deck should deepen the crowd AABB")
	assert_gt(decked.end.y, flat.end.y + 1.0,
			"deck rows should raise the crowd AABB past the balcony rise")


# Union of the per-section custom AABBs — the whole crowd's bounds.
func _crowd_aabb(stands: ArenaStands) -> AABB:
	var union: AABB = AABB()
	var first: bool = true
	for mm: MultiMesh in _crowd_sections(stands):
		union = mm.custom_aabb if first else union.merge(mm.custom_aabb)
		first = false
	return union


func test_set_crowd_rows_applies_both_counts() -> void:
	var stands: ArenaStands = _make_stands(3, 2)
	stands.set_crowd_rows(4, 0)
	assert_eq(stands.num_terraces, 4)
	assert_eq(stands.upper_terraces, 0)


# ── Seating sections ─────────────────────────────────────────────────────────

func _make_sectioned_stands(aisles: int, fill: float) -> ArenaStands:
	var stands: ArenaStands = ArenaStands.new()
	stands.num_aisles = aisles
	stands.attendance = fill
	stands.set_crowd_rows(3, 2)
	add_child_autofree(stands)
	return stands


func test_aisles_clear_spectators() -> void:
	# Aisle corridors are cleared seats; a sectioned bowl must hold fewer
	# spectators than the same bowl without aisles.
	var solid: int = _crowd_count(_make_sectioned_stands(0, 1.0))
	var sectioned: int = _crowd_count(_make_sectioned_stands(12, 1.0))
	assert_gt(solid, 0)
	assert_lt(sectioned, solid, "aisles should remove seats from the bowl")


func test_attendance_scatters_empty_seats() -> void:
	var packed: int = _crowd_count(_make_sectioned_stands(0, 1.0))
	var sparse: int = _crowd_count(_make_sectioned_stands(0, 0.5))
	assert_lt(sparse, packed, "sub-1.0 attendance should leave seats empty")
	assert_gt(sparse, 0, "half attendance should still seat a crowd")


func test_arc_parameter_is_radially_aligned() -> void:
	# Aisles run straight up the rake because seats stacked outward on the
	# same normal share one base-path arc position — check a straight-side
	# stack and a corner-fan stack across two row offsets.
	var stands: ArenaStands = _make_sectioned_stands(12, 1.0)
	var half_w: float = stands.rink_width / 2.0
	var inner_side: float = stands._base_path_s(Vector2(-half_w - 0.5, 4.0))
	var outer_side: float = stands._base_path_s(Vector2(-half_w - 6.0, 4.0))
	assert_almost_eq(inner_side, outer_side, 0.001,
			"straight-side stacks must share an arc position")
	var cx: float = half_w - stands.corner_radius
	var cz: float = stands.rink_length / 2.0 - stands.corner_radius
	var diag: Vector2 = Vector2(1.0, 1.0).normalized()
	var inner_corner: float = stands._base_path_s(
			Vector2(cx, cz) + diag * (stands.corner_radius + 0.5))
	var outer_corner: float = stands._base_path_s(
			Vector2(cx, cz) + diag * (stands.corner_radius + 6.0))
	assert_almost_eq(inner_corner, outer_corner, 0.001,
			"corner-fan stacks must share an arc position")


func test_arc_parameter_spans_full_perimeter() -> void:
	# Every seat position must land inside [0, perimeter) — a mis-mapped
	# region would alias two sections onto one another.
	var stands: ArenaStands = _make_sectioned_stands(12, 1.0)
	var total: float = stands._base_path_length()
	for ang: int in range(0, 360, 15):
		var dir: Vector2 = Vector2.from_angle(deg_to_rad(ang))
		var p: Vector2 = dir * Vector2(stands.rink_width / 2.0 + 3.0,
				stands.rink_length / 2.0 + 3.0)
		var s: float = stands._base_path_s(p)
		assert_between(s, 0.0, total, "arc position out of range at %d°" % ang)


func test_aisle_predicate_cuts_section_boundaries() -> void:
	var stands: ArenaStands = _make_sectioned_stands(12, 1.0)
	var seg: float = stands._base_path_length() / 12.0
	assert_true(stands._in_aisle(0.0), "section boundary should be an aisle")
	assert_true(stands._in_aisle(seg), "every boundary should be an aisle")
	assert_false(stands._in_aisle(seg * 0.5), "section centers stay seated")


func test_away_block_flags_upper_deck_only() -> void:
	# The visiting-fan block lives in the upper deck; a deck-less bowl has no
	# flagged seats, a decked one flags some (but not most) of the crowd.
	var flat: int = _away_flag_count(_make_sectioned_stands(12, 1.0), 3, 0)
	assert_eq(flat, 0, "no upper deck → no visiting block")
	var stands: ArenaStands = _make_sectioned_stands(12, 1.0)
	var flagged: int = _away_flag_count(stands, 3, 2)
	assert_gt(flagged, 0, "decked bowl should flag a visiting block")
	assert_lt(flagged, _crowd_count(stands) / 4,
			"the visiting block is one section, not a quarter of the bowl")


func _away_flag_count(stands: ArenaStands, lower: int, upper: int) -> int:
	stands.set_crowd_rows(lower, upper)
	var layout: Dictionary = stands._get_or_build_layout()
	var count: int = 0
	for slice_flags: PackedByteArray in (layout.away_flags as Array[PackedByteArray]):
		for flag: int in slice_flags:
			count += flag
	return count


# ── Rinkside staff ───────────────────────────────────────────────────────────

func _staff_multimesh(stands: ArenaStands, part: String) -> MultiMesh:
	var mmi: MultiMeshInstance3D = stands.find_child(part, false, false)
	assert_not_null(mmi, "rebuild should produce a %s child" % part)
	return mmi.multimesh


func test_standing_staff_reach_full_stature() -> void:
	# Body and head ride separate transforms — only a standing body stretches —
	# so nothing but this arithmetic keeps the two joined. The crown has to land
	# at the staffer's stature above the tread they stand on, with the head
	# resting on the body rather than sunk into it.
	var stands: ArenaStands = _make_stands(3, 2)
	var body_box: AABB = stands._build_body_mesh().get_aabb()
	var head_box: AABB = stands._build_head_mesh().get_aabb()
	var post := Vector3(6.0, 1.5, 2.0)
	for stature: float in [1.52, 1.75, 1.88]:
		var girth: float = stands._staff_girth_scale(stature)
		var lift: float = stands._staff_hip_height(stature)
		var body: Transform3D = stands._staff_body_transform(post, 0.0, girth, lift)
		var head: Transform3D = stands._staff_head_transform(post, 0.0, girth, lift)
		var body_top: float = body.origin.y \
				+ body_box.end.y * body.basis.get_scale().y
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
	var stands: ArenaStands = _make_stands(3, 2)
	var head_box: AABB = stands._build_head_mesh().get_aabb()
	var post := Vector3(-6.0, 1.2, 0.0)
	var girth: float = stands._staff_girth_scale(1.75)
	var body: Transform3D = stands._staff_body_transform(post, 0.0, girth, 0.0)
	var head: Transform3D = stands._staff_head_transform(post, 0.0, girth, 0.0)
	assert_almost_eq(body.basis.get_scale().y, girth, 0.0001,
			"a seated body should not stretch")
	assert_eq(head.origin, post, "a seated head rides the body's own origin")
	var crown: float = head.origin.y + head_box.end.y * girth
	assert_almost_eq(crown - post.y, 1.75 * stands._SITTING_HEIGHT_FRACTION, 0.001,
			"a seated staffer stands only their sitting height above the seat")


func test_only_the_coaches_stand() -> void:
	# Off-ice officials and box attendants work sitting down; the bench is the one
	# post staffed on its feet. Read through _staff_postings because a MultiMesh's
	# instance transforms come back empty under the headless renderer.
	var stands: ArenaStands = _make_stands(3, 2)
	var posts: Array[Vector3] = []
	var jackets: Array[Color] = []
	var standing: Array[bool] = []
	stands._staff_postings(posts, jackets, standing)
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
	var stands: ArenaStands = _make_stands(3, 2)
	var posts: Array[Vector3] = []
	var jackets: Array[Color] = []
	var standing: Array[bool] = []
	stands._staff_postings(posts, jackets, standing)
	var head_box: AABB = stands._build_head_mesh().get_aabb()
	var table_top: float = stands.stands_base_y + stands._OFFICIALS_HEIGHT
	var seat_top: float = stands.stands_base_y + stands._BENCH_SEAT_HEIGHT
	for i: int in posts.size():
		if standing[i]:
			continue
		var girth: float = stands._staff_girth_scale(stands._STANDING_STATURE_MIN)
		var crown: float = posts[i].y + head_box.end.y * girth
		assert_gt(crown, table_top + 0.2,
				"a seated staffer's head should clear the counter in front of them")
		assert_lt(posts[i].y, table_top,
				"nobody should be seated above the surface they work at")
		if absf(posts[i].z) > stands.PENALTY_BOX_CENTER_Z:
			assert_almost_eq(posts[i].y, seat_top, 0.001,
					"box attendants sit on the box's own seat block")


func test_staff_aabb_covers_the_standing_figures() -> void:
	# Same trap as the crowd sections: an under-sized custom AABB culls the whole
	# MultiMesh, and the seed box only covers instance origins (their feet).
	var stands: ArenaStands = _make_stands(3, 2)
	var bodies: MultiMesh = _staff_multimesh(stands, "StaffBodies")
	var heads: MultiMesh = _staff_multimesh(stands, "StaffHeads")
	assert_gt(bodies.instance_count, 0, "the rinkside furniture should be staffed")
	assert_eq(heads.instance_count, bodies.instance_count, "one head per body")
	assert_eq(heads.custom_aabb, bodies.custom_aabb,
			"heads and bodies share one figure, so they share one bound")
	assert_gt(bodies.custom_aabb.size.y, stands._STANDING_STATURE_MAX,
			"staff bounds must clear the tallest figure standing at the highest post")


# ── Cull bounds ──────────────────────────────────────────────────────────────
#
# Every MultiMesh here declares a custom_aabb, because Godot's auto-AABB
# mis-culls instances pushed one transform at a time. That makes the box a hand-
# written claim about geometry the renderer never re-checks: declare one smaller
# than its instances and they vanish the moment the shortfall leaves the screen,
# from some camera angles and not others. Instance transforms come back empty
# under the headless renderer, so these test the growth rule instead — that a box
# seeded with instance ORIGINS grows enough to hold the largest figure standing
# at any corner of that seed.

func _worst_case_figure(stands: ArenaStands, foot: Vector3, girth: float,
		height: float) -> AABB:
	# Widest footprint a figure can present: the body box turned 45°, so its
	# diagonal faces the camera rather than a face.
	var half: float = maxf(stands._BODY_SIZE.x, stands._BODY_SIZE.z) \
			* girth * sqrt(2.0) * 0.5
	return AABB(foot - Vector3(half, 0.0, half),
			Vector3(half * 2.0, height, half * 2.0))


func _assert_bounds_hold(stands: ArenaStands, grown: AABB, seed: AABB,
		girth: float, height: float, what: String) -> void:
	for dx: float in [0.0, 1.0]:
		for dy: float in [0.0, 1.0]:
			for dz: float in [0.0, 1.0]:
				var foot: Vector3 = seed.position + seed.size * Vector3(dx, dy, dz)
				var figure: AABB = _worst_case_figure(stands, foot, girth, height)
				assert_true(grown.encloses(figure),
						"%s at %v should sit inside the declared bounds" % [what, foot])


func test_crowd_section_bounds_hold_the_tallest_spectator() -> void:
	var stands: ArenaStands = _make_stands(3, 2)
	var seed := AABB(Vector3(-4.0, 1.0, -3.0), Vector3(8.0, 2.4, 6.0))
	_assert_bounds_hold(stands, stands._grow_section_aabb(seed), seed,
			stands._CROWD_SCALE_MAX,
			stands._FIGURE_HEIGHT * stands._CROWD_SCALE_MAX, "a spectator")


func test_staff_bounds_hold_the_tallest_coach() -> void:
	# The standing figure is the tall one, so the box is sized off full stature
	# rather than the seated crowd's sitting height.
	var stands: ArenaStands = _make_stands(3, 2)
	var seed := AABB(Vector3(-14.1, 1.2, -5.6), Vector3(28.2, 0.06, 11.2))
	_assert_bounds_hold(stands, stands._grow_staff_aabb(seed), seed,
			stands._staff_girth_scale(stands._STANDING_STATURE_MAX),
			stands._STANDING_STATURE_MAX, "a coach")


func test_seat_bounds_hold_the_furniture() -> void:
	var stands: ArenaStands = _make_stands(3, 2)
	var seed := AABB(Vector3(-4.0, 1.0, -3.0), Vector3(8.0, 2.4, 6.0))
	var grown: AABB = stands._grow_seat_aabb(seed)
	var half: float = Vector2(stands._SEAT_WIDTH,
			stands._SEAT_BACK_OFFSET + stands._SEAT_BACK_THICKNESS).length() * 0.5
	for dx: float in [0.0, 1.0]:
		for dz: float in [0.0, 1.0]:
			var foot: Vector3 = seed.position + seed.size * Vector3(dx, 1.0, dz)
			assert_true(grown.encloses(AABB(foot - Vector3(half, 0.0, half),
					Vector3(half * 2.0, stands._SEAT_BACK_HEIGHT, half * 2.0))),
					"a seat at %v should sit inside the declared bounds" % foot)


# ── Rinkside wells ───────────────────────────────────────────────────────────
#
# The bench, the penalty boxes and the officials' table stand on the bowl's base
# level, but the terraces used to step straight past them — so anyone working at
# that furniture stood on the tread behind it, a riser above the floor the
# furniture sits on. Cutting those cleared rows down to one flat well is what
# puts staff and furniture on the same floor.

func test_cleared_rows_are_one_flat_well() -> void:
	var stands: ArenaStands = _make_stands(3, 2)
	var in_bench := Vector2(stands.rink_width / 2.0 + 1.0, ArenaStands.BENCH_CENTER_Z)
	var out_in_bowl := Vector2(stands.rink_width / 2.0 + 1.0, 20.0)
	for row: int in [0, 1]:
		assert_almost_eq(stands._row_floor_y(row, in_bench), stands.stands_base_y,
				0.0001, "cleared row %d should be at the well's floor" % row)
	# Behind the cutout the rake resumes from the bowl's base, unchanged.
	assert_almost_eq(stands._row_floor_y(1, out_in_bowl),
			stands.stands_base_y + stands.riser_height, 0.0001,
			"a normal row 1 should still be one riser up")
	assert_almost_eq(stands._row_floor_y(2, in_bench),
			stands.stands_base_y + 2.0 * stands.riser_height, 0.0001,
			"seating rows behind the well keep their own height")


func test_the_row_behind_a_well_carries_the_whole_rise() -> void:
	# The rise the well swallowed has to come back somewhere, or the first seated
	# row behind the bench floats over a hole.
	var stands: ArenaStands = _make_stands(3, 2)
	var in_bench := Vector2(stands.rink_width / 2.0 + 1.0, ArenaStands.BENCH_CENTER_Z)
	assert_almost_eq(stands._riser_bottom_y(2, in_bench), stands.stands_base_y,
			0.0001, "the row behind the well should rise from the well's floor")
	assert_almost_eq(stands._riser_bottom_y(1, in_bench), stands.stands_base_y,
			0.0001, "rows inside the well are level, leaving no riser to draw")
	assert_almost_eq(stands._riser_bottom_y(0, in_bench),
			stands.stands_base_y - stands.riser_height, 0.0001,
			"row 0 still fronts the bowl, well or no well")


func test_terrace_mesh_is_flat_through_the_bench_cutout() -> void:
	# The rule above only matters if the emitted concrete follows it. Row 1's
	# tread band inside the cutout must carry no geometry at the height it would
	# have stepped to — that leftover step is what a coach stood on.
	var stands: ArenaStands = _make_stands(3, 2)
	var terraces: MeshInstance3D = stands.find_child("Terraces", false, false)
	var verts: PackedVector3Array = (terraces.mesh as ArrayMesh) \
			.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var stepped: float = stands.stands_base_y + stands.riser_height
	var half_width: float = stands.rink_width / 2.0
	var inside: int = 0
	var outside: int = 0
	for v: Vector3 in verts:
		# Straight bench side only, and clear of the cutout's ends so the side
		# walls (which legitimately span both heights) stay out of it.
		var beyond: float = v.x - half_width
		if v.x < 0.0 or beyond < stands.tread_depth or beyond > stands.tread_depth * 2.0:
			continue
		if absf(v.z) < ArenaStands.BENCH_HALF_LEN:
			inside += 1
			assert_almost_eq(v.y, stands.stands_base_y, 0.0001,
					"row 1 inside the bench cutout should be at the well floor")
		elif absf(v.z) > ArenaStands.BENCH_CENTER_Z + ArenaStands.BENCH_HALF_LEN + 2.0 \
				and absf(v.z) < 18.0 and is_equal_approx(v.y, stepped):
			outside += 1
	assert_gt(inside, 0, "the cutout's tread band should exist in the mesh")
	assert_gt(outside, 0, "the same band outside the cutout should still step up")


func test_staff_and_their_furniture_share_a_floor() -> void:
	# The whole point: nobody works a riser above the thing they work at.
	var stands: ArenaStands = _make_stands(3, 2)
	var posts: Array[Vector3] = []
	var jackets: Array[Color] = []
	var standing: Array[bool] = []
	stands._staff_postings(posts, jackets, standing)
	var seat_top: float = stands.stands_base_y + stands._BENCH_SEAT_HEIGHT
	for i: int in posts.size():
		var expected: float = stands.stands_base_y if standing[i] else seat_top
		assert_almost_eq(posts[i].y, expected, 0.0001,
				"staffer %d should stand on the furniture's own floor" % i)
