extends GutTest

# PuckReceptionRules — receive-vs-deflect decision.
#
# Reactive model: catch depends only on the puck's absolute speed and the blade
# angle at contact. No blade-velocity / cushion term.

const PICKUP_MAX: float = 8.0
const DEFLECT_MIN: float = 20.0  # mirrors Puck.deflect_min_speed default
const ALIGN_BONUS: float = 8.0

func test_slow_puck_always_received() -> void:
	# Below pickup_max_speed, alignment doesn't matter.
	var puck_vel := Vector3(5, 0, 0)
	var bad_normal := Vector3(0, 0, 1)  # perpendicular to puck travel
	assert_true(PuckReceptionRules.should_receive(
		puck_vel, bad_normal, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS))

func test_quick_pass_received_at_any_angle() -> void:
	# The core fix: a snap pass (14 m/s) lands on a blade angled the worst possible
	# way (perpendicular, alignment 0). 14 < threshold 20 → receive, regardless of
	# angle. Passes are no longer angle-gated.
	var puck_vel := Vector3(14, 0, 0)
	var perp_normal := Vector3(0, 0, 1)
	assert_true(PuckReceptionRules.should_receive(
		puck_vel, perp_normal, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS),
		"a 14 m/s pass should receive even on a perpendicular blade")

func test_charged_pass_received_at_any_angle() -> void:
	# A charged "rocket" pass (19 m/s) also catches at any angle — 19 < 20.
	var puck_vel := Vector3(19, 0, 0)
	var perp_normal := Vector3(0, 0, 1)
	assert_true(PuckReceptionRules.should_receive(
		puck_vel, perp_normal, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS),
		"a 19 m/s charged pass should receive even on a perpendicular blade")

func test_hard_shot_glancing_alignment_deflected() -> void:
	# A hard shot (26 m/s) at a glancing blade (alignment 0). Threshold stays 20 →
	# 26 >= 20, deflect. Fast pucks still need a square blade.
	var puck_vel := Vector3(26, 0, 0)
	var face_normal := Vector3(0, 0, 1)
	assert_false(PuckReceptionRules.should_receive(
		puck_vel, face_normal, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS))

func test_hard_shot_dead_on_alignment_received() -> void:
	# Same 26 m/s shot, but the blade face is pointed dead-on (alignment 1.0):
	# threshold = 20 + 8 = 28 → 26 < 28, a clean square reception of a hard shot.
	var puck_vel := Vector3(26, 0, 0)
	var face_normal := Vector3(-1, 0, 0)
	assert_true(PuckReceptionRules.should_receive(
		puck_vel, face_normal, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS))

func test_hard_slapshot_at_square_blade_still_deflects() -> void:
	# 34 m/s slapshot, face pointed dead-on. Even with the full alignment bonus the
	# threshold is 28 m/s — 34 > 28, deflect. Guards against the change making
	# everything sticky: a rocket can't be corralled, square or not.
	var puck_vel := Vector3(34, 0, 0)
	var face_normal := Vector3(-1, 0, 0)
	assert_false(PuckReceptionRules.should_receive(
		puck_vel, face_normal, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS))

func test_partial_alignment_scales_threshold() -> void:
	# Blade ~45° to the incoming puck → alignment ≈ 0.707, threshold ≈ 25.7.
	# A 24 m/s puck catches (24 < 25.7); a 27 m/s puck deflects (27 > 25.7).
	var face_normal := Vector3(-1, 0, 1).normalized()  # 45° off the -X incoming line
	assert_true(PuckReceptionRules.should_receive(
		Vector3(24, 0, 0), face_normal, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS))
	assert_false(PuckReceptionRules.should_receive(
		Vector3(27, 0, 0), face_normal, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS))

func test_zero_alignment_bonus_is_flat_speed_gate() -> void:
	# With alignment_bonus = 0, behavior collapses to a flat speed check at
	# deflect_min_speed regardless of angle.
	var face_normal := Vector3(-1, 0, 0)
	assert_false(PuckReceptionRules.should_receive(
		Vector3(22, 0, 0), face_normal, PICKUP_MAX, DEFLECT_MIN, 0.0),
		"22 m/s puck with no alignment bonus should deflect at threshold 20")
	assert_true(PuckReceptionRules.should_receive(
		Vector3(18, 0, 0), face_normal, PICKUP_MAX, DEFLECT_MIN, 0.0),
		"18 m/s puck under baseline threshold should still receive")


# ── blade_can_interact — on-ice/off-ice gate ─────────────────────────────────

func test_grounded_blade_interacts_with_grounded_puck() -> void:
	assert_true(PuckReceptionRules.blade_can_interact(false, false))

func test_grounded_blade_ignores_airborne_puck() -> void:
	# The saucer-pass change: a stationary grounded blade lets an airborne puck
	# fly over instead of corralling it.
	assert_false(PuckReceptionRules.blade_can_interact(false, true))

func test_lifted_blade_ignores_grounded_puck() -> void:
	assert_false(PuckReceptionRules.blade_can_interact(true, false))

func test_lifted_blade_interacts_with_airborne_puck() -> void:
	# Lifted blade only reaches airborne pucks (and may only tip them — the
	# tip-vs-catch restriction is enforced at the call site, not here).
	assert_true(PuckReceptionRules.blade_can_interact(true, true))


# ── deflect_can_reach — per-level committed-deflect reach ─────────────────────

func test_flat_deflect_reaches_grounded_only() -> void:
	# FLAT (0): blade on the ice — grounded pucks only; a saucer flies over.
	assert_true(PuckReceptionRules.deflect_can_reach(0, false), "FLAT reaches grounded")
	assert_false(PuckReceptionRules.deflect_can_reach(0, true), "FLAT ignores airborne")

func test_low_deflect_reaches_both() -> void:
	# LOW (1): the straddle level — tips a grounded shot up OR pops a low saucer.
	assert_true(PuckReceptionRules.deflect_can_reach(1, false), "LOW reaches grounded")
	assert_true(PuckReceptionRules.deflect_can_reach(1, true), "LOW reaches airborne")

func test_high_deflect_reaches_airborne_only() -> void:
	# HIGH (2): blade lifted — knocks airborne pucks down; a grounded puck passes
	# under the raised blade.
	assert_false(PuckReceptionRules.deflect_can_reach(2, false), "HIGH ignores grounded")
	assert_true(PuckReceptionRules.deflect_can_reach(2, true), "HIGH reaches airborne")


# ── blade_face_normal ────────────────────────────────────────────────────────

func test_blade_face_normal_opposes_incoming_puck() -> void:
	# Shaft runs hand(origin) → blade(+X). The face perpendicular to it that
	# opposes a +Z-moving puck is -Z.
	var n: Vector3 = PuckReceptionRules.blade_face_normal(
		Vector3(1, 0, 0), Vector3.ZERO, Vector3(0, 0, 5), Vector3(1, 0, 0))
	assert_almost_eq(n, Vector3(0, 0, -1), Vector3(0.001, 0.001, 0.001))

func test_blade_face_normal_is_horizontal_unit() -> void:
	var n: Vector3 = PuckReceptionRules.blade_face_normal(
		Vector3(2, 0.5, 1), Vector3(0, 0.3, 0), Vector3(-1, 0, -1), Vector3(1, 0, 0))
	assert_almost_eq(n.length(), 1.0, 0.001, "result is a unit vector")
	assert_almost_eq(n.y, 0.0, 0.001, "result is horizontal")

func test_blade_face_normal_falls_back_when_shaft_degenerate() -> void:
	# Hand and blade coincident → use the fallback shaft direction (+X here), so
	# the face is along ±Z; the +Z reference flips it to -Z.
	var n: Vector3 = PuckReceptionRules.blade_face_normal(
		Vector3.ZERO, Vector3.ZERO, Vector3(0, 0, 1), Vector3(1, 0, 0))
	assert_almost_eq(n, Vector3(0, 0, -1), Vector3(0.001, 0.001, 0.001))
