extends GutTest

# The check-commit stance authors a loaded blade position — and for a long time
# nothing checked that the arm could actually put the blade there.
#
# It could not. A raised blade eats the hand-to-blade drop, and the stick's
# horizontal projection is sqrt(stick² − drop²), so raising the blade pushes its
# nearest reachable point FURTHER out. At full stick length the blade could not
# come closer than ~0.92 m to the shoulder while the pose asked for ~0.53 m.
# TopHandIK does not fail loudly on that: it pins the hand at hand_y_max and
# overshoots the target ALONG THE AIM LINE, so the dials silently degraded from
# a position to a direction, and the hand parked above the shoulder with the
# elbow swinging beneath it.
#
# SkaterController.hit_commit_choke_frac is the term that makes the pose
# reachable. These tests are the check that was missing: the blade lands where
# it is authored, the hand stays off its ceiling, and the choke never turns into
# a shorter STICK — only a shorter grip.

const SKATER_SCENE: PackedScene = preload("res://Scenes/Skater.tscn")
const PUCK_SCENE: PackedScene = preload("res://Scenes/Puck.tscn")
const DT: float = 1.0 / 120.0
# Long enough for the commit-lift ease (9/s) and the lead ease (5/s) to converge.
const TICKS: int = 90


class GameStateStub:
	extends Node

	func is_host() -> bool:
		return true

	func is_movement_locked() -> bool:
		return false


func _committed(lefty: bool, hit: bool) -> SkaterController:
	var skater: Skater = SKATER_SCENE.instantiate() as Skater
	skater.is_left_handed = lefty
	add_child_autofree(skater)
	# Standing height, as the spawner leaves them. blade_y_local() is measured
	# DOWN from the upper body, so a skater left at y = 0 is sunk into the ice and
	# every reach the solver computes from that drop is meaningless.
	skater.global_position = Vector3(0.0, GameRules.FACEOFF_SPAWN_HEIGHT, 0.0)
	skater.set_process(false)
	skater.set_physics_process(false)
	var puck: Puck = PUCK_SCENE.instantiate() as Puck
	add_child_autofree(puck)
	puck.set_physics_process(false)
	puck.global_position = Vector3(30.0, 0.0, 30.0)
	var gs := GameStateStub.new()
	add_child_autofree(gs)
	var controller := SkaterController.new()
	add_child_autofree(controller)
	controller.setup(skater, puck, gs)
	# Every spawn path applies attributes (ActorSpawner falls back to
	# all_average), and that is where the choke lands in metres — a controller
	# without it is not a skater the game can produce.
	controller.apply_attributes(PlayerAttributes.all_average())

	var input := InputState.new()
	for _i: int in TICKS:
		input.delta = DT
		input.host_timestamp += DT
		input.move_vector = Vector2(0.0, -1.0)
		input.mouse_world_pos = skater.global_position + Vector3(0.0, 0.0, -3.0)
		input.hit_held = hit
		controller._process_input(input, DT)
		skater._physics_process(DT)
		skater._process(DT)
	return controller


# Where the stance ASKS for the blade, in upper-body-local XZ.
func _authored_blade(c: SkaterController) -> Vector2:
	var skater: Skater = c.skater
	var side: float = -1.0 if skater.is_left_handed else 1.0
	return Vector2(
			c.hit_commit_blade_local_x * side
					- skater.get_check_lead() * c.hit_commit_blade_sweep_m,
			c.hit_commit_blade_local_z)


func test_the_loaded_blade_is_actually_reached() -> void:
	for lefty: bool in [true, false]:
		var c: SkaterController = _committed(lefty, true)
		var blade: Vector3 = c.skater.blade.position
		var want: Vector2 = _authored_blade(c)
		assert_almost_eq(blade.x, want.x, 0.02,
				"%s: the blade lands where the stance authored it (x)"
						% ["lefty" if lefty else "righty"])
		assert_almost_eq(blade.z, want.y, 0.02,
				"%s: the blade lands where the stance authored it (z)"
						% ["lefty" if lefty else "righty"])


func test_the_hand_stays_off_its_ceiling() -> void:
	# hand_y_max is the symptom the overshoot showed up as: pinned there, the
	# solve has no way left to shorten the stick's reach and gives up on the
	# target. Off it, the pose has room in both directions.
	for lefty: bool in [true, false]:
		var c: SkaterController = _committed(lefty, true)
		assert_lt(c.skater.top_hand.position.y, c.hand_y_max - 0.03,
				"%s: the top hand has headroom under its ROM ceiling"
						% ["lefty" if lefty else "righty"])


func test_the_choke_shortens_the_grip_not_the_stick() -> void:
	# The shaft is drawn hand→blade plus the butt overhang, so a choke that the
	# butt did not absorb would render as a shorter STICK. Same skater, same
	# stick: the drawn length must not move.
	var loose: SkaterController = _committed(true, false)
	var choked: SkaterController = _committed(true, true)
	assert_gt(choked.skater.grip_choke(), 0.2,
			"the commit really is choking up — otherwise this proves nothing")
	assert_eq(loose.skater.grip_choke(), 0.0, "and an uncommitted skater is not")
	var loose_len: float = loose.skater.stick_mesh.scale.z
	var choked_len: float = choked.skater.stick_mesh.scale.z
	assert_almost_eq(choked_len, loose_len, 0.01,
			"the drawn shaft keeps its length — the butt gives back what the grip took")


# The shaft is drawn hand→blade, so if the solve ever produced a pair further
# apart than the length it solved with, the stick would visibly come off the
# blade. The choke changes that length mid-pose, which is exactly when a stale
# copy of it would show up.
func test_the_stick_stays_rigid_through_the_choke() -> void:
	for hit: bool in [true, false]:
		var c: SkaterController = _committed(true, hit)
		var span: float = c.skater.top_hand.position.distance_to(c.skater.blade.position)
		assert_almost_eq(span, c._ik.solve_stick_length(), 0.005,
				"committed=%s: hand and blade stay one stick apart" % hit)


func test_the_choke_is_off_outside_a_commit() -> void:
	var c: SkaterController = _committed(true, false)
	assert_eq(c.skater.grip_choke(), 0.0, "no choke without the Hit button")
	assert_almost_eq(c._ik.solve_stick_length(), c.stick_length, 1e-6,
			"and every solve runs on the full stick")


func test_the_choke_scales_with_the_build() -> void:
	# It is a fraction of the skater's OWN stick, so a bigger build chokes by
	# more metres and by the same proportion.
	var c: SkaterController = _committed(true, true)
	assert_almost_eq(c.skater.commit_grip_choke_m,
			c.stick_length * c.hit_commit_choke_frac, 1e-6,
			"the metres come from this skater's stick, not a global constant")
