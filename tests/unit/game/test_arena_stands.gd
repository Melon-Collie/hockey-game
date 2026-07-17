extends GutTest

# ArenaStands procedural build — the invariants a display-less run can still
# check: the rebuild's child inventory (terraces + shell + crowd + benches),
# the upper deck actually adding spectators, set_crowd_rows collapsing to one
# geometry, and the explicit crowd AABB enclosing every instance (a too-small
# AABB re-introduces the whole-section culling bug the custom AABB exists to
# prevent).
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


func _crowd_count(stands: ArenaStands) -> int:
	var bodies: MultiMeshInstance3D = stands.find_child("SpectatorBodies", false, false)
	if bodies == null or bodies.multimesh == null:
		return -1
	return bodies.multimesh.instance_count


func test_rebuild_child_inventory() -> void:
	var stands: ArenaStands = _make_stands(3, 2)
	for expected: String in ["Terraces", "Shell", "SpectatorBodies",
			"SpectatorHeads", "BenchSeatHome", "BenchSeatAway"]:
		assert_not_null(stands.find_child(expected, false, false),
				"rebuild should produce a %s child" % expected)


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


func _crowd_aabb(stands: ArenaStands) -> AABB:
	var bodies: MultiMeshInstance3D = stands.find_child("SpectatorBodies", false, false)
	return bodies.multimesh.custom_aabb


func test_set_crowd_rows_applies_both_counts() -> void:
	var stands: ArenaStands = _make_stands(3, 2)
	stands.set_crowd_rows(4, 0)
	assert_eq(stands.num_terraces, 4)
	assert_eq(stands.upper_terraces, 0)
