extends GutTest

# HitRules — gates for crediting a body check as a hit.

# ── is_valid_hit ─────────────────────────────────────────────────────────────

func test_valid_hit_passes_all_gates() -> void:
	assert_true(HitRules.is_valid_hit(HitRules.MIN_HIT_IMPULSE + 1.0, false, true))

func test_below_impulse_threshold_rejected() -> void:
	assert_false(HitRules.is_valid_hit(HitRules.MIN_HIT_IMPULSE - 0.01, false, true))

func test_at_impulse_threshold_passes() -> void:
	assert_true(HitRules.is_valid_hit(HitRules.MIN_HIT_IMPULSE, false, true))

func test_attacker_carrying_puck_rejected() -> void:
	assert_false(HitRules.is_valid_hit(HitRules.MIN_HIT_IMPULSE + 5.0, true, true))

func test_victim_not_puck_relevant_rejected() -> void:
	assert_false(HitRules.is_valid_hit(HitRules.MIN_HIT_IMPULSE + 5.0, false, false))

# ── is_victim_puck_relevant ──────────────────────────────────────────────────

func test_victim_is_puck_carrier() -> void:
	assert_true(HitRules.is_victim_puck_relevant(
			2, 2, Vector3(10.0, 0.0, 10.0), Vector3(50.0, 0.0, 50.0)))

func test_victim_within_proximity_radius() -> void:
	# Puck offset by less than PUCK_PROXIMITY_RADIUS on the XZ plane.
	var offset: float = HitRules.PUCK_PROXIMITY_RADIUS - 0.1
	assert_true(HitRules.is_victim_puck_relevant(
			2, 99, Vector3.ZERO, Vector3(offset, 0.0, 0.0)))

func test_victim_outside_proximity_radius() -> void:
	var offset: float = HitRules.PUCK_PROXIMITY_RADIUS + 0.1
	assert_false(HitRules.is_victim_puck_relevant(
			2, 99, Vector3.ZERO, Vector3(offset, 0.0, 0.0)))

func test_proximity_ignores_y_axis() -> void:
	# Y differences (e.g. puck airborne) must not push us outside the radius.
	assert_true(HitRules.is_victim_puck_relevant(
			2, 99, Vector3.ZERO, Vector3(0.0, 100.0, 0.0)))
