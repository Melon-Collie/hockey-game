class_name SkaterMeshBuilder
extends RefCounted

# Low-poly faceted geometry for the skater: shaped torso, helmeted head, deltoid
# shoulder caps, arm bone prisms, joint balls, glove fists and cuffs, hip/knee
# balls, thighs, socks, skate collars, boots with a blade runner, and the stick
# knob. Cosmetic only — gameplay reads the Marker3D anchors and collision
# shapes, never these meshes.
#
# The skater renders as TWO skinned meshes, not as a tree of MeshInstance3Ds:
# shared_upper_skin_mesh (UpperBone / UpperSurface) and shared_leg_skin_mesh
# (LegBone / LegSurface). Both are cached and shared by every skater on the ice —
# per-skater colour is a surface override and per-build sizing rides the scale in
# each bone's pose, so nothing here is ever mutated per instance. The goalie and
# the puck still hang meshes on nodes and subclass this builder for the geometry
# helpers (see _swap_instance).
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
# style; per-face normals are what make the shaped silhouettes read.
#
# NORMALS UNDER SKINNING: Godot transforms a skinned normal by the bone matrix
# itself, not by its inverse transpose, so a bone whose pose carries non-uniform
# scale renders with skewed normals. _radial_side_normals fixes that where the
# anisotropy is extreme (the arm bones, ~4:1). Do not reach for it elsewhere —
# on a part scaled near 1:1 it costs more than it buys (see the note there).
#
# Some parts contribute SEVERAL surfaces to one bone — the boot carries its blade
# steel and laces, the skate collar its accent stripe, the helmet the head/neck
# skin — because a part that never moves relative to another does not need its
# own bone, only its own material. Nothing may ever set material_override on
# either skinned mesh: it overrides every surface at once. Paint through
# surface_override() / the Skater seams instead.

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

# Head + helmet. The scene's Helmet node carries the helmet SHELL on surface 0
# (painted the kit's helmet color, scaled by the appearance rig) and the
# head/neck skin on surface 1 — one mesh, so both share its transform. The
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
# The mid station adds no shape — it sits on the straight run between two
# identical loops — but it is where the sweep splits into the BACK of the hand
# and the FINGERS, the two pieces a glove design paints apart.
const _GLOVE_FINGER_STATION: int = 2
const _GLOVE_FIST_STATIONS: Array[Vector3] = [
	Vector3(0.95, 0.80, 0.74),    # wrist-side bevel (tucks under the cuff)
	Vector3(0.55, 1.05, 0.95),
	Vector3(0.0, 1.05, 0.95),     # knuckle line — the back / fingers split
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
# Station the toe cap starts at — the boot sweep commits stations 0..N as the
# quarter and N..last as the cap, so the two pieces share this ring and meet
# with no gap. The front band is the whole cap, which is the proportion a real
# toe cap covers.
const _BOOT_TOE_STATION: int = 3
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
# rotated frame as _BOOT_STATIONS: toe −Y, +Z down. The holder's two towers
# drop from the sole and are bridged by a bottom rail, leaving the arch open
# between them; the thin runner spans the length and bottoms out at the
# replaced sphere's ice-contact depth (z = 0.080).
#
# Steel is a MID gray, not the near-white it was: the holder is a paintable
# zone now, and a white holder sitting on a near-white runner loses the
# skate's bottom edge entirely. Dark enough to separate from GearModelRegistry
# .WHITE, bright enough to still read against a black boot. Public because the
# workbench preview and the capture tool dress their own runners with it —
# three copies of this color is how it went stale in the first place.
const BLADE_STEEL_COLOR := Color(0.62, 0.66, 0.70)
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
# Swaps a scene primitive for a generated build, in place. The skater no longer
# uses this — every one of its parts is a surface of a skinned rig — but the
# goalie and the puck still hang their meshes on nodes, and they subclass this
# builder for the geometry helpers.
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
		return _radial_side_normals(_build_lathe(profile, _LEG_SIDES, 1.0, 1.0)))


# Rewrites a lathe's SIDE normals to be purely radial — no component along the
# lathe axis — leaving the caps alone. Only the arm bones need this, and they
# need it because they are the one part whose scale is strongly non-uniform.
#
# Godot's skinning transforms a normal by the bone matrix itself, not by its
# inverse transpose (an ordinary MeshInstance3D gets the proper normal matrix).
# Under a bone scale of (r, r, length) that skews any normal with an axial
# component the WRONG way and by the ratio length/r — about 4:1 on an arm — so
# the 6.8° taper cone shaded as a 27° one, and worse, the shading then changed
# with the bone's length as the arm stretched on an over-reach.
#
# A normal with no axial component is immune: scaling it by (r, r, length)
# multiplies it by r and normalizes back to itself.
#
# Baking the sides radial is not the art compromise it looks like. The proper
# normal matrix divides the axial component by length while dividing the radial
# one by r, so at an arm's r/length (~0.23) it was ALREADY flattening the 6.8°
# taper to 1.6° off radial before this change — the node rig rendered these as
# near-cylinders too. What baking it buys is that the shading no longer depends
# on r/length at all, so an over-reach that stretches the forearm can no longer
# change how it is lit. The pose diff holds this to the letter: every pose is
# byte-identical to the node rig apart from one edge pixel.
static func _radial_side_normals(src: ArrayMesh) -> ArrayMesh:
	var arrays: Array = src.surface_get_arrays(0)
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	for i: int in normals.size():
		var n: Vector3 = normals[i]
		# Caps point straight up the axis; flattening them would zero them.
		if absf(n.y) > 0.99:
			continue
		n.y = 0.0
		normals[i] = n.normalized()
	arrays[Mesh.ARRAY_NORMAL] = normals
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return out


# ── The leg rig: one skinned mesh, sixteen bones ─────────────────────────────
# Same conversion as the arms (see the ArmPart block), with one structural
# difference: the legs are a CHAIN, not siblings. LegL/R carry hip pitch and
# roll, ShinL/R hang off them and carry the knee, and the six meshes per leg ride
# whichever of the two they belonged to. The bone parents below mirror that
# exactly, so a pose write composes down the chain the way the node transforms
# did — flattening it would mean re-deriving the shin's world frame by hand on
# every gait tick.
#
# Bone order is L then R, pivot first. LEG_* and SHIN_* carry no vertices; they
# exist to be rotated, which is what a bone is for.
enum LegBone {
	LEG_L, HIP_L, THIGH_L, KNEE_L, SHIN_L, SOCK_L, SKATE_L, FOOT_L,
	LEG_R, HIP_R, THIGH_R, KNEE_R, SHIN_R, SOCK_R, SKATE_R, FOOT_R,
}
const LEG_BONE_COUNT: int = 16
# Parent per bone, index-aligned with LegBone. -1 = attached to the skeleton
# root (LowerBody's frame).
const LEG_BONE_PARENT: Array[int] = [
	-1, LegBone.LEG_L, LegBone.LEG_L, LegBone.LEG_L,
	LegBone.LEG_L, LegBone.SHIN_L, LegBone.SHIN_L, LegBone.SHIN_L,
	-1, LegBone.LEG_R, LegBone.LEG_R, LegBone.LEG_R,
	LegBone.LEG_R, LegBone.SHIN_R, LegBone.SHIN_R, LegBone.SHIN_R,
]
# Scene node name per bone, index-aligned with LegBone. Skater._build_leg_rig
# reads each one's local transform before freeing the subtree, so the .tscn stays
# the place leg proportions are authored.
const LEG_BONE_NODE: Array[String] = [
	"LegL", "LegL/HipL", "LegL/ThighL", "LegL/KneeL",
	"LegL/ShinL", "LegL/ShinL/SockL", "LegL/ShinL/SkateL", "LegL/ShinL/FootL",
	"LegR", "LegR/HipR", "LegR/ThighR", "LegR/KneeR",
	"LegR/ShinR", "LegR/ShinR/SockR", "LegR/ShinR/SkateR", "LegR/ShinR/FootR",
]

# Surfaces of the leg mesh. Not one per bone: the skate collar carries its accent
# stripe, and the boot carries its toe cap, its blade holder, its steel runner
# and its laces — so those parts contribute several surfaces to one bone. Each
# extra surface is a piece a gear MODEL paints on its own (GearModelRegistry);
# the runner is the exception that stays steel by construction.
enum LegSurface {
	HIP_L, THIGH_L, KNEE_L, SOCK_L,
	SKATE_L_COLLAR, SKATE_L_STRIPE,
	FOOT_L_SHELL, FOOT_L_TOE, FOOT_L_HOLDER, FOOT_L_RUNNER, FOOT_L_LACES,
	HIP_R, THIGH_R, KNEE_R, SOCK_R,
	SKATE_R_COLLAR, SKATE_R_STRIPE,
	FOOT_R_SHELL, FOOT_R_TOE, FOOT_R_HOLDER, FOOT_R_RUNNER, FOOT_R_LACES,
}
const LEG_SURFACE_COUNT: int = 22


static func shared_leg_skin_mesh() -> ArrayMesh:
	return _shared("leg_skin", func() -> ArrayMesh:
		var m := ArrayMesh.new()
		var hip: ArrayMesh = _shared("hip", _build_hip)
		var thigh: ArrayMesh = _shared("thigh", _build_thigh)
		var knee: ArrayMesh = _shared("knee", _build_knee)
		var sock: ArrayMesh = _shared("sock", _build_sock)
		var skate: ArrayMesh = shared_skate_assembly()
		var boot: ArrayMesh = shared_boot_assembly()
		# Appended in LegSurface order — see the enum.
		for side: int in 2:
			var leg: int = LegBone.LEG_L if side == 0 else LegBone.LEG_R
			var shin: int = LegBone.SHIN_L if side == 0 else LegBone.SHIN_R
			_append_skinned_surface(m, hip, leg + 1)
			_append_skinned_surface(m, thigh, leg + 2)
			_append_skinned_surface(m, knee, leg + 3)
			_append_skinned_surface(m, sock, shin + 1)
			_append_skinned_surface(m, skate, shin + 2, SKATE_SURF_COLLAR)
			_append_skinned_surface(m, skate, shin + 2, SKATE_SURF_STRIPE)
			_append_skinned_surface(m, boot, shin + 3, BOOT_SURF_SHELL)
			_append_skinned_surface(m, boot, shin + 3, BOOT_SURF_TOE)
			_append_skinned_surface(m, boot, shin + 3, BOOT_SURF_HOLDER)
			_append_skinned_surface(m, boot, shin + 3, BOOT_SURF_RUNNER)
			_append_skinned_surface(m, boot, shin + 3, BOOT_SURF_LACES)
		return m)


static func shared_leg_skin() -> Skin:
	if _leg_skin == null:
		_leg_skin = Skin.new()
		for i: int in LEG_BONE_COUNT:
			_leg_skin.add_bind(i, Transform3D.IDENTITY)
	return _leg_skin


static var _leg_skin: Skin = null


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
const BOOT_SURF_TOE: int = 1
const BOOT_SURF_HOLDER: int = 2
const BOOT_SURF_RUNNER: int = 3
const BOOT_SURF_LACES: int = 4
const SKATE_SURF_COLLAR: int = 0
const SKATE_SURF_STRIPE: int = 1
# Surfaces WITHIN a part mesh, for the three parts that split into pieces a
# gear model paints separately (see _build_boot / _build_skate_blade /
# shared_glove_fist).
const BOOT_PART_QUARTER: int = 0
const BOOT_PART_TOE: int = 1
const BLADE_PART_HOLDER: int = 0
const BLADE_PART_RUNNER: int = 1
const FIST_PART_BACK: int = 0
const FIST_PART_FINGERS: int = 1
const HELMET_SURF_SHELL: int = 0
const HELMET_SURF_SKIN: int = 1


# The per-instance material for one surface, created from the surface's shared
# default on first use. Every writer must go through this: the default lives on
# the CACHED mesh that all skaters share, so painting it directly would repaint
# the whole roster. Returns a material that is safe to mutate.
static func surface_override(mesh: MeshInstance3D, surface: int) -> StandardMaterial3D:
	var mat: StandardMaterial3D = mesh.get_surface_override_material(surface) as StandardMaterial3D
	if mat != null:
		return mat
	var shared: StandardMaterial3D = mesh.mesh.surface_get_material(surface) as StandardMaterial3D
	mat = shared.duplicate() as StandardMaterial3D if shared != null else StandardMaterial3D.new()
	mesh.set_surface_override_material(surface, mat)
	return mat


static func shared_skate_assembly() -> ArrayMesh:
	return _shared("skate_assembly", _build_skate_assembly)


static func _build_skate_assembly() -> ArrayMesh:
	var m := ArrayMesh.new()
	_append_surface(m, _shared("skate", _build_skate))
	# The stripe carried its offset and radius as node transform, so unlike the
	# boot's parts it has to be baked. Safe because the collar's own scaling is
	# axis-aligned and the stripe has no rotation — diagonal scales commute, so
	# baking cannot shear it the way a rotated child would.
	_append_surface(m, shared_skate_stripe(), Transform3D(
			Basis.IDENTITY.scaled(Vector3(_SKATE_STRIPE_RADIUS, 1.0, _SKATE_STRIPE_RADIUS)),
			Vector3(0.0, _SKATE_STRIPE_Y, 0.0)))
	var stripe := StandardMaterial3D.new()
	stripe.albedo_color = Color(0.08, 0.08, 0.08)
	stripe.roughness = 0.42
	BodyRim.apply(stripe)
	m.surface_set_material(SKATE_SURF_STRIPE, stripe)
	return m


static func shared_helmet_assembly() -> ArrayMesh:
	return _shared("helmet_assembly", _build_helmet_assembly)


static func _build_helmet_assembly() -> ArrayMesh:
	var m := ArrayMesh.new()
	_append_surface(m, _shared("helmet", _build_helmet))
	# Head and neck were separate nodes but always wore the SAME skin material,
	# so they collapse into one surface rather than two — one skin colour to
	# paint, and Skater.set_skin_tone has a single target.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.append_from(_shared("head", _build_head), 0,
			Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -_HEAD_FORWARD_M)))
	st.append_from(_shared("neck", _build_neck), 0, Transform3D.IDENTITY)
	st.commit(m)
	m.surface_set_material(HELMET_SURF_SKIN, _make_skin_mat())
	return m


static func shared_boot_assembly() -> ArrayMesh:
	return _shared("boot_assembly", _build_boot_assembly)


static func _build_boot_assembly() -> ArrayMesh:
	var m := ArrayMesh.new()
	var boot: ArrayMesh = _shared("boot", _build_boot)
	var blade: ArrayMesh = _shared("skate_blade", _build_skate_blade)
	_append_surface(m, boot, Transform3D.IDENTITY, BOOT_PART_QUARTER)
	_append_surface(m, boot, Transform3D.IDENTITY, BOOT_PART_TOE)
	_append_surface(m, blade, Transform3D.IDENTITY, BLADE_PART_HOLDER)
	_append_surface(m, blade, Transform3D.IDENTITY, BLADE_PART_RUNNER)
	_append_surface(m, shared_laces())
	# Defaults for the merged surfaces, standing in for the material_override
	# their child nodes used to carry — so an unpainted rig (workbench preview,
	# a spawn before the uniform pass) still shows steel and white laces rather
	# than untextured white. Surface 0 is left null on purpose: _swap_instance
	# carries the scene primitive's material onto it, exactly as before.
	var steel := StandardMaterial3D.new()
	steel.albedo_color = BLADE_STEEL_COLOR
	steel.roughness = 0.25
	BodyRim.apply(steel)
	m.surface_set_material(BOOT_SURF_RUNNER, steel)
	var lace := StandardMaterial3D.new()
	lace.albedo_color = _LACE_COLOR
	lace.roughness = 0.9
	BodyRim.apply(lace)
	m.surface_set_material(BOOT_SURF_LACES, lace)
	return m


# Appends `src`'s surface 0 to `target` as a new surface. The children this
# replaces all sat at identity relative to their parent, so no transform is
# baked — which is also why the merge cannot change the rendered geometry.
static func _append_surface(target: ArrayMesh, src: ArrayMesh,
		xform: Transform3D = Transform3D.IDENTITY, src_surface: int = 0) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.append_from(src, src_surface, xform)
	st.commit(target)


# The same prism with the old wrapper's 90°-about-X baked into the vertices, so
# its long axis is local Z — the axis the arm rig's looking_at basis aims. The
# mesh's long axis used to disagree with the aiming axis, which is the only
# reason each bone needed a rotated child; baking the rotation let one transform
# carry (radius, radius, length).
static func shared_arm_bone_z() -> ArrayMesh:
	return _shared("arm_bone_z", func() -> ArrayMesh:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.append_from(shared_arm_bone(), 0,
				Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3.ZERO))
		return st.commit())


# ── The upper-body rig: one skinned mesh, one Skeleton3D ─────────────────────
# Fourteen parts that used to be fourteen MeshInstance3D children of UpperBody —
# both arms, the torso, the helmet/head unit and the two deltoid caps — each
# carrying a shared mesh and its own per-frame transform. They are now fourteen
# bones of one skeleton driving one mesh, which is how an articulated body is
# supposed to be built, and it takes the per-frame cost from a Node3D transform
# write each (dirtying a subtree and pushing a global to the RenderingServer)
# down to entries in the skeleton's pose array.
#
# WHY IT IS EXACT, not merely close: every vertex is weighted 1.0 to a single
# bone, the bone rests are identity, and the skin binds are identity. A skinned
# vertex is then `bone_pose * v`, which is precisely what a child node with that
# local transform produced. The parts' geometry is left in its own local space
# (untransformed) for the same reason — it is already the space the shared
# meshes were authored in. So `set_bone_pose(part, X)` takes the SAME X the old
# `node.transform = X` took, and the pose diff can hold the renderer to it.
#
# The flat bone list (no parents) is deliberate and matches the old layout: all
# fourteen were siblings under UpperBody, each posed independently in that space.
# A hierarchy would compose transforms the old rig never composed. (The legs are
# the opposite case — see LegBone.)
enum UpperBone {
	TOP_UPPER_ARM,
	TOP_FOREARM,
	BOTTOM_UPPER_ARM,
	BOTTOM_FOREARM,
	TOP_ELBOW,
	BOTTOM_ELBOW,
	TOP_HAND,
	BOTTOM_HAND,
	TOP_CUFF,
	BOTTOM_CUFF,
	TORSO,
	HELMET,
	SHOULDER_L,
	SHOULDER_R,
}
const UPPER_BONE_COUNT: int = 14

# Surfaces. One per bone for the first thirteen; the helmet is the exception,
# carrying the shell and the head/neck skin as two surfaces of one bone (they
# never moved relative to each other, only needed separate materials). Merging
# the arm parts that share a material would cut draw calls further, but that is a
# different change with a different risk (crossed paint) — see skater_matrix.gd.
#
# The two FINGERS surfaces ride the hand bones but are listed LAST, out of
# anatomical order, on purpose: for the first ten entries a surface index and
# its bone index coincide, and the uniform painter passes UpperBone values to
# the surface seams on the strength of it. Inserting the fingers next to the
# hands would break that silently. Append new arm surfaces here, at the end.
enum UpperSurface {
	TOP_UPPER_ARM,
	TOP_FOREARM,
	BOTTOM_UPPER_ARM,
	BOTTOM_FOREARM,
	TOP_ELBOW,
	BOTTOM_ELBOW,
	TOP_HAND,
	BOTTOM_HAND,
	TOP_CUFF,
	BOTTOM_CUFF,
	TORSO,
	HELMET_SHELL,
	HELMET_SKIN,
	SHOULDER_L,
	SHOULDER_R,
	TOP_FINGERS,
	BOTTOM_FINGERS,
}
const UPPER_SURFACE_COUNT: int = 17
# Scene node name per bone for the four parts whose placement is authored in
# Scenes/Skater.tscn rather than derived (the arm parts are placed by IK). Read
# by Skater._build_upper_rig, which then frees them — same deal as LEG_BONE_NODE.
# Indices 0-9 are unused; the arm parts have no scene node.
const UPPER_BONE_NODE: Array[String] = [
	"", "", "", "", "", "", "", "", "", "",
	"UpperBodyMesh", "Helmet", "ShoulderL", "ShoulderR",
]


static func shared_upper_skin_mesh() -> ArrayMesh:
	return _shared("upper_skin", func() -> ArrayMesh:
		var m := ArrayMesh.new()
		var bone: ArrayMesh = shared_arm_bone_z()
		var ball: ArrayMesh = shared_joint_ball()
		var fist: ArrayMesh = shared_glove_fist()
		var cuff: ArrayMesh = shared_cuff()
		var helmet: ArrayMesh = shared_helmet_assembly()
		var shoulder: ArrayMesh = _shared("shoulder", _build_shoulder)
		# Appended in UpperSurface order. For the ten arm parts the surface index
		# and the bone index coincide, which is why they can share a number.
		_append_skinned_surface(m, bone, UpperBone.TOP_UPPER_ARM)
		_append_skinned_surface(m, bone, UpperBone.TOP_FOREARM)
		_append_skinned_surface(m, bone, UpperBone.BOTTOM_UPPER_ARM)
		_append_skinned_surface(m, bone, UpperBone.BOTTOM_FOREARM)
		_append_skinned_surface(m, ball, UpperBone.TOP_ELBOW)
		_append_skinned_surface(m, ball, UpperBone.BOTTOM_ELBOW)
		_append_skinned_surface(m, fist, UpperBone.TOP_HAND, FIST_PART_BACK)
		_append_skinned_surface(m, fist, UpperBone.BOTTOM_HAND, FIST_PART_BACK)
		_append_skinned_surface(m, cuff, UpperBone.TOP_CUFF)
		_append_skinned_surface(m, cuff, UpperBone.BOTTOM_CUFF)
		_append_skinned_surface(m, _shared("torso", _build_torso), UpperBone.TORSO)
		_append_skinned_surface(m, helmet, UpperBone.HELMET, HELMET_SURF_SHELL)
		_append_skinned_surface(m, helmet, UpperBone.HELMET, HELMET_SURF_SKIN)
		_append_skinned_surface(m, shoulder, UpperBone.SHOULDER_L)
		_append_skinned_surface(m, shoulder, UpperBone.SHOULDER_R)
		# Out of anatomical order — see the UpperSurface doc block.
		_append_skinned_surface(m, fist, UpperBone.TOP_HAND, FIST_PART_FINGERS)
		_append_skinned_surface(m, fist, UpperBone.BOTTOM_HAND, FIST_PART_FINGERS)
		return m)


# Identity binds, so the skinned vertex is the bone pose alone. Shared by every
# skater: Godot builds a per-instance SkinReference from one Skin resource.
static func shared_upper_skin() -> Skin:
	if _upper_skin == null:
		_upper_skin = Skin.new()
		for i: int in UPPER_BONE_COUNT:
			_upper_skin.add_bind(i, Transform3D.IDENTITY)
	return _upper_skin


static var _upper_skin: Skin = null


# Copies a single-surface mesh into `target` verbatim, adding the bone/weight
# attributes that make every one of its vertices rigid to `bone`.
#
# Goes through surface_get_arrays rather than SurfaceTool because SurfaceTool
# re-processes what it is given — it would re-index and could re-derive normals,
# and this mesh has to be vertex-for-vertex what the unskinned one was or the
# pose diff is comparing two different models. Copying the arrays and adding two
# more changes nothing else.
static func _append_skinned_surface(target: ArrayMesh, src: ArrayMesh, bone: int,
		src_surface: int = 0) -> void:
	var arrays: Array = src.surface_get_arrays(src_surface)
	var vertex_count: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var bones := PackedInt32Array()
	bones.resize(vertex_count * 4)
	var weights := PackedFloat32Array()
	weights.resize(vertex_count * 4)
	# resize() zero-fills, so influences 1-3 are already bone 0 at weight 0.
	for i: int in vertex_count:
		bones[i * 4] = bone
		weights[i * 4] = 1.0
	arrays[Mesh.ARRAY_BONES] = bones
	arrays[Mesh.ARRAY_WEIGHTS] = weights
	target.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	# Carry the source surface's shared default across, so surface_override()
	# still has something to duplicate for parts that ship with one (the boot's
	# steel and laces).
	var shared: Material = src.surface_get_material(src_surface)
	if shared != null:
		target.surface_set_material(target.get_surface_count() - 1, shared)


# Elbow ball, unit radius.
static func shared_joint_ball() -> ArrayMesh:
	return _shared("joint_ball", func() -> ArrayMesh:
		return _build_ball(1.0, 8, 4, 1.0))


# Gloved fist (see _GLOVE_FIST_STATIONS): the BACK of the hand on surface 0
# and the FINGERS on surface 1, each closed at the knuckle ring they share.
static func shared_glove_fist() -> ArrayMesh:
	return _shared("glove_fist", func() -> ArrayMesh:
		var loops: Array[PackedVector3Array] = []
		for s: Vector3 in _GLOVE_FIST_STATIONS:
			loops.append(_octagon_loop(s.x, s.y, s.z, 0.6, 0.55))
		var m := ArrayMesh.new()
		_commit_sweep_segment(m, loops, 0, _GLOVE_FINGER_STATION, _fist_loop_center)
		_commit_sweep_segment(m, loops, _GLOVE_FINGER_STATION, loops.size() - 1,
				_fist_loop_center)
		return m)


# A fist loop's axis point — the sweep runs along local Y, so the caps fan to
# the loop's own height on that axis.
static func _fist_loop_center(loop: PackedVector3Array) -> Vector3:
	return Vector3(0.0, loop[0].y, 0.0)


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


# ── Helmet face gear ─────────────────────────────────────────────────────────
# Visor / cage / fishbowl, in the helmet's own frame (face toward −Z, matching
# the head's forward offset) so the piece can ride the HELMET bone. All three
# are sections of a sphere just proud of the shell, sampled with the helmet's
# latitude convention: the shields are one solid patch each, the cage is the
# same patch emitted as thin strips (its bars). Looks (color/alpha/roughness)
# live in GearModelRegistry.FACE_*; the meshes carry no default material —
# SkaterUniformCoordinator.make_face_gear_material is the one paint source.

const _FACE_SHIELD_RADIUS: float = 0.158  # proud of the 0.155 shell
# Visor: brow to just under the eye line (the equator). Ends short of the ear
# loops (rim dips at ±90° from the face) so it reads as clipped to the rim.
const _VISOR_V0: float = 0.41   # tucked under the brow rim (front cut 0.40)
const _VISOR_V1: float = 0.55
const _VISOR_HALF_ARC: float = 1.25   # rad each side of dead front
# Fishbowl: the same shield carried down past the chin (the head ball's south
# pole region — v 0.78 is jaw depth on the shield's slightly larger radius).
const _FISHBOWL_V1: float = 0.78
const _FISHBOWL_HALF_ARC: float = 1.35
# Cage: a bar lattice over the fishbowl's opening. Bar half-width is metres of
# arc, converted per-axis to parameter half-widths where the bars are emitted.
const _CAGE_RADIUS: float = 0.157
const _CAGE_BAR_HALF_M: float = 0.003
const _CAGE_V0: float = 0.42
const _CAGE_V1: float = 0.72
const _CAGE_HALF_ARC: float = 1.15
const _CAGE_H_BAR_COUNT: int = 4
const _CAGE_V_BAR_OFFSETS: Array[float] = [-0.84, -0.42, 0.0, 0.42, 0.84]


# The face piece's fixed look — the one gear piece whose colors never resolve
# against the kit (a visor is smoked polycarbonate and a cage bare steel
# whoever wears them), so the material lives here with the geometry instead of
# on the uniform coordinator, and the gear workbench turntable and the capture
# tool dress their previews from the same factory. The shields carry their
# transparency in the registry alpha; the cage is an open lattice of one-sided
# strips, so it renders two-sided instead.
static func make_face_gear_material(option: int) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = GearModelRegistry.face_color(option)
	mat.roughness = GearModelRegistry.face_roughness(option)
	if mat.albedo_color.a < 1.0:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if option == GearModelRegistry.FACE_CAGE:
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


# The face piece for one GearModelRegistry FACE_* option — null for bare (and
# for a forged index, matching the registry's clamp).
static func shared_face_gear(option: int) -> ArrayMesh:
	match option:
		GearModelRegistry.FACE_VISOR:
			return _shared("face_visor", _build_visor)
		GearModelRegistry.FACE_CAGE:
			return _shared("face_cage", _build_cage)
		GearModelRegistry.FACE_FISHBOWL:
			return _shared("face_fishbowl", _build_fishbowl)
		_:
			return null


static func _build_visor() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)  # flat shading — see class doc block
	_sphere_patch(st, _FACE_SHIELD_RADIUS, _VISOR_V0, _VISOR_V1,
			PI - _VISOR_HALF_ARC, PI + _VISOR_HALF_ARC, 2, 8)
	st.generate_normals()
	return st.commit()


static func _build_fishbowl() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)  # flat shading — see class doc block
	_sphere_patch(st, _FACE_SHIELD_RADIUS, _VISOR_V0, _FISHBOWL_V1,
			PI - _FISHBOWL_HALF_ARC, PI + _FISHBOWL_HALF_ARC, 3, 10)
	st.generate_normals()
	return st.commit()


static func _build_cage() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)  # flat shading — see class doc block
	# Latitude half-width of a horizontal bar: metres over the pole-to-pole arc.
	var dv: float = _CAGE_BAR_HALF_M / (PI * _CAGE_RADIUS)
	for i: int in _CAGE_H_BAR_COUNT:
		var v: float = lerpf(_CAGE_V0 + dv, _CAGE_V1 - dv,
				float(i) / float(_CAGE_H_BAR_COUNT - 1))
		_sphere_patch(st, _CAGE_RADIUS, v - dv, v + dv,
				PI - _CAGE_HALF_ARC, PI + _CAGE_HALF_ARC, 1, 8)
	# Azimuth half-width of a vertical bar: metres over the ring radius at the
	# lattice's mid-latitude. Constant per bar, so bars taper slightly toward
	# the brow where rings shrink — as welded cage wire does.
	var dth: float = _CAGE_BAR_HALF_M \
			/ (_CAGE_RADIUS * sin(PI * (_CAGE_V0 + _CAGE_V1) * 0.5))
	for off: float in _CAGE_V_BAR_OFFSETS:
		_sphere_patch(st, _CAGE_RADIUS, _CAGE_V0, _CAGE_V1,
				PI + off - dth, PI + off + dth, 4, 1)
	st.generate_normals()
	return st.commit()


# One rectangular patch of a sphere between two (latitude, azimuth) corners,
# sampled on a v_steps × th_steps quad grid. Conventions match _build_helmet:
# θ = 0 is +Z (the back) advancing toward +X, v is the latitude fraction, and
# the quad winding faces outward. UVs are nominal — every face piece is
# solid-painted. Open sheet, not a solid: the shields are millimetre glazing
# and the bars are wire, so a closed back would double the triangles to say
# nothing (their materials go two-sided or transparent instead).
static func _sphere_patch(st: SurfaceTool, radius: float, v0: float, v1: float,
		th0: float, th1: float, v_steps: int, th_steps: int) -> void:
	for j in v_steps:
		var va: float = lerpf(v0, v1, float(j) / float(v_steps))
		var vb: float = lerpf(v0, v1, float(j + 1) / float(v_steps))
		for k in th_steps:
			var ta: float = lerpf(th0, th1, float(k) / float(th_steps))
			var tb: float = lerpf(th0, th1, float(k + 1) / float(th_steps))
			_uv_quad(st,
					_sphere_point(radius, va, ta), Vector2.ZERO,
					_sphere_point(radius, va, tb), Vector2(0.1, 0.0),
					_sphere_point(radius, vb, tb), Vector2(0.1, 0.1),
					_sphere_point(radius, vb, ta), Vector2(0.0, 0.1))


static func _sphere_point(radius: float, v: float, theta: float) -> Vector3:
	var ring_r: float = radius * sin(PI * v)
	return Vector3(sin(theta) * ring_r, radius * cos(PI * v), cos(theta) * ring_r)


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
# The boot as its two paintable pieces: the QUARTER (heel through instep) on
# surface 0 and the TOE cap on surface 1. Both are closed solids — each caps
# the ring they share, so the junction faces are interior and the winding
# stays testable (same reasoning as the helmet's liner closure).
static func _build_boot() -> ArrayMesh:
	var loops: Array[PackedVector3Array] = []
	for s: Vector4 in _BOOT_STATIONS:
		loops.append(_boot_loop(s.x, s.y, s.z, s.w))
	var m := ArrayMesh.new()
	_commit_sweep_segment(m, loops, 0, _BOOT_TOE_STATION, _boot_loop_center)
	_commit_sweep_segment(m, loops, _BOOT_TOE_STATION, loops.size() - 1, _boot_loop_center)
	return m


# A boot loop's axis point, midway between its top and sole edges — the apex
# each end cap fans to.
static func _boot_loop_center(loop: PackedVector3Array) -> Vector3:
	return Vector3(0.0, loop[0].y, (loop[0].z + loop[2].z) * 0.5)


# Sweeps `loops[first..last]` into a new closed surface of `target`, capping
# both ends so the piece is a solid on its own. `center_of` returns the axis
# point a loop's cap fans to. Splitting a sweep this way is how one part
# becomes several PAINTABLE pieces without becoming several meshes.
static func _commit_sweep_segment(target: ArrayMesh, loops: Array[PackedVector3Array],
		first: int, last: int, center_of: Callable) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)  # flat shading — see class doc block
	_sweep_loops(st, loops.slice(first, last + 1))
	_loop_cap(st, loops[first], center_of.call(loops[first]), true)
	_loop_cap(st, loops[last], center_of.call(loops[last]), false)
	st.generate_normals()
	st.commit(target)


# The blade as its two pieces: the HOLDER on surface 0 and the steel RUNNER on
# surface 1 (see the _BLADE_* constants' doc). They are separate surfaces
# because they are separate materials in life — the holder is molded plastic a
# player picks the color of, the runner is steel and always will be.
#
# The holder is one piece, not two posts: two towers dropping from the sole
# (they tuck up into it — z 0.042 < the boot's 0.045 sole line) bridged along
# the bottom by the RAIL the runner seats into, so only the steel's last few
# millimetres show below it. The arch between the towers stays open above the
# rail, which is the window a real holder is recognised by.
static func _build_skate_blade() -> ArrayMesh:
	var m := ArrayMesh.new()
	var holder := SurfaceTool.new()
	holder.begin(Mesh.PRIMITIVE_TRIANGLES)
	holder.set_smooth_group(-1)  # flat shading — see class doc block
	_box(holder, Vector3(-0.008, 0.036, 0.042), Vector3(0.008, 0.094, 0.098))    # heel tower
	_box(holder, Vector3(-0.008, -0.080, 0.042), Vector3(0.008, -0.026, 0.098))  # toe tower
	# Rail: tower to tower along the bottom, ending where the towers do, so the
	# runner's heel and toe tips still show past it.
	_box(holder, Vector3(-0.008, -0.080, 0.084), Vector3(0.008, 0.094, 0.098))
	holder.generate_normals()
	holder.commit(m)
	var runner := SurfaceTool.new()
	runner.begin(Mesh.PRIMITIVE_TRIANGLES)
	runner.set_smooth_group(-1)
	_box(runner, Vector3(-0.0035, -0.088, 0.090),
			Vector3(0.0035, 0.098, _BLADE_ICE_Z))
	runner.generate_normals()
	runner.commit(m)
	return m


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
