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

const _EXPECTED_HUD_NODES: Array[String] = [
	"StaminaRing",
	"SelfBeacon",
	"SlapperIndicator",
]


func _has_descendant_named(root: Node, node_name: String) -> bool:
	if root.name == node_name:
		return true
	for child: Node in root.get_children():
		if _has_descendant_named(child, node_name):
			return true
	return false


func test_world_hud_nodes_are_in_the_tree() -> void:
	var skater: Skater = load("res://Scenes/Skater.tscn").instantiate() as Skater
	add_child_autofree(skater)
	await get_tree().process_frame
	for node_name: String in _EXPECTED_HUD_NODES:
		assert_true(_has_descendant_named(skater, node_name),
				"%s must be parented into the skater — an unparented HUD node fails "
				% node_name + "silently on its first global_position write")
