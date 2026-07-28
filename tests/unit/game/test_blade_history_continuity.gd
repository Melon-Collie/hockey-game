extends GutTest

# Blade history across a discontinuity. The host's pickup / poke tests sweep the
# segment (prev blade contact → current blade contact) and the faceoff draw reads
# blade_world_velocity, both first differences of anchors Skater keeps. If either
# anchor survives a teleport — faceoff staging, respawn, slot swap — the host sees
# a blade that covered the whole jump in one tick: a segment sweeping the rink
# (a skater across the ice corrals the puck off the drop) and a "swipe" of
# thousands of m/s feeding the draw's retained crest.

const SKATER_SCENE: PackedScene = preload("res://Scenes/Skater.tscn")
const PUCK_SCENE: PackedScene = preload("res://Scenes/Puck.tscn")
const DT: float = 1.0 / 120.0
# The kind of jump a post-goal faceoff staging makes: end zone to center ice.
const FAR: Vector3 = Vector3(0.0, 1.0, -40.0)
const NEAR: Vector3 = Vector3(0.0, 1.0, 0.0)


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


# Settle the anchors at the starting pose the way a live tick would, so the jump
# under test is the only discontinuity in the histories.
func _settle(skater: Skater, at: Vector3) -> void:
	skater.global_position = at
	skater.capture_prev_blade_contact()
	skater.reseed_blade_history()


func test_teleport_leaves_prev_blade_contact_at_the_new_pose() -> void:
	var c := _make_controller()
	_settle(c.skater, FAR)
	var before: Vector3 = c.skater.get_prev_blade_contact_global()
	c.teleport_to(NEAR, Vector2(0.0, -1.0))
	var after: Vector3 = c.skater.get_prev_blade_contact_global()
	assert_gt(before.distance_to(after), 10.0,
			"the prev anchor moved with the body — it did not survive the jump")
	assert_lt(after.distance_to(c.skater.get_blade_contact_global()), 0.01,
			"prev blade contact re-anchored to where the stick actually is now")


func test_teleport_does_not_report_a_blade_velocity_across_the_jump() -> void:
	var c := _make_controller()
	_settle(c.skater, FAR)
	c.teleport_to(NEAR, Vector2(0.0, -1.0))
	# The tick after the jump differences the anchors. Without the reseed this
	# reads ~40 m / (1/120 s) ≈ 4800 m/s.
	c.skater._physics_process(DT)
	assert_lt(c.skater.blade_world_velocity.length(), 1.0,
			"blade velocity is measured within a tick, never across a teleport")


# The draw's retained crest is a decaying PEAK, so a single corrupt tick poisons
# the whole faceoff: the contest heading would come from the staging jump rather
# than from anyone's swipe. Mirrors PhaseCoordinator._enter_faceoff_prep, which
# arms the tracking and then relocates the centers.
func test_faceoff_draw_crest_ignores_the_staging_jump() -> void:
	var c := _make_controller()
	_settle(c.skater, FAR)
	c.skater.begin_draw_tracking(c.faceoff_draw_peak_decay, c.faceoff_draw_window)
	c.teleport_to(NEAR, Vector2(0.0, -1.0))
	c.skater._physics_process(DT)
	assert_lt(c.skater.draw_peak_velocity().length(), 1.0,
			"the retained swipe crest is a real swing, not the relocation")
