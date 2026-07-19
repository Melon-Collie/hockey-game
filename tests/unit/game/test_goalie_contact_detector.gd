extends GutTest

# GoalieContactDetector.nearest — the production analytic puck-vs-goalie contact used to drive
# the puck. Builds tiny synthetic goalies (StaticBody3D + BoxShape3D) in the tree so
# global_transform resolves, then fires swept segments and checks the nearest-contact pick,
# the part, the outward normal, and the clean-miss.

const R: float = 0.065


func _goalie_with_box(pos: Vector3, half: Vector3) -> Node3D:
	var goalie := Node3D.new()
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = half * 2.0
	cs.shape = box
	body.add_child(cs)
	goalie.add_child(body)
	goalie.position = pos
	add_child_autofree(goalie)
	return goalie


func test_detects_a_head_on_contact() -> void:
	var goalie := _goalie_with_box(Vector3.ZERO, Vector3(0.5, 0.5, 0.5))
	var out := GoalieContactDetector.Contact.new()
	var scratch := SweptDiscOBB.Result.new()
	var hit: bool = GoalieContactDetector.nearest([goalie], Vector3(-2, 0, 0), Vector3(0, 0, 0), R, scratch, out)
	assert_true(hit, "swept segment into the box is a contact")
	assert_eq(out.part, goalie.get_child(0), "reports the StaticBody3D part struck")
	assert_almost_eq(out.normal.x, -1.0, 0.01, "outward normal points back along -X")
	assert_eq(out.goalie, goalie)


func test_clean_miss_returns_false() -> void:
	var goalie := _goalie_with_box(Vector3.ZERO, Vector3(0.3, 0.3, 0.3))
	var out := GoalieContactDetector.Contact.new()
	var scratch := SweptDiscOBB.Result.new()
	var hit: bool = GoalieContactDetector.nearest([goalie], Vector3(-2, 2, 0), Vector3(2, 2, 0), R, scratch, out)
	assert_false(hit, "a pass 2 m over the box is a miss")
	assert_null(out.part)


func test_picks_nearest_part_by_toi() -> void:
	# Two boxes in one goalie; a puck from -X contacts the nearer one (smaller toi).
	var goalie := Node3D.new()
	for x: float in [0.0, 3.0]:
		var body := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(0.5, 0.5, 0.5)
		cs.shape = box
		body.add_child(cs)
		body.position = Vector3(x, 0, 0)
		goalie.add_child(body)
	add_child_autofree(goalie)
	var out := GoalieContactDetector.Contact.new()
	var scratch := SweptDiscOBB.Result.new()
	GoalieContactDetector.nearest([goalie], Vector3(-2, 0, 0), Vector3(2.5, 0, 0), R, scratch, out)
	assert_eq(out.part, goalie.get_child(0), "picked the nearer box (x=0)")


func test_picks_nearest_across_two_goalies() -> void:
	var near := _goalie_with_box(Vector3(0, 0, 0), Vector3(0.5, 0.5, 0.5))
	var far := _goalie_with_box(Vector3(5, 0, 0), Vector3(0.5, 0.5, 0.5))
	var out := GoalieContactDetector.Contact.new()
	var scratch := SweptDiscOBB.Result.new()
	GoalieContactDetector.nearest([near, far], Vector3(-2, 0, 0), Vector3(6, 0, 0), R, scratch, out)
	assert_eq(out.goalie, near, "nearest contact is the near goalie")
