class_name GameCamera
extends Camera3D

# Top-down tilted camera, anchored on the local player. The mouse cursor IS
# the player's gaze: where the cursor points, the camera leans, and the
# further the cursor sits from the player the wider the camera zooms.
#
# Two carve-outs from "cursor only":
#   - Carrier velocity lead: skating with the puck adds a velocity-direction
#     offset to the cursor offset so the camera leans forward and widens
#     zoom without forcing the player to drag their cursor away from the
#     puck. Off-puck the camera is pure cursor-driven.
#   - Offensive-zone bias: past the attacking blue line and with the puck
#     loose or on the local team, the anchor shifts toward the goal
#     (positioning) so the goal comes into frame. Gated on possession —
#     a turnover smoothly releases the bias so the camera doesn't keep
#     pulling toward the goal while the play heads the other way. A zoom
#     floor still applies as a backup when the bias alone can't fit
#     player + goal.
#
# Predictability over expression (principle #9): no shake, no breakaway, no
# cinematic moments, no possession-change swings.

# ── Target ────────────────────────────────────────────────────────────────────
# Set by LocalController.setup() after the local skater is spawned.
@export var skater: Skater
@export var puck: Puck

# ── Cursor lean ───────────────────────────────────────────────────────────────
# The anchor (look-at) leans from the local player toward the world position
# under the cursor — the same input the player uses to aim. Cursor offset from
# the player is clamped to `max_cursor_dist`, then scaled by `cursor_weight`,
# so the anchor never offsets more than `max_cursor_dist * cursor_weight` from
# the player regardless of where the cursor sits.
@export var cursor_weight: float = 0.3
@export var max_cursor_dist: float = 8.0

# ── Carrier velocity lead ────────────────────────────────────────────────────
# Only active while the local player is carrying the puck. Adds a velocity-
# direction offset to the raw cursor offset before clamping, so skating with
# the puck naturally widens zoom AND leans the anchor forward — without
# forcing the player to pull their cursor away from the puck they're handling.
# Inactive when not carrying (off-puck feel stays pure cursor-driven).
@export var carry_lead_distance: float = 4.0    # max world-units at full speed
@export var carry_lead_full_speed: float = 12.0  # skater speed at which lead peaks

# ── Zoom ──────────────────────────────────────────────────────────────────────
# Height interpolates from `min_height` (cursor on player) to `max_height`
# (cursor at `max_cursor_dist` or beyond). Both ends scale by the user's
# `camera_distance` preference.
@export var min_height: float = 10.0
@export var max_height: float = 22.0

# ── Offensive-zone bias ──────────────────────────────────────────────────────
# Past the attacking blue line, the anchor shifts toward the goal so the goal
# comes into frame via positioning rather than zooming out. At
# `ozone_bias_fraction = 0.5` the anchor lands at the midpoint between player
# and goal. Engagement ramps over `OZONE_RAMP_DISTANCE` past the blue line so
# crossing isn't a hard step. A zoom floor still applies as a backup when the
# bias alone can't fit player + goal (e.g., near the blue line), based on the
# BIASED anchor's extent rather than the unbiased one.
@export var ozone_bias_fraction: float = 0.5
@export var ozone_zoom_padding: float = 2.0
@export var ozone_max_height: float = 25.0
# Ozone engagement ramp: distances past the attacking blue line at which
# engagement is 0 (start) and 1 (end). Negative `start` means the ramp begins
# BEFORE the line — useful so the camera is already partway engaged when the
# player actually crosses.
@export var ozone_ramp_start_distance: float = -1.0
@export var ozone_ramp_end_distance: float = 5.0
# How far ahead (seconds) we look at the player's velocity when deciding ozone
# engagement. Pre-empts both entry and exit so the camera anchor doesn't lag
# the player through the blue line on a fast skate-back / skate-forward.
const _OZONE_PREDICT_TIME: float = 0.25
# Possession engagement smooth rate; ~0.17s settle from full to none.
const _POSSESSION_SMOOTH: float = 6.0

# ── Smoothing (critical-damp time constants, seconds to ~95%) ─────────────────
# Settled but not laggy. Cursor flicks should ease rather than snap.
@export var smooth_time_anchor: float = 0.22
@export var smooth_time_height: float = 0.35

# ── Soft rink clamp ───────────────────────────────────────────────────────────
# Anchor is clamped so the visible frustum stays inside the rink. When the
# player is near the side boards, this naturally pulls the anchor toward the
# rink interior to avoid wasting screen on crowd (boards-bias falls out of
# the geometry without a separate concept).
@export var clamp_softness: float = 3.0

# ── Player visibility clamp ──────────────────────────────────────────────────
# The local player must always be visible — this caps how far the anchor can
# offset from the player so the cursor lean + ozone bias stack can never push
# the player off the bottom of the screen. `player_screen_margin = 0.15` means
# the player is always at least 15% of half-screen-height from any edge, with
# some "behind the player" view that opens up when the cursor reaches.
@export var player_screen_margin: float = 0.15
@export var player_clamp_softness: float = 1.5

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
# 1.0 when local team has (or could fight for) the puck; 0.0 when an opponent
# is the carrier. Smoothly tracks so a turnover gracefully releases the ozone
# bias.
var _possession_engagement: float = 1.0

func set_local_team_id(team_id: int) -> void:
	_local_team_id = team_id

# No-op: the new camera derives attack direction from `_local_team_id` directly
# and doesn't need a carrier-team callable. Stub exists so the LocalController
# can forward `set_goal_context` unconditionally — the classic camera uses it.
func set_goal_context(_goal_0: HockeyGoal, _goal_1: HockeyGoal, _carrier_team_getter: Callable) -> void:
	pass

# Team 0 defends +Z (attacks -Z). Team 1 defends -Z (attacks +Z).
# See GameManager._assign_goals_to_teams.
func _attack_dir() -> int:
	if _local_team_id == 0:
		return -1
	if _local_team_id == 1:
		return 1
	return 0

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
	# Softness can't exceed limit, or the asymptote target would too.
	var soft: float = minf(softness, limit)
	var s: float = signf(x)
	var ax: float = absf(x)
	var knee: float = maxf(limit - soft, 0.0)
	if ax <= knee:
		return x
	var t: float = (ax - knee) / soft
	return s * (knee + soft * t / (1.0 + t))

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
	var tan_half_fov: float = tan(deg_to_rad(fov) * 0.5)
	var aspect: float = get_viewport().get_visible_rect().size.x / get_viewport().get_visible_rect().size.y

	if not _initialized:
		_smoothed_anchor = Vector3(player_pos.x, 0.0, player_pos.z)
		_initialized = true

	# ── Step 1: Cursor offset from player ────────────────────────────────────
	# The cursor IS the player's gaze.
	var cursor_pos: Vector3 = _cursor_world_pos()
	cursor_pos.y = 0.0
	var raw_offset: Vector3 = cursor_pos - player_pos
	raw_offset.y = 0.0

	# Carrier velocity lead: when carrying, add a velocity-direction offset to
	# the cursor offset. The same machinery below (clamp → lean → zoom) then
	# both widens zoom and leans anchor forward while skating with the puck,
	# without making the player drag their cursor away from the puck. Inactive
	# off-puck so non-carry feel stays pure cursor-driven.
	var is_carrying: bool = puck != null and puck.get_carrier() == skater
	if is_carrying:
		var vel_xz: Vector3 = Vector3(skater.velocity.x, 0.0, skater.velocity.z)
		var speed: float = vel_xz.length()
		if speed > 0.5:
			var t_speed: float = clampf(speed / carry_lead_full_speed, 0.0, 1.0)
			raw_offset += (vel_xz / speed) * t_speed * carry_lead_distance

	# Clamp the combined offset's magnitude. After clamping, distance drives
	# both anchor lean and zoom width — same number, two effects.
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
	# Off-puck the camera is shift-only: zoom stays at min_height regardless
	# of where the cursor sits. Carrying re-enables cursor-distance zoom so
	# the player can widen the frame for long passes / shots while still
	# getting the velocity-lead widening when skating.
	var t_zoom: float = 0.0
	if is_carrying and max_cursor_dist > 0.001:
		t_zoom = clamped_dist / max_cursor_dist
	var dist_mult: float = PlayerPrefs.camera_distance
	var target_height: float = lerpf(min_height, max_height, t_zoom) * dist_mult

	# Possession engagement: 1.0 when my team has the puck (or it's loose),
	# 0.0 when an opponent has it. A turnover releases the ozone bias smoothly
	# so the camera doesn't keep pulling toward the goal when the play is
	# heading the other way.
	var raw_possession: float = 1.0
	if puck != null and _local_team_id != -1:
		var carrier: Skater = puck.get_carrier()
		if carrier != null and carrier.get_team_id() != _local_team_id:
			raw_possession = 0.0
	_possession_engagement = lerpf(
			_possession_engagement, raw_possession, _POSSESSION_SMOOTH * delta)

	# Ozone bias + zoom floor: past the attacking blue line, shift the anchor
	# toward the goal (positioning) and lift zoom only as a backup when the
	# shift alone can't fit player + goal in frame. Engagement uses a
	# velocity-predicted player position rather than the current position so
	# the bias releases (or engages) before the player physically crosses the
	# blue line — prevents the anchor from lagging off-screen during a fast
	# skate-back through the line.
	var attack_dir: int = _attack_dir()
	if attack_dir != 0:
		var predicted_z: float = player_pos.z + skater.velocity.z * _OZONE_PREDICT_TIME
		var dist_past_line: float = (predicted_z * float(attack_dir)) - GameRules.BLUE_LINE_Z
		var engagement: float = smoothstep(
				ozone_ramp_start_distance, ozone_ramp_end_distance, dist_past_line) \
				* _possession_engagement
		if engagement > 0.001:
			var goal_z: float = float(attack_dir) * GameRules.GOAL_LINE_Z
			var goal_offset: float = goal_z - player_pos.z  # signed; toward the goal
			var bias_z: float = goal_offset * ozone_bias_fraction * engagement
			target_anchor.z += bias_z
			var biased_anchor_z: float = player_pos.z + bias_z
			var dist_to_player: float = absf(biased_anchor_z - player_pos.z)
			var dist_to_goal: float = absf(biased_anchor_z - goal_z)
			var max_extent_z: float = maxf(dist_to_player, dist_to_goal)
			var needed_height: float = max_extent_z / tan_half_fov + ozone_zoom_padding
			needed_height = minf(needed_height, ozone_max_height) * dist_mult
			target_height = maxf(target_height, needed_height)

	# Spring-damp lag compensation. The smoothed anchor lags a moving target
	# by `velocity * smooth_time` at steady state — at high backskate speeds
	# this can push the player off the bottom of the frame. Adding
	# `velocity * smooth_time_anchor` to the target cancels the lag exactly,
	# so at any constant velocity the player stays at their intended screen
	# position. The spring still smooths *changes* in velocity (the smoothing
	# we want); constant motion is no longer behind the camera.
	target_anchor.x += skater.velocity.x * smooth_time_anchor
	target_anchor.z += skater.velocity.z * smooth_time_anchor

	# ── Step 4: Spring-damp height ───────────────────────────────────────────
	var height_res: Array = _spring_damp(
			_current_height, target_height, _height_vel, smooth_time_height, delta)
	_current_height = height_res[0]
	_height_vel = height_res[1]

	# ── Step 5a: Soft rink clamp on anchor ───────────────────────────────────
	# Subtracting visible_half_* makes the clamp tighten as zoom widens — the
	# anchor pulls toward rink center when the visible frustum is wide enough
	# to threaten clipping past the boards. At the side boards this naturally
	# reclaims screen space from the crowd; at low zoom (visible_half < rink_half)
	# the player follows freely.
	var visible_half_x: float = tan_half_fov * aspect * _current_height
	var visible_half_z: float = tan_half_fov * _current_height
	var safe_x: float = maxf(rink_half_width - visible_half_x, 0.0)
	var safe_z: float = maxf(rink_half_length - visible_half_z, 0.0)
	target_anchor.x = _soft_clamp(target_anchor.x, safe_x, clamp_softness)
	target_anchor.z = _soft_clamp(target_anchor.z, safe_z, clamp_softness)

	# ── Step 5b: Player visibility clamp ─────────────────────────────────────
	# Cap the anchor offset from the player so cursor lean + ozone bias stack
	# can never push the player off-screen. Applied AFTER the rink clamp so
	# it wins when they conflict — a sliver of crowd is acceptable, losing the
	# player is not.
	var max_offset_x: float = visible_half_x * (1.0 - player_screen_margin)
	var max_offset_z: float = visible_half_z * (1.0 - player_screen_margin)
	target_anchor.x = player_pos.x + _soft_clamp(
			target_anchor.x - player_pos.x, max_offset_x, player_clamp_softness)
	target_anchor.z = player_pos.z + _soft_clamp(
			target_anchor.z - player_pos.z, max_offset_z, player_clamp_softness)

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
