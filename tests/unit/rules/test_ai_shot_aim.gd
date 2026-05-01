extends GutTest

# AIShotAim is a pure function: shooter+goalie+net geometry → aim point.
# All inputs in world XZ; net is a horizontal segment at z=net_z spanning
# x ∈ [-net_half, +net_half].

const NET_HW: float = 0.915
const SHADOW_HW: float = 0.5
const NET_Z: float = 26.65


func test_centered_goalie_picks_a_corner() -> void:
	# Shooter dead center in the slot, goalie centered on the goal — both
	# arcs are equal, picks left by tie-break.
	var shooter := Vector3(0.0, 0.0, 20.0)
	var goalie := Vector3(0.0, 0.0, 26.5)
	var aim: Vector3 = AIShotAim.compute_open_net_aim(shooter, goalie, NET_Z, NET_HW, SHADOW_HW)
	assert_eq(aim.z, NET_Z, "aim should land on the net plane")
	# Tie-break is left arc → aim_x is the midpoint of [-0.915, -0.5*shadow projection]
	assert_lt(aim.x, 0.0, "tie-break picks the left arc")


func test_goalie_offset_left_picks_right_corner() -> void:
	# Goalie shifted to -X (covers the left side of the net from the
	# shooter's vantage) → the right arc is wider → aim right.
	var shooter := Vector3(0.0, 0.0, 20.0)
	var goalie := Vector3(-0.5, 0.0, 26.5)
	var aim: Vector3 = AIShotAim.compute_open_net_aim(shooter, goalie, NET_Z, NET_HW, SHADOW_HW)
	assert_gt(aim.x, 0.0, "open right side should pull aim toward +X")


func test_goalie_offset_right_picks_left_corner() -> void:
	var shooter := Vector3(0.0, 0.0, 20.0)
	var goalie := Vector3(0.5, 0.0, 26.5)
	var aim: Vector3 = AIShotAim.compute_open_net_aim(shooter, goalie, NET_Z, NET_HW, SHADOW_HW)
	assert_lt(aim.x, 0.0, "open left side should pull aim toward -X")


func test_aim_inside_net_bounds() -> void:
	var shooter := Vector3(3.0, 0.0, 18.0)
	var goalie := Vector3(0.4, 0.0, 26.0)
	var aim: Vector3 = AIShotAim.compute_open_net_aim(shooter, goalie, NET_Z, NET_HW, SHADOW_HW)
	assert_gte(aim.x, -NET_HW)
	assert_lte(aim.x, NET_HW)


func test_shooter_at_goalie_z_falls_back_to_center() -> void:
	# Sightline can't cross the net plane; fall back to center.
	var shooter := Vector3(2.0, 0.0, 26.5)
	var goalie := Vector3(0.0, 0.0, 26.5)
	var aim: Vector3 = AIShotAim.compute_open_net_aim(shooter, goalie, NET_Z, NET_HW, SHADOW_HW)
	assert_almost_eq(aim.x, 0.0, 0.0001)
	assert_eq(aim.z, NET_Z)
