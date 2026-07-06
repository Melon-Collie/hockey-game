extends GutTest

# GaitIntentRules — pure input-intent gait signals (v15 intent byte).
# Frame convention matches CarveRules: Vector2(x, z); forward is (0, −1).


# ── dig_in ────────────────────────────────────────────────────────────────────

func test_dig_full_at_standstill() -> void:
	assert_eq(GaitIntentRules.dig_in(true, 0.0, 4.0), 1.0)


func test_dig_fades_with_speed() -> void:
	assert_almost_eq(GaitIntentRules.dig_in(true, 2.0, 4.0), 0.5, 0.0001)
	assert_eq(GaitIntentRules.dig_in(true, 6.0, 4.0), 0.0)


func test_dig_requires_intent() -> void:
	assert_eq(GaitIntentRules.dig_in(false, 0.0, 4.0), 0.0)


# ── reversal ──────────────────────────────────────────────────────────────────

func test_reversal_full_at_dead_opposite() -> void:
	assert_almost_eq(GaitIntentRules.reversal(
			Vector2(0.0, -6.0), Vector2(0.0, 1.0), 6.0, 2.5, 0.5), 1.0, 0.0001)


func test_reversal_partial_on_back_diagonal() -> void:
	# 135° apart: opposition ≈ 0.707 → (0.707 − 0.5) / 0.5 ≈ 0.41.
	var r: float = GaitIntentRules.reversal(
			Vector2(0.0, -6.0), Vector2(sin(3.0 * PI / 4.0), -cos(3.0 * PI / 4.0)),
			6.0, 2.5, 0.5)
	assert_between(r, 0.3, 0.5)


func test_reversal_zero_when_aligned_or_lateral() -> void:
	assert_eq(GaitIntentRules.reversal(
			Vector2(0.0, -6.0), Vector2(0.0, -1.0), 6.0, 2.5, 0.5), 0.0)
	assert_eq(GaitIntentRules.reversal(
			Vector2(0.0, -6.0), Vector2(1.0, 0.0), 6.0, 2.5, 0.5), 0.0)


func test_reversal_gates_below_min_speed_and_empty_input() -> void:
	assert_eq(GaitIntentRules.reversal(
			Vector2(0.0, -1.0), Vector2(0.0, 1.0), 1.0, 2.5, 0.5), 0.0)
	assert_eq(GaitIntentRules.reversal(
			Vector2(0.0, -6.0), Vector2.ZERO, 6.0, 2.5, 0.5), 0.0)


# ── shuffle ───────────────────────────────────────────────────────────────────

func test_shuffle_full_on_pure_sidestep() -> void:
	assert_almost_eq(GaitIntentRules.shuffle(Vector2(1.0, 0.0), 0.0, 4.0, 0.6), 1.0, 0.0001)


func test_shuffle_signed_by_side() -> void:
	assert_lt(GaitIntentRules.shuffle(Vector2(-1.0, 0.0), 0.0, 4.0, 0.6), 0.0)


func test_shuffle_mild_on_diagonal() -> void:
	# 45° diagonal: lateral fraction ≈ 0.707 → (0.707 − 0.6) / 0.4 ≈ 0.27 —
	# a forward diagonal is mostly a stride, only a hint of side-step.
	var sh: float = GaitIntentRules.shuffle(
			Vector2(sin(PI / 4.0), -cos(PI / 4.0)), 0.0, 4.0, 0.6)
	assert_between(sh, 0.15, 0.4)


func test_shuffle_zero_on_forward_intent() -> void:
	assert_eq(GaitIntentRules.shuffle(Vector2(0.0, -1.0), 0.0, 4.0, 0.6), 0.0)


func test_shuffle_fades_with_speed() -> void:
	assert_almost_eq(GaitIntentRules.shuffle(Vector2(1.0, 0.0), 2.0, 4.0, 0.6), 0.5, 0.0001)
	assert_eq(GaitIntentRules.shuffle(Vector2(1.0, 0.0), 6.0, 4.0, 0.6), 0.0)


# ── backpedal ─────────────────────────────────────────────────────────────────

func test_backpedal_full_holding_straight_back() -> void:
	assert_almost_eq(GaitIntentRules.backpedal(Vector2(0.0, 1.0), 0.35), 1.0, 0.0001)


func test_backpedal_partial_on_back_diagonal() -> void:
	# 45° back-diagonal: backward fraction ≈ 0.707 → (0.707 − 0.35) / 0.65 ≈ 0.55.
	var b: float = GaitIntentRules.backpedal(Vector2(sin(PI / 4.0), cos(PI / 4.0)), 0.35)
	assert_between(b, 0.45, 0.65)


func test_backpedal_zero_forward_or_lateral() -> void:
	assert_eq(GaitIntentRules.backpedal(Vector2(0.0, -1.0), 0.35), 0.0)
	assert_eq(GaitIntentRules.backpedal(Vector2(1.0, 0.0), 0.35), 0.0)


func test_backpedal_zero_on_empty_input() -> void:
	assert_eq(GaitIntentRules.backpedal(Vector2.ZERO, 0.35), 0.0)
