extends GutTest

# Every world-HUD node SkaterHUDCoordinator builds must actually be in the tree.
#
# Regression guard. An unparented Node3D is not obviously broken: it constructs
# fine, keeps its local transform, and stays silent until something writes its
# global_position — which then fails with "Condition !is_inside_tree() is true"
# and returns an identity transform. The stamina ring shipped that way for a
# build after a refactor removed its add_child: the gauge simply never appeared,
# and the only symptom was an error line in a log nobody was reading.
#
# Checking names in the subtree rather than the coordinator's own references is
# deliberate — the references would be non-null in exactly the broken case.

const SKATER_SCENE: PackedScene = preload("res://Scenes/Skater.tscn")

# Shrinks as world HUD moves out of the node tree. The slapper indicator and the
# stamina gauge left when they became ice-shader uniforms; the beacon is what is
# still a node, because it floats above the head and the ice shader cannot draw
# it at all.
const _EXPECTED_HUD_NODES: Array[String] = [
	"SelfBeacon",
]


func _has_descendant_named(root: Node, node_name: String) -> bool:
	if root.name == node_name:
		return true
	for child: Node in root.get_children():
		if _has_descendant_named(child, node_name):
			return true
	return false


func test_world_hud_nodes_are_in_the_tree() -> void:
	var skater: Skater = SKATER_SCENE.instantiate() as Skater
	add_child_autofree(skater)
	await get_tree().process_frame
	for node_name: String in _EXPECTED_HUD_NODES:
		assert_true(_has_descendant_named(skater, node_name),
				"%s must be parented into the skater — an unparented HUD node fails "
				% node_name + "silently on its first global_position write")


# A freshly spawned skater shows its name plate and (once a ring relation is
# known) its on-ice ring. Regression guard for a default that inverted.
#
# The ring and the plate used to be a MeshInstance3D and a Label3D, born
# `visible = true`. Moving them to shader uniforms and a 2D overlay turned that
# implicit default into `var _..._visible: bool`, and the only writers are the
# replay/spectator latch and the ghost pass — neither of which runs on an
# ordinary skater. Defaulting them false hid both from spawn until the first
# goal replay happened to restore them, which is why it read as "sometimes".
func test_world_hud_starts_visible() -> void:
	var skater: Skater = SKATER_SCENE.instantiate() as Skater
	add_child_autofree(skater)
	await get_tree().process_frame
	assert_true(skater.name_plate_visible(),
			"a spawned skater's name plate must be visible without a replay cycle")
	# ring_field_visible() additionally needs a resolved relation, which a bare
	# spawn has no registry to supply — so drive one in and check the gate opens.
	skater.set_ring_relation_resolver(func() -> int: return 0)
	assert_true(skater.ring_field_visible(),
			"a spawned skater's on-ice ring must be visible once its relation is known")
