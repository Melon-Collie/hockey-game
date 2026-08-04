extends GutTest

# The pivot read end-to-end through SkaterSkatingCoordinator: a cursor swing
# across a held travel line must hold the hips past the normal alignment clamp
# (the open-hip transit), then settle square once the swing completes — while
# a coordinated carve (facing and travel rotating together) never trips the
# read. Facing and velocity are driven directly; the read derives from
# replicated state only.

const SKATER_SCENE: PackedScene = preload("res://Scenes/Skater.tscn")
const DT: float = 1.0 / 120.0

var _skater: Skater = null
var _controller: SkaterController = null
var _coord: SkaterSkatingCoordinator = null


func before_each() -> void:
	_skater = SKATER_SCENE.instantiate() as Skater
	add_child_autofree(_skater)
	_skater.set_physics_process(false)
	_skater.set_process(false)
	_controller = SkaterController.new()
	autofree(_controller)
	var sm := SkaterStateMachine.new()
	_coord = SkaterSkatingCoordinator.new()
	_coord.setup(_skater, sm, _controller)
	_skater.velocity = Vector3(0.0, 0.0, -6.0)
	_skater.move_intent = Vector2.ZERO
	_skater.set_facing(Vector2(0.0, -1.0))


func test_cursor_swing_holds_hips_past_the_clamp_then_settles() -> void:
	for _i: int in 30:
		_coord.apply(DT)
	# Swing facing to ψ = 100° over 0.4 s, then hold — the open-hip glide.
	for i: int in 48:
		var a: float = deg_to_rad(100.0) * float(i + 1) / 48.0
		_skater.set_facing(Vector2(sin(a), -cos(a)).normalized())
		_coord.apply(DT)
	for _i: int in 60:
		_coord.apply(DT)
	var clamp_rad: float = deg_to_rad(_controller.hip_align_max_deg)
	assert_gt(absf(_coord.travel_align_yaw), clamp_rad + deg_to_rad(20.0),
			"the transit should hold the hips on the old travel line, well past "
			+ "the alignment clamp (held %.1f°)" % rad_to_deg(absf(_coord.travel_align_yaw)))
	# Complete the swing to ψ = 180° — the step-around — and let it settle.
	for i: int in 36:
		var a: float = deg_to_rad(100.0 + 80.0 * float(i + 1) / 36.0)
		_skater.set_facing(Vector2(sin(a), -cos(a)).normalized())
		_coord.apply(DT)
	for _i: int in 120:
		_coord.apply(DT)
	assert_lt(absf(_coord.travel_align_yaw), deg_to_rad(15.0),
			"after the step-around the hips should settle square under the torso "
			+ "(%.1f°)" % rad_to_deg(absf(_coord.travel_align_yaw)))


func test_coordinated_carve_does_not_trip_the_pivot() -> void:
	for _i: int in 30:
		_coord.apply(DT)
	# Rotate travel AND facing together at 2 rad/s — a hard carve: ψ stays ~0.
	for i: int in 120:
		var a: float = 2.0 * DT * float(i + 1)
		var dir := Vector2(sin(a), -cos(a))
		_skater.velocity = Vector3(dir.x, 0.0, dir.y) * 6.0
		_skater.set_facing(dir)
		_coord.apply(DT)
	assert_almost_eq(_coord._pivot_blend, 0.0, 0.05,
			"facing and travel rotating together is a carve, not a pivot")
