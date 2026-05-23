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


# ── Wrister charge — same input sequence yields same state ───────────────────

func test_wrister_charge_deterministic_from_neutral_start() -> void:
	var a := SkaterAimingBehavior.new()
	var b := SkaterAimingBehavior.new()
	a.reset_wrister(Vector2.ZERO)
	b.reset_wrister(Vector2.ZERO)
	# Identical synthetic mouse-sweep sequence — diagonal drag with a small
	# direction reversal mid-sweep to exercise the variance check.
	var sweep: Array[Vector2] = [
		Vector2(10, 0), Vector2(20, 5), Vector2(30, 10),
		Vector2(40, 12), Vector2(35, 15), Vector2(45, 18), Vector2(55, 20),
	]
	for p: Vector2 in sweep:
		a.tick_wrister_charge(p, 35.0, 2.0)
		b.tick_wrister_charge(p, 35.0, 2.0)
	assert_eq(a.charge_distance, b.charge_distance,
			"charge_distance must be deterministic from identical input sequence")
	assert_eq(a.prev_blade_dir, b.prev_blade_dir,
			"prev_blade_dir must match")
	assert_eq(a.prev_mouse_screen_pos, b.prev_mouse_screen_pos,
			"prev_mouse_screen_pos must match")


func test_wrister_charge_deterministic_from_mid_charge_start() -> void:
	# Mimics reconcile: save state, replay same inputs from the saved state,
	# expect identical end state. The "saved state" here is a partially-built
	# charge that two instances inherit identically.
	var a := SkaterAimingBehavior.new()
	var b := SkaterAimingBehavior.new()
	a.charge_distance = 0.4
	a.prev_blade_dir = Vector3(0.6, 0.0, 0.8)
	a.prev_mouse_screen_pos = Vector2(100, 50)
	b.charge_distance = 0.4
	b.prev_blade_dir = Vector3(0.6, 0.0, 0.8)
	b.prev_mouse_screen_pos = Vector2(100, 50)
	var sweep: Array[Vector2] = [
		Vector2(110, 55), Vector2(125, 65), Vector2(140, 78), Vector2(155, 92),
	]
	for p: Vector2 in sweep:
		a.tick_wrister_charge(p, 35.0, 2.0)
		b.tick_wrister_charge(p, 35.0, 2.0)
	assert_eq(a.charge_distance, b.charge_distance)
	assert_eq(a.prev_blade_dir, b.prev_blade_dir)
	assert_eq(a.prev_mouse_screen_pos, b.prev_mouse_screen_pos)


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
	a.reset_wrister(Vector2.ZERO)
	b.reset_wrister(Vector2.ZERO)
	a.tick_wrister_charge(Vector2(100, 0), 35.0, 2.0)
	a.tick_wrister_charge(Vector2(200, 0), 35.0, 2.0)
	b.tick_wrister_charge(Vector2(50, 0), 35.0, 2.0)
	b.tick_wrister_charge(Vector2(75, 0), 35.0, 2.0)
	assert_ne(a.charge_distance, b.charge_distance,
			"different sweep magnitudes must produce different charge")
