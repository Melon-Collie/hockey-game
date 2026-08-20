extends GutTest

# The check-commit stance poses the HAND and lets the blade follow it down the
# shaft, and these are the checks that the pose the dials describe is the pose
# the rig actually holds.
#
# Blade-first did not survive contact with the geometry. A loaded blade tucked
# close sits deep inside TopHandIK's CLOSE regime, and CLOSE pins the hand's XZ
# at the shoulder marker — while the rendered arm roots at the shoulder the trunk
# texture has MOVED, which the commit's lean and load-up carry ~0.16 m forward.
# The arm ended up rooted in front of its own hand, and the forearm folded behind
# the upper arm to reach back to it.
#
# So: the hand is posed where a checker holds it, the blade is derived one
# (choked) stick along the loaded bearing, and the elbow falls out of a chord
# that finally points forward. The fold assertion below is the one that would
# have caught the original defect.

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


# The HAND is what the stance authors; the blade follows it down the shaft.
func test_the_loaded_hand_is_posed_where_the_stance_asks() -> void:
	for lefty: bool in [true, false]:
		var c: SkaterController = _committed(lefty, true)
		var side: float = -1.0 if lefty else 1.0
		var hand: Vector3 = c.skater.top_hand.position
		var label: String = "lefty" if lefty else "righty"
		# Looser on x than the others: the wall/net clamps run after the pose and
		# the rigid-stick correction slides the hand along the shaft to pay for
		# them, which shows up as a couple of centimetres across the body.
		assert_almost_eq(hand.x, c.hit_commit_hand_local_x * side, 0.05,
				"%s: the loaded hand sits where it is posed (x)" % label)
		assert_almost_eq(hand.y, c.hit_commit_hand_local_y, 0.02,
				"%s: the loaded hand sits where it is posed (y)" % label)
		assert_almost_eq(hand.z, c.hit_commit_hand_local_z, 0.02,
				"%s: the loaded hand sits where it is posed (z)" % label)


func test_the_hand_stays_off_its_ceiling() -> void:
	# The blade-first solve used to park the hand AT hand_y_max, which is what
	# folded the elbow backwards. Posed, it sits wherever the stance says — and
	# that has to be somewhere the arm can actually hold.
	for lefty: bool in [true, false]:
		var c: SkaterController = _committed(lefty, true)
		assert_lt(c.skater.top_hand.position.y, c.hand_y_max - 0.03,
				"%s: the top hand has headroom under its ROM ceiling"
						% ["lefty" if lefty else "righty"])


# The defect this whole pose rework exists for: the forearm folding behind the
# upper arm. An elbow is a hinge, so the fold has to open toward the FRONT.
func test_the_forearm_folds_forward_not_backward() -> void:
	for lefty: bool in [true, false]:
		var c: SkaterController = _committed(lefty, true)
		var skater: Skater = c.skater
		var root: Vector3 = skater._arms._textured_shoulder(skater.shoulder.position)
		var hand: Vector3 = skater.top_hand.position
		var pole: Vector3 = skater.arm_pole_local
		pole.x *= 1.0 if lefty else -1.0
		pole = CheckStanceRules.tucked_pole(pole, CheckStanceRules.side_load(
				skater.get_check_lead(), signf(skater.shoulder.position.x)))
		var elbow: Vector3 = skater.upper_body.to_local(TwoBoneIK.solve_elbow(
				skater.upper_body.to_global(root), skater.upper_body.to_global(hand),
				skater.upper_arm_length, skater.forearm_length,
				skater.upper_body.global_transform.basis * pole))
		var upper: Vector3 = (elbow - root).normalized()
		var fore: Vector3 = (hand - elbow).normalized()
		var fold: Vector3 = fore - upper * fore.dot(upper)
		var label: String = "lefty" if lefty else "righty"
		assert_lt(fold.z, 0.0,
				"%s: the forearm folds in FRONT of the upper arm, not behind it" % label)
		# And it is a real bend rather than a doubled-over one.
		var flex: float = 180.0 - rad_to_deg(acos(clampf(upper.dot(fore), -1.0, 1.0)))
		assert_between(flex, 60.0, 150.0,
				"%s: the elbow holds a natural bend (got %.0f deg)" % [label, flex])


func test_the_choke_shortens_the_grip_not_the_stick() -> void:
	# The shaft is drawn hand→blade plus the butt overhang, so a choke that the
	# butt did not absorb would render as a shorter STICK. Same skater, same
	# stick: the drawn length must not move.
	var loose: SkaterController = _committed(true, false)
	var choked: SkaterController = _committed(true, true)
	assert_gt(choked.skater.grip_choke(), 0.1,
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
