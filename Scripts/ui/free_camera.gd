class_name FreeCamera
extends Camera3D

# Six-DOF fly camera for spectating and replay analysis. WASD translates on the
# camera's local plane, Q/E descend/ascend on world Y, and holding the right
# mouse button captures the cursor and turns mouse delta into yaw/pitch. Pitch
# is clamped to ±89° so the look basis never flips through the pole.
#
# Position is unclamped — fly behind the net, through the boards, above the
# rafters. Replay analysis wants angles no broadcast cam would ever produce.

@export var base_speed: float = 10.0     # m/s, WASD/QE held
@export var boost_speed: float = 30.0    # m/s while block (Shift) / L3 held
@export var look_sensitivity: float = 0.18  # degrees per pixel of mouse delta
@export var accel_time: float = 0.15     # seconds to ramp from 0 → base_speed
# Pad free-look: degrees per second at full right-stick deflection (the stick is a
# rate control, unlike the mouse's per-pixel delta). Trigger past this counts as a
# vertical (ascend/descend) press.
@export var pad_look_speed: float = 160.0
const _PAD_STICK_DEADZONE: float = 0.15
const _PAD_TRIGGER_THRESHOLD: float = 0.5

var _prev_camera: Camera3D = null
var _looking: bool = false
var _yaw_deg: float = 0.0
var _pitch_deg: float = 0.0
var _velocity: Vector3 = Vector3.ZERO
# Pad device id for the spectator free-cam (see LocalInputGatherer for why it's
# not assumed to be 0). Cached, refreshed on connect/disconnect. -1 = no pad.
var _pad_device: int = -1


func _ready() -> void:
	Input.joy_connection_changed.connect(func(_d: int, _c: bool) -> void: _refresh_pad_device())
	_refresh_pad_device()


func _refresh_pad_device() -> void:
	var pads: Array = Input.get_connected_joypads()
	_pad_device = int(pads[0]) if not pads.is_empty() else -1


func _pad_active() -> bool:
	return InputDeviceTracker.is_gamepad_active() and _pad_device >= 0


func activate(initial_xform: Transform3D) -> void:
	# Inherit the previous camera's pose so the first toggle doesn't teleport
	# the viewer halfway across the rink. Decompose to euler so our own pitch
	# clamp + yaw accumulator stay consistent with the visible orientation.
	if current:
		return
	_prev_camera = get_viewport().get_camera_3d()
	global_transform = initial_xform
	var basis_euler: Vector3 = initial_xform.basis.get_euler()
	_yaw_deg = rad_to_deg(basis_euler.y)
	_pitch_deg = clampf(rad_to_deg(basis_euler.x), -89.0, 89.0)
	_velocity = Vector3.ZERO
	fov = PlayerPrefs.fov
	make_current()


func deactivate() -> void:
	if _looking:
		_release_mouse()
	if _prev_camera != null and is_instance_valid(_prev_camera):
		_prev_camera.make_current()
	_prev_camera = null


# Scene change mid-look would otherwise leak MOUSE_MODE_CAPTURED into the
# next scene (you'd land in free play with an invisible cursor). Belt-and-
# suspenders on top of deactivate()'s release.
func _exit_tree() -> void:
	if _looking:
		_release_mouse()


func _unhandled_input(event: InputEvent) -> void:
	if not current:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed:
				_capture_mouse()
			else:
				_release_mouse()
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _looking:
		var mm := event as InputEventMouseMotion
		_yaw_deg -= mm.relative.x * look_sensitivity
		_pitch_deg = clampf(_pitch_deg - mm.relative.y * look_sensitivity, -89.0, 89.0)
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not current:
		return
	# Mirror GameCamera so the player FOV slider drives all three player-
	# perspective cams (gameplay + chase + free) in lockstep.
	if not is_equal_approx(fov, PlayerPrefs.fov):
		fov = PlayerPrefs.fov
	# Pad free-look: the right stick is a rate control (deg/s), applied here so it
	# accumulates into the same yaw/pitch the mouse feeds. Mouse delta stays in
	# _unhandled_input; the two are additive, so either device works.
	if _pad_active():
		var look: Vector2 = GamepadAimRules.apply_radial_deadzone(Vector2(
				Input.get_joy_axis(_pad_device, JOY_AXIS_RIGHT_X),
				Input.get_joy_axis(_pad_device, JOY_AXIS_RIGHT_Y)), _PAD_STICK_DEADZONE)
		_yaw_deg -= look.x * pad_look_speed * delta
		_pitch_deg = clampf(_pitch_deg - look.y * pad_look_speed * delta, -89.0, 89.0)
	# Rotation: rebuild from accumulated yaw/pitch so the camera can't drift
	# from float error over a long session.
	var cam_basis := Basis.from_euler(Vector3(deg_to_rad(_pitch_deg), deg_to_rad(_yaw_deg), 0.0))
	var input_dir: Vector3 = _read_input_direction(cam_basis)
	var boosting: bool = Input.is_action_pressed("block") \
			or (_pad_active() and Input.is_joy_button_pressed(_pad_device, JOY_BUTTON_LEFT_STICK))
	var target_speed: float = boost_speed if boosting else base_speed
	var target_vel: Vector3 = input_dir * target_speed
	# Ease the velocity so taps don't teleport. accel_time controls the time
	# constant; tiny delta clamps to 1.0 so we never overshoot.
	var alpha: float = clampf(delta / maxf(accel_time, 0.001), 0.0, 1.0)
	_velocity = _velocity.lerp(target_vel, alpha)
	global_transform = Transform3D(cam_basis, global_position + _velocity * delta)


func _read_input_direction(cam_basis: Basis) -> Vector3:
	var forward: Vector3 = -cam_basis.z
	var right: Vector3 = cam_basis.x
	var dir := Vector3.ZERO
	if Input.is_action_pressed("move_up"):
		dir += forward
	if Input.is_action_pressed("move_down"):
		dir -= forward
	if Input.is_action_pressed("move_right"):
		dir += right
	if Input.is_action_pressed("move_left"):
		dir -= right
	if Input.is_action_pressed("camera_pan_up"):
		dir += Vector3.UP
	if Input.is_action_pressed("camera_pan_down"):
		dir -= Vector3.UP
	# Pad: left stick translates on the camera plane; triggers rise/fall (RT up,
	# LT down). Summed with any keyboard input so both devices stay live.
	if _pad_active():
		var stick: Vector2 = GamepadAimRules.apply_radial_deadzone(Vector2(
				Input.get_joy_axis(_pad_device, JOY_AXIS_LEFT_X),
				Input.get_joy_axis(_pad_device, JOY_AXIS_LEFT_Y)), _PAD_STICK_DEADZONE)
		# Stick up (−Y) drives forward; stick right (+X) drives right.
		dir += forward * -stick.y + right * stick.x
		if Input.get_joy_axis(_pad_device, JOY_AXIS_TRIGGER_RIGHT) >= _PAD_TRIGGER_THRESHOLD:
			dir += Vector3.UP
		if Input.get_joy_axis(_pad_device, JOY_AXIS_TRIGGER_LEFT) >= _PAD_TRIGGER_THRESHOLD:
			dir -= Vector3.UP
	if dir.length() > 1.0:
		dir = dir.normalized()
	return dir


func _capture_mouse() -> void:
	_looking = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _release_mouse() -> void:
	_looking = false
	# Restore whatever the cursor-confine setting asks for rather than forcing
	# VISIBLE, so leaving spectator look doesn't un-confine the cursor.
	PlayerPrefs.apply_input()
