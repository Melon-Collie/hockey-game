class_name ShotMechanics

# Pure shot-release math. Callers gather world/local positions and pass them in;
# these functions compute direction + power without touching the engine.

class ShotResult:
	var direction: Vector3   # normalized, includes Y if elevated
	var power: float         # final shot power after backhand penalty / charge curve

	# Fills `out` when provided (a caller-owned scratch for hot paths that re-solve
	# every tick), else allocates a fresh instance.
	static func make(d: Vector3, p: float, out: ShotResult = null) -> ShotResult:
		var r: ShotResult = out if out != null else ShotResult.new()
		r.direction = d
		r.power = p
		return r

# ── Loft levels ───────────────────────────────────────────────────────────────
# Elevation is a player-selected LOFT LEVEL (scroll wheel), not a computed arc:
#   0 = FLAT  — puck stays on the ice
#   1 = LOW   — a saucer flip (~0.26 m apex): clears stick blades, lands and slides
#   2 = HIGH  — a rising shot (~1.12 m apex, puck top ~1.14 m): the peak sits a
#               clean ~5 cm UNDER the crossbar's inner edge (1.19 m), so a HIGH
#               shot snipes the top of the net but its disc never reaches the bar
#               to sail over it. Apex height is a FIXED ceiling (v_y is power-
#               independent), so raising shot power can't put a shot over the net —
#               it only pushes the apex DISTANCE out (see v_y default on
#               SkaterController.loft_vertical_speed_high for the tuning history).
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
# binds only below ~6.6 m/s at HIGH loft (v_y·√2). Since the wrister floor dropped to
# 10 m/s (soft touch passes), the very softest release — a min-power backhand
# from a low-Hands skater, ~6.4 m/s — can now reach the cap, flattening that
# flip to 45° instead of running vertical: exactly the intended behavior (a
# soft chip over a sprawled goalie stays possible, never a straight-up pop).
# Every other release gets its full level v_y. Keeps every legit direction
# under ShotReleaseRules.MAX_DIRECTION_Y (normalized y at 45° is ~0.707 vs the
# 0.75 clamp) so the host's forged-direction clamp never touches an honest shot.
const MAX_LOFT_RATIO: float = 1.0

class WristerConfig:
	var min_wrister_power: float = 0.0
	var max_wrister_power: float = 0.0
	var backhand_power_coefficient: float = 0.0
	var quick_shot_power: float = 0.0
	var loft_vy_low: float = 0.0                # vertical launch speed (m/s), level 1
	var loft_vy_high: float = 0.0               # vertical launch speed (m/s), level 2
	# ── Power model (see wrister_power_t) ──
	# Cursor speed (m/s of screen-space pointer travel, already scaled by the
	# player's Shot Power Sensitivity) that reads as a full-power release.
	# <= 0.0 disables the wrister (returns zero power).
	var full_sweep_speed: float = 0.0
	# Feel-curve exponent on the 0..1 power parameter. < 1.0 is top-end
	# generous (an ordinary confident flick lands high in the band); 1.0 is
	# linear. <= 0.0 means linear.
	var power_curve: float = 0.0

class SlapperConfig:
	var min_slapper_power: float = 0.0
	var max_slapper_power: float = 0.0
	var max_slapper_charge_time: float = 0.0
	var loft_vy_low: float = 0.0
	var loft_vy_high: float = 0.0
	# One-timer momentum transfer (0 disables → a standing slapshot is untouched).
	var one_timer_feed_transfer: float = 0.0
	var one_timer_max_power: float = 0.0

# ── Wrister power model (pure mouse speed) ────────────────────────────────────
# Normalized 0..1 charged-wrister power from a single signal: CURSOR SPEED —
# the raw screen-space pointer speed at release, scaled by the player's Shot
# Power Sensitivity (so the feel is DPI-independent). Distance dragged does not
# enter: the drag vector is the aim, its *speed* is the power. A slow deliberate
# sweep is a soft touch pass; a hard flick is a full shot. power_curve then
# shapes the parameter — the feel curve (< 1.0 is top-end generous, so an
# ordinary confident flick lands high in the band). All wrister shapes fall out
# of this one axis: slow → soft pass-weight wrister, fast → full wrister.
static func wrister_power_t(sweep_speed: float, cfg: WristerConfig) -> float:
	if cfg.full_sweep_speed <= 0.0:
		return 0.0
	var t: float = clampf(sweep_speed / cfg.full_sweep_speed, 0.0, 1.0)
	if cfg.power_curve > 0.0:
		t = pow(t, cfg.power_curve)
	return t

# Inverse of the pure-mouse power model: the cursor speed that yields
# target_power_t (0..1). Bots have no real pointer, so they commit a target
# power fraction and the controller feeds this back as the sweep_speed — driving
# the same wrister_power_t a human does, deterministically hitting any % of the
# band. power_t = (speed/full)^curve, so speed = full · target^(1/curve).
static func wrister_speed_for_power_t(target_power_t: float, cfg: WristerConfig) -> float:
	var t: float = clampf(target_power_t, 0.0, 1.0)
	if cfg.full_sweep_speed <= 0.0:
		return 0.0
	if cfg.power_curve > 0.0:
		t = pow(t, 1.0 / cfg.power_curve)
	return cfg.full_sweep_speed * t

# Forehand vs backhand from the SWING CHIRALITY — the net rotational sense of
# the blade's sweep around the player over the stroke (ChargeTracking.rotation,
# radians; + / - is counter-/clockwise about the vertical axis). A forehand and
# a backhand curl the blade in opposite rotational directions — that IS the
# distinction (mirror-image wrist rolls) — so the sign of the accumulated swing
# classifies it. Unlike a travel-direction read this handles a cross-body
# backhand correctly: an off-side start swept to the stick side nets to the
# backhand rotation even though it finishes stick-ward.
#
# deadband (radians) keeps a near-radial push — a straight-out shot with almost
# no angular sweep — defaulting to FOREHAND (the strong side you square up on);
# a backhand is the deliberate rotational commit.
#
# SIGN: a positive swing is a forehand for a right-handed shooter, mirrored for
# lefties (is_left_handed flips it). Absolute chirality sign is empirical, not
# reliably derivable through the handedness/coordinate conventions — if playtest
# shows it inverted, flip the `handed` sign here and nowhere else.
static func is_backhand_from_swing(
		swing_rotation: float, is_left_handed: bool,
		deadband: float = 0.0) -> bool:
	var handed: float = -1.0 if is_left_handed else 1.0
	return swing_rotation * handed < -deadband

# Wrister release. HARD BINARY — a quick shot and a charged wrister are two
# distinct shots, with NO blend between them. Which one fires is decided by the
# INPUT at the call site (not any threshold in here) and passed in as is_quick_shot:
#   - QUICK SHOT (the dedicated quick_shot button, via _fire_quick_shot): aims
#     player→blade (the blade tracks the cursor via ROM-clamped IK, so aim is
#     accurate and can never point behind the player) at the fixed quick/pass power.
#   - WRISTER (the LMB shoot button, via _release_wrister): aims along the DRAG
#     (the swept cursor direction) at charged power — the pure mouse-speed model
#     above (wrister_power_t), fed by sweep_speed. The drag direction IS the aim —
#     this is the defining mechanic of the shot, so it is never diluted.
# The two live on separate buttons precisely so there's no tap-vs-hold guess: the
# old hold-time classifier made an ordinary tap that lingered a few ticks fire a
# wrister when the player expected a snap. There is intentionally no blend band:
# dragging to aim is the core of the game, and mixing the body-relative tap
# direction into charged shots both muddies the feel and — because tap_dir depends
# on the predicted body position — is a client/host divergence source. Netcode
# upshot: a charged wrister's aim (the drag vector) is body-independent and
# identical on client and host.
# Backhand is the caller's call: the controller passes is_backhand from
# is_backhand_from_swing (above) — the rotational sense of the blade's sweep
# around the player over the stroke.
static func release_wrister(
		player_pos: Vector3,
		mouse_world_pos: Vector3,
		blade_world_pos: Vector3,
		is_backhand: bool,
		elevation_level: int,
		cfg: WristerConfig,
		charge_direction: Vector3 = Vector3.ZERO,
		is_quick_shot: bool = false,
		sweep_speed: float = 0.0,
		out: ShotResult = null) -> ShotResult:
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
				cfg.quick_shot_power, out)

	# WRISTER — aim along the drag, power from the pure mouse-speed model
	# (wrister_power_t). Falls back to player→mouse only when no drag direction
	# was recorded.
	var wrister_dir: Vector3
	if charge_direction.length_squared() > 0.0001:
		wrister_dir = Vector3(charge_direction.x, 0.0, charge_direction.z).normalized()
	else:
		wrister_dir = (target - player_xz).normalized()
	var power: float = lerpf(cfg.min_wrister_power, cfg.max_wrister_power,
			wrister_power_t(sweep_speed, cfg))
	if is_backhand:
		power *= cfg.backhand_power_coefficient

	var y: float = loft_y(power, _loft_vy(elevation_level, cfg.loft_vy_low, cfg.loft_vy_high))
	return ShotResult.make(
			Vector3(wrister_dir.x, y, wrister_dir.z).normalized(),
			power, out)

# Slapper release — power scales linearly with charge time.
#
# shot_direction: when non-zero, used as the shot direction directly (locked
# at press time); falls back to blade→mouse when zero (backwards compat).
#
# incoming_speed: the loose feed's speed at contact for a ONE-TIMER (0 for a
# standing slapshot). A one-timer redirects the feed's own momentum, so a
# fraction of it (one_timer_feed_transfer) is added to the wind-up power and the
# whole thing is capped at one_timer_max_power — a ceiling ABOVE the standing
# max, so the hardest shot in the game is a hard feed one-timed by a wound-up
# shooter. Applied HERE, before loft_y, so the fixed-apex loft geometry is
# computed against the final power (a raised power must not sail the puck over
# the net). Raw incoming magnitude (not net-ward projection) — a hard cross-seam
# feed should reward the classic one-timer just as much as a straight feed.
static func release_slapper(
		blade_world_pos: Vector3,
		mouse_world_pos: Vector3,
		elevation_level: int,
		charge_time: float,
		cfg: SlapperConfig,
		shot_direction: Vector3 = Vector3.ZERO,
		incoming_speed: float = 0.0) -> ShotResult:
	var shot_dir: Vector3
	if shot_direction.length_squared() > 0.0001:
		shot_dir = Vector3(shot_direction.x, 0.0, shot_direction.z).normalized()
	else:
		var blade_xz := Vector3(blade_world_pos.x, 0.0, blade_world_pos.z)
		var target := Vector3(mouse_world_pos.x, 0.0, mouse_world_pos.z)
		shot_dir = (target - blade_xz).normalized()
	var charge_t: float = clampf(charge_time / cfg.max_slapper_charge_time, 0.0, 1.0)
	var power: float = lerpf(cfg.min_slapper_power, cfg.max_slapper_power, charge_t)
	if incoming_speed > 0.0 and cfg.one_timer_feed_transfer > 0.0:
		power = minf(power + cfg.one_timer_feed_transfer * incoming_speed,
				cfg.one_timer_max_power)

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

# Follow-through aim direction (world XZ). The finish choreography sweeps the
# torso + blade along the SHOT line so the release reads as a genuine follow-
# through — but by the time the timer ends the cursor has usually kept moving
# (you dragged THROUGH the shot), so pointing the finish at the frozen shot line
# leaves the pose to re-rotate to the live cursor once normal tracking resumes:
# the "follow-through, then a reset back" read. This eases the aim from the shot
# line toward the current cursor over the TAIL of the timer (the last
# `return_frac`), so the finish lands on wherever the mouse actually is and the
# handoff to blade-tracking is seamless. The shot-line follow-through is
# preserved through the meat of the timer (t below the tail → returns shot_dir
# unchanged). Returns ZERO when shot_dir is degenerate (whiff) so callers keep
# their existing whiff fallback; horizontal unit vector otherwise.
static func follow_through_aim(
		shot_dir: Vector3, cursor_dir: Vector3, t: float, return_frac: float) -> Vector3:
	var sd := Vector3(shot_dir.x, 0.0, shot_dir.z)
	if sd.length_squared() < 0.0001:
		return Vector3.ZERO
	sd = sd.normalized()
	var cd := Vector3(cursor_dir.x, 0.0, cursor_dir.z)
	if return_frac <= 0.0 or cd.length_squared() < 0.0001:
		return sd
	cd = cd.normalized()
	var tail_start: float = 1.0 - clampf(return_frac, 0.0, 1.0)
	if t <= tail_start:
		return sd
	var rt: float = clampf((t - tail_start) / maxf(1.0 - tail_start, 0.0001), 0.0, 1.0)
	rt = rt * rt * (3.0 - 2.0 * rt)  # smoothstep
	var ang: float = lerp_angle(atan2(sd.x, -sd.z), atan2(cd.x, -cd.z), rt)
	return Vector3(sin(ang), 0.0, -cos(ang))

# Should a blade-in-wall squeeze auto-release the puck? Pure threshold check.
static func should_release_on_wall_pin(squeeze: float, threshold: float) -> bool:
	return squeeze > threshold
