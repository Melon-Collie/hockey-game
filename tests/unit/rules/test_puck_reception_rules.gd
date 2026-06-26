extends GutTest

# PuckReceptionRules — receive-vs-deflect decision.

const PICKUP_MAX: float = 8.0
const DEFLECT_MIN: float = 14.0
const ALIGN_BONUS: float = 8.0

func test_slow_puck_always_received() -> void:
	# Below pickup_max_speed, alignment and blade velocity don't matter.
	var puck_vel := Vector3(5, 0, 0)
	var blade_vel := Vector3.ZERO
	var bad_normal := Vector3(0, 0, 1)  # perpendicular to puck travel
	assert_true(PuckReceptionRules.should_receive(
		puck_vel, blade_vel, bad_normal, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS))

func test_fast_puck_dead_on_alignment_received() -> void:
	# Puck moving +X at 20 m/s, blade face pointed back at puck (-X).
	# rel_speed = 20, alignment = 1.0, threshold = 14 + 8 = 22 → 20 < 22, receive.
	var puck_vel := Vector3(20, 0, 0)
	var blade_vel := Vector3.ZERO
	var face_normal := Vector3(-1, 0, 0)
	assert_true(PuckReceptionRules.should_receive(
		puck_vel, blade_vel, face_normal, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS))

func test_fast_puck_glancing_alignment_deflected() -> void:
	# Same puck speed, but blade face perpendicular to puck travel (alignment 0).
	# Threshold stays at 14 → 20 >= 14, deflect.
	var puck_vel := Vector3(20, 0, 0)
	var blade_vel := Vector3.ZERO
	var face_normal := Vector3(0, 0, 1)
	assert_false(PuckReceptionRules.should_receive(
		puck_vel, blade_vel, face_normal, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS))

func test_cushion_lets_fast_puck_be_received() -> void:
	# Puck and blade both moving +X at 20 and 10 m/s — relative speed is 10,
	# well under the 14 m/s threshold, so the puck is received regardless of
	# alignment.
	var puck_vel := Vector3(20, 0, 0)
	var blade_vel := Vector3(10, 0, 0)
	var bad_normal := Vector3(0, 0, 1)
	assert_true(PuckReceptionRules.should_receive(
		puck_vel, blade_vel, bad_normal, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS))

func test_hard_shot_at_unaware_blade_still_deflects() -> void:
	# 30 m/s puck, blade stationary, face pointed dead-on. Even with the full
	# alignment bonus the threshold is 22 m/s — 30 > 22, deflect. Guards
	# against the change making everything sticky.
	var puck_vel := Vector3(30, 0, 0)
	var blade_vel := Vector3.ZERO
	var face_normal := Vector3(-1, 0, 0)
	assert_false(PuckReceptionRules.should_receive(
		puck_vel, blade_vel, face_normal, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS))

func test_blade_swinging_away_no_alignment_bonus() -> void:
	# Blade moving away from puck (+X) faster than puck (+X slow) → puck moves
	# away from blade in rel frame. alignment clamps to 0, threshold stays 14.
	var puck_vel := Vector3(5, 0, 0)
	var blade_vel := Vector3(-10, 0, 0)  # blade going -X, puck going +X
	# rel_vel = puck - blade = (15, 0, 0); puck_speed = 5 (under pickup_max)
	# So this short-circuits to received. Use a faster puck to exercise the
	# alignment path:
	puck_vel = Vector3(20, 0, 0)
	# rel_vel = (30, 0, 0), rel_speed = 30, way over any threshold → deflect.
	var face_normal := Vector3(-1, 0, 0)
	assert_false(PuckReceptionRules.should_receive(
		puck_vel, blade_vel, face_normal, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS))

func test_zero_alignment_bonus_matches_baseline_behavior() -> void:
	# With alignment_bonus = 0, behavior collapses to the old rel_speed check.
	var puck_vel := Vector3(15, 0, 0)
	var blade_vel := Vector3.ZERO
	var face_normal := Vector3(-1, 0, 0)
	assert_false(PuckReceptionRules.should_receive(
		puck_vel, blade_vel, face_normal, PICKUP_MAX, DEFLECT_MIN, 0.0),
		"15 m/s puck with no alignment bonus should deflect at threshold 14")
	puck_vel = Vector3(13, 0, 0)
	assert_true(PuckReceptionRules.should_receive(
		puck_vel, blade_vel, face_normal, PICKUP_MAX, DEFLECT_MIN, 0.0),
		"13 m/s puck under baseline threshold should still receive")


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
