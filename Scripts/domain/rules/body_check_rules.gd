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
	# Knockdown: the top of the same intensity continuum. A hit whose victim impulse
	# exceeds knockdown_impulse doesn't just stagger — it KNOCKS THE VICTIM DOWN
	# (movement locked, slides + bleeds speed, can't touch the puck) for a recovery
	# window that scales with how far past the threshold it landed, from
	# min_knockdown_seconds at the threshold to max_knockdown_seconds at
	# knockdown_ref_impulse. NOTE: these (and min/ref_impulse above) are placeholders
	# on the OLD magnitude scale — the Slice B inelastic model delivers ~half the old
	# impulse, so the whole ladder wants a downward re-tune once the feel is dialed.
	var knockdown_impulse: float = 11.0        # m/s victim impulse above which a hit knocks down (0 disables)
	var knockdown_ref_impulse: float = 16.0    # m/s impulse of a maximal (longest) knockdown
	var min_knockdown_seconds: float = 0.7     # down time of a just-barely knockdown
	var max_knockdown_seconds: float = 1.5     # down time of a maximal hit


# 0..1 hit hardness from the victim impulse magnitude.
static func intensity(impulse_mag: float, cfg: Config) -> float:
	if cfg.ref_impulse <= cfg.min_impulse:
		return 0.0
	return clampf((impulse_mag - cfg.min_impulse) / (cfg.ref_impulse - cfg.min_impulse), 0.0, 1.0)


# Seconds of stagger a fresh hit adds (0 below min_impulse). Callers take the max
# with any in-flight timer so a weaker follow-up can't shorten an existing stagger.
static func stagger_seconds_from_impulse(impulse_mag: float, cfg: Config) -> float:
	return intensity(impulse_mag, cfg) * cfg.max_stagger_seconds


# Seconds of KNOCKDOWN a fresh hit adds: 0 below knockdown_impulse, then ramps
# from min_knockdown_seconds at the threshold to max_knockdown_seconds at
# knockdown_ref_impulse (clamped). Like stagger, callers take the max with any
# in-flight timer so a weaker follow-up can't shorten an existing knockdown.
static func knockdown_seconds_from_impulse(impulse_mag: float, cfg: Config) -> float:
	if cfg.knockdown_impulse <= 0.0 or impulse_mag < cfg.knockdown_impulse:
		return 0.0
	var span: float = maxf(cfg.knockdown_ref_impulse - cfg.knockdown_impulse, 0.001)
	var t: float = clampf((impulse_mag - cfg.knockdown_impulse) / span, 0.0, 1.0)
	return lerpf(cfg.min_knockdown_seconds, cfg.max_knockdown_seconds, t)


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


# The transfer-impulse magnitude a body check actually lands on its victim: closing
# speed along the hit normal × mass ratio × the victim's brace-adjusted transfer.
# This single magnitude is the shared "how hard did it land" number every downstream
# effect keys off — the victim's knockback (Skater._resolve_player_collisions), the
# stagger it inflicts, the puck strip (reconstructed from impact_force by
# puck_strip_impulse below), and the attacker's own drive-through rebound
# (attacker_restitution). Folding the brace in HERE is what makes a committed hit on
# a braced/immovable victim peel off in a battle instead of the attacker gluing to
# them: the brace cuts the delivered impulse, which raises the rebound.
static func delivered_transfer_impulse(
		approach: float,
		weight_ratio: float,
		attacker_transfer: float,
		victim_brace_resistance: float,
		victim_braced: bool) -> float:
	var effective_transfer: float = attacker_transfer * (victim_brace_resistance if victim_braced else 1.0)
	return approach * weight_ratio * effective_transfer


# Attacker rebound (restitution) for a hit, scaled DOWN as the delivered impulse
# rises: a glancing shoulder bounces the attacker back at base_restitution, a
# squared-up monster hit falls toward floor_restitution (~0) so the attacker
# "drives through" the check and keeps their forward momentum to arrive on the
# loose puck instead of rebounding off the victim. Keyed off the same delivered
# impulse magnitude the puck strip and stagger use, so a harder hit reads harder
# everywhere. Pure floats (no Config) to keep the hot-path collision resolver in
# skater.gd decoupled from the stagger Config.
static func attacker_restitution(
		delivered_impulse: float,
		base_restitution: float,
		floor_restitution: float,
		min_impulse: float,
		ref_impulse: float) -> float:
	if ref_impulse <= min_impulse:
		return base_restitution
	var t: float = clampf((delivered_impulse - min_impulse) / (ref_impulse - min_impulse), 0.0, 1.0)
	return lerpf(base_restitution, floor_restitution, t)


# Thrust multiplier (<= 1.0) for the stagger remaining this tick. The penalty is
# proportional to the fraction of a full-strength window still on the clock, so a
# harder hit (longer timer) both starts deeper and takes longer to ease back to
# full thrust as stagger_timer decays to 0.
static func thrust_mult(stagger_timer: float, cfg: Config) -> float:
	if stagger_timer <= 0.0 or cfg.max_stagger_seconds <= 0.0:
		return 1.0
	var frac: float = clampf(stagger_timer / cfg.max_stagger_seconds, 0.0, 1.0)
	return 1.0 - frac * cfg.max_thrust_penalty


# The victim transfer-impulse the puck-strip / pickup-denial decision keys off —
# the SAME "how hard did it land on the victim" magnitude the stagger uses, so a
# hit's Physical (transfer), both skaters' Size (attacker + victim mass), and the
# closing Speed all decide whether the puck comes loose. A low-Physical shove
# barely jars it; an enforcer strips it clean.
#
# Reconstructed from impact_force = attacker_weight × approach (what the
# body_checked_player signal carries) so the attacker-weight term cancels:
#     delivered = approach × (att_weight / vic_weight) × effective_transfer
#               = (impact_force / att_weight) × (att_weight / vic_weight) × eff
#               = impact_force × effective_transfer / vic_weight
# MUST stay equal to the knockback magnitude in
# Skater._resolve_player_collisions (`other.velocity -= normal × approach ×
# weight_ratio × effective_transfer`); test_body_check_rules locks the identity.
static func puck_strip_impulse(
		impact_force: float,
		attacker_transfer: float,
		victim_weight: float,
		victim_brace_resistance: float,
		victim_braced: bool) -> float:
	var effective_transfer: float = attacker_transfer * (victim_brace_resistance if victim_braced else 1.0)
	return impact_force * effective_transfer / maxf(victim_weight, 0.001)
