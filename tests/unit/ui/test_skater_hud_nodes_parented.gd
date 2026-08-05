extends GutTest

# The per-skater world HUD, as it now exists.
#
# The flat-on-ice half has left the node tree: the slot ring, elevation chevrons,
# the slapper one-timer indicator and the stamina gauge are ice-shader uniforms.
# What stays a node is what cannot be painted on the ice — the name plate, which
# is world-sized text standing up off the surface, and the self-beacon, which
# floats above the head. The beacon is additionally built LAZILY, only on the
# skater the ring-relation resolver reports as SELF.
#
# Both properties pinned below have broken before:
#
#   • Parenting. An unparented Node3D is not obviously broken: it constructs
#     fine, keeps its local transform, and stays silent until something writes
#     its global_position, which then fails with "Condition !is_inside_tree() is
#     true" and returns identity. The stamina ring shipped that way for a build
#     — the gauge simply never appeared, and the only symptom was an error line
#     in a log nobody was reading. Checking names in the subtree rather than the
#     coordinator's own references is deliberate: the references would be
#     non-null in exactly the broken case.
#
#   • Visibility defaults. `_ring_visible` replaced a MeshInstance3D born
#     visible = true and defaulted to false. Its only writers are the
#     replay/spectator latch and the ghost pass, neither of which runs on an
#     ordinary skater, so the ring stayed hidden from spawn until the first goal
#     replay restored it.

const SKATER_SCENE: PackedScene = preload("res://Scenes/Skater.tscn")

# RingRelation.SELF — what the resolver answers for the local player's skater.
const _RELATION_SELF: int = 0


func _has_descendant_named(root: Node, node_name: String) -> bool:
	if root.name == node_name:
		return true
	for child: Node in root.get_children():
		if _has_descendant_named(child, node_name):
			return true
	return false


func _spawn() -> Skater:
	var skater: Skater = SKATER_SCENE.instantiate() as Skater
	add_child_autofree(skater)
	return skater


func test_name_plate_is_parented() -> void:
	var skater: Skater = _spawn()
	await get_tree().process_frame
	assert_true(_has_descendant_named(skater, "PlayerNameLabel"),
			"the name plate must be parented into the skater — an unparented Label3D "
			+ "fails silently on its first global_position write")


func test_self_beacon_is_lazy_and_parented_once_built() -> void:
	var skater: Skater = _spawn()
	await get_tree().process_frame
	assert_false(_has_descendant_named(skater, "SelfBeacon"),
			"the beacon must NOT exist before a relation says this is your skater "
			+ "— it used to be built on all ten at 5v5 so that one could show it")
	skater.set_ring_relation_resolver(func() -> int: return _RELATION_SELF)
	assert_true(_has_descendant_named(skater, "SelfBeacon"),
			"the beacon must be parented into the skater once built — an unparented "
			+ "HUD node fails silently on its first global_position write")


func test_world_hud_starts_visible() -> void:
	var skater: Skater = _spawn()
	await get_tree().process_frame
	assert_true(skater.name_plate_visible(),
			"a spawned skater's name plate must be visible without a replay cycle")
	# ring_field_visible() additionally needs a resolved relation, which a bare
	# spawn has no registry to supply — so drive one in and check the gate opens.
	skater.set_ring_relation_resolver(func() -> int: return _RELATION_SELF)
	assert_true(skater.ring_field_visible(),
			"a spawned skater's on-ice ring must be visible once its relation is known")
