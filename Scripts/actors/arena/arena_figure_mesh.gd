class_name ArenaFigureMesh

# The human figure this arena is populated with — its geometry, its
# anthropometry, and the arithmetic that stands one up.
#
# One file because the crowd and the rinkside staff are the same population in
# two postures, and the bridge between them (`_SITTING_HEIGHT_FRACTION`) only
# works if both read it from the same place. `ArenaCrowd` takes the seated form,
# `ArenaRinkside` takes the standing one; neither depends on the other.

# Spectator body dimensions — stacked boxes matching the skater art style.
const BODY_SIZE: Vector3 = Vector3(0.28, 0.45, 0.28)
const HEAD_SIZE: Vector3 = Vector3(0.22, 0.22, 0.22)
# Tiny lift to keep the body bottom face off the tread without a visible gap.
# Without it the two co-planar surfaces z-fight; without keeping the bottom
# face at all, back-row spectators look hollow when the camera ends up below
# their row (upper-bowl rows reach ~6 m, well above typical camera height).
const BODY_Y_LIFT: float = 0.002
# Neck gap between the body box's top face and the head box's bottom.
const NECK_GAP: float = 0.02

# ── Stature ──────────────────────────────────────────────────────────────────
# One unscaled figure stands 0.692 m from the tread to the crown of its head.
# That is not a person: these spectators sit with their base ON the tread rather
# than on a raised pan, so their whole height IS sitting height, and a real adult
# sitting height runs about 0.79 m to 0.97 m.
#
# Every stature below is divided by this to get a scale factor, so the figures
# are sized by anthropometry in one place instead of by eye in several.
const FIGURE_HEIGHT: float = BODY_Y_LIFT + BODY_SIZE.y + NECK_GAP + HEAD_SIZE.y
# Roughly 5th-percentile female to 95th-percentile male. Rolled per spectator, so
# a row is a mix of statures rather than a line of identical boxes — which reads
# as a crowd of people at a glance, where a uniform one reads as a texture.
const SEATED_STATURE_MIN: float = 0.80
const SEATED_STATURE_MAX: float = 0.96
const CROWD_SCALE_MAX: float = SEATED_STATURE_MAX / FIGURE_HEIGHT
# The rinkside staff are the same population on their feet — the same percentiles
# read off the standing column of the same tables.
const STANDING_STATURE_MIN: float = 1.52
const STANDING_STATURE_MAX: float = 1.88
# Sitting height is about 52% of stature in adults, and that ratio is the entire
# bridge between the two populations. Standing widens nobody — it unfolds legs the
# seated figure has no geometry for — so a staffer is sized ACROSS by the seated
# scale of a person their height (`stature * this / FIGURE_HEIGHT`) and lifted by
# the remaining 48%, which is their hip height. Scaling the whole figure uniformly
# to standing stature instead is what makes a coach read as a giant beside the
# crowd: at 1.75 m the body box comes out 0.71 m across under a half-metre head,
# both about double a spectator's, because a box that is a seated torso ends up
# standing in for torso AND legs.
const SITTING_HEIGHT_FRACTION: float = 0.52

# Skin tones + hat colors for the head box. Independent of body color (no team
# correlation) so the bowl reads as a sea of people, not a wall of identical
# avatars — and shared with the rinkside staff, who are the same population.
const HEAD_PALETTE: Array[Color] = [
	Color(0.94, 0.82, 0.70),  # light skin
	Color(0.85, 0.69, 0.55),  # medium-light skin
	Color(0.72, 0.55, 0.42),  # medium skin
	Color(0.55, 0.40, 0.30),  # tan
	Color(0.40, 0.28, 0.22),  # dark skin
	Color(0.12, 0.10, 0.10),  # black hair / dark cap
	Color(0.32, 0.22, 0.16),  # brown hair
	Color(0.78, 0.74, 0.68),  # grey hair / pale cap
]


# Body box, origin at the figure's base. Lifted 2 mm off the tread so the bottom
# face doesn't z-fight — the bottom is visible from any camera below the row
# (common for back-row spectators in the upper bowl).
#
# `surface_material` is embedded in the returned mesh. The crowd passes its
# animated shader; a caller that sets a material_override on the instance (the
# staff do) passes nothing, since the override would replace it anyway.
static func body_mesh(surface_material: Material = null) -> ArrayMesh:
	return _box_mesh(Vector3(0.0, BODY_Y_LIFT + BODY_SIZE.y * 0.5, 0.0),
			BODY_SIZE, surface_material)


# Head box, positioned above the body so it lines up when applied with the same
# transform as the body. Lifted with the body.
static func head_mesh(surface_material: Material = null) -> ArrayMesh:
	return _box_mesh(Vector3(0.0, head_center_y(), 0.0), HEAD_SIZE, surface_material)


static func head_center_y() -> float:
	return BODY_Y_LIFT + BODY_SIZE.y + NECK_GAP + HEAD_SIZE.y * 0.5


static func _box_mesh(center: Vector3, size: Vector3,
		surface_material: Material) -> ArrayMesh:
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PrimitiveType.PRIMITIVE_TRIANGLES)
	ArenaMeshEmit.box(st, center, size)
	st.generate_normals()
	if surface_material != null:
		st.set_material(surface_material)
	return st.commit()


# Uniform scale for a seated figure of `stature`. The head rides the body on one
# transform, so heads vary a little with stature — not how people are built, but
# invisible at this level of stylization.
static func seated_scale(stature: float) -> float:
	return stature / FIGURE_HEIGHT


# What the crowd's scale would be for a spectator of this standing stature.
static func girth_scale(stature: float) -> float:
	return stature * SITTING_HEIGHT_FRACTION / FIGURE_HEIGHT


# Everything standing adds over sitting: the hips a seated figure folds away.
static func hip_height(stature: float) -> float:
	return stature * (1.0 - SITTING_HEIGHT_FRACTION)


# The body box is the only part of a figure that changes with posture: standing,
# it stands in for legs as well as torso, so it is stretched in Y by `lift` until
# its top lands at the neck. Across, it stays at `girth` either way — shoulders
# are shoulders, sitting or standing — and a seated figure (lift 0) comes out as
# exactly the spectator this geometry was drawn for.
static func body_transform(post: Vector3, yaw: float, girth: float,
		lift: float) -> Transform3D:
	var y_scale: float = girth + lift / (BODY_Y_LIFT + BODY_SIZE.y)
	return Transform3D(
			Basis(Vector3.UP, yaw).scaled(Vector3(girth, y_scale, girth)), post)


# The head is that same figure's head untouched, carried up by whatever the body
# box grew — so the crown lands at full stature and the neck gap survives.
static func head_transform(post: Vector3, yaw: float, girth: float,
		lift: float) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3.ONE * girth),
			post + Vector3.UP * lift)
