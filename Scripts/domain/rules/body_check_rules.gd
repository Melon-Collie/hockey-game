class_name BodyCheckRules

# Pure math for the "stagger" debuff a body check inflicts on its victim: a
# temporary thrust penalty plus an instantaneous stamina bite, both scaled by how
# hard the hit landed. Kept pure (static, no engine state) so it unit-tests
# without a live skater and — like StaminaRules / SkaterMovementRules — survives
# client-side prediction + reconcile: the victim's stagger_timer is replicated,
# snapped to the host baseline at replay start, and decays deterministically.
#
# "How hard" is the victim's transfer-impulse magnitude — the m/s velocity delta
# the hit imparts (= approach x weight_ratio x effective_transfer, so Size and
# Physical and the closing Speed all feed it) — normalized to 0..1 between
# min_impulse (below which a bump inflicts nothing) and ref_impulse (a
# full-strength check).
#
# One float, stagger_timer (seconds remaining), encodes BOTH the penalty depth
# and the recovery window: a harder hit sets a longer timer, and the per-tick
# thrust penalty is proportional to the timer that remains, so depth and duration
# scale together off a single replicated value and ease back as it decays.

class Config:
	var min_impulse: float = 3.0          # m/s victim velocity delta below which no debuff lands
	var ref_impulse: float = 9.0          # m/s delta treated as a full-strength check
	var max_stagger_seconds: float = 1.0  # recovery window of a full-strength check
	var max_stamina_drain: float = 0.35   # pool fraction (0..1) a full-strength check bites
	var max_thrust_penalty: float = 0.5   # peak thrust reduction (fraction) at full stagger


# 0..1 hit hardness from the victim impulse magnitude.
static func intensity(impulse_mag: float, cfg: Config) -> float:
	if cfg.ref_impulse <= cfg.min_impulse:
		return 0.0
	return clampf((impulse_mag - cfg.min_impulse) / (cfg.ref_impulse - cfg.min_impulse), 0.0, 1.0)


# Seconds of stagger a fresh hit adds (0 below min_impulse). Callers take the max
# with any in-flight timer so a weaker follow-up can't shorten an existing stagger.
static func stagger_seconds_from_impulse(impulse_mag: float, cfg: Config) -> float:
	return intensity(impulse_mag, cfg) * cfg.max_stagger_seconds


# Stamina (pool fraction, 0..1) a hit drains, charged only for the stagger it adds
# BEYOND what's already decaying on the victim. A clean hit from a settled skater
# (prev_stagger_timer 0) bites the full intensity-scaled amount; during sustained
# contact, where prev is near the incoming stagger, only the small top-up is
# charged — so grinding someone bleeds stamina at roughly the decay rate instead of
# emptying the pool tick-by-tick. Returns 0 when the hit isn't harder than the
# residual stagger.
static func incremental_stamina_drain(prev_stagger_timer: float, impulse_mag: float, cfg: Config) -> float:
	if cfg.max_stagger_seconds <= 0.0:
		return 0.0
	var add: float = stagger_seconds_from_impulse(impulse_mag, cfg)
	if add <= prev_stagger_timer:
		return 0.0
	return ((add - prev_stagger_timer) / cfg.max_stagger_seconds) * cfg.max_stamina_drain


# Thrust multiplier (<= 1.0) for the stagger remaining this tick. The penalty is
# proportional to the fraction of a full-strength window still on the clock, so a
# harder hit (longer timer) both starts deeper and takes longer to ease back to
# full thrust as stagger_timer decays to 0.
static func thrust_mult(stagger_timer: float, cfg: Config) -> float:
	if stagger_timer <= 0.0 or cfg.max_stagger_seconds <= 0.0:
		return 1.0
	var frac: float = clampf(stagger_timer / cfg.max_stagger_seconds, 0.0, 1.0)
	return 1.0 - frac * cfg.max_thrust_penalty
