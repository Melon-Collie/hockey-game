extends GutTest

# The jersey hem swing: the torso profile's UV contract, the split at the waist,
# and the swing itself.
#
# The skirt is a slice of the torso lathe on its own bone (UpperBone.HEM), posed
# per frame — NOT a vertex shader. That choice is what lets the torso keep a
# StandardMaterial3D and the real BodyRim term, matching the arms and helmet
# beside it in light and in shadow; a custom shader can only approximate that rim
# with emission, which does not fade where the light does.
#
# The UV test is the load-bearing one. Stations were added below the waist for
# the skirt to bend through, and the lathe was cut in two — and
# SkaterUniformCoordinator and JerseyDecal paint stripes, name and number against
# that lathe's exact UV convention. Both changes are only safe because
# _build_lathe derives V from a station's own HEIGHT and from the WHOLE profile.
# If either ever becomes index- or slice-relative, every jersey in the game
# silently re-lays out and nothing else in the suite notices.

const SKATER_SCENE: PackedScene = preload("res://Scenes/Skater.tscn")

# The V a station at height `y` must land on: 0 at the top of the profile,
# 0.5 at the bottom, from _build_lathe's `0.5 * (y_top - y) / span`.
const _Y_TOP: float = 0.275
const _Y_BOT: float = -0.275
# The seven stations that predate the hem work, and the three added for it.
const _ORIGINAL_STATIONS: Array[float] = [0.275, 0.245, 0.130, 0.000, -0.150, -0.230, -0.275]
const _SWING_STATIONS: Array[float] = [-0.075, -0.190, -0.253]
const _WAIST_Y: float = 0.000
# A point on the hem ring, in torso-local space (the bottom station plus its
# rear sway) — the thing the swing is specified in terms of.
const _HEM_POINT := Vector3(0.0, -0.275, 0.032)
const _WAIST_POINT := Vector3(0.0, 0.0, 0.006)


func _expected_v(y: float) -> float:
	return 0.5 * (_Y_TOP - y) / (_Y_TOP - _Y_BOT)


func _uvs_of(mesh: ArrayMesh) -> PackedVector2Array:
	return mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV] as PackedVector2Array


func _verts_of(mesh: ArrayMesh) -> PackedVector3Array:
	return mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array


func _has_v(uvs: PackedVector2Array, want: float) -> bool:
	for uv: Vector2 in uvs:
		if absf(uv.y - want) < 1e-4:
			return true
	return false


# ── The painter contract ─────────────────────────────────────────────────────

func test_the_original_profile_stations_keep_their_v() -> void:
	var uvs: PackedVector2Array = _uvs_of(SkaterMeshBuilder.shared_torso())
	for y: float in _ORIGINAL_STATIONS:
		assert_true(_has_v(uvs, _expected_v(y)),
				("no torso vertex sits at V %f, where the ring at y=%f belongs — " %
						[_expected_v(y), y]) +
				"inserting profile stations must not move the ones already there, or " +
				"every stripe and number on every jersey shifts")


# The cut is the second way the UVs could have moved, and the more subtle one:
# a slice that derived V from its own extent would renumber both halves.
func test_splitting_the_lathe_does_not_renumber_either_half() -> void:
	var body: PackedVector2Array = _uvs_of(SkaterMeshBuilder.shared_torso_body())
	var skirt: PackedVector2Array = _uvs_of(SkaterMeshBuilder.shared_torso_skirt())
	assert_true(_has_v(body, _expected_v(_Y_TOP)),
			"the body half must still start at the collar's V, not at 0 of its own range")
	assert_true(_has_v(skirt, _expected_v(_Y_BOT)),
			"the skirt half must still end at the hem's V")
	assert_true(_has_v(skirt, _expected_v(_WAIST_Y)),
			"and start at the waist's V — a slice's V comes from the WHOLE profile")
	for y: float in _ORIGINAL_STATIONS:
		var want: float = _expected_v(y)
		assert_true(_has_v(body, want) or _has_v(skirt, want),
				"the ring at y=%f must survive the cut into one half or the other" % y)


# Both halves carry the waist ring, and the swing rotates ABOUT it — so the seam
# cannot open however hard the skirt swings.
func test_both_halves_share_the_waist_ring() -> void:
	var body_ring: Array[Vector3] = _ring_at(SkaterMeshBuilder.shared_torso_body(), _WAIST_Y)
	var skirt_ring: Array[Vector3] = _ring_at(SkaterMeshBuilder.shared_torso_skirt(), _WAIST_Y)
	assert_gt(body_ring.size(), 0, "the body half must include the waist ring")
	assert_gt(skirt_ring.size(), 0, "and so must the skirt half")
	# The SAME ring, vertex for vertex — otherwise "shared" is only a claim about
	# heights and the seam is welded by luck.
	for v: Vector3 in body_ring:
		var matched: bool = false
		for w: Vector3 in skirt_ring:
			if v.distance_to(w) < 1e-5:
				matched = true
				break
		assert_true(matched, "waist vertex %s has no twin in the skirt half" % v)


func _ring_at(mesh: ArrayMesh, y: float) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for v: Vector3 in _verts_of(mesh):
		if absf(v.y - y) < 1e-5 and not out.has(v):
			out.append(v)
	return out


# The swing stations are additive: they sit ON the segments between their
# neighbours, so the silhouette is the one that was tuned, not a new one.
func test_the_swing_stations_do_not_change_the_silhouette() -> void:
	var cases: Array[Array] = [
		[_SWING_STATIONS[0], 0.000, -0.150],
		[_SWING_STATIONS[1], -0.150, -0.230],
		[_SWING_STATIONS[2], -0.230, -0.275],
	]
	for c: Array in cases:
		var y: float = c[0]
		var lo: float = c[1]
		var hi: float = c[2]
		var t: float = (y - lo) / (hi - lo)
		var want: float = lerpf(_profile_radius(lo), _profile_radius(hi), t)
		assert_almost_eq(_profile_radius(y), want, 5e-4,
				"the station at y=%f must lie on the segment between its neighbours " % y +
				"— it is there for vertices to bend through, not to reshape the jersey")


# Radius at a profile station, read off the built mesh rather than the constant,
# so this also catches the profile and the mesh disagreeing.
func _profile_radius(y: float) -> float:
	var best: float = 0.0
	for v: Vector3 in _verts_of(SkaterMeshBuilder.shared_torso()):
		if absf(v.y - y) > 1e-4:
			continue
		best = maxf(best, absf(v.x) / 1.05)  # _TORSO_X_SCALE
	return best


# ── The rig ──────────────────────────────────────────────────────────────────

func _live_skater() -> Skater:
	var skater: Skater = SKATER_SCENE.instantiate() as Skater
	add_child_autofree(skater)
	return skater


func _bone_pose(skater: Skater, bone: int) -> Transform3D:
	var skel := skater.upper_body.find_child("UpperRig", true, false) as Skeleton3D
	return skel.get_bone_pose(bone)


func _upper_material(skater: Skater, surface: int) -> Material:
	var mesh := skater.upper_body.find_child("UpperMesh", true, false) as MeshInstance3D
	return mesh.get_surface_override_material(surface)


# Where the hem ring actually ends up, relative to where the torso would have
# put it — the swing as the rig delivers it, not as it was asked for.
func _hem_offset(skater: Skater) -> Vector3:
	return (_bone_pose(skater, SkaterMeshBuilder.UpperBone.HEM) * _HEM_POINT) \
			- (_bone_pose(skater, SkaterMeshBuilder.UpperBone.TORSO) * _HEM_POINT)


# The whole reason the swing is a bone: the jersey keeps the engine's own rim
# term, so it lights like the arms and helmet next to it instead of glowing
# faintly in shadow the way an emission approximation would.
func test_the_jersey_keeps_a_standard_material_with_the_body_rim() -> void:
	var skater: Skater = _live_skater()
	var mat := _upper_material(skater, SkaterMeshBuilder.UpperSurface.TORSO) as StandardMaterial3D
	assert_not_null(mat, "the torso must stay a StandardMaterial3D to keep the real rim")
	assert_true(mat.rim_enabled, "with BodyRim applied")
	assert_almost_eq(mat.rim, BodyRim.STRENGTH, 1e-6, "at the shared rim strength")
	assert_eq(_upper_material(skater, SkaterMeshBuilder.UpperSurface.HEM), mat,
			"and the skirt must wear the very same material — the seam is a geometry " +
			"boundary, not a paint one")


# The skirt has no placement of its own; it takes the torso's. If the two drift,
# the jersey comes apart at the waist.
func test_the_skirt_tracks_the_torso_bone() -> void:
	var skater: Skater = _live_skater()
	assert_almost_eq(_hem_offset(skater).length(), 0.0, 1e-6,
			"at rest the skirt sits exactly on the torso's pose")
	# The gait's trunk texture is the pose channel most likely to be forgotten:
	# the bone list is flat, so nothing but _repose_upper_bone keeps these
	# together.
	skater.set_trunk_texture(0.12, -0.08)
	assert_almost_eq(_hem_offset(skater).length(), 0.0, 1e-6,
			"and it must follow the trunk texture without being told")
	# A body dial scaling the trunk is the other one.
	skater.set_upper_bone_scale(SkaterMeshBuilder.UpperBone.TORSO, Vector3(1.2, 1.1, 1.15))
	assert_almost_eq(_hem_offset(skater).length(), 0.0, 1e-6,
			"and the torso's scale, or a heavy build wears a jersey in two pieces")


func test_a_swing_moves_the_hem_and_leaves_the_waist_alone() -> void:
	var skater: Skater = _live_skater()
	skater.set_hem_swing(Vector3(0.0, 0.0, 0.04))
	var hem_pose: Transform3D = _bone_pose(skater, SkaterMeshBuilder.UpperBone.HEM)
	var torso_pose: Transform3D = _bone_pose(skater, SkaterMeshBuilder.UpperBone.TORSO)
	assert_almost_eq((hem_pose * _WAIST_POINT).distance_to(torso_pose * _WAIST_POINT),
			0.0, 1e-4,
			"the shared waist ring is the pivot and must not move, or the seam opens")
	var moved: Vector3 = _hem_offset(skater)
	assert_almost_eq(moved.length(), 0.04, 5e-3,
			"the hem ring travels the distance it was asked to")
	assert_gt(moved.z, 0.0, "and in the direction it was asked to")


func test_a_swing_of_zero_is_the_rest_pose() -> void:
	var skater: Skater = _live_skater()
	skater.set_hem_swing(Vector3(0.0, 0.0, 0.04))
	skater.set_hem_swing(Vector3.ZERO)
	assert_almost_eq(_hem_offset(skater).length(), 0.0, 1e-9,
			"a settled skirt returns exactly to the torso's pose")


func test_ghosting_and_back_leaves_both_jersey_halves_intact() -> void:
	var skater: Skater = _live_skater()
	var before: Material = _upper_material(skater, SkaterMeshBuilder.UpperSurface.TORSO)
	skater.set_ghost(true)
	for surface: int in [SkaterMeshBuilder.UpperSurface.TORSO, SkaterMeshBuilder.UpperSurface.HEM]:
		assert_almost_eq((_upper_material(skater, surface) as StandardMaterial3D).albedo_color.a,
				0.3, 1e-6, "a ghosted jersey is translucent, skirt included")
	skater.set_ghost(false)
	assert_eq(_upper_material(skater, SkaterMeshBuilder.UpperSurface.TORSO), before,
			"un-ghosting restores the same material")
	assert_almost_eq((_upper_material(skater, SkaterMeshBuilder.UpperSurface.TORSO)
			as StandardMaterial3D).albedo_color.a, 1.0, 1e-6, "at full opacity")


# ── The swing model ──────────────────────────────────────────────────────────
# Direction is the whole feel, and it is the one thing a screenshot of a
# stationary skater cannot show. Driven through the coordinator rather than
# Skater._process so this measures the flow model and not the rest of the
# cosmetic pass.

const _DT: float = 1.0 / 60.0
# Body forward is -Z (the frame compute_velocity_lean_target reads).
const _FORWARD := Vector3(0.0, 0.0, -6.0)


func _settle(skater: Skater, velocity: Vector3, frames: int) -> void:
	skater.velocity = velocity
	for _i in frames:
		skater._uniform.update_jersey_flow(_DT)


func test_a_skater_already_moving_does_not_open_with_a_lurch() -> void:
	var skater: Skater = _live_skater()
	_settle(skater, _FORWARD, 1)
	assert_almost_eq(_hem_offset(skater).length(), 0.0, 1e-6,
			"the cloth starts where the body is — a skater spawned at speed, or one " +
			"whose first frame lands mid-stride, must not fling its hem")


func test_accelerating_trails_the_hem_behind() -> void:
	var skater: Skater = _live_skater()
	_settle(skater, Vector3.ZERO, 1)
	_settle(skater, _FORWARD, 1)
	assert_gt(_hem_offset(skater).z, 0.0,
			"the body pulls forward (-Z) out from under the cloth, so the skirt is " +
			"left behind it (+Z)")


func test_holding_a_steady_speed_lets_the_hem_settle() -> void:
	var skater: Skater = _live_skater()
	_settle(skater, Vector3.ZERO, 1)
	_settle(skater, _FORWARD, 1)
	var launched: float = _hem_offset(skater).length()
	_settle(skater, _FORWARD, 90)
	assert_gt(launched, 0.0, "sanity: the skirt really did trail on the way up to speed")
	assert_lt(_hem_offset(skater).length(), launched * 0.1,
			"a skater gliding at a constant speed has a hem that hangs — the swing is " +
			"a lag, so nothing keeps feeding it once the cloth catches up")


func test_stopping_hard_throws_the_hem_forward() -> void:
	var skater: Skater = _live_skater()
	_settle(skater, _FORWARD, 60)
	_settle(skater, Vector3.ZERO, 1)
	assert_lt(_hem_offset(skater).z, 0.0,
			"the body stops and the cloth does not, so the skirt swings out ahead (-Z)")


func test_the_swing_is_capped() -> void:
	var skater: Skater = _live_skater()
	_settle(skater, Vector3.ZERO, 1)
	# A step no skater can take, standing in for a respawn or a mode change
	# dropping a large velocity in on one frame.
	_settle(skater, Vector3(0.0, 0.0, -400.0), 1)
	# Uncapped this step asks for metres of swing, so the bound only has to be
	# somewhere near _FLOW_MAX to prove the clamp fires at all.
	assert_lte(_hem_offset(skater).length(), 0.1,
			"however violent the velocity step, the hem stays on the body")
