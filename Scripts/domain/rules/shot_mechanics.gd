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

# ── Loft levels: where the puck sits on the blade ─────────────────────────────
# Elevation is a player-selected LOFT LEVEL (scroll wheel, 0..3), fictionalized
# as the CONTACT POINT on the blade (design: docs/elevation-rework-plan.md).
# Each level is a SET LAUNCH ANGLE from the blade curve's per-gear ladder
# (PlayerAttributes._CURVE_LOFT_*_DEG) — no target-height solve, no position
# input, no power coupling. Arrival height is emergent from angle × charge ×
# range, and MISSING HIGH is the price of greed: the player is the calibrated
# shooter, or isn't yet.
#   0 = FLAT — heel. The puck stays on the ice.
#   1 = LOW  — mid-blade partial roll (7°/8°/8.5° by gear): the saucer at pass
#              pace, the point snipe at full wrister charge.
#   2 = MID  — toe-side (14°/15°/16°): the slot snipe (~4–5 m at full charge).
#   3 = HIGH — the toe (22°/26°/30°): the in-tight roof; the flattest ladder
#              (M88) cannot roof the doorstep but also can never sail — its
#              worst outcome at any charge is a crossbar ping — while the M28
#              roofs from the crease and pays for it everywhere else.
# The levels double as DEFLECT MODES (blade lift height + redirect sign follow
# the level — see PuckCollisionRules.deflect_loft_speed).
# QUICK PASSES keep the fixed vertical-speed table (loft_vy_low/high — LOW at
# pass power IS the saucer pass, MID/HIGH the flip), position- and gear-free.
const ELEVATION_FLAT: int = 0
const ELEVATION_LOW: int = 1
const ELEVATION_MID: int = 2
const ELEVATION_HIGH: int = 3

# Universal cap on the pre-normalization Y/XZ ratio of a lofted direction:
# 1.0 = 45°. Pure anti-forgery guard — the steepest authored ladder rung (M28
# HIGH, 30°) sits well under it. Keeps every legit direction under
# ShotReleaseRules.MAX_DIRECTION_Y (normalized y at 45° is ~0.707 vs the 0.75
# clamp) so the host's forged-direction clamp never touches an honest shot.
const MAX_LOFT_RATIO: float = 1.0

class WristerConfig:
	var min_wrister_power: float = 0.0
	var max_wrister_power: float = 0.0
	var backhand_power_coefficient: float = 0.0
	var quick_pass_power: float = 0.0
	# Fixed vertical launch speeds (m/s) for the QUICK-PASS loft table only
	# (levels 1/2 — the saucer and the flip; see the loft-level doc above).
	var loft_vy_low: float = 0.0
	var loft_vy_high: float = 0.0
	# The blade curve's angle ladder as tan(angle) per elevated level (see
	# shot_loft_y). Defaults = the M92 (league-neutral) ladder.
	var loft_tan_low: float = GameRules.DEFAULT_LOFT_TAN_LOW
	var loft_tan_mid: float = GameRules.DEFAULT_LOFT_TAN_MID
	var loft_tan_high: float = GameRules.DEFAULT_LOFT_TAN_HIGH
	# ── Power model (see wrister_power_t) ──
	# Cursor speed (m/s of screen-space pointer travel, already scaled by the
	# player's Shot Power Sensitivity) that reads as a full-power release.
	# <= 0.0 disables the wrister (returns zero power).
	var full_sweep_speed: float = 0.0
	# Feel-curve exponent on the 0..1 power parameter. < 1.0 is top-end
	# generous (an ordinary confident flick lands high in the band); 1.0 is
	# linear. <= 0.0 means linear.
	var power_curve: float = 0.0
	# ── Travel-gated ceiling (see wrister_travel_cap_t) ──
	# Blade path length (meters, player-relative XZ, accumulated over the
	# stroke by ChargeTracking) that unlocks the FULL power band. <= 0.0
	# disables the gate (cap is always 1.0).
	var full_stroke_travel: float = 0.0
	# Fraction of the power band (0..1 of t) reachable with ZERO stroke
	# travel — the instant flick-pass / snap tier. The gate never caps below
	# this, so quick releases stay a real pass.
	var travel_cap_floor: float = 0.0

class SlapperConfig:
	var min_slapper_power: float = 0.0
	var max_slapper_power: float = 0.0
	var max_slapper_charge_time: float = 0.0
	# Angle ladder as tan(angle) per elevated level (see shot_loft_y).
	var loft_tan_low: float = GameRules.DEFAULT_LOFT_TAN_LOW
	var loft_tan_mid: float = GameRules.DEFAULT_LOFT_TAN_MID
	var loft_tan_high: float = GameRules.DEFAULT_LOFT_TAN_HIGH

# ── Wrister power model (pure mouse speed, travel-gated ceiling) ─────────────
# Normalized 0..1 charged-wrister power from a single signal: CURSOR SPEED —
# the raw screen-space pointer speed at release, scaled by the player's Shot
# Power Sensitivity (so the feel is DPI-independent). Distance dragged does not
# enter: the drag vector is the aim, its *speed* is the power. A slow deliberate
# sweep is a soft touch pass; a hard flick is a full shot. power_curve then
# shapes the parameter — the feel curve (< 1.0 is top-end generous, so an
# ordinary confident flick lands high in the band). All wrister shapes fall out
# of this one axis: slow → soft pass-weight wrister, fast → full wrister.
#
# stroke_travel then CAPS the result (wrister_travel_cap_t below): the top of
# the band must be earned with real blade travel. The cap can only ever LOWER
# the speed-derived t and never below the flick-pass floor, so the soft/mid
# band — everything the pure-speed model was adopted for — is computed
# identically to the ungated model. Default INF = no gate (quick shots, bots,
# legacy callers).
static func wrister_power_t(
		sweep_speed: float, cfg: WristerConfig, stroke_travel: float = INF) -> float:
	if cfg.full_sweep_speed <= 0.0:
		return 0.0
	var t: float = clampf(sweep_speed / cfg.full_sweep_speed, 0.0, 1.0)
	if cfg.power_curve > 0.0:
		t = pow(t, cfg.power_curve)
	return minf(t, wrister_travel_cap_t(stroke_travel, cfg))


# Ceiling (0..1 of the power parameter) a stroke has EARNED with blade travel —
# the anti-twitch gate. The power signal is raw cursor speed, which a wiggle, a
# short jerk, or a cranked Shot Power Sensitivity can max without the blade
# sweeping any real arc; this cap demands the loading phase of an actual
# wrister stroke for the top of the band. Grounded in world-space blade path
# (meters over the stroke, ChargeTracking travel): it can't be bought with DPI
# or the sensitivity setting, because pixels don't move the blade past ROM.
#   - travel >= full_stroke_travel → 1.0 (an honest sweep pays this by nature)
#   - travel 0 → travel_cap_floor (the instant flick-pass / snap tier)
#   - full_stroke_travel <= 0 → gate disabled, always 1.0
static func wrister_travel_cap_t(stroke_travel: float, cfg: WristerConfig) -> float:
	if cfg.full_stroke_travel <= 0.0:
		return 1.0
	return clampf(stroke_travel / cfg.full_stroke_travel, cfg.travel_cap_floor, 1.0)

# Inverse of the pure-mouse power model: the cursor speed that yields
# target_power_t (0..1). Bots have no real pointer, so they commit a target
# power fraction and the controller feeds this back as the sweep_speed — driving
# the same wrister_power_t a human does, deterministically hitting any % of the
# band. power_t = (speed/full)^curve, so speed = full · target^(1/curve).
# Inverts only the SPEED axis: bots also bypass the travel gate (stroke_travel
# INF — their wind-up is cosmetic, the committed fraction is the whole gesture),
# so no travel term appears here.
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

# The wrister's aim DIRECTION (world XZ, un-normalized — release_wrister normalizes).
# BOTS commit their direction directly (bot_aim_dir non-ZERO — they have no cursor,
# and their cosmetic near-body wind-up cursor would make origin→cursor garbage);
# HUMANS aim POSITIONALLY from the frozen shot origin toward the cursor ("the puck
# fires from where it sits toward where you point"). See
# SkaterController._wrister_aim_dir.
static func wrister_aim_dir(bot_aim_dir: Vector3, mouse_world: Vector3,
		origin_world: Vector3) -> Vector3:
	if bot_aim_dir.length_squared() > 0.0001:
		return bot_aim_dir
	return Vector3(mouse_world.x - origin_world.x, 0.0, mouse_world.z - origin_world.z)

# The slapper's aim DIRECTION (world XZ, un-normalized — the caller normalizes),
# measured at the press tick and then LOCKED for the whole wind-up.
# BOTS commit their direction directly (bot_aim_dir non-ZERO), for the same reason
# the wrister does and one more: the human lock is measured from the BLADE's world
# point (a shoulder-anchored, attribute-scaled, facing-rotated offset ~1 m off the
# body), which a bot has no way to reproduce from the state snapshot. Placing a
# cursor "the right distance out" to cancel that offset parallel-shifts the locked
# line by roughly the blade offset — around a net width at one-timer range, and
# worse than that in tight where the shot vector is shorter than the offset itself.
# HUMANS aim blade→cursor: the puck fires from the blade toward where you point.
# See SkaterController._enter_slapper_charge.
static func slapper_aim_dir(bot_aim_dir: Vector3, mouse_world: Vector3,
		blade_world: Vector3) -> Vector3:
	if bot_aim_dir.length_squared() > 0.0001:
		return bot_aim_dir
	return Vector3(mouse_world.x - blade_world.x, 0.0, mouse_world.z - blade_world.z)

# Wrister forehand/backhand. BOTS commit the hand (paired with a committed
# bot_aim_dir); HUMANS read the CURSOR-sweep chirality (is_backhand_from_swing;
# the blade is frozen so the cursor is the only sweep). See
# SkaterController._wrister_is_backhand.
static func wrister_is_backhand(bot_aim_dir: Vector3, bot_backhand: bool,
		swing_rotation: float, is_left_handed: bool, deadband: float) -> bool:
	if bot_aim_dir.length_squared() > 0.0001:
		return bot_backhand
	return is_backhand_from_swing(swing_rotation, is_left_handed, deadband)

# Wrister release. HARD BINARY — a quick pass and a charged wrister are two
# distinct releases, with NO blend between them. Which one fires is decided by the
# INPUT at the call site (not any threshold in here) and passed in as is_quick_pass:
#   - QUICK PASS (the dedicated quick_pass button, via _fire_quick_pass): aims
#     blade→cursor — from the puck's position (the blade) toward the cursor, so
#     the pass goes where you point — at the fixed quick/pass power.
#   - WRISTER (the LMB shoot button, via _release_wrister): aims along the
#     charge_direction the caller hands in, at charged power — the pure mouse-speed
#     model above (wrister_power_t), fed by sweep_speed. The controller supplies
#     that vector POSITIONALLY: from the frozen shot origin (the puck, held still
#     during the charge) toward the cursor — the same aim as the quick pass, so
#     "the puck fires from where it sits toward where you point." (Bots commit the
#     direction directly.) Falls back to player→cursor when zero.
# The two live on separate buttons precisely so there's no tap-vs-hold guess: the
# old hold-time classifier made an ordinary tap that lingered a few ticks fire a
# wrister when the player expected a snap.
# Backhand is the caller's call: the controller passes is_backhand — for humans
# the rotational sense of the CURSOR's bearing sweep over the stroke
# (is_backhand_from_swing above; the blade is frozen so the cursor is the sweep),
# for bots the committed hand.
static func release_wrister(
		player_pos: Vector3,
		mouse_world_pos: Vector3,
		blade_world_pos: Vector3,
		is_backhand: bool,
		elevation_level: int,
		cfg: WristerConfig,
		charge_direction: Vector3 = Vector3.ZERO,
		is_quick_pass: bool = false,
		sweep_speed: float = 0.0,
		stroke_travel: float = INF,
		out: ShotResult = null) -> ShotResult:
	var target := Vector3(mouse_world_pos.x, 0.0, mouse_world_pos.z)
	var player_xz := Vector3(player_pos.x, 0.0, player_pos.z)

	if is_quick_pass:
		# QUICK PASS — aim from the blade (the puck's position) toward the cursor,
		# so the pass goes where you point. The old player→blade aim inherited the
		# blade's lateral carry-side offset (the puck sits off to the forehand
		# side), which pulled the pass off the cursor line — this reads blade→cursor
		# directly. Falls back to player→cursor only when the cursor sits on the
		# blade (degenerate, no direction). Loft rides the same level table as
		# charged shots: level 1 at pass power is the saucer pass, level 2 the flip.
		var blade_xz := Vector3(blade_world_pos.x, 0.0, blade_world_pos.z)
		var pass_dir: Vector3 = (target - blade_xz).normalized()
		if pass_dir.length_squared() < 0.0001:
			pass_dir = (target - player_xz).normalized()
		# Quick passes ride the fixed-speed table under the UNIVERSAL cap only —
		# the toe cap is a shot lever (you flip a pass off the mid-blade, not
		# the toe), and at pass power no honest curve ever bound here anyway.
		var tap_y: float = loft_y(cfg.quick_pass_power,
				_loft_vy(elevation_level, cfg.loft_vy_low, cfg.loft_vy_high))
		return ShotResult.make(
				Vector3(pass_dir.x, tap_y, pass_dir.z).normalized(),
				cfg.quick_pass_power, out)

	# WRISTER — aim along the drag, power from the pure mouse-speed model with
	# the travel-gated ceiling (wrister_power_t). Falls back to player→mouse
	# only when no drag direction was recorded.
	var wrister_dir: Vector3
	if charge_direction.length_squared() > 0.0001:
		wrister_dir = Vector3(charge_direction.x, 0.0, charge_direction.z).normalized()
	else:
		wrister_dir = (target - player_xz).normalized()
	var power: float = lerpf(cfg.min_wrister_power, cfg.max_wrister_power,
			wrister_power_t(sweep_speed, cfg, stroke_travel))
	if is_backhand:
		power *= cfg.backhand_power_coefficient

	var y: float = shot_loft_y(elevation_level,
			cfg.loft_tan_low, cfg.loft_tan_mid, cfg.loft_tan_high)
	return ShotResult.make(
			Vector3(wrister_dir.x, y, wrister_dir.z).normalized(),
			power, out)

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
		shot_direction: Vector3 = Vector3.ZERO,
		out: ShotResult = null) -> ShotResult:
	var shot_dir: Vector3
	if shot_direction.length_squared() > 0.0001:
		shot_dir = Vector3(shot_direction.x, 0.0, shot_direction.z).normalized()
	else:
		var blade_xz := Vector3(blade_world_pos.x, 0.0, blade_world_pos.z)
		var target := Vector3(mouse_world_pos.x, 0.0, mouse_world_pos.z)
		shot_dir = (target - blade_xz).normalized()
	var charge_t: float = clampf(charge_time / cfg.max_slapper_charge_time, 0.0, 1.0)
	var power: float = lerpf(cfg.min_slapper_power, cfg.max_slapper_power, charge_t)

	var y: float = shot_loft_y(elevation_level,
			cfg.loft_tan_low, cfg.loft_tan_mid, cfg.loft_tan_high)
	return ShotResult.make(
			Vector3(shot_dir.x, y, shot_dir.z).normalized(),
			power, out)

# Vertical launch speed (m/s) for a QUICK-PASS loft level (charged shots use
# shot_loft_y). Levels above HIGH clamp to high — the input decode already
# bounds the wire value, this is belt-and-braces.
static func _loft_vy(elevation_level: int, vy_low: float, vy_high: float) -> float:
	if elevation_level <= ELEVATION_FLAT:
		return 0.0
	if elevation_level == ELEVATION_LOW:
		return vy_low
	return vy_high

# Y direction component (pre-normalization Y/XZ ratio) that gives a shot fired
# at `power` a vertical launch speed of `loft_vy`, exactly:
#   v_y = power · y / sqrt(1 + y²)  →  y = loft_vy / sqrt(power² − loft_vy²)
# The ratio IS tan(launch angle), capped at `loft_tan_max` as a degenerate-
# input guard (y would run toward vertical as power approaches loft_vy).
# Serves the fixed-speed consumers: the quick-pass loft table and the puck's
# deflect-tip solve (Puck.deflect_up/down_loft_speed).
static func loft_y(power: float, loft_vy: float,
		loft_tan_max: float = MAX_LOFT_RATIO) -> float:
	if loft_vy <= 0.0:
		return 0.0
	var tan_cap: float = minf(MAX_LOFT_RATIO, loft_tan_max)
	var max_vy_at_cap: float = power * tan_cap / sqrt(1.0 + tan_cap * tan_cap)
	if loft_vy >= max_vy_at_cap:
		return tan_cap
	return loft_vy / sqrt(power * power - loft_vy * loft_vy)

# Y direction ratio (tan of the launch angle) for a CHARGED shot — the ladder
# lookup of the contact-point model (see the loft-level doc at the top of this
# file). Set angles: power and position never enter; where the arc arrives is
# the player's read, and over the bar is a real outcome. Levels above HIGH
# clamp to HIGH (belt-and-braces with the 2-bit input decode), every rung is
# bounded by MAX_LOFT_RATIO so the host's forged-direction clamp
# (ShotReleaseRules.MAX_DIRECTION_Y) never touches an honest shot.
static func shot_loft_y(elevation_level: int,
		loft_tan_low: float, loft_tan_mid: float, loft_tan_high: float) -> float:
	if elevation_level <= ELEVATION_FLAT:
		return 0.0
	if elevation_level == ELEVATION_LOW:
		return minf(MAX_LOFT_RATIO, loft_tan_low)
	if elevation_level == ELEVATION_MID:
		return minf(MAX_LOFT_RATIO, loft_tan_mid)
	return minf(MAX_LOFT_RATIO, loft_tan_high)

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

# Follow-through blade-extension direction in the upper-body LOCAL frame, for a
# shot along `axis_world` (world XZ). The frozen-wrister whip builds the stick
# outward FROM THE SHOULDER along this local direction, so the blade drives along
# the shot vector regardless of the body's yaw (the coil): for any yaw B,
# `B * whip_local_dir(A, B)` is parallel to A in XZ. (Body lean — pitch/roll —
# introduces a small error the vertical solve absorbs; yaw is exact.) This is what
# keeps the finish on the shot line instead of splaying radially outward from the
# body. Returns ZERO for a degenerate axis (caller falls back).
static func whip_local_dir(axis_world: Vector3, upper_body_basis: Basis) -> Vector3:
	var a := Vector3(axis_world.x, 0.0, axis_world.z)
	if a.length_squared() < 0.0001:
		return Vector3.ZERO
	var local: Vector3 = upper_body_basis.inverse() * a.normalized()
	var dir := Vector3(local.x, 0.0, local.z)
	if dir.length_squared() < 0.0001:
		return Vector3.ZERO
	return dir.normalized()


# Should a blade-in-wall squeeze auto-release the puck? Pure threshold check.
static func should_release_on_wall_pin(squeeze: float, threshold: float) -> bool:
	return squeeze > threshold

# Below this along-wall carrier speed (m/s) a wall-pin release has no natural
# direction (pinned dead against the boards), so it falls back to the inward
# normal rather than picking an arbitrary side.
const WALL_PIN_MIN_ALONG_SPEED: float = 0.5

# Direction to squirt a carried puck when the blade is squeezed into the boards
# past the release threshold. A real puck lost on the wall dribbles ALONG the
# boards in the direction the carrier was moving — not straight out into the slot
# (an unnatural giveaway to the middle). `wall_normal` points INWARD (away from
# the boards, the get_blade_wall_normal convention); the wall tangent is its 90°
# rotation in XZ. Projects the carrier's horizontal velocity onto that tangent and
# releases along it, signed by which way the carrier was travelling. `inward_bias`
# blends that fraction of the inward normal into the along-wall direction so the
# puck peels a touch off the boards rather than hugging them (0 = pure slide).
# Falls back to the inward normal when the carrier is pinned with no along-wall
# momentum (so the puck still comes free), and to the carrier's heading — else
# ZERO — when there is no usable wall normal (callers keep their own degenerate
# fallback on ZERO).
static func wall_pin_release_direction(
		wall_normal: Vector3, carrier_velocity: Vector3, inward_bias: float = 0.0) -> Vector3:
	var vel := Vector3(carrier_velocity.x, 0.0, carrier_velocity.z)
	var n := Vector3(wall_normal.x, 0.0, wall_normal.z)
	if n.length_squared() < 0.0001:
		return vel.normalized() if vel.length_squared() > 0.0001 else Vector3.ZERO
	n = n.normalized()
	var tangent := Vector3(-n.z, 0.0, n.x)  # along the boards
	var along: float = vel.dot(tangent)
	if absf(along) < WALL_PIN_MIN_ALONG_SPEED:
		return n  # pinned dead — no along-wall direction; release inward so it frees
	var dir: Vector3 = tangent * signf(along)
	if inward_bias > 0.0:
		dir += n * inward_bias  # peel slightly off the boards so it doesn't hug them
	return dir.normalized()
