class_name GameCamera
extends Camera3D

# ── Target References ─────────────────────────────────────────────────────────
@export var skater: Skater
@export var puck: Puck
@export var local_controller: LocalController

# ── Zone Bias ─────────────────────────────────────────────────────────────────
# Fraction of available slack to use when shifting toward the attacking zone.
# 1.0 = push player/puck to the trailing edge of the frame; 0.0 = no bias.
@export var zone_bias: float = 0.7
# How fast the bias transitions when possession changes (prevents snapping).
@export var bias_smooth_speed: float = 1.5

# ── Zoom Tuning ───────────────────────────────────────────────────────────────
@export var min_height: float = 10.0
@export var ozone_min_height: float = 14.0  # min height when local player is in the offensive zone
@export var max_height: float = 40.0
@export var zoom_speed: float = 3.0
@export var zoom_padding: float = 4.0  # extra visible space beyond player+puck span

# ── Rink Bounds ───────────────────────────────────────────────────────────────
@export var rink_half_width: float = 13.0
@export var rink_half_length: float = 30.0

# ── Smoothing ─────────────────────────────────────────────────────────────────
@export var smooth_speed: float = 3.0

# Tilted-camera pitch. Subtle by design — much steeper than this and the
# mouse-to-world projection becomes nonlinear enough to break stickhandling.
const _TILTED_PITCH_DEG: float = -75.0

# ── Goal Context (set via set_goal_context) ───────────────────────────────────
var _goal_0: HockeyGoal = null  # Team 0's defended goal
var _goal_1: HockeyGoal = null  # Team 1's defended goal
var _carrier_team_getter: Callable  # () -> int team_id, or -1 if no carrier
var _local_team_id: int = -1

# ── Runtime ───────────────────────────────────────────────────────────────────
var _current_height: float = 15.0
var _smoothed_attack_dir: float = 0.0    # lerps between -1, 0, +1 on possession change
var _smoothed_direction_factor: float = 1.0  # lerps movement-direction bias to avoid snapping

# ── Shake ─────────────────────────────────────────────────────────────────────
var _shake_trauma: float = 0.0
const _SHAKE_DECAY: float = 4.0
const _SHAKE_MAG: float = 0.25

func set_goal_context(goal_0: HockeyGoal, goal_1: HockeyGoal, carrier_team_getter: Callable) -> void:
	_goal_0 = goal_0
	_goal_1 = goal_1
	_carrier_team_getter = carrier_team_getter

func set_local_team_id(team_id: int) -> void:
	_local_team_id = team_id

# Returns +1 or -1 (attacking direction in Z) when someone has the puck, 0 otherwise.
func _get_attacking_direction() -> int:
	if not _carrier_team_getter.is_valid():
		return 0
	var carrier_team: int = _carrier_team_getter.call()
	if carrier_team == -1:
		return 0
	var attacking_goal: HockeyGoal = _goal_1 if carrier_team == 0 else _goal_0
	if attacking_goal == null:
		return 0
	return 1 if attacking_goal.defending_team_id == 0 else -1

func shake(trauma: float) -> void:
	_shake_trauma = minf(1.0, _shake_trauma + trauma)

func _ready() -> void:
	make_current()
	GameManager.goal_scored.connect(func(_t, _n, _a1, _a2) -> void: shake(1.0))
	GameManager.local_player_hit.connect(func(mag: float) -> void:
		if mag >= 3.0:
			shake(clampf(mag / 12.0, 0.2, 0.4)))

func _physics_process(delta: float) -> void:
	if not skater or not puck:
		return

	var player_pos: Vector3 = skater.global_position + skater.visual_offset
	player_pos.y = 0.0
	var puck_pos: Vector3 = puck.global_position
	puck_pos.y = 0.0

	# Pull FOV from prefs so the user-facing slider drives every downstream
	# computation (zoom math, ortho size, tilt offset).
	if not is_equal_approx(fov, PlayerPrefs.fov):
		fov = PlayerPrefs.fov
	var fov_rad: float = deg_to_rad(fov)
	var aspect: float = get_viewport().get_visible_rect().size.x / get_viewport().get_visible_rect().size.y
	var tan_half_fov: float = tan(fov_rad / 2.0)

	# ── Step 1: Base center = midpoint of player and puck ────────────────────
	var base_center: Vector3 = (player_pos + puck_pos) * 0.5

	# ── Step 2: Zoom to keep both player and puck in frame ───────────────────
	var half_span_x: float = abs(player_pos.x - puck_pos.x) * 0.5
	var half_span_z: float = abs(player_pos.z - puck_pos.z) * 0.5
	var needed_x: float = (half_span_x + zoom_padding) / (tan_half_fov * aspect)
	var needed_z: float = (half_span_z + zoom_padding) / tan_half_fov
	# Zoom out when someone has the puck AND the local player is in the zone
	# being attacked — works for either ozone, either carrier.
	var attack_dir_now: int = _get_attacking_direction()
	var in_ozone: bool = attack_dir_now != 0 and \
		(player_pos.z * float(attack_dir_now)) > GameRules.BLUE_LINE_Z
	# User-facing camera-distance multiplier (Options → Game). Scales the
	# clamp range so the dynamic zoom math keeps its shape but the overall
	# height shifts up/down per the player's preference.
	var dist_mult: float = PlayerPrefs.camera_distance
	var effective_min: float = (ozone_min_height if in_ozone else min_height) * dist_mult
	var effective_max: float = max_height * dist_mult
	var target_height: float = clampf(maxf(needed_x, needed_z), effective_min, effective_max)
	_current_height = lerpf(_current_height, target_height, zoom_speed * delta)

	var visible_half_x: float = tan_half_fov * aspect * _current_height
	var visible_half_z: float = tan_half_fov * _current_height

	# ── Step 3: Attacking zone bias ───────────────────────────────────────────
	# Lerp the attack direction so possession changes ease in rather than snap.
	var attack_dir: int = _get_attacking_direction()
	_smoothed_attack_dir = lerpf(_smoothed_attack_dir, float(attack_dir), bias_smooth_speed * delta)

	var target_center: Vector3 = base_center
	if not is_zero_approx(_smoothed_attack_dir):
		# Scale bias by how much the player is moving toward the attacking zone.
		# Moving directly toward ozone = 1.0, sideways = 0.5, backward = 0.0.
		# Smoothed so a momentary backward step doesn't yank the bias away.
		var vel_xz: Vector3 = Vector3(skater.velocity.x, 0.0, skater.velocity.z)
		var raw_direction_factor: float = 1.0
		if vel_xz.length_squared() > 0.25:  # ignore drift when nearly stationary
			var vel_dir: Vector3 = vel_xz.normalized()
			var dot: float = vel_dir.z * float(attack_dir)
			raw_direction_factor = clampf((dot + 1.0) * 0.5, 0.0, 1.0)
		_smoothed_direction_factor = lerpf(_smoothed_direction_factor, raw_direction_factor, bias_smooth_speed * delta)
		var direction_factor: float = _smoothed_direction_factor

		# Slack = how far we can shift before the trailing subject hits the frame edge.
		var min_z: float = minf(player_pos.z, puck_pos.z)
		var max_z: float = maxf(player_pos.z, puck_pos.z)
		var slack_pos: float = maxf(visible_half_z - (base_center.z - min_z), 0.0)
		var slack_neg: float = maxf(visible_half_z - (max_z - base_center.z), 0.0)
		var blended_slack: float = 0.0
		if _smoothed_attack_dir > 0.0:
			blended_slack = _smoothed_attack_dir * slack_pos
		else:
			blended_slack = _smoothed_attack_dir * slack_neg
		target_center.z += blended_slack * zone_bias * direction_factor

	# ── Step 4: Rink clamp ────────────────────────────────────────────────────
	var safe_x: float = maxf(rink_half_width - visible_half_x, 0.0)
	var safe_z: float = maxf(rink_half_length - visible_half_z, 0.0)
	target_center.x = clampf(target_center.x, -safe_x, safe_x)
	target_center.z = clampf(target_center.z, -safe_z, safe_z)

	# ── Step 5: Smooth movement ───────────────────────────────────────────────
	# Tilted mode: camera looks along a slanted ray, so a camera at
	# target_center.xz looks at a point ~h*tan(off-axis-angle) behind itself.
	# Offset the camera in the direction the view is being pulled away from
	# so the play stays centered. attack_up flip mirrors the offset sign.
	var pitch: float = -90.0
	var tilt_z_offset: float = 0.0
	if PlayerPrefs.camera_mode == PlayerPrefs.CAMERA_MODE_TILTED:
		pitch = _TILTED_PITCH_DEG
		var off_axis_rad: float = deg_to_rad(90.0 + _TILTED_PITCH_DEG)  # 15° at -75° pitch
		var raw_offset: float = _current_height * tan(off_axis_rad)
		var flip_sign: float = -1.0 if PlayerPrefs.attack_up and _local_team_id == 1 else 1.0
		tilt_z_offset = raw_offset * flip_sign
	var target_pos: Vector3 = Vector3(
			target_center.x, _current_height, target_center.z + tilt_z_offset)
	global_position = global_position.lerp(target_pos, smooth_speed * delta)

	# ── Step 5b: Apply projection + pitch from PlayerPrefs ────────────────────
	# Ortho `size` = vertical world units visible; matches the perspective
	# FOV's vertical extent at the current height so the same zone frames in
	# both modes.
	var flip_y: float = 180.0 if PlayerPrefs.attack_up and _local_team_id == 1 else 0.0
	match PlayerPrefs.camera_mode:
		PlayerPrefs.CAMERA_MODE_ORTHOGRAPHIC:
			if projection != PROJECTION_ORTHOGONAL:
				projection = PROJECTION_ORTHOGONAL
			size = 2.0 * tan_half_fov * _current_height
		PlayerPrefs.CAMERA_MODE_TOP_DOWN:
			if projection != PROJECTION_PERSPECTIVE:
				projection = PROJECTION_PERSPECTIVE
		PlayerPrefs.CAMERA_MODE_TILTED:
			if projection != PROJECTION_PERSPECTIVE:
				projection = PROJECTION_PERSPECTIVE
	rotation_degrees = Vector3(pitch, flip_y, 0.0)

	# ── Step 6: Shake ─────────────────────────────────────────────────────────
	if _shake_trauma > 0.0:
		_shake_trauma = maxf(0.0, _shake_trauma - _SHAKE_DECAY * delta)
		global_position += Vector3(
			randf_range(-1.0, 1.0) * _shake_trauma * _SHAKE_MAG,
			0.0,
			randf_range(-1.0, 1.0) * _shake_trauma * _SHAKE_MAG)
