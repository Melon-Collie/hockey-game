class_name StickBladeMeshBuilder
extends RefCounted

# Procedural hockey-stick blade mesh: a bowed centerline (the "curve" of a stick
# pattern), a heel→toe height taper closed by a rounded toe, a thickness taper,
# and a toe kick off the ice. Cosmetic only — gameplay reads the Blade Marker3D
# and Skater.blade_length (heel + contact at mid-blade), never this mesh, so the
# builder must keep the toe at exactly `length` from the heel and otherwise owes
# the contact math nothing.
#
# Frame: HEEL-ORIGIN blade-local space. The heel (where the shaft meets the
# blade — the Blade Marker3D position) is at the origin; the toe tip is at
# z = −length (−Z is the marker's look_at forward). +Y is up, X is lateral.
# Building heel-origin (instead of a centered box) lets the cosmetic tilt in
# Skater._apply_blade_tilt pivot about the heel, so the shaft→blade junction
# stays pinned when the blade pitches with the shaft.
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
# Params defaults are senior-blade measurements (metres) with the thickness run
# a few mm chunky to match the proxy-art body: 30 cm heel→toe, 6 cm tall at the
# heel tapering to ~5 cm at the toe, ~2 cm of bow, a 2.8 cm toe-corner radius,
# 3 mm of toe kick. A future gear system varies a player's stick by handing
# this builder different Params (curve depth/power = the pattern; toe_round_m =
# square vs round toe) — that's the whole seam.


class Params:
	var length: float = 0.30           # heel→toe, matches Skater.blade_length
	var height: float = 0.06           # blade face height at the heel
	var height_toe_frac: float = 0.86  # …tapering to this fraction at the toe
	var thickness_heel: float = 0.026  # cross-section thickness at the heel
	var thickness_toe: float = 0.016   # …tapering to this at the toe
	var curve_depth: float = 0.022     # centerline bow at the toe
	# Bow profile exponent — the pattern's character. The bow is
	# curve_depth·u^curve_power, so curvature eases in from zero at the heel
	# (no kink where the bow starts) and keeps opening to the toe. Lower puts
	# the bend nearer the heel (a heel curve), higher holds the blade straight
	# and turns late (a toe curve). 3 is a mid pattern.
	var curve_power: float = 3.0
	var toe_round_m: float = 0.028     # top-corner radius closing the toe
	# Bottom edge: dead flat from the heel through the contact zone, then the
	# toe lifts off the ice. A blade rockered along its whole length reads as a
	# rocking chair; real ones sit flat and kick at the toe.
	var toe_kick_m: float = 0.003
	var toe_kick_start_frac: float = 0.66
	var curve_sign: float = 1.0        # +1 lefty, −1 righty (see doc block)
	var inflate: float = 0.0           # grow the cross-section (tape band)
	# How far the cross-section may grow BELOW the sole plane. Tape bands cap
	# this near zero so the wrap hugs the bottom edge instead of hanging the
	# whole inflate below the blade (the blade would ride on a tape shelf).
	var sole_inflate_cap: float = INF
	var u_start: float = 0.0           # span start, fraction heel→toe
	var u_end: float = 1.0             # span end, fraction heel→toe
	var segments: int = 16
	# Hosel: the tapered throat that carries the heel cross-section up the
	# shaft line. 0 (the tape-band default) keeps a flat heel cap instead.
	# The angle is the stick's lie (Skater.blade_lie_deg): the shaft-follow
	# tilt keeps the blade rigidly at that angle to the shaft, so in
	# blade-local space the shaft ALWAYS ascends from the heel at the lie —
	# fixed hosel geometry stays glued to the rendered shaft in every pose
	# (only the clamped extremes of the follow pitch open a small seam, and
	# the tip is buried inside the shaft box).
	var hosel_length: float = 0.0      # along the shaft line from the heel
	var hosel_angle_deg: float = 42.0  # lie: shaft↔ice angle at flat blade


# Stations spent on the toe-corner arc, placed by sweep angle rather than by
# depth so the facets come out even. Four is enough to read as round at the
# game camera and in replays without pretending to be a smooth surface — the
# flat shading below wants facets anyway.
const _TOE_ARC_SEGMENTS: int = 4

# The toe rounds in plan view too (over a radius of the toe half-thickness),
# floored here so the tip closes on a slim cap instead of a degenerate edge
# whose normals are undefined.
const _TOE_TIP_WIDTH_FRAC: float = 0.4

# Hosel tip half height: just inside the 0.05 shaft BoxMesh dimension so the
# taper's end cap hides within the shaft rather than poking through it. The
# throat keeps the blade's own heel half-WIDTH the whole way up — widening it
# toward the shaft's wider box would flare the throat outward, which reads as a
# lump; staying narrow simply buries it inside the shaft.
const _HOSEL_TIP_HALF_H: float = 0.023
const _HOSEL_SEGMENTS: int = 5


# Station u values, heel→toe. Uniform across the body, then the toe-corner arc
# gets its own stations (a span that stops short of the corner — a heelward
# tape wrap — never reaches them). A span living entirely inside the corner
# arc collapses the body to its single start station.
static func _stations(p: Params) -> PackedFloat32Array:
	var n: int = maxi(p.segments, 2)
	var us := PackedFloat32Array()
	var corner_u: float = 1.0 - clampf(p.toe_round_m / maxf(p.length, 0.001), 0.0, 0.5)
	var body_end: float = minf(p.u_end, corner_u)
	if body_end > p.u_start + 0.0001:
		for i in n + 1:
			us.append(lerpf(p.u_start, body_end, float(i) / float(n)))
	else:
		us.append(p.u_start)
	for k in range(1, _TOE_ARC_SEGMENTS + 1):
		var phi: float = (PI * 0.5) * float(k) / float(_TOE_ARC_SEGMENTS)
		var u: float = 1.0 - p.toe_round_m * (1.0 - sin(phi)) / maxf(p.length, 0.001)
		if u > us[us.size() - 1] and u <= p.u_end:
			us.append(u)
	return us


static func build(p: Params) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Flat shading: without this, generate_normals() averages normals across
	# every shared corner position (default smooth group), blurring the top /
	# face / cap directions into meaningless diagonals. Flat faces also match
	# the game's low-poly box-and-cylinder art.
	st.set_smooth_group(-1)
	_emit_band(st, p)
	st.generate_normals()
	return st.commit()


# One capped band of blade-shaped geometry into a caller-owned SurfaceTool —
# the whole blade when the span is [0, 1], a single tape wrap otherwise.
static func _emit_band(st: SurfaceTool, p: Params) -> void:
	var us: PackedFloat32Array = _stations(p)
	var n: int = us.size() - 1
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
	var toe_half_th: float = p.thickness_toe * 0.5

	for i in n + 1:
		var u: float = us[i]
		var z: float = -u * p.length
		var uc: float = clampf(u, 0.0, 1.0)
		var d_toe: float = (1.0 - uc) * p.length  # distance back from the tip
		# Centerline bow, and the plan-view tangent it implies. Cross-sections
		# stay perpendicular to the bowed centerline so the toe doesn't shear.
		var bend: float = p.curve_sign * p.curve_depth * pow(uc, p.curve_power)
		var dbend_du: float = p.curve_sign * p.curve_depth * p.curve_power \
				* pow(uc, maxf(p.curve_power - 1.0, 0.0))
		var tangent: Vector2 = Vector2(dbend_du, -p.length).normalized()  # (x, z)
		var lateral: Vector2 = Vector2(-tangent.y, tangent.x)             # +X-ish
		var half_th: float = lerpf(p.thickness_heel, p.thickness_toe, uc) * 0.5 + p.inflate
		if d_toe < toe_half_th and toe_half_th > 0.0:
			var xp: float = (toe_half_th - d_toe) / toe_half_th
			half_th *= maxf(sqrt(maxf(1.0 - xp * xp, 0.0)), _TOE_TIP_WIDTH_FRAC)
		# Vertical profile: flat bottom edge with a toe kick, a linear height
		# taper heel→toe, and the top edge falling away on the toe-corner arc.
		# The bottom edge only carries inflate down to the sole cap.
		var half_h: float = p.height * 0.5 + p.inflate
		var kick_t: float = clampf(
				(uc - p.toe_kick_start_frac) / maxf(1.0 - p.toe_kick_start_frac, 0.001), 0.0, 1.0)
		var bottom_y: float = -(p.height * 0.5 + minf(p.inflate, p.sole_inflate_cap)) \
				+ p.toe_kick_m * kick_t * kick_t
		var top_y: float = bottom_y + (half_h - bottom_y) * lerpf(1.0, p.height_toe_frac, uc)
		if d_toe < p.toe_round_m and p.toe_round_m > 0.0:
			var x: float = p.toe_round_m - d_toe
			top_y -= p.toe_round_m - sqrt(maxf(p.toe_round_m * p.toe_round_m - x * x, 0.0))
			top_y = maxf(top_y, bottom_y + 0.002)
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

	for i in n:
		_quad(st, bt[i], bt[i + 1], ft[i + 1], ft[i])  # top (+Y)
		_quad(st, fb[i], fb[i + 1], bb[i + 1], bb[i])  # bottom (−Y)
		_quad(st, fb[i], ft[i], ft[i + 1], fb[i + 1])  # front face (+lateral)
		_quad(st, bb[i], bb[i + 1], bt[i + 1], bt[i])  # back face (−lateral)
	if p.hosel_length > 0.0:
		_add_hosel(st, p, fb[0], ft[0], bt[0], bb[0])
	else:
		_quad(st, fb[0], bb[0], bt[0], ft[0])          # heel cap (+Z)
	_quad(st, bb[n], fb[n], ft[n], bt[n])              # toe cap (−Z)


# ── Tape ──────────────────────────────────────────────────────────────────────
# Real cloth-tape proportions: ~2.4 cm-wide wraps laid heel→toe, each
# overlapping the last by about half. Rendered as alternating snug/proud bands
# so flat shading draws the wrap ridges; the proud radius (1.6 mm) is the
# tape's whole projection off the blade face, and the sole cap keeps the
# bottom edge within a taped-blade's real skim of the ice instead of a shelf
# the blade rides on.
const TAPE_WRAP_WIDTH_M: float = 0.024
const _TAPE_WRAP_STEP_FRAC: float = 0.6    # advance per wrap, in wrap widths
const _TAPE_INFLATE_SNUG_M: float = 0.0010
const _TAPE_INFLATE_PROUD_M: float = 0.0016
const _TAPE_SOLE_CAP_M: float = 0.0006
const _TAPE_SEGMENTS: int = 2


# The wrapped tape band over `span` (heel→toe u range, e.g.
# StickTapeConfig.span_range()). `p` carries the blade geometry the wraps
# follow — its inflate/u fields are overwritten per wrap. Returns null for a
# degenerate span so callers can clear the tape node.
static func build_tape(p: Params, span: Vector2) -> ArrayMesh:
	var span_len: float = span.y - span.x
	if span_len <= 0.001:
		return null
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)  # flat shading — see build()
	var width_u: float = TAPE_WRAP_WIDTH_M / maxf(p.length, 0.001)
	var count: int = maxi(1, int(ceilf((span_len - width_u) / (width_u * _TAPE_WRAP_STEP_FRAC))) + 1)
	# Even re-spacing so the last wrap ends exactly at span.y.
	var step: float = (span_len - width_u) / float(count - 1) if count > 1 else 0.0
	p.segments = _TAPE_SEGMENTS
	p.sole_inflate_cap = _TAPE_SOLE_CAP_M
	p.hosel_length = 0.0
	for i in count:
		p.u_start = span.x + step * float(i)
		p.u_end = minf(p.u_start + width_u, span.y)
		p.inflate = _TAPE_INFLATE_SNUG_M if i % 2 == 0 else _TAPE_INFLATE_PROUD_M
		_emit_band(st, p)
	st.generate_normals()
	return st.commit()


# Extrudes the hosel from the blade's heel ring up the shaft line. Stations
# march from the heel cross-section (the exact ring the blade strips end on, so
# the seam is welded) along axis (0, sin lie, cos lie) — up and BACKWARD, +Z
# being heel-ward — while the section eases into a rectangle tilted
# perpendicular to the shaft. The smoothstepped height blend is what draws the
# throat fillet: the blade's tall top edge sweeps up into the shaft line
# instead of stepping.
static func _add_hosel(st: SurfaceTool, p: Params,
		heel_fb: Vector3, heel_ft: Vector3, heel_bt: Vector3, heel_bb: Vector3) -> void:
	var lie: float = deg_to_rad(p.hosel_angle_deg)
	var axis := Vector3(0.0, sin(lie), cos(lie))
	var tip_up := Vector3(0.0, cos(lie), -sin(lie))  # perpendicular "up" at the tip
	var base_center: Vector3 = (heel_ft + heel_fb + heel_bt + heel_bb) * 0.25
	var half_w: float = absf(heel_ft.x - heel_bt.x) * 0.5
	var base_half_h: float = absf(heel_ft.y - heel_fb.y) * 0.5
	var m: int = _HOSEL_SEGMENTS
	var fb: PackedVector3Array = PackedVector3Array()
	var ft: PackedVector3Array = PackedVector3Array()
	var bt: PackedVector3Array = PackedVector3Array()
	var bb: PackedVector3Array = PackedVector3Array()
	fb.resize(m + 1)
	ft.resize(m + 1)
	bt.resize(m + 1)
	bb.resize(m + 1)
	fb[0] = heel_fb
	ft[0] = heel_ft
	bt[0] = heel_bt
	bb[0] = heel_bb
	for j in range(1, m + 1):
		var t: float = float(j) / float(m)
		var ease_t: float = t * t * (3.0 - 2.0 * t)
		var center: Vector3 = base_center + axis * (p.hosel_length * t)
		var section_h: float = lerpf(base_half_h, _HOSEL_TIP_HALF_H, ease_t)
		var up_dir: Vector3 = (Vector3.UP * (1.0 - t) + tip_up * t).normalized()
		var side := Vector3(half_w, 0.0, 0.0)
		fb[j] = center + side - up_dir * section_h
		ft[j] = center + side + up_dir * section_h
		bt[j] = center - side + up_dir * section_h
		bb[j] = center - side - up_dir * section_h
	# Stations advance heel-ward (+Z-ish) — the reverse longitudinal direction
	# of the blade strips, so each quad order mirrors its blade counterpart to
	# keep the winding outward.
	for j in m:
		_quad(st, ft[j], ft[j + 1], bt[j + 1], bt[j])  # top
		_quad(st, bb[j], bb[j + 1], fb[j + 1], fb[j])  # bottom
		_quad(st, fb[j], fb[j + 1], ft[j + 1], ft[j])  # front face (+X)
		_quad(st, bb[j], bt[j], bt[j + 1], bb[j + 1])  # back face (−X)
	_quad(st, ft[m], fb[m], bb[m], bt[m])              # tip cap (+axis, in-shaft)


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
