class_name ArenaBowlPath
extends RefCounted

# The bowl's perimeter, in plan: where a ring at a given outward offset runs,
# and where any point in the building sits along it.
#
# All section math runs on the BASE path's arc-length parameter: every seat
# projects perpendicularly onto the boards' rounded-rect perimeter (straights →
# perpendicular foot, corners → same angle on the base corner arc), so seats
# stacked up the rake share one s value regardless of row offset. Aisles are cuts
# at fixed s — that's what makes them radial and deck-aligned.

var _spec: ArenaBowlSpec

# Angular slices the bowl's instanced furniture and people are partitioned into,
# each with its own tight AABB, so the renderer frustum-culls off-screen stands
# wholesale instead of vertex-processing every spectator every frame. 8 ≈ 45° per
# slice: tight enough that gameplay zoom keeps only a few slices in frustum, few
# enough that the extra draw calls (2 per slice) stay negligible. The crowd and
# the seats bin against the same slices deliberately, so a seat and its occupant
# are culled together. (Unrelated to the SEATING sections cut by aisles below,
# which exist for the building's stairways rather than for the renderer.)
const CULL_SECTIONS: int = 8


func _init(spec: ArenaBowlSpec) -> void:
	_spec = spec


# Bin instance transforms into CULL_SECTIONS angular slices around centre ice,
# returning each slice's source indices. Deterministic (angle bins over a
# deterministic transform list), which is what lets a paint pass walk the
# sections in build order and stay reproducible.
static func sector_bins(transforms: Array[Transform3D]) -> Array[PackedInt32Array]:
	var bins: Array[PackedInt32Array] = []
	bins.resize(CULL_SECTIONS)
	for k: int in CULL_SECTIONS:
		bins[k] = PackedInt32Array()
	for i: int in transforms.size():
		var o: Vector3 = transforms[i].origin
		var sector: int = int(floor((atan2(o.z, o.x) + PI) / TAU * CULL_SECTIONS))
		bins[clampi(sector, 0, CULL_SECTIONS - 1)].append(i)
	return bins


# Compute the (straight-X, straight-Z) sample counts, derived once from the
# base path so every ring shares the same vertex count regardless of offset.
func path_step_counts() -> Vector2i:
	var arc_step_base: float = (PI / 2.0) * _spec.corner_radius \
			/ float(_spec.corner_segments)
	var straight_x: float = _spec.rink_width - 2.0 * _spec.corner_radius
	var straight_z: float = _spec.rink_length - 2.0 * _spec.corner_radius
	var nx: int = max(1, int(round(straight_x / arc_step_base)))
	var nz: int = max(1, int(round(straight_z / arc_step_base)))
	return Vector2i(nx, nz)


# Sample a rounded-rectangle path offset outward from the board outer face
# by `off` meters, using fixed step counts so rings stay vertex-aligned.
# Returns XZ points in CCW order (viewed from above with +X right, +Z up).
func sample_offset_path(off: float, n_straight_x: int = -1,
		n_straight_z: int = -1) -> PackedVector2Array:
	var half_w: float = _spec.rink_width / 2.0
	var half_l: float = _spec.rink_length / 2.0
	var r: float = _spec.corner_radius
	var segments: int = _spec.corner_segments
	var r_off: float = r + off
	# Corner arc centers (same as rink corner centers).
	var c_br: Vector2 = Vector2( half_w - r, -half_l + r)
	var c_tr: Vector2 = Vector2( half_w - r,  half_l - r)
	var c_tl: Vector2 = Vector2(-half_w + r,  half_l - r)
	var c_bl: Vector2 = Vector2(-half_w + r, -half_l + r)
	if n_straight_x < 0 or n_straight_z < 0:
		var counts: Vector2i = path_step_counts()
		n_straight_x = counts.x
		n_straight_z = counts.y

	var pts: PackedVector2Array = PackedVector2Array()
	# Order, CCW from above: bottom edge → bottom-left corner → left edge →
	# top-left corner → top edge → top-right corner → right edge → bottom-right corner.
	_append_straight(pts,
			Vector2( half_w - r, -half_l - off),
			Vector2(-half_w + r, -half_l - off), n_straight_x)
	_append_arc(pts, c_bl, r_off, -PI / 2.0, -PI, segments)
	_append_straight(pts,
			Vector2(-half_w - off, -half_l + r),
			Vector2(-half_w - off,  half_l - r), n_straight_z)
	_append_arc(pts, c_tl, r_off, PI, PI / 2.0, segments)
	_append_straight(pts,
			Vector2(-half_w + r, half_l + off),
			Vector2( half_w - r, half_l + off), n_straight_x)
	_append_arc(pts, c_tr, r_off, PI / 2.0, 0.0, segments)
	_append_straight(pts,
			Vector2(half_w + off,  half_l - r),
			Vector2(half_w + off, -half_l + r), n_straight_z)
	_append_arc(pts, c_br, r_off, 0.0, -PI / 2.0, segments)
	return pts


# Append straight segment samples [start, ..., end) — endpoint omitted so
# the next segment's start point is not duplicated.
func _append_straight(pts: PackedVector2Array, start: Vector2, end: Vector2,
		steps: int) -> void:
	for i: int in steps:
		var t: float = float(i) / float(steps)
		pts.append(start.lerp(end, t))


# Append arc samples sweeping from a0 to a1 across `segments` steps.
# Endpoint omitted (matches _append_straight convention).
func _append_arc(pts: PackedVector2Array, center: Vector2, radius: float,
		a0: float, a1: float, segments: int) -> void:
	for i: int in segments:
		var t: float = float(i) / float(segments)
		var ang: float = lerp(a0, a1, t)
		pts.append(center + Vector2(cos(ang), sin(ang)) * radius)


# ── Arc-length parameter ─────────────────────────────────────────────────────

# Arc length of the base (off = 0) path, in the sampler's traversal order.
func base_path_length() -> float:
	return 2.0 * (_spec.rink_width - 2.0 * _spec.corner_radius) \
			+ 2.0 * (_spec.rink_length - 2.0 * _spec.corner_radius) \
			+ TAU * _spec.corner_radius


# Arc position s ∈ [0, base_path_length()) of a seat's perpendicular projection
# onto the base path. p is (x, z), same packing as the samplers. Segment order
# and directions mirror sample_offset_path exactly.
func base_path_s(p: Vector2) -> float:
	var cx_max: float = _spec.rink_width / 2.0 - _spec.corner_radius
	var cz_max: float = _spec.rink_length / 2.0 - _spec.corner_radius
	var len_x: float = 2.0 * cx_max
	var len_z: float = 2.0 * cz_max
	var len_c: float = (PI / 2.0) * _spec.corner_radius
	var x: float = p.x
	var z: float = p.y
	if absf(x) <= cx_max:
		# Short-end straights (behind the goals).
		if z < 0.0:
			return cx_max - x  # bottom edge: +x → −x
		return len_x + 2.0 * len_c + len_z + (x + cx_max)  # top edge: −x → +x
	if absf(z) <= cz_max:
		# Long-side straights.
		if x < 0.0:
			return len_x + len_c + (z + cz_max)  # left edge: −z → +z
		return 2.0 * len_x + 3.0 * len_c + len_z + (cz_max - z)  # right: +z → −z
	# Corner fans: angular progress along the quarter arc, in sweep order.
	var ang: float = atan2(z - signf(z) * cz_max, x - signf(x) * cx_max)
	var progress: float
	var s0: float
	if x < 0.0 and z < 0.0:
		progress = (-PI / 2.0 - ang) / (PI / 2.0)  # −π/2 → −π
		s0 = len_x
	elif x < 0.0:
		progress = (PI - ang) / (PI / 2.0)  # π → π/2
		s0 = len_x + len_c + len_z
	elif z > 0.0:
		progress = (PI / 2.0 - ang) / (PI / 2.0)  # π/2 → 0
		s0 = 2.0 * len_x + 2.0 * len_c + len_z
	else:
		progress = -ang / (PI / 2.0)  # 0 → −π/2
		s0 = 2.0 * len_x + 3.0 * len_c + 2.0 * len_z
	return s0 + clampf(progress, 0.0, 1.0) * len_c


# ── Seating sections ─────────────────────────────────────────────────────────

# Whether an arc position falls inside a cleared aisle corridor. Aisles sit
# at the section boundaries k · (perimeter / num_aisles).
func in_aisle(s: float) -> bool:
	if _spec.num_aisles <= 0 or _spec.aisle_width <= 0.0:
		return false
	var seg: float = base_path_length() / float(_spec.num_aisles)
	var into: float = fposmod(s, seg)
	return minf(into, seg - into) < _spec.aisle_width * 0.5


func section_id(s: float) -> int:
	if _spec.num_aisles <= 0:
		return 0
	var seg: float = base_path_length() / float(_spec.num_aisles)
	return clampi(int(s / seg), 0, _spec.num_aisles - 1)


# The visiting-fan block: the upper-deck section containing the top-left
# corner's midpoint — an upper corner on the −X side, opposite the benches,
# where real arenas park the away support.
func away_section_id() -> int:
	if _spec.num_aisles <= 0:
		return -1
	var len_x: float = _spec.rink_width - 2.0 * _spec.corner_radius
	var len_z: float = _spec.rink_length - 2.0 * _spec.corner_radius
	var len_c: float = (PI / 2.0) * _spec.corner_radius
	return section_id(len_x + len_c + len_z + len_c * 0.5)


# ── Band stations ────────────────────────────────────────────────────────────

# Turn one of this bowl's sampled paths into the {pos, inward} stations
# BoardAdBandBuilder wants.
#
# The traversal is REVERSED on the way in, because this file and HockeyRink wind
# their perimeters oppositely: sample_offset_path runs bottom edge → left → top
# → right, while HockeyRink's stations run right → top → left → bottom. Arc
# length is the band's U axis, so feeding this bowl's own order would run U the
# other way round the building and hang every wordmark mirrored.
#
# Reversing flips the tangent, so inward — which must still point at the rink —
# is the +90° rotation here where the un-reversed path wanted −90°. Tangents
# come from a central difference so a station on a corner blends its two
# neighbours instead of inheriting one segment's normal wholesale.
func stations(offset: float) -> Array:
	var pts: PackedVector2Array = sample_offset_path(offset)
	pts.reverse()
	var out: Array = []
	var count: int = pts.size()
	for i: int in count:
		var prev: Vector2 = pts[(i - 1 + count) % count]
		var next: Vector2 = pts[(i + 1) % count]
		var tangent: Vector2 = (next - prev).normalized()
		out.append({
			"pos": pts[i],
			"inward": Vector2(-tangent.y, tangent.x),
		})
	return out


# ── Polyline helpers ─────────────────────────────────────────────────────────

# Walk the (already-CCW) sample polyline at uniform arc-length `spacing` and
# return the resampled points. Keeps spectator placement even regardless of
# the underlying corner_segments / straight-step density.
static func resample_uniform(samples: PackedVector2Array,
		spacing: float) -> PackedVector2Array:
	var out: PackedVector2Array = PackedVector2Array()
	if samples.size() < 2 or spacing <= 0.0:
		return out
	var cum: float = 0.0
	var next_t: float = spacing * 0.5  # half-step inset so the first/last don't crowd a seam
	var n: int = samples.size()
	for i: int in n:
		var a: Vector2 = samples[i]
		var b: Vector2 = samples[(i + 1) % n]
		var seg_len: float = a.distance_to(b)
		if seg_len <= 0.0:
			continue
		while next_t <= cum + seg_len:
			var t: float = (next_t - cum) / seg_len
			out.append(a.lerp(b, t))
			next_t += spacing
		cum += seg_len
	return out


# Outward (away from the rink) unit normal at a point on one of this bowl's
# sampled paths.
#
# The rotation sign is the whole content of this function, and it is the opposite
# of the one `stations` uses, because that helper reverses the loop first.
# On the path as sample_offset_path emits it, the bottom edge runs −X at
# z = −half_length, so its tangent is (−1, 0) and the rink lies at +Z: rotating
# the tangent by −90° gives (0, +1), which points at the ice. Outward is the +90°
# rotation. Getting this backwards bores every tunnel INTO the seating bowl,
# which looks like the portals are projecting out of the concourse rather than
# cut into it.
static func outward_at(wall: PackedVector2Array, index: int) -> Vector2:
	var count: int = wall.size()
	var tangent: Vector2 = (wall[(index + 1) % count]
			- wall[(index - 1 + count) % count]).normalized()
	return Vector2(-tangent.y, tangent.x)


# Yaw that squares a seat (and its occupant) to the ice at `points[i]`, where
# `points` is one resampled row as a closed loop.
#
# The heading is the ROW'S OWN inward normal, not the bearing to centre ice.
# Seats are bolted in ranks: down a straight side every seat in a row faces the
# same way — perpendicular to the boards — and the heading only swings around the
# corner arcs. Aiming each seat at the origin instead splays a straight rank into
# a fan, ~20 deg off square by the ends of the long sides.
#
# Tangent from a central difference so a seat on a corner blends its two
# neighbours instead of inheriting one segment's normal. This path winds bottom →
# left → top → right, which makes the −90 deg rotation of the tangent the one
# pointing at the rink — the opposite of `stations`, which reverses the
# traversal first (see its note). With Basis(Y, yaw) the local forward is
# (−sin yaw, −cos yaw), so facing `inward` is atan2(−inward.x, −inward.y).
static func row_facing_yaw(points: PackedVector2Array, i: int) -> float:
	var n: int = points.size()
	var tangent: Vector2 = points[(i + 1) % n] - points[(i - 1 + n) % n]
	if tangent.length_squared() < 0.000001:
		return atan2(points[i].x, points[i].y)  # degenerate row: face centre ice
	var inward := Vector2(tangent.y, -tangent.x)
	return atan2(-inward.x, -inward.y)
