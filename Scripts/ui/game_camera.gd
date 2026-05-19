class_name GameCamera
extends Camera3D

# ── Target References ─────────────────────────────────────────────────────────
@export var skater: Skater
@export var puck: Puck
@export var local_controller: LocalController

# ── Lead (velocity + zone) ────────────────────────────────────────────────────
# Velocity lead pulls the frame in the local player's skating direction so the
# camera moves with them whether they carry or not.
@export var lead_distance: float = 5.0          # max world-units lead at full speed
@export var lead_full_speed: float = 12.0       # skater speed at which lead peaks
@export var lead_smooth: float = 5.0
# Zone lead is a possession-aware additive pull toward the attacking goal so
# you can see receivers / the play even when stationary with the puck.
@export var zone_lead: float = 3.5
@export var bias_smooth_speed: float = 2.0      # smooths possession transitions

# ── Threat-aware framing ──────────────────────────────────────────────────────
# Opponents within this distance of the local player are included in the
# zoom-fit so pressure widens the frame instead of locking tight on stickwork.
@export var threat_distance: float = 11.0

# ── Breakaway ─────────────────────────────────────────────────────────────────
# When the local player carries and no opponent sits ahead within
# `breakaway_lookahead`, slide a virtual point from the player toward the
# attacking goal so the zoom math naturally frames {player, goal}. The fit
# tightens when you're close to the net and widens when you're farther out.
# Smoothed both directions so a defender re-entering the lane doesn't snap the
# zoom.
@export var breakaway_lookahead: float = 18.0
@export var breakaway_smooth: float = 1.5

# ── Zoom Tuning ───────────────────────────────────────────────────────────────
@export var min_height: float = 10.0
@export var ozone_min_height: float = 14.0  # min height when local player is in the offensive zone
@export var max_height: float = 40.0
@export var zoom_padding: float = 4.0  # extra visible space beyond fit-set span

# ── Smoothing (critical-damp time constants, seconds to ~95%) ─────────────────
@export var smooth_time_anchor: float = 0.18
@export var smooth_time_height: float = 0.28

# ── Soft rink clamp ───────────────────────────────────────────────────────────
# The last `clamp_softness` meters near the rink edge compress non-linearly so
# the camera doesn't visibly pin when play sits in a corner.
@export var clamp_softness: float = 3.0

# ── Rink Bounds ───────────────────────────────────────────────────────────────
@export var rink_half_width: float = 13.0
@export var rink_half_length: float = 30.0

# Tilted-camera pitch. Subtle by design — much steeper than this and the
# mouse-to-world projection becomes nonlinear enough to break stickhandling.
const _TILTED_PITCH_DEG: float = -75.0

# ── Goal Context (set via set_goal_context) ───────────────────────────────────
var _goal_0: HockeyGoal = null  # Team 0's defended goal
var _goal_1: HockeyGoal = null  # Team 1's defended goal
var _carrier_team_getter: Callable  # () -> int team_id, or -1 if no carrier
var _local_team_id: int = -1

# ── Play Context (set via set_play_context) ──────────────────────────────────
var _local_is_carrier_getter: Callable    # () -> bool
var _opponent_positions_getter: Callable  # () -> Array[Vector3]

# ── Runtime ───────────────────────────────────────────────────────────────────
var _initialized: bool = false
var _current_height: float = 15.0
var _height_vel: float = 0.0
var _smoothed_anchor: Vector3 = Vector3.ZERO
var _anchor_vel: Vector3 = Vector3.ZERO
var _smoothed_attack_dir: float = 0.0
var _smoothed_lead_offset: Vector3 = Vector3.ZERO
var _smoothed_breakaway: float = 0.0

# ── Shake ─────────────────────────────────────────────────────────────────────
var _shake_trauma: float = 0.0
const _SHAKE_DECAY: float = 4.0
const _SHAKE_MAG: float = 0.25

func set_goal_context(goal_0: HockeyGoal, goal_1: HockeyGoal, carrier_team_getter: Callable) -> void:
	_goal_0 = goal_0
	_goal_1 = goal_1
	_carrier_team_getter = carrier_team_getter

func set_play_context(local_is_carrier_getter: Callable, opponent_positions_getter: Callable) -> void:
	_local_is_carrier_getter = local_is_carrier_getter
	_opponent_positions_getter = opponent_positions_getter

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

# World position of the goal the carrier's team is attacking, or Vector3.INF
# when there's no carrier.
func _get_attacking_goal_position() -> Vector3:
	if not _carrier_team_getter.is_valid():
		return Vector3.INF
	var carrier_team: int = _carrier_team_getter.call()
	if carrier_team == -1:
		return Vector3.INF
	var attacking_goal: HockeyGoal = _goal_1 if carrier_team == 0 else _goal_0
	if attacking_goal == null:
		return Vector3.INF
	return attacking_goal.global_position

func shake(trauma: float) -> void:
	_shake_trauma = minf(1.0, _shake_trauma + trauma)

func _ready() -> void:
	make_current()
	GameManager.goal_scored.connect(func(_t, _n, _a1, _a2) -> void: shake(1.0))
	GameManager.local_player_hit.connect(func(mag: float) -> void:
		if mag >= 3.0:
			shake(clampf(mag / 12.0, 0.2, 0.4)))
	GameManager.local_player_landed_hit.connect(func(mag: float) -> void:
		if mag >= 3.0:
			shake(clampf(mag / 16.0, 0.15, 0.3)))

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
# (but never exceeds) ±limit beyond that.
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

# Returns Vector3.INF when no opponent is within `threat_distance` of the
# player. Caller checks `is_inf(result.x)`.
func _find_nearest_threat(player_pos: Vector3) -> Vector3:
	if not _opponent_positions_getter.is_valid():
		return Vector3.INF
	var nearest_d_sq: float = threat_distance * threat_distance
	var nearest: Vector3 = Vector3.INF
	var opps: Array = _opponent_positions_getter.call()
	for opp_pos: Vector3 in opps:
		var dx: float = opp_pos.x - player_pos.x
		var dz: float = opp_pos.z - player_pos.z
		var d_sq: float = dx * dx + dz * dz
		if d_sq < nearest_d_sq:
			nearest_d_sq = d_sq
			nearest = Vector3(opp_pos.x, 0.0, opp_pos.z)
	return nearest

func _detect_breakaway(player_pos: Vector3, attack_dir: int) -> bool:
	if attack_dir == 0:
		return false
	if not _local_is_carrier_getter.is_valid() or not _local_is_carrier_getter.call():
		return false
	if not _opponent_positions_getter.is_valid():
		return false
	var af: float = float(attack_dir)
	var opps: Array = _opponent_positions_getter.call()
	for opp_pos: Vector3 in opps:
		var ahead: float = (opp_pos.z - player_pos.z) * af
		if ahead > 0.0 and ahead < breakaway_lookahead:
			return false
	return true

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

	if not _initialized:
		_smoothed_anchor = Vector3(
				(player_pos.x + puck_pos.x) * 0.5, 0.0, (player_pos.z + puck_pos.z) * 0.5)
		_initialized = true

	var attack_dir: int = _get_attacking_direction()

	# Breakaway engagement ramp. Drives the goal-extension below; ramping (not
	# binary) means a defender re-entering the lane eases the frame back in.
	var breakaway_now: float = 1.0 if _detect_breakaway(player_pos, attack_dir) else 0.0
	_smoothed_breakaway = lerpf(_smoothed_breakaway, breakaway_now, breakaway_smooth * delta)

	# ── Step 1: Build fit set ────────────────────────────────────────────────
	# Base: {player, puck}. Plus the nearest opponent within `threat_distance`,
	# so stickhandling under pressure widens the frame instead of locking tight.
	# Plus a virtual point that slides from player toward the attacking goal as
	# breakaway engagement ramps 0→1 — the zoom math naturally frames {player,
	# goal} during breakaways without a separate height override.
	var fit_min_x: float = minf(player_pos.x, puck_pos.x)
	var fit_max_x: float = maxf(player_pos.x, puck_pos.x)
	var fit_min_z: float = minf(player_pos.z, puck_pos.z)
	var fit_max_z: float = maxf(player_pos.z, puck_pos.z)
	var threat_pos: Vector3 = _find_nearest_threat(player_pos)
	if not is_inf(threat_pos.x):
		fit_min_x = minf(fit_min_x, threat_pos.x)
		fit_max_x = maxf(fit_max_x, threat_pos.x)
		fit_min_z = minf(fit_min_z, threat_pos.z)
		fit_max_z = maxf(fit_max_z, threat_pos.z)
	if _smoothed_breakaway > 0.001:
		var goal_pos: Vector3 = _get_attacking_goal_position()
		if not is_inf(goal_pos.x):
			var vx: float = lerpf(player_pos.x, goal_pos.x, _smoothed_breakaway)
			var vz: float = lerpf(player_pos.z, goal_pos.z, _smoothed_breakaway)
			fit_min_x = minf(fit_min_x, vx)
			fit_max_x = maxf(fit_max_x, vx)
			fit_min_z = minf(fit_min_z, vz)
			fit_max_z = maxf(fit_max_z, vz)
	var base_center: Vector3 = Vector3(
			(fit_min_x + fit_max_x) * 0.5, 0.0, (fit_min_z + fit_max_z) * 0.5)

	# ── Step 2: Dynamic zoom to fit the set ───────────────────────────────────
	var half_span_x: float = (fit_max_x - fit_min_x) * 0.5
	var half_span_z: float = (fit_max_z - fit_min_z) * 0.5
	var needed_x: float = (half_span_x + zoom_padding) / (tan_half_fov * aspect)
	var needed_z: float = (half_span_z + zoom_padding) / tan_half_fov
	var in_ozone: bool = attack_dir != 0 and \
			(player_pos.z * float(attack_dir)) > GameRules.BLUE_LINE_Z
	# User-facing camera-distance multiplier (Options → Game).
	var dist_mult: float = PlayerPrefs.camera_distance
	var effective_min: float = (ozone_min_height if in_ozone else min_height) * dist_mult
	var effective_max: float = max_height * dist_mult
	var target_height: float = clampf(maxf(needed_x, needed_z), effective_min, effective_max)

	var height_res: Array = _spring_damp(
			_current_height, target_height, _height_vel, smooth_time_height, delta)
	_current_height = height_res[0]
	_height_vel = height_res[1]

	var visible_half_x: float = tan_half_fov * aspect * _current_height
	var visible_half_z: float = tan_half_fov * _current_height

	# ── Step 3: Lead offset ───────────────────────────────────────────────────
	# Velocity lead (always-on): offset in skating direction scaled by speed.
	var vel_xz: Vector3 = Vector3(skater.velocity.x, 0.0, skater.velocity.z)
	var speed: float = vel_xz.length()
	var target_lead: Vector3 = Vector3.ZERO
	if speed > 0.5:  # ignore drift
		var t: float = clampf(speed / lead_full_speed, 0.0, 1.0)
		target_lead = (vel_xz / speed) * t * lead_distance

	# Zone lead (possession-aware additive). Smoothed possession sign keeps the
	# pull from snapping when the carrier changes.
	_smoothed_attack_dir = lerpf(_smoothed_attack_dir, float(attack_dir), bias_smooth_speed * delta)
	target_lead.z += _smoothed_attack_dir * zone_lead

	_smoothed_lead_offset = _smoothed_lead_offset.lerp(target_lead, lead_smooth * delta)
	var target_anchor: Vector3 = base_center + _smoothed_lead_offset

	# ── Step 4: Soft rink clamp ──────────────────────────────────────────────
	var safe_x: float = maxf(rink_half_width - visible_half_x, 0.0)
	var safe_z: float = maxf(rink_half_length - visible_half_z, 0.0)
	target_anchor.x = _soft_clamp(target_anchor.x, safe_x, clamp_softness)
	target_anchor.z = _soft_clamp(target_anchor.z, safe_z, clamp_softness)

	# ── Step 5: Smooth-damp the anchor (xz) ──────────────────────────────────
	var ax_res: Array = _spring_damp(
			_smoothed_anchor.x, target_anchor.x, _anchor_vel.x, smooth_time_anchor, delta)
	_smoothed_anchor.x = ax_res[0]
	_anchor_vel.x = ax_res[1]
	var az_res: Array = _spring_damp(
			_smoothed_anchor.z, target_anchor.z, _anchor_vel.z, smooth_time_anchor, delta)
	_smoothed_anchor.z = az_res[0]
	_anchor_vel.z = az_res[1]

	# ── Step 6: Compose camera position ──────────────────────────────────────
	# Tilt geometry is derived from the actual (smoothed) height so the view
	# anchor stays put during zoom transitions.
	var pitch: float = -90.0
	var tilt_z_offset: float = 0.0
	if PlayerPrefs.camera_mode == PlayerPrefs.CAMERA_MODE_TILTED:
		pitch = _TILTED_PITCH_DEG
		var off_axis_rad: float = deg_to_rad(90.0 + _TILTED_PITCH_DEG)  # 15° at -75° pitch
		var flip_sign: float = -1.0 if PlayerPrefs.attack_up and _local_team_id == 1 else 1.0
		tilt_z_offset = _current_height * tan(off_axis_rad) * flip_sign

	global_position = Vector3(
			_smoothed_anchor.x, _current_height, _smoothed_anchor.z + tilt_z_offset)

	# ── Step 7: Projection + rotation ────────────────────────────────────────
	# Ortho `size` matches perspective FOV's vertical extent so the same zone
	# frames in both modes.
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

	# ── Step 8: Shake ────────────────────────────────────────────────────────
	if _shake_trauma > 0.0:
		_shake_trauma = maxf(0.0, _shake_trauma - _SHAKE_DECAY * delta)
		global_position += Vector3(
			randf_range(-1.0, 1.0) * _shake_trauma * _SHAKE_MAG,
			0.0,
			randf_range(-1.0, 1.0) * _shake_trauma * _SHAKE_MAG)
