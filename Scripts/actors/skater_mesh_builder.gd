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
# Rear (+Z is the back) shift per _TORSO_PROFILE ring — the hockey-butt sway:
# the seat builds through the lower back and peaks at the hem that drapes
# over it, while the chest rings stay centered so the belly keeps its line.
const _TORSO_REAR_SWAY: Array[float] = [0.0, 0.0, 0.0, 0.006, 0.018, 0.028, 0.032]
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
# The collar ENDS just below its node origin: the scene seats that origin at
# the boot's heel-top line, so the cuff perches ON the boot with ~1 cm of
# overlap seal instead of dropping past the heel as a column (the old -0.100
# bottom reached blade-holder depth and swallowed the boot's silhouette).
const _SKATE_PROFILE: Array[Vector2] = [
	Vector2(0.100, 0.090),   # boot collar
	Vector2(0.020, 0.082),
	Vector2(-0.010, 0.078),
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
# shell's lower edge varies with azimuth — flat at brow height around the
# face and temples, dropping to the nape over the back arc — see the rim
# profile constants below (latitudes are equirect fractions; θ = 0 is +Z,
# the back).
const _HELMET_RADIUS: float = 0.155
# Rim profile, anchored to head anatomy (head r 0.135, eye line ≈ the
# equator): the rim holds FLAT at the brow latitude (y ≈ +0.048, above the
# eye line) from the face around the temples, then smoothsteps down over the
# back arc to the nape — the hockey-helmet shape, rather than a cosine that
# starts sinking immediately off the brow. The drop engages where cos(θ)
# (−1 at the face, +1 at the back) crosses _HELMET_DROP_START_C — about 70°
# either side of dead back.
const _HELMET_FRONT_CUT: float = 0.40
const _HELMET_BACK_CUT: float = 0.76
const _HELMET_DROP_START_C: float = 0.34
# Ear loops: a localized rim dip centered on each side (|sin θ| = 1),
# narrowed by the exponent so it reads as an ear cover, not a lower brim.
# At the nearest sampled azimuths the dip reaches ear-top depth (y ≈ −0.03);
# it fades to nothing at the face and inside the nape drop.
const _HELMET_EAR_DIP: float = 0.22
const _HELMET_EAR_DIP_POWER: float = 6.0
# The shell closes with a fan to an apex HIGH inside the dome (this fraction
# of the radius up), not a floor at rim height — a low floor reads as a
# helmet-colored lid across the face opening from the top-down camera,
# hiding the head entirely. High, the closure is an interior liner you only
# glimpse near the rim.
const _HELMET_LINER_APEX_FRAC: float = 0.5
const HEAD_RADIUS: float = 0.135
# The head sits this far forward of the helmet center (real faces do) so the
# face shows near-flush in the brow opening instead of recessed 2 cm behind
# the rim. Capped by clearance: forward offset + HEAD_RADIUS must stay under
# _HELMET_RADIUS or the face pokes through the shell at the front equator.
const _HEAD_FORWARD_M: float = 0.015

# Shoulder cap: an asymmetric deltoid pad. The +Y end — which
# Skater._orient_shoulder_cap points INTO the trap/chest (away from the arm)
# — is a blunt, flat-capped base, so the cap merges into the torso
# silhouette instead of pinching to a pole right where it meets the chest;
# the −Y end keeps the prolate taper that runs down the arm. Stations are
# (y, radius, equirect v): the v column preserves the sphere-convention
# mapping the shoulder-number decal is painted against, with the number band
# on the full-width equator.
const _SHOULDER_PROFILE: Array[Vector3] = [
	Vector3(0.075, 0.068, 0.12),   # blunt torso-side base (flat-capped)
	Vector3(0.045, 0.096, 0.30),
	Vector3(0.000, 0.105, 0.50),   # equator — the number band
	Vector3(-0.055, 0.096, 0.68),
	Vector3(-0.105, 0.070, 0.85),
	Vector3(-0.137, 0.030, 1.0),   # arm-side taper
]

# Hips fill the seat under the torso's rear sway: a touch bigger than the
# 0.13 they shipped at, with the rearward seat bias carried by the HipL/R
# nodes' scene position (z 0.035).
const _HIP_RADIUS: float = 0.138
const _KNEE_RADIUS: float = 0.095

# Gloved fist: a beveled cube, slightly wider than deep and chamfered all
# around, swept along local Y — Skater._update_hand_glove aligns that axis
# with the forearm so the block's faces track the arm instead of sitting
# world-aligned. UNIT-scale like the other arm-rig meshes: node scale =
# hand_sphere_radius sizes it (stations are y, half_w, half_d multiples).
const _GLOVE_FIST_STATIONS: Array[Vector3] = [
	Vector3(0.95, 0.80, 0.74),    # wrist-side bevel (tucks under the cuff)
	Vector3(0.55, 1.05, 0.95),
	Vector3(-0.55, 1.05, 0.95),
	Vector3(-0.95, 0.80, 0.74),   # finger-side bevel
]

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
	# Heel top rises toward the collar like a real boot's quarter (was -0.040,
	# which left the cuff floating over a low heel), meeting the collar's
	# bottom so ankle and boot read as one piece from the side. The rearmost
	# station runs the quarter back UNDER the collar's footprint (the cuff
	# seats 0.10 heel-ward of this frame's origin, so its underside otherwise
	# hangs bare behind the heel) — sole tucked well up so the stride's
	# heel-kick arc can't drag it through the ice.
	Vector4(0.155, 0.042, -0.062, 0.030),   # heel counter, under the cuff
	Vector4(0.115, 0.052, -0.070, 0.045),   # heel
	Vector4(0.045, 0.060, -0.072, 0.046),   # instep rise
	Vector4(-0.045, 0.058, -0.048, 0.046),  # forefoot
	Vector4(-0.115, 0.040, -0.012, 0.040),  # toe
]
# Skate blade — its own steel-colored child mesh under each Foot node (the
# boot paints dark, so a fused same-color fin never read as a blade). Same
# rotated frame as _BOOT_STATIONS: toe −Y, +Z down. Two holder posts drop
# from the sole with daylight between them at the arch; the thin runner
# spans the length and bottoms out at the replaced sphere's ice-contact
# depth (z = 0.080).
const _BLADE_STEEL_COLOR := Color(0.82, 0.85, 0.88)
# On-skates stance lift: the scene's part layout is tuned as STANDING height,
# so the skate stack raises both body roots (applied in Skater._ready before
# the default-height captures — the same root-raise mechanism the height
# attribute uses) and the blade assembly reaches this much deeper than the
# old foot-sphere ice contact (z 0.080), keeping the steel on y = 0. The
# height attribute's root scaling still uses FACEOFF_SPAWN_HEIGHT as its ice
# height, so the lift's unscaled share leaves <3 mm of contact error at the
# extreme builds — visually nil.
const SKATE_LIFT_M: float = 0.04
const _BLADE_ICE_Z: float = 0.080 + SKATE_LIFT_M
# Skate accent stripe (see shared_skate_stripe): band height, its center on
# the collar's local Y, and a radius just proud of the collar's sidewall at
# that height (~0.085) so the band never z-fights the lathe under it.
const SKATE_STRIPE_HEIGHT_M: float = 0.04
const _SKATE_STRIPE_Y: float = 0.045
const _SKATE_STRIPE_RADIUS: float = 0.092
# Skate laces, drawn-on as geometry: thin rungs laid across the instep, each
# (y, z) pair the rung's center on the boot's top line — z interpolated from
# the _BOOT_STATIONS top_z at that y, so every rung seats on the surface it
# crosses (ankle → forefoot). _LACE_COLOR is only the pre-uniform placeholder;
# the gear style's lace pick repaints them (SkaterUniformCoordinator).
const _LACE_RUNGS: Array[Vector2] = [
	Vector2(0.070, -0.0711),
	Vector2(0.035, -0.0693),
	Vector2(0.000, -0.0600),
	Vector2(-0.035, -0.0507),
]
const _LACE_HALF_W: float = 0.030
const _LACE_HALF_T: float = 0.006   # rung thickness along the instep (local Y)
# Rung depth is biased PROUD of the surface rather than centered on it: the
# top line slopes ~0.46 across the heel→instep segment, so a surface-centered
# box left barely 2 mm showing there — fine at rink distance, visible
# clipping at the workbench close-up. Sink keeps the underside buried so no
# gap opens as the slope crosses the rung.
const _LACE_PROUD: float = 0.008    # rise above the top surface
const _LACE_SINK: float = 0.003     # burial below it
const _LACE_COLOR := Color(0.88, 0.88, 0.86)

# Neck: skin tube from chin to collar, a child of the Helmet node like the
# head so it rides the same head-bulk scaling and skeleton offsets. Stations
# are helmet-local (helmet origin y 0.65, torso top 0.47): the top hides
# inside the head ball, the bottom flares into the traps where it sinks
# into the torso.
const _NECK_PROFILE: Array[Vector2] = [
	Vector2(-0.095, 0.064),
	Vector2(-0.155, 0.070),
	Vector2(-0.190, 0.092),  # trapezius flare into the collar
]

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
		# Boot, steel and laces are ONE mesh with three surfaces (see
		# shared_boot_assembly) — the steel and laces used to be child nodes.
		_swap(lower_body, "Leg%s/Shin%s/Foot%s" % [side, side, side],
				"boot_assembly", _build_boot_assembly)
		_ensure_skate_stripe(lower_body, "Leg%s/Shin%s/Skate%s" % [side, side, side])


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


# The same prism with the wrapper's old 90°-about-X baked into the vertices, so
# its long axis is local Z — the axis _update_bone_mesh's looking_at basis aims.
#
# This is what lets an arm bone be ONE node instead of two. The rig used to be a
# Node3D wrapper carrying (1, 1, length) around a MeshInstance3D child carrying
# (radius, 1, radius) and a 90° rotation, purely because the mesh's long axis
# disagreed with the aiming axis. With the rotation baked, a single instance
# carries (radius, radius, length) and the wrapper disappears: four fewer nodes
# per skater, and — since these are written every frame by the IK — one less
# level of transform propagation on each write.
# ── Merged assemblies ────────────────────────────────────────────────────────
# Parts that never move relative to their parent do not need to be nodes. Each
# one used to be a MeshInstance3D child purely because it needed its OWN
# material — the steel is bright, the laces take a gear colour — and a child was
# the only place to hang one. A multi-surface mesh with per-surface overrides
# gives the same result with one node instead of three.
#
# The cost of a node here is not the draw call: these are children of a foot the
# gait moves every frame, so each one is a transform to propagate and a global
# to recompute, per skater, per frame.
#
# NON-NEGOTIABLE for any merged mesh: nothing may set material_override on it.
# That property overrides EVERY surface at once, so it would erase the steel and
# the laces the moment the boot was painted. The parent's own colour lives on
# surface 0 like everything else — see SkaterUniformCoordinator's BOOT_* slots.
const BOOT_SURF_SHELL: int = 0
const BOOT_SURF_BLADE: int = 1
const BOOT_SURF_LACES: int = 2


static func shared_boot_assembly() -> ArrayMesh:
	return _shared("boot_assembly", _build_boot_assembly)


static func _build_boot_assembly() -> ArrayMesh:
	var m := ArrayMesh.new()
	_append_surface(m, _shared("boot", _build_boot))
	_append_surface(m, _shared("skate_blade", _build_skate_blade))
	_append_surface(m, shared_laces())
	# Defaults for the two merged surfaces, standing in for the material_override
	# their child nodes used to carry — so an unpainted rig (workbench preview,
	# a spawn before the uniform pass) still shows steel and white laces rather
	# than untextured white. Surface 0 is left null on purpose: _swap_instance
	# carries the scene primitive's material onto it, exactly as before.
	var steel := StandardMaterial3D.new()
	steel.albedo_color = _BLADE_STEEL_COLOR
	steel.roughness = 0.25
	BodyRim.apply(steel)
	m.surface_set_material(BOOT_SURF_BLADE, steel)
	var lace := StandardMaterial3D.new()
	lace.albedo_color = _LACE_COLOR
	lace.roughness = 0.9
	BodyRim.apply(lace)
	m.surface_set_material(BOOT_SURF_LACES, lace)
	return m


# Appends `src`'s surface 0 to `target` as a new surface. The children this
# replaces all sat at identity relative to their parent, so no transform is
# baked — which is also why the merge cannot change the rendered geometry.
static func _append_surface(target: ArrayMesh, src: ArrayMesh) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.append_from(src, 0, Transform3D.IDENTITY)
	st.commit(target)


static func shared_arm_bone_z() -> ArrayMesh:
	return _shared("arm_bone_z", func() -> ArrayMesh:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.append_from(shared_arm_bone(), 0,
				Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3.ZERO))
		return st.commit())


# Elbow ball, unit radius.
static func shared_joint_ball() -> ArrayMesh:
	return _shared("joint_ball", func() -> ArrayMesh:
		return _build_ball(1.0, 8, 4, 1.0))


# Gloved fist (see _GLOVE_FIST_STATIONS).
static func shared_glove_fist() -> ArrayMesh:
	return _shared("glove_fist", func() -> ArrayMesh:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.set_smooth_group(-1)  # flat shading — see class doc block
		var loops: Array[PackedVector3Array] = []
		for s: Vector3 in _GLOVE_FIST_STATIONS:
			loops.append(_octagon_loop(s.x, s.y, s.z, 0.6, 0.55))
		_sweep_loops(st, loops)
		_loop_cap(st, loops[0],
				Vector3(0.0, _GLOVE_FIST_STATIONS[0].x, 0.0), true)
		_loop_cap(st, loops[loops.size() - 1],
				Vector3(0.0, _GLOVE_FIST_STATIONS[_GLOVE_FIST_STATIONS.size() - 1].x, 0.0),
				false)
		st.generate_normals()
		return st.commit())


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
	return _build_lathe(_TORSO_PROFILE, _TORSO_SIDES, _TORSO_X_SCALE, _TORSO_Z_SCALE,
			_TORSO_REAR_SWAY)


# Helmet shell: lat/long bands whose bottom latitude follows the per-azimuth
# cut (see the constants' doc), closed by a fan from the rim to an interior
# center — those closure faces hide inside the head ball, and closing keeps
# the solid's winding testable. Same ring orientation as _build_ball, so the
# shared quad ordering stays outward.
static func _build_head() -> ArrayMesh:
	return _build_ball(HEAD_RADIUS, 10, 5, 1.0)


# Shared part accessors for out-of-game figures (the lobby's bench dummies)
# so every rendered player body — live or furniture — wears the same faceted
# set from the same cache.
static func shared_torso() -> ArrayMesh:
	return _shared("torso", _build_torso)


static func shared_helmet_shell() -> ArrayMesh:
	return _shared("helmet", _build_helmet)


static func shared_head_ball() -> ArrayMesh:
	return _shared("head", _build_head)


static func shared_shoulder_cap() -> ArrayMesh:
	return _shared("shoulder", _build_shoulder)


static func shared_thigh() -> ArrayMesh:
	return _shared("thigh", _build_thigh)


static func shared_sock() -> ArrayMesh:
	return _shared("sock", _build_sock)


static func shared_boot() -> ArrayMesh:
	return _shared("boot", _build_boot)


static func shared_skate_collar() -> ArrayMesh:
	return _shared("skate", _build_skate)


# Skate accent stripe: a thin unit-radius band that rings the collar proud of
# its sidewall — the one piece the skate-color cosmetic paints (the boot and
# collar themselves stay dark). Unit radius like the glove cuff; the creation
# site scales it to sit just off the collar.
static func shared_skate_stripe() -> ArrayMesh:
	return _shared("skate_stripe", func() -> ArrayMesh:
		var h: float = SKATE_STRIPE_HEIGHT_M * 0.5
		var profile: Array[Vector2] = [Vector2(h, 1.0), Vector2(-h, 1.0)]
		return _build_lathe(profile, _LEG_SIDES, 1.0, 1.0))


# Drawn-on skate laces (see _LACE_RUNGS): one mesh of instep rungs in the
# boot's rotated frame, shared like every other part.
static func shared_laces() -> ArrayMesh:
	return _shared("laces", func() -> ArrayMesh:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.set_smooth_group(-1)  # flat shading — see class doc block
		for rung: Vector2 in _LACE_RUNGS:
			_box(st,
					Vector3(-_LACE_HALF_W, rung.x - _LACE_HALF_T, rung.y - _LACE_PROUD),
					Vector3(_LACE_HALF_W, rung.x + _LACE_HALF_T, rung.y + _LACE_SINK))
		st.generate_normals()
		return st.commit())


static func shared_skate_blade() -> ArrayMesh:
	return _shared("skate_blade", _build_skate_blade)


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
			var t: float = clampf((cos(theta) - _HELMET_DROP_START_C)
					/ (1.0 - _HELMET_DROP_START_C), 0.0, 1.0)
			var cut_v: float = lerpf(_HELMET_FRONT_CUT, _HELMET_BACK_CUT,
					t * t * (3.0 - 2.0 * t)) \
					+ _HELMET_EAR_DIP * pow(absf(sin(theta)), _HELMET_EAR_DIP_POWER)
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
	var apex := Vector3(0.0, _HELMET_RADIUS * _HELMET_LINER_APEX_FRAC, 0.0)
	_cap(st, rings[lat], apex, Vector2(0.5, 0.9), false, 0.05)
	st.generate_normals()
	return st.commit()


# The head ball and neck under the helmet shell. Created (not swapped — no
# scene nodes exist for them) as children of the Helmet MeshInstance3D so
# they ride the same appearance-rig scaling and skeleton offsets.
# SkaterUniformCoordinator resolves both by name for ghost fades; the skin
# material lives here because no kit color paints skin — the player's
# identity tone does (Skater.set_skin_tone).
static func _ensure_head(upper_body: Node3D) -> void:
	var helmet: MeshInstance3D = upper_body.get_node_or_null("Helmet") as MeshInstance3D
	if helmet == null or helmet.get_node_or_null("Head") != null:
		return
	var head := MeshInstance3D.new()
	head.name = "Head"
	head.position = Vector3(0.0, 0.0, -_HEAD_FORWARD_M)
	head.mesh = _shared("head", _build_head)
	head.material_override = _make_skin_mat()
	helmet.add_child(head)
	var neck := MeshInstance3D.new()
	neck.name = "Neck"
	neck.mesh = _shared("neck", _build_neck)
	neck.material_override = _make_skin_mat()
	helmet.add_child(neck)


static func _build_neck() -> ArrayMesh:
	return _build_lathe(_NECK_PROFILE, 8, 1.0, 1.0)


# Default-tone skin material — Skater.set_skin_tone repaints the albedo to
# the player's identity pick at spawn (and live from the edit-player popup).
static func _make_skin_mat() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = SkinToneRegistry.color_for(SkinToneRegistry.DEFAULT_INDEX)
	mat.roughness = 0.85
	BodyRim.apply(mat)
	return mat


static func _build_shoulder() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)  # flat shading — see class doc block
	var lon: int = 10
	var n: int = _SHOULDER_PROFILE.size()
	var rings: Array[PackedVector3Array] = []
	for s: Vector3 in _SHOULDER_PROFILE:
		rings.append(_ring(s.x, s.y, 1.0, 1.0, lon))
	for i in n - 1:
		for k in lon:
			var u0: float = float(k) / float(lon)
			var u1: float = float(k + 1) / float(lon)
			_uv_quad(st,
					rings[i][k], Vector2(u0, _SHOULDER_PROFILE[i].z),
					rings[i][k + 1], Vector2(u1, _SHOULDER_PROFILE[i].z),
					rings[i + 1][k + 1], Vector2(u1, _SHOULDER_PROFILE[i + 1].z),
					rings[i + 1][k], Vector2(u0, _SHOULDER_PROFILE[i + 1].z))
	# Caps sample the decal's pole regions (plain shoulder color).
	_cap(st, rings[0], Vector3(0.0, _SHOULDER_PROFILE[0].x, 0.0),
			Vector2(0.5, 0.06), true, 0.05)
	_cap(st, rings[n - 1], Vector3(0.0, _SHOULDER_PROFILE[n - 1].x, 0.0),
			Vector2(0.5, 0.97), false, 0.02)
	st.generate_normals()
	return st.commit()


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
		x_scale: float, z_scale: float,
		z_offsets: Array[float] = []) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)  # flat shading — see class doc block
	var y_top: float = profile[0].x
	var y_bot: float = profile[profile.size() - 1].x
	var span: float = maxf(y_top - y_bot, 0.001)
	var rings: Array[PackedVector3Array] = []
	var vs := PackedFloat32Array()
	for i in profile.size():
		var s: Vector2 = profile[i]
		var ring: PackedVector3Array = _ring(s.x, s.y, x_scale, z_scale, sides)
		# Optional per-ring Z shift (index-aligned with the profile; short or
		# empty array = centered). Rings stay circular — the shift moves the
		# whole ring, giving the lathe an asymmetric sway (the torso's seat)
		# while the angular UV convention is untouched.
		var z_off: float = z_offsets[i] if i < z_offsets.size() else 0.0
		if z_off != 0.0:
			for k in ring.size():
				ring[k].z += z_off
		rings.append(ring)
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
	var top_off: float = z_offsets[0] if z_offsets.size() > 0 else 0.0
	var bot_off: float = z_offsets[profile.size() - 1] \
			if z_offsets.size() >= profile.size() else 0.0
	_cap(st, rings[0], Vector3(0.0, y_top, top_off), Vector2(0.25, 0.75), true)
	_cap(st, rings[rings.size() - 1], Vector3(0.0, y_bot, bot_off), Vector2(0.75, 0.75), false)
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
	st.generate_normals()
	return st.commit()


# Holder posts + steel runner (see the _BLADE_* constants' doc). The posts
# tuck up into the sole (z 0.042 < the boot's 0.045 sole line).
static func _build_skate_blade() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)  # flat shading — see class doc block
	_box(st, Vector3(-0.008, 0.036, 0.042), Vector3(0.008, 0.094, 0.098))    # heel post
	_box(st, Vector3(-0.008, -0.080, 0.042), Vector3(0.008, -0.026, 0.098))  # toe post
	_box(st, Vector3(-0.0035, -0.088, 0.090),
			Vector3(0.0035, 0.098, _BLADE_ICE_Z))                            # steel runner
	st.generate_normals()
	return st.commit()


# The accent stripe is a CHILD of the collar mesh so it rides the same node
# scaling and stride animation. Default-painted boot-dark (the classic look);
# SkaterUniformCoordinator repaints it with the player's skate-color pick.
static func _ensure_skate_stripe(lower_body: Node3D, skate_path: String) -> void:
	var collar: MeshInstance3D = lower_body.get_node_or_null(skate_path) as MeshInstance3D
	if collar == null or collar.get_node_or_null("Stripe") != null:
		return
	var stripe := MeshInstance3D.new()
	stripe.name = "Stripe"
	stripe.mesh = shared_skate_stripe()
	stripe.position = Vector3(0.0, _SKATE_STRIPE_Y, 0.0)
	stripe.scale = Vector3(_SKATE_STRIPE_RADIUS, 1.0, _SKATE_STRIPE_RADIUS)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.08, 0.08, 0.08)
	mat.roughness = 0.42
	BodyRim.apply(mat)
	stripe.material_override = mat
	collar.add_child(stripe)


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


# Chamfered-rectangle cross-section, CCW seen from +Y (the sweep-loop
# contract). face_frac is the flat front/back segment's half-width as a
# fraction of hw; side_frac the flat side segment's half-depth as a fraction
# of hd.
static func _octagon_loop(y: float, hw: float, hd: float,
		face_frac: float, side_frac: float) -> PackedVector3Array:
	var fx: float = hw * face_frac
	var sz: float = hd * side_frac
	var pts := PackedVector3Array()
	pts.resize(8)
	pts[0] = Vector3(-fx, y, -hd)
	pts[1] = Vector3(-hw, y, -sz)
	pts[2] = Vector3(-hw, y, sz)
	pts[3] = Vector3(-fx, y, hd)
	pts[4] = Vector3(fx, y, hd)
	pts[5] = Vector3(hw, y, sz)
	pts[6] = Vector3(hw, y, -sz)
	pts[7] = Vector3(fx, y, -hd)
	return pts


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
