extends GutTest

# Parity: NativeGoalieBodyPose (C++ GDExtension, native/src/) against the
# GDScript reference GoalieBodyConfigBuilder, driven side by side through the
# same Inputs bundles. The builder is a pure function of inputs + tunables
# (every state overwrites all twelve config fields), so each case is compared
# independently — no stateful lockstep needed. Tunables load into the native
# port from a real GoalieController's @exports via configure(), and into the
# GDScript builder via the same mapping GoalieController._configure_collaborators
# uses, so both sides see identical numbers. Goes pending when the extension
# isn't built.

const State = GoalieStateMachine.State
const TOLERANCE: float = 0.001
const SEED: int = 0x504F5345  # "POSE"

# NativeGoalieBodyPose.build flag bits.
const F_READING_PINNED_WINDUP: int = 1
const F_REACTING_TO_SHOT: int = 2
const F_SHOT_IS_ELEVATED: int = 4
const F_ARM_REACTION_PENDING: int = 8
const F_BLADE_INTENT_ACTIVE: int = 16
const F_PADDLE_SWEEP_ACTIVE: int = 32
const F_STANDING_SWEEP_ACTIVE: int = 64
const F_PRELEAN_ACTIVE: int = 128
const F_PRELEAN_DIRECTIONAL: int = 256
const F_PUCK_PLAY_STOPPING: int = 512

const ALL_STATES: Array[int] = [
	State.STANDING, State.BUTTERFLY, State.RECOVERING, State.RVH_LEFT,
	State.RVH_RIGHT, State.READY, State.SLIDING, State.COILING,
	State.VH_LEFT, State.VH_RIGHT, State.COVERING, State.PLAYING_PUCK,
	State.CATCHING, State.CATCHING_DOWN,
]

var _rng := RandomNumberGenerator.new()
var _gd: GoalieBodyConfigBuilder = null
var _inputs: GoalieBodyConfigBuilder.Inputs = null
var _controller: GoalieController = null
var _native: RefCounted = null
var _configure_missing: String = ""
var _case_count: int = 0


func before_all() -> void:
	if not ClassDB.class_exists(&"NativeGoalieBodyPose"):
		return
	# Property-bag only — configure() reads @exports by name, so the controller
	# never needs setup() or a scene around it.
	_controller = GoalieController.new()
	_gd = GoalieBodyConfigBuilder.new()
	_inputs = GoalieBodyConfigBuilder.Inputs.new()
	_native = ClassDB.instantiate(&"NativeGoalieBodyPose")
	_native.set_state_ids(
			State.STANDING, State.BUTTERFLY, State.RECOVERING,
			State.RVH_LEFT, State.RVH_RIGHT, State.READY, State.SLIDING,
			State.COILING, State.VH_LEFT, State.VH_RIGHT, State.COVERING,
			State.PLAYING_PUCK, State.CATCHING, State.CATCHING_DOWN)
	_configure_missing = _native.configure(_controller)
	_sync_gd_tunables()


func after_all() -> void:
	if _controller != null:
		_controller.free()


func _native_missing() -> bool:
	if _native != null:
		return false
	pending("native extension not built — see native/README.md")
	return true


# Mirror of the `_pose.*` block in GoalieController._configure_collaborators —
# the exact export-to-builder mapping the game uses (note the two _deg renames).
func _sync_gd_tunables() -> void:
	_gd.catches_left = _controller.catches_left
	_gd.rvh_post_pad_angle = _controller.rvh_post_pad_angle
	_gd.pad_toe_out_standing = _controller.pad_toe_out_standing_deg
	_gd.pad_toe_out_butterfly = _controller.pad_toe_out_butterfly_deg
	_gd.glove_max_x_outward = _controller.glove_max_x_outward
	_gd.glove_max_x_inward = _controller.glove_max_x_inward
	_gd.glove_max_z_reach = _controller.glove_max_z_reach
	_gd.glove_max_yaw_deg = _controller.glove_max_yaw_deg
	_gd.blocker_max_x_outward = _controller.blocker_max_x_outward
	_gd.blocker_max_x_inward = _controller.blocker_max_x_inward
	_gd.blocker_max_z_reach = _controller.blocker_max_z_reach
	_gd.blocker_max_yaw_deg = _controller.blocker_max_yaw_deg
	_gd.active_blade_max_yaw_deg = _controller.active_blade_max_yaw_deg
	_gd.lunge_extension = _controller.lunge_extension
	_gd.paddle_sweep_max_yaw_deg = _controller.paddle_sweep_max_yaw_deg
	_gd.paddle_sweep_y_drop = _controller.paddle_sweep_y_drop
	_gd.paddle_sweep_x_extension = _controller.paddle_sweep_x_extension
	_gd.standing_sweep_max_yaw_deg = _controller.standing_sweep_max_yaw_deg
	_gd.standing_sweep_y_drop = _controller.standing_sweep_y_drop
	_gd.standing_sweep_x_extension = _controller.standing_sweep_x_extension
	_gd.sweep_anim_x_extension = _controller.sweep_anim_x_extension
	_gd.sweep_anim_z_extension = _controller.sweep_anim_z_extension
	_gd.sweep_anim_max_yaw_deg = _controller.sweep_anim_max_yaw_deg
	_gd.sweep_windup_x_extension = _controller.sweep_windup_x_extension
	_gd.sweep_windup_z_pull = _controller.sweep_windup_z_pull
	_gd.sweep_windup_max_yaw_deg = _controller.sweep_windup_max_yaw_deg
	_gd.body_lean_max_deg = _controller.body_lean_max_deg
	_gd.body_lean_reach_norm = _controller.body_lean_reach_norm
	_gd.shoulder_pitch_y_neutral = _controller.shoulder_pitch_y_neutral
	_gd.shoulder_pitch_forward_max_deg = _controller.shoulder_pitch_forward_max_deg
	_gd.shoulder_pitch_back_max_deg = _controller.shoulder_pitch_back_max_deg
	_gd.shoulder_pitch_y_range = _controller.shoulder_pitch_y_range
	_gd.react_hand_y_min = _controller.react_hand_y_min
	_gd.react_hand_y_max = _controller.react_hand_y_max
	_gd.arm_reach_above_chest = _controller.arm_reach_above_chest
	_gd.react_hand_z = _controller.react_hand_z
	_gd.slide_pushoff_lift = _controller.slide_pushoff_lift
	_gd.slide_pushoff_rot_deg = _controller.slide_pushoff_rot_deg
	_gd.slide_body_lean_deg = _controller.slide_body_lean_deg
	_gd.slide_initial_speed = _controller.slide_initial_speed


func _set_catches_left(value: bool) -> void:
	_controller.catches_left = value
	_configure_missing = _native.configure(_controller)
	_gd.catches_left = value


func _reset_inputs() -> void:
	_inputs = GoalieBodyConfigBuilder.Inputs.new()
	_inputs.state = State.STANDING


func _flags() -> int:
	var flags: int = 0
	if _inputs.reading_pinned_windup:
		flags |= F_READING_PINNED_WINDUP
	if _inputs.reacting_to_shot:
		flags |= F_REACTING_TO_SHOT
	if _inputs.shot_is_elevated:
		flags |= F_SHOT_IS_ELEVATED
	if _inputs.arm_reaction_pending:
		flags |= F_ARM_REACTION_PENDING
	if _inputs.blade_intent_active:
		flags |= F_BLADE_INTENT_ACTIVE
	if _inputs.paddle_sweep_active:
		flags |= F_PADDLE_SWEEP_ACTIVE
	if _inputs.standing_sweep_active:
		flags |= F_STANDING_SWEEP_ACTIVE
	if _inputs.prelean_active:
		flags |= F_PRELEAN_ACTIVE
	if _inputs.prelean_directional:
		flags |= F_PRELEAN_DIRECTIONAL
	if _inputs.puck_play_stopping:
		flags |= F_PUCK_PLAY_STOPPING
	return flags


# Runs both implementations on the current Inputs and compares every config
# field. Returns false (after failing the test) on divergence so callers can
# bail out of long loops.
func _check(label: String) -> bool:
	var c: GoalieBodyConfig = _gd.build(_inputs)
	_native.build(_inputs.state, _flags(), _inputs.five_hole_openness,
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
	_case_count += 1
	var fields: Array = [
		["left_pad_pos", c.left_pad_pos, _native.get_left_pad_pos()],
		["left_pad_rot", c.left_pad_rot, _native.get_left_pad_rot()],
		["right_pad_pos", c.right_pad_pos, _native.get_right_pad_pos()],
		["right_pad_rot", c.right_pad_rot, _native.get_right_pad_rot()],
		["body_pos", c.body_pos, _native.get_body_pos()],
		["body_rot", c.body_rot, _native.get_body_rot()],
		["head_pos", c.head_pos, _native.get_head_pos()],
		["head_rot", c.head_rot, _native.get_head_rot()],
		["glove_pos", c.glove_pos, _native.get_glove_pos()],
		["glove_rot", c.glove_rot, _native.get_glove_rot()],
		["blocker_pos", c.blocker_pos, _native.get_blocker_pos()],
		["blocker_rot", c.blocker_rot, _native.get_blocker_rot()],
	]
	for f: Array in fields:
		var a: Vector3 = f[1]
		var b: Vector3 = f[2]
		var err: float = maxf(absf(a.x - b.x), maxf(absf(a.y - b.y), absf(a.z - b.z)))
		if err > TOLERANCE:
			fail_test("%s diverged (%s, state %d, case %d): gd=%s native=%s" % [
					f[0], label, _inputs.state, _case_count, a, b])
			return false
	return true


func _randomize_inputs() -> void:
	_inputs.state = ALL_STATES[_rng.randi_range(0, ALL_STATES.size() - 1)]
	_inputs.five_hole_openness = _rng.randf_range(0.0, 0.30)
	_inputs.reading_pinned_windup = _rng.randf() < 0.3
	_inputs.reacting_to_shot = _rng.randf() < 0.4
	_inputs.shot_is_elevated = _rng.randf() < 0.6
	_inputs.shot_impact_x = _rng.randf_range(-2.0, 2.0)
	_inputs.shot_impact_y = _rng.randf_range(0.0, 2.0)
	_inputs.current_x = _rng.randf_range(-1.5, 1.5)
	_inputs.goalie_z = _rng.randf_range(-28.0, 28.0)
	_inputs.direction_sign = 1 if _rng.randf() < 0.5 else -1
	_inputs.slide_velocity_x = _rng.randf_range(-5.0, 5.0)
	_inputs.slide_dir = signf(_rng.randf_range(-1.0, 1.0)) if _rng.randf() < 0.85 else 0.0
	_inputs.arm_reaction_pending = _rng.randf() < 0.3
	_inputs.puck_position = Vector3(
			_rng.randf_range(-3.0, 3.0), _rng.randf_range(0.0, 1.5),
			_inputs.goalie_z + _rng.randf_range(-8.0, 8.0))
	_inputs.puck_velocity_est = Vector3(
			_rng.randf_range(-10.0, 10.0), _rng.randf_range(-5.0, 10.0),
			_rng.randf_range(-25.0, 25.0))
	if _rng.randf() < 0.15:
		# Dead-flat trajectory — exercises the no-ballistic-solve branch.
		_inputs.puck_velocity_est.z = 0.0
	_inputs.blade_intent_active = _rng.randf() < 0.5
	_inputs.paddle_sweep_active = _rng.randf() < 0.4
	_inputs.standing_sweep_active = _rng.randf() < 0.4
	_inputs.lunge_progress = _rng.randf() if _rng.randf() < 0.4 else 0.0
	_inputs.sweep_anim_progress = _rng.randf() if _rng.randf() < 0.4 else 0.0
	_inputs.sweep_anim_dir = signf(_rng.randf_range(-1.0, 1.0))
	_inputs.sweep_windup_progress = _rng.randf() if _rng.randf() < 0.4 else 0.0
	_inputs.prelean_active = _rng.randf() < 0.4
	_inputs.prelean_directional = _rng.randf() < 0.5
	_inputs.prelean_impact_x = _rng.randf_range(-2.0, 2.0)
	_inputs.prelean_impact_y = _rng.randf_range(0.0, 2.0)
	_inputs.prelean_strength = _rng.randf()
	_inputs.prelean_ready_lift = _rng.randf_range(0.0, 0.2)
	_inputs.left_pad_toe_out = -1.0 if _rng.randf() < 0.3 else _rng.randf_range(0.0, 18.0)
	_inputs.right_pad_toe_out = -1.0 if _rng.randf() < 0.3 else _rng.randf_range(0.0, 18.0)
	_inputs.head_yaw_deg = _rng.randf_range(-70.0, 70.0)
	_inputs.puck_play_stopping = _rng.randf() < 0.5
	_inputs.puck_play_stride_phase = _rng.randf_range(0.0, TAU)
	_inputs.puck_play_stride_intensity = _rng.randf()


# Every tunable the port reads must exist on the controller by its exact
# @export name — a rename on either side fails here, not as silent drift.
func test_configure_finds_every_tunable() -> void:
	if _native_missing():
		return
	assert_eq(_configure_missing, "",
			"controller properties missing: %s" % _configure_missing)


func test_all_states_neutral_pose_match() -> void:
	if _native_missing():
		return
	for state: int in ALL_STATES:
		_reset_inputs()
		_inputs.state = state
		if not _check("neutral"):
			return
		# Windup tell (upright poses) + sentinel-free toe-outs (down poses).
		_inputs.reading_pinned_windup = true
		_inputs.left_pad_toe_out = 6.0
		_inputs.right_pad_toe_out = 12.0
		if not _check("windup + toe-out"):
			return
	pass_test("all %d states match at neutral inputs" % ALL_STATES.size())


func test_elevated_reach_both_sides_match() -> void:
	if _native_missing():
		return
	for state: int in [State.STANDING, State.READY, State.BUTTERFLY, State.SLIDING]:
		for impact_x: float in [-0.9, -0.3, 0.0, 0.3, 0.9]:
			for impact_y: float in [0.2, 0.9, 1.4]:
				_reset_inputs()
				_inputs.state = state
				_inputs.reacting_to_shot = true
				_inputs.shot_is_elevated = true
				_inputs.shot_impact_x = impact_x
				_inputs.shot_impact_y = impact_y
				_inputs.puck_position = Vector3(impact_x, 0.9, 6.0)
				_inputs.puck_velocity_est = Vector3(0.0, 2.0, -18.0)
				if not _check("elevated reach"):
					return
	pass_test("elevated reach matches across states and impact points")


func test_fuzz_parity_catches_left() -> void:
	if _native_missing():
		return
	_rng.seed = SEED
	_reset_inputs()
	for i: int in 3000:
		_randomize_inputs()
		if not _check("fuzz L"):
			return
	pass_test("3000 catches-left fuzz cases within %f" % TOLERANCE)


func test_fuzz_parity_catches_right() -> void:
	if _native_missing():
		return
	_set_catches_left(false)
	_rng.seed = SEED + 1
	_reset_inputs()
	var ok: bool = true
	for i: int in 2000:
		_randomize_inputs()
		if not _check("fuzz R"):
			ok = false
			break
	_set_catches_left(true)
	if ok:
		pass_test("2000 catches-right (mirrored hands) fuzz cases within %f" % TOLERANCE)
