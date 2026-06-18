class_name StaminaRules

# Pure sprint / stamina math, extracted so it can be unit-tested without a live
# skater. Stamina is a 0..1 fraction of a full pool. The caller (SkaterController)
# owns the `stamina` + `locked` state and calls these three pure helpers each
# physics tick.
#
# Determinism note: every output is a pure function of the current stamina,
# lock flag, and this tick's input — exactly like SkaterMovementRules. That is
# what lets stamina survive client-side prediction + reconcile: LocalController
# snaps `stamina` / `_sprint_locked` to the server baseline at replay start and
# then re-derives them forward through the replayed inputs (the same treatment
# velocity gets), so host and client stay bit-for-bit aligned.
#
# Exhaustion lockout: when stamina hits zero `locked` latches true and the
# sprint boost won't re-engage until stamina has regenerated back up to
# `unlock_fraction`. Without the latch, sprint would flicker on/off tick-by-tick
# at an empty bar (regen one tick, drain it the next). The lock flag is part of
# the replicated state for the same reason stamina is.

class StaminaConfig:
	var drain_per_sec: float = 0.45          # fraction/sec drained while sprinting (no puck)
	var carry_drain_multiplier: float = 1.6  # extra drain while carrying the puck
	var regen_per_sec: float = 0.30          # fraction/sec regained while not sprinting
	var unlock_fraction: float = 0.5         # exhausted → must regen to here before sprinting again

# Whether the sprint boost is engaged this tick. Requires the key held, real
# movement input (not coasting or braking — that's the caller's `is_moving`),
# stamina remaining, and not currently exhausted.
static func sprint_active(stamina: float, sprint_held: bool, is_moving: bool, locked: bool) -> bool:
	return sprint_held and is_moving and not locked and stamina > 0.0

# Stamina one tick later. Drains (faster while carrying) when the boost is
# active, otherwise regenerates toward the 1.0 ceiling. Clamped at both ends.
static func next_stamina(stamina: float, active: bool, has_puck: bool, delta: float, cfg: StaminaConfig) -> float:
	if active:
		var drain: float = cfg.drain_per_sec * (cfg.carry_drain_multiplier if has_puck else 1.0)
		return maxf(stamina - drain * delta, 0.0)
	return minf(stamina + cfg.regen_per_sec * delta, 1.0)

# Lockout flag one tick later. Pass the *already-updated* stamina from
# next_stamina(). Latches true when an active sprint bottoms out at zero; clears
# only once stamina has recovered to unlock_fraction while not sprinting.
static func next_locked(locked: bool, stamina: float, active: bool, cfg: StaminaConfig) -> bool:
	if active and stamina <= 0.0:
		return true
	if locked and not active and stamina >= cfg.unlock_fraction:
		return false
	return locked
