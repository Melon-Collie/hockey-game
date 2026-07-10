extends GutTest

# PuckReceptionRules — receive-vs-deflect decision.
#
# Reactive, RELATIVE-frame model: catch depends on the puck's speed in the
# receiver's frame (puck velocity − receiver velocity) and the blade angle at
# contact. Still no blade-velocity / cushion term — the receiver's SKATING
# velocity is a frame correction, not a stick gesture.

const PICKUP_MAX: float = 8.0
const DEFLECT_MIN: float = 22.0  # mirrors Puck.deflect_min_speed default
const ALIGN_BONUS: float = 8.0
const STILL := Vector3.ZERO  # stationary receiver — collapses to the old absolute model


func test_slow_puck_always_received() -> void:
	# Below pickup_max_speed, alignment doesn't matter.
	var puck_vel := Vector3(5, 0, 0)
	var bad_normal := Vector3(0, 0, 1)  # perpendicular to puck travel
	assert_true(PuckReceptionRules.should_receive(
		puck_vel, STILL, bad_normal, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS))


func test_quick_pass_received_at_any_angle() -> void:
	# A snap pass (14 m/s) lands on a blade angled the worst possible way
	# (perpendicular, alignment 0). 14 < threshold 22 → receive, regardless of
	# angle. Passes are not angle-gated.
	var puck_vel := Vector3(14, 0, 0)
	var perp_normal := Vector3(0, 0, 1)
	assert_true(PuckReceptionRules.should_receive(
		puck_vel, STILL, perp_normal, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS),
		"a 14 m/s pass should receive even on a perpendicular blade")


func test_bot_arrival_pace_received_at_any_angle_when_static() -> void:
	# The bot pass magnet (PASS_TARGET_CLOSING_M_S) is the puck's CLOSING speed in
	# the receiver's frame; for a stationary receiver that equals its world speed,
	# and it catches at any angle because the target sits under the any-angle
	# ceiling (deflect_min 22).
	var puck_vel := Vector3(AIActionScoring.PASS_TARGET_CLOSING_M_S, 0, 0)
	var perp_normal := Vector3(0, 0, 1)
	assert_true(PuckReceptionRules.should_receive(
		puck_vel, STILL, perp_normal, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS),
		"a magnet-pace bot feed should receive on a static receiver at any angle")
	assert_lt(AIActionScoring.PASS_TARGET_CLOSING_M_S, DEFLECT_MIN,
		"the magnet closing pace sits under the any-angle catch ceiling")


func test_hard_shot_glancing_alignment_deflected() -> void:
	# A hard shot (26 m/s) at a glancing blade (alignment 0). Threshold stays 22 →
	# 26 >= 22, deflect. Fast pucks still need a square blade.
	var puck_vel := Vector3(26, 0, 0)
	var face_normal := Vector3(0, 0, 1)
	assert_false(PuckReceptionRules.should_receive(
		puck_vel, STILL, face_normal, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS))


func test_hard_shot_dead_on_alignment_received() -> void:
	# Same 26 m/s shot, but the blade face is pointed dead-on (alignment 1.0):
	# threshold = 22 + 8 = 30 → 26 < 30, a clean square reception of a hard shot.
	var puck_vel := Vector3(26, 0, 0)
	var face_normal := Vector3(-1, 0, 0)
	assert_true(PuckReceptionRules.should_receive(
		puck_vel, STILL, face_normal, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS))


func test_hard_slapshot_at_square_blade_still_deflects() -> void:
	# 34 m/s slapshot, face pointed dead-on. Even with the full alignment bonus
	# the threshold is 30 m/s — 34 > 30, deflect. Guards against the change
	# making everything sticky: a rocket can't be corralled, square or not.
	var puck_vel := Vector3(34, 0, 0)
	var face_normal := Vector3(-1, 0, 0)
	assert_false(PuckReceptionRules.should_receive(
		puck_vel, STILL, face_normal, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS))


func test_partial_alignment_scales_threshold() -> void:
	# Blade ~45° to the incoming puck → alignment ≈ 0.707, threshold ≈ 27.7.
	# A 26 m/s puck catches (26 < 27.7); a 29 m/s puck deflects (29 > 27.7).
	var face_normal := Vector3(-1, 0, 1).normalized()  # 45° off the -X incoming line
	assert_true(PuckReceptionRules.should_receive(
		Vector3(26, 0, 0), STILL, face_normal, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS))
	assert_false(PuckReceptionRules.should_receive(
		Vector3(29, 0, 0), STILL, face_normal, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS))


func test_zero_alignment_bonus_is_flat_speed_gate() -> void:
	# With alignment_bonus = 0, behavior collapses to a flat relative-speed check
	# at deflect_min_speed regardless of angle.
	var face_normal := Vector3(-1, 0, 0)
	assert_false(PuckReceptionRules.should_receive(
		Vector3(24, 0, 0), STILL, face_normal, PICKUP_MAX, DEFLECT_MIN, 0.0),
		"24 m/s puck with no alignment bonus should deflect at threshold 22")
	assert_true(PuckReceptionRules.should_receive(
		Vector3(20, 0, 0), STILL, face_normal, PICKUP_MAX, DEFLECT_MIN, 0.0),
		"20 m/s puck under baseline threshold should still receive")


# ── Relative frame — the receiver's own velocity shifts the read ─────────────

func test_stretch_pass_to_streaking_receiver_received() -> void:
	# The headline case: a hard 24 m/s stretch pass would deflect off a static
	# perpendicular blade (24 > 22), but the receiver is streaking WITH the pass
	# at 8 m/s — in their frame it arrives at 16 m/s. Easy catch at any angle.
	var puck_vel := Vector3(24, 0, 0)
	var receiver_vel := Vector3(8, 0, 0)
	var perp_normal := Vector3(0, 0, 1)
	assert_false(PuckReceptionRules.should_receive(
		puck_vel, STILL, perp_normal, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS),
		"the same pass deflects off a static badly-angled blade")
	assert_true(PuckReceptionRules.should_receive(
		puck_vel, receiver_vel, perp_normal, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS),
		"a streaking receiver sees the stretch pass arrive soft")


func test_closing_hard_on_a_feed_steepens_it() -> void:
	# A 20 m/s feed a static receiver catches at any angle (20 < 22) becomes a
	# 30.6 m/s contact for a receiver sprinting head-on into it — above even the
	# fully-squared ceiling (30) → bobble/deflect. Don't charge the pass.
	var puck_vel := Vector3(20, 0, 0)
	var sprint_at_pass := Vector3(-10.6, 0, 0)
	var square_normal := Vector3(-1, 0, 0)
	assert_true(PuckReceptionRules.should_receive(
		puck_vel, STILL, square_normal, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS))
	assert_false(PuckReceptionRules.should_receive(
		puck_vel, sprint_at_pass, square_normal, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS),
		"sprinting head-on into a hard feed pushes past the squared ceiling")


func test_retreating_with_a_wrister_cushions_it() -> void:
	# Emergent "give with the puck": a max wrister (33 m/s) deflects off a static
	# squared blade (33 > 30), but a receiver skating backward with it at 4 m/s
	# reads it at 29 — squared, that's a catch. Cushioning is a skating read.
	var puck_vel := Vector3(33, 0, 0)
	var retreat := Vector3(4, 0, 0)
	var square_normal := Vector3(-1, 0, 0)
	assert_false(PuckReceptionRules.should_receive(
		puck_vel, STILL, square_normal, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS),
		"a max wrister into a static squared blade still deflects")
	assert_true(PuckReceptionRules.should_receive(
		puck_vel, retreat, square_normal, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS),
		"retreating with the shot cushions it under the squared ceiling")


func test_skating_onto_a_dying_pass_is_instant_pickup() -> void:
	# Receiver overtaking a slow puck from behind: relative speed is the
	# difference (|9 − 5| = 4 ≤ pickup_max) → unconditional pickup, any angle.
	var puck_vel := Vector3(5, 0, 0)
	var receiver_vel := Vector3(9, 0, 0)
	var perp_normal := Vector3(0, 0, 1)
	assert_true(PuckReceptionRules.should_receive(
		puck_vel, receiver_vel, perp_normal, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS))


func test_alignment_is_judged_in_the_receiver_frame() -> void:
	# A lateral receiver changes the approach LINE, not just the speed. Puck
	# flies +X at 26; receiver strafes 14 m/s along -Z, so in their frame it
	# approaches along (26, 0, 14) at ≈29.5 m/s. A blade squared to the WORLD
	# line (-X face) reads alignment 26/29.5 ≈ 0.88 → threshold ≈29.0 < 29.5 →
	# deflect; squaring to the RELATIVE line (alignment 1.0 → threshold 30)
	# restores the catch. Squareness must track the relative approach.
	var puck_vel := Vector3(26, 0, 0)
	var world_square := Vector3(-1, 0, 0)
	var strafe_fast := Vector3(0, 0, -14)
	assert_false(PuckReceptionRules.should_receive(
		puck_vel, strafe_fast, world_square, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS),
		"a hard strafe steepens the relative line past a world-squared blade")
	var rel := puck_vel - strafe_fast
	var rel_square: Vector3 = -rel.normalized()
	assert_true(PuckReceptionRules.should_receive(
		puck_vel, strafe_fast, rel_square, PICKUP_MAX, DEFLECT_MIN, ALIGN_BONUS),
		"squaring to the relative approach line restores the catch")


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
	# tip-vs-catch restriction is enforced at the call site, not here). A deflect
	# at HIGH sets blade_up, so this is also the HIGH-deflect (knock-down) reach;
	# FLAT/LOW deflects keep blade_up false and play the ice through the grounded
	# cases above.
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
