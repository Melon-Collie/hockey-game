extends GutTest

# BoardAdLayout — packing sponsor panels into the free arc of the dasher boards —
# plus the clearances the hand-picked in-ice slots (AdBrands.ICE_SLOTS) have to
# hold against every marking painted on the sheet.

const EPS: float = 0.001
const PERIMETER: float = 157.35   # the shipping rink, to the centimetre

# ── Interval merging ─────────────────────────────────────────────────────

func test_disjoint_reservations_survive_the_merge() -> void:
	var merged: Array[Vector2] = BoardAdLayout.merge_reserved(100.0,
			[Vector2(10.0, 5.0), Vector2(40.0, 5.0)] as Array[Vector2])
	assert_eq(merged.size(), 2, "two reservations that do not touch stay two")
	assert_almost_eq(merged[0].x, 10.0, EPS, "first start")
	assert_almost_eq(merged[0].y, 5.0, EPS, "first length")

func test_overlapping_reservations_collapse() -> void:
	var merged: Array[Vector2] = BoardAdLayout.merge_reserved(100.0,
			[Vector2(10.0, 8.0), Vector2(15.0, 10.0)] as Array[Vector2])
	assert_eq(merged.size(), 1, "an overlap is one stretch of blocked board")
	assert_almost_eq(merged[0].x, 10.0, EPS, "merged start")
	assert_almost_eq(merged[0].y, 15.0, EPS, "merged length spans both")

func test_unsorted_input_merges_the_same() -> void:
	var forward: Array[Vector2] = BoardAdLayout.merge_reserved(100.0,
			[Vector2(5.0, 3.0), Vector2(20.0, 3.0), Vector2(60.0, 3.0)] as Array[Vector2])
	var shuffled: Array[Vector2] = BoardAdLayout.merge_reserved(100.0,
			[Vector2(60.0, 3.0), Vector2(5.0, 3.0), Vector2(20.0, 3.0)] as Array[Vector2])
	assert_eq(shuffled, forward, "order in is irrelevant; order out is ascending")

func test_a_reservation_crossing_the_seam_is_cut_at_it() -> void:
	# 95 → 105 on a 100 m loop is 95→100 plus 0→5.
	var merged: Array[Vector2] = BoardAdLayout.merge_reserved(100.0,
			[Vector2(95.0, 10.0)] as Array[Vector2])
	assert_eq(merged.size(), 2, "one wrapping stretch, two linear spans")
	assert_almost_eq(merged[0].x, 0.0, EPS, "tail starts at the seam")
	assert_almost_eq(merged[0].y, 5.0, EPS, "tail length")
	assert_almost_eq(merged[1].x, 95.0, EPS, "head start")
	assert_almost_eq(merged[1].y, 5.0, EPS, "head length")

# ── Free runs ────────────────────────────────────────────────────────────

func test_no_reservations_is_one_run_of_the_whole_loop() -> void:
	var runs: Array[Vector2] = BoardAdLayout.free_runs(100.0, [] as Array[Vector2])
	assert_eq(runs.size(), 1, "an unobstructed loop is a single run")
	assert_almost_eq(runs[0].y, 100.0, EPS, "and it is the whole perimeter")

func test_a_fully_reserved_loop_has_no_runs() -> void:
	var runs: Array[Vector2] = BoardAdLayout.free_runs(100.0,
			[Vector2(0.0, 100.0)] as Array[Vector2])
	assert_eq(runs.size(), 0, "nothing free means nothing to fill")

func test_the_run_spanning_the_seam_is_returned_once() -> void:
	# One reservation at 40→60 leaves 60→140 (i.e. 60→100→40), a single run.
	var runs: Array[Vector2] = BoardAdLayout.free_runs(100.0,
			[Vector2(40.0, 20.0)] as Array[Vector2])
	assert_eq(runs.size(), 1, "the seam does not split a run in two")
	assert_almost_eq(runs[0].x, 60.0, EPS, "starts after the reservation")
	assert_almost_eq(runs[0].y, 80.0, EPS, "and carries past arc 0")

func test_runs_and_reservations_tile_the_loop() -> void:
	var reserved: Array[Vector2] = [Vector2(10.0, 5.0), Vector2(30.0, 12.0),
			Vector2(88.0, 4.0)] as Array[Vector2]
	var total: float = 0.0
	for run: Vector2 in BoardAdLayout.free_runs(100.0, reserved):
		total += run.y
	for span: Vector2 in BoardAdLayout.merge_reserved(100.0, reserved):
		total += span.y
	assert_almost_eq(total, 100.0, EPS, "free plus blocked accounts for every metre")

# ── Panel placement ──────────────────────────────────────────────────────

func test_panels_never_land_on_a_reservation() -> void:
	var reserved: Array[Vector2] = _shipping_reservations()
	var panels: Array[Vector2] = BoardAdLayout.place_panels(
			PERIMETER, reserved, 3.95, 0.3, 0.35)
	assert_gt(panels.size(), 0, "the shipping rink has room for ads")
	for panel: Vector2 in panels:
		for span: Vector2 in BoardAdLayout.merge_reserved(PERIMETER, reserved):
			assert_false(_spans_overlap(PERIMETER, panel, span),
					"panel at %.2f (w %.2f) clears the reservation at %.2f (len %.2f)"
							% [panel.x, panel.y, span.x, span.y])

func test_panels_never_overlap_each_other() -> void:
	var panels: Array[Vector2] = BoardAdLayout.place_panels(
			PERIMETER, _shipping_reservations(), 3.95, 0.3, 0.35)
	for i: int in panels.size():
		for j: int in range(i + 1, panels.size()):
			assert_false(_spans_overlap(PERIMETER, panels[i], panels[j]),
					"panel %d and panel %d are disjoint" % [i, j])

func test_every_panel_is_the_requested_width() -> void:
	# Uniform width is load-bearing: the atlas cell aspect is fixed, so a panel
	# of any other width would show stretched art.
	for panel: Vector2 in BoardAdLayout.place_panels(
			PERIMETER, _shipping_reservations(), 3.95, 0.3, 0.35):
		assert_almost_eq(panel.y, 3.95, EPS, "panel width")

func test_neighbours_in_a_run_keep_at_least_the_minimum_gap() -> void:
	# 50 m run, 4 m panels, 1 m minimum gap: the packer must not squeeze an
	# extra panel in by shrinking the gaps below what was asked for.
	var panels: Array[Vector2] = BoardAdLayout.place_panels(
			100.0, [Vector2(50.0, 50.0)] as Array[Vector2], 4.0, 1.0, 0.0)
	assert_gt(panels.size(), 1, "several panels fit in 50 m")
	for i: int in range(1, panels.size()):
		var gap: float = panels[i].x - (panels[i - 1].x + panels[i - 1].y)
		assert_gte(gap, 1.0 - EPS, "gap between panel %d and %d" % [i - 1, i])

func test_a_run_shorter_than_one_panel_gets_none() -> void:
	# 3 m of free board with 0.35 m margins cannot hold a 3.95 m panel.
	var panels: Array[Vector2] = BoardAdLayout.place_panels(
			100.0, [Vector2(3.0, 97.0)] as Array[Vector2], 3.95, 0.3, 0.35)
	assert_eq(panels.size(), 0, "no panel rather than a clipped one")

func test_a_run_that_fits_exactly_one_panel_centres_it() -> void:
	# 10 m run, 4 m panel, 1 m margins → 8 m usable, so 2 m of slack, split.
	var panels: Array[Vector2] = BoardAdLayout.place_panels(
			100.0, [Vector2(10.0, 90.0)] as Array[Vector2], 4.0, 0.5, 1.0)
	assert_eq(panels.size(), 1, "exactly one panel")
	assert_almost_eq(panels[0].x, 3.0, EPS, "centred in the run, not shoved to its start")

func test_the_run_margin_is_honoured() -> void:
	var margin: float = 0.6
	var panels: Array[Vector2] = BoardAdLayout.place_panels(
			100.0, [Vector2(60.0, 40.0)] as Array[Vector2], 4.0, 0.3, margin)
	assert_gt(panels.size(), 0, "panels fit")
	assert_gte(panels[0].x, margin - EPS, "first panel clears the run's start")
	var last: Vector2 = panels[panels.size() - 1]
	assert_lte(last.x + last.y, 60.0 - margin + EPS, "last panel clears the run's end")

func test_more_free_board_means_more_panels() -> void:
	var tight: Array[Vector2] = BoardAdLayout.place_panels(
			100.0, [Vector2(30.0, 70.0)] as Array[Vector2], 4.0, 0.3, 0.35)
	var roomy: Array[Vector2] = BoardAdLayout.place_panels(
			100.0, [Vector2(30.0, 40.0)] as Array[Vector2], 4.0, 0.3, 0.35)
	assert_gt(roomy.size(), tight.size(), "freeing 30 m of board buys more panels")

func test_the_layout_is_deterministic() -> void:
	# Board ads are never replicated — every machine derives them. If this
	# stops holding, clients see different boards from the host.
	var reserved: Array[Vector2] = _shipping_reservations()
	var first: Array[Vector2] = BoardAdLayout.place_panels(PERIMETER, reserved, 3.95, 0.3, 0.35)
	var second: Array[Vector2] = BoardAdLayout.place_panels(PERIMETER, reserved, 3.95, 0.3, 0.35)
	assert_eq(second, first, "same rink, same boards")

# ── In-ice slot clearances ───────────────────────────────────────────────
#
# Each assertion re-derives the marking from GameRules rather than restating a
# number, so a slot is checked against the ice that actually gets painted.

const FACEOFF_CIRCLE_RADIUS: float = 4.572
const FACEOFF_DOT_RADIUS: float = 0.3048
const THICK_LINE_HALF: float = 0.15    # centre red and blue lines are 0.3 m wide
const THIN_LINE_HALF: float = 0.025    # goal lines
const CREASE_ARC_RADIUS: float = 1.83
const ICE_CLEARANCE: float = 0.30      # bare ice the paint keeps around itself

func test_ice_slots_stay_inside_the_boards() -> void:
	for slot: Dictionary in AdBrands.ICE_SLOTS:
		for corner: Vector2 in _slot_corners(slot):
			var clamped: Vector2 = GameRules.clamp_to_rink_inner(corner, 1.0)
			assert_almost_eq(clamped.distance_to(corner), 0.0, EPS,
					"corner %s is a metre clear of the boards" % corner)

func test_ice_slots_clear_the_centre_and_blue_lines() -> void:
	# Every line runs the full width of the sheet, so clearance is purely a
	# question of the slot's Z span — no slot may straddle one.
	for slot: Dictionary in AdBrands.ICE_SLOTS:
		var half_z: float = (slot.size as Vector2).y * 0.5
		var near_z: float = absf((slot.center as Vector2).y) - half_z
		var far_z: float = absf((slot.center as Vector2).y) + half_z
		assert_gte(near_z, THICK_LINE_HALF + ICE_CLEARANCE,
				"slot clears the centre red line")
		# Blue lines at ±BLUE_LINE_Z.
		var to_blue: float = _interval_distance(near_z, far_z,
				GameRules.BLUE_LINE_Z - THICK_LINE_HALF,
				GameRules.BLUE_LINE_Z + THICK_LINE_HALF)
		assert_gte(to_blue, ICE_CLEARANCE, "slot clears the blue line")
		# Goal lines at ±GOAL_LINE_Z.
		var to_goal: float = _interval_distance(near_z, far_z,
				GameRules.GOAL_LINE_Z - THIN_LINE_HALF,
				GameRules.GOAL_LINE_Z + THIN_LINE_HALF)
		assert_gte(to_goal, ICE_CLEARANCE, "slot clears the goal line")

func test_ice_slots_clear_every_faceoff_circle_and_dot() -> void:
	for slot: Dictionary in AdBrands.ICE_SLOTS:
		var centre_gap: float = _slot_distance_to(slot, GameRules.CENTER_ICE_DOT)
		assert_gte(centre_gap, FACEOFF_CIRCLE_RADIUS + ICE_CLEARANCE,
				"slot clears the centre circle")
		for dot: Vector2 in GameRules.END_ZONE_FACEOFF_DOTS:
			assert_gte(_slot_distance_to(slot, dot), FACEOFF_CIRCLE_RADIUS + ICE_CLEARANCE,
					"slot clears the end-zone circle at %s" % dot)
		for dot: Vector2 in GameRules.NEUTRAL_ZONE_FACEOFF_DOTS:
			assert_gte(_slot_distance_to(slot, dot), FACEOFF_DOT_RADIUS + ICE_CLEARANCE,
					"slot clears the neutral-zone dot at %s" % dot)

func test_ice_slots_clear_both_creases() -> void:
	for slot: Dictionary in AdBrands.ICE_SLOTS:
		for sign_z: float in [1.0, -1.0]:
			var goal_centre := Vector2(0.0, sign_z * GameRules.GOAL_LINE_Z)
			assert_gte(_slot_distance_to(slot, goal_centre),
					CREASE_ARC_RADIUS + ICE_CLEARANCE,
					"slot clears the crease at z = %.2f" % goal_centre.y)

func test_ice_slots_do_not_overlap_each_other() -> void:
	for i: int in AdBrands.ICE_SLOTS.size():
		for j: int in range(i + 1, AdBrands.ICE_SLOTS.size()):
			assert_false(_slots_overlap(AdBrands.ICE_SLOTS[i], AdBrands.ICE_SLOTS[j]),
					"ice slot %d and %d are disjoint" % [i, j])

func test_every_ice_slot_names_a_real_brand() -> void:
	for slot: Dictionary in AdBrands.ICE_SLOTS:
		assert_between(slot.brand as int, 0, AdBrands.BRANDS.size() - 1,
				"brand index is in range")

# ── In-ice atlas packing ─────────────────────────────────────────────────
#
# The painter gives each slot its own cell rather than one rink-sized image, and
# the ice shader maps a slot's world rect onto that cell. The mapping only holds
# if the cells are unstretched, disjoint, and inside the atlas.

func test_every_ice_slot_fits_the_shader_arrays() -> void:
	assert_lte(AdBrands.ICE_SLOTS.size(), IceAdPainter.MAX_SLOTS,
			"ads_world[] and ads_atlas[] in ice.gdshader are MAX_SLOTS long")

func test_ice_atlas_cells_are_unstretched() -> void:
	var atlas := Vector2(IceAdPainter.atlas_size(AdBrands.ICE_SLOTS))
	for i: int in AdBrands.ICE_SLOTS.size():
		var slot_size: Vector2 = AdBrands.ICE_SLOTS[i].size
		var uv: Rect2 = IceAdPainter.cell_uv(AdBrands.ICE_SLOTS, i)
		var metres: Vector2 = uv.size * atlas / IceAdPainter.PX_PER_METER
		assert_almost_eq(metres.x, slot_size.x, 0.01,
				"cell %d covers the slot's width, so the wordmark is not squeezed" % i)
		assert_almost_eq(metres.y, slot_size.y, 0.01,
				"cell %d covers the slot's length" % i)

func test_ice_atlas_cells_are_disjoint_and_inside_the_atlas() -> void:
	var placed: Array[Rect2] = []
	for i: int in AdBrands.ICE_SLOTS.size():
		var uv: Rect2 = IceAdPainter.cell_uv(AdBrands.ICE_SLOTS, i)
		assert_true(Rect2(0.0, 0.0, 1.0, 1.0).encloses(uv),
				"cell %d is inside the atlas" % i)
		for other: Rect2 in placed:
			assert_false(other.intersects(uv),
					"cell %d keeps its gutter from the cells before it" % i)
		placed.append(uv)

# ── Helpers ──────────────────────────────────────────────────────────────

# The reservations the shipping rink produces: centre and blue stripes on both
# side walls, goal-line stripes in the four corners, and the bench stretch. Arc
# positions are approximate — the point is a realistic amount and distribution
# of blocked board, not a re-derivation of HockeyRink's geometry.
func _shipping_reservations() -> Array[Vector2]:
	return [
		Vector2(20.7, 0.8), Vector2(13.4, 0.8), Vector2(28.0, 0.8),     # east wall stripes
		Vector2(99.0, 0.8), Vector2(91.7, 0.8), Vector2(106.3, 0.8),    # west wall stripes
		Vector2(48.5, 0.65), Vector2(70.0, 0.65),                        # north corners
		Vector2(127.0, 0.65), Vector2(148.5, 0.65),                      # south corners
		Vector2(13.9, 15.2),                                             # benches
	] as Array[Vector2]

# True when two arc spans share any board, accounting for either wrapping the
# seam. Compared by sampling both spans onto the same unwrapped line.
func _spans_overlap(perimeter: float, a: Vector2, b: Vector2) -> bool:
	for shift: float in [-perimeter, 0.0, perimeter]:
		var b_start: float = b.x + shift
		if a.x < b_start + b.y - BoardAdLayout.EPSILON \
				and b_start < a.x + a.y - BoardAdLayout.EPSILON:
			return true
	return false

func _slot_corners(slot: Dictionary) -> Array:
	var c: Vector2 = slot.center
	var h: Vector2 = (slot.size as Vector2) * 0.5
	return [
		c + Vector2(-h.x, -h.y), c + Vector2(h.x, -h.y),
		c + Vector2(h.x, h.y), c + Vector2(-h.x, h.y),
	]

# Shortest distance from a point to the slot's rectangle (0 when inside).
func _slot_distance_to(slot: Dictionary, point: Vector2) -> float:
	var c: Vector2 = slot.center
	var h: Vector2 = (slot.size as Vector2) * 0.5
	var dx: float = maxf(absf(point.x - c.x) - h.x, 0.0)
	var dz: float = maxf(absf(point.y - c.y) - h.y, 0.0)
	return sqrt(dx * dx + dz * dz)

func _slots_overlap(a: Dictionary, b: Dictionary) -> bool:
	var ac: Vector2 = a.center
	var bc: Vector2 = b.center
	var ah: Vector2 = (a.size as Vector2) * 0.5
	var bh: Vector2 = (b.size as Vector2) * 0.5
	return absf(ac.x - bc.x) < ah.x + bh.x and absf(ac.y - bc.y) < ah.y + bh.y

# Gap between two 1D intervals; 0 when they touch or overlap.
func _interval_distance(a_lo: float, a_hi: float, b_lo: float, b_hi: float) -> float:
	if a_hi < b_lo:
		return b_lo - a_hi
	if b_hi < a_lo:
		return a_lo - b_hi
	return 0.0
