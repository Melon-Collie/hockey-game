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
	var hit_drain_per_sec: float = 0.5       # fraction/sec drained while committing a check (hit button)

# Whether the sprint boost is engaged this tick. Requires the key held, real
# movement input (not coasting or braking — that's the caller's `is_moving`),
# stamina remaining, and not currently exhausted.
static func sprint_active(stamina: float, sprint_held: bool, is_moving: bool, locked: bool) -> bool:
	return sprint_held and is_moving and not locked and stamina > 0.0

# Whether a body-check commit is engaged this tick. Like sprint it's the same
# stamina pool and lockout, but it does NOT require movement — you can hold the
# check-ready stance stationary to line someone up. Drains whether or not you
# connect (the exertion is holding the commit), so it's a resource read.
static func hit_active(stamina: float, hit_held: bool, locked: bool) -> bool:
	return hit_held and not locked and stamina > 0.0

# Stamina one tick later. Drains for sprint (faster while carrying) AND/OR a hit
# commit — the two are additive on the shared pool — otherwise regenerates toward
# the 1.0 ceiling. Clamped at both ends. `hit_committed` trails with a default so
# existing sprint-only callers are unaffected.
static func next_stamina(stamina: float, active: bool, has_puck: bool, delta: float, cfg: StaminaConfig, hit_committed: bool = false) -> float:
	var drain: float = 0.0
	if active:
		drain += cfg.drain_per_sec * (cfg.carry_drain_multiplier if has_puck else 1.0)
	if hit_committed:
		drain += cfg.hit_drain_per_sec
	if drain > 0.0:
		return maxf(stamina - drain * delta, 0.0)
	return minf(stamina + cfg.regen_per_sec * delta, 1.0)

# Lockout flag one tick later. Pass the *already-updated* stamina from
# next_stamina(). Latches true when any stamina draw (sprint or hit commit)
# bottoms out at zero; clears only once stamina has recovered to unlock_fraction
# while nothing is drawing. `hit_committed` trails with a default for
# back-compatibility with sprint-only callers.
static func next_locked(locked: bool, stamina: float, active: bool, cfg: StaminaConfig, hit_committed: bool = false) -> bool:
	var draining: bool = active or hit_committed
	if draining and stamina <= 0.0:
		return true
	if locked and not draining and stamina >= cfg.unlock_fraction:
		return false
	return locked
