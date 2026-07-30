extends GutTest

# StickBladeMeshBuilder invariants a display-less run can still check:
# heel-origin bounds tied to the gameplay blade length, the curve bowing to
# the correct side per handedness, outward-facing winding on every strip
# (an inverted quad order renders as a hole — generate_normals derives the
# normals from the winding, so asserting normal direction pins both), and
# the wrapped tape band staying a ribbed skin of the same curve.
#
# Plus the Skater rig integration: the scene's placeholder BoxMesh is
# replaced with the generated mesh at the marker origin, a handedness flip
# regenerates the opposite curve, and the shaft-follow tilt actually pitches
# the blade mesh toe-up when the blade marker rises above the hand (the
# slapshot wind-up / stick-lift pose the old fixed tilt ignored).

const SKATER_SCENE: PackedScene = preload("res://Scenes/Skater.tscn")


func _build(curve_sign: float, inflate: float = 0.0,
		u_start: float = 0.0, u_end: float = 1.0) -> ArrayMesh:
	var p := StickBladeMeshBuilder.Params.new()
	p.curve_sign = curve_sign
	p.inflate = inflate
	p.u_start = u_start
	p.u_end = u_end
	return StickBladeMeshBuilder.build(p)


func _verts(mesh: ArrayMesh) -> PackedVector3Array:
	return mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array

func _norms(mesh: ArrayMesh) -> PackedVector3Array:
	return mesh.surface_get_arrays(0)[Mesh.ARRAY_NORMAL] as PackedVector3Array


func _mean_x(verts: PackedVector3Array, z_max: float) -> float:
	var total: float = 0.0
	var count: int = 0
	for v: Vector3 in verts:
		if v.z < z_max:
			total += v.x
			count += 1
	assert_gt(count, 0, "expected vertices in the toe region")
	return total / float(count)


func test_heel_origin_bounds() -> void:
	var p := StickBladeMeshBuilder.Params.new()
	var verts: PackedVector3Array = _verts(StickBladeMeshBuilder.build(p))
	var mesh_aabb := AABB(verts[0], Vector3.ZERO)
	for v: Vector3 in verts:
		mesh_aabb = mesh_aabb.expand(v)
	# Heel cap at z = 0, toe tip at z = −length (the gameplay heel→toe span).
	assert_almost_eq(mesh_aabb.position.z, -p.length, 0.002, "toe tip at -length")
	assert_almost_eq(mesh_aabb.end.z, 0.0, 0.002, "heel cap at the marker origin")
	# Face height stays the authored blade height.
	assert_almost_eq(mesh_aabb.end.y, p.height * 0.5, 0.002, "top edge at +height/2")
	assert_almost_eq(mesh_aabb.position.y, -p.height * 0.5, 0.002, "bottom edge at -height/2")
	# Lateral: bounded by curve depth + the thickest half cross-section.
	var x_limit: float = p.curve_depth + p.thickness_heel * 0.5 + 0.003
	assert_lt(absf(mesh_aabb.position.x), x_limit, "lateral bound (back)")
	assert_lt(absf(mesh_aabb.end.x), x_limit, "lateral bound (front)")


# Face height at the station ring nearest a depth. The ring's four corners
# straddle that depth by the half-thickness (cross-sections rotate with the
# bow), hence the window rather than an exact match.
func _face_height_at(verts: PackedVector3Array, z: float) -> float:
	var lo: float = INF
	var hi: float = -INF
	for v: Vector3 in verts:
		if absf(v.z - z) > 0.004:
			continue
		lo = minf(lo, v.y)
		hi = maxf(hi, v.y)
	assert_true(is_finite(lo), "expected a station near z = %.3f" % z)
	return hi - lo


# Centerline bow at the station ring nearest a depth: the mean of the front and
# back faces, so the half-thickness cancels out.
func _bow_at(verts: PackedVector3Array, z: float) -> float:
	var total: float = 0.0
	var count: int = 0
	for v: Vector3 in verts:
		if absf(v.z - z) > 0.004:
			continue
		total += v.x
		count += 1
	assert_gt(count, 0, "expected a station near z = %.3f" % z)
	return total / float(count)


func test_toe_keeps_most_of_the_blade_height() -> void:
	# The blade tapers heel→toe and closes on a rounded corner; it does NOT
	# collapse into a fin. Measured just behind the corner arc, where the taper
	# is all that has acted.
	var p := StickBladeMeshBuilder.Params.new()
	var verts: PackedVector3Array = _verts(StickBladeMeshBuilder.build(p))
	var heel_h: float = _face_height_at(verts, 0.0)
	var toe_h: float = _face_height_at(verts, -(p.length - p.toe_round_m))
	assert_almost_eq(toe_h / heel_h, p.height_toe_frac, 0.04, "height taper holds to the corner")
	# The corner then closes on a cap tall enough to read as a blade end rather
	# than a knife point.
	assert_gt(_face_height_at(verts, -p.length), p.height * 0.28, "toe cap keeps a face")


func test_bottom_edge_is_flat_until_the_toe_kick() -> void:
	# A blade rockered end to end rocks on its middle; a real one lies on the
	# ice through the contact zone and lifts only at the toe.
	var p := StickBladeMeshBuilder.Params.new()
	var verts: PackedVector3Array = _verts(StickBladeMeshBuilder.build(p))
	var sole: float = -p.height * 0.5
	var flat_z: float = -p.length * p.toe_kick_start_frac
	var seen: int = 0
	for v: Vector3 in verts:
		if v.z < flat_z or v.y > 0.0:
			continue
		seen += 1
		assert_almost_eq(v.y, sole, 0.0002, "sole is one plane from heel to the kick")
	assert_gt(seen, 8, "sampled the bottom edge over the contact zone")
	# …and the toe lifts clear of it by the kick, no more.
	var toe_bottom: float = INF
	for v: Vector3 in verts:
		if absf(v.z + p.length) < 0.004:
			toe_bottom = minf(toe_bottom, v.y)
	assert_almost_eq(toe_bottom, sole + p.toe_kick_m, 0.0003, "toe kicks off the ice")


func test_curve_eases_in_from_a_straight_heel() -> void:
	# Curvature ramps from zero at the heel, so there is no kink where the bow
	# starts: a third of the way out the centerline has barely left the axis.
	var p := StickBladeMeshBuilder.Params.new()
	var verts: PackedVector3Array = _verts(StickBladeMeshBuilder.build(p))
	var toe_bow: float = _bow_at(verts, -p.length)
	assert_gt(toe_bow, p.curve_depth * 0.8, "toe carries the full bow")
	assert_lt(_bow_at(verts, -p.length / 3.0), toe_bow * 0.15, "heel third stays near-straight")


func test_face_open_twist_leans_the_top_edge_only() -> void:
	# The face-open twist (the visual half of a pattern's face angle) leans
	# the TOP corners toward the convex side, pivoting on the bottom edge —
	# the sole must stay exactly where the untwisted blade put it, and the
	# heel ring must not move at all (the hosel welds to it).
	var flat_p := StickBladeMeshBuilder.Params.new()
	var open_p := StickBladeMeshBuilder.Params.new()
	open_p.face_open_deg = 12.0
	var flat_verts: PackedVector3Array = _verts(StickBladeMeshBuilder.build(flat_p))
	var open_verts: PackedVector3Array = _verts(StickBladeMeshBuilder.build(open_p))
	assert_eq(flat_verts.size(), open_verts.size(), "same topology")
	var max_top_shift: float = 0.0
	for i: int in flat_verts.size():
		var f: Vector3 = flat_verts[i]
		var o: Vector3 = open_verts[i]
		if absf(f.z) < 0.001:
			assert_almost_eq(o.x, f.x, 0.0001, "heel ring pinned (hosel weld)")
		if f.y < -0.02:  # bottom-edge verts
			assert_almost_eq(o.x, f.x, 0.0001, "sole corners never move")
			assert_almost_eq(o.y, f.y, 0.0001, "sole height never moves")
		elif f.y > 0.01 and f.z < -0.2:  # top edge in the toe half
			max_top_shift = maxf(max_top_shift, (o.x - f.x) * signf(flat_p.curve_sign))
	assert_gt(max_top_shift, 0.004, "toe-half top edge leans toward the convex side")


func test_curve_bows_with_handedness_sign() -> void:
	# Deep-toe vertices sit on the bowed centerline; sign +1 (lefty) bows +X.
	assert_gt(_mean_x(_verts(_build(1.0)), -0.27), 0.008, "lefty curve bows +X")
	assert_lt(_mean_x(_verts(_build(-1.0)), -0.27), -0.008, "righty curve bows -X")


func test_winding_outward_every_strip() -> void:
	var mesh: ArrayMesh = _build(1.0)
	var verts: PackedVector3Array = _verts(mesh)
	var norms: PackedVector3Array = _norms(mesh)
	assert_eq(verts.size() % 3, 0, "triangle soup")
	var seen_top: bool = false
	var seen_bottom: bool = false
	var seen_front: bool = false
	var seen_back: bool = false
	var seen_heel_cap: bool = false
	var seen_toe_cap: bool = false
	var tri_count: int = int(verts.size() / 3.0)
	for t in tri_count:
		var c: Vector3 = (verts[t * 3] + verts[t * 3 + 1] + verts[t * 3 + 2]) / 3.0
		var n: Vector3 = norms[t * 3]
		assert_almost_eq(n.length(), 1.0, 0.01, "unit normal")
		# Caps: identified by depth along the blade.
		if absf(n.z) > 0.7:
			if c.z > -0.02:
				seen_heel_cap = true
				assert_gt(n.z, 0.7, "heel cap faces +Z (outward)")
			elif c.z < -0.28:
				seen_toe_cap = true
				assert_lt(n.z, -0.7, "toe cap faces -Z (outward)")
			continue
		# Straight heel zone (no bow, full height): every strip's direction is
		# unambiguous there, and one shared _quad helper means a single caught
		# inversion catches that whole strip.
		if c.z < -0.09:
			continue
		if n.y > 0.75:
			seen_top = true
			assert_gt(c.y, 0.01, "up-facing normals only on the top edge")
		elif n.y < -0.75:
			seen_bottom = true
			assert_lt(c.y, -0.01, "down-facing normals only on the bottom edge")
		elif absf(n.x) > 0.75:
			if c.x > 0.0:
				seen_front = true
				assert_gt(n.x, 0.75, "front face points away from the centerline")
			else:
				seen_back = true
				assert_lt(n.x, -0.75, "back face points away from the centerline")
	assert_true(seen_top and seen_bottom and seen_front and seen_back,
			"all four side strips sampled in the heel zone")
	assert_true(seen_heel_cap and seen_toe_cap, "both end caps sampled")


func _tape_mesh(span: Vector2) -> ArrayMesh:
	return StickBladeMeshBuilder.build_tape(StickBladeMeshBuilder.Params.new(), span)


func test_tape_wraps_hug_the_blade() -> void:
	# The wrapped band stays a tight skin: proud of the blade face by at most
	# the proud-wrap inflate, and never hanging below the sole by more than
	# the sole cap (the old single inflated shell hung 4 mm under the blade
	# and the blade rode on a tape shelf).
	var p := StickBladeMeshBuilder.Params.new()
	var span: Vector2 = StickTapeConfig.new().span_range()  # heel→mid default
	var blade_verts: PackedVector3Array = _verts(StickBladeMeshBuilder.build(p))
	var tape_verts: PackedVector3Array = _verts(_tape_mesh(span))
	var blade_x: float = 0.0
	var blade_top: float = -INF
	for v: Vector3 in blade_verts:
		blade_top = maxf(blade_top, v.y)
		if v.z > -0.09:
			blade_x = maxf(blade_x, v.x)
	var tape_x: float = 0.0
	var tape_bottom: float = INF
	var tape_top: float = -INF
	var tape_z_min: float = INF
	var tape_z_max: float = -INF
	for v: Vector3 in tape_verts:
		tape_bottom = minf(tape_bottom, v.y)
		tape_top = maxf(tape_top, v.y)
		tape_z_min = minf(tape_z_min, v.z)
		tape_z_max = maxf(tape_z_max, v.z)
		if v.z > -0.09:
			tape_x = maxf(tape_x, v.x)
	assert_gt(tape_x, blade_x + 0.0005, "tape sits proud of the blade face")
	assert_lt(tape_x, blade_x + 0.0022, "…but stays a skin, not a shell")
	assert_gt(tape_top, blade_top + 0.0005, "tape shows over the top edge")
	assert_gt(tape_bottom, -p.height * 0.5 - 0.0008, "sole projection capped")
	assert_gt(tape_z_max, 0.001, "heel span overhangs the heel cap (no z-fight)")
	assert_between(tape_z_min, -0.20, -0.17, "band ends around 62% of the blade")


func test_tape_renders_discrete_wraps() -> void:
	# Each wrap band carries its own end caps, so a wrapped span shows ribbed
	# seams instead of one smooth strip: many more ±Z-facing triangles than
	# the two caps a single band would have.
	var mesh: ArrayMesh = _tape_mesh(Vector2(-0.02, 1.0))  # FULL span
	var verts: PackedVector3Array = _verts(mesh)
	var norms: PackedVector3Array = _norms(mesh)
	var cap_tris: int = 0
	var tri_count: int = int(verts.size() / 3.0)
	for t in tri_count:
		if absf(norms[t * 3].z) > 0.9:
			cap_tris += 1
	assert_gt(cap_tris, 20, "many wrap-edge caps across the span")


func test_tape_span_none_returns_null() -> void:
	assert_null(_tape_mesh(Vector2(0.0, 0.0)), "degenerate span builds nothing")


func test_hosel_extends_up_the_shaft_line() -> void:
	var p := StickBladeMeshBuilder.Params.new()
	p.hosel_length = 0.085
	var mesh: ArrayMesh = StickBladeMeshBuilder.build(p)
	var verts: PackedVector3Array = _verts(mesh)
	var norms: PackedVector3Array = _norms(mesh)
	var lie: float = deg_to_rad(p.hosel_angle_deg)
	var axis := Vector3(0.0, sin(lie), cos(lie))
	# The throat replaces the flat heel cap and climbs up-and-back along the
	# shaft line (heel-ward is +Z in blade space).
	var z_max: float = -INF
	var y_max: float = -INF
	for v: Vector3 in verts:
		z_max = maxf(z_max, v.z)
		y_max = maxf(y_max, v.y)
	assert_gt(z_max, 0.04, "hosel reaches behind the heel along the shaft")
	assert_gt(y_max, 0.05, "hosel climbs above the blade's top edge")
	# Base ring center: the heel cross-section's midpoint. The bottom edge is
	# flat at the heel (the kick is at the toe), so mid sits on the origin.
	var base_center := Vector3.ZERO
	var seen_tip_cap: bool = false
	var tri_count: int = int(verts.size() / 3.0)
	for t in tri_count:
		var c: Vector3 = (verts[t * 3] + verts[t * 3 + 1] + verts[t * 3 + 2]) / 3.0
		var n: Vector3 = norms[t * 3]
		# The old flat heel cap (+Z normal) must be gone; the only strongly
		# +Z-ish normal left is the tip cap, which faces along the shaft axis.
		assert_lt(n.z, 0.9, "no flat heel cap remains once the hosel replaces it")
		if n.dot(axis) > 0.9:
			seen_tip_cap = true
			continue
		# Hosel strips: outward-wound cross-sections around the shaft axis —
		# every normal points away from its station's point on the axis.
		if c.z > 0.01:
			var axis_point: Vector3 = base_center + axis * (c - base_center).dot(axis)
			assert_gt(n.dot(c - axis_point), 0.0, "hosel strip winds outward")
	assert_true(seen_tip_cap, "tip cap faces along the shaft axis")


# ── Skater rig integration ────────────────────────────────────────────────────

func _make_skater() -> Skater:
	var skater: Skater = SKATER_SCENE.instantiate() as Skater
	add_child_autofree(skater)
	skater.set_physics_process(false)
	skater.set_process(false)
	return skater


func test_skater_installs_generated_blade_at_marker_origin() -> void:
	var skater: Skater = _make_skater()
	var blade_mesh: MeshInstance3D = skater.blade.get_node("MeshInstance3D") as MeshInstance3D
	assert_not_null(blade_mesh.mesh as ArrayMesh, "placeholder BoxMesh replaced")
	assert_eq(blade_mesh.position, Vector3.ZERO, "heel-origin mesh seated at the marker")
	var z_max: float = -INF
	for v: Vector3 in _verts(blade_mesh.mesh as ArrayMesh):
		z_max = maxf(z_max, v.z)
	assert_gt(z_max, 0.04, "skater blade carries the hosel taper")


func test_handedness_flip_regenerates_opposite_curve() -> void:
	var skater: Skater = _make_skater()
	var blade_mesh: MeshInstance3D = skater.blade.get_node("MeshInstance3D") as MeshInstance3D
	assert_gt(_mean_x(_verts(blade_mesh.mesh as ArrayMesh), -0.27), 0.008,
			"default lefty curve bows +X")
	skater.is_left_handed = false
	assert_lt(_mean_x(_verts(blade_mesh.mesh as ArrayMesh), -0.27), -0.008,
			"flip to righty regenerates the -X curve")


func test_tape_config_drives_the_tape_node() -> void:
	var skater: Skater = _make_skater()
	var blade_mesh: MeshInstance3D = skater.blade.get_node("MeshInstance3D") as MeshInstance3D
	# A toe-span job builds a wrap over the toe half only.
	skater.set_tape_config(StickTapeConfig.new(1, StickTapeConfig.Span.TOE, 1))
	var tape: MeshInstance3D = blade_mesh.get_node_or_null("BladeTape") as MeshInstance3D
	assert_not_null(tape, "tape node exists for a taped span")
	var z_max: float = -INF
	for v: Vector3 in _verts(tape.mesh as ArrayMesh):
		z_max = maxf(z_max, v.z)
	assert_lt(z_max, -0.14, "toe-span tape stays on the toe half")
	# A bare job removes the node outright.
	skater.set_tape_config(StickTapeConfig.new(1, StickTapeConfig.Span.NONE, 1))
	assert_null(blade_mesh.get_node_or_null("BladeTape"), "bare blade has no tape node")


func test_shaft_follow_pitch_tips_blade_with_raised_shaft() -> void:
	var skater: Skater = _make_skater()
	var blade_mesh: MeshInstance3D = skater.blade.get_node("MeshInstance3D") as MeshInstance3D
	# Rest-lie shaft (~42°, hand above the blade): the blade lies near-flat.
	skater.set_top_hand_position(Vector3(0.24, -0.10, 0.0))
	skater.set_blade_position(Vector3(0.24, -1.0, -1.0))
	skater._apply_blade_tilt()
	var toe_dir: Vector3 = -blade_mesh.transform.basis.z
	assert_lt(absf(toe_dir.y), 0.25, "near-rest lie leaves the blade near-flat")
	# Slapshot-wind-up-like shaft (blade ABOVE the hand): the blade must pitch
	# toe-up with the shaft instead of floating ice-parallel.
	skater.set_blade_position(Vector3(0.4, 0.4, -0.4))
	skater._apply_blade_tilt()
	toe_dir = -blade_mesh.transform.basis.z
	assert_gt(toe_dir.y, 0.7, "raised shaft pitches the blade toe-up")
