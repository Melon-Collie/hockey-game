class_name ShotMechanics

# Pure shot-release math. Callers gather world/local positions and pass them in;
# these functions compute direction + power without touching the engine.

class ShotResult:
	var direction: Vector3   # normalized, includes Y if elevated
	var power: float         # final shot power after backhand penalty / charge curve

	static func make(d: Vector3, p: float) -> ShotResult:
		var r := ShotResult.new()
		r.direction = d
		r.power = p
		return r

# ── Loft levels ───────────────────────────────────────────────────────────────
# Elevation is a player-selected LOFT LEVEL (scroll wheel), not a computed arc:
#   0 = FLAT  — puck stays on the ice
#   1 = LOW   — a saucer flip (~0.25 m apex): clears stick blades, lands and slides
#   2 = HIGH  — a rising shot (~1.22 m apex): apex sits at the crossbar, so it
#               only clears the bar while still rising (miss high only on a soft
#               floaty loft from range, not an easy sail-over from the slot)
# Each level maps to a FIXED VERTICAL LAUNCH SPEED (m/s), independent of shot
# power and shot direction. Where the puck sits on its arc when it reaches the
# net is therefore emergent from loft × power × distance — range and charge
# management are the skill, not a solved-for arrival height. Levels apply
# identically to quick shots (passes), wristers, and slappers, in every
# direction — a saucer pass, a flip clear, and a top-shelf snipe are all the
# same mechanic. (The old system ballistically solved Y to arrive at a target
# height at the goal line, which both trivialized top-corner aim and made
# toward-net saucer passes impossible.)
const ELEVATION_FLAT: int = 0
const ELEVATION_LOW: int = 1
const ELEVATION_HIGH: int = 2

# Cap on the pre-normalization Y/XZ ratio of a lofted direction: 1.0 = 45°.
# This is a degenerate-input guard, not a feel lever — it stops y from running
# toward vertical as power approaches the level's launch speed. At 45° it
# binds only below ~6.9 m/s at HIGH loft, which no legit release reaches (the
# softest is a min-charge backhand wrister ~8.4 m/s), so every real shot gets
# its full level v_y and steep soft flips (chip over a sprawled goalie, a
# rainbow flip clear) stay possible. Keeps every legit direction under
# ShotReleaseRules.MAX_DIRECTION_Y (normalized y at 45° is ~0.707 vs the 0.75
# clamp) so the host's forged-direction clamp never touches an honest shot.
const MAX_LOFT_RATIO: float = 1.0

class WristerConfig:
	var min_wrister_power: float = 0.0
	var max_wrister_power: float = 0.0
	var max_wrister_charge_distance: float = 0.0
	var backhand_power_coefficient: float = 0.0
	var quick_shot_power: float = 0.0
	var loft_vy_low: float = 0.0                # vertical launch speed (m/s), level 1
	var loft_vy_high: float = 0.0               # vertical launch speed (m/s), level 2

class SlapperConfig:
	var min_slapper_power: float = 0.0
	var max_slapper_power: float = 0.0
	var max_slapper_charge_time: float = 0.0
	var loft_vy_low: float = 0.0
	var loft_vy_high: float = 0.0

# Wrister release. HARD BINARY — a quick shot and a charged wrister are two
# distinct shots, with NO blend between them. Which one fires is decided by the
# INPUT at the call site (not any threshold in here) and passed in as is_quick_shot:
#   - QUICK SHOT (the dedicated quick_shot button, via _fire_quick_shot): aims
#     player→blade (the blade tracks the cursor via ROM-clamped IK, so aim is
#     accurate and can never point behind the player) at the fixed quick/pass power.
#   - WRISTER (the LMB shoot button, via _release_wrister): aims along the DRAG
#     (the swept cursor direction) at charged power. The drag direction IS the aim —
#     this is the defining mechanic of the shot, so it is never diluted.
# The two live on separate buttons precisely so there's no tap-vs-hold guess: the
# old hold-time classifier made an ordinary tap that lingered a few ticks fire a
# wrister when the player expected a snap. There is intentionally no blend band:
# dragging to aim is the core of the game, and mixing the body-relative tap
# direction into charged shots both muddies the feel and — because tap_dir depends
# on the predicted body position — is a client/host divergence source. Netcode
# upshot: a charged wrister's aim (the drag vector) is body-independent and
# identical on client and host.
# Backhand is detected by blade X sign in upper-body-local space: positive X is a
# backhand for a left-handed player, negative for a righty.
static func release_wrister(
		player_pos: Vector3,
		mouse_world_pos: Vector3,
		blade_world_pos: Vector3,
		is_backhand: bool,
		elevation_level: int,
		charge_distance: float,
		cfg: WristerConfig,
		charge_direction: Vector3 = Vector3.ZERO,
		is_quick_shot: bool = false) -> ShotResult:
	var target := Vector3(mouse_world_pos.x, 0.0, mouse_world_pos.z)
	var player_xz := Vector3(player_pos.x, 0.0, player_pos.z)

	if is_quick_shot:
		# QUICK SHOT — aim player→blade at fixed quick/pass power. Loft rides
		# the same level table as charged shots: level 1 at pass power is the
		# saucer pass, level 2 the flip.
		var blade_xz := Vector3(blade_world_pos.x, 0.0, blade_world_pos.z)
		var tap_dir: Vector3 = (blade_xz - player_xz).normalized()
		if tap_dir.length_squared() < 0.0001:
			tap_dir = (target - player_xz).normalized()
		var tap_y: float = loft_y(cfg.quick_shot_power,
				_loft_vy(elevation_level, cfg.loft_vy_low, cfg.loft_vy_high))
		return ShotResult.make(
				Vector3(tap_dir.x, tap_y, tap_dir.z).normalized(),
				cfg.quick_shot_power)

	# WRISTER — aim along the drag, power scaling with charge. Falls back to
	# player→mouse only when no drag direction was recorded.
	var charge_t: float = clampf(charge_distance / cfg.max_wrister_charge_distance, 0.0, 1.0)
	var wrister_dir: Vector3
	if charge_direction.length_squared() > 0.0001:
		wrister_dir = Vector3(charge_direction.x, 0.0, charge_direction.z).normalized()
	else:
		wrister_dir = (target - player_xz).normalized()
	var power: float = lerpf(cfg.min_wrister_power, cfg.max_wrister_power, charge_t)
	if is_backhand:
		power *= cfg.backhand_power_coefficient

	var y: float = loft_y(power, _loft_vy(elevation_level, cfg.loft_vy_low, cfg.loft_vy_high))
	return ShotResult.make(
			Vector3(wrister_dir.x, y, wrister_dir.z).normalized(),
			power)

# Slapper release — power scales linearly with charge time.
#
# shot_direction: when non-zero, used as the shot direction directly (locked
# at press time); falls back to blade→mouse when zero (backwards compat).
static func release_slapper(
		blade_world_pos: Vector3,
		mouse_world_pos: Vector3,
		elevation_level: int,
		charge_time: float,
		cfg: SlapperConfig,
		shot_direction: Vector3 = Vector3.ZERO) -> ShotResult:
	var shot_dir: Vector3
	if shot_direction.length_squared() > 0.0001:
		shot_dir = Vector3(shot_direction.x, 0.0, shot_direction.z).normalized()
	else:
		var blade_xz := Vector3(blade_world_pos.x, 0.0, blade_world_pos.z)
		var target := Vector3(mouse_world_pos.x, 0.0, mouse_world_pos.z)
		shot_dir = (target - blade_xz).normalized()
	var charge_t: float = clampf(charge_time / cfg.max_slapper_charge_time, 0.0, 1.0)
	var power: float = lerpf(cfg.min_slapper_power, cfg.max_slapper_power, charge_t)

	var y: float = loft_y(power, _loft_vy(elevation_level, cfg.loft_vy_low, cfg.loft_vy_high))
	return ShotResult.make(
			Vector3(shot_dir.x, y, shot_dir.z).normalized(),
			power)

# Vertical launch speed (m/s) for a loft level. Levels above HIGH clamp to
# high — the input decode already bounds the wire value, this is belt-and-braces.
static func _loft_vy(elevation_level: int, vy_low: float, vy_high: float) -> float:
	if elevation_level <= ELEVATION_FLAT:
		return 0.0
	if elevation_level == ELEVATION_LOW:
		return vy_low
	return vy_high

# Y direction component (pre-normalization Y/XZ ratio) that gives a shot fired
# at `power` a vertical launch speed of `loft_vy`, exactly:
#   v_y = power · y / sqrt(1 + y²)  →  y = loft_vy / sqrt(power² − loft_vy²)
# Since loft_vy is per-level constant, the apex (v_y²/2g) is the same for every
# shot at that level — charge buys pace, not height, so the two aim axes stay
# orthogonal. When power can't meaningfully exceed loft_vy (a very soft flip),
# the ratio is capped at MAX_LOFT_RATIO instead of running toward vertical.
static func loft_y(power: float, loft_vy: float) -> float:
	if loft_vy <= 0.0:
		return 0.0
	var max_vy_at_cap: float = power * MAX_LOFT_RATIO / sqrt(1.0 + MAX_LOFT_RATIO * MAX_LOFT_RATIO)
	if loft_vy >= max_vy_at_cap:
		return MAX_LOFT_RATIO
	return loft_vy / sqrt(power * power - loft_vy * loft_vy)

# Should a blade-in-wall squeeze auto-release the puck? Pure threshold check.
static func should_release_on_wall_pin(squeeze: float, threshold: float) -> bool:
	return squeeze > threshold
