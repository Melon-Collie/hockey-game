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
@export var zone_lead: float = 1.5
@export var bias_smooth_speed: float = 0.8      # smooths possession transitions

# ── Threat-aware framing ──────────────────────────────────────────────────────
# Opponents within this distance of the local player are included in the
# zoom-fit so pressure widens the frame instead of locking tight on stickwork.
# Anchor stays on the player; only the zoom changes.
@export var threat_distance: float = 11.0

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

# Tilted-camera pitch is driven by PlayerPrefs.tilt_angle (positive degrees
# below horizontal; 90 = straight down). Perspective foreshortening grows as
# tilt_angle decreases — Y-axis cursor speed becomes increasingly non-uniform
# across the screen — so the pref is clamped between 70° and 90°.

# ── Goal Context (set via set_goal_context) ───────────────────────────────────
var _goal_0: HockeyGoal = null  # Team 0's defended goal
var _goal_1: HockeyGoal = null  # Team 1's defended goal
var _carrier_team_getter: Callable  # () -> int team_id, or -1 if no carrier
var _local_team_id: int = -1

# ── Play Context (set via set_play_context) ──────────────────────────────────
var _opponent_positions_getter: Callable  # () -> Array[Vector3]

# ── Runtime ───────────────────────────────────────────────────────────────────
var _initialized: bool = false
var _current_height: float = 15.0
var _height_vel: float = 0.0
var _smoothed_anchor: Vector3 = Vector3.ZERO
var _anchor_vel: Vector3 = Vector3.ZERO
var _smoothed_attack_dir: float = 0.0
var _smoothed_lead_offset: Vector3 = Vector3.ZERO

func set_goal_context(goal_0: HockeyGoal, goal_1: HockeyGoal, carrier_team_getter: Callable) -> void:
	_goal_0 = goal_0
	_goal_1 = goal_1
	_carrier_team_getter = carrier_team_getter

func set_play_context(opponent_positions_getter: Callable) -> void:
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
		_smoothed_anchor = Vector3(player_pos.x, 0.0, player_pos.z)
		_initialized = true

	var attack_dir: int = _get_attacking_direction()

	# ── Step 1: Lead offset ──────────────────────────────────────────────────
	# Computed first so the anchor is available to the zoom math below.
	# Velocity lead (always-on): offset in skating direction scaled by speed.
	# Constant offset at a constant speed → cursor-to-world stays predictable.
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

	# ── Step 2: Anchor = local player + lead ─────────────────────────────────
	# Mitts uses mouse-as-world-pointer (stickhandling, poke-checking, passing
	# all aim into world space — same model as a League skill-shot). For aim to
	# feel consistent, the player's screen position must be a stable function
	# of state. So the anchor follows ONLY the local player; the fit-set below
	# drives zoom only.
	var target_anchor: Vector3 = Vector3(player_pos.x, 0.0, player_pos.z) + _smoothed_lead_offset

	# ── Step 3: Zoom from extents relative to the anchor ────────────────────
	# Find the half-width / half-depth the camera needs to reach to keep these
	# points visible: {player, puck, nearest threat}. Threat widens under
	# pressure without moving the anchor — anchor stays on the player.
	var max_dx: float = absf(player_pos.x - target_anchor.x)
	var max_dz: float = absf(player_pos.z - target_anchor.z)
	max_dx = maxf(max_dx, absf(puck_pos.x - target_anchor.x))
	max_dz = maxf(max_dz, absf(puck_pos.z - target_anchor.z))
	var threat_pos: Vector3 = _find_nearest_threat(player_pos)
	if not is_inf(threat_pos.x):
		max_dx = maxf(max_dx, absf(threat_pos.x - target_anchor.x))
		max_dz = maxf(max_dz, absf(threat_pos.z - target_anchor.z))

	var needed_x: float = (max_dx + zoom_padding) / (tan_half_fov * aspect)
	var needed_z: float = (max_dz + zoom_padding) / tan_half_fov
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

	# ── Step 4: Soft rink clamp ──────────────────────────────────────────────
	# Clamp the anchor (= look-at point) to the rink itself, not to "rink minus
	# visible_half". This means at low zoom the camera VIEW can extend past the
	# boards (showing some crowd), but the player stays at screen center — the
	# whole point of option C. Anchor extension past boards comes from lead,
	# which is bounded; soft clamp eases it back without snapping.
	target_anchor.x = _soft_clamp(target_anchor.x, rink_half_width, clamp_softness)
	target_anchor.z = _soft_clamp(target_anchor.z, rink_half_length, clamp_softness)

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
	# Tilt geometry derives from the smoothed height so the view anchor stays
	# put during zoom transitions. At tilt_angle = 90° (straight down) the
	# off-axis offset collapses to zero and the camera looks straight down.
	var off_axis_rad: float = deg_to_rad(90.0 - PlayerPrefs.tilt_angle)
	var flip_sign: float = -1.0 if PlayerPrefs.attack_up and _local_team_id == 1 else 1.0
	var tilt_z_offset: float = _current_height * tan(off_axis_rad) * flip_sign

	global_position = Vector3(
			_smoothed_anchor.x, _current_height, _smoothed_anchor.z + tilt_z_offset)

	# ── Step 7: Rotation ─────────────────────────────────────────────────────
	var flip_y: float = 180.0 if PlayerPrefs.attack_up and _local_team_id == 1 else 0.0
	rotation_degrees = Vector3(-PlayerPrefs.tilt_angle, flip_y, 0.0)
