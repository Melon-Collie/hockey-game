class_name GoalieMeshBuilder
extends SkaterMeshBuilder

# Low-poly faceted replacements for the goalie's primitive part meshes:
# chest-protector body, mask, leg pads with roll ridges, catch glove (rim +
# pocket + detail ball), blocker board and hand, plus the unit tube the hip
# connectors stretch. Extends SkaterMeshBuilder for its emission toolbox
# (lathe / ball / loop sweep / caps) and the shared mesh cache — same flat-
# shaded style, so both "players" read as one art set.
#
# Visual-only: every part stays inside the envelope of the primitive it
# replaces. The sibling COLLIDERS in Goalie.tscn are untouched — saves,
# rebounds, and skater bumps are byte-identical.
#
# The body must keep three goalie_jersey.gdshader contracts: a flat +Z back
# region (normal.z > 0.9 gates the nameplate projection), a flat top face
# (normal.y > 0.9 gates the yoke), and the box's full ±0.36 object-Y span
# (stripes map over it). The sweep below tapers WIDTH only — depth stays
# constant so every back facet keeps its exact +Z normal.

# Body cross-section (replaces the 0.52 × 0.72 × 0.28 BoxMesh): flat back,
# chamfered front — a chest protector rather than a crate. Stations are
# (y, width multiplier); depth is fixed.
const _BODY_HALF_W: float = 0.26
const _BODY_HALF_D: float = 0.14
const _BODY_STATIONS: Array[Vector2] = [
	Vector2(0.36, 0.965),   # shoulder line
	Vector2(0.20, 1.0),     # chest
	Vector2(-0.05, 1.0),
	Vector2(-0.25, 0.955),  # waist
	Vector2(-0.36, 0.92),
]

# Leg pad (replaces the 0.28 × 0.84 × 0.2 BoxMesh): chamfered-octagon slab
# with alternating girth stations — the horizontal roll ridges of a real pad.
# Depth-symmetric, so the butterfly flare rotations read the same from every
# side. Stations are (y, girth multiplier) applied to width and depth both.
const _PAD_HALF_W: float = 0.14
const _PAD_HALF_D: float = 0.10
const _PAD_STATIONS: Array[Vector2] = [
	Vector2(0.42, 0.94),
	Vector2(0.32, 1.0),     # thigh roll
	Vector2(0.22, 0.94),
	Vector2(0.12, 1.0),     # knee roll
	Vector2(0.02, 0.94),
	Vector2(-0.10, 1.0),    # shin roll
	Vector2(-0.24, 0.97),
	Vector2(-0.42, 0.90),   # boot channel
]

# Mask (replaces the oblate head sphere, r 0.17 × height 0.26): faceted
# oblate ball with a chin cut — reads as a goalie mask shell, not a beach
# ball. y scale is the original sphere's height/diameter ratio.
const _MASK_RADIUS: float = 0.17
const _MASK_Y_SCALE: float = 0.7647
const _MASK_CUT_V: float = 0.88

# Catch glove — a trapper built from the scene's three glove nodes. Frame
# note: Ring/Main sit in a rotated frame (local −Y faces the shooter, local
# +Z is down, X lateral); the cuff node is unrotated at the glove origin —
# which is the wrist, where the drawn forearm terminates.
#   - Rim (replaces the TorusMesh): an oval hoop, meatier on the up side
#     where a trapper's finger stalls and T-web live, thinner at the heel.
#   - Pocket (replaces the flat disc): a rounded pot behind the rim, its
#     front face the catch surface.
#   - Cuff (replaces the floating detail ball): a chamfered wrist block.
const _GLOVE_RING_R: float = 0.108
const _GLOVE_RING_X_SCALE: float = 1.06   # oval: wider laterally than tall
const _GLOVE_RING_Z_SCALE: float = 0.94
const _GLOVE_TUBE_MIN_R: float = 0.022    # heel side
const _GLOVE_TUBE_MAX_R: float = 0.034    # finger/web side (local −Z = up)
const _GLOVE_POCKET_PROFILE: Array[Vector2] = [
	Vector2(0.060, 0.040),    # pocket back (toward the body)
	Vector2(0.035, 0.082),
	Vector2(0.000, 0.100),
	Vector2(-0.040, 0.110),
	Vector2(-0.055, 0.098),   # front lip, curling in behind the rim
]
const _GLOVE_CUFF_HALF_W: float = 0.075
const _GLOVE_CUFF_HALF_D: float = 0.032
const _GLOVE_CUFF_HALF_H: float = 0.070

# Blocker board (replaces the 0.2 × 0.3 × 0.05 BoxMesh) and hand ball.
const _BLOCKER_HALF_W: float = 0.10
const _BLOCKER_HALF_D: float = 0.025
const _BLOCKER_HALF_H: float = 0.15
const _BLOCKER_HAND_R: float = 0.05

# Hip connector tube radius — baked into the shared connector mesh; the
# per-frame stretch in Goalie._point_connector scales the basis Y column only.
const HIP_CONNECTOR_RADIUS: float = 0.08


# Swaps every scene-primitive goalie part for its cached low-poly build.
# Idempotent; the uniform coordinator's material_override painting and the
# jersey ShaderMaterial ride mesh identity unchanged. (Named apart from the
# inherited SkaterMeshBuilder.apply — GDScript forbids overriding with a
# different signature.)
static func apply_goalie(goalie: Goalie) -> void:
	_swap_instance(goalie.body_mesh, "goalie_body", _build_body)
	_swap_instance(goalie.head_mesh, "goalie_mask", _build_mask)
	_swap_instance(goalie.left_pad_mesh, "goalie_pad", _build_pad)
	_swap_instance(goalie.right_pad_mesh, "goalie_pad", _build_pad)
	_swap_instance(goalie.glove_ring_mesh, "goalie_glove_ring", _build_glove_ring)
	_swap_instance(goalie.glove_main_mesh, "goalie_glove_pocket", _build_glove_pocket)
	_swap_instance(goalie.glove_detail_mesh, "goalie_glove_cuff", _build_glove_cuff)
	_swap_instance(goalie.blocker_mesh, "goalie_blocker", _build_blocker)
	_swap_instance(goalie.blocker_hand_mesh, "goalie_blocker_hand", _build_blocker_hand)


# Unit-radius, unit-height straight tube for the hip connectors (the arm
# bones use the tapered shared_arm_bone instead). Cylinder-convention UVs —
# the connectors are painted with the pants stripe texture.
static func shared_connector_tube() -> ArrayMesh:
	return _shared("goalie_connector", func() -> ArrayMesh:
		var profile: Array[Vector2] = [
			Vector2(0.5, HIP_CONNECTOR_RADIUS), Vector2(-0.5, HIP_CONNECTOR_RADIUS)]
		return _build_lathe(profile, 8, 1.0, 1.0))


# ── Part builders ─────────────────────────────────────────────────────────────


static func _build_body() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)  # flat shading — see SkaterMeshBuilder doc block
	var loops: Array[PackedVector3Array] = []
	for s: Vector2 in _BODY_STATIONS:
		loops.append(_body_loop(s.x, s.y))
	_sweep_loops(st, loops)
	_loop_cap(st, loops[0], Vector3(0.0, _BODY_STATIONS[0].x, 0.0), true)     # top (yoke)
	_loop_cap(st, loops[loops.size() - 1],
			Vector3(0.0, _BODY_STATIONS[_BODY_STATIONS.size() - 1].x, 0.0), false)
	st.generate_normals()
	return st.commit()


# 8-point chest cross-section, CCW seen from +Y (the sweep-loop contract):
# generous flat back segment at +Z for the nameplate, wide chamfers rounding
# the front. Width multiplier scales x only — see the class doc block.
static func _body_loop(y: float, w_mult: float) -> PackedVector3Array:
	var hw: float = _BODY_HALF_W * w_mult
	var hd: float = _BODY_HALF_D
	var pts := PackedVector3Array()
	pts.resize(8)
	pts[0] = Vector3(-0.13 * w_mult, y, -hd)   # front-left
	pts[1] = Vector3(-hw, y, -0.05)
	pts[2] = Vector3(-hw, y, 0.08)
	pts[3] = Vector3(-0.21 * w_mult, y, hd)    # back-left
	pts[4] = Vector3(0.21 * w_mult, y, hd)     # back-right
	pts[5] = Vector3(hw, y, 0.08)
	pts[6] = Vector3(hw, y, -0.05)
	pts[7] = Vector3(0.13 * w_mult, y, -hd)    # front-right
	return pts


static func _build_pad() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)  # flat shading — see SkaterMeshBuilder doc block
	var loops: Array[PackedVector3Array] = []
	for s: Vector2 in _PAD_STATIONS:
		loops.append(_octagon_loop(s.x, _PAD_HALF_W * s.y, _PAD_HALF_D * s.y, 0.64, 0.55))
	_sweep_loops(st, loops)
	_loop_cap(st, loops[0], Vector3(0.0, _PAD_STATIONS[0].x, 0.0), true)
	_loop_cap(st, loops[loops.size() - 1],
			Vector3(0.0, _PAD_STATIONS[_PAD_STATIONS.size() - 1].x, 0.0), false)
	st.generate_normals()
	return st.commit()


static func _build_blocker() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)  # flat shading — see SkaterMeshBuilder doc block
	var loops: Array[PackedVector3Array] = [
		_octagon_loop(_BLOCKER_HALF_H, _BLOCKER_HALF_W, _BLOCKER_HALF_D, 0.75, 0.48),
		_octagon_loop(-_BLOCKER_HALF_H, _BLOCKER_HALF_W, _BLOCKER_HALF_D, 0.75, 0.48),
	]
	_sweep_loops(st, loops)
	_loop_cap(st, loops[0], Vector3(0.0, _BLOCKER_HALF_H, 0.0), true)
	_loop_cap(st, loops[1], Vector3(0.0, -_BLOCKER_HALF_H, 0.0), false)
	st.generate_normals()
	return st.commit()


# Chamfered-rectangle cross-section, CCW seen from +Y. face_frac is the flat
# front/back segment's half-width as a fraction of hw; side_frac the flat
# side segment's half-depth as a fraction of hd.
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


static func _build_mask() -> ArrayMesh:
	return _build_ball(_MASK_RADIUS, 10, 6, _MASK_CUT_V, _MASK_Y_SCALE)


# Faceted oval hoop, axis local +Y like the TorusMesh it replaces (the Glove
# node's rotated frame points that axis at the shooter). The tube thickens
# from the heel (local +Z = down) to the finger/web side (−Z = up) so the
# hoop reads as a trapper's rim rather than a donut. Tube loops play the
# "stations" role of the sweep contract, advancing around the main ring with
# the first loop re-appended to close it.
static func _build_glove_ring() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)  # flat shading — see SkaterMeshBuilder doc block
	var main_segs: int = 10
	var tube_segs: int = 6
	var loops: Array[PackedVector3Array] = []
	for i in main_segs + 1:
		var theta: float = TAU * float(i % main_segs) / float(main_segs)
		# θ = 0 is local +Z (down/heel); cos(θ) = −1 at the up side.
		var lift: float = 0.5 - 0.5 * cos(theta)
		var tube_r: float = lerpf(_GLOVE_TUBE_MIN_R, _GLOVE_TUBE_MAX_R, lift)
		var center := Vector3(
				_GLOVE_RING_R * _GLOVE_RING_X_SCALE * sin(theta), 0.0,
				_GLOVE_RING_R * _GLOVE_RING_Z_SCALE * cos(theta))
		var radial: Vector3 = center.normalized()
		var pts := PackedVector3Array()
		pts.resize(tube_segs)
		for j in tube_segs:
			var phi: float = TAU * float(j) / float(tube_segs)
			pts[j] = center + radial * (tube_r * cos(phi)) + Vector3.UP * (tube_r * sin(phi))
		loops.append(pts)
	_sweep_loops(st, loops)
	st.generate_normals()
	return st.commit()


# Rounded pot behind the rim, its flat −Y cap the catch face the shooter
# sees; the profile's front lip curls in so the rim hoop overlaps it.
static func _build_glove_pocket() -> ArrayMesh:
	return _build_lathe(_GLOVE_POCKET_PROFILE, 10,
			_GLOVE_RING_X_SCALE, _GLOVE_RING_Z_SCALE)


static func _build_blocker_hand() -> ArrayMesh:
	return _build_ball(_BLOCKER_HAND_R, 8, 4, 1.0)


# Chamfered wrist block on the unrotated glove-origin node (parent frame:
# Y up, Z toward the goalie's back). Nudged backward so it reads as the cuff
# the pocket grows out of, meeting the drawn forearm at the origin.
static func _build_glove_cuff() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)  # flat shading — see SkaterMeshBuilder doc block
	var top: PackedVector3Array = _octagon_loop(
			_GLOVE_CUFF_HALF_H, _GLOVE_CUFF_HALF_W * 0.94, _GLOVE_CUFF_HALF_D, 0.7, 0.5)
	var bottom: PackedVector3Array = _octagon_loop(
			-_GLOVE_CUFF_HALF_H, _GLOVE_CUFF_HALF_W, _GLOVE_CUFF_HALF_D, 0.7, 0.5)
	# Shifted on the locals before nesting them — chained writes into a packed
	# array already stored inside an Array hit copy-on-write and vanish.
	for k in top.size():
		top[k] += Vector3(0.0, 0.0, 0.01)
		bottom[k] += Vector3(0.0, 0.0, 0.01)
	var loops: Array[PackedVector3Array] = [top, bottom]
	_sweep_loops(st, loops)
	_loop_cap(st, loops[0], Vector3(0.0, _GLOVE_CUFF_HALF_H, 0.01), true)
	_loop_cap(st, loops[1], Vector3(0.0, -_GLOVE_CUFF_HALF_H, 0.01), false)
	st.generate_normals()
	return st.commit()
