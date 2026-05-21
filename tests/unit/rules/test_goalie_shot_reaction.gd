extends GutTest

# GoalieShotReaction — owns the reaction freeze + shot/arm processing timers.
# Tests cover start/finish lifecycle, processing-timer expiry returning the
# "drop butterfly" signal, freeze countdown, and client-side mirroring.

var sr: GoalieShotReaction

func before_each() -> void:
	sr = GoalieShotReaction.new()
	sr.reaction_delay = 0.13
	sr.arm_reaction_delay = 0.18
	sr.max_reaction_duration = 1.5
	sr.reaction_clear_delay = 0.25

# ── Defaults ─────────────────────────────────────────────────────────────────

func test_initial_state() -> void:
	assert_false(sr.reacting)
	assert_eq(sr.shot_timer, 0.0)
	assert_eq(sr.arm_timer, 0.0)
	assert_eq(sr.clear_timer, -1.0)
	assert_false(sr.is_elevated)

# ── start() ──────────────────────────────────────────────────────────────────

func test_start_arms_processing_timers() -> void:
	sr.start(0.5, 0.3, false, 0.13)
	assert_true(sr.reacting)
	assert_almost_eq(sr.shot_timer, 0.13, 0.001)
	assert_almost_eq(sr.arm_timer, 0.18, 0.001)
	assert_eq(sr.impact_x, 0.5)
	assert_eq(sr.impact_y, 0.3)
	assert_false(sr.is_elevated)

func test_start_emits_started_signal() -> void:
	watch_signals(sr)
	sr.start(0.5, 0.3, true, 0.13)
	assert_signal_emitted_with_parameters(sr, "started", [0.5, 0.3, true])

func test_start_clears_clear_timer_and_age() -> void:
	sr.clear_timer = 0.1
	sr.age = 0.5
	sr.start(0.0, 0.0, false, 0.13)
	assert_eq(sr.clear_timer, -1.0)
	assert_eq(sr.age, 0.0)

# ── tick_processing_timers ───────────────────────────────────────────────────

# Low shot, upright, timer just expired → returns true to trigger butterfly drop.
func test_processing_timer_expiry_triggers_butterfly_when_upright() -> void:
	sr.start(0.0, 0.2, false, 0.05)
	var triggered: bool = sr.tick_processing_timers(0.1, true)
	assert_true(triggered)

# Elevated shot: never triggers butterfly drop from the shot timer (leg drop
# is for low shots only).
func test_processing_timer_does_not_trigger_for_elevated() -> void:
	sr.start(0.0, 1.2, true, 0.05)
	var triggered: bool = sr.tick_processing_timers(0.1, true)
	assert_false(triggered)

# Not upright (already in butterfly/RVH) — no trigger.
func test_processing_timer_does_not_trigger_when_not_upright() -> void:
	sr.start(0.0, 0.2, false, 0.05)
	var triggered: bool = sr.tick_processing_timers(0.1, false)
	assert_false(triggered)

func test_processing_timer_returns_false_when_not_yet_expired() -> void:
	sr.start(0.0, 0.2, false, 0.13)
	var triggered: bool = sr.tick_processing_timers(0.01, true)
	assert_false(triggered)
	assert_almost_eq(sr.shot_timer, 0.12, 0.001)

func test_arm_timer_decays_in_parallel() -> void:
	sr.start(0.0, 1.2, true, 0.13)
	sr.tick_processing_timers(0.05, true)
	assert_almost_eq(sr.arm_timer, 0.13, 0.001)

func test_arm_pending_during_arm_timer() -> void:
	sr.start(0.0, 1.2, true, 0.13)
	assert_true(sr.arm_pending())
	sr.tick_processing_timers(0.20, false)
	assert_false(sr.arm_pending())

# ── tick_freeze ──────────────────────────────────────────────────────────────

# Carrier present (pickup) arms the clear timer; once it elapses, freeze ends.
func test_carrier_pickup_arms_clear_timer() -> void:
	sr.start(0.0, 0.5, false, 0.13)
	sr.tick_freeze(0.01, true)
	assert_almost_eq(sr.clear_timer, 0.25 - 0.01, 0.01)

func test_clear_timer_elapsed_finishes_reaction() -> void:
	sr.start(0.0, 0.5, false, 0.13)
	sr.arm_clear()
	var ended: bool = sr.tick_freeze(0.3, false)
	assert_true(ended)
	assert_false(sr.reacting)

# Duration cap (safety net) — if no resolving event, finish anyway.
func test_max_duration_finishes_reaction() -> void:
	sr.start(0.0, 0.5, false, 0.13)
	var ended: bool = sr.tick_freeze(2.0, false)
	assert_true(ended)
	assert_false(sr.reacting)

func test_tick_freeze_does_nothing_when_not_reacting() -> void:
	var ended: bool = sr.tick_freeze(1.0, false)
	assert_false(ended)

# ── arm_clear ────────────────────────────────────────────────────────────────

# First event wins — a later arm shouldn't shorten an in-progress clear.
func test_arm_clear_does_not_shorten_in_progress_clear() -> void:
	sr.start(0.0, 0.5, false, 0.13)
	sr.arm_clear()
	sr.tick_freeze(0.1, false)  # clear_timer now 0.15
	sr.arm_clear()              # second arm
	assert_almost_eq(sr.clear_timer, 0.15, 0.01, "second arm doesn't reset to 0.25")

func test_arm_clear_no_op_when_not_reacting() -> void:
	sr.arm_clear()
	assert_eq(sr.clear_timer, -1.0)

# ── finish ───────────────────────────────────────────────────────────────────

func test_finish_emits_signal() -> void:
	sr.start(0.0, 0.5, true, 0.13)
	watch_signals(sr)
	sr.finish()
	assert_signal_emitted(sr, "finished")

func test_finish_clears_is_elevated() -> void:
	sr.start(0.0, 1.2, true, 0.13)
	sr.finish()
	assert_false(sr.is_elevated)
	assert_false(sr.reacting)

func test_finish_no_op_when_not_reacting() -> void:
	watch_signals(sr)
	sr.finish()
	assert_signal_not_emitted(sr, "finished")

# ── tip_to_low ───────────────────────────────────────────────────────────────

# Re-projection sees the elevated shot tip down — arm the butterfly drop.
func test_tip_to_low_clears_elevated_and_arms_shot_timer() -> void:
	sr.start(0.0, 1.2, true, 0.13)
	# Wait out the shot timer first (otherwise tip_to_low is a no-op)
	sr.tick_processing_timers(0.2, false)
	sr.tip_to_low(0.13)
	assert_false(sr.is_elevated)
	assert_almost_eq(sr.shot_timer, 0.13, 0.001)

func test_tip_to_low_no_op_if_not_elevated() -> void:
	sr.start(0.0, 0.3, false, 0.13)
	sr.tick_processing_timers(0.2, false)
	var timer_before: float = sr.shot_timer
	sr.tip_to_low(0.13)
	assert_false(sr.is_elevated)
	assert_eq(sr.shot_timer, timer_before, "tip_to_low is a no-op when shot was never elevated")

# ── Client side ──────────────────────────────────────────────────────────────

func test_apply_remote_seeds_client_timer() -> void:
	sr.apply_remote(0.5, 1.2, true, true, 0.0)
	assert_true(sr.reacting)
	assert_eq(sr.client_timer, GoalieShotReaction.CLIENT_REACTION_DURATION_S)
	assert_eq(sr.impact_x, 0.5)
	assert_eq(sr.impact_y, 1.2)
	assert_true(sr.is_elevated)

# RTT compensation: client subtracts transit time so the processing timer
# lands at the same wall-clock T+delay as the host.
func test_apply_remote_subtracts_rtt_from_shot_timer() -> void:
	sr.apply_remote(0.0, 0.3, false, true, 0.05)
	assert_almost_eq(sr.shot_timer, 0.13 - 0.05, 0.001)
	assert_almost_eq(sr.arm_timer, 0.18 - 0.05, 0.001)

func test_apply_remote_clamps_negative_timer_to_zero() -> void:
	# RTT >= delay → react on arrival
	sr.apply_remote(0.0, 0.3, false, true, 1.0)
	assert_eq(sr.shot_timer, 0.0)
	assert_eq(sr.arm_timer, 0.0)

func test_apply_remote_skips_timers_when_not_upright() -> void:
	sr.shot_timer = 0.05
	sr.arm_timer = 0.05
	sr.apply_remote(0.0, 0.3, false, false, 0.0)
	# Timers untouched when not upright (caller already past the standing/ready window)
	assert_almost_eq(sr.shot_timer, 0.05, 0.001)

func test_tick_client_expires_freeze() -> void:
	sr.apply_remote(0.0, 0.5, false, true, 0.0)
	sr.tick_client(2.0)
	assert_false(sr.reacting)

func test_clear_for_client_drops_all_freeze_state() -> void:
	sr.apply_remote(0.0, 1.2, true, true, 0.0)
	sr.clear_for_client()
	assert_false(sr.reacting)
	assert_false(sr.is_elevated)
	assert_eq(sr.client_timer, 0.0)
	assert_eq(sr.shot_timer, 0.0)

# ── update_impact ────────────────────────────────────────────────────────────

func test_update_impact_replaces_coords() -> void:
	sr.start(0.0, 0.5, false, 0.13)
	sr.update_impact(0.8, 1.1)
	assert_eq(sr.impact_x, 0.8)
	assert_eq(sr.impact_y, 1.1)
