extends GutTest

# Blade lever calibration — the attributes-v4 hands model, pinned as a spec.
# The blade caps derive from LEVER GEOMETRY (reach + stick length), never a
# table: tip speed ∝ lever (the same angular gesture sweeps a longer blade
# faster in m/s), inertia cap ∝ 1/lever^k. Two constitution guarantees live
# here:
#   1. NEUTRAL IDENTITY — the 6'1"/201/standard build's caps equal the shipped
#      exports exactly.
#   2. TRAVERSE-TIME FLATNESS — reach envelope / tip speed stays ~constant
#      across every build: everyone's wrists are heard at the same ANGULAR
#      fidelity. The lever changes what your hands drive, never how faithfully
#      they're heard.
# Plus the deliberate seesaw: reversal time (tip speed / accel cap) varies
# monotonically with lever and stays inside the authored spread.

const SKATER_SCENE: PackedScene = preload("res://Scenes/Skater.tscn")


class GameStateStub:
	extends Node

	func is_host() -> bool:
		return false

	func is_movement_locked() -> bool:
		return false


func _make_controller() -> SkaterController:
	var skater: Skater = SKATER_SCENE.instantiate() as Skater
	add_child_autofree(skater)
	skater.set_physics_process(false)
	skater.set_process(false)
	var puck: Puck = (preload("res://Scenes/Puck.tscn").instantiate()) as Puck
	add_child_autofree(puck)
	puck.set_physics_process(false)
	puck.global_position = Vector3(20.0, 0.0, 20.0)
	var gs := GameStateStub.new()
	add_child_autofree(gs)
	var controller := SkaterController.new()
	add_child_autofree(controller)
	# Runs at the SHIPPED defaults (max_blade_accel 250, exponent 1.6 —
	# playtest-calibrated): the seesaw assertions below spec the live game.
	controller.setup(skater, puck, gs)
	return controller


# The build matrix spanning the lever extremes: scalpel (small + short stick)
# → neutral → scythe (tall + long stick).
func _builds() -> Array[PlayerAttributes]:
	return [
		PlayerAttributes.new(68, 158, 1, 1, 1, PlayerAttributes.LENGTH_SHORT),
		PlayerAttributes.new(68, 158),
		PlayerAttributes.all_average(),
		PlayerAttributes.new(79, 257),
		PlayerAttributes.new(79, 257, 1, 1, 1, PlayerAttributes.LENGTH_LONG),
	]


func test_neutral_build_caps_equal_shipped_exports() -> void:
	var c := _make_controller()
	var base_speed: float = c.max_blade_speed
	var base_accel: float = c.max_blade_accel
	c.apply_attributes(PlayerAttributes.all_average())
	assert_almost_eq(c.max_blade_speed, base_speed, 0.0001,
			"neutral tip speed == shipped export")
	assert_almost_eq(c.max_blade_accel, base_accel, 0.0001,
			"neutral inertia cap == shipped export")


func test_tip_speed_rides_the_lever() -> void:
	var c := _make_controller()
	var speeds: Array[float] = []
	for attrs: PlayerAttributes in _builds():
		c.apply_attributes(attrs)
		speeds.append(c.max_blade_speed)
	for i: int in range(speeds.size() - 1):
		assert_lt(speeds[i], speeds[i + 1],
				"tip speed strictly increases with lever (index %d)" % i)


func test_traverse_time_is_flat_across_builds() -> void:
	# The fidelity guarantee: time to sweep your own reach envelope is ~constant
	# — the ratio (max blade reach / tip speed) stays within a few percent of
	# neutral for every build × length. The residual comes from the constant
	# blade length and the forehand/backhand ROM split not scaling perfectly
	# with the sweep lever; it must stay far below anything a hands table would
	# have produced (the v3 spread was ±20%).
	var c := _make_controller()
	var ratios: Array[float] = []
	for attrs: PlayerAttributes in _builds():
		c.apply_attributes(attrs)
		ratios.append(c.build_ai_caps().max_blade_reach / c.max_blade_speed)
	var lo: float = ratios.min()
	var hi: float = ratios.max()
	assert_lt(hi / lo, 1.08, "traverse time flat within 8%% (got %.3f)" % (hi / lo))


func test_reversal_seesaw_bounded_and_monotonic() -> void:
	# The deliberate tradeoff: reversal time ∝ tip_speed / accel_cap grows with
	# the lever (the scythe can't cut back like the scalpel). Monotonic across
	# the matrix, and the extreme-to-extreme spread stays inside the authored
	# band — wide enough to feel, far from the L³ brutality of raw physics.
	var c := _make_controller()
	var reversal: Array[float] = []
	for attrs: PlayerAttributes in _builds():
		c.apply_attributes(attrs)
		assert_gt(c.max_blade_accel, 0.0, "inertia cap live")
		reversal.append(c.max_blade_speed / c.max_blade_accel)
	for i: int in range(reversal.size() - 1):
		assert_lt(reversal[i], reversal[i + 1],
				"reversal time strictly increases with lever (index %d)" % i)
	var spread: float = reversal[reversal.size() - 1] / reversal[0]
	assert_between(spread, 1.15, 1.80,
			"scalpel→scythe reversal spread inside the authored band")


func test_stick_length_gear_leans_the_stick() -> void:
	var c := _make_controller()
	c.apply_attributes(PlayerAttributes.new(73, 201, 1, 1, 1, PlayerAttributes.LENGTH_SHORT))
	var short_len: float = c.stick_length
	c.apply_attributes(PlayerAttributes.all_average())
	var std_len: float = c.stick_length
	c.apply_attributes(PlayerAttributes.new(73, 201, 1, 1, 1, PlayerAttributes.LENGTH_LONG))
	var long_len: float = c.stick_length
	assert_lt(short_len, std_len, "short cuts the stick")
	assert_lt(std_len, long_len, "long extends it")
	assert_almost_eq(short_len / std_len, 0.96, 0.001, "short = −4% of the height's cut")
	assert_almost_eq(long_len / std_len, 1.04, 0.001, "long = +4%")


func test_apply_is_idempotent() -> void:
	# Repeated applies (free-play picker changes) recompute from bases — the
	# lever derivation must never compound.
	var c := _make_controller()
	var attrs := PlayerAttributes.new(79, 257, 1, 1, 1, PlayerAttributes.LENGTH_LONG)
	c.apply_attributes(attrs)
	var speed_once: float = c.max_blade_speed
	var accel_once: float = c.max_blade_accel
	c.apply_attributes(attrs)
	assert_almost_eq(c.max_blade_speed, speed_once, 0.0001, "tip speed stable")
	assert_almost_eq(c.max_blade_accel, accel_once, 0.0001, "accel cap stable")
