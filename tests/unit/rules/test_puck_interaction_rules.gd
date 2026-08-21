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


# ── check_body_block (analytic vertical-cylinder replacement for the Area3D) ──

const _AXIS := Vector2(0, 0)        # body cylinder axis
const _REACH: float = 0.5 + 0.065   # body radius + puck radius
const _Y_BOT: float = 0.2           # passive torso band [0.2, 1.2]
const _Y_TOP: float = 1.2


func test_body_block_hits_a_puck_into_the_torso_band() -> void:
	assert_true(PuckInteractionRules.check_body_block(
			Vector3(-1, 0.7, 0), Vector3(0, 0.7, 0), _AXIS, _REACH, _Y_BOT, _Y_TOP))


func test_body_block_grounded_puck_passes_under_raised_band() -> void:
	# A grounded puck (y≈ice) is below the raised torso band — slides under, a flat shot passes.
	assert_false(PuckInteractionRules.check_body_block(
			Vector3(-1, 0.0175, 0), Vector3(1, 0.0175, 0), _AXIS, _REACH, _Y_BOT, _Y_TOP),
			"grounded puck clears the raised passive band")


func test_body_block_uniform_reach_high_in_the_band() -> void:
	# Unlike the old sphere (which narrowed at height), the cylinder blocks with FULL reach at
	# the top of the torso band — a puck near the band edge is still stopped at the body radius.
	assert_true(PuckInteractionRules.check_body_block(
			Vector3(-1, 1.15, 0), Vector3(0, 1.15, 0), _AXIS, _REACH, _Y_BOT, _Y_TOP),
			"uniform horizontal reach across the whole band, not just the centre")


func test_body_block_swept_catches_a_fast_puck_through_the_cylinder() -> void:
	assert_true(PuckInteractionRules.check_body_block(
			Vector3(-2, 0.7, 0), Vector3(2, 0.7, 0), _AXIS, _REACH, _Y_BOT, _Y_TOP),
			"swept test catches a tunnelling puck a point test would miss")


func test_body_block_misses_a_puck_wide_of_the_body() -> void:
	assert_false(PuckInteractionRules.check_body_block(
			Vector3(5, 0.7, 0), Vector3(6, 0.7, 0), _AXIS, _REACH, _Y_BOT, _Y_TOP))


func test_body_block_misses_a_puck_over_the_top_of_the_band() -> void:
	# Horizontally aligned but above the torso band (a high shot over the shoulder).
	assert_false(PuckInteractionRules.check_body_block(
			Vector3(-1, 1.6, 0), Vector3(0, 1.6, 0), _AXIS, _REACH, _Y_BOT, _Y_TOP),
			"a puck above the band clears the body")


# ── body_block_contact_normal ────────────────────────────────────────────────


func test_body_block_normal_names_the_side_the_puck_actually_struck() -> void:
	# Puck crosses the body left-to-right, passing on the +Z side. The face it hit
	# is the +Z one, wherever the tick happened to end.
	var n: Vector3 = PuckInteractionRules.body_block_contact_normal(
			Vector3(-1.0, 0.7, 0.3), Vector3(1.0, 0.7, 0.3), _AXIS)
	assert_almost_eq(n.z, 1.0, 0.001, "normal points out the side the puck passed")
	assert_almost_eq(n.x, 0.0, 0.001)
	assert_almost_eq(n.y, 0.0, 0.001)


func test_body_block_normal_survives_a_puck_that_crossed_the_body_this_tick() -> void:
	# The bug this exists for: the puck ends the tick PAST the axis, so a normal
	# taken from its committed position names the far face and reflects it back
	# across the blocker. Read on the swept segment, the answer is unchanged by
	# how far past the puck got.
	var early: Vector3 = PuckInteractionRules.body_block_contact_normal(
			Vector3(-0.4, 0.7, 0.25), Vector3(-0.1, 0.7, 0.25), _AXIS)
	var late: Vector3 = PuckInteractionRules.body_block_contact_normal(
			Vector3(-0.4, 0.7, 0.25), Vector3(0.5, 0.7, 0.25), _AXIS)
	assert_almost_eq(late.z, 1.0, 0.001, "still the +Z face after crossing the axis")
	assert_gt(late.dot(early), 0.9, "same face as the sub-tick sample that stopped short")


func test_body_block_normal_falls_back_for_a_dead_centre_hit() -> void:
	# Straight through the axis: no side to be on, so the normal faces the puck's
	# own approach rather than picking a side out of float noise.
	var n: Vector3 = PuckInteractionRules.body_block_contact_normal(
			Vector3(-1.0, 0.7, 0.0), Vector3(1.0, 0.7, 0.0), _AXIS)
	assert_almost_eq(n.x, -1.0, 0.001, "faces back down the incoming line")


func test_body_block_normal_is_unit_and_horizontal() -> void:
	var n: Vector3 = PuckInteractionRules.body_block_contact_normal(
			Vector3(-1.0, 1.4, 0.2), Vector3(0.2, 0.3, 0.2), _AXIS)
	assert_almost_eq(n.length(), 1.0, 0.001)
	assert_eq(n.y, 0.0, "the body block is resolved in XZ")


# ── sweep_separation ─────────────────────────────────────────────────────────
# The diagnostic exposure of the quantity check_pickup / check_poke threshold on.
# A claim miss reports a bare boolean, which cannot distinguish a boundary graze
# from the host's rewind reconstructing something unrelated — that distinction is
# what makes a claim-miss RATE readable at all, so the number has to be the
# test's own rather than an endpoint approximation of it.

func test_sweep_separation_agrees_with_the_check_it_exposes() -> void:
	# The contract that matters: check_pickup passes exactly when the separation
	# is within the radius. Sweep the radius across the measured separation and
	# assert the two never disagree.
	var pp := Vector3(0, 0, 0)
	var pc := Vector3(1, 0, 0)
	var bp := Vector3(0, 0, 0.5)
	var bc := Vector3(1, 0, 0.5)
	var sep: float = PuckInteractionRules.sweep_separation(pp, pc, bp, bc)
	assert_almost_eq(sep, 0.5, 0.0001, "parallel sweeps 0.5 apart separate by 0.5")
	assert_true(PuckInteractionRules.check_pickup(pp, pc, bp, bc, sep + 0.01),
			"a radius above the separation must pass")
	assert_false(PuckInteractionRules.check_pickup(pp, pc, bp, bc, sep - 0.01),
			"a radius below the separation must fail")


func test_sweep_separation_is_zero_when_the_sweeps_cross() -> void:
	# A tunnelling contact — the case the swept test exists for. Separation 0 is
	# what distinguishes "they touched" from "they nearly touched".
	assert_almost_eq(PuckInteractionRules.sweep_separation(
			Vector3(-1, 0, 0), Vector3(1, 0, 0),
			Vector3(0, 0, -1), Vector3(0, 0, 1)), 0.0, 0.0001)


func test_sweep_separation_reports_a_gross_miss_at_its_true_scale() -> void:
	# The discriminating case: a boundary graze and a rewind failure must produce
	# very different numbers, not just "false" twice.
	var graze: float = PuckInteractionRules.sweep_separation(
			Vector3.ZERO, Vector3(1, 0, 0), Vector3(0, 0, 0.4), Vector3(1, 0, 0.4))
	var gross: float = PuckInteractionRules.sweep_separation(
			Vector3.ZERO, Vector3(1, 0, 0), Vector3(0, 0, 3.0), Vector3(1, 0, 3.0))
	assert_almost_eq(graze, 0.4, 0.0001)
	assert_almost_eq(gross, 3.0, 0.0001)
	assert_gt(gross / graze, 5.0, "the two failure kinds are orders apart, not both just 'false'")
