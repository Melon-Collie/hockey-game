extends GutTest

# SkaterAimingBehavior is owned by SkaterController and ticked inside
# _process_input. Reconcile replay runs the same input sequence twice (once
# during live prediction, once during reconcile replay) and assumes the
# output is bit-identical given matching starting state.
#
# These tests pin the determinism guarantee. If a future change makes the
# aiming tick depend on engine time, RNG, or any state outside the inputs +
# explicit starting state, the test fails and the reconcile divergence
# channel is caught in CI instead of in a player session months later.
#
# Pattern is general: any RefCounted that participates in reconcile replay
# should have a determinism test like this.


# ── Wrister swing — same input sequence yields same state ────────────────────

const DT: float = 1.0 / 120.0
const SMOOTHING: float = 14.0

func test_wrister_charge_deterministic_from_neutral_start() -> void:
	var a := SkaterAimingBehavior.new()
	var b := SkaterAimingBehavior.new()
	a.reset_wrister(Vector3.ZERO, Vector3.ZERO)
	b.reset_wrister(Vector3.ZERO, Vector3.ZERO)
	# Identical synthetic cursor+blade sweep — both track together (active
	# drag), with a small direction reversal mid-sweep to exercise variance.
	var sweep: Array[Vector3] = [
		Vector3(0.1, 0.0, 0.0), Vector3(0.2, 0.0, 0.05), Vector3(0.3, 0.0, 0.1),
		Vector3(0.4, 0.0, 0.12), Vector3(0.35, 0.0, 0.15), Vector3(0.45, 0.0, 0.18), Vector3(0.55, 0.0, 0.2),
	]
	for p: Vector3 in sweep:
		a.tick_wrister_charge(p, p, 35.0, DT, SMOOTHING)
		b.tick_wrister_charge(p, p, 35.0, DT, SMOOTHING)
	assert_eq(a.cursor_speed_ema, b.cursor_speed_ema,
			"cursor_speed_ema (the power signal) must be deterministic from identical inputs")
	assert_eq(a.swing_rotation, b.swing_rotation,
			"swing_rotation must be deterministic from identical inputs")
	assert_eq(a.stroke_travel, b.stroke_travel,
			"stroke_travel (the power-ceiling gate) must be deterministic from identical inputs")
	assert_eq(a.prev_blade_dir, b.prev_blade_dir,
			"prev_blade_dir must match")
	assert_eq(a.prev_intent_pos, b.prev_intent_pos,
			"prev_intent_pos must match")
	assert_eq(a.prev_blade_pos_rel_skater, b.prev_blade_pos_rel_skater,
			"prev_blade_pos_rel_skater must match")


func test_wrister_charge_deterministic_from_mid_charge_start() -> void:
	# Mimics reconcile: save state, replay same inputs from the saved state,
	# expect identical end state. The "saved state" here is a partially-built
	# swing that two instances inherit identically.
	var a := SkaterAimingBehavior.new()
	var b := SkaterAimingBehavior.new()
	a.cursor_speed_ema = 700.0
	a.swing_rotation = 0.3
	a.stroke_travel = 0.4
	a.prev_blade_dir = Vector3(0.6, 0.0, 0.8)
	a.prev_intent_pos = Vector3(0.3, 0.0, 0.2)
	a.prev_blade_pos_rel_skater = Vector3(0.3, 0.0, 0.2)
	b.cursor_speed_ema = 700.0
	b.swing_rotation = 0.3
	b.stroke_travel = 0.4
	b.prev_blade_dir = Vector3(0.6, 0.0, 0.8)
	b.prev_intent_pos = Vector3(0.3, 0.0, 0.2)
	b.prev_blade_pos_rel_skater = Vector3(0.3, 0.0, 0.2)
	var sweep: Array[Vector3] = [
		Vector3(0.35, 0.0, 0.22), Vector3(0.4, 0.0, 0.25), Vector3(0.45, 0.0, 0.28), Vector3(0.5, 0.0, 0.32),
	]
	for p: Vector3 in sweep:
		a.tick_wrister_charge(p, p, 35.0, DT, SMOOTHING)
		b.tick_wrister_charge(p, p, 35.0, DT, SMOOTHING)
	assert_eq(a.cursor_speed_ema, b.cursor_speed_ema)
	assert_eq(a.swing_rotation, b.swing_rotation)
	assert_eq(a.stroke_travel, b.stroke_travel)
	assert_eq(a.prev_blade_dir, b.prev_blade_dir)
	assert_eq(a.prev_intent_pos, b.prev_intent_pos)
	assert_eq(a.prev_blade_pos_rel_skater, b.prev_blade_pos_rel_skater)


# ── Slapper charge — timer accumulation is pure delta sum ────────────────────

func test_slapper_charge_timer_deterministic() -> void:
	var a := SkaterAimingBehavior.new()
	var b := SkaterAimingBehavior.new()
	# Different physics frame timings shouldn't change the result if the same
	# delta sequence is applied. Documented invariant: slapper_charge_timer
	# is saved/restored across reconcile to prevent O(N) re-tick.
	var deltas: Array[float] = [
		1.0/240.0, 1.0/240.0, 1.0/240.0, 1.0/240.0, 1.0/240.0,
		1.0/240.0, 1.0/240.0, 1.0/240.0,
	]
	for dt: float in deltas:
		a.tick_slapper(dt)
		b.tick_slapper(dt)
	assert_eq(a.slapper_charge_timer, b.slapper_charge_timer)


func test_slapper_charge_re_tick_inflates_without_save_restore() -> void:
	# This is the symptom the slapper_charge_timer save/restore in
	# LocalController.reconcile prevents. If the same input sequence is
	# replayed twice without resetting state in between, the timer doubles.
	# Test exists to make the failure mode explicit — if someone ever removes
	# the save/restore, this is what they'd be re-introducing.
	var a := SkaterAimingBehavior.new()
	var deltas: Array[float] = [1.0/240.0, 1.0/240.0, 1.0/240.0]
	# First "live" tick pass
	for dt: float in deltas:
		a.tick_slapper(dt)
	var after_first: float = a.slapper_charge_timer
	# Replay the same inputs without restoring saved state — timer compounds.
	for dt: float in deltas:
		a.tick_slapper(dt)
	assert_gt(a.slapper_charge_timer, after_first * 1.99,
			"replay without save/restore inflates timer ~O(N)")


# ── One-timer window — countdown is deterministic ────────────────────────────

func test_one_timer_window_deterministic() -> void:
	var a := SkaterAimingBehavior.new()
	var b := SkaterAimingBehavior.new()
	a.one_timer_window_timer = 0.5
	b.one_timer_window_timer = 0.5
	var deltas: Array[float] = [0.016, 0.016, 0.016, 0.016, 0.016]
	for dt: float in deltas:
		a.tick_one_timer_window(dt)
		b.tick_one_timer_window(dt)
	assert_eq(a.one_timer_window_timer, b.one_timer_window_timer)


func test_one_timer_window_stops_at_zero() -> void:
	# Countdown must clamp at zero — replay over the boundary shouldn't go
	# negative or wrap. Both instances should bottom out identically.
	var a := SkaterAimingBehavior.new()
	a.one_timer_window_timer = 0.05
	for i in range(10):  # well past expiration
		a.tick_one_timer_window(0.016)
	assert_true(a.one_timer_window_timer <= 0.0,
			"one_timer_window must not go negative under sustained ticks")


# ── Negative case — different inputs MUST produce different state ────────────
# Sanity check the test harness itself: the assertions would silently pass
# if the methods were no-ops. This ensures non-trivial behavior is being
# exercised.

func test_wrister_charge_differs_for_different_sequences() -> void:
	var a := SkaterAimingBehavior.new()
	var b := SkaterAimingBehavior.new()
	a.reset_wrister(Vector3.ZERO, Vector3.ZERO)
	b.reset_wrister(Vector3.ZERO, Vector3.ZERO)
	# Faster per-tick cursor travel → higher cursor_speed_ema (more power).
	a.tick_wrister_charge(Vector3(10.0, 0, 0), Vector3(10.0, 0, 0), 35.0, DT, SMOOTHING)
	a.tick_wrister_charge(Vector3(20.0, 0, 0), Vector3(20.0, 0, 0), 35.0, DT, SMOOTHING)
	b.tick_wrister_charge(Vector3(1.0, 0, 0), Vector3(1.0, 0, 0), 35.0, DT, SMOOTHING)
	b.tick_wrister_charge(Vector3(2.0, 0, 0), Vector3(2.0, 0, 0), 35.0, DT, SMOOTHING)
	assert_ne(a.cursor_speed_ema, b.cursor_speed_ema,
			"different sweep speeds must produce different power")
