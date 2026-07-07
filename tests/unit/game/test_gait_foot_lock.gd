extends GutTest

# Foot lock — the conveyor must reduce the skate's WORLD-frame fore-aft slip
# during the push versus the pure-FK gait. The FK stride swings each leg about
# the hip in the body frame with no coupling to the ice, so a planted skate
# slides across the ice as the body translates ("moonwalk"). The conveyor drives
# the pushing foot backward (toward world-locked) so the drive comes off a
# gripping edge instead of a sliding one. This pins that the mechanism works;
# the shipped defaults (foot_lock_blend 0.6) are conservative and tuned by feel.

const SKATER_SCENE: PackedScene = preload("res://Scenes/Skater.tscn")
const DT: float = 1.0 / 120.0
const WARMUP_TICKS: int = 240
const MEASURE_TICKS: int = 480
const THIGH_LEN: float = 0.31
const SHIN_LEN: float = 0.45
const SPEED: float = 3.0


# Foot's forward (−Z body frame) offset from the hip — same model as
# test_gait_stroke_profile and LegIKRules.
func _foot_forward(pitch: float, knee: float) -> float:
	return THIGH_LEN * sin(pitch) + SHIN_LEN * sin(pitch + knee)


# Runs a steady cruise straight up-ice and returns, per foot, the minimum
# instantaneous WORLD-frame fore-aft foot speed over the window — the most
# "planted" moment. world_speed = ground_speed + d(foot_forward)/dt.
func _min_world_foot_speed(configure: Callable) -> float:
	var skater: Skater = SKATER_SCENE.instantiate() as Skater
	add_child_autofree(skater)
	skater.set_physics_process(false)
	skater.set_process(false)
	var controller: SkaterController = SkaterController.new()
	autofree(controller)
	configure.call(controller)
	var sm := SkaterStateMachine.new()
	var coord := SkaterSkatingCoordinator.new()
	coord.setup(skater, sm, controller)
	skater.set_facing(Vector2(0.0, -1.0))
	skater.velocity = Vector3(0.0, 0.0, -SPEED)
	skater.move_intent = Vector2(0.0, -1.0)

	var leg_l: Node3D = skater.get_node("MeshRoot/LowerBody/LegL") as Node3D
	var shin_l: Node3D = skater.get_node("MeshRoot/LowerBody/LegL/ShinL") as Node3D

	for _i: int in WARMUP_TICKS:
		coord.apply(DT)
	var prev_ff: float = _foot_forward(leg_l.rotation.x, shin_l.rotation.x)
	var min_world: float = INF
	for _i: int in MEASURE_TICKS:
		coord.apply(DT)
		var ff: float = _foot_forward(leg_l.rotation.x, shin_l.rotation.x)
		# Planted skate falling behind the body: d(ff)/dt = −SPEED ⇒ world ≈ 0.
		var world_v: float = SPEED + (ff - prev_ff) / DT
		min_world = minf(min_world, absf(world_v))
		prev_ff = ff
	return min_world


func test_foot_lock_reduces_world_slip() -> void:
	var fk: float = _min_world_foot_speed(func(c: SkaterController) -> void:
		c.foot_lock_blend = 0.0)
	# Strong-lock config so the test exercises the mechanism, not the defaults.
	var locked: float = _min_world_foot_speed(func(c: SkaterController) -> void:
		c.foot_lock_blend = 1.0
		c.foot_lock_push_frac = 0.2
		c.foot_lock_reach_max = 0.3
		c.foot_lock_stride_gain = 0.2)
	gut.p("min world foot speed — FK %.2f m/s, locked %.2f m/s (ground %.1f)"
			% [fk, locked, SPEED])
	assert_lt(locked, fk, "the lock must plant the foot harder than the FK gait")
	assert_lt(locked, 0.5 * SPEED,
			"the pushing foot should approach planted (well under ground speed)")
