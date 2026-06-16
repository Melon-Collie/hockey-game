extends GutTest

# PuckInteractionRules — segment-segment swept detection.
# Both puck and blade paths are swept across the tick, so fast blade swings
# against a stationary puck are caught. Y components kept at zero unless a
# test needs 3D coverage. Static-blade tests pass the same vector for
# blade_prev and blade_curr to match the old capsule-vs-point behaviour.


# ── check_pickup — static blade (degenerate blade segment) ───────────────────

func test_pickup_detects_direct_hit() -> void:
	assert_true(PuckInteractionRules.check_pickup(
		Vector3(0, 0, 0), Vector3(1, 0, 0),
		Vector3(0.5, 0, 0), Vector3(0.5, 0, 0), 0.5))


func test_pickup_misses_when_blade_outside_radius() -> void:
	assert_false(PuckInteractionRules.check_pickup(
		Vector3(0, 0, 0), Vector3(1, 0, 0),
		Vector3(0.5, 0, 0.6), Vector3(0.5, 0, 0.6), 0.5))


func test_pickup_hits_at_exact_radius_boundary() -> void:
	assert_true(PuckInteractionRules.check_pickup(
		Vector3(0, 0, 0), Vector3(1, 0, 0),
		Vector3(0.5, 0, 0.5), Vector3(0.5, 0, 0.5), 0.5))


func test_pickup_misses_when_blade_beyond_path_end() -> void:
	assert_false(PuckInteractionRules.check_pickup(
		Vector3(0, 0, 0), Vector3(1, 0, 0),
		Vector3(3, 0, 0), Vector3(3, 0, 0), 0.5))


func test_pickup_misses_when_blade_behind_path_start() -> void:
	assert_false(PuckInteractionRules.check_pickup(
		Vector3(2, 0, 0), Vector3(3, 0, 0),
		Vector3(0, 0, 0.4), Vector3(0, 0, 0.4), 0.5))


func test_pickup_detects_when_prev_is_inside_radius() -> void:
	assert_true(PuckInteractionRules.check_pickup(
		Vector3(0.1, 0, 0), Vector3(2, 0, 0),
		Vector3(0, 0, 0), Vector3(0, 0, 0), 0.5))


# ── Zero-length puck segment (stationary puck), static blade ─────────────────

func test_pickup_stationary_puck_inside_radius() -> void:
	assert_true(PuckInteractionRules.check_pickup(
		Vector3(0, 0, 0), Vector3(0, 0, 0),
		Vector3(0.3, 0, 0), Vector3(0.3, 0, 0), 0.5))


func test_pickup_stationary_puck_outside_radius() -> void:
	assert_false(PuckInteractionRules.check_pickup(
		Vector3(0, 0, 0), Vector3(0, 0, 0),
		Vector3(0.6, 0, 0), Vector3(0.6, 0, 0), 0.5))


# ── Tunneling protection — fast puck, static blade ───────────────────────────

func test_pickup_catches_fast_puck_that_passes_through_zone() -> void:
	assert_true(PuckInteractionRules.check_pickup(
		Vector3(0, 0, 0), Vector3(10, 0, 0),
		Vector3(5, 0, 0.3), Vector3(5, 0, 0.3), 0.5))


func test_pickup_fast_puck_still_misses_when_offset_exceeds_radius() -> void:
	assert_false(PuckInteractionRules.check_pickup(
		Vector3(0, 0, 0), Vector3(10, 0, 0),
		Vector3(5, 0, 0.6), Vector3(5, 0, 0.6), 0.5))


# ── Stationary puck + fast blade swing (was missed by old point test) ─────────

func test_pickup_stationary_puck_fast_blade_sweep_through_zone() -> void:
	# Puck at origin; blade sweeps from X=−2 to X=+2 in one tick.
	# Old test: point at X=+2, 2 m away from puck → miss. New: segment hits.
	assert_true(PuckInteractionRules.check_pickup(
		Vector3(0, 0, 0), Vector3(0, 0, 0),
		Vector3(-2, 0, 0), Vector3(2, 0, 0), 0.5))


func test_pickup_stationary_puck_fast_blade_sweep_misses_with_lateral_offset() -> void:
	# Blade sweeps parallel but 0.6 m away in Z — outside radius.
	assert_false(PuckInteractionRules.check_pickup(
		Vector3(0, 0, 0), Vector3(0, 0, 0),
		Vector3(-2, 0, 0.6), Vector3(2, 0, 0.6), 0.5))


# ── Both puck and blade moving toward each other ─────────────────────────────

func test_pickup_both_moving_toward_each_other() -> void:
	# Puck moves from X=2 → X=1; blade moves from X=−1 → X=0.
	# At closest approach they are 1 m apart — within radius 0.5? No, 1 > 0.5.
	assert_false(PuckInteractionRules.check_pickup(
		Vector3(2, 0, 0), Vector3(1, 0, 0),
		Vector3(-1, 0, 0), Vector3(0, 0, 0), 0.5))


func test_pickup_both_moving_toward_each_other_collision() -> void:
	# Puck moves from X=1 → X=0.3; blade moves from X=0 → X=0.6.
	# Segments overlap in X around 0.3–0.6 → within radius.
	assert_true(PuckInteractionRules.check_pickup(
		Vector3(1, 0, 0), Vector3(0.3, 0, 0),
		Vector3(0, 0, 0), Vector3(0.6, 0, 0), 0.5))


# ── Degenerate zero-length blade segment ─────────────────────────────────────

func test_pickup_degenerate_blade_segment_hit() -> void:
	# blade_prev == blade_curr — degenerates to segment-vs-point.
	assert_true(PuckInteractionRules.check_pickup(
		Vector3(0, 0, 0), Vector3(1, 0, 0),
		Vector3(0.5, 0, 0.3), Vector3(0.5, 0, 0.3), 0.5))


func test_pickup_degenerate_blade_segment_miss() -> void:
	assert_false(PuckInteractionRules.check_pickup(
		Vector3(0, 0, 0), Vector3(1, 0, 0),
		Vector3(0.5, 0, 0.6), Vector3(0.5, 0, 0.6), 0.5))


func test_pickup_both_segments_degenerate() -> void:
	# puck_prev == puck_curr and blade_prev == blade_curr — pure point-vs-point.
	assert_true(PuckInteractionRules.check_pickup(
		Vector3(0, 0, 0), Vector3(0, 0, 0),
		Vector3(0.3, 0, 0), Vector3(0.3, 0, 0), 0.5))
	assert_false(PuckInteractionRules.check_pickup(
		Vector3(0, 0, 0), Vector3(0, 0, 0),
		Vector3(0.6, 0, 0), Vector3(0.6, 0, 0), 0.5))


# ── 3D coverage ───────────────────────────────────────────────────────────────

func test_pickup_works_correctly_with_y_offset() -> void:
	assert_true(PuckInteractionRules.check_pickup(
		Vector3(0, 0.05, 0), Vector3(1, 0.05, 0),
		Vector3(0.5, 0.05, 0.3), Vector3(0.5, 0.05, 0.3), 0.5))


# ── check_poke ────────────────────────────────────────────────────────────────

func test_poke_detects_direct_hit() -> void:
	assert_true(PuckInteractionRules.check_poke(
		Vector3(0, 0, 0), Vector3(1, 0, 0),
		Vector3(0.5, 0, 0), Vector3(0.5, 0, 0), 0.5))


func test_poke_misses_when_outside_radius() -> void:
	assert_false(PuckInteractionRules.check_poke(
		Vector3(0, 0, 0), Vector3(1, 0, 0),
		Vector3(0.5, 0, 0.6), Vector3(0.5, 0, 0.6), 0.5))


func test_poke_and_pickup_return_same_result_for_same_inputs() -> void:
	var cases: Array = [
		[Vector3(0,0,0), Vector3(1,0,0), Vector3(0.5,0,0.3), Vector3(0.5,0,0.3), 0.5],
		[Vector3(0,0,0), Vector3(1,0,0), Vector3(0.5,0,0.6), Vector3(0.5,0,0.6), 0.5],
		[Vector3(0,0,0), Vector3(0,0,0), Vector3(0.4,0,0),   Vector3(0.4,0,0),   0.5],
		[Vector3(0,0,0), Vector3(10,0,0), Vector3(5,0,0.3),  Vector3(5,0,0.3),   0.5],
		# Fast blade sweep through stationary puck.
		[Vector3(0,0,0), Vector3(0,0,0), Vector3(-2,0,0),    Vector3(2,0,0),     0.5],
	]
	for c: Array in cases:
		var pickup := PuckInteractionRules.check_pickup(c[0], c[1], c[2], c[3], c[4])
		var poke   := PuckInteractionRules.check_poke(c[0], c[1], c[2], c[3], c[4])
		assert_eq(pickup, poke, "check_pickup and check_poke disagree for %s" % str(c))


# ── check_blade_under_stick — stick-lift trigger geometry ────────────────────
# Victim's stick runs along X at height Y=1 (hand at x=0, blade at x=1).
# Attacker's blade is a single point.

func test_blade_under_stick_hooked_below_within_radius() -> void:
	# Attacker blade directly below the middle of the shaft, 0.2 m down.
	assert_true(PuckInteractionRules.check_blade_under_stick(
		Vector3(0.5, 0.8, 0),
		Vector3(0, 1, 0), Vector3(1, 1, 0), 0.5))

func test_blade_above_stick_does_not_trigger() -> void:
	# Same proximity but the attacker blade is above the shaft — not hooked under.
	assert_false(PuckInteractionRules.check_blade_under_stick(
		Vector3(0.5, 1.2, 0),
		Vector3(0, 1, 0), Vector3(1, 1, 0), 0.5))

func test_blade_below_but_beyond_radius_does_not_trigger() -> void:
	# Below the shaft but 0.8 m away — outside the radius.
	assert_false(PuckInteractionRules.check_blade_under_stick(
		Vector3(0.5, 0.2, 0),
		Vector3(0, 1, 0), Vector3(1, 1, 0), 0.5))

func test_blade_level_with_stick_does_not_trigger() -> void:
	# Exactly level (not strictly below) with zero margin → no trigger.
	assert_false(PuckInteractionRules.check_blade_under_stick(
		Vector3(0.5, 1.0, 0),
		Vector3(0, 1, 0), Vector3(1, 1, 0), 0.5))

func test_blade_under_stick_closest_point_at_endpoint() -> void:
	# Attacker blade off the hand end of the shaft; closest point is the hand
	# endpoint (0,1,0). Within radius and below → triggers.
	assert_true(PuckInteractionRules.check_blade_under_stick(
		Vector3(-0.2, 0.7, 0),
		Vector3(0, 1, 0), Vector3(1, 1, 0), 0.5))

func test_blade_under_stick_degenerate_zero_length_shaft() -> void:
	# Zero-length shaft degenerates to point-vs-point at the hand position.
	assert_true(PuckInteractionRules.check_blade_under_stick(
		Vector3(0, 0.8, 0),
		Vector3(0, 1, 0), Vector3(0, 1, 0), 0.5))
	assert_false(PuckInteractionRules.check_blade_under_stick(
		Vector3(0, 1.2, 0),
		Vector3(0, 1, 0), Vector3(0, 1, 0), 0.5))

func test_blade_under_stick_under_margin_requires_clearance() -> void:
	# 0.1 m below the shaft but a 0.2 m margin is required → no trigger.
	assert_false(PuckInteractionRules.check_blade_under_stick(
		Vector3(0.5, 0.9, 0),
		Vector3(0, 1, 0), Vector3(1, 1, 0), 0.5, 0.2))
	# 0.3 m below clears the same margin → triggers.
	assert_true(PuckInteractionRules.check_blade_under_stick(
		Vector3(0.5, 0.7, 0),
		Vector3(0, 1, 0), Vector3(1, 1, 0), 0.5, 0.2))
