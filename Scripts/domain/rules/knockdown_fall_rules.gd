class_name KnockdownFallRules

# Pure math for the knockdown fall pose: a checked player tips about the skates
# in the hit direction, bounces off the ice, and lies flat until the get-up.
#
# Grounded model, not an authored curve: the body is a rigid rod pivoting at the
# ice under a constant angular acceleration (gravity torque), seeded with the
# tip rate the hit's shove actually imparted (shove speed / COM height — the
# angular momentum the impulse put about the skate pivot). Ice contact reflects
# the tip rate through a restitution, so the bounce count and rhythm fall out of
# the impact speed instead of being keyframed. Everything is a closed-form
# function of elapsed down-time, so every machine — and reconcile replay —
# renders the identical fall from the replicated knockdown timer.

class Config:
	extends RefCounted
	var buckle_seconds: float = 0.1   # knees give before the tip starts (the gait's drop covers it)
	var fall_accel: float = 6.0       # rad/s² — tipping-rod gravity torque, (3g/2L)·sin θ averaged over the arc for L ≈ 1.7 m
	var settle_angle: float = 1.466   # rad — lying tilt; short of π/2 because the body rests on its own bulk
	var restitution: float = 0.3      # fraction of tip rate kept through an ice bounce
	var rest_omega: float = 0.7       # rad/s — an impact slower than this doesn't visibly rebound
	var com_height: float = 0.95      # m — the shove-speed → tip-rate lever arm (belt height)
	var max_entry_omega: float = 4.2  # rad/s cap on the seeded tip rate (a freight-train hit still reads as a fall, not a spin)


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
