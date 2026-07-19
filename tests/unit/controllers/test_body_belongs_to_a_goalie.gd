extends GutTest

# PuckController._body_belongs_to_a_goalie — the Phase-2 probe's ground-truth helper:
# does a Jolt-reported colliding body (a StaticBody3D part) belong to one of the goalies?
# Regression guard: the goalie list is a TYPED array, so `body in goalies` / find() threw
# on a plain-Node needle and silently returned false — which miscounted every sustained-
# contact tick as a phantom. The walk-up must compare by identity, never `in`.


func _goalie_with_part() -> Array:
	# A stand-in goalie: a Node3D root with a StaticBody3D "part" beneath it, like the real
	# Goalie whose CollisionShape parts sit under StaticBody3D children.
	var goalie := Node3D.new()
	var part := StaticBody3D.new()
	goalie.add_child(part)
	add_child_autofree(goalie)
	return [goalie, part]


func test_part_under_goalie_belongs() -> void:
	var gp := _goalie_with_part()
	var goalies: Array[Node3D] = [gp[0]]  # a TYPED array, as GameManager.goalies is
	assert_true(PuckController._body_belongs_to_a_goalie(gp[1], goalies),
			"a StaticBody3D part under the goalie belongs to it (typed array, no crash)")


func test_goalie_root_itself_belongs() -> void:
	var gp := _goalie_with_part()
	var goalies: Array[Node3D] = [gp[0]]
	assert_true(PuckController._body_belongs_to_a_goalie(gp[0], goalies),
			"the goalie node itself belongs")


func test_unrelated_body_does_not_belong() -> void:
	var gp := _goalie_with_part()
	var goalies: Array[Node3D] = [gp[0]]
	var stranger := StaticBody3D.new()
	add_child_autofree(stranger)
	assert_false(PuckController._body_belongs_to_a_goalie(stranger, goalies),
			"a body outside every goalie's subtree does not belong")


func test_empty_goalie_list_is_false() -> void:
	var stranger := StaticBody3D.new()
	add_child_autofree(stranger)
	var goalies: Array[Node3D] = []
	assert_false(PuckController._body_belongs_to_a_goalie(stranger, goalies))
