extends GutTest

# ── Movement + puck-step GDScript-vs-native micro-benchmark (report-only; NOT
# in the default suite) ─ Times the two per-tick physics kernels against their
# C++ ports (NativeSkaterMovement / NativePuckStep, native/src/). The batched
# rows are the point: integrate_forward and step_tick loop N iterations behind
# ONE boundary crossing, which is where the reconcile-replay and client
# re-predict multipliers live.
#
# Run explicitly:
#   bash .claude/hooks/run-gut.sh -gdir=res://benchmarks
#
# Compare RELATIVELY within one run. Goes pending when the extension isn't
# built.

const REPS: int = 20000
const DELTA: float = 1.0 / 120.0

var _results: Array[Dictionary] = []
var _bench_roots: Array[Node3D] = []


func _report(label: String, gd_usec: int, nat_usec: int, reps: int) -> void:
	_results.append({
		"label": label,
		"gd_us": float(gd_usec) / float(reps),
		"nat_us": float(nat_usec) / float(reps),
	})


func _print_results(title: String) -> void:
	var widest: int = 0
	for r: Dictionary in _results:
		widest = maxi(widest, (r["label"] as String).length())
	gut.p("")
	gut.p("── %s (µs/call) ──" % title)
	gut.p("  %s  %10s  %10s  %8s" % ["case".rpad(widest), "GDScript", "native", "speedup"])
	for r: Dictionary in _results:
		gut.p("  %s  %10.2f  %10.2f  %7.1fx" % [
				(r["label"] as String).rpad(widest), r["gd_us"], r["nat_us"],
				(r["gd_us"] as float) / maxf(r["nat_us"] as float, 0.001)])
	gut.p("")


func _movement_cfg() -> SkaterMovementRules.MovementConfig:
	var cfg := SkaterMovementRules.MovementConfig.new()
	cfg.thrust = 18.0
	cfg.friction = 3.0
	cfg.max_speed = 8.5
	cfg.move_deadzone = 0.1
	cfg.brake_multiplier = 3.0
	cfg.puck_carry_speed_multiplier = 0.9
	cfg.backward_thrust_multiplier = 0.5
	cfg.crossover_thrust_multiplier = 0.7
	cfg.friction_drag = 0.2
	cfg.sprint_thrust_multiplier = 1.2
	cfg.sprint_max_speed_multiplier = 1.25
	cfg.sprint_carry_penalty_bypass = 0.7
	cfg.lateral_grip = 0.85
	return cfg


func test_movement_gdscript_vs_native() -> void:
	if not ClassDB.class_exists(&"NativeSkaterMovement"):
		pending("native extension not built — see native/README.md")
		return
	_results.clear()
	var cfg: SkaterMovementRules.MovementConfig = _movement_cfg()
	var native: RefCounted = ClassDB.instantiate(&"NativeSkaterMovement")
	native.configure(cfg)
	native.set_stagger_params(1.0, 0.5)
	var result := SkaterMovementRules.ForwardResult.new()
	var vel := Vector3(3.0, 0.0, -4.0)
	var input := Vector2(0.4, -0.9)

	var t0: int = Time.get_ticks_usec()
	for _i: int in REPS:
		var _v: Vector3 = SkaterMovementRules.apply_movement(
				vel, input, 0.3, true, false, DELTA, cfg, false)
	var gd_us: int = Time.get_ticks_usec() - t0
	t0 = Time.get_ticks_usec()
	for _i: int in REPS:
		var _v: Vector3 = native.apply_movement(vel, input, 0.3, true, false, DELTA, false)
	_report("apply_movement (1 tick)", gd_us, Time.get_ticks_usec() - t0, REPS)

	for spec: Array in [[24, 500], [240, 100]]:
		var ticks: int = spec[0]
		var reps: int = spec[1]
		t0 = Time.get_ticks_usec()
		for _i: int in reps:
			SkaterMovementRules.integrate_forward(Vector3.ZERO, vel, input, 0.3,
					false, false, false, cfg, DELTA, ticks, 30, result, 0.4, null)
		gd_us = Time.get_ticks_usec() - t0
		t0 = Time.get_ticks_usec()
		for _i: int in reps:
			native.integrate_forward(Vector3.ZERO, vel, input, 0.3,
					false, false, false, DELTA, ticks, 30, 0.4, false)
		_report("integrate_forward %d ticks (batched)" % ticks,
				gd_us, Time.get_ticks_usec() - t0, reps)

	_print_results("Skater movement")
	assert_true(_results.size() == 3, "benchmark produced rows")


func test_puck_step_gdscript_vs_native() -> void:
	if not ClassDB.class_exists(&"NativePuckStep"):
		pending("native extension not built — see native/README.md")
		return
	_results.clear()
	var native: RefCounted = ClassDB.instantiate(&"NativePuckStep")
	native.set_rink_geometry(GameRules.INNER_HALF_WIDTH, GameRules.INNER_HALF_LENGTH,
			GameRules.INNER_CORNER_RADIUS, GameRules.CORNER_CENTER_X, GameRules.CORNER_CENTER_Z)
	native.set_puck_params(GameRules.PUCK_BOARD_BOUNCE, GameRules.PUCK_BOARD_FRICTION,
			GameRules.PUCK_ICE_DECEL_M_S2, GameRules.GRAVITY_M_S2, AITrajectory.PUCK_REST_HEIGHT_M)
	native.set_net_geometry(GameRules.GOAL_LINE_Z, GameRules.NET_HALF_WIDTH,
			GameRules.NET_POST_RADIUS, GameRules.NET_DEPTH, GameRules.NET_BACK_HALF_WIDTH,
			GameRules.NET_HEIGHT, GameRules.NET_CROWN_HALF_WIDTH, GameRules.NET_TOP_DEPTH,
			GameRules.PUCK_COLLISION_HALF_HEIGHT,
			PuckGeometryCollision.POST_RESTITUTION, PuckGeometryCollision.NET_RESTITUTION)
	native.set_substep_params(PuckAuthorityRules.FRAME_SUBSTEP_RANGE_Z,
			PuckAuthorityRules.FRAME_SUBSTEP_M, PuckAuthorityRules.MAX_FRAME_SUBSTEPS)
	var scratch := PuckGeometryCollision.Result.new()
	var out := PuckAuthorityRules.TickResult.new()
	var radius: float = GameRules.PUCK_COLLISION_RADIUS

	# Open ice: 1 sub-step per tick. Near net at pace: the full 16-sub-step tick
	# — the case the client re-predict loop pays dozens of times per frame.
	for spec: Array in [
			["open ice (1 substep)", Vector3(0.0, 0.0175, 0.0), Vector3(8.0, 0.0, 6.0), REPS],
			["near net fast (16 substeps)", Vector3(0.5, 0.0175, 25.9), Vector3(4.0, 0.0, 30.0), 4000],
		]:
		var pos: Vector3 = spec[1]
		var vel: Vector3 = spec[2]
		var reps: int = spec[3]
		var t0: int = Time.get_ticks_usec()
		for _i: int in reps:
			var n: int = PuckAuthorityRules.frame_substeps(pos.z, vel.length(), DELTA)
			var sub_dt: float = DELTA / float(n)
			out.touched_post = false
			out.touched_net = false
			var gp: Vector3 = pos
			var gv: Vector3 = vel
			for _s: int in n:
				PuckAuthorityRules.step_frame_substep(gp, gv, sub_dt, radius,
						38.0, 0.0175, 3.0, scratch, out)
				gp = out.position
				gv = out.velocity
		var gd_us: int = Time.get_ticks_usec() - t0
		t0 = Time.get_ticks_usec()
		for _i: int in reps:
			native.clear_touched()
			native.step_tick(pos, vel, DELTA, radius, 38.0, 0.0175, 3.0)
			var _p: Vector3 = native.get_position()
			var _v: Vector3 = native.get_velocity()
		_report(spec[0] as String, gd_us, Time.get_ticks_usec() - t0, reps)

	# Swept-disc OBB contact — the goalie-part test the near-net tick multiplies.
	var xform := Transform3D(Basis.from_euler(Vector3(0.1, 0.4, 0.0)), Vector3(0.3, 0.4, 25.8))
	var half := Vector3(0.15, 0.4, 0.2)
	var prev := Vector3(0.0, 0.1, 25.0)
	var curr := Vector3(0.4, 0.15, 26.2)
	var obb_result := SweptDiscOBB.Result.new()
	var t0b: int = Time.get_ticks_usec()
	for _i: int in REPS:
		var _hit: bool = SweptDiscOBB.contact(prev, curr, 0.065, xform, half, obb_result)
	var gd_us_b: int = Time.get_ticks_usec() - t0b
	t0b = Time.get_ticks_usec()
	for _i: int in REPS:
		var _hit: bool = native.obb_contact(prev, curr, 0.065, xform, half)
	_report("swept-disc OBB contact", gd_us_b, Time.get_ticks_usec() - t0b, REPS)

	_print_results("Loose-puck step")
	assert_true(_results.size() == 3, "benchmark produced rows")


# The near-net goalie-contact interleave at live scale: 2 goalies x 7 box
# parts, 16 sub-step tests per tick. Legacy re-reads engine properties per
# part per sub-step; the native path gathers once per tick and runs the slab
# loop natively per sub-step.
func test_goalie_contact_gather_vs_legacy() -> void:
	if not GoalieContactDetector.native_available():
		pending("native extension not built — see native/README.md")
		return
	_results.clear()
	var goalies: Array = []
	for g: int in 2:
		var root := Node3D.new()
		add_child(root)
		_bench_roots.append(root)
		root.global_position = Vector3(0.4 - 0.8 * g, 0.0, 25.3)
		for p: int in 7:
			var body := StaticBody3D.new()
			root.add_child(body)
			body.position = Vector3(0.15 * (p - 3), 0.2 * p, 0.05 * (p - 3))
			var cs := CollisionShape3D.new()
			var box := BoxShape3D.new()
			box.size = Vector3(0.25, 0.5, 0.2)
			cs.shape = box
			body.add_child(cs)
	var scratch := SweptDiscOBB.Result.new()
	var contact := GoalieContactDetector.Contact.new()
	var packed := PackedFloat32Array()
	var parts: Array = []
	var part_goalies: Array = []
	var prev := Vector3(0.1, 0.1, 24.9)
	var curr := Vector3(0.15, 0.12, 25.05)
	var ticks: int = 2000

	var t0: int = Time.get_ticks_usec()
	for _t: int in ticks:
		for _s: int in 16:
			var _hit: bool = GoalieContactDetector.nearest(
					goalies, prev, curr, 0.065, scratch, contact)
	var gd_us: int = Time.get_ticks_usec() - t0

	t0 = Time.get_ticks_usec()
	for _t: int in ticks:
		var count: int = GoalieContactDetector.gather_boxes(
				goalies, packed, parts, part_goalies)
		for _s: int in 16:
			var _hit: bool = GoalieContactDetector.nearest_packed(
					packed, count, parts, part_goalies, prev, curr, 0.065, contact)
	_report("goalie contact tick (16 substeps)", gd_us, Time.get_ticks_usec() - t0, ticks)

	for r: Node3D in _bench_roots:
		r.free()
	_bench_roots.clear()
	_print_results("Near-net goalie interleave")
	assert_true(_results.size() == 1, "benchmark produced rows")
