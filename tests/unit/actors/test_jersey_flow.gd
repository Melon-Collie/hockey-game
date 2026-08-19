extends GutTest

# The jersey hem swing: the torso profile's UV contract, the shader contract,
# the ghost path, and the flow model itself.
#
# The UV one is the load-bearing test in this file. The hem needs rings to bend
# through, so stations were added to _TORSO_PROFILE — and SkaterUniformCoordinator
# and JerseyDecal paint the stripes, name and number against that lathe's exact
# UV convention. Adding a ring is only safe because _build_lathe derives V from
# a station's own HEIGHT; if that ever changes to something index-based, every
# jersey in the game silently re-lays out and nothing else in the suite notices.

const _SHADER_PATH: String = "res://Shaders/jersey_flow.gdshader"
const _COORD_PATH: String = "res://Scripts/actors/skater_uniform_coordinator.gd"

# The V a station at height `y` must land on: 0 at the top of the profile,
# 0.5 at the bottom, from _build_lathe's `0.5 * (y_top - y) / span`.
const _Y_TOP: float = 0.275
const _Y_BOT: float = -0.275


func _expected_v(y: float) -> float:
	return 0.5 * (_Y_TOP - y) / (_Y_TOP - _Y_BOT)


func _torso_uvs() -> PackedVector2Array:
	var mesh: ArrayMesh = SkaterMeshBuilder.shared_torso()
	return mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV] as PackedVector2Array


# The four stations that predate the hem work, at the heights they have always
# had. Their V is what JerseyDecal's stripe/name/number layout is pinned to.
func test_the_original_profile_stations_keep_their_v() -> void:
	var uvs: PackedVector2Array = _torso_uvs()
	for y: float in [0.275, 0.245, 0.130, 0.000, -0.150, -0.230, -0.275]:
		var want: float = _expected_v(y)
		var found: bool = false
		for uv: Vector2 in uvs:
			if absf(uv.y - want) < 1e-4:
				found = true
				break
		assert_true(found,
				("no torso vertex sits at V %f, where the ring at y=%f belongs — " % [want, y]) +
				"inserting profile stations must not move the ones already there, or " +
				"every stripe and number on every jersey shifts")


# The swing stations are additive: they sit ON the segments between their
# neighbours, so the silhouette is the one that was tuned, not a new one.
func test_the_swing_stations_do_not_change_the_silhouette() -> void:
	# (inserted y, lower neighbour, upper neighbour) — radius must interpolate.
	var cases: Array[Array] = [
		[-0.075, 0.000, -0.150],
		[-0.190, -0.150, -0.230],
		[-0.253, -0.230, -0.275],
	]
	for c: Array in cases:
		var y: float = c[0]
		var y_a: float = c[1]
		var y_b: float = c[2]
		var r_at_y: float = _profile_radius(y)
		var t: float = (y - y_a) / (y_b - y_a)
		var want: float = lerpf(_profile_radius(y_a), _profile_radius(y_b), t)
		assert_almost_eq(r_at_y, want, 5e-4,
				"the station at y=%f must lie on the segment between its neighbours " % y +
				"— it is there for vertices to bend through, not to reshape the jersey")


# Radius of the torso lathe at a profile station, read back off the built mesh
# rather than the constant, so this also catches the profile and the mesh
# disagreeing.
func _profile_radius(y: float) -> float:
	var verts: PackedVector3Array = SkaterMeshBuilder.shared_torso() \
			.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array
	var best: float = 0.0
	for v: Vector3 in verts:
		if absf(v.y - y) > 1e-4:
			continue
		# _TORSO_X_SCALE stretches x, so the +Z/-Z extremes carry the true radius
		# and the z-swayed rings are measured off their own centre.
		best = maxf(best, absf(v.x) / 1.05)
	return best


func test_shader_declares_every_uniform_the_coordinator_writes() -> void:
	var src: String = FileAccess.get_file_as_string(_SHADER_PATH)
	assert_false(src.is_empty(), "could not read %s" % _SHADER_PATH)
	var declared := PackedStringArray()
	for line: String in src.split("\n"):
		var trimmed: String = line.strip_edges()
		if not trimmed.begins_with("uniform "):
			continue
		var decl: String = trimmed.trim_prefix("uniform ")
		for cut: String in [":", "=", ";", "["]:
			decl = decl.get_slice(cut, 0)
		var parts: PackedStringArray = decl.strip_edges().split(" ", false)
		if parts.size() >= 2:
			declared.append(parts[parts.size() - 1])

	var coord_src: String = FileAccess.get_file_as_string(_COORD_PATH)
	var re := RegEx.create_from_string('_jersey_mat\\.set_shader_parameter\\(&"([a-zA-Z_0-9]+)"')
	var pushed := PackedStringArray()
	for m: RegExMatch in re.search_all(coord_src):
		if not pushed.has(m.get_string(1)):
			pushed.append(m.get_string(1))
	assert_gt(pushed.size(), 0, "found no jersey uniform writes — did the parser break?")
	for name: String in pushed:
		assert_true(declared.has(name),
				"the coordinator writes jersey uniform '%s', which the shader does " % name +
				"not declare — that write is a silent no-op and the hem never moves")


# The hem ramp is expressed in the lathe's V, so it has to agree with what the
# lathe actually produces: full swing at the bottom ring and nothing at the
# collar.
func test_the_hem_ramp_matches_the_lathe_v_range() -> void:
	var src: String = FileAccess.get_file_as_string(_SHADER_PATH)
	var start_re := RegEx.create_from_string('hem_start_v = ([0-9.]+)')
	var full_re := RegEx.create_from_string('hem_full_v = ([0-9.]+)')
	var start_v: float = float(start_re.search(src).get_string(1))
	var full_v: float = float(full_re.search(src).get_string(1))
	assert_almost_eq(full_v, _expected_v(_Y_BOT), 1e-6,
			"the ramp must reach full swing exactly at the hem ring's V")
	assert_gt(start_v, _expected_v(0.0),
			"and start BELOW the waist ring, so the swing lives in the skirt")
	assert_lt(start_v, full_v, "the ramp has to have somewhere to ramp")


# ── The ghost path ───────────────────────────────────────────────────────────
# The trap this file exists to keep shut. apply_ghost fades all 17 upper-body
# surfaces through a StandardMaterial3D seam that, handed a ShaderMaterial it
# cannot cast, silently returns a fresh WHITE material instead. Un-ghosting then
# restores that white to full alpha — so before the branch in apply_ghost, one
# offside would have put every skater in a blank shirt for the rest of the match.
# The stick shaft hit exactly this and carries a comment about it; the torso is
# the second custom-shader part and gets a test instead.

const SKATER_SCENE: PackedScene = preload("res://Scenes/Skater.tscn")


# Read the override straight off the skinned mesh node. Skater's own
# upper_surface_material() is the wrong instrument here: it CREATES an override
# from the shared default when it cannot cast what is there, which is the very
# substitution under test — asking through it would manufacture the pass.
func _torso_material(skater: Skater) -> Material:
	var mesh := skater.upper_body.find_child("UpperMesh", true, false) as MeshInstance3D
	assert_not_null(mesh, "the skinned upper-body mesh should be built by _ready")
	return mesh.get_surface_override_material(SkaterMeshBuilder.UpperSurface.TORSO)


func _live_skater() -> Skater:
	var skater: Skater = SKATER_SCENE.instantiate() as Skater
	add_child_autofree(skater)
	return skater


func test_the_torso_wears_the_flow_shader() -> void:
	var mat: Material = _torso_material(_live_skater())
	var shader_mat := mat as ShaderMaterial
	assert_not_null(shader_mat, "the torso must carry a ShaderMaterial, or the hem cannot move")
	assert_eq(shader_mat.shader.resource_path, _SHADER_PATH,
			"and it must be jersey_flow.gdshader specifically")


func test_ghosting_and_back_leaves_the_flow_shader_on_the_torso() -> void:
	var skater: Skater = _live_skater()
	var original: Material = _torso_material(skater)
	skater.set_ghost(true)
	var ghosted := _torso_material(skater) as StandardMaterial3D
	assert_not_null(ghosted, "a ghosted torso fades through a translucent standard material")
	assert_almost_eq(ghosted.albedo_color.a, 0.3, 1e-6, "and it is actually translucent")
	assert_not_null(ghosted.albedo_texture,
			"carrying the jersey texture — a ghost is a faded player, not a blank one")

	skater.set_ghost(false)
	var restored: Material = _torso_material(skater)
	assert_eq(restored, original,
			"un-ghosting must restore the ORIGINAL flow ShaderMaterial. A white " +
			"StandardMaterial3D here is the seam's failed cast, and every skater " +
			"wears it for the rest of the match")


# ── The swing itself ─────────────────────────────────────────────────────────
# Direction is the whole feel here, and it is the one thing a screenshot of a
# stationary skater cannot show. Driven through the coordinator rather than
# Skater._process so this measures the flow model and not the rest of the
# cosmetic pass.

const _DT: float = 1.0 / 60.0
# Body forward is -Z (the frame compute_velocity_lean_target reads).
const _FORWARD := Vector3(0.0, 0.0, -6.0)


func _flow(skater: Skater) -> Vector3:
	var mat := _torso_material(skater) as ShaderMaterial
	var v: Vector4 = mat.get_shader_parameter(&"flow")
	return Vector3(v.x, v.y, v.z)


func _settle(skater: Skater, velocity: Vector3, frames: int) -> void:
	skater.velocity = velocity
	for _i in frames:
		skater._uniform.update_jersey_flow(_DT)


func test_a_skater_already_moving_does_not_open_with_a_lurch() -> void:
	var skater: Skater = _live_skater()
	_settle(skater, _FORWARD, 1)
	assert_almost_eq(_flow(skater).length(), 0.0, 1e-6,
			"the cloth starts where the body is — a skater spawned at speed, or one " +
			"whose first frame lands mid-stride, must not fling its hem")


func test_accelerating_trails_the_hem_behind() -> void:
	var skater: Skater = _live_skater()
	_settle(skater, Vector3.ZERO, 1)
	_settle(skater, _FORWARD, 1)
	assert_gt(_flow(skater).z, 0.0,
			"the body pulls forward (-Z) out from under the cloth, so the skirt is " +
			"left behind it (+Z)")


func test_holding_a_steady_speed_lets_the_hem_settle() -> void:
	var skater: Skater = _live_skater()
	_settle(skater, Vector3.ZERO, 1)
	_settle(skater, _FORWARD, 1)
	var launched: float = _flow(skater).length()
	_settle(skater, _FORWARD, 90)
	assert_gt(launched, 0.0, "sanity: the skirt really did trail on the way up to speed")
	assert_lt(_flow(skater).length(), launched * 0.1,
			"a skater gliding at a constant speed has a hem that hangs — the swing is " +
			"a lag, so nothing keeps feeding it once the cloth catches up")


func test_stopping_hard_throws_the_hem_forward() -> void:
	var skater: Skater = _live_skater()
	_settle(skater, _FORWARD, 60)
	_settle(skater, Vector3.ZERO, 1)
	assert_lt(_flow(skater).z, 0.0,
			"the body stops and the cloth does not, so the skirt swings out ahead (-Z)")


func test_the_swing_is_capped() -> void:
	var skater: Skater = _live_skater()
	_settle(skater, Vector3.ZERO, 1)
	# A step no skater can take, standing in for a respawn or a mode change
	# dropping a large velocity in on one frame.
	_settle(skater, Vector3(0.0, 0.0, -400.0), 1)
	assert_lte(_flow(skater).length(), 0.05 + 1e-6,
			"however violent the velocity step, the hem stays on the body")
