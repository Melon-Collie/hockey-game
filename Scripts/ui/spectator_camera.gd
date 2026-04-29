class_name SpectatorCamera
extends Camera3D

# Cinematic side-rail camera for goal replays (and future spectator slots).
# Sits outside the boards on the +X side, tracks a target (puck) along Z, and
# smoothly looks at it. activate() saves the current camera and takes over;
# deactivate() restores it.

@export var rail_x: float = 18.0       # X offset from rink center (outside the boards)
@export var rail_height: float = 7.0   # elevation above ice
@export var follow_speed: float = 4.5  # position lerp speed
@export var look_speed: float = 7.0    # rotation slerp speed
@export var replay_fov: float = 52.0   # slightly narrower than game cam; more cinematic

var _target_getter: Callable = Callable()
var _prev_camera: Camera3D = null


func setup(target_getter: Callable) -> void:
	_target_getter = target_getter
	fov = replay_fov


func activate() -> void:
	# Guard against double-activation: a second call would overwrite _prev_camera
	# with our own current reference, breaking deactivate() restore. Goal-replay
	# overlapping with a stale spectator camera is the realistic trigger.
	if current:
		return
	_prev_camera = get_viewport().get_camera_3d()
	# Snap to the correct rail position before going current so there is no
	# opening sweep across the rink on the first frame.
	if _target_getter.is_valid():
		var target: Vector3 = _target_getter.call()
		global_position = Vector3(rail_x, rail_height, target.z)
		if global_position.distance_to(target) > 0.1:
			look_at(target, Vector3.UP)
	make_current()


func deactivate() -> void:
	if _prev_camera != null and is_instance_valid(_prev_camera):
		_prev_camera.make_current()
	_prev_camera = null


func _process(delta: float) -> void:
	if not current or not _target_getter.is_valid():
		return
	var target: Vector3 = _target_getter.call()

	# Slide along the rail, keeping X and Y fixed and tracking the puck's Z.
	var rail_target: Vector3 = Vector3(rail_x, rail_height, target.z)
	global_position = global_position.lerp(rail_target, follow_speed * delta)

	# Smoothly orient toward the puck.
	if global_position.distance_to(target) > 0.1:
		var look_xform: Transform3D = global_transform.looking_at(target, Vector3.UP)
		global_transform = global_transform.interpolate_with(look_xform, look_speed * delta)
