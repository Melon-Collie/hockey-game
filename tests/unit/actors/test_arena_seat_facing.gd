extends GutTest

# ArenaBowlPath.row_facing_yaw — the heading every seat and every spectator in the
# bowl is placed at.
#
# The sign of the tangent rotation is the entire content of that function, and
# getting it backwards turns the whole bowl to face the concourse — which renders
# as a plausible-looking arena until you look at anyone's face. So the invariant
# is pinned here rather than left to the comment: a seat's forward must point at
# the ice.

# A closed loop wound the way sample_offset_path winds one: bottom edge (running
# +x → −x) → left → top → right. The winding is what decides which rotation of the
# tangent points at the rink, so a loop wound the other way would pin the opposite
# sign and pass a broken function.
func _bowl_loop(half_x: float, half_z: float, per_side: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i: int in per_side:
		pts.append(Vector2(lerpf(half_x, -half_x, float(i) / per_side), -half_z))
	for i: int in per_side:
		pts.append(Vector2(-half_x, lerpf(-half_z, half_z, float(i) / per_side)))
	for i: int in per_side:
		pts.append(Vector2(lerpf(-half_x, half_x, float(i) / per_side), half_z))
	for i: int in per_side:
		pts.append(Vector2(half_x, lerpf(half_z, -half_z, float(i) / per_side)))
	return pts


# Local -Z is a figure's forward, so Basis(UP, yaw) puts it at (-sin, -cos).
func _forward(yaw: float) -> Vector2:
	return Vector2(-sin(yaw), -cos(yaw))


func test_every_seat_faces_the_ice() -> void:
	var loop: PackedVector2Array = _bowl_loop(18.0, 36.0, 12)
	for i: int in loop.size():
		var forward: Vector2 = _forward(ArenaBowlPath.row_facing_yaw(loop, i))
		assert_gt(forward.dot(-loop[i].normalized()), 0.0,
				"seat %d at %v faces inward, not out at the concourse" % [i, loop[i]])


func test_a_straight_rank_shares_one_heading() -> void:
	# The point of the change: down a straight side the row is one rank of seats
	# all square to the boards. A bearing-to-centre heading fans them out instead,
	# and the fan is widest exactly where the side is longest.
	var loop: PackedVector2Array = _bowl_loop(18.0, 36.0, 12)
	# Interior samples of the bottom edge (index 0 and the corner index share a
	# neighbour with another side, so their tangents legitimately blend).
	var straight: float = ArenaBowlPath.row_facing_yaw(loop, 4)
	for i: int in [5, 6, 7, 8]:
		assert_almost_eq(ArenaBowlPath.row_facing_yaw(loop, i), straight, 1e-5,
				"seat %d shares its rank's heading" % i)
	assert_almost_eq(_forward(straight).y, 1.0, 1e-5,
			"the bottom rank looks straight across the rink, toward +z")


func test_a_corner_seat_turns_with_the_arc() -> void:
	# The corners are where a normal-based heading has to move, and it must land
	# between its two neighbouring sides rather than snapping to one of them.
	var loop: PackedVector2Array = _bowl_loop(18.0, 36.0, 12)
	var corner: int = 12  # the turn from the bottom edge onto the -x side
	var forward: Vector2 = _forward(ArenaBowlPath.row_facing_yaw(loop, corner))
	assert_gt(forward.x, 0.0, "a -x-side seat looks back across the rink, toward +x")
	assert_gt(forward.y, 0.0, "and still carries the bottom edge's inward component")
