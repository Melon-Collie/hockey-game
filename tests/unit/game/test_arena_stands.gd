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
			"SpectatorHeads*", "BenchSeatHome", "BenchSeatAway"]:
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
