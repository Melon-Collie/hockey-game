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
	assert_almost_eq(aim.z, NET_Z, 0.001, "aim should land on the net plane")
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
	assert_almost_eq(aim.z, NET_Z, 0.001)


func test_corner_bias_pulls_aim_toward_post() -> void:
	# Goalie shifted -X — right arc is wider, aim goes right. With
	# default corner_bias = 0.7, aim should sit closer to the right
	# post than to the open arc midpoint.
	var shooter := Vector3(0.0, 0.0, 20.0)
	var goalie := Vector3(-0.4, 0.0, 26.0)
	var aim: Vector3 = AIShotAim.compute_open_net_aim(shooter, goalie, NET_Z, NET_HW, SHADOW_HW)
	# Compute the arc midpoint manually for comparison.
	var dz: float = goalie.z - shooter.z
	var to_net_z: float = NET_Z - shooter.z
	var t: float = to_net_z / dz
	var shadow_x: float = shooter.x + t * (goalie.x - shooter.x)
	var shadow_right: float = clampf(shadow_x + SHADOW_HW, -NET_HW, NET_HW)
	var midpoint: float = (shadow_right + NET_HW) * 0.5
	assert_gt(aim.x, midpoint, "default corner_bias should pull aim past the arc midpoint toward the post")
	assert_lte(aim.x, NET_HW, "aim still inside the net")


func test_corner_bias_zero_matches_arc_midpoint() -> void:
	# corner_bias = 0 reproduces the legacy "midpoint of open arc" behavior.
	var shooter := Vector3(0.0, 0.0, 20.0)
	var goalie := Vector3(-0.4, 0.0, 26.0)
	var aim: Vector3 = AIShotAim.compute_open_net_aim(
			shooter, goalie, NET_Z, NET_HW, SHADOW_HW, 0.0)
	var dz: float = goalie.z - shooter.z
	var to_net_z: float = NET_Z - shooter.z
	var t: float = to_net_z / dz
	var shadow_x: float = shooter.x + t * (goalie.x - shooter.x)
	var shadow_right: float = clampf(shadow_x + SHADOW_HW, -NET_HW, NET_HW)
	var midpoint: float = (shadow_right + NET_HW) * 0.5
	assert_almost_eq(aim.x, midpoint, 0.001,
			"corner_bias=0 lands aim at the arc midpoint exactly")
