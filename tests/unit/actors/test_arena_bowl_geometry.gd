extends GutTest

# The two pure geometry layers under ArenaStands: `ArenaBowlPath` (the perimeter
# in plan, and the arc-length parameter every seating section is cut on) and
# `ArenaBowlRake` (the bowl in section — row heights, deck levels, and the flat
# wells the rinkside furniture stands in).
#
# Both are RefCounted over an ArenaBowlSpec, so these need no scene and no
# renderer: the assertions are arithmetic about where the building is.


func _spec() -> ArenaBowlSpec:
	return ArenaBowlSpec.new()


func _path(spec: ArenaBowlSpec = null) -> ArenaBowlPath:
	return ArenaBowlPath.new(spec if spec != null else _spec())


func _rake(spec: ArenaBowlSpec) -> ArenaBowlRake:
	return ArenaBowlRake.new(spec, ArenaBowlPath.new(spec))


# ── Arc-length parameter ─────────────────────────────────────────────────────

func test_arc_parameter_is_radially_aligned() -> void:
	# Aisles run straight up the rake because seats stacked outward on the
	# same normal share one base-path arc position — check a straight-side
	# stack and a corner-fan stack across two row offsets.
	var spec: ArenaBowlSpec = _spec()
	var path: ArenaBowlPath = _path(spec)
	var half_w: float = spec.rink_width / 2.0
	assert_almost_eq(path.base_path_s(Vector2(-half_w - 0.5, 4.0)),
			path.base_path_s(Vector2(-half_w - 6.0, 4.0)), 0.001,
			"straight-side stacks must share an arc position")
	var cx: float = half_w - spec.corner_radius
	var cz: float = spec.rink_length / 2.0 - spec.corner_radius
	var diag: Vector2 = Vector2(1.0, 1.0).normalized()
	assert_almost_eq(
			path.base_path_s(Vector2(cx, cz) + diag * (spec.corner_radius + 0.5)),
			path.base_path_s(Vector2(cx, cz) + diag * (spec.corner_radius + 6.0)),
			0.001, "corner-fan stacks must share an arc position")


func test_arc_parameter_spans_full_perimeter() -> void:
	# Every seat position must land inside [0, perimeter) — a mis-mapped
	# region would alias two sections onto one another.
	var spec: ArenaBowlSpec = _spec()
	var path: ArenaBowlPath = _path(spec)
	var total: float = path.base_path_length()
	for ang: int in range(0, 360, 15):
		var dir: Vector2 = Vector2.from_angle(deg_to_rad(ang))
		var p: Vector2 = dir * Vector2(spec.rink_width / 2.0 + 3.0,
				spec.rink_length / 2.0 + 3.0)
		assert_between(path.base_path_s(p), 0.0, total,
				"arc position out of range at %d°" % ang)


func test_aisle_predicate_cuts_section_boundaries() -> void:
	var spec: ArenaBowlSpec = _spec()
	spec.num_aisles = 12
	var path: ArenaBowlPath = _path(spec)
	var seg: float = path.base_path_length() / 12.0
	assert_true(path.in_aisle(0.0), "section boundary should be an aisle")
	assert_true(path.in_aisle(seg), "every boundary should be an aisle")
	assert_false(path.in_aisle(seg * 0.5), "section centers stay seated")


func test_the_away_block_sits_on_the_far_corner() -> void:
	# The visiting section is the upper corner opposite the benches (which are on
	# +X), so its arc position must fall on the −X half of the building.
	var spec: ArenaBowlSpec = _spec()
	var path: ArenaBowlPath = _path(spec)
	var away: int = path.away_section_id()
	assert_between(away, 0, spec.num_aisles - 1, "the away block must be a real section")
	var seg: float = path.base_path_length() / float(spec.num_aisles)
	# Walk the −X long side; some of its sections must be the away one, and none
	# of the +X side's may be.
	var minus_x: float = path.base_path_s(Vector2(-spec.rink_width / 2.0 - 1.0, 0.0))
	var plus_x: float = path.base_path_s(Vector2(spec.rink_width / 2.0 + 1.0, 0.0))
	assert_lt(absf(minus_x - (float(away) + 0.5) * seg), path.base_path_length() * 0.25,
			"the away block should sit within a quarter-perimeter of the −X side")
	assert_ne(path.section_id(plus_x), away,
			"the benches' own side is never the visiting block")


func test_sector_bins_partition_every_instance_once() -> void:
	# The cull slices are how the renderer drops off-screen stands wholesale. A
	# transform that lands in no bin is a spectator that never draws; one in two
	# bins is drawn twice.
	var transforms: Array[Transform3D] = []
	for ang: int in range(0, 360, 7):
		var dir: Vector2 = Vector2.from_angle(deg_to_rad(ang)) * 20.0
		transforms.append(Transform3D(Basis.IDENTITY, Vector3(dir.x, 1.0, dir.y)))
	var seen: Dictionary = {}
	var bins: Array[PackedInt32Array] = ArenaBowlPath.sector_bins(transforms)
	assert_eq(bins.size(), ArenaBowlPath.CULL_SECTIONS)
	for bin: PackedInt32Array in bins:
		assert_false(bin.is_empty(), "a ring of instances should reach every slice")
		for i: int in bin:
			assert_false(seen.has(i), "instance %d landed in two slices" % i)
			seen[i] = true
	assert_eq(seen.size(), transforms.size(), "every instance should land in a slice")


# ── Row placement ────────────────────────────────────────────────────────────

func test_rows_step_out_and_up_by_their_own_dimensions() -> void:
	var spec: ArenaBowlSpec = _spec()
	var rake: ArenaBowlRake = _rake(spec)
	assert_almost_eq(rake.lower_row_offset(0), spec.base_outward_offset, 0.0001,
			"row 0 sits at the base offset")
	assert_almost_eq(rake.lower_row_offset(3) - rake.lower_row_offset(2),
			spec.tread_depth, 0.0001, "consecutive rows are one tread apart")
	assert_almost_eq(rake.lower_row_y(3) - rake.lower_row_y(2),
			spec.riser_height, 0.0001, "and one riser up")
	# The deck's own rake is steeper, and it starts a balcony above the walkway.
	assert_almost_eq(rake.upper_row_y(0),
			rake.lower_top_tread_y() + spec.upper_deck_rise, 0.0001,
			"the deck's first tread sits at the top of the fascia")
	assert_almost_eq(rake.upper_row_y(1) - rake.upper_row_y(0),
			spec.upper_riser_height, 0.0001, "deck rows use the deck's riser")
	assert_gt(rake.shell_offset(), rake.upper_row_offset(spec.upper_terraces - 1),
			"the shell stands behind the back row")


func test_a_deckless_bowl_puts_the_shell_behind_the_walkway() -> void:
	# LOW crowd density disables the deck; the wall has to close in rather than
	# leaving the walkway open onto nothing.
	var spec: ArenaBowlSpec = _spec()
	spec.upper_terraces = 0
	var rake: ArenaBowlRake = _rake(spec)
	assert_almost_eq(rake.top_tread_y(), rake.lower_top_tread_y(), 0.0001,
			"with no deck, the back row is the lower bowl's")
	assert_almost_eq(rake.shell_offset(), rake.upper_deck_inner_offset(), 0.0001,
			"and the shell stands where the deck would have")


# ── Rinkside wells ───────────────────────────────────────────────────────────
#
# The bench, the penalty boxes and the officials' table stand on the bowl's base
# level, but the terraces used to step straight past them — so anyone working at
# that furniture stood on the tread behind it, a riser above the floor the
# furniture sits on. Cutting those cleared rows down to one flat well is what
# puts staff and furniture on the same floor.

func test_cleared_rows_are_one_flat_well() -> void:
	var spec: ArenaBowlSpec = _spec()
	var rake: ArenaBowlRake = _rake(spec)
	var in_bench := Vector2(spec.rink_width / 2.0 + 1.0,
			ArenaRinksideLayout.BENCH_CENTER_Z)
	var out_in_bowl := Vector2(spec.rink_width / 2.0 + 1.0, 20.0)
	for row: int in [0, 1]:
		assert_almost_eq(rake.row_floor_y(row, in_bench), spec.stands_base_y,
				0.0001, "cleared row %d should be at the well's floor" % row)
	# Behind the cutout the rake resumes from the bowl's base, unchanged.
	assert_almost_eq(rake.row_floor_y(1, out_in_bowl),
			spec.stands_base_y + spec.riser_height, 0.0001,
			"a normal row 1 should still be one riser up")
	assert_almost_eq(rake.row_floor_y(2, in_bench),
			spec.stands_base_y + 2.0 * spec.riser_height, 0.0001,
			"seating rows behind the well keep their own height")


func test_the_row_behind_a_well_carries_the_whole_rise() -> void:
	# The rise the well swallowed has to come back somewhere, or the first seated
	# row behind the bench floats over a hole.
	var spec: ArenaBowlSpec = _spec()
	var rake: ArenaBowlRake = _rake(spec)
	var in_bench := Vector2(spec.rink_width / 2.0 + 1.0,
			ArenaRinksideLayout.BENCH_CENTER_Z)
	assert_almost_eq(rake.riser_bottom_y(2, in_bench), spec.stands_base_y,
			0.0001, "the row behind the well should rise from the well's floor")
	assert_almost_eq(rake.riser_bottom_y(1, in_bench), spec.stands_base_y,
			0.0001, "rows inside the well are level, leaving no riser to draw")
	assert_almost_eq(rake.riser_bottom_y(0, in_bench),
			spec.stands_base_y - spec.riser_height, 0.0001,
			"row 0 still fronts the bowl, well or no well")


func test_both_sides_of_the_rink_get_a_well() -> void:
	# +X is the player benches, −X the penalty boxes and the scorer's table. The
	# −X span is the narrower of the two, and getting the sign wrong would clear
	# the bench's width out of the wrong side of the bowl.
	var plus_x: float = ArenaRinksideLayout.BENCH_CENTER_Z \
			+ ArenaRinksideLayout.BENCH_HALF_LEN
	var minus_x: float = ArenaRinksideLayout.PENALTY_BOX_CENTER_Z \
			+ ArenaRinksideLayout.PENALTY_BOX_HALF_LEN
	assert_true(ArenaRinksideLayout.in_bench_zone(0, Vector2(10.0, plus_x - 0.1)))
	assert_false(ArenaRinksideLayout.in_bench_zone(0, Vector2(10.0, plus_x + 1.0)))
	assert_true(ArenaRinksideLayout.in_bench_zone(0, Vector2(-10.0, minus_x - 0.1)))
	assert_false(ArenaRinksideLayout.in_bench_zone(0, Vector2(-10.0, plus_x - 0.1)),
			"the −X side is cleared for the boxes, not for the benches' width")
	assert_false(ArenaRinksideLayout.in_bench_zone(
			ArenaRinksideLayout.BENCH_CLEAR_ROWS, Vector2(10.0, 0.0)),
			"the clearance stops after its own row count")


func test_staff_stand_on_the_well_floor_not_the_tread_behind_it() -> void:
	var spec: ArenaBowlSpec = _spec()
	var rake: ArenaBowlRake = _rake(spec)
	var behind := ArenaRinksideLayout.STAFF_BEHIND_BENCH
	var at_bench := Vector2(spec.rink_width / 2.0 + spec.base_outward_offset + behind,
			ArenaRinksideLayout.BENCH_CENTER_Z)
	assert_almost_eq(rake.floor_y_at(behind, at_bench), spec.stands_base_y, 0.0001,
			"a coach a metre back from the bench is still in the well")
	var out_in_bowl := Vector2(at_bench.x, 20.0)
	assert_gt(rake.floor_y_at(behind, out_in_bowl), spec.stands_base_y,
			"the same distance back outside the cutout is up a riser")


# ── Vomitories ───────────────────────────────────────────────────────────────

func test_portals_land_at_the_head_of_every_stairway() -> void:
	# A vomitory shares the aisles' spacing but takes its own, wider span — the
	# passage is wider than the steps that feed it.
	var spec: ArenaBowlSpec = _spec()
	var path: ArenaBowlPath = ArenaBowlPath.new(spec)
	var rake: ArenaBowlRake = ArenaBowlRake.new(spec, path)
	var seg: float = path.base_path_length() / float(spec.num_aisles)
	assert_true(rake.in_vomitory(0.0), "a portal sits at every section boundary")
	assert_true(rake.in_vomitory(seg), "and at the next one")
	assert_false(rake.in_vomitory(seg * 0.5), "section centres stay walled")
	assert_gt(spec.vomitory_width, spec.aisle_width,
			"the portal is wider than the aisle feeding it")
	assert_true(rake.in_vomitory(spec.aisle_width * 0.5 + 0.01),
			"so it is still a doorway just past the aisle's own edge")


func test_a_shallow_balcony_yields_the_fascia_to_the_ribbon_board() -> void:
	# The lower bowl's portals and the ribbon strip share one wall. When the
	# balcony is too short for both, the portals are the ones that go — signalled
	# by a head height at or below the walkway the caller compares against.
	var spec: ArenaBowlSpec = _spec()
	var tall: ArenaBowlRake = _rake(spec)
	assert_gt(tall.fascia_portal_head(), tall.lower_top_tread_y(),
			"a storey-high fascia has room for portals under the ribbon")
	spec.upper_deck_rise = 1.0
	var shallow: ArenaBowlRake = _rake(spec)
	assert_lt(shallow.fascia_portal_head(), shallow.lower_top_tread_y(),
			"a one-step fascia has room for the ribbon only")


func test_disabling_vomitories_closes_every_wall() -> void:
	var spec: ArenaBowlSpec = _spec()
	spec.vomitories_enabled = false
	var rake: ArenaBowlRake = _rake(spec)
	assert_false(rake.vomitories_wanted())
	assert_false(rake.in_vomitory(0.0), "no portals means no doorways anywhere")
	assert_eq(rake.fascia_portal_head(), -INF,
			"and no lintel height for the fascia to make room for")
