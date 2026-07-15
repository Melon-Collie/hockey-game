extends GutTest

# StaminaRules — pure sprint/stamina math. Caller owns stamina + lock state;
# each tick produces the next stamina and lock flag. These tests exercise the
# drain/regen curves, the carry penalty, and the exhaustion lockout hysteresis.

var _cfg: StaminaRules.StaminaConfig

func before_each() -> void:
	_cfg = StaminaRules.StaminaConfig.new()
	_cfg.drain_per_sec = 0.5
	_cfg.carry_drain_multiplier = 2.0
	_cfg.regen_per_sec = 0.25
	_cfg.unlock_fraction = 0.5
	_cfg.hit_drain_per_sec = 0.4


# ── sprint_active ─────────────────────────────────────────────────────────────

func test_sprint_active_requires_held_moving_and_stamina() -> void:
	assert_true(StaminaRules.sprint_active(1.0, true, true, false), "held + moving + stamina → active")
	assert_false(StaminaRules.sprint_active(1.0, false, true, false), "not held → inactive")
	assert_false(StaminaRules.sprint_active(1.0, true, false, false), "not moving → inactive")
	assert_false(StaminaRules.sprint_active(0.0, true, true, false), "empty stamina → inactive")
	assert_false(StaminaRules.sprint_active(1.0, true, true, true), "locked → inactive even with full stamina")


# ── next_stamina ──────────────────────────────────────────────────────────────

func test_drain_while_sprinting() -> void:
	# 0.5/sec for 0.5s = 0.25 drained
	var s: float = StaminaRules.next_stamina(1.0, true, false, 0.5, _cfg)
	assert_almost_eq(s, 0.75, 0.0001, "drains at drain_per_sec while not carrying")

func test_carry_drains_faster() -> void:
	# 0.5 * 2.0 = 1.0/sec for 0.5s = 0.5 drained
	var s: float = StaminaRules.next_stamina(1.0, true, true, 0.5, _cfg)
	assert_almost_eq(s, 0.5, 0.0001, "carry multiplier increases drain")

func test_drain_clamps_at_zero() -> void:
	var s: float = StaminaRules.next_stamina(0.1, true, true, 1.0, _cfg)
	assert_eq(s, 0.0, "stamina can't go negative")

func test_regen_when_not_active() -> void:
	var s: float = StaminaRules.next_stamina(0.5, false, false, 1.0, _cfg)
	assert_almost_eq(s, 0.75, 0.0001, "regenerates at regen_per_sec when not sprinting")

func test_regen_clamps_at_one() -> void:
	var s: float = StaminaRules.next_stamina(0.95, false, false, 1.0, _cfg)
	assert_eq(s, 1.0, "stamina can't exceed full")

func test_has_puck_ignored_while_regenerating() -> void:
	# The carry multiplier only applies to drain, never to regen.
	var s: float = StaminaRules.next_stamina(0.5, false, true, 1.0, _cfg)
	assert_almost_eq(s, 0.75, 0.0001, "carry flag doesn't affect regen rate")


# ── hit_active + hit drain ────────────────────────────────────────────────────

func test_hit_active_requires_held_and_stamina_but_not_moving() -> void:
	# Unlike sprint, a hit commit needs no movement (line someone up while parked).
	assert_true(StaminaRules.hit_active(1.0, true, false), "held + stamina → active (movement not required)")
	assert_false(StaminaRules.hit_active(1.0, false, false), "not held → inactive")
	assert_false(StaminaRules.hit_active(0.0, true, false), "empty stamina → inactive")
	assert_false(StaminaRules.hit_active(1.0, true, true), "locked → inactive")

func test_hit_drains_stamina() -> void:
	# 0.4/sec for 0.5s = 0.2 drained, with no sprint active.
	var s: float = StaminaRules.next_stamina(1.0, false, false, 0.5, _cfg, true)
	assert_almost_eq(s, 0.8, 0.0001, "hit commit drains at hit_drain_per_sec")

func test_sprint_and_hit_drains_are_additive() -> void:
	# Sprint (0.5) + hit (0.4) = 0.9/sec for 0.5s = 0.45 drained.
	var s: float = StaminaRules.next_stamina(1.0, true, false, 0.5, _cfg, true)
	assert_almost_eq(s, 0.55, 0.0001, "sprint and hit drains stack on the shared pool")

func test_hit_alone_regenerates_when_not_committed() -> void:
	var s: float = StaminaRules.next_stamina(0.5, false, false, 1.0, _cfg, false)
	assert_almost_eq(s, 0.75, 0.0001, "no draw (sprint or hit) → regenerates")

func test_hit_commit_latches_lock_at_empty() -> void:
	assert_true(StaminaRules.next_locked(false, 0.0, false, _cfg, true), "empty during a hit commit → locked")

func test_hit_commit_blocks_unlock() -> void:
	assert_true(StaminaRules.next_locked(true, 0.6, false, _cfg, true), "clear requires no draw — a held hit commit blocks it")


# ── next_locked (exhaustion hysteresis) ───────────────────────────────────────

func test_lock_latches_when_active_sprint_bottoms_out() -> void:
	assert_true(StaminaRules.next_locked(false, 0.0, true, _cfg), "empty during active sprint → locked")

func test_no_lock_while_stamina_remains() -> void:
	assert_false(StaminaRules.next_locked(false, 0.3, true, _cfg), "stamina left → stays unlocked")

func test_lock_holds_until_unlock_fraction() -> void:
	assert_true(StaminaRules.next_locked(true, 0.49, false, _cfg), "below unlock_fraction → stays locked")
	assert_false(StaminaRules.next_locked(true, 0.5, false, _cfg), "reached unlock_fraction → clears")

func test_lock_does_not_clear_while_active() -> void:
	# Defensive: sprint_active() already gates on `locked`, so an active sprint
	# while locked shouldn't happen, but the clear must not fire mid-sprint.
	assert_true(StaminaRules.next_locked(true, 0.6, true, _cfg), "clear requires not-active")


# ── Integration: full drain → lock → regen → unlock cycle ─────────────────────

func test_full_exhaustion_cycle() -> void:
	var stamina: float = 1.0
	var locked: bool = false
	var dt: float = 1.0 / 240.0
	# Sprint (no puck) until exhausted.
	var ticks: int = 0
	while ticks < 10000:
		var active: bool = StaminaRules.sprint_active(stamina, true, true, locked)
		stamina = StaminaRules.next_stamina(stamina, active, false, dt, _cfg)
		locked = StaminaRules.next_locked(locked, stamina, active, _cfg)
		ticks += 1
		if locked:
			break
	assert_true(locked, "sprinting eventually exhausts and locks")
	assert_eq(stamina, 0.0, "locks exactly at empty")

	# Holding sprint while locked must not drain or unlock below the threshold.
	var active_locked: bool = StaminaRules.sprint_active(stamina, true, true, locked)
	assert_false(active_locked, "can't sprint while locked")
	stamina = StaminaRules.next_stamina(stamina, active_locked, false, dt, _cfg)
	assert_eq(stamina, StaminaRules.next_stamina(0.0, false, false, dt, _cfg), "regens even while holding sprint when locked")

	# Regen back up; lock clears at unlock_fraction.
	ticks = 0
	while ticks < 10000 and locked:
		var active: bool = StaminaRules.sprint_active(stamina, true, true, locked)
		stamina = StaminaRules.next_stamina(stamina, active, false, dt, _cfg)
		locked = StaminaRules.next_locked(locked, stamina, active, _cfg)
		ticks += 1
	assert_false(locked, "regenerating to unlock_fraction clears the lock")
	assert_almost_eq(stamina, _cfg.unlock_fraction, 0.01, "unlocks right around unlock_fraction")
