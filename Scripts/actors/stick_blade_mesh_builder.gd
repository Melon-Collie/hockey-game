class_name StickBladeMeshBuilder
extends RefCounted

# Procedural hockey-stick blade mesh. Replaces the old rectangular-prism
# BoxMesh with real blade geometry: a curved centerline (the "curve" of a
# stick pattern), a rounded toe, a heel→toe thickness taper, and a slight
# bottom-edge rocker. Cosmetic only — gameplay reads the Blade Marker3D and
# Skater.blade_length (heel + contact at mid-blade), never this mesh, so the
# builder must keep the toe at exactly `length` from the heel and otherwise
# owes the contact math nothing.
#
# Frame: HEEL-ORIGIN blade-local space. The heel (where the shaft meets the
# blade — the Blade Marker3D position) is at the origin; the toe tip is at
# z = −length (−Z is the marker's look_at forward). +Y is up, X is lateral.
# Building heel-origin (instead of the old centered BoxMesh) lets the
# cosmetic tilt in Skater._apply_blade_tilt pivot about the heel, so the
# shaft→blade junction stays pinned when the blade pitches with the shaft.
#
# The same builder produces the team-tape band: pass `inflate` (cross-section
# growth) and a `u_start`/`u_end` sub-span (fractions heel→toe) and the band
# hugs the curved blade instead of clipping through it as a straight box.
# u_start may be slightly negative so the band's heel cap sits proud of the
# blade's own heel cap (coplanar caps z-fight).
#
# Curve sign convention: +1 bows the centerline toward +X, which (with the
# marker's -Z-forward frame) puts the concave face on a LEFT-handed shooter's
# forehand. Pass −1 for a righty. Matches the face-open loft sign in
# Skater._apply_blade_tilt — flip there and here together if a side ever
# reads wrong in the editor.
#
# All Params defaults are real senior-blade measurements (metres): ~30 cm
# heel→toe, ~6 cm tall, ~2–3 cm rendered thickness (a touch chunky to match
# the proxy-art body), ~2 cm of curve (a mid "P92-like" pattern), toe
# rounding over the last quarter. A future gear system varies a player's
# stick by handing this builder different Params (curve depth/start = the
# pattern; toe_round = square vs round toe) — that's the whole seam.


class Params:
	var length: float = 0.30           # heel→toe, matches Skater.blade_length
	var height: float = 0.06           # blade face height
	var thickness_heel: float = 0.032  # cross-section thickness at the heel
	var thickness_toe: float = 0.019   # …tapering to this at the toe
	var curve_depth: float = 0.022     # max centerline bow at the toe
	var curve_start_frac: float = 0.35 # fraction from heel where the bow begins
	var toe_round_frac: float = 0.24   # fraction of length the toe rounds over
	var rocker_m: float = 0.006        # bottom-edge lift at heel/toe (mid flat)
	var curve_sign: float = 1.0        # +1 lefty, −1 righty (see doc block)
	var inflate: float = 0.0           # grow the cross-section (tape band)
	var u_start: float = 0.0           # span start, fraction heel→toe
	var u_end: float = 1.0             # span end, fraction heel→toe
	var segments: int = 16


# Height factor floor at the toe tip — the rounded toe ends in a small flat
# cap instead of a degenerate zero-height edge.
const _TOE_TIP_MIN_HEIGHT_FRAC: float = 0.18


static func build(p: Params) -> ArrayMesh:
	var n: int = maxi(p.segments, 2)
	# Station corner rings, heel→toe: front (+lateral) / back (−lateral),
	# bottom / top.
	var fb: PackedVector3Array = PackedVector3Array()
	var ft: PackedVector3Array = PackedVector3Array()
	var bt: PackedVector3Array = PackedVector3Array()
	var bb: PackedVector3Array = PackedVector3Array()
	fb.resize(n + 1)
	ft.resize(n + 1)
	bt.resize(n + 1)
	bb.resize(n + 1)

	for i in n + 1:
		var u: float = lerpf(p.u_start, p.u_end, float(i) / float(n))
		var z: float = -u * p.length
		# Centerline bow: quadratic ease from curve_start_frac out to the toe.
		var s: float = clampf(
				(u - p.curve_start_frac) / maxf(1.0 - p.curve_start_frac, 0.001), 0.0, 1.0)
		var bend: float = p.curve_sign * p.curve_depth * s * s
		# Cross-sections stay perpendicular to the bowed centerline: rotate the
		# lateral axis by the plan-view tangent so the toe doesn't shear.
		var dbend_du: float = p.curve_sign * p.curve_depth * 2.0 * s \
				/ maxf(1.0 - p.curve_start_frac, 0.001)
		var tangent: Vector2 = Vector2(dbend_du, -p.length).normalized()  # (x, z)
		var lateral: Vector2 = Vector2(-tangent.y, tangent.x)              # +X-ish
		var half_th: float = lerpf(p.thickness_heel, p.thickness_toe, clampf(u, 0.0, 1.0)) * 0.5 \
				+ p.inflate
		# Vertical profile: straight bottom edge with a slight rocker at the
		# extremes; the top edge sweeps down in a quarter-circle through the toe
		# zone so the toe rounds from the top while the bottom stays on the ice.
		var half_h: float = p.height * 0.5 + p.inflate
		var v: float = clampf(
				(u - (1.0 - p.toe_round_frac)) / maxf(p.toe_round_frac, 0.001), 0.0, 1.0)
		var height_frac: float = maxf(sqrt(maxf(1.0 - v * v, 0.0)), _TOE_TIP_MIN_HEIGHT_FRAC)
		var rocker_t: float = 2.0 * clampf(u, 0.0, 1.0) - 1.0
		var bottom_y: float = -half_h + p.rocker_m * rocker_t * rocker_t
		var top_y: float = bottom_y + (half_h - bottom_y) * height_frac
		# The rotated cross-section pivots about the centerline, so the outer
		# corner at the bowed toe would land a couple of mm past −length —
		# clamp so no part of the mesh ever exceeds the gameplay heel→toe span.
		var front_z: float = maxf(z + lateral.y * half_th, -p.length)
		var back_z: float = maxf(z - lateral.y * half_th, -p.length)
		var front_x: float = bend + lateral.x * half_th
		var back_x: float = bend - lateral.x * half_th
		fb[i] = Vector3(front_x, bottom_y, front_z)
		ft[i] = Vector3(front_x, top_y, front_z)
		bt[i] = Vector3(back_x, top_y, back_z)
		bb[i] = Vector3(back_x, bottom_y, back_z)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Flat shading: without this, generate_normals() averages normals across
	# every shared corner position (default smooth group), blurring the top /
	# face / cap directions into meaningless diagonals. Flat faces also match
	# the game's low-poly box-and-cylinder art.
	st.set_smooth_group(-1)
	for i in n:
		_quad(st, bt[i], bt[i + 1], ft[i + 1], ft[i])  # top (+Y)
		_quad(st, fb[i], fb[i + 1], bb[i + 1], bb[i])  # bottom (−Y)
		_quad(st, fb[i], ft[i], ft[i + 1], fb[i + 1])  # front face (+lateral)
		_quad(st, bb[i], bb[i + 1], bt[i + 1], bt[i])  # back face (−lateral)
	_quad(st, fb[0], bb[0], bt[0], ft[0])              # heel cap (+Z)
	_quad(st, bb[n], fb[n], ft[n], bt[n])              # toe cap (−Z)
	st.generate_normals()
	return st.commit()


# Emits one quad as two triangles. Corners are listed CLOCKWISE as seen from
# outside the mesh (Godot's front-face winding), so generate_normals() yields
# outward normals.
static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	st.add_vertex(a)
	st.add_vertex(b)
	st.add_vertex(c)
	st.add_vertex(a)
	st.add_vertex(c)
	st.add_vertex(d)
