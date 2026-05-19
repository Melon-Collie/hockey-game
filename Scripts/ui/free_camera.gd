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
@export var boost_speed: float = 30.0    # m/s while block (Shift) held
@export var look_sensitivity: float = 0.18  # degrees per pixel of mouse delta
@export var accel_time: float = 0.15     # seconds to ramp from 0 → base_speed

var _prev_camera: Camera3D = null
var _looking: bool = false
var _yaw_deg: float = 0.0
var _pitch_deg: float = 0.0
var _velocity: Vector3 = Vector3.ZERO


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
	# Rotation: rebuild from accumulated yaw/pitch so the camera can't drift
	# from float error over a long session.
	var basis := Basis.from_euler(Vector3(deg_to_rad(_pitch_deg), deg_to_rad(_yaw_deg), 0.0))
	var input_dir: Vector3 = _read_input_direction(basis)
	var target_speed: float = boost_speed if Input.is_action_pressed("block") else base_speed
	var target_vel: Vector3 = input_dir * target_speed
	# Ease the velocity so taps don't teleport. accel_time controls the time
	# constant; tiny delta clamps to 1.0 so we never overshoot.
	var alpha: float = clampf(delta / maxf(accel_time, 0.001), 0.0, 1.0)
	_velocity = _velocity.lerp(target_vel, alpha)
	global_transform = Transform3D(basis, global_position + _velocity * delta)


func _read_input_direction(basis: Basis) -> Vector3:
	var forward: Vector3 = -basis.z
	var right: Vector3 = basis.x
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
	if dir.length() > 1.0:
		dir = dir.normalized()
	return dir


func _capture_mouse() -> void:
	_looking = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _release_mouse() -> void:
	_looking = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
