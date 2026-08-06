extends GutTest

# The rendered shaft runs from the top hand to the blade (Skater.update_stick_mesh
# scales it to that distance), so |hand − blade| IS the stick's drawn length. Every
# obstacle clamp may move the blade, and the arm is then rebuilt to reach it with
# the stick choking up — so an obstacle can only ever SHORTEN what is drawn.
#
# It lengthened it. Skating into the boards near the goal line handed the blade to
# the net's back mesh, whose plane has no lateral span and so claimed a stick out
# in the corner metres away; the blade hung on that surface while the player skated
# off it and the shaft drew ten times its own length. The posed shot states then
# had a second copy of the same fault — they clamped the blade and left the hand.
#
# Two claims, because the posed states and the tracked one earn it differently:
# nothing is ever drawn longer than the stick, and no obstacle adds to what the
# same run draws in open ice. The second catches a clamp buying its correction in
# stick length even where the authored pose has room to absorb it.

const SKATER_SCENE: PackedScene = preload("res://Scenes/Skater.tscn")
const PUCK_SCENE: PackedScene = preload("res://Scenes/Puck.tscn")
const DT: float = 1.0 / 120.0
const TICKS: int = 120
# Open ice, far from every board and both nets — the control run's start.
const OPEN_ICE := Vector3(0.0, 0.0, 0.0)
# The lean differs slightly between a run that hits the boards and one that
# doesn't, so the pose does too. Millimetres; the fault this pins added metres.
const SLOP: float = 0.02


class GameStateStub:
	extends Node

	func is_host() -> bool:
		return true

	func is_movement_locked() -> bool:
		return false


func _make_controller() -> SkaterController:
	var skater: Skater = SKATER_SCENE.instantiate() as Skater
	add_child_autofree(skater)
	skater.set_process(false)
	var puck: Puck = PUCK_SCENE.instantiate() as Puck
	add_child_autofree(puck)
	puck.set_physics_process(false)
	puck.global_position = Vector3(20.0, 0.0, 20.0)
	var gs := GameStateStub.new()
	add_child_autofree(gs)
	var controller := SkaterController.new()
	add_child_autofree(controller)
	controller.setup(skater, puck, gs)
	return controller


# Skate from `start` along `move`, then reverse straight back out — the repro: the
# pin only shows once the player leaves the thing that set it. `mode` picks the
# state posing the stick, since each one clamps its own way. Returns the longest
# shaft drawn over the run.
func _worst_shaft(c: SkaterController, start: Vector3, move: Vector2,
		cursor_deg: float, mode: String) -> float:
	var sk: Skater = c.skater
	sk.global_position = start
	sk.velocity = Vector3.ZERO
	sk.set_facing(move)
	c._ik.reset_blade_smoothing()
	sk.reseed_blade_history()
	var worst: float = 0.0
	var dir := Vector3(cos(deg_to_rad(cursor_deg)), 0.0, sin(deg_to_rad(cursor_deg)))
	for i: int in TICKS:
		sk.capture_prev_blade_contact()
		var input := InputState.new()
		input.delta = DT
		input.move_vector = move if i < TICKS / 2 else -move
		input.mouse_world_pos = sk.global_position + dir * 3.0
		input.mouse_world_pos.y = 0.0
		match mode:
			"wrister":
				input.shoot_pressed = (i == 30)
				input.shoot_held = i >= 30 and i < 50
			"slapper":
				input.slap_pressed = (i == 30)
				input.slap_held = i >= 30 and i < 60
			"block":
				input.block_held = i >= 30 and i < 70
		c._process_input(input, DT)
		sk._physics_process(DT)
		worst = maxf(worst,
				sk.get_top_hand_position().distance_to(sk.get_blade_position()))
	return worst


# The end zone's board perimeter over the z band where the net's own faces are
# also in reach of the stick — which is what turned a board pin into a net pin —
# plus the two spots where the cage itself is what the stick runs into: the goal
# mouth, and alongside the side twine.
const SPOTS: Array[Vector3] = [
	Vector3(12.0, 0.0, 20.0), Vector3(11.0, 0.0, 25.0), Vector3(9.0, 0.0, 28.0),
	Vector3(0.0, 0.0, 29.0), Vector3(0.0, 0.0, 26.65), Vector3(1.5, 0.0, 27.5)]
const MODES: Array[String] = ["skate", "wrister", "slapper", "block"]


func test_no_pose_ever_draws_a_shaft_longer_than_the_stick() -> void:
	var c := _make_controller()
	var worst: float = 0.0
	var where: String = ""
	for mode: String in MODES:
		for approach_deg: int in range(0, 360, 90):
			var move := Vector2(
					cos(deg_to_rad(approach_deg)), sin(deg_to_rad(approach_deg)))
			for cursor_deg: int in [0, 180]:
				for spot: Vector3 in SPOTS:
					var drawn: float = _worst_shaft(
							c, spot, move, float(cursor_deg), mode)
					if drawn > worst:
						worst = drawn
						where = "%s at %s approach=%d cursor=%d" % [
								mode, str(spot), approach_deg, cursor_deg]
	assert_lte(worst, c.stick_length + SLOP,
			"drew %.2f m of a %.2f m stick — %s" % [worst, c.stick_length, where])


func test_no_obstacle_ever_lengthens_the_drawn_stick() -> void:
	var c := _make_controller()
	var worst_excess: float = 0.0
	var where: String = ""
	for mode: String in MODES:
		for approach_deg: int in range(0, 360, 90):
			var move := Vector2(
					cos(deg_to_rad(approach_deg)), sin(deg_to_rad(approach_deg)))
			for cursor_deg: int in [0, 180]:
				# What this pose sequence draws with nothing in the way.
				var free: float = _worst_shaft(
						c, OPEN_ICE, move, float(cursor_deg), mode)
				for spot: Vector3 in SPOTS:
					var excess: float = _worst_shaft(
							c, spot, move, float(cursor_deg), mode) - free
					if excess > worst_excess:
						worst_excess = excess
						where = "%s at %s approach=%d cursor=%d (open ice drew %.2f)" % [
								mode, str(spot), approach_deg, cursor_deg, free]
	assert_lte(worst_excess, SLOP,
			"the boards and the net added %.2f m to the shaft — %s" % [worst_excess, where])
