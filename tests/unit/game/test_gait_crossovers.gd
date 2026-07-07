extends GutTest

# Crossover gait — three behaviors pinned:
#  1. Cadence follows the ARC while carving: stride frequency during a real
#     turn is crossover_phase_per_turn × turn rate, not the straight-line
#     speed law — a tight turn quickens the feet, a wide arc glides.
#  2. Backward turning is gated out: a defender curling backward keeps C-cuts
#     on the speed law (forward crossover roles mirror wrong through the flip).
#  3. Two-beat rhythm: the over-step and the under-push ride OPPOSITE halves
#     of the stride cycle (push-push around the corner), not the same half.

const SKATER_SCENE: PackedScene = preload("res://Scenes/Skater.tscn")
const DT: float = 1.0 / 120.0
const WARMUP_TICKS: int = 300
const MEASURE_TICKS: int = 240
const SPEED: float = 5.0
const TURN_RATE: float = 1.6  # rad/s — exactly carve_ref_turn_rate: a full carve


class Rig:
	var skater: Skater
	var controller: SkaterController
	var coord: SkaterSkatingCoordinator
	var travel: Vector2  # unit travel direction, rotated per tick when turning
	var backward: bool = false


func _make_rig(backward: bool) -> Rig:
	var rig := Rig.new()
	rig.skater = SKATER_SCENE.instantiate() as Skater
	add_child_autofree(rig.skater)
	rig.skater.set_physics_process(false)
	rig.skater.set_process(false)
	rig.controller = SkaterController.new()
	autofree(rig.controller)
	var sm := SkaterStateMachine.new()
	rig.coord = SkaterSkatingCoordinator.new()
	rig.coord.setup(rig.skater, sm, rig.controller)
	rig.travel = Vector2(0.0, -1.0)
	rig.backward = backward
	return rig


# One tick of steady circular (or straight, turn = 0) travel. Positive turn
# rotates travel toward +X — the skater's right when facing along travel — so
# carve > 0 (left leg over, right leg under-pushes).
func _tick(rig: Rig, turn: float) -> void:
	rig.travel = rig.travel.rotated(turn * DT)
	var facing: Vector2 = -rig.travel if rig.backward else rig.travel
	rig.skater.set_facing(facing)
	rig.skater.velocity = Vector3(rig.travel.x, 0.0, rig.travel.y) * SPEED
	rig.skater.move_intent = rig.travel
	rig.coord.apply(DT)


# Mean stride-phase advance rate (rad/s) over MEASURE_TICKS of steady motion.
func _phase_rate(rig: Rig, turn: float) -> float:
	for _i: int in WARMUP_TICKS:
		_tick(rig, turn)
	var prev: float = rig.coord.stride_phase
	var advanced: float = 0.0
	for _i: int in MEASURE_TICKS:
		_tick(rig, turn)
		advanced += wrapf(rig.coord.stride_phase - prev, -PI, PI)
		prev = rig.coord.stride_phase
	return advanced / (MEASURE_TICKS * DT)


func test_carve_cadence_follows_turn_rate() -> void:
	var straight_rig: Rig = _make_rig(false)
	var straight: float = _phase_rate(straight_rig, 0.0)
	var carving: float = _phase_rate(_make_rig(false), TURN_RATE)
	var turn_law: float = TURN_RATE * straight_rig.controller.crossover_phase_per_turn
	gut.p("phase rate — straight %.2f, full carve %.2f (turn law %.2f) rad/s"
			% [straight, carving, turn_law])
	assert_lt(straight, 6.5, "straight cruise must stay on the speed law")
	assert_gt(carving, 9.0, "a full carve must re-time the feet to the arc")
	assert_almost_eq(carving, turn_law, 1.5,
			"carve cadence should approximate crossover_phase_per_turn × turn rate")


func test_backward_turning_keeps_speed_law() -> void:
	var back_turning: float = _phase_rate(_make_rig(true), TURN_RATE)
	gut.p("backward-turn phase rate %.2f rad/s" % back_turning)
	assert_lt(back_turning, 6.5,
			"backward turning must not adopt the crossover cadence (forward gate)")


func test_crossover_strokes_alternate() -> void:
	# Full right carve: left leg's over-step roll peaks on one half of the
	# cycle, the right leg's under-push trough on the other — separated by well
	# over a quarter cycle. (The old simultaneous strokes put both at the same
	# phase.)
	var rig: Rig = _make_rig(false)
	var leg_l: Node3D = rig.skater.get_node("MeshRoot/LowerBody/LegL") as Node3D
	var leg_r: Node3D = rig.skater.get_node("MeshRoot/LowerBody/LegR") as Node3D
	for _i: int in WARMUP_TICKS:
		_tick(rig, TURN_RATE)
	var best_l: float = -INF
	var best_l_phase: float = 0.0
	var worst_r: float = INF
	var worst_r_phase: float = 0.0
	for _i: int in MEASURE_TICKS:
		_tick(rig, TURN_RATE)
		if leg_l.rotation.z > best_l:
			best_l = leg_l.rotation.z
			best_l_phase = rig.coord.stride_phase
		if leg_r.rotation.z < worst_r:
			worst_r = leg_r.rotation.z
			worst_r_phase = rig.coord.stride_phase
	var separation: float = absf(wrapf(best_l_phase - worst_r_phase, -PI, PI))
	gut.p("over-step peak at phase %.2f, under-push trough at %.2f — separation %.2f rad"
			% [best_l_phase, worst_r_phase, separation])
	assert_gt(separation, 1.5,
			"over-step and under-push must ride opposite halves of the stride cycle")
