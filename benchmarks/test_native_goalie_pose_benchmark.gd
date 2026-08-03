extends GutTest

# ── Goalie pose GDScript-vs-native micro-benchmark (report-only; NOT in the
# default suite) ─ Times GoalieBodyConfigBuilder.build against the C++ port
# (NativeGoalieBodyPose, native/src/) across representative states. The native
# rows include the full per-call boundary price: the 25-arg build call plus
# all 12 Vector3 output getters.
#
# Context: the pose solve is ~30% of the goalie tick (33 µs of 111 µs,
# benchmarks/test_goalie_micro_benchmark.gd), and the goalie is the most
# expensive actor per capita on the host tick.
#
# Run explicitly:
#   bash .claude/hooks/run-gut.sh -gdir=res://benchmarks
#
# Compare RELATIVELY within one run. Goes pending when the extension isn't
# built.

const State = GoalieStateMachine.State
const REPS: int = 20000

const F_REACTING_TO_SHOT: int = 2
const F_SHOT_IS_ELEVATED: int = 4
const F_PRELEAN_ACTIVE: int = 128

var _results: Array[Dictionary] = []
var _gd: GoalieBodyConfigBuilder = null
var _inputs: GoalieBodyConfigBuilder.Inputs = null
var _controller: GoalieController = null
var _native: RefCounted = null


func before_all() -> void:
	if not ClassDB.class_exists(&"NativeGoalieBodyPose"):
		return
	_controller = GoalieController.new()
	_gd = GoalieBodyConfigBuilder.new()
	_native = ClassDB.instantiate(&"NativeGoalieBodyPose")
	_native.set_state_ids(
			State.STANDING, State.BUTTERFLY, State.RECOVERING,
			State.RVH_LEFT, State.RVH_RIGHT, State.READY, State.SLIDING,
			State.COILING, State.VH_LEFT, State.VH_RIGHT, State.COVERING,
			State.PLAYING_PUCK, State.CATCHING, State.CATCHING_DOWN)
	_native.configure(_controller)
	# Only the fields the benched states read need mirroring — reuse the parity
	# suite for the exhaustive mapping; here the builder runs on its own
	# defaults, which match the controller exports for these states.
	_gd.catches_left = _controller.catches_left


func after_all() -> void:
	if _controller != null:
		_controller.free()


func _pose_state(state: int, flags: int) -> void:
	_inputs = GoalieBodyConfigBuilder.Inputs.new()
	_inputs.state = state
	_inputs.reacting_to_shot = flags & F_REACTING_TO_SHOT != 0
	_inputs.shot_is_elevated = flags & F_SHOT_IS_ELEVATED != 0
	_inputs.prelean_active = flags & F_PRELEAN_ACTIVE != 0
	_inputs.shot_impact_x = 0.6
	_inputs.shot_impact_y = 1.1
	_inputs.current_x = 0.2
	_inputs.goalie_z = 25.4
	_inputs.direction_sign = 1
	_inputs.puck_position = Vector3(1.5, 0.02, 20.0)
	_inputs.puck_velocity_est = Vector3(-2.0, 0.0, 18.0)
	_inputs.prelean_impact_x = 0.4
	_inputs.prelean_impact_y = 0.9
	_inputs.prelean_strength = 0.7


func _native_build_only(state: int, flags: int) -> void:
	_native.build(state, flags, _inputs.five_hole_openness,
			_inputs.shot_impact_x, _inputs.shot_impact_y, _inputs.current_x,
			_inputs.goalie_z, _inputs.direction_sign, _inputs.slide_velocity_x,
			_inputs.slide_dir, _inputs.puck_position, _inputs.puck_velocity_est,
			_inputs.lunge_progress, _inputs.sweep_anim_progress,
			_inputs.sweep_anim_dir, _inputs.sweep_windup_progress,
			_inputs.prelean_impact_x, _inputs.prelean_impact_y,
			_inputs.prelean_strength, _inputs.prelean_ready_lift,
			_inputs.left_pad_toe_out, _inputs.right_pad_toe_out,
			_inputs.head_yaw_deg, _inputs.puck_play_stride_phase,
			_inputs.puck_play_stride_intensity)


func _native_call(state: int, flags: int) -> void:
	_native.build(state, flags, _inputs.five_hole_openness,
			_inputs.shot_impact_x, _inputs.shot_impact_y, _inputs.current_x,
			_inputs.goalie_z, _inputs.direction_sign, _inputs.slide_velocity_x,
			_inputs.slide_dir, _inputs.puck_position, _inputs.puck_velocity_est,
			_inputs.lunge_progress, _inputs.sweep_anim_progress,
			_inputs.sweep_anim_dir, _inputs.sweep_windup_progress,
			_inputs.prelean_impact_x, _inputs.prelean_impact_y,
			_inputs.prelean_strength, _inputs.prelean_ready_lift,
			_inputs.left_pad_toe_out, _inputs.right_pad_toe_out,
			_inputs.head_yaw_deg, _inputs.puck_play_stride_phase,
			_inputs.puck_play_stride_intensity)
	var _a: Vector3 = _native.get_left_pad_pos()
	var _b: Vector3 = _native.get_left_pad_rot()
	var _c: Vector3 = _native.get_right_pad_pos()
	var _d: Vector3 = _native.get_right_pad_rot()
	var _e: Vector3 = _native.get_body_pos()
	var _f: Vector3 = _native.get_body_rot()
	var _g: Vector3 = _native.get_head_pos()
	var _h: Vector3 = _native.get_head_rot()
	var _i: Vector3 = _native.get_glove_pos()
	var _j: Vector3 = _native.get_glove_rot()
	var _k: Vector3 = _native.get_blocker_pos()
	var _l: Vector3 = _native.get_blocker_rot()


func test_goalie_pose_gdscript_vs_native() -> void:
	if _native == null:
		pending("native extension not built — see native/README.md")
		return
	for spec: Array in [
			["standing (neutral)", State.STANDING, 0],
			["butterfly + elevated react", State.BUTTERFLY,
					F_REACTING_TO_SHOT | F_SHOT_IS_ELEVATED],
			["RVH (post seal)", State.RVH_LEFT, 0],
			["sliding + prelean", State.SLIDING, F_PRELEAN_ACTIVE],
		]:
		var state: int = spec[1]
		var flags: int = spec[2]
		_pose_state(state, flags)

		var t0: int = Time.get_ticks_usec()
		for _i: int in REPS:
			var _cfg: GoalieBodyConfig = _gd.build(_inputs)
		var gd_us: float = float(Time.get_ticks_usec() - t0) / float(REPS)

		t0 = Time.get_ticks_usec()
		for _i: int in REPS:
			_native_call(state, flags)
		var nat_us: float = float(Time.get_ticks_usec() - t0) / float(REPS)
		_results.append({"label": spec[0] + " (12 getters)", "gd_us": gd_us, "nat_us": nat_us})

		t0 = Time.get_ticks_usec()
		for _i: int in REPS:
			_native_build_only(state, flags)
			var _outs: PackedVector3Array = _native.get_outputs_packed()
		var packed_us: float = float(Time.get_ticks_usec() - t0) / float(REPS)
		_results.append({"label": spec[0] + " (packed out)", "gd_us": gd_us, "nat_us": packed_us})

	var widest: int = 0
	for r: Dictionary in _results:
		widest = maxi(widest, (r["label"] as String).length())
	gut.p("")
	gut.p("── Goalie pose solve (µs/call, %d reps) ──" % REPS)
	gut.p("  %s  %10s  %10s  %8s" % ["state".rpad(widest), "GDScript", "native", "speedup"])
	for r: Dictionary in _results:
		gut.p("  %s  %10.2f  %10.2f  %7.1fx" % [
				(r["label"] as String).rpad(widest), r["gd_us"], r["nat_us"],
				(r["gd_us"] as float) / maxf(r["nat_us"] as float, 0.001)])
	gut.p("")
	assert_true(_results.size() == 8, "benchmark produced rows")
