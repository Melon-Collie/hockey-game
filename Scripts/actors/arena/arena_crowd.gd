class_name ArenaCrowd
extends RefCounted

# The spectators: where they sit, what they wear, and how hard they react.
#
# Split in two along the cache line `ArenaStands` keeps. `fill_layout` produces
# the color-independent half — transforms, animation rolls, section AABBs — which
# is deterministic under a fixed seed and so is built once per geometry and
# reused for the process lifetime. `paint` writes the per-instance colors, which
# depend on the team colors and so re-run whenever those move. A rebuild with
# unchanged colors reattaches without touching a single instance.

# Deterministic seed so the editor preview matches the runtime build. Shared by
# the layout roll and the paint roll: two passes over the same stream, so a
# spectator's colours belong to the same person their stature does.
const _SEED: int = 31337

const _CROWD_SHADER_PATH: String = "res://Shaders/crowd.gdshader"

# Away-fan share inside the designated visiting block. A feel constant: real
# visiting sections read as a wall of away colors with locals mixed through,
# and 0.7 sells that without looking like a printed flag.
const _AWAY_SECTION_FILL: float = 0.7

# Shared by both crowd MultiMeshes and — static — across arena instances:
# the cached body/head meshes embed this material, so it must be the same
# object for every bowl the process ever builds, or excitement writes from a
# fresh arena would land on a dead material.
static var _crowd_material: ShaderMaterial = null

# Civilian shirts/coats for the neutral fan slice.
const _NEUTRAL_BODY_PALETTE: Array[Color] = [
	Color(0.25, 0.25, 0.28),  # charcoal
	Color(0.55, 0.45, 0.35),  # khaki
	Color(0.78, 0.74, 0.70),  # cream
	Color(0.40, 0.36, 0.32),  # taupe
	Color(0.92, 0.88, 0.85),  # off-white
	Color(0.35, 0.40, 0.45),  # slate
	Color(0.62, 0.30, 0.20),  # rust
]

var _spec: ArenaBowlSpec
var _path: ArenaBowlPath
var _rake: ArenaBowlRake
# Rebuilt with the spectators (a rebuild frees all children), so guard reads
# with is_instance_valid during the free→re-add window.
var _flashbulbs: CrowdFlashbulbs = null


func _init(spec: ArenaBowlSpec, path: ArenaBowlPath, rake: ArenaBowlRake) -> void:
	_spec = spec
	_path = path
	_rake = rake


# Drop the process-lifetime crowd material. It holds a GPU RID that survives
# scene changes for perf, and a static var is freed at script-unload — AFTER the
# RenderingServer finalizes — so at exit it would destruct with a null server and
# its RID would be reported as leaked. Only call at app quit.
static func release_shared_material() -> void:
	_crowd_material = null


# Shared material — crowd.gdshader reads the per-instance MultiMesh color for
# albedo and animates sway/hop from INSTANCE_CUSTOM + the excitement uniform. One
# material across both MultiMeshes and across rebuilds, so excitement state
# persists and a single uniform write drives the whole bowl. Cull disabled like
# the terrace material: culling back faces on individual spectators leaves
# rink-facing faces invisible at some camera angles (the boxes look hollow), and
# the extra triangles are cheap on a few thousand instances of an 8-vert mesh.
static func shared_material() -> ShaderMaterial:
	if _crowd_material == null:
		_crowd_material = ShaderMaterial.new()
		_crowd_material.shader = load(_CROWD_SHADER_PATH)
		_crowd_material.set_shader_parameter("excitement", 0.0)
	return _crowd_material


# How hard the bowl is reacting, 0..1. Written by the owner's excitement cue —
# this is the sink, not the clock.
func set_excitement(v: float) -> void:
	shared_material().set_shader_parameter("excitement", v)
	if _flashbulbs != null and is_instance_valid(_flashbulbs):
		_flashbulbs.set_excitement(v)


# ── Layout ───────────────────────────────────────────────────────────────────

# Build the color-independent half of the crowd into `layout`: per-section
# MultiMesh pairs with meshes, transforms, anim data, and AABBs. Each section
# is a pair because bodies tint with the team-mix color while heads tint from
# the skin/hat palette — an extra draw call vs. a combined mesh, but it lets
# the head pick a color independent of the body without a custom shader.
# Colors stay default until the first `paint` pass.
func fill_layout(layout: Dictionary) -> void:
	var transforms: Array[Transform3D] = []
	var anim_data: Array[Color] = []
	var away_block: PackedByteArray = PackedByteArray()
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = _SEED
	for i: int in _rake.lower_row_count():
		_append_row(transforms, anim_data, away_block, rng,
				_rake.lower_row_offset(i) + _rake.seat_inset(),
				_rake.lower_row_y(i), i, false)
	# Upper deck rows. bench_row -1: the bench cutout is an ice-level concern
	# only — the deck hangs far above the benches.
	for j: int in _rake.upper_row_count():
		_append_row(transforms, anim_data, away_block, rng,
				_rake.upper_row_offset(j) + _rake.seat_inset(),
				_rake.upper_row_y(j), -1, true)

	var body_mesh: ArrayMesh = ArenaFigureMesh.body_mesh(shared_material())
	var head_mesh: ArrayMesh = ArenaFigureMesh.head_mesh(shared_material())
	var body_mms: Array[MultiMesh] = []
	var head_mms: Array[MultiMesh] = []
	var away_flags: Array[PackedByteArray] = []
	for idxs: PackedInt32Array in ArenaBowlPath.sector_bins(transforms):
		if idxs.is_empty():
			continue
		var body_mm: MultiMesh = _make_multimesh(body_mesh, idxs.size())
		var head_mm: MultiMesh = _make_multimesh(head_mesh, idxs.size())
		var slice_away: PackedByteArray = PackedByteArray()
		slice_away.resize(idxs.size())
		var seed_aabb: AABB = AABB(transforms[idxs[0]].origin, Vector3.ZERO)
		for n_i: int in idxs.size():
			var src: int = idxs[n_i]
			body_mm.set_instance_transform(n_i, transforms[src])
			body_mm.set_instance_custom_data(n_i, anim_data[src])
			head_mm.set_instance_transform(n_i, transforms[src])
			head_mm.set_instance_custom_data(n_i, anim_data[src])
			slice_away[n_i] = away_block[src]
			seed_aabb = seed_aabb.expand(transforms[src].origin)
		# Godot's auto-AABB for MultiMesh is unreliable when transforms are
		# pushed via set_instance_transform individually (vs. a single `buffer`
		# set), and especially when the source mesh AABB is offset from origin
		# (the head box is centered at y~0.58). Without an explicit AABB the
		# renderer mis-culls whole stretches of crowd from certain angles.
		var section_aabb: AABB = grow_section_aabb(seed_aabb)
		body_mm.custom_aabb = section_aabb
		head_mm.custom_aabb = section_aabb
		body_mms.append(body_mm)
		head_mms.append(head_mm)
		away_flags.append(slice_away)
	layout["body_mms"] = body_mms
	layout["head_mms"] = head_mms
	layout["away_flags"] = away_flags


func _make_multimesh(mesh: ArrayMesh, count: int) -> MultiMesh:
	var mm: MultiMesh = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = count
	return mm


# Grow a section's origin-fit AABB to cover the spectators' full standing
# bodies plus the shader animation (crowd.gdshader): up to ~0.18 m of
# celebration hop on top, ~0.1 m of sway sideways; rotated bodies can extend
# by the box diagonal in any horizontal direction.
func grow_section_aabb(seed_aabb: AABB) -> AABB:
	# Sized for the TALLEST spectator a stature roll can produce, not the mesh's
	# own dimensions — an under-sized AABB gets the whole section frustum-culled.
	var horizontal_margin: float = max(ArenaFigureMesh.BODY_SIZE.x,
			ArenaFigureMesh.BODY_SIZE.z) * ArenaFigureMesh.CROWD_SCALE_MAX * 0.71 + 0.15
	var pos: Vector3 = seed_aabb.position \
			- Vector3(horizontal_margin, 0.1, horizontal_margin)
	var end: Vector3 = seed_aabb.end + Vector3(
			horizontal_margin,
			(ArenaFigureMesh.BODY_SIZE.y + ArenaFigureMesh.HEAD_SIZE.y)
					* ArenaFigureMesh.CROWD_SCALE_MAX + 0.35,
			horizontal_margin)
	return AABB(pos, end - pos)


# One ring of spectators at `spectator_off` outward of the boards, feet at
# `y`. bench_row is the lower-bowl row index for the bench cutout, or -1 for
# rows the cutout can never apply to (the upper deck). is_upper selects the
# deck for the visiting-fan block (upper only). Appends a matching 0/1 flag
# to away_block per placed spectator.
func _append_row(transforms: Array[Transform3D], anim_data: Array[Color],
		away_block: PackedByteArray, rng: RandomNumberGenerator,
		spectator_off: float, y: float, bench_row: int, is_upper: bool) -> void:
	var away_section: int = _path.away_section_id()
	var resampled: PackedVector2Array = ArenaBowlPath.resample_uniform(
			_path.sample_offset_path(spectator_off), _spec.spectator_spacing)
	for i: int in resampled.size():
		var p: Vector2 = resampled[i]
		if bench_row >= 0 and ArenaRinksideLayout.in_bench_zone(bench_row, p):
			continue
		# Vacancy roll first (before any jitter rolls) so the occupied seats'
		# jitter stream is stable relative to the seat sequence.
		if rng.randf() > _spec.attendance:
			continue
		var arc_s: float = _path.base_path_s(p)
		if _path.in_aisle(arc_s):
			continue
		var pos: Vector3 = Vector3(p.x,
				y + rng.randf_range(-_spec.spectator_y_jitter, _spec.spectator_y_jitter),
				p.y)
		# Square to the row, like the seat under them — the jitter is what breaks
		# up the rank, not a per-fan bearing to centre ice.
		var yaw: float = ArenaBowlPath.row_facing_yaw(resampled, i) \
				+ deg_to_rad(rng.randf_range(-_spec.spectator_yaw_jitter_deg,
						_spec.spectator_yaw_jitter_deg))
		var stature: float = rng.randf_range(ArenaFigureMesh.SEATED_STATURE_MIN,
				ArenaFigureMesh.SEATED_STATURE_MAX)
		var spectator_basis: Basis = Basis(Vector3.UP, yaw).scaled(
				Vector3.ONE * ArenaFigureMesh.seated_scale(stature))
		transforms.append(Transform3D(spectator_basis, pos))
		away_block.append(1 if is_upper and _spec.num_aisles > 0
				and _path.section_id(arc_s) == away_section else 0)
		# Animation roll (crowd.gdshader INSTANCE_CUSTOM): phase de-sync,
		# sway amplitude, hop amplitude. Same data on body and head so the
		# two draw calls move as one person.
		anim_data.append(Color(
				rng.randf(),
				rng.randf_range(0.6, 1.4),
				rng.randf_range(0.2, 1.0),
				0.0))


# ── Paint ────────────────────────────────────────────────────────────────────

# Roll body/head colors for every spectator. Own rng stream (same _SEED),
# consumed across the sections in their fixed build order, so the fan-mix
# assignment is deterministic and identical across repaints of the same
# layout. Seats flagged into the visiting-fan block roll the away-heavy mix.
func paint(layout: Dictionary) -> void:
	var body_mms: Array[MultiMesh] = layout.body_mms
	var head_mms: Array[MultiMesh] = layout.head_mms
	var away_flags: Array[PackedByteArray] = layout.away_flags
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = _SEED
	for k: int in body_mms.size():
		var body_mm: MultiMesh = body_mms[k]
		var head_mm: MultiMesh = head_mms[k]
		var slice_away: PackedByteArray = away_flags[k]
		for i: int in body_mm.instance_count:
			var picked: Array[Color] = pick_colors(rng, slice_away[i] != 0)
			body_mm.set_instance_color(i, picked[0])
			head_mm.set_instance_color(i, picked[1])


# Roll a body + head color pair for one spectator. Returns [body, head].
# Body roll: home_fan_ratio of home colors, away_fan_ratio of away colors,
# rest neutral civilian shirts. Real arenas skew heavily toward home, with
# the traveling support concentrated in one visiting block (in_away_block —
# away-heavy, zero home) plus a sprinkle scattered through the bowl.
# Within each team slice, secondary_color_ratio swap to the secondary tint.
# Head roll: skin/hat palette by default, with a small team_cap_ratio chance
# of a team-colored hat for committed fans.
func pick_colors(rng: RandomNumberGenerator,
		in_away_block: bool = false) -> Array[Color]:
	var roll: float = rng.randf()
	var home_cut: float = 0.0 if in_away_block else _spec.home_fan_ratio
	var away_cut: float = _AWAY_SECTION_FILL if in_away_block else _spec.away_fan_ratio
	var body: Color
	var team_loyalty: Color = Color(0, 0, 0, 0)  # alpha=0 sentinel = neutral
	if roll < home_cut:
		var base: Color = _spec.home_color_secondary \
				if rng.randf() < _spec.secondary_color_ratio else _spec.home_color
		body = _shade(base, rng)
		team_loyalty = _spec.home_color
	elif roll < home_cut + away_cut:
		var base: Color = _spec.away_color_secondary \
				if rng.randf() < _spec.secondary_color_ratio else _spec.away_color
		body = _shade(base, rng)
		team_loyalty = _spec.away_color
	else:
		body = _NEUTRAL_BODY_PALETTE[rng.randi() % _NEUTRAL_BODY_PALETTE.size()]
	var head: Color
	if team_loyalty.a > 0.0 and rng.randf() < _spec.team_cap_ratio:
		head = _shade(team_loyalty, rng)
	else:
		head = ArenaFigureMesh.HEAD_PALETTE[
				rng.randi() % ArenaFigureMesh.HEAD_PALETTE.size()]
	return [body, head]


func _shade(base: Color, rng: RandomNumberGenerator) -> Color:
	var s: float = rng.randf_range(-0.18, 0.18)
	return base.lightened(s) if s > 0.0 else base.darkened(-s)


# ── Attach ───────────────────────────────────────────────────────────────────

func attach(root: Node3D, layout: Dictionary) -> void:
	var body_mms: Array[MultiMesh] = layout.body_mms
	var head_mms: Array[MultiMesh] = layout.head_mms
	for k: int in body_mms.size():
		var body_mmi: MultiMeshInstance3D = MultiMeshInstance3D.new()
		body_mmi.multimesh = body_mms[k]
		body_mmi.name = "SpectatorBodies%d" % k
		# The crowd casts no shadows. Thousands of instances × the 8 shadow-
		# casting ceiling spotlights (RinkArena.tscn) is the arena's biggest
		# shadow-map cost, and crowd-on-crowd shadows up in the stands are never
		# visible from the rink-focused camera — a shimmer at best, given the
		# sway/hop animation. (The goalie disables shadow casting the same way.)
		body_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(body_mmi)
		var head_mmi: MultiMeshInstance3D = MultiMeshInstance3D.new()
		head_mmi.multimesh = head_mms[k]
		head_mmi.name = "SpectatorHeads%d" % k
		head_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(head_mmi)

	_flashbulbs = CrowdFlashbulbs.new()
	_flashbulbs.name = "CrowdFlashbulbs"
	_flashbulbs.set_sources(head_mms)
	root.add_child(_flashbulbs)
