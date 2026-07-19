extends GutTest

# GoalieCollisionShadow — builds a tiny synthetic goalie (StaticBody3D + BoxShape3D) in
# the tree so global_transform resolves, then fires puck swept segments at it and checks
# detection agreement, part-match, and the clean-miss case.

const R: float = 0.065


func _make_goalie_with_box(pos: Vector3, half: Vector3) -> Node3D:
	var goalie := Node3D.new()
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = half * 2.0
	cs.shape = box
	body.add_child(cs)
	goalie.add_child(body)
	goalie.position = pos
	add_child_autofree(goalie)  # into the tree so global_transform resolves
	return goalie


func test_agreement_and_part_match_on_a_hit() -> void:
	var goalie := _make_goalie_with_box(Vector3(0, 0, 0), Vector3(0.5, 0.5, 0.5))
	var part: Node = goalie.get_child(0)  # the StaticBody3D
	var shadow := GoalieCollisionShadow.new()
	shadow.record_contact(goalie, part, Vector3(-2, 0, 0), Vector3(0, 0, 0), R)
	assert_eq(shadow.jolt_contacts, 1)
	assert_eq(shadow.analytic_agreed, 1, "analytic caught the contact Jolt reported")
	assert_eq(shadow.part_matches, 1, "analytic picked the same part")
	assert_eq(shadow.normal_sane, 1, "normal opposes the puck's travel")
	assert_almost_eq(shadow.agreement_pct(), 100.0, 0.01)


func test_analytic_miss_counts_as_disagreement() -> void:
	var goalie := _make_goalie_with_box(Vector3(0, 0, 0), Vector3(0.3, 0.3, 0.3))
	var part: Node = goalie.get_child(0)
	var shadow := GoalieCollisionShadow.new()
	# Puck passes 2 m above the box — analytic correctly finds no contact.
	shadow.record_contact(goalie, part, Vector3(-2, 2, 0), Vector3(2, 2, 0), R)
	assert_eq(shadow.jolt_contacts, 1)
	assert_eq(shadow.analytic_agreed, 0, "analytic finds no contact on a clear miss (the failure to watch)")
	assert_almost_eq(shadow.agreement_pct(), 0.0, 0.01)


func test_part_match_false_when_wrong_part_reported() -> void:
	var goalie := _make_goalie_with_box(Vector3(0, 0, 0), Vector3(0.5, 0.5, 0.5))
	var shadow := GoalieCollisionShadow.new()
	var not_the_part := StaticBody3D.new()
	add_child_autofree(not_the_part)
	shadow.record_contact(goalie, not_the_part, Vector3(-2, 0, 0), Vector3(0, 0, 0), R)
	assert_eq(shadow.analytic_agreed, 1, "still detected the contact")
	assert_eq(shadow.part_matches, 0, "but the analytic part != the reported part")


func test_picks_nearest_part_among_several() -> void:
	# Two boxes; a puck from -X should contact the NEARER one (smaller toi).
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
	var near_body: Node = goalie.get_child(0)  # x=0
	var shadow := GoalieCollisionShadow.new()
	shadow.record_contact(goalie, near_body, Vector3(-2, 0, 0), Vector3(2.5, 0, 0), R)
	assert_eq(shadow.analytic_agreed, 1)
	assert_eq(shadow.part_matches, 1, "analytic picked the nearer box, matching the reported part")


func test_probe_counts_a_phantom_when_analytic_hits_but_jolt_saw_nothing() -> void:
	# The analytic swept test contacts the box, but Jolt reported no contact this tick ->
	# phantom (the false-positive direction record_contact structurally can't see).
	var goalie := _make_goalie_with_box(Vector3(0, 0, 0), Vector3(0.5, 0.5, 0.5))
	var shadow := GoalieCollisionShadow.new()
	shadow.probe([goalie], Vector3(-2, 0, 0), Vector3(0, 0, 0), R, false)
	assert_eq(shadow.probe_ticks, 1)
	assert_eq(shadow.probe_hit_ticks, 1, "analytic fired")
	assert_eq(shadow.false_positive_ticks, 1, "Jolt saw nothing -> phantom")
	assert_almost_eq(shadow.false_positive_pct(), 100.0, 0.01)


func test_probe_agrees_when_jolt_also_saw_contact() -> void:
	# Analytic hit AND Jolt contact this tick -> agreement, not a phantom (the sustained-
	# contact case: a puck resting on the pads that get_colliding_bodies reports).
	var goalie := _make_goalie_with_box(Vector3(0, 0, 0), Vector3(0.5, 0.5, 0.5))
	var shadow := GoalieCollisionShadow.new()
	shadow.probe([goalie], Vector3(-2, 0, 0), Vector3(0, 0, 0), R, true)
	assert_eq(shadow.probe_hit_ticks, 1)
	assert_eq(shadow.agreed_probe_ticks, 1, "Jolt agreed -> not a phantom")
	assert_eq(shadow.false_positive_ticks, 0)


func test_probe_clear_miss_records_no_hit() -> void:
	# Analytic finds no contact (puck passes 2 m above) -> probed but no hit, no phantom.
	var goalie := _make_goalie_with_box(Vector3(0, 0, 0), Vector3(0.3, 0.3, 0.3))
	var shadow := GoalieCollisionShadow.new()
	shadow.probe([goalie], Vector3(-2, 2, 0), Vector3(2, 2, 0), R, false)
	assert_eq(shadow.probe_ticks, 1)
	assert_eq(shadow.probe_hit_ticks, 0, "analytic correctly saw nothing")
	assert_eq(shadow.false_positive_ticks, 0, "no hit -> no phantom")


func test_reset_session_zeroes() -> void:
	var goalie := _make_goalie_with_box(Vector3.ZERO, Vector3(0.5, 0.5, 0.5))
	var shadow := GoalieCollisionShadow.new()
	shadow.record_contact(goalie, goalie.get_child(0), Vector3(-2, 0, 0), Vector3(0, 0, 0), R)
	assert_gt(shadow.jolt_contacts, 0)
	shadow.probe([goalie], Vector3(-2, 0, 0), Vector3(0, 0, 0), R, false)
	assert_gt(shadow.probe_ticks, 0)
	shadow.reset_session()
	assert_eq(shadow.jolt_contacts, 0)
	assert_eq(shadow.analytic_agreed, 0)
	assert_eq(shadow.probe_ticks, 0)
	assert_eq(shadow.false_positive_ticks, 0)
