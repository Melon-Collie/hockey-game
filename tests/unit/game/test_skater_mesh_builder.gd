extends GutTest

# SkaterMeshBuilder invariants a display-less run can still check. Three
# things break silently if a generator drifts, and each is pinned here:
#
#   1. Winding — Godot front faces are clockwise-from-outside, so an outward-
#      wound closed solid has NEGATIVE signed volume. An inside-out part still
#      "works" headless but renders as a hollow shell in game.
#   2. UV conventions — SkaterUniformCoordinator paints against the engine
#      primitive layouts (cylinder side V ∈ [0, 0.5], sphere equirect V ∈
#      [0, 1], everything inside [0, 1]). A part whose UVs drift out of range
#      wraps its jersey paint somewhere unintended.
#   3. Envelope — each part must stay inside the primitive it replaced (plus
#      millimetres), because ice contact, board clearance, and the gear that
#      overlaps it were all tuned around the primitive silhouettes.
#
# Proportion changes inside those bounds are free — this suite deliberately
# pins none of the shaping.

const _EPS: float = 0.005  # envelope tolerance, metres


class PartSpec:
	var label: String
	var mesh: ArrayMesh
	var max_size: Vector3
	var side_only_v: bool  # lathed part: side V capped at 0.5 (caps use the rest)
	# Which surface of `mesh` carries this piece. A part that splits into
	# separately-paintable pieces (the boot's quarter and toe cap, the blade's
	# holder and runner, the fist's back and fingers) is ONE mesh of several
	# surfaces, and every piece has to hold the winding/UV/envelope contract on
	# its own — a split that leaves a half open is invisible until it renders.
	var surface: int

	func _init(p_label: String, p_mesh: ArrayMesh, p_max: Vector3, p_side: bool,
			p_surface: int = 0) -> void:
		label = p_label
		mesh = p_mesh
		max_size = p_max
		side_only_v = p_side
		surface = p_surface


# Envelopes come from the primitives in Scenes/Skater.tscn: torso cylinder
# r 0.22 h 0.55, helmet sphere r 0.155, hip r 0.13, knee r 0.095, thigh
# cylinder r 0.14 h 0.3, sock r 0.09 h 0.3, skate r 0.09 h 0.2, foot prolate
# sphere r 0.08 half-length 0.125. Two deliberate exceptions: the shoulder cap
# is prolate along its pole (it leans along the arm, high on the torso — no
# ice/boards to poke), and the arm-rig meshes are unit-sized (node scale is
# the real dimension), so their bounds are the nominal unit envelopes.
func _parts() -> Array[PartSpec]:
	return [
		PartSpec.new("torso", SkaterMeshBuilder._build_torso(),
				Vector3(0.47, 0.55, 0.44), true),
		PartSpec.new("helmet", SkaterMeshBuilder._build_helmet(),
				Vector3(0.31, 0.31, 0.31), false),
		PartSpec.new("head", SkaterMeshBuilder._build_ball(
				SkaterMeshBuilder.HEAD_RADIUS, 10, 5, 1.0),
				Vector3(0.27, 0.27, 0.27), false),
		PartSpec.new("neck", SkaterMeshBuilder._build_neck(),
				Vector3(0.19, 0.10, 0.19), true),
		PartSpec.new("blade_holder", SkaterMeshBuilder._build_skate_blade(),
				Vector3(0.02, 0.19, 0.06), false, SkaterMeshBuilder.BLADE_PART_HOLDER),
		PartSpec.new("blade_runner", SkaterMeshBuilder._build_skate_blade(),
				Vector3(0.01, 0.19, 0.04), false, SkaterMeshBuilder.BLADE_PART_RUNNER),
		PartSpec.new("shoulder", SkaterMeshBuilder._build_shoulder(),
				Vector3(0.21, 0.28, 0.21), false),
		PartSpec.new("arm_bone", SkaterMeshBuilder.shared_arm_bone(),
				Vector3(2.0, 1.0, 2.0), true),
		PartSpec.new("joint_ball", SkaterMeshBuilder.shared_joint_ball(),
				Vector3(2.0, 2.0, 2.0), false),
		PartSpec.new("glove_back", SkaterMeshBuilder.shared_glove_fist(),
				Vector3(2.2, 1.0, 2.0), false, SkaterMeshBuilder.FIST_PART_BACK),
		PartSpec.new("glove_fingers", SkaterMeshBuilder.shared_glove_fist(),
				Vector3(2.2, 1.0, 2.0), false, SkaterMeshBuilder.FIST_PART_FINGERS),
		PartSpec.new("cuff", SkaterMeshBuilder.shared_cuff(),
				Vector3(2.0, SkaterMeshBuilder.CUFF_HEIGHT_M, 2.0), true),
		PartSpec.new("knob", SkaterMeshBuilder.shared_knob(),
				Vector3(0.07, SkaterMeshBuilder.KNOB_HEIGHT_M, 0.07), true),
		# Hip re-pinned +0.02 over the replaced r-0.13 ball: deliberately
		# inflated to fill the seat under the torso's rear sway (the seat's
		# rearward bias itself is scene node placement, not mesh).
		PartSpec.new("hip", SkaterMeshBuilder._build_hip(),
				Vector3(0.28, 0.28, 0.28), false),
		PartSpec.new("knee", SkaterMeshBuilder._build_knee(),
				Vector3(0.19, 0.19, 0.19), false),
		PartSpec.new("thigh", SkaterMeshBuilder._build_thigh(),
				Vector3(0.29, 0.30, 0.28), true),
		PartSpec.new("sock", SkaterMeshBuilder._build_sock(),
				Vector3(0.19, 0.30, 0.19), true),
		PartSpec.new("skate", SkaterMeshBuilder._build_skate(),
				Vector3(0.18, 0.20, 0.18), true),
		# Boot length re-pinned +0.02 over the replaced prolate sphere: the
		# heel counter deliberately runs the quarter back under the skate
		# collar's footprint. Heel-ward only — toward the shin column, with
		# the extension's sole tucked above the tread line — so the tuned
		# ice/board contact silhouette is unchanged.
		PartSpec.new("boot_quarter", SkaterMeshBuilder._build_boot(),
				Vector3(0.16, 0.21, 0.16), false, SkaterMeshBuilder.BOOT_PART_QUARTER),
		PartSpec.new("boot_toe", SkaterMeshBuilder._build_boot(),
				Vector3(0.13, 0.08, 0.13), false, SkaterMeshBuilder.BOOT_PART_TOE),
	]


func test_every_part_is_wound_outward() -> void:
	for part: PartSpec in _parts():
		var vol: float = _signed_volume(part.mesh, part.surface)
		assert_lt(vol, -1e-7,
				"%s should be a closed outward-wound solid (negative signed volume)"
				% part.label)


func test_every_part_has_unit_flat_normals() -> void:
	# Degenerate pole quads are allowed a zero-area filler triangle; every
	# triangle with real area must carry a unit normal (flat shading gives one
	# normal per face, so a bad one shows as a black facet).
	for part: PartSpec in _parts():
		var arrays: Array = part.mesh.surface_get_arrays(part.surface)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var bad: int = 0
		for i in range(0, verts.size(), 3):
			var area2: float = (verts[i + 1] - verts[i]).cross(verts[i + 2] - verts[i]).length()
			if area2 > 1e-9 and absf(normals[i].length() - 1.0) > 0.01:
				bad += 1
		assert_eq(bad, 0, "%s should have unit normals on every real face" % part.label)


func test_uvs_stay_inside_painter_conventions() -> void:
	for part: PartSpec in _parts():
		var arrays: Array = part.mesh.surface_get_arrays(part.surface)
		var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var v_side_max: float = 0.0
		for uv: Vector2 in uvs:
			assert_between(uv.x, 0.0, 1.0, "%s U inside [0, 1]" % part.label)
			assert_between(uv.y, 0.0, 1.0, "%s V inside [0, 1]" % part.label)
			if part.side_only_v and uv.y <= 0.5:
				v_side_max = maxf(v_side_max, uv.y)
		if part.side_only_v:
			# The side band should actually reach (near) the 0.5 boundary —
			# a shrunken V range would squash the stripe bands visibly.
			assert_gt(v_side_max, 0.45,
					"%s side V should span up to ~0.5 like the engine cylinder" % part.label)


func test_every_part_stays_inside_its_primitive_envelope() -> void:
	for part: PartSpec in _parts():
		var size: Vector3 = _surface_bounds(part.mesh, part.surface).size
		for axis in 3:
			assert_lt(size[axis], part.max_size[axis] + _EPS,
					"%s axis %d should stay inside the replaced primitive's envelope"
					% [part.label, axis])


func test_arm_rig_meshes_keep_their_placement_dimensions() -> void:
	# These heights are PLACEMENT inputs, not just looks: the bone wrapper's
	# per-frame Z scale assumes a unit-height prism, and the cuff/knob sit
	# offset along their bone by half their baked height (Skater reads the
	# CUFF_HEIGHT_M / KNOB_HEIGHT_M constants). A drifted mesh height slides
	# every cuff off the wrist silently.
	assert_almost_eq(SkaterMeshBuilder.shared_arm_bone().get_aabb().size.y, 1.0, 0.001,
			"bone prism must be unit height")
	assert_almost_eq(SkaterMeshBuilder.shared_cuff().get_aabb().size.y,
			SkaterMeshBuilder.CUFF_HEIGHT_M, 0.001,
			"cuff mesh height must match CUFF_HEIGHT_M")
	assert_almost_eq(SkaterMeshBuilder.shared_knob().get_aabb().size.y,
			SkaterMeshBuilder.KNOB_HEIGHT_M, 0.001,
			"knob mesh height must match KNOB_HEIGHT_M")


func test_helmet_opens_at_the_face() -> void:
	# The helmet shell's rim must sit brow-high at the front (−Z, exposing
	# the head ball's face) and reach lower at the back — the asymmetry that
	# makes it read as a helmet over a head rather than a full ball. Compare
	# the lowest vertex on each half.
	var mesh: ArrayMesh = SkaterMeshBuilder._build_helmet()
	var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var front_min_y: float = INF
	var back_min_y: float = INF
	for v: Vector3 in verts:
		if v.z < -0.05:
			front_min_y = minf(front_min_y, v.y)
		elif v.z > 0.05:
			back_min_y = minf(back_min_y, v.y)
	assert_gt(front_min_y, back_min_y + 0.03,
			"the helmet rim should sit meaningfully higher at the face than the back")


func test_skate_blade_reaches_the_lifted_ice_depth() -> void:
	# The foot node's local +Z is down; the replaced foot sphere bottomed out
	# at z = +0.08 ≈ the ice, and the on-skates stance lifts the body roots by
	# SKATE_LIFT_M with the steel reaching correspondingly deeper. The runner
	# must land exactly there (shallower floats the skate, deeper sinks it).
	var aabb: AABB = SkaterMeshBuilder._build_skate_blade().get_aabb()
	assert_almost_eq(aabb.position.z + aabb.size.z,
			0.08 + SkaterMeshBuilder.SKATE_LIFT_M, 0.002,
			"the steel runner should bottom out at the lifted ice-contact depth")
	# The boot itself must stay well above the ice — the blade carries it.
	var boot: AABB = SkaterMeshBuilder._build_boot().get_aabb()
	assert_lt(boot.position.z + boot.size.z, 0.05,
			"the boot sole should ride on the blade, clear of the ice")


# Face gear is the one open-sheet family (millimetre glazing and cage wire —
# no closed solid to sign-check), so it gets its own contract instead of a
# PartSpec row: bare and forged picks carry no mesh, and every real piece
# stays on the face — inside the shield radius, in the helmet's front half
# (the face is −Z), and below the brow rim so nothing pokes through the shell
# dome. The visor-vs-fishbowl depth split is design intent worth pinning too:
# a visor that reaches the chin IS a fishbowl.
func test_face_gear_pieces_sit_on_the_face() -> void:
	assert_null(SkaterMeshBuilder.shared_face_gear(GearModelRegistry.FACE_NONE),
			"bare carries no mesh")
	assert_null(SkaterMeshBuilder.shared_face_gear(-1), "forged picks carry no mesh")
	assert_null(SkaterMeshBuilder.shared_face_gear(99), "forged picks carry no mesh")
	var brow_y: float = 0.158 * cos(PI * 0.40) + 0.005
	for option: int in [GearModelRegistry.FACE_VISOR, GearModelRegistry.FACE_CAGE,
			GearModelRegistry.FACE_FISHBOWL]:
		var mesh: ArrayMesh = SkaterMeshBuilder.shared_face_gear(option)
		assert_not_null(mesh, "option %d has a mesh" % option)
		var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		assert_gt(verts.size(), 0, "option %d has geometry" % option)
		for v: Vector3 in verts:
			assert_lt(v.length(), 0.158 + 0.001,
					"option %d stays inside the shield radius" % option)
			assert_lt(v.z, 0.001, "option %d stays on the face half" % option)
			assert_lt(v.y, brow_y, "option %d stays under the brow rim" % option)
	var visor: AABB = _surface_bounds(
			SkaterMeshBuilder.shared_face_gear(GearModelRegistry.FACE_VISOR), 0)
	var bowl: AABB = _surface_bounds(
			SkaterMeshBuilder.shared_face_gear(GearModelRegistry.FACE_FISHBOWL), 0)
	assert_gt(visor.position.y, -0.05, "the visor stops above the mouth")
	assert_lt(bowl.position.y, -0.10, "the fishbowl covers past the chin")


# One surface's own bounds. ArrayMesh.get_aabb() unions every surface, which
# would let a piece drift outside its envelope as long as a sibling covered it.
func _surface_bounds(mesh: ArrayMesh, surface: int) -> AABB:
	var verts: PackedVector3Array = mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]
	var bounds := AABB(verts[0], Vector3.ZERO)
	for v: Vector3 in verts:
		bounds = bounds.expand(v)
	return bounds


func _signed_volume(mesh: ArrayMesh, surface: int = 0) -> float:
	var arrays: Array = mesh.surface_get_arrays(surface)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var total: float = 0.0
	for i in range(0, verts.size(), 3):
		total += verts[i].dot(verts[i + 1].cross(verts[i + 2])) / 6.0
	return total


# The upper-body and leg rigs are only exact replacements for the nodes they replaced
# because every vertex is RIGID — weight 1.0 on one bone, nothing on the other
# three. Blended weights would make a bone pose an approximation of the node
# transform it stands in for, and the pose diff would start reporting drift with
# no obvious cause. Cheap to check here, invisible in a render.
func test_skinned_rigs_are_rigidly_weighted() -> void:
	var rigs: Array = [
		["upper", SkaterMeshBuilder.shared_upper_skin_mesh(),
				SkaterMeshBuilder.UPPER_SURFACE_COUNT, SkaterMeshBuilder.UPPER_BONE_COUNT],
		["leg", SkaterMeshBuilder.shared_leg_skin_mesh(),
				SkaterMeshBuilder.LEG_SURFACE_COUNT, SkaterMeshBuilder.LEG_BONE_COUNT],
	]
	for rig: Array in rigs:
		var label: String = rig[0]
		var mesh: ArrayMesh = rig[1]
		assert_eq(mesh.get_surface_count(), int(rig[2]),
				"%s rig surface count must match its enum" % label)
		for surface: int in mesh.get_surface_count():
			var arrays: Array = mesh.surface_get_arrays(surface)
			var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
			var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
			var verts: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			assert_eq(bones.size(), verts * 4,
					"%s surface %d needs four bone influences per vertex" % [label, surface])
			var bone: int = bones[0]
			assert_between(bone, 0, int(rig[3]) - 1,
					"%s surface %d bone index in range" % [label, surface])
			var uniform_bone: bool = true
			var rigid: bool = true
			for v: int in verts:
				if bones[v * 4] != bone:
					uniform_bone = false
				if not is_equal_approx(weights[v * 4], 1.0) \
						or weights[v * 4 + 1] != 0.0 \
						or weights[v * 4 + 2] != 0.0 \
						or weights[v * 4 + 3] != 0.0:
					rigid = false
			assert_true(uniform_bone,
					"%s surface %d must ride ONE bone" % [label, surface])
			assert_true(rigid,
					"%s surface %d must be weight 1.0 on that bone alone" % [label, surface])
