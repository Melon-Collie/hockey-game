class_name ArenaRinkside
extends RefCounted

# The furniture at ice level and the people who work at it: the two player
# benches on +X, the penalty boxes and the off-ice officials' table on −X, and
# the nine staff posted at them.
#
# All of it is empty furniture as far as the game is concerned — 3v3 fields no
# reserves and no penalties are called — so it earns its place by breaking the
# crowd wall where a real rink breaks it, and by putting something behind the
# glass for the boards' gates to open onto. `ArenaRinksideLayout` holds the spans
# it is built to, because the terraces and the crowd have to be cut away from
# behind it and neither of those should have to know about this file.

# Staff: the people the rinkside furniture was built for. Coaches stand behind
# each bench; the timekeeping crew and the penalty-box attendants sit at theirs,
# which is how a real rink works — the bench is the only post nobody works from a
# chair. They are the crowd's own body and head boxes, standing ones stood up per
# the stature block, but on a plain material rather than the crowd shader,
# because a coach does not do the wave.
const _STAFF_SEED: int = 5150

var _spec: ArenaBowlSpec
var _rake: ArenaBowlRake


func _init(spec: ArenaBowlSpec, rake: ArenaBowlRake) -> void:
	_spec = spec
	_rake = rake


# ── Player benches ───────────────────────────────────────────────────────────

# One solid team-colored bench block + a charcoal backrest per team, sitting
# on the first-row tread where the crowd was cleared. Rebuilt with the bowl,
# so bench colors re-tint when team_colors_ready re-runs setup().
func build_benches(root: Node3D) -> void:
	var x_inner: float = _spec.rink_width / 2.0 + _spec.base_outward_offset
	var tread_y: float = _spec.stands_base_y
	for side: float in [-1.0, 1.0]:
		var center_z: float = side * ArenaRinksideLayout.BENCH_CENTER_Z
		# Home (team 0) defends +Z, so its bench sits on the +Z half.
		var team_color: Color = _spec.home_color if side > 0.0 else _spec.away_color
		_add_box(root, "BenchSeatHome" if side > 0.0 else "BenchSeatAway",
				Vector3(0.42, ArenaRinksideLayout.BENCH_SEAT_HEIGHT,
						ArenaRinksideLayout.BENCH_HALF_LEN * 2.0),
				Vector3(x_inner + ArenaRinksideLayout.BENCH_SEAT_X_OFFSET,
						tread_y + ArenaRinksideLayout.BENCH_SEAT_HEIGHT * 0.5, center_z),
				team_color.darkened(0.25), 0.8)
		_add_box(root, "BenchBackHome" if side > 0.0 else "BenchBackAway",
				Vector3(0.06, 0.5, ArenaRinksideLayout.BENCH_HALF_LEN * 2.0),
				Vector3(x_inner + 0.57, tread_y + 0.55, center_z),
				Color(0.20, 0.20, 0.22), 0.9)


# Seat-surface center of a team's bench (top face of the seat block), in
# ArenaStands-local space. Home (team 0) sits on the +Z half, matching
# build_benches. The lobby backdrop uses this to seat roster dummies.
func bench_seat_center(team_id: int) -> Vector3:
	var side: float = 1.0 if team_id == 0 else -1.0
	return Vector3(
			_spec.rink_width / 2.0 + _spec.base_outward_offset
					+ ArenaRinksideLayout.BENCH_SEAT_X_OFFSET,
			_spec.stands_base_y + ArenaRinksideLayout.BENCH_SEAT_HEIGHT,
			side * ArenaRinksideLayout.BENCH_CENTER_Z)


# ── Penalty boxes and the officials' table ───────────────────────────────────

# The −X answer to the benches: a box per team either side of centre ice with
# the off-ice officials' table in the gap. Same construction as build_benches
# and, like it, empty furniture — it earns its place by breaking up the only
# stretch of this bowl that ran crowd from corner to corner.
func build_penalty_boxes(root: Node3D) -> void:
	var x_inner: float = -(_spec.rink_width / 2.0 + _spec.base_outward_offset)
	var tread_y: float = _spec.stands_base_y
	var seat_h: float = ArenaRinksideLayout.BENCH_SEAT_HEIGHT
	var half_len: float = ArenaRinksideLayout.PENALTY_BOX_HALF_LEN

	for side: float in [-1.0, 1.0]:
		var center_z: float = side * ArenaRinksideLayout.PENALTY_BOX_CENTER_Z
		# Matches the benches' convention: the +Z-half team is home.
		var team_color: Color = _spec.home_color if side > 0.0 else _spec.away_color
		_add_box(root, "PenaltySeatHome" if side > 0.0 else "PenaltySeatAway",
				Vector3(0.42, seat_h, half_len * 2.0),
				Vector3(x_inner - ArenaRinksideLayout.BENCH_SEAT_X_OFFSET,
						tread_y + seat_h * 0.5, center_z),
				team_color.darkened(0.35), 0.8)
		_add_box(root, "PenaltyBackHome" if side > 0.0 else "PenaltyBackAway",
				Vector3(0.06, 0.5, half_len * 2.0),
				Vector3(x_inner - 0.57, tread_y + 0.55, center_z),
				Color(0.20, 0.20, 0.22), 0.9)
		# Divider between this box and the officials, so the three read as three
		# compartments rather than one long shelf.
		_add_box(root, "PenaltyDividerHome" if side > 0.0 else "PenaltyDividerAway",
				Vector3(0.72, 1.05, 0.07),
				Vector3(x_inner - 0.36, tread_y + 0.525,
						side * ArenaRinksideLayout.OFFICIALS_HALF_LEN),
				Color(0.24, 0.25, 0.28), 0.9)

	# Timekeeper's table: desk height, so the crew seated behind it clears the
	# top from the chest up rather than peering over it.
	_add_box(root, "OfficialsTable",
			Vector3(0.60, ArenaRinksideLayout.OFFICIALS_HEIGHT,
					ArenaRinksideLayout.OFFICIALS_HALF_LEN * 2.0),
			Vector3(x_inner - 0.42,
					tread_y + ArenaRinksideLayout.OFFICIALS_HEIGHT * 0.5, 0.0),
			Color(0.17, 0.18, 0.21), 0.85)
	# What the crew sit on. Without it they would be standing at the table (the
	# well floor puts a seated figure's head level with the counter), and every
	# other seated staffer here sits on real furniture.
	_add_box(root, "OfficialsSeat",
			Vector3(ArenaRinksideLayout.OFFICIALS_SEAT_DEPTH, seat_h,
					ArenaRinksideLayout.OFFICIALS_HALF_LEN * 2.0),
			Vector3(x_inner - ArenaRinksideLayout.STAFF_BEHIND_TABLE,
					tread_y + seat_h * 0.5, 0.0),
			Color(0.22, 0.23, 0.26), 0.85)


func _add_box(root: Node3D, node_name: String, size: Vector3, pos: Vector3,
		color: Color, roughness: float) -> void:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	var mesh := BoxMesh.new()
	mesh.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	mesh.material = mat
	mi.mesh = mesh
	mi.position = pos
	root.add_child(mi)


# ── Staff ────────────────────────────────────────────────────────────────────

# Nine figures at the rinkside furniture: two coaches behind each bench, an
# attendant at each penalty box door, and three of the off-ice crew at the
# table. A table with no timekeeper reads emptier than no table.
#
# One MultiMesh pair for the lot, same body and head meshes the crowd uses, but
# with a plain material: the crowd shader sways and hops off per-instance custom
# data, and staff standing at their posts should do neither.
func build_staff(root: Node3D) -> void:
	var posts: Array[Vector3] = []
	var jackets: Array[Color] = []
	var standing: Array[bool] = []
	staff_postings(posts, jackets, standing)

	var rng := RandomNumberGenerator.new()
	rng.seed = _STAFF_SEED
	# Body and head take separate transforms, where the crowd shares one: a
	# standing figure stretches in Y and its head does not, so the two cannot
	# ride the same basis.
	var body_mm: MultiMesh = _staff_multimesh(ArenaFigureMesh.body_mesh(), posts.size())
	var head_mm: MultiMesh = _staff_multimesh(ArenaFigureMesh.head_mesh(), posts.size())
	var bounds := AABB(posts[0], Vector3.ZERO)
	for i: int in posts.size():
		var stature: float = rng.randf_range(
				ArenaFigureMesh.STANDING_STATURE_MIN,
				ArenaFigureMesh.STANDING_STATURE_MAX)
		var girth: float = ArenaFigureMesh.girth_scale(stature)
		# Sitting IS the unscaled figure, so a seated staffer lifts by nothing and
		# both transforms collapse to the spectator's.
		var lift: float = ArenaFigureMesh.hip_height(stature) if standing[i] else 0.0
		var yaw: float = atan2(posts[i].x, posts[i].z)
		body_mm.set_instance_transform(i,
				ArenaFigureMesh.body_transform(posts[i], yaw, girth, lift))
		head_mm.set_instance_transform(i,
				ArenaFigureMesh.head_transform(posts[i], yaw, girth, lift))
		body_mm.set_instance_color(i, jackets[i])
		head_mm.set_instance_color(i,
				ArenaFigureMesh.HEAD_PALETTE[
						rng.randi() % ArenaFigureMesh.HEAD_PALETTE.size()])
		bounds = bounds.expand(posts[i])
	var staff_aabb: AABB = grow_staff_aabb(bounds)
	body_mm.custom_aabb = staff_aabb
	head_mm.custom_aabb = staff_aabb

	for part: Array in [["StaffBodies", body_mm], ["StaffHeads", head_mm]]:
		var mmi := MultiMeshInstance3D.new()
		mmi.name = part[0]
		mmi.multimesh = part[1]
		mmi.material_override = _staff_material()
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(mmi)


# Explicit bounds for the same reason the crowd sections have them (see
# ArenaCrowd.grow_section_aabb). The seed box covers instance ORIGINS (their
# feet) only, so it has to grow by the tallest figure's own reach — sideways by a
# rotated body's half-diagonal, up by a full stature.
func grow_staff_aabb(seed_aabb: AABB) -> AABB:
	var reach: float = maxf(ArenaFigureMesh.BODY_SIZE.x, ArenaFigureMesh.BODY_SIZE.z) \
			* ArenaFigureMesh.girth_scale(ArenaFigureMesh.STANDING_STATURE_MAX)
	return AABB(seed_aabb.position - Vector3(reach, 0.1, reach),
			seed_aabb.size + Vector3(reach * 2.0,
					ArenaFigureMesh.STANDING_STATURE_MAX + 0.1, reach * 2.0))


# Who works where, filled into caller-owned arrays: a post, a jacket, and
# whether they work on their feet. Separate from the build because a MultiMesh's
# instance transforms are write-only under the headless renderer — this is the
# only seam a test can read the roster through.
func staff_postings(posts: Array[Vector3], jackets: Array[Color],
		standing: Array[bool]) -> void:
	var bench_x: float = _spec.rink_width / 2.0 + _spec.base_outward_offset
	var behind_bench: float = ArenaRinksideLayout.STAFF_BEHIND_BENCH

	# Coaches: two behind each bench, on the tread a step up from the bench
	# itself, facing the ice. Jackets are only lightly darkened from the team
	# colour — staff stand against dark furniture behind tinted glass, and
	# anything nearer to black merges with the box they are in.
	for side: float in [-1.0, 1.0]:
		var jacket: Color = (_spec.home_color if side > 0.0
				else _spec.away_color).darkened(0.3)
		for dz: float in [-1.15, 1.15]:
			var bench_z: float = side * ArenaRinksideLayout.BENCH_CENTER_Z + dz
			posts.append(Vector3(bench_x + behind_bench,
					_rake.floor_y_at(behind_bench,
							Vector2(bench_x + behind_bench, bench_z)),
					bench_z))
			jackets.append(jacket)
			standing.append(true)

	# Penalty-box attendants, sitting on the box's own bench at the door end —
	# the same seat block a penalized player uses, so they need no chair.
	for side: float in [-1.0, 1.0]:
		posts.append(Vector3(
				-(bench_x + ArenaRinksideLayout.BENCH_SEAT_X_OFFSET),
				_spec.stands_base_y + ArenaRinksideLayout.BENCH_SEAT_HEIGHT,
				side * (ArenaRinksideLayout.PENALTY_BOX_CENTER_Z
						+ ArenaRinksideLayout.PENALTY_BOX_HALF_LEN - 0.4)))
		jackets.append(Color(0.38, 0.40, 0.46))
		standing.append(false)

	# Timekeeping crew, on the bench behind the table between the boxes.
	for dz: float in [-0.72, 0.0, 0.72]:
		posts.append(Vector3(-(bench_x + ArenaRinksideLayout.STAFF_BEHIND_TABLE),
				_spec.stands_base_y + ArenaRinksideLayout.BENCH_SEAT_HEIGHT, dz))
		# The off-ice crew works in shirtsleeves; pale is also what separates them
		# from the dark counter they sit behind.
		jackets.append(Color(0.74, 0.76, 0.80))
		standing.append(false)


func _staff_multimesh(mesh: ArrayMesh, count: int) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = count
	return mm


# Lit, unlike the crowd — staff stand at ice level under the rig that lights the
# boards, close enough to the camera that flat shading would read as cardboard.
func _staff_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.85
	return mat
