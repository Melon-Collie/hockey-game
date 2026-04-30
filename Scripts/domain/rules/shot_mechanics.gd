class_name ShotMechanics

# Pure shot-release math. Callers gather world/local positions and pass them in;
# these functions compute direction + power without touching the engine.
#
# Returns a Dictionary with keys:
#   direction: Vector3 — normalized, includes Y if elevated
#   power: float       — final shot power after backhand penalty / charge curve

class WristerConfig:
	var min_wrister_power: float = 0.0
	var max_wrister_power: float = 0.0
	var max_wrister_charge_distance: float = 0.0
	var backhand_power_coefficient: float = 0.0
	var quick_shot_power: float = 0.0
	var quick_shot_threshold: float = 0.0
	var quick_shot_elevation: float = 0.0       # fixed Y for snap releases
	var elevation_target_height: float = 0.0    # world Y to hit at the goal line
	var elevation_blade_height: float = 0.0     # puck starting world Y
	var elevation_gravity: float = 0.0          # m/s²
	var elevation_goal_line_z: float = 0.0      # absolute Z of goal lines
	var max_apex_above_blade: float = 1.5       # cap apex above blade (m); bounds missed shots
	var attacking_goal_z: float = 0.0           # signed Z of offensive net; 0 = unknown (legacy)
	var toward_net_dot_threshold: float = 0.5   # cos(60°) — shots within this cone use full math
	var away_from_net_y: float = 0.10           # low fallback Y direction for non-net shots

class SlapperConfig:
	var min_slapper_power: float = 0.0
	var max_slapper_power: float = 0.0
	var max_slapper_charge_time: float = 0.0
	var elevation_target_height: float = 0.0
	var elevation_blade_height: float = 0.0
	var elevation_gravity: float = 0.0
	var elevation_goal_line_z: float = 0.0
	var max_apex_above_blade: float = 1.5
	var attacking_goal_z: float = 0.0
	var toward_net_dot_threshold: float = 0.5
	var away_from_net_y: float = 0.10

# Wrister release. Quick shots (very short charge) aim along player→blade —
# the blade tracks the cursor via IK but ROM constraints prevent it going
# behind the player, so this direction is always valid. Full wristers aim
# from the drag direction with power scaling over the charge distance.
# Backhand is detected by blade X sign in upper-body-local space: positive X
# is a backhand for a left-handed player, negative X for a right-handed player.
static func release_wrister(
		player_pos: Vector3,
		mouse_world_pos: Vector3,
		blade_world_pos: Vector3,
		is_backhand: bool,
		is_elevated: bool,
		charge_distance: float,
		cfg: WristerConfig,
		charge_direction: Vector3 = Vector3.ZERO) -> Dictionary:
	var target := Vector3(mouse_world_pos.x, 0.0, mouse_world_pos.z)
	var charge_t: float = clampf(charge_distance / cfg.max_wrister_charge_distance, 0.0, 1.0)

	if charge_t < cfg.quick_shot_threshold:
		# Quick shot — aim player→blade. The blade tracks the cursor via IK so
		# aim is accurate, and ROM constraints mean the blade can never be behind
		# the player, so this direction can't flip backward when the cursor is.
		var player_xz := Vector3(player_pos.x, 0.0, player_pos.z)
		var blade_xz := Vector3(blade_world_pos.x, 0.0, blade_world_pos.z)
		var dir: Vector3 = (blade_xz - player_xz).normalized()
		if dir.length_squared() < 0.0001:
			dir = (target - player_xz).normalized()
		var quick_y: float = cfg.quick_shot_elevation if is_elevated else 0.0
		return {
			"direction": Vector3(dir.x, quick_y, dir.z).normalized(),
			"power": cfg.quick_shot_power,
		}

	# Full wrister — shot goes where the blade was dragged, power scales with charge.
	# charge_direction is the world-space direction the blade was sweeping at release;
	# fall back to player→mouse only when no drag direction is available.
	var shot_dir: Vector3
	if charge_direction.length_squared() > 0.0001:
		shot_dir = Vector3(charge_direction.x, 0.0, charge_direction.z).normalized()
	else:
		var player_xz := Vector3(player_pos.x, 0.0, player_pos.z)
		shot_dir = (target - player_xz).normalized()
	var power: float = lerpf(cfg.min_wrister_power, cfg.max_wrister_power, charge_t)

	if is_backhand:
		power *= cfg.backhand_power_coefficient

	var y: float = 0.0
	if is_elevated:
		y = _elevation_y(player_pos, shot_dir, power, cfg.elevation_target_height,
				cfg.elevation_blade_height, cfg.elevation_gravity, cfg.elevation_goal_line_z,
				cfg.attacking_goal_z, cfg.max_apex_above_blade,
				cfg.away_from_net_y, cfg.toward_net_dot_threshold)
	return {
		"direction": Vector3(shot_dir.x, y, shot_dir.z).normalized(),
		"power": power,
	}

# Slapper release — power scales linearly with charge time.
#
# shot_direction: when non-zero, used as the shot direction directly (locked
# at press time); falls back to blade→mouse when zero (backwards compat).
static func release_slapper(
		blade_world_pos: Vector3,
		mouse_world_pos: Vector3,
		is_elevated: bool,
		charge_time: float,
		cfg: SlapperConfig,
		shot_direction: Vector3 = Vector3.ZERO) -> Dictionary:
	var shot_dir: Vector3
	if shot_direction.length_squared() > 0.0001:
		shot_dir = Vector3(shot_direction.x, 0.0, shot_direction.z).normalized()
	else:
		var blade_xz := Vector3(blade_world_pos.x, 0.0, blade_world_pos.z)
		var target := Vector3(mouse_world_pos.x, 0.0, mouse_world_pos.z)
		shot_dir = (target - blade_xz).normalized()
	var charge_t: float = clampf(charge_time / cfg.max_slapper_charge_time, 0.0, 1.0)
	var power: float = lerpf(cfg.min_slapper_power, cfg.max_slapper_power, charge_t)

	var y: float = 0.0
	if is_elevated:
		y = _elevation_y(blade_world_pos, shot_dir, power, cfg.elevation_target_height,
				cfg.elevation_blade_height, cfg.elevation_gravity, cfg.elevation_goal_line_z,
				cfg.attacking_goal_z, cfg.max_apex_above_blade,
				cfg.away_from_net_y, cfg.toward_net_dot_threshold)
	return {
		"direction": Vector3(shot_dir.x, y, shot_dir.z).normalized(),
		"power": power,
	}

# Compute the Y direction component for an elevated shot.
#
# Two-stage classification:
#   1. If `attacking_goal_z` is set (team known) and the shot's XZ direction is
#      within `toward_net_dot_threshold` of the vector to that goal, run the
#      full ballistic-targeting math. Otherwise return `away_from_net_y` — a
#      small fixed loft so backward / lateral shots don't try to arc to a goal.
#   2. The ballistic math computes Y to land at `target_height` at the goal
#      line, then caps the resulting initial vertical velocity so the apex
#      can't exceed `max_apex_above_blade`. This bounds missed shots from
#      flying over the boards while still letting on-net shots arrive on net.
#
# Apex math: max v_y = sqrt(2g · max_apex). When the natural y exceeds that,
# solve y from v_y = power·y/sqrt(1+y²) at v_y_max →
# y = v_y_max / sqrt(power² − v_y_max²).
static func _elevation_y(
		origin: Vector3,
		shot_dir: Vector3,
		power: float,
		target_height: float,
		blade_height: float,
		gravity: float,
		goal_line_z: float,
		attacking_goal_z: float,
		max_apex_above_blade: float,
		away_from_net_y: float,
		toward_net_dot_threshold: float) -> float:
	var goal_z: float
	var is_toward_net: bool = true
	if absf(attacking_goal_z) > 0.001:
		goal_z = attacking_goal_z
		var to_goal_xz := Vector2(0.0, goal_z) - Vector2(origin.x, origin.z)
		var shot_xz := Vector2(shot_dir.x, shot_dir.z)
		if to_goal_xz.length_squared() > 0.0001 and shot_xz.length_squared() > 0.0001:
			is_toward_net = shot_xz.normalized().dot(to_goal_xz.normalized()) >= toward_net_dot_threshold
	else:
		goal_z = goal_line_z if shot_dir.z >= 0.0 else -goal_line_z

	if not is_toward_net:
		return away_from_net_y

	var D: float = maxf(absf(goal_z - origin.z), 2.0)
	var y: float = (target_height - blade_height + 0.5 * gravity * D * D / (power * power)) / D
	var v_y_max: float = sqrt(2.0 * gravity * max_apex_above_blade)
	var v_y: float = power * y / sqrt(1.0 + y * y)
	if v_y > v_y_max and power > v_y_max:
		y = v_y_max / sqrt(power * power - v_y_max * v_y_max)
	return maxf(y, 0.0)

# Should a blade-in-wall squeeze auto-release the puck? Pure threshold check.
static func should_release_on_wall_pin(squeeze: float, threshold: float) -> bool:
	return squeeze > threshold
