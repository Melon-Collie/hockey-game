class_name ChaseCamera
extends Camera3D

# Third-person chase cam for spectator / replay player-follow. Sits behind the
# tracked skater along their facing, looks slightly ahead so the puck sits in
# frame when the player has it. Smooth position + slerp yaw so quick turns
# don't whip the camera, but it still keeps up on transitions.

@export var follow_distance: float = 5.5   # meters behind the skater
@export var follow_height: float = 2.5     # meters above ice
@export var look_ahead: float = 3.0        # meters ahead of skater for aim
@export var look_height: float = 1.0       # meters above ice for aim
@export var pos_lerp: float = 8.0
@export var look_lerp: float = 6.0

var _target_getter: Callable = Callable()
var _prev_camera: Camera3D = null
var _smoothed_focus: Vector3 = Vector3.ZERO
var _initialized: bool = false


func setup(target_getter: Callable) -> void:
	# Getter returns the currently-tracked Skater (or null if none). The
	# Director updates the bound target by re-pointing the Callable on cycle —
	# this cam re-reads it every frame so we don't cache stale references.
	_target_getter = target_getter
	fov = PlayerPrefs.fov
	# Driven at render rate, so it is already continuous — see GameCamera._ready.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF


func activate() -> void:
	if current:
		return
	_prev_camera = get_viewport().get_camera_3d()
	_initialized = false
	_snap_to_target()
	make_current()


func deactivate() -> void:
	if _prev_camera != null and is_instance_valid(_prev_camera):
		_prev_camera.make_current()
	_prev_camera = null


# Returns the current transform so the Director can hand it off to FreeCamera
# on a mode swap (FREE inherits CHASE pose for a non-snapping transition).
func current_transform() -> Transform3D:
	return global_transform


# Re-snap to the currently-resolved target. Director calls this on player
# cycle so the camera leaps to the new skater rather than smooth-lerping
# across the rink (which would look like a swing).
func snap_to_target() -> void:
	_snap_to_target()


func _snap_to_target() -> void:
	var skater: Skater = _resolve_target()
	if skater == null:
		return
	var facing: Vector3 = _facing_world(skater)
	var pos: Vector3 = skater.global_position - facing * follow_distance + Vector3.UP * follow_height
	var focus: Vector3 = skater.global_position + facing * look_ahead + Vector3.UP * look_height
	global_position = pos
	_smoothed_focus = focus
	_initialized = true
	if global_position.distance_to(focus) > 0.1:
		look_at(focus, Vector3.UP)


func _process(delta: float) -> void:
	if not current:
		return
	# Mirror GameCamera so the player FOV slider drives all three player-
	# perspective cams (gameplay + chase + free) in lockstep.
	if not is_equal_approx(fov, PlayerPrefs.fov):
		fov = PlayerPrefs.fov
	var skater: Skater = _resolve_target()
	if skater == null:
		return
	if not _initialized:
		_snap_to_target()
		return
	var facing: Vector3 = _facing_world(skater)
	var target_pos: Vector3 = skater.global_position - facing * follow_distance + Vector3.UP * follow_height
	var target_focus: Vector3 = skater.global_position + facing * look_ahead + Vector3.UP * look_height
	var pos_alpha: float = clampf(delta * pos_lerp, 0.0, 1.0)
	global_position = global_position.lerp(target_pos, pos_alpha)
	var focus_alpha: float = clampf(delta * look_lerp, 0.0, 1.0)
	_smoothed_focus = _smoothed_focus.lerp(target_focus, focus_alpha)
	if global_position.distance_to(_smoothed_focus) > 0.1:
		var look_xform: Transform3D = global_transform.looking_at(_smoothed_focus, Vector3.UP)
		# Slerp the orientation toward the look-target. interpolate_with handles
		# both position and rotation, so cap position by overriding back to ours.
		var blended: Transform3D = global_transform.interpolate_with(look_xform, focus_alpha)
		blended.origin = global_position
		global_transform = blended


func _resolve_target() -> Skater:
	if not _target_getter.is_valid():
		return null
	var result: Variant = _target_getter.call()
	if result is Skater:
		return result as Skater
	return null


func _facing_world(skater: Skater) -> Vector3:
	# Skater.get_facing() returns a Vector2 in the horizontal plane (x, z).
	# Fall back to -Z if the skater is momentarily zero-velocity post-spawn.
	var f2: Vector2 = skater.get_facing()
	if f2.length_squared() < 0.0001:
		return Vector3.FORWARD
	var n: Vector2 = f2.normalized()
	return Vector3(n.x, 0.0, n.y)
