extends GutTest

# PuckReceptionRules — receive-vs-deflect decision.

const PICKUP_MAX: float = 8.0
const DEFLECT_MIN: float = 20.0  # mirrors Puck.deflect_min_speed default
const ALIGN_BONUS: float = 8.0

func test_slow_puck_always_received() -> void:
	# Below pickup_max_speed, alignment and blade velocity don't matter.
	var puck_vel := Vector3(5, 0, 0)
	var blade_vel := Vector3.ZERO
	var bad_normal := Vector3(0, 0, 1)  # perpendicular to puck travel
	assert_true(PuckReceptionRules.should_receive(
		puck_vel, blade_vel, bad_normal, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS))

func test_quick_pass_received_at_any_angle() -> void:
	# The core fix: a snap pass (14 m/s) lands on a blade angled the worst possible
	# way (perpendicular, alignment 0). closing = 14 < threshold 20 → receive,
	# regardless of angle. Passes are no longer angle-gated.
	var puck_vel := Vector3(14, 0, 0)
	var blade_vel := Vector3.ZERO
	var perp_normal := Vector3(0, 0, 1)
	assert_true(PuckReceptionRules.should_receive(
		puck_vel, blade_vel, perp_normal, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS),
		"a 14 m/s pass should receive even on a perpendicular blade")

func test_charged_pass_received_at_any_angle() -> void:
	# A charged "rocket" pass (19 m/s) also catches at any angle — closing 19 < 20.
	var puck_vel := Vector3(19, 0, 0)
	var blade_vel := Vector3.ZERO
	var perp_normal := Vector3(0, 0, 1)
	assert_true(PuckReceptionRules.should_receive(
		puck_vel, blade_vel, perp_normal, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS),
		"a 19 m/s charged pass should receive even on a perpendicular blade")

func test_blade_meeting_puck_is_not_penalized() -> void:
	# A skater skating INTO an incoming pass (blade closing on the puck) used to
	# inflate rel_speed and fumble a catchable pass. Now closing speed is capped at
	# the puck's own speed, so meeting a 19 m/s pass is no harder than a static
	# blade: closing = min(rel 29, puck 19) = 19 < 20 → receive.
	var puck_vel := Vector3(19, 0, 0)
	var blade_vel := Vector3(-10, 0, 0)  # blade going -X into a +X puck
	var face_normal := Vector3(-1, 0, 0)
	assert_true(PuckReceptionRules.should_receive(
		puck_vel, blade_vel, face_normal, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS),
		"skating to meet a pass must not make it harder to catch")

func test_hard_shot_glancing_alignment_deflected() -> void:
	# A hard shot (26 m/s) at a glancing blade (alignment 0). Threshold stays 20 →
	# 26 >= 20, deflect. Fast pucks still need a square blade or a cushion.
	var puck_vel := Vector3(26, 0, 0)
	var blade_vel := Vector3.ZERO
	var face_normal := Vector3(0, 0, 1)
	assert_false(PuckReceptionRules.should_receive(
		puck_vel, blade_vel, face_normal, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS))

func test_hard_shot_dead_on_alignment_received() -> void:
	# Same 26 m/s shot, but the blade face is pointed dead-on (alignment 1.0):
	# threshold = 20 + 8 = 28 → 26 < 28, a clean square reception of a hard shot.
	var puck_vel := Vector3(26, 0, 0)
	var blade_vel := Vector3.ZERO
	var face_normal := Vector3(-1, 0, 0)
	assert_true(PuckReceptionRules.should_receive(
		puck_vel, blade_vel, face_normal, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS))

func test_cushion_lets_fast_puck_be_received() -> void:
	# Puck and blade both moving +X at 30 and 12 m/s — relative (closing) speed is
	# 18, under the 20 m/s threshold, so a hard shot is absorbed by drawing the
	# blade back with it regardless of face alignment.
	var puck_vel := Vector3(30, 0, 0)
	var blade_vel := Vector3(12, 0, 0)
	var bad_normal := Vector3(0, 0, 1)
	assert_true(PuckReceptionRules.should_receive(
		puck_vel, blade_vel, bad_normal, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS))

func test_hard_slapshot_at_unaware_blade_still_deflects() -> void:
	# 34 m/s slapshot, blade stationary, face pointed dead-on. Even with the full
	# alignment bonus the threshold is 28 m/s — 34 > 28, deflect. Guards against
	# the change making everything sticky: a rocket still needs a cushion.
	var puck_vel := Vector3(34, 0, 0)
	var blade_vel := Vector3.ZERO
	var face_normal := Vector3(-1, 0, 0)
	assert_false(PuckReceptionRules.should_receive(
		puck_vel, blade_vel, face_normal, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS))

func test_zero_alignment_bonus_matches_baseline_behavior() -> void:
	# With alignment_bonus = 0, behavior collapses to a flat closing-speed check
	# at deflect_min_speed.
	var puck_vel := Vector3(22, 0, 0)
	var blade_vel := Vector3.ZERO
	var face_normal := Vector3(-1, 0, 0)
	assert_false(PuckReceptionRules.should_receive(
		puck_vel, blade_vel, face_normal, PICKUP_MAX, DEFLECT_MIN, 0.0),
		"22 m/s puck with no alignment bonus should deflect at threshold 20")
	puck_vel = Vector3(18, 0, 0)
	assert_true(PuckReceptionRules.should_receive(
		puck_vel, blade_vel, face_normal, PICKUP_MAX, DEFLECT_MIN, 0.0),
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
