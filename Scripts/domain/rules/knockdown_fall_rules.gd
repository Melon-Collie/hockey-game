class_name KnockdownFallRules

# Pure math for the knockdown fall pose: a checked player tips about the skates
# in the hit direction, bounces off the ice, and lies flat until the get-up.
#
# Grounded model, not an authored curve: the body is a rigid rod pivoting at the
# ice under a constant angular acceleration (gravity torque), seeded with the
# tip rate the hit's shove actually imparted (shove speed / COM height — the
# angular momentum the impulse put about the skate pivot). Ice contact reflects
# the tip rate through a restitution, so the bounce count and rhythm fall out of
# the impact speed instead of being keyframed. The lying pose is solved, not
# authored: the waist fold resolves to the ground-plane complement (fold_at)
# and the limbs scatter from first impact by the hit's own momentum and side
# (sprawl_into), so no two falls settle identically. Everything is a
# closed-form function of elapsed down-time, so every machine — and reconcile
# replay — renders the identical fall from the replicated knockdown timer.

class Config:
	extends RefCounted
	var buckle_seconds: float = 0.1   # knees give before the tip starts (the gait's drop covers it)
	var fall_accel: float = 6.0       # rad/s² — tipping-rod gravity torque, (3g/2L)·sin θ averaged over the arc for L ≈ 1.7 m
	var settle_angle: float = 1.466   # rad — lying tilt; short of π/2 because the body rests on its own bulk
	var restitution: float = 0.3      # fraction of tip rate kept through an ice bounce
	var rest_omega: float = 0.7       # rad/s — an impact slower than this doesn't visibly rebound
	var com_height: float = 0.95      # m — the shove-speed → tip-rate lever arm (belt height)
	var max_entry_omega: float = 4.2  # rad/s cap on the seeded tip rate (a freight-train hit still reads as a fall, not a spin)
	var sprawl_in_seconds: float = 0.25  # the limbs scatter over this window after first ice contact
	var sprawl_splay: float = 0.31       # rad — free-leg outward splay of a maximal sprawl


# Tilt (radians, about the skate pivot) after `elapsed` seconds of down-time,
# seeded by the horizontal shove speed (m/s) the hit imparted. Piecewise
# ballistic: within a flight segment θ(t) = θ₀ + ω·t + ½a·t², and each ice
# contact solves the impact time in closed form and reflects ω through the
# restitution — so the whole history is re-derivable from `elapsed` alone (no
# integrator state), which is what makes it replay- and reconcile-safe.
static func tilt_at(elapsed: float, entry_speed: float, cfg: Config) -> float:
	var t: float = elapsed - cfg.buckle_seconds
	if t <= 0.0:
		return 0.0
	var accel: float = maxf(cfg.fall_accel, 0.001)
	var omega: float = clampf(
			entry_speed / maxf(cfg.com_height, 0.001), 0.0, cfg.max_entry_omega)
	var theta: float = 0.0
	# Bounded segment walk: each pass consumes one flight-to-impact segment. The
	# restitution shrinks flight times geometrically, so real configs settle in
	# 2–3 passes; the cap is a numerical backstop, not a tuning surface.
	for _i in range(6):
		# Impact time from (θ, ω): positive root of ½a·dt² + ω·dt = settle − θ.
		var gap: float = cfg.settle_angle - theta
		var impact_omega: float = sqrt(omega * omega + 2.0 * accel * gap)
		var t_hit: float = (impact_omega - omega) / accel
		if t < t_hit:
			return theta + (omega + 0.5 * accel * t) * t
		if impact_omega * cfg.restitution < cfg.rest_omega:
			return cfg.settle_angle
		t -= t_hit
		omega = -impact_omega * cfg.restitution
		theta = cfg.settle_angle
	return cfg.settle_angle


# Elapsed down-time of the first ice contact — the buckle delay plus the
# closed-form flight time to the settle plane, from the same seeded tip rate as
# tilt_at. This is when the loose limbs start to scatter (sprawl_into): during
# the flight the body falls as one rod; the impact is what flings the limbs.
static func first_impact_time(entry_speed: float, cfg: Config) -> float:
	var accel: float = maxf(cfg.fall_accel, 0.001)
	var omega: float = clampf(
			entry_speed / maxf(cfg.com_height, 0.001), 0.0, cfg.max_entry_omega)
	var impact_omega: float = sqrt(omega * omega + 2.0 * accel * cfg.settle_angle)
	return cfg.buckle_seconds + (impact_omega - omega) / accel


# Waist fold (radians, layered onto the whole-body tilt in the fall direction)
# for a given tilt. In the air the torso curls reflexively (`curl` — a feel
# value, the flinch of riding out a hit); on the ice the ground is a
# constraint, not a suggestion: the fold resolves to the complement that lays
# the torso IN the ground plane (π/2 − tilt), because holding the airborne curl
# through the landing folds the chest through the ice on a full fall and
# dropping the fold entirely props the body up as a plank. Blending on
# tilt/settle rather than time means every restitution bounce re-flexes the
# body a little on its way back down — the impact flinch falls out for free.
static func fold_at(tilt: float, curl: float, cfg: Config) -> float:
	var ground_t: float = clampf(tilt / maxf(cfg.settle_angle, 0.001), 0.0, 1.0)
	ground_t = ground_t * ground_t * (3.0 - 2.0 * ground_t)
	var flat: float = maxf(PI / 2.0 - tilt, 0.0)
	return lerpf(curl, flat, ground_t)


# The symmetric leg collapse (hip flex, knee fold) whose height deficit equals
# `drop` — thigh forward and shin back by the same angle α, so
# (thigh + shin)·(1 − cos α) = drop. This is the buckle pose that keeps the
# boots at the ice while the gait's crumple sinks the body by the drop; without
# it the straight-legged crumple buries the skates by exactly that length.
# Returned as (hip pitch, knee fold) in the set_leg_swing conventions:
# positive pitch flexes the thigh forward, knee = −(hip + shin-from-vertical).
static func buckle_angles(drop: float, thigh_len: float, shin_len: float) -> Vector2:
	var reach: float = maxf(thigh_len + shin_len, 0.001)
	var a: float = acos(clampf(1.0 - drop / reach, -1.0, 1.0))
	return Vector2(a, -2.0 * a)


# Scratch for sprawl_into — caller-owned and refilled per frame (the hot-path
# "build once, fill scratch" idiom; a downed skater renders every frame).
class SprawlPose:
	extends RefCounted
	var l_pitch: float = 0.0
	var l_roll: float = 0.0
	var l_knee: float = 0.0
	var r_pitch: float = 0.0
	var r_roll: float = 0.0
	var r_knee: float = 0.0


# Sprawl shape fractions (feel, hand-picked — the scatter *timing* and *side*
# are the modelled parts):
const _SCATTER_FLOOR: float = 0.35  # even the softest fall scatters this fraction
const _FREE_EXTEND: float = 0.75    # how far out of the buckle the free leg straightens
const _PIN_FOLD: float = 0.3        # extra knee fold the pinned leg takes
const _PIN_SPLAY: float = 0.35      # pinned-leg outward roll, as a fraction of the free splay


# Downed-leg pose, closed-form in `elapsed` like tilt_at (replay/reconcile-safe
# with zero stored state). Two stages:
#   1. Buckle — both legs collapse into the crouch that matches the gait's
#      crumple drop (buckle_angles), from the instant the drop lands.
#   2. Sprawl — from first ice contact the loose limbs scatter: the leg the
#      body fell onto stays pinned and folds deeper; the top leg extends and
#      splays wide. Scatter scale rides the entry tip rate (a harder hit flings
#      the limbs wider) and the side follows the fall's lateral lean, so the
#      lying pose varies hit-to-hit instead of being one authored keyframe.
# `fall_dir` is the body-local fall direction (the recoil dir, unit XZ);
# falling toward +X lands on the right side, which frees the LEFT leg on top.
static func sprawl_into(out: SprawlPose, elapsed: float, entry_speed: float,
		fall_dir: Vector2, drop: float, thigh_len: float, shin_len: float,
		cfg: Config) -> void:
	var buckle: Vector2 = buckle_angles(drop, thigh_len, shin_len)
	out.l_pitch = buckle.x
	out.l_roll = 0.0
	out.l_knee = buckle.y
	out.r_pitch = buckle.x
	out.r_roll = 0.0
	out.r_knee = buckle.y
	var w: float = clampf(
			(elapsed - first_impact_time(entry_speed, cfg))
			/ maxf(cfg.sprawl_in_seconds, 0.001), 0.0, 1.0)
	if w <= 0.0:
		return
	w = w * w * (3.0 - 2.0 * w)
	var omega_t: float = clampf(
			entry_speed / maxf(cfg.com_height, 0.001)
			/ maxf(cfg.max_entry_omega, 0.001), 0.0, 1.0)
	var scatter: float = (_SCATTER_FLOOR + (1.0 - _SCATTER_FLOOR) * omega_t) * w
	var free_pitch: float = buckle.x * (1.0 - _FREE_EXTEND * scatter)
	var free_knee: float = buckle.y * (1.0 - _FREE_EXTEND * scatter)
	var pin_knee: float = buckle.y * (1.0 + _PIN_FOLD * scatter)
	var splay: float = cfg.sprawl_splay * scatter
	if fall_dir.x > 0.0:
		out.l_pitch = free_pitch
		out.l_roll = -splay
		out.l_knee = free_knee
		out.r_roll = splay * _PIN_SPLAY
		out.r_knee = pin_knee
	else:
		out.r_pitch = free_pitch
		out.r_roll = splay
		out.r_knee = free_knee
		out.l_roll = -splay * _PIN_SPLAY
		out.l_knee = pin_knee


# Get-up envelope: scales the fall tilt (and the arm brace) by the knockdown
# pose factor kd_t — 1 while fully down, easing to 0 over the getup tail (see
# the kd_t derivation in SkaterSkatingCoordinator). Smoothstepped so the body
# leaves the ice and arrives upright without velocity pops at either end.
static func getup_scale(kd_t: float) -> float:
	var k: float = clampf(kd_t, 0.0, 1.0)
	return k * k * (3.0 - 2.0 * k)


# Arm-brace blend (0..1): ramps in over brace_in_seconds of down-time — the
# reflexive pull-in reads as a reaction, not a snap — and releases through the
# same get-up envelope as the tilt so the hands rejoin the live IK continuously.
static func brace_at(elapsed: float, kd_t: float, brace_in_seconds: float) -> float:
	var ramp: float = clampf(elapsed / maxf(brace_in_seconds, 0.001), 0.0, 1.0)
	return ramp * getup_scale(kd_t)


# Deflects a fall direction (unit, world XZ) so the tipped body cannot lie
# through the boards: a body checked into the glass crumples DOWN it and ends up
# along the wall, because the wall is where the fall's momentum goes. `proximity`
# is a BoardPlayRules.board_proximity() result probed at the body's reach, so
# closeness 0→1 spans "boards one body-length away" → "against them"; the
# into-wall component is clamped to the fraction of the reach the remaining gap
# can absorb (gap/reach = 1 − closeness), which lands the head exactly at the
# glass in the worst case and leaves any fall that already fits untouched. The
# tangential remainder keeps the side the fall already leaned to, so the body
# sweeps the short way onto the wall line; a dead-perpendicular shove breaks the
# tie the same way on every machine (the rotated normal).
static func wall_safe_fall_dir(dir: Vector2, proximity: Vector2) -> Vector2:
	var closeness: float = proximity.length()
	if closeness < 0.0001 or dir.length_squared() < 0.0001:
		return dir
	var into: Vector2 = -proximity / closeness
	var into_amt: float = dir.dot(into)
	var max_into: float = 1.0 - closeness
	if into_amt <= max_into:
		return dir
	var tangent := Vector2(-into.y, into.x)
	if dir.dot(tangent) < 0.0:
		tangent = -tangent
	var tangent_amt: float = sqrt(maxf(1.0 - max_into * max_into, 0.0))
	return into * max_into + tangent * tangent_amt
