extends GutTest

# SkaterPoseCoordinator.compute_upper_body_lean_target — the directional
# reach lean. Pure static math: hand position relative to the shoulder in
# upper-body-local XZ → Vector2(pitch = rotation.x, roll = rotation.z).
#
# Sign conventions under test (Godot node rotations, upper-body frame):
#   - negative rotation.x pitches the torso top toward local −Z (forward)
#   - negative rotation.z rolls the torso top toward local +X (right)
# So a forward reach must produce (negative, 0), a reach toward +X must
# produce (0, negative), and the lean vector must always point at the hand.
#
# The lean feeds the blade IK's frame (upper_body_to_local), so this math is
# reach-affecting, not just cosmetic — pin it.

const ROM: float = 0.4
const LEAN_MAX_DEG: float = 18.0

var _shoulder := Vector2(0.24, 0.0)


func _target(hand_offset: Vector2, engage_power: float = 1.0) -> Vector2:
	return SkaterPoseCoordinator.compute_upper_body_lean_target(
			_shoulder + hand_offset, _shoulder, ROM, LEAN_MAX_DEG, engage_power)


func test_no_reach_is_zero() -> void:
	assert_eq(_target(Vector2.ZERO), Vector2.ZERO)


func test_zero_rom_is_zero() -> void:
	var t: Vector2 = SkaterPoseCoordinator.compute_upper_body_lean_target(
			_shoulder + Vector2(0.0, -ROM), _shoulder, 0.0, LEAN_MAX_DEG, 1.0)
	assert_eq(t, Vector2.ZERO)


func test_forward_reach_pitches_forward_only() -> void:
	# Hand straight ahead (−Z) at full ROM: full forward pitch, no roll.
	var t: Vector2 = _target(Vector2(0.0, -ROM))
	assert_almost_eq(t.x, -deg_to_rad(LEAN_MAX_DEG), 0.0001, "full forward pitch")
	assert_almost_eq(t.y, 0.0, 0.0001, "no roll on a straight-ahead reach")


func test_right_reach_rolls_right_only() -> void:
	# Hand toward +X at full ROM: negative roll (top toward +X), no pitch.
	var t: Vector2 = _target(Vector2(ROM, 0.0))
	assert_almost_eq(t.x, 0.0, 0.0001, "no pitch on a pure side reach")
	assert_almost_eq(t.y, -deg_to_rad(LEAN_MAX_DEG), 0.0001, "full roll toward +X")


func test_left_reach_rolls_left() -> void:
	var t: Vector2 = _target(Vector2(-ROM, 0.0))
	assert_almost_eq(t.y, deg_to_rad(LEAN_MAX_DEG), 0.0001, "positive roll toward −X")


func test_diagonal_reach_splits_evenly() -> void:
	# 45° reach: pitch and roll magnitudes match (unit direction components).
	var t: Vector2 = _target(Vector2(ROM, -ROM).normalized() * ROM)
	assert_almost_eq(absf(t.x), absf(t.y), 0.0001, "diagonal splits pitch/roll evenly")
	assert_lt(t.x, 0.0, "forward component pitches forward")
	assert_lt(t.y, 0.0, "rightward component rolls right")
	var mag: float = sqrt(t.x * t.x + t.y * t.y)
	assert_almost_eq(mag, deg_to_rad(LEAN_MAX_DEG), 0.0001, "total magnitude is the cap")


func test_reach_beyond_rom_clamps_to_max() -> void:
	var t: Vector2 = _target(Vector2(0.0, -ROM * 3.0))
	assert_almost_eq(t.x, -deg_to_rad(LEAN_MAX_DEG), 0.0001, "reach factor clamps at 1")


func test_engage_power_suppresses_mid_reach() -> void:
	# At half reach, power 2 gives a quarter of the cap (0.5² = 0.25) —
	# the torso stays quiet through mid-ROM stickhandling.
	var linear: Vector2 = _target(Vector2(0.0, -ROM * 0.5), 1.0)
	var eased: Vector2 = _target(Vector2(0.0, -ROM * 0.5), 2.0)
	assert_almost_eq(linear.x, -deg_to_rad(LEAN_MAX_DEG) * 0.5, 0.0001)
	assert_almost_eq(eased.x, -deg_to_rad(LEAN_MAX_DEG) * 0.25, 0.0001)


func test_engage_power_preserves_endpoints() -> void:
	# The curve reshapes the middle only — rim and rest are unchanged.
	assert_eq(_target(Vector2.ZERO, 2.0), Vector2.ZERO)
	var rim: Vector2 = _target(Vector2(0.0, -ROM), 2.0)
	assert_almost_eq(rim.x, -deg_to_rad(LEAN_MAX_DEG), 0.0001)
