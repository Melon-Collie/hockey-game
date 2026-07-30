class_name SkaterMeshBuilder
extends RefCounted

# Low-poly faceted replacements for the skater's part meshes: shaped torso,
# helmeted head, deltoid shoulder caps, hip/knee balls, thighs, socks, skate
# cuffs, and boots with a blade runner (swapped in during Skater._ready()),
# plus the shared_* meshes the code-created arm rig builds from (bone prisms,
# joint balls, glove cuffs, stick knob). Cosmetic only — gameplay reads the
# Marker3D anchors and collision shapes, never these meshes.
#
# The arm-rig meshes are baked at UNIT radius and resized by node scale
# (creation sites in Skater, per-attribute resizing in
# SkaterAppearanceCoordinator) — never by mesh mutation, so every skater can
# share one cached mesh.
#
# UV layouts replicate the Godot primitives they replace, because
# SkaterUniformCoordinator paints against those exact conventions:
#   - Lathed (cylinder-style) parts: side U wraps from +Z toward +X with the
#     side occupying V ∈ [0, 0.5] top→bottom; the top cap disk lands in the
#     U ∈ [0, 0.5], V ∈ [0.5, 1] quadrant (where the jersey yoke paints), the
#     bottom cap in U ∈ [0.5, 1] of the same half.
#   - Ball (sphere-style) parts: equirect, U from +Z toward +X, V from 0 at
#     the top pole to 1 at the bottom (where the shoulder-number decal paints).
# Change a painter convention there and the matching generator here together.
#
# Everything is flat-shaded (smooth_group(-1)) — the faceting IS the art
# style; per-face normals are what make the shaped silhouettes read. Meshes
# build once into a static cache shared by every skater: per-skater color is
# material_override and body-build sizing is node scale, so sharing is safe.

# Profiles are (y, radius) stations top→bottom in the part's mesh-local frame,
# spanning the same envelope as the primitive each replaces (heights and radii
# from Scenes/Skater.tscn) so nothing pokes through ice, boards, or gear that
# was tuned around the primitive silhouettes.
const _TORSO_PROFILE: Array[Vector2] = [
	Vector2(0.275, 0.158),   # trap line — stays wide so the deltoid caps emerge from it
	Vector2(0.245, 0.198),
	Vector2(0.130, 0.208),   # chest
	Vector2(0.000, 0.196),   # waist tuck
	Vector2(-0.150, 0.204),
	Vector2(-0.230, 0.214),
	Vector2(-0.275, 0.222),  # jersey hem flare
]
const _THIGH_PROFILE: Array[Vector2] = [
	Vector2(0.150, 0.142),
	Vector2(0.050, 0.139),
	Vector2(-0.080, 0.129),
	Vector2(-0.150, 0.118),
]
const _SOCK_PROFILE: Array[Vector2] = [
	Vector2(0.150, 0.088),
	Vector2(0.070, 0.094),   # calf bulge
	Vector2(-0.040, 0.086),
	Vector2(-0.150, 0.076),  # ankle
]
const _SKATE_PROFILE: Array[Vector2] = [
	Vector2(0.100, 0.090),   # boot collar
	Vector2(0.020, 0.083),
	Vector2(-0.100, 0.075),
]

# Chest reads wider than deep — lateral/depth scale on the torso lathe. The
# legs keep circular sections (hockey pants and socks are round enough).
const _TORSO_X_SCALE: float = 1.05
const _TORSO_Z_SCALE: float = 0.88

const _TORSO_SIDES: int = 10   # back number spans ~3 facets — creased, still legible
const _LEG_SIDES: int = 8

# Head + helmet. The scene's Helmet node carries the helmet SHELL (painted
# the kit's helmet color, scaled by the appearance rig); the builder parents
# a "Head" MeshInstance3D under it so both share the node's transform. The
# shell's lower edge varies with azimuth — brow-high at the face (−Z,
# leaving the head visible), ear-low on the sides, lowest at the back — via
# cut_v(θ) = CUT_BASE + CUT_BACK_BIAS·cos(θ) in equirect latitude fractions
# (θ = 0 is +Z, the back).
const _HELMET_RADIUS: float = 0.155
const _HELMET_CUT_BASE: float = 0.69
const _HELMET_CUT_BACK_BIAS: float = 0.11
const HEAD_RADIUS: float = 0.135
# Placeholder skin — deliberately shocking pink so the head/helmet split is
# unmistakable in playtests until real skin tones arrive.
const HEAD_COLOR := Color(1.0, 0.2, 0.75)

# Shoulder cap: a prolate deltoid pad, elongated along its local +Y pole. The
# pole is NOT static — Skater._orient_shoulder_cap leans it toward the arm's
# live upper-arm direction each rig update, so the elongation must read as
# "along the arm", not "tall". Slightly narrower than the ball it replaced;
# the length makes up the presence.
const _SHOULDER_RADIUS: float = 0.105
const _SHOULDER_Y_SCALE: float = 1.3

const _HIP_RADIUS: float = 0.13
const _KNEE_RADIUS: float = 0.095

# Arm-rig fixed dimensions. The cuff/knob heights are placement inputs on the
# skater side (_update_cuff_transform / _update_stick_knob offset along the
# bone by half the height), so they live here with the geometry they measure.
const _ARM_TAPER: float = 0.88   # distal end radius fraction (top of mesh = proximal)
const CUFF_HEIGHT_M: float = 0.06
const KNOB_HEIGHT_M: float = 0.05
const _KNOB_TOP_RADIUS: float = 0.035
const _KNOB_BOTTOM_RADIUS: float = 0.03

# Boot stations heel→toe in the Foot node's local frame. That node's scene
# transform is rotated: local −Y is the toe direction, local +Z is DOWN, X is
# lateral (see the FootL/R note in SkaterAppearanceCoordinator). Each station
# is (y, half_width, top_z, sole_z) — top_z is negative (up), sole_z positive
# (down). Envelope matches the prolate foot sphere it replaces (r 0.08, half
# length 0.125).
const _BOOT_STATIONS: Array[Vector4] = [
	Vector4(0.115, 0.052, -0.040, 0.045),   # heel
	Vector4(0.045, 0.060, -0.072, 0.046),   # instep rise
	Vector4(-0.045, 0.058, -0.048, 0.046),  # forefoot
	Vector4(-0.115, 0.040, -0.012, 0.040),  # toe
]
# Blade runner under the sole: a thin fin from just under the boot down to the
# replaced sphere's bottom extent (local z 0.08 ≈ the ice), inset from both
# boot ends the way real runners are.
const _BLADE_HALF_W: float = 0.006
const _BLADE_Y_MIN: float = -0.088
const _BLADE_Y_MAX: float = 0.098
const _BLADE_Z_TOP: float = 0.044
const _BLADE_Z_BOT: float = 0.080

static var _cache: Dictionary = {}


# Swaps every scene-primitive part mesh under the two body roots for its
# cached low-poly build. Idempotent; safe before or after the coordinators
# run (they touch material_override and node scale, never mesh identity).
static func apply(upper_body: Node3D, lower_body: Node3D) -> void:
	_swap(upper_body, "UpperBodyMesh", "torso", _build_torso)
	_swap(upper_body, "Helmet", "helmet", _build_helmet)
	_ensure_head(upper_body)
	_swap(upper_body, "ShoulderL", "shoulder", _build_shoulder)
	_swap(upper_body, "ShoulderR", "shoulder", _build_shoulder)
	for side: String in ["L", "R"]:
		_swap(lower_body, "Leg%s/Hip%s" % [side, side], "hip", _build_hip)
		_swap(lower_body, "Leg%s/Thigh%s" % [side, side], "thigh", _build_thigh)
		_swap(lower_body, "Leg%s/Knee%s" % [side, side], "knee", _build_knee)
		_swap(lower_body, "Leg%s/Shin%s/Sock%s" % [side, side, side], "sock", _build_sock)
		_swap(lower_body, "Leg%s/Shin%s/Skate%s" % [side, side, side], "skate", _build_skate)
		_swap(lower_body, "Leg%s/Shin%s/Foot%s" % [side, side, side], "boot", _build_boot)


static func _swap(root: Node3D, path: String, key: String, builder: Callable) -> void:
	_swap_instance(root.get_node_or_null(path) as MeshInstance3D, key, builder)


static func _swap_instance(mi: MeshInstance3D, key: String, builder: Callable) -> void:
	if mi == null:
		return
	var built: ArrayMesh = _shared(key, builder)
	# Carry the scene primitive's material onto the shared build so the part
	# keeps its editor default color until apply_uniform overrides it.
	var prim: PrimitiveMesh = mi.mesh as PrimitiveMesh
	if prim != null and prim.material != null and built.surface_get_material(0) == null:
		built.surface_set_material(0, prim.material)
	mi.mesh = built


static func _shared(key: String, builder: Callable) -> ArrayMesh:
	var built: ArrayMesh = _cache.get(key)
	if built == null:
		built = builder.call()
		_cache[key] = built
	return built


# ── Arm-rig meshes (unit radius — size with node scale, never mesh mutation) ──


# Bone prism for the arm wrappers: unit height (the wrapper's per-frame Z
# scale stretches it to the bone length), unit proximal radius (the visual's
# X/Z scale sets thickness), tapering toward the distal end — look_at points
# both bones' mesh-top at the proximal joint. Side UVs follow the cylinder
# convention because _paint_cylinder_h wraps stripe textures on it.
static func shared_arm_bone() -> ArrayMesh:
	return _shared("arm_bone", func() -> ArrayMesh:
		var profile: Array[Vector2] = [Vector2(0.5, 1.0), Vector2(-0.5, _ARM_TAPER)]
		return _build_lathe(profile, _LEG_SIDES, 1.0, 1.0))


# Elbow/hand ball, unit radius.
static func shared_joint_ball() -> ArrayMesh:
	return _shared("joint_ball", func() -> ArrayMesh:
		return _build_ball(1.0, 8, 4, 1.0))


# Glove cuff ring: unit radius, CUFF_HEIGHT_M tall (real height baked — the
# cuff's along-bone placement offsets by it, only the radius scales).
static func shared_cuff() -> ArrayMesh:
	return _shared("cuff", func() -> ArrayMesh:
		var h: float = CUFF_HEIGHT_M * 0.5
		var profile: Array[Vector2] = [Vector2(h, 1.0), Vector2(-h, 1.0)]
		return _build_lathe(profile, _LEG_SIDES, 1.0, 1.0))


# Butt-end knob at its real dimensions (never rescaled).
static func shared_knob() -> ArrayMesh:
	return _shared("knob", func() -> ArrayMesh:
		var h: float = KNOB_HEIGHT_M * 0.5
		var profile: Array[Vector2] = [
			Vector2(h, _KNOB_TOP_RADIUS), Vector2(-h, _KNOB_BOTTOM_RADIUS)]
		return _build_lathe(profile, _LEG_SIDES, 1.0, 1.0))


# ── Part builders ─────────────────────────────────────────────────────────────


static func _build_torso() -> ArrayMesh:
	return _build_lathe(_TORSO_PROFILE, _TORSO_SIDES, _TORSO_X_SCALE, _TORSO_Z_SCALE)


# Helmet shell: lat/long bands whose bottom latitude follows the per-azimuth
# cut (see the constants' doc), closed by a fan from the rim to an interior
# center — those closure faces hide inside the head ball, and closing keeps
# the solid's winding testable. Same ring orientation as _build_ball, so the
# shared quad ordering stays outward.
static func _build_helmet() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)  # flat shading — see class doc block
	var lon: int = 10
	var lat: int = 4
	var rings: Array[PackedVector3Array] = []
	for j in lat + 1:
		var ring := PackedVector3Array()
		ring.resize(lon + 1)
		for k in lon + 1:
			var theta: float = TAU * float(k) / float(lon)
			var cut_v: float = _HELMET_CUT_BASE + _HELMET_CUT_BACK_BIAS * cos(theta)
			var v: float = cut_v * float(j) / float(lat)
			var y: float = _HELMET_RADIUS * cos(PI * v)
			var ring_r: float = _HELMET_RADIUS * sin(PI * v)
			ring[k] = Vector3(sin(theta) * ring_r, y, cos(theta) * ring_r)
		rings.append(ring)
	for j in lat:
		for k in lon:
			_uv_quad(st,
					rings[j][k], Vector2.ZERO,
					rings[j][k + 1], Vector2(0.1, 0.0),
					rings[j + 1][k + 1], Vector2(0.1, 0.1),
					rings[j + 1][k], Vector2(0.0, 0.1))
	var rim: PackedVector3Array = rings[lat]
	var center := Vector3.ZERO
	for k in lon:
		center += rim[k]
	center /= float(lon)
	center.x = 0.0
	center.z = 0.0
	_cap(st, rim, center, Vector2(0.5, 0.9), false, 0.05)
	st.generate_normals()
	return st.commit()


# The pink head ball under the helmet shell. Created (not swapped — no scene
# node exists for it) as a child of the Helmet MeshInstance3D so it rides the
# same appearance-rig scaling and skeleton offsets. SkaterUniformCoordinator
# resolves it by name for ghost fades; the placeholder material lives here
# because no kit color paints skin.
static func _ensure_head(upper_body: Node3D) -> void:
	var helmet: MeshInstance3D = upper_body.get_node_or_null("Helmet") as MeshInstance3D
	if helmet == null or helmet.get_node_or_null("Head") != null:
		return
	var head := MeshInstance3D.new()
	head.name = "Head"
	head.mesh = _shared("head", func() -> ArrayMesh:
		return _build_ball(HEAD_RADIUS, 10, 5, 1.0))
	var mat := StandardMaterial3D.new()
	mat.albedo_color = HEAD_COLOR
	mat.roughness = 0.85
	BodyRim.apply(mat)
	head.material_override = mat
	helmet.add_child(head)


static func _build_shoulder() -> ArrayMesh:
	return _build_ball(_SHOULDER_RADIUS, 10, 5, 1.0, _SHOULDER_Y_SCALE)


static func _build_hip() -> ArrayMesh:
	return _build_ball(_HIP_RADIUS, 8, 4, 1.0)


static func _build_knee() -> ArrayMesh:
	return _build_ball(_KNEE_RADIUS, 8, 4, 1.0)


static func _build_thigh() -> ArrayMesh:
	return _build_lathe(_THIGH_PROFILE, _LEG_SIDES, 1.02, 0.96)


static func _build_sock() -> ArrayMesh:
	return _build_lathe(_SOCK_PROFILE, _LEG_SIDES, 1.0, 1.0)


static func _build_skate() -> ArrayMesh:
	return _build_lathe(_SKATE_PROFILE, _LEG_SIDES, 1.0, 1.0)


# ── Lathe (cylinder-convention) parts ─────────────────────────────────────────


# Faceted solid of revolution over (y, radius) stations, with the cylinder UV
# convention from the class doc block. Both end caps are emitted — the engine
# cylinders had them, and the torso's top cap is where the yoke paints.
static func _build_lathe(profile: Array[Vector2], sides: int,
		x_scale: float, z_scale: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)  # flat shading — see class doc block
	var y_top: float = profile[0].x
	var y_bot: float = profile[profile.size() - 1].x
	var span: float = maxf(y_top - y_bot, 0.001)
	var rings: Array[PackedVector3Array] = []
	var vs := PackedFloat32Array()
	for s: Vector2 in profile:
		rings.append(_ring(s.x, s.y, x_scale, z_scale, sides))
		vs.append(0.5 * (y_top - s.x) / span)
	for i in profile.size() - 1:
		for k in sides:
			var u0: float = float(k) / float(sides)
			var u1: float = float(k + 1) / float(sides)
			_uv_quad(st,
					rings[i][k], Vector2(u0, vs[i]),
					rings[i][k + 1], Vector2(u1, vs[i]),
					rings[i + 1][k + 1], Vector2(u1, vs[i + 1]),
					rings[i + 1][k], Vector2(u0, vs[i + 1]))
	_cap(st, rings[0], Vector3(0.0, y_top, 0.0), Vector2(0.25, 0.75), true)
	_cap(st, rings[rings.size() - 1], Vector3(0.0, y_bot, 0.0), Vector2(0.75, 0.75), false)
	st.generate_normals()
	return st.commit()


# One horizontal ring of sides+1 points (the last duplicates the first so the
# UV seam gets u = 1.0 instead of wrapping back to 0). θ starts at +Z and
# advances toward +X — the engine primitive winding the painters expect.
static func _ring(y: float, radius: float, x_scale: float, z_scale: float,
		sides: int) -> PackedVector3Array:
	var pts := PackedVector3Array()
	pts.resize(sides + 1)
	for k in sides + 1:
		var theta: float = TAU * float(k) / float(sides)
		pts[k] = Vector3(sin(theta) * radius * x_scale, y, cos(theta) * radius * z_scale)
	return pts


# Fan cap over a ring. Cap UVs live on a disk inside the engine cylinder's cap
# quadrant (top cap around (0.25, 0.75), bottom around (0.75, 0.75)) — the
# painters only ever flood-fill these regions, so the disk mapping inside the
# quadrant is free.
static func _cap(st: SurfaceTool, ring: PackedVector3Array, center: Vector3,
		uv_center: Vector2, facing_up: bool, uv_radius: float = 0.24) -> void:
	var sides: int = ring.size() - 1
	for k in sides:
		var uv_k: Vector2 = uv_center + _cap_uv_offset(k, sides) * uv_radius
		var uv_k1: Vector2 = uv_center + _cap_uv_offset(k + 1, sides) * uv_radius
		if facing_up:
			_tri(st, center, uv_center, ring[k + 1], uv_k1, ring[k], uv_k)
		else:
			_tri(st, center, uv_center, ring[k], uv_k, ring[k + 1], uv_k1)


static func _cap_uv_offset(k: int, sides: int) -> Vector2:
	var theta: float = TAU * float(k) / float(sides)
	return Vector2(sin(theta), cos(theta))


# ── Ball (sphere-convention) parts ────────────────────────────────────────────


# Faceted lat/long ball with equirect UVs. v_end < 1 truncates the bottom at
# that latitude fraction and closes it with a flat cap (the helmet's jaw cut);
# v_end == 1 closes at the bottom pole. y_scale stretches along the pole axis
# (a prolate ball — same latitude-scaling SphereMesh's height param does, so
# the equirect painting convention holds). Pole stations collapse their band
# quads to triangles via the degenerate half of _uv_quad — zero-area triangles
# are invisible and flat shading gives every real face its own normal anyway.
static func _build_ball(radius: float, lon: int, lat: int, v_end: float,
		y_scale: float = 1.0) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)  # flat shading — see class doc block
	var rings: Array[PackedVector3Array] = []
	var vs := PackedFloat32Array()
	for j in lat + 1:
		var v: float = v_end * float(j) / float(lat)
		var y: float = radius * cos(PI * v) * y_scale
		var ring_r: float = radius * sin(PI * v)
		rings.append(_ring(y, ring_r, 1.0, 1.0, lon))
		vs.append(v)
	for j in lat:
		for k in lon:
			var u0: float = float(k) / float(lon)
			var u1: float = float(k + 1) / float(lon)
			_uv_quad(st,
					rings[j][k], Vector2(u0, vs[j]),
					rings[j][k + 1], Vector2(u1, vs[j]),
					rings[j + 1][k + 1], Vector2(u1, vs[j + 1]),
					rings[j + 1][k], Vector2(u0, vs[j + 1]))
	if v_end < 1.0:
		var y_cut: float = radius * cos(PI * v_end) * y_scale
		_cap(st, rings[rings.size() - 1], Vector3(0.0, y_cut, 0.0), Vector2(0.5, 0.92), false, 0.07)
	st.generate_normals()
	return st.commit()


# ── Boot ──────────────────────────────────────────────────────────────────────


# Skate boot + blade runner in the Foot node's rotated local frame (see
# _BOOT_STATIONS). The boot is a 6-point chamfered cross-section swept
# heel→toe; the runner is a thin box fin reaching the replaced sphere's ice
# contact depth. Solid-painted part (skate dark), so UVs are nominal.
static func _build_boot() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)  # flat shading — see class doc block
	var n: int = _BOOT_STATIONS.size()
	var loops: Array[PackedVector3Array] = []
	for s: Vector4 in _BOOT_STATIONS:
		loops.append(_boot_loop(s.x, s.y, s.z, s.w))
	_sweep_loops(st, loops)
	var heel := Vector3(0.0, _BOOT_STATIONS[0].x, (loops[0][0].z + loops[0][2].z) * 0.5)
	var toe := Vector3(0.0, _BOOT_STATIONS[n - 1].x,
			(loops[n - 1][0].z + loops[n - 1][2].z) * 0.5)
	_loop_cap(st, loops[0], heel, true)      # heel (+Y)
	_loop_cap(st, loops[n - 1], toe, false)  # toe (−Y)
	_box(st, Vector3(-_BLADE_HALF_W, _BLADE_Y_MIN, _BLADE_Z_TOP),
			Vector3(_BLADE_HALF_W, _BLADE_Y_MAX, _BLADE_Z_BOT))
	st.generate_normals()
	return st.commit()


# Boot cross-section at one station: narrowed top, full-width sidewall, tucked
# sole edge. Wound counter-clockwise as seen from +Y (the heel side) to match
# the lathe rings' winding sense, so the shared band-quad ordering stays
# outward-facing. Local +Z is DOWN in this frame, so top_z < sole_z.
static func _boot_loop(y: float, half_w: float, top_z: float, sole_z: float) -> PackedVector3Array:
	var mid_z: float = lerpf(top_z, sole_z, 0.55)
	var pts := PackedVector3Array()
	pts.resize(6)
	pts[0] = Vector3(-half_w * 0.62, y, top_z)
	pts[1] = Vector3(-half_w, y, mid_z)
	pts[2] = Vector3(-half_w * 0.72, y, sole_z)
	pts[3] = Vector3(half_w * 0.72, y, sole_z)
	pts[4] = Vector3(half_w, y, mid_z)
	pts[5] = Vector3(half_w * 0.62, y, top_z)
	return pts


# Band quads between consecutive CLOSED loops (equal point counts, no
# duplicated seam point — unlike _ring). Contract: loops are wound counter-
# clockwise as seen from the sweep's START side (the side loops[0] faces) and
# advance away from it, matching _ring/_boot_loop — the shared quad ordering
# then keeps every face outward. UVs are nominal; sweep parts paint solid.
# A closed sweep (torus) just appends its first loop again as the last.
static func _sweep_loops(st: SurfaceTool, loops: Array[PackedVector3Array]) -> void:
	var points: int = loops[0].size()
	for i in loops.size() - 1:
		for k in points:
			var k1: int = (k + 1) % points
			_uv_quad(st,
					loops[i][k], Vector2.ZERO,
					loops[i][k1], Vector2(0.1, 0.0),
					loops[i + 1][k1], Vector2(0.1, 0.1),
					loops[i + 1][k], Vector2(0.0, 0.1))


# Fan cap over a closed loop. facing_start caps the sweep's start side
# (facing against the advance direction), the winding mirror of the end cap.
static func _loop_cap(st: SurfaceTool, loop: PackedVector3Array, center: Vector3,
		facing_start: bool) -> void:
	for k in loop.size():
		var k1: int = (k + 1) % loop.size()
		if facing_start:
			_tri(st, center, Vector2.ZERO, loop[k1], Vector2.ZERO, loop[k], Vector2.ZERO)
		else:
			_tri(st, center, Vector2.ZERO, loop[k], Vector2.ZERO, loop[k1], Vector2.ZERO)


# Axis-aligned box between two corners, wound clockwise-from-outside per face.
static func _box(st: SurfaceTool, lo: Vector3, hi: Vector3) -> void:
	var z0 := Vector2.ZERO
	_uv_quad(st,  # +Z
			Vector3(lo.x, hi.y, hi.z), z0, Vector3(hi.x, hi.y, hi.z), z0,
			Vector3(hi.x, lo.y, hi.z), z0, Vector3(lo.x, lo.y, hi.z), z0)
	_uv_quad(st,  # −Z
			Vector3(hi.x, hi.y, lo.z), z0, Vector3(lo.x, hi.y, lo.z), z0,
			Vector3(lo.x, lo.y, lo.z), z0, Vector3(hi.x, lo.y, lo.z), z0)
	_uv_quad(st,  # +X
			Vector3(hi.x, hi.y, hi.z), z0, Vector3(hi.x, hi.y, lo.z), z0,
			Vector3(hi.x, lo.y, lo.z), z0, Vector3(hi.x, lo.y, hi.z), z0)
	_uv_quad(st,  # −X
			Vector3(lo.x, hi.y, lo.z), z0, Vector3(lo.x, hi.y, hi.z), z0,
			Vector3(lo.x, lo.y, hi.z), z0, Vector3(lo.x, lo.y, lo.z), z0)
	_uv_quad(st,  # +Y
			Vector3(lo.x, hi.y, lo.z), z0, Vector3(hi.x, hi.y, lo.z), z0,
			Vector3(hi.x, hi.y, hi.z), z0, Vector3(lo.x, hi.y, hi.z), z0)
	_uv_quad(st,  # −Y
			Vector3(lo.x, lo.y, hi.z), z0, Vector3(hi.x, lo.y, hi.z), z0,
			Vector3(hi.x, lo.y, lo.z), z0, Vector3(lo.x, lo.y, lo.z), z0)


# ── Emission primitives ───────────────────────────────────────────────────────


# One quad as two triangles, corners listed CLOCKWISE as seen from outside the
# mesh (Godot's front-face winding, same convention as StickBladeMeshBuilder)
# so generate_normals() yields outward normals.
static func _uv_quad(st: SurfaceTool,
		a: Vector3, uva: Vector2, b: Vector3, uvb: Vector2,
		c: Vector3, uvc: Vector2, d: Vector3, uvd: Vector2) -> void:
	_tri(st, a, uva, b, uvb, c, uvc)
	_tri(st, a, uva, c, uvc, d, uvd)


static func _tri(st: SurfaceTool,
		a: Vector3, uva: Vector2, b: Vector3, uvb: Vector2,
		c: Vector3, uvc: Vector2) -> void:
	st.set_uv(uva)
	st.add_vertex(a)
	st.set_uv(uvb)
	st.add_vertex(b)
	st.set_uv(uvc)
	st.add_vertex(c)
