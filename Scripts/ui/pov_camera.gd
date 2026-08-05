class_name PovCamera
extends Camera3D

# Spectator/replay reproduction of the top-down Mitts gameplay camera
# (GameCamera), re-centered on an arbitrary tracked skater so a spectator can
# watch the game from each player's point of view. Cycling targets is owned by
# CameraDirector (same [↑↓] flow as the chase cam).
#
# Framing mirrors GameCamera's locked mode — center pinned on the tracked
# skater, dynamic zoom opening just enough to keep the puck in frame while
# it's in play — and reads the same user prefs (FOV, camera tilt, camera
# distance, attack-up flip) so the view matches what that player's own screen
# roughly looks like. The dynamic mode's zone bias / carrier vision need goal
# + possession context the director doesn't have, and locked framing is the
# faithful-enough read for spectating.

@export var min_height: float = 10.0
@export var max_height: float = 32.0
@export var zoom_speed: float = 3.0
@export var zoom_padding: float = 4.0
@export var smooth_speed: float = 3.0

# Same puck-in-play test as GameCamera: a stashed / off-rink puck must not
# drive the zoom.
@export var rink_half_width: float = 13.0
@export var rink_half_length: float = 30.0
const _ON_RINK_MARGIN: float = 5.0

var _target_getter: Callable = Callable()
var _puck_pos_getter: Callable = Callable()
var _prev_camera: Camera3D = null
var _current_height: float = 15.0


func _ready() -> void:
	# The jumbotron hangs over center ice, directly between any top-down
	# camera and the play — mask it out exactly like the gameplay camera does.
	cull_mask &= ~Jumbotron.RENDER_LAYER_MASK
	# Driven at render rate, so it is already continuous — see GameCamera._ready.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF


# target_getter returns the tracked Skater (or null); puck_pos_getter returns
# the puck's world position (the director's shared puck getter).
func setup(target_getter: Callable, puck_pos_getter: Callable) -> void:
	_target_getter = target_getter
	_puck_pos_getter = puck_pos_getter
	fov = PlayerPrefs.fov


func activate() -> void:
	if current:
		return
	_prev_camera = get_viewport().get_camera_3d()
	snap_to_target()
	make_current()


func deactivate() -> void:
	if _prev_camera != null and is_instance_valid(_prev_camera):
		_prev_camera.make_current()
	_prev_camera = null


# Returns the current transform so the Director can hand it off to FreeCamera
# on a mode swap (FREE inherits the pose for a non-snapping transition).
func current_transform() -> Transform3D:
	return global_transform


# Jump straight to the resolved target's framing — target cycle and playback
# discontinuities (seeks, faceoff resets) cut rather than pan.
func snap_to_target() -> void:
	var skater: Skater = _resolve_target()
	if skater == null:
		return
	_current_height = _fit_height(skater)
	_apply_pose(_anchor(skater), _current_height, skater, 1.0)


func _process(delta: float) -> void:
	if not current:
		return
	if not is_equal_approx(fov, PlayerPrefs.fov):
		fov = PlayerPrefs.fov
	var skater: Skater = _resolve_target()
	if skater == null:
		return
	_current_height = lerpf(_current_height, _fit_height(skater), zoom_speed * delta)
	_apply_pose(_anchor(skater), _current_height, skater,
			clampf(smooth_speed * delta, 0.0, 1.0))


func _resolve_target() -> Skater:
	if not _target_getter.is_valid():
		return null
	var result: Variant = _target_getter.call()
	if result is Skater:
		return result as Skater
	return null


func _anchor(skater: Skater) -> Vector3:
	var pos: Vector3 = skater.global_position + skater.visual_offset
	pos.y = 0.0
	return pos


# Whether the puck is in play on the rink (vs stashed / absent) — mirrors
# GameCamera._is_on_rink.
func _puck_fit_pos(anchor: Vector3) -> Vector3:
	if not _puck_pos_getter.is_valid():
		return anchor
	var puck_pos: Vector3 = _puck_pos_getter.call()
	puck_pos.y = 0.0
	if absf(puck_pos.x) > rink_half_width + _ON_RINK_MARGIN \
			or absf(puck_pos.z) > rink_half_length + _ON_RINK_MARGIN:
		return anchor
	return puck_pos


# Locked-mode dynamic zoom: center pinned on the skater, symmetric span out to
# the puck, height fitting that span plus padding — GameCamera's Step 1+2 with
# the fit set collapsed to {player, puck}.
func _fit_height(skater: Skater) -> float:
	var anchor: Vector3 = _anchor(skater)
	var puck_pos: Vector3 = _puck_fit_pos(anchor)
	var half_span_x: float = absf(anchor.x - puck_pos.x)
	var half_span_z: float = absf(anchor.z - puck_pos.z)
	var fov_rad: float = deg_to_rad(fov)
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	var aspect: float = viewport_size.x / maxf(viewport_size.y, 1.0)
	var tan_half_fov: float = tan(fov_rad / 2.0)
	var needed_x: float = (half_span_x + zoom_padding) / (tan_half_fov * aspect)
	var needed_z: float = (half_span_z + zoom_padding) / tan_half_fov
	var dist_mult: float = PlayerPrefs.camera_distance
	return clampf(maxf(needed_x, needed_z),
			min_height * dist_mult, max_height * dist_mult)


# Tilted top-down pose over the anchor: same slanted-ray offset math as
# GameCamera Step 5, including the attack-up flip when the tracked skater's
# team attacks downward (so the POV matches what that player would see).
func _apply_pose(anchor: Vector3, height: float, skater: Skater, alpha: float) -> void:
	var tilt_deg: float = PlayerPrefs.camera_tilt_deg
	var flipped: bool = PlayerPrefs.attack_up and skater.get_team_id() == 1
	var flip_sign: float = -1.0 if flipped else 1.0
	var tilt_z_offset: float = height * tan(deg_to_rad(90.0 - tilt_deg)) * flip_sign
	var target_pos: Vector3 = Vector3(anchor.x, height, anchor.z + tilt_z_offset)
	global_position = global_position.lerp(target_pos, alpha) if alpha < 1.0 else target_pos
	rotation_degrees = Vector3(-tilt_deg, 180.0 if flipped else 0.0, 0.0)
