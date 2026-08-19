extends GutTest

# The shoulder PAD and the arm that grows out of it are placed by two different
# code paths that never read each other: `Skater._repose_upper_bone` writes the
# cap bone, `Skater._textured_shoulder` gives the arm its root. When they
# disagreed the pad walked off the arm, worst at exactly the poses that displace
# a shoulder most — which is what the check-commit load-up now does on purpose.
#
# So this is the "these two must agree" test, on a LIVE rig rather than on the
# pure geometry (CheckStanceRules has its own suite): it also covers the side
# plumbing the rule cannot see — handedness → stick side → which cap loads.

const _SCENE: String = "res://Scenes/Skater.tscn"
const _DT: float = 1.0 / 120.0
# Enough ticks for the lead ease to converge (_CHECK_LEAD_SPEED is 5/s).
const _TICKS: int = 60
# A representative commit texture: the stance's own forward lean, plus a roll
# the gait can still be carrying from a stride underneath it.
const _PITCH: float = -0.244   # ~14°, hit_commit_lean_deg
const _ROLL: float = 0.09


func _rig(lefty: bool, committed: bool) -> Skater:
	var skater: Skater = (load(_SCENE) as PackedScene).instantiate() as Skater
	skater.is_left_handed = lefty
	add_child_autofree(skater)
	# Driven by hand — nothing here wants the gait or the physics integration.
	skater.set_process(false)
	skater.set_physics_process(false)
	skater.hit_committed = committed
	for _i: int in _TICKS:
		skater._update_commit_stance(_DT)
	skater.set_trunk_texture(_PITCH, _ROLL)
	return skater


# The cap bone's origin and the arm root for the same side.
func _cap(skater: Skater, side_sign: float) -> Vector3:
	var bone: int = SkaterMeshBuilder.UpperBone.SHOULDER_R if side_sign > 0.0 \
			else SkaterMeshBuilder.UpperBone.SHOULDER_L
	return skater._arm_skeleton.get_bone_pose(bone).origin


func _root(skater: Skater, side_sign: float) -> Vector3:
	var marker: Vector3 = skater.shoulder.position
	if signf(marker.x) != side_sign:
		marker = skater.bottom_shoulder.position
	return skater._textured_shoulder(marker)


func _assert_pad_sits_on_the_arm(skater: Skater, label: String) -> void:
	for side_sign: float in [-1.0, 1.0]:
		var gap: float = _cap(skater, side_sign).distance_to(_root(skater, side_sign))
		assert_almost_eq(gap, 0.0, 1e-5,
				"%s: %s cap and arm root must be the same point"
				% [label, "right" if side_sign > 0.0 else "left"])


func test_the_pad_sits_on_the_arm_uncommitted() -> void:
	_assert_pad_sits_on_the_arm(_rig(true, false), "lefty at rest")
	_assert_pad_sits_on_the_arm(_rig(false, false), "righty at rest")


func test_the_pad_sits_on_the_arm_through_the_load_up() -> void:
	_assert_pad_sits_on_the_arm(_rig(true, true), "lefty committing")
	_assert_pad_sits_on_the_arm(_rig(false, true), "righty committing")


# Handedness → stick side → lead side, end to end through the real skater. A
# right-handed shot carries the stick on his right, so he throws the left
# shoulder; a lefty throws the right.
func test_the_thrown_shoulder_is_the_one_off_the_stick() -> void:
	assert_gt(_rig(true, true).get_check_lead(), 0.0,
			"a left-handed shot leads with the RIGHT shoulder")
	assert_lt(_rig(false, true).get_check_lead(), 0.0,
			"a right-handed shot leads with the LEFT shoulder")


func test_an_uncommitted_skater_has_no_lead_at_all() -> void:
	assert_eq(_rig(true, false).get_check_lead(), 0.0,
			"the stance is off until the Hit button commits")


# The asymmetry itself, measured on the rig: the trailing cap may only move by
# whatever the (symmetric) trunk texture does to both of them, while the leading
# one travels further forward and further down on top of that.
func test_only_the_thrown_shoulder_leaves_the_trunk_texture() -> void:
	var rest: Skater = _rig(false, false)
	var loaded: Skater = _rig(false, true)
	# Right-handed: the LEFT cap is thrown, the right one only rides the texture.
	var trailing_moved: float = _cap(rest, 1.0).distance_to(_cap(loaded, 1.0))
	var leading_moved: float = _cap(rest, -1.0).distance_to(_cap(loaded, -1.0))
	assert_almost_eq(trailing_moved, 0.0, 1e-5,
			"the trailing cap holds its place under an unchanged texture")
	assert_gt(leading_moved, 0.03,
			"the thrown cap travels a real distance, not a token one")
	assert_lt(_cap(loaded, -1.0).z, _cap(rest, -1.0).z,
			"and it travels FORWARD (−z), which is what loading up looks like")
	assert_lt(_cap(loaded, -1.0).y, _cap(rest, -1.0).y, "and a little down")
	assert_gt(_cap(loaded, -1.0).x, _cap(rest, -1.0).x,
			"and inward across the chest")
