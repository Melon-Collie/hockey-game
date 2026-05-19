class_name GameCamera
extends Camera3D

# Top-down tilted camera, anchored on the local player. The mouse cursor IS
# the player's gaze: where the cursor points, the camera leans, and the
# further the cursor sits from the player the wider the camera zooms. Nothing
# else moves the camera — no game state, no possession, no opponent positions,
# no velocity, no shake. Predictability over expression (principle #9).

# ── Target ────────────────────────────────────────────────────────────────────
# Set by LocalController.setup() after the local skater is spawned.
@export var skater: Skater

# ── Cursor lean ───────────────────────────────────────────────────────────────
# The anchor (look-at) leans from the local player toward the world position
# under the cursor — the same input the player uses to aim. Cursor offset from
# the player is clamped to `max_cursor_dist`, then scaled by `cursor_weight`,
# so the anchor never offsets more than `max_cursor_dist * cursor_weight` from
# the player regardless of where the cursor sits.
@export var cursor_weight: float = 0.3
@export var max_cursor_dist: float = 8.0

# ── Zoom ──────────────────────────────────────────────────────────────────────
# Height interpolates from `min_height` (cursor on player) to `max_height`
# (cursor at `max_cursor_dist` or beyond). Both ends scale by the user's
# `camera_distance` preference.
@export var min_height: float = 10.0
@export var max_height: float = 22.0

# ── Smoothing (critical-damp time constants, seconds to ~95%) ─────────────────
# Tighter than the previous design — we lean predictable; lag should be barely
# perceptible.
@export var smooth_time_anchor: float = 0.10
@export var smooth_time_height: float = 0.15

# ── Soft rink clamp ───────────────────────────────────────────────────────────
@export var clamp_softness: float = 3.0

# ── Rink Bounds ───────────────────────────────────────────────────────────────
@export var rink_half_width: float = 13.0
@export var rink_half_length: float = 30.0

# ── Local team (for attack-up Y flip; set once by LocalController) ───────────
var _local_team_id: int = -1

# ── Runtime ───────────────────────────────────────────────────────────────────
var _initialized: bool = false
var _current_height: float = 15.0
var _height_vel: float = 0.0
var _smoothed_anchor: Vector3 = Vector3.ZERO
var _anchor_vel: Vector3 = Vector3.ZERO

func set_local_team_id(team_id: int) -> void:
	_local_team_id = team_id

func _ready() -> void:
	make_current()

# Critical-damped spring (SmoothDamp). Settles in ~smooth_time seconds with no
# oscillation, framerate-independent. Returns [new_pos, new_vel].
static func _spring_damp(current: float, target: float, vel: float, smooth_time: float, dt: float) -> Array:
	if smooth_time < 0.0001 or dt <= 0.0:
		return [target, 0.0]
	var omega: float = 2.0 / smooth_time
	var x: float = omega * dt
	var exp_factor: float = 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x)
	var change: float = current - target
	var temp: float = (vel + omega * change) * dt
	var new_vel: float = (vel - omega * temp) * exp_factor
	var new_pos: float = target + (change + temp) * exp_factor
	return [new_pos, new_vel]

# Asymmetric saturate: identity inside ±(limit - softness), smoothly approaches
# (but never exceeds) ±limit beyond that. Used to keep the anchor inside the
# rink without a hard wall the camera visibly pins against.
static func _soft_clamp(x: float, limit: float, softness: float) -> float:
	if limit <= 0.0:
		return 0.0
	var s: float = signf(x)
	var ax: float = absf(x)
	var knee: float = maxf(limit - softness, 0.0)
	if ax <= knee:
		return x
	var t: float = (ax - knee) / softness
	return s * (knee + softness * t / (1.0 + t))

# Project the current screen cursor onto the rink (y=0 plane). Godot's
# built-in raycast respects the camera's actual pitch and projection, so this
# works at any tilt_angle without per-pitch correction.
func _cursor_world_pos() -> Vector3:
	var viewport: Viewport = get_viewport()
	if viewport == null:
		return Vector3.ZERO
	var mouse_pos: Vector2 = viewport.get_mouse_position()
	var ray_origin: Vector3 = project_ray_origin(mouse_pos)
	var ray_dir: Vector3 = project_ray_normal(mouse_pos)
	if absf(ray_dir.y) < 0.0001:
		return Vector3(ray_origin.x, 0.0, ray_origin.z)
	var t: float = -ray_origin.y / ray_dir.y
	return ray_origin + ray_dir * t

func _physics_process(delta: float) -> void:
	if not skater:
		return

	var player_pos: Vector3 = skater.global_position + skater.visual_offset
	player_pos.y = 0.0

	# FOV is user-tunable; pull from prefs each tick so the slider works live.
	if not is_equal_approx(fov, PlayerPrefs.fov):
		fov = PlayerPrefs.fov

	if not _initialized:
		_smoothed_anchor = Vector3(player_pos.x, 0.0, player_pos.z)
		_initialized = true

	# ── Step 1: Cursor offset from player (clamped to max_cursor_dist) ───────
	# The cursor IS the player's gaze. Everything below is a function of where
	# the mouse points relative to the player — no game state, no velocity.
	var cursor_pos: Vector3 = _cursor_world_pos()
	cursor_pos.y = 0.0
	var raw_offset: Vector3 = cursor_pos - player_pos
	raw_offset.y = 0.0
	var raw_dist: float = raw_offset.length()
	var clamped_dist: float = minf(raw_dist, max_cursor_dist)
	var clamped_offset: Vector3 = Vector3.ZERO
	if raw_dist > 0.001:
		clamped_offset = (raw_offset / raw_dist) * clamped_dist

	# ── Step 2: Anchor target = player + clamped_offset * weight ─────────────
	var target_anchor: Vector3 = Vector3(
			player_pos.x + clamped_offset.x * cursor_weight,
			0.0,
			player_pos.z + clamped_offset.z * cursor_weight)

	# ── Step 3: Zoom target — lerp by clamped cursor distance ────────────────
	# Cursor on player → tightest zoom (max precision for stickhandling).
	# Cursor at max_cursor_dist → widest zoom (see what you're aiming at).
	var t_zoom: float = 0.0
	if max_cursor_dist > 0.001:
		t_zoom = clamped_dist / max_cursor_dist
	var dist_mult: float = PlayerPrefs.camera_distance
	var target_height: float = lerpf(min_height, max_height, t_zoom) * dist_mult

	# ── Step 4: Spring-damp height ───────────────────────────────────────────
	var height_res: Array = _spring_damp(
			_current_height, target_height, _height_vel, smooth_time_height, delta)
	_current_height = height_res[0]
	_height_vel = height_res[1]

	# ── Step 5: Soft rink clamp on anchor ────────────────────────────────────
	# Anchor stays inside the rink; the camera VIEW can extend a little over
	# the boards at high zoom.
	target_anchor.x = _soft_clamp(target_anchor.x, rink_half_width, clamp_softness)
	target_anchor.z = _soft_clamp(target_anchor.z, rink_half_length, clamp_softness)

	# ── Step 6: Spring-damp anchor (xz only; height is composed separately) ──
	var ax_res: Array = _spring_damp(
			_smoothed_anchor.x, target_anchor.x, _anchor_vel.x, smooth_time_anchor, delta)
	_smoothed_anchor.x = ax_res[0]
	_anchor_vel.x = ax_res[1]
	var az_res: Array = _spring_damp(
			_smoothed_anchor.z, target_anchor.z, _anchor_vel.z, smooth_time_anchor, delta)
	_smoothed_anchor.z = az_res[0]
	_anchor_vel.z = az_res[1]

	# ── Step 7: Compose camera position from anchor + height + tilt offset ──
	# Tilt geometry derives from the smoothed height so the view anchor stays
	# put during zoom transitions. At tilt_angle = 90° the off-axis offset
	# collapses to zero and the camera looks straight down.
	var off_axis_rad: float = deg_to_rad(90.0 - PlayerPrefs.tilt_angle)
	var flip_sign: float = -1.0 if PlayerPrefs.attack_up and _local_team_id == 1 else 1.0
	var tilt_z_offset: float = _current_height * tan(off_axis_rad) * flip_sign

	global_position = Vector3(
			_smoothed_anchor.x, _current_height, _smoothed_anchor.z + tilt_z_offset)

	# ── Step 8: Rotation (pitch + attack-up Y flip; never rotates in-play) ──
	var flip_y: float = 180.0 if PlayerPrefs.attack_up and _local_team_id == 1 else 0.0
	rotation_degrees = Vector3(-PlayerPrefs.tilt_angle, flip_y, 0.0)
