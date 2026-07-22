extends GutTest

# SweptDiscOBB — swept-sphere vs oriented-box contact. Tests hit/miss, the entry-face
# normal (axis-aligned and rotated boxes), the radius (grazing) contribution, and the
# already-overlapping case.

const R: float = 0.065  # ~PUCK_COLLISION_RADIUS


func _unit_box(pos: Vector3, basis: Basis = Basis.IDENTITY) -> Transform3D:
	return Transform3D(basis, pos)


func test_head_on_hit_reports_facing_normal() -> void:
	# Box at origin (half 0.5); puck slides +X into its -X face from outside.
	var res := SweptDiscOBB.Result.new()
	var hit: bool = SweptDiscOBB.contact(
		Vector3(-2, 0, 0), Vector3(0, 0, 0), R,
		_unit_box(Vector3.ZERO), Vector3(0.5, 0.5, 0.5), res)
	assert_true(hit, "puck driven into the box should contact it")
	assert_almost_eq(res.normal.x, -1.0, 0.01, "outward normal points back along -X")
	assert_lt(res.toi, 1.0)
	assert_gt(res.toi, 0.0)


func test_clean_miss_returns_false() -> void:
	# Puck passes well above the box (Y offset beyond half+radius).
	var res := SweptDiscOBB.Result.new()
	var hit: bool = SweptDiscOBB.contact(
		Vector3(-2, 2, 0), Vector3(2, 2, 0), R,
		_unit_box(Vector3.ZERO), Vector3(0.5, 0.5, 0.5), res)
	assert_false(hit, "a pass 2 m above a 0.5 m box is a miss")


func test_radius_enables_a_grazing_hit() -> void:
	# Puck center passes 0.54 m from the box center on Z — just outside the 0.5 half but
	# inside 0.5 + radius, so the disc grazes the +Z face.
	var res := SweptDiscOBB.Result.new()
	var graze: bool = SweptDiscOBB.contact(
		Vector3(-2, 0, 0.54), Vector3(2, 0, 0.54), R,
		_unit_box(Vector3.ZERO), Vector3(0.5, 0.5, 0.5), res)
	assert_true(graze, "disc radius should turn a near-miss into a graze")
	# Same path without radius would miss (center outside the box).
	var res2 := SweptDiscOBB.Result.new()
	var no_r: bool = SweptDiscOBB.contact(
		Vector3(-2, 0, 0.54), Vector3(2, 0, 0.54), 0.0,
		_unit_box(Vector3.ZERO), Vector3(0.5, 0.5, 0.5), res2)
	assert_false(no_r, "zero-radius center path outside the box misses")


func test_rotated_box_normal_follows_orientation() -> void:
	# Box yaw-rotated 45°; a puck coming straight down +... hits a face whose normal is
	# the rotated axis, not world-axis-aligned.
	var res := SweptDiscOBB.Result.new()
	var b := Basis(Vector3.UP, deg_to_rad(45.0))
	var hit: bool = SweptDiscOBB.contact(
		Vector3(-2, 0, -2), Vector3(0, 0, 0), R,
		_unit_box(Vector3.ZERO, b), Vector3(0.5, 0.5, 0.5), res)
	assert_true(hit)
	# Normal should be unit length and horizontal (a side face of a yaw-rotated box).
	assert_almost_eq(res.normal.length(), 1.0, 0.01)
	assert_almost_eq(res.normal.y, 0.0, 0.01, "side-face normal of a yaw box is horizontal")


func test_already_overlapping_is_a_contact_at_toi_zero() -> void:
	# prev already inside the box → immediate contact.
	var res := SweptDiscOBB.Result.new()
	var hit: bool = SweptDiscOBB.contact(
		Vector3(0.1, 0, 0), Vector3(0.2, 0, 0), R,
		_unit_box(Vector3.ZERO), Vector3(0.5, 0.5, 0.5), res)
	assert_true(hit, "starting inside the box is a contact")
	assert_almost_eq(res.toi, 0.0, 0.001, "already-overlapping contacts at toi 0")


func test_surface_hit_has_zero_depth() -> void:
	# A clean from-outside contact needs no depenetration: point (the centre at toi)
	# already rests on the expanded surface, so depth must be 0 — the eject is
	# `point + normal * depth`, and a non-zero depth here would pop the puck off
	# the face it just touched.
	var res := SweptDiscOBB.Result.new()
	assert_true(SweptDiscOBB.contact(
		Vector3(-2, 0, 0), Vector3(0, 0, 0), R,
		_unit_box(Vector3.ZERO), Vector3(0.5, 0.5, 0.5), res))
	assert_almost_eq(res.depth, 0.0, 1e-6)


func test_stationary_overlap_is_detected_with_min_penetration_normal() -> void:
	# Zero-length sweep fully inside the box — the goalie dropped ONTO a resting
	# puck. The ray slab test alone cannot see this (every axis is parallel); it
	# must still report a contact, normal along the MINIMUM-penetration axis
	# (nearest face), with depth pushing the centre back to that face.
	var res := SweptDiscOBB.Result.new()
	var hit: bool = SweptDiscOBB.contact(
		Vector3(0.4, 0.1, 0.0), Vector3(0.4, 0.1, 0.0), R,
		_unit_box(Vector3.ZERO), Vector3(0.5, 0.5, 0.5), res)
	assert_true(hit, "a resting puck inside a box is a contact")
	assert_almost_eq(res.toi, 0.0, 0.001)
	assert_almost_eq(res.normal.x, 1.0, 0.01, "nearest face is +X (0.4 of 0.5+R)")
	# Push-out lands the centre on the expanded (+X) surface: 0.4 + depth == 0.5 + R.
	assert_almost_eq(res.depth, 0.5 + R - 0.4, 0.001)


func test_stationary_outside_is_a_miss() -> void:
	# Zero-length sweep clear of the box — no phantom contact from the overlap path.
	var res := SweptDiscOBB.Result.new()
	assert_false(SweptDiscOBB.contact(
		Vector3(2.0, 0.0, 0.0), Vector3(2.0, 0.0, 0.0), R,
		_unit_box(Vector3.ZERO), Vector3(0.5, 0.5, 0.5), res))


func test_start_inside_normal_is_nearest_face_and_depth_ejects() -> void:
	# Start-inside with motion: the honest normal is the nearest face of the START
	# point (min penetration), not the backward-extrapolated entry slab — under the
	# analytic drive this normal drives the save response. Start near the +Z face,
	# moving +X: entry-slab extrapolation would blame an X face; nearest is +Z.
	var res := SweptDiscOBB.Result.new()
	var hit: bool = SweptDiscOBB.contact(
		Vector3(0.0, 0.0, 0.45), Vector3(0.1, 0.0, 0.45), R,
		_unit_box(Vector3.ZERO), Vector3(0.5, 0.5, 0.5), res)
	assert_true(hit)
	assert_almost_eq(res.normal.z, 1.0, 0.01, "min-penetration axis is +Z")
	assert_almost_eq(res.depth, 0.5 + R - 0.45, 0.001)


func test_translated_box_hit_point_is_world_space() -> void:
	# Box centered at (5, 0, 5); puck driven into it — contact point near the box, not
	# near the origin (verifies the world transform is applied).
	var res := SweptDiscOBB.Result.new()
	var hit: bool = SweptDiscOBB.contact(
		Vector3(3, 0, 5), Vector3(5, 0, 5), R,
		_unit_box(Vector3(5, 0, 5)), Vector3(0.5, 0.5, 0.5), res)
	assert_true(hit)
	assert_lt(res.point.x, 5.0, "contact is on the near (-X) side of the box")
	assert_gt(res.point.x, 4.0, "but close to it")
	assert_almost_eq(res.normal.x, -1.0, 0.01)
