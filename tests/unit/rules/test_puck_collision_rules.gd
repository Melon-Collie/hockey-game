extends GutTest

# PuckCollisionRules — pure physics math for puck interactions.

# ── can_poke_check ───────────────────────────────────────────────────────────

func test_same_team_cannot_poke() -> void:
	assert_false(PuckCollisionRules.can_poke_check(0, 0))
	assert_false(PuckCollisionRules.can_poke_check(1, 1))

func test_opponents_can_poke() -> void:
	assert_true(PuckCollisionRules.can_poke_check(0, 1))
	assert_true(PuckCollisionRules.can_poke_check(1, 0))

# ── deflect_velocity ─────────────────────────────────────────────────────────

func test_full_blend_reflects_velocity() -> void:
	# Puck moving +X, contact normal -X (blade face toward -X, puck bounces back)
	var velocity := Vector3(10, 0, 0)
	var normal := Vector3(-1, 0, 0)
	var result: Vector3 = PuckCollisionRules.deflect_velocity(velocity, normal, 1.0, 1.0)
	assert_lt(result.x, 0.0, "deflected velocity X should flip sign")
	assert_almost_eq(result.length(), 10.0, 0.01)

func test_zero_blend_preserves_direction() -> void:
	# With deflect_blend=0 the result is along the incoming direction
	var velocity := Vector3(10, 0, 0)
	var normal := Vector3(-1, 0, 0)
	var result: Vector3 = PuckCollisionRules.deflect_velocity(velocity, normal, 0.0, 1.0)
	assert_gt(result.x, 0.0, "zero blend should keep moving in incoming direction")

func test_speed_retain_scales_magnitude() -> void:
	var velocity := Vector3(10, 0, 0)
	var normal := Vector3(-1, 0, 0)
	var result: Vector3 = PuckCollisionRules.deflect_velocity(velocity, normal, 1.0, 0.5)
	assert_almost_eq(result.length(), 5.0, 0.01)

func test_max_angle_clamps_wild_deflection() -> void:
	# Puck moving +X, blade normal at 45° fully reflects it to a 90° turn (toward
	# -Z). A flat 45° cap must pull that back to a 45° turn off the incoming line.
	# Args: blend, retain, retain_min(-1=off), max_deg, max_deg_min(-1=off), ref.
	var velocity := Vector3(10, 0, 0)
	var normal := Vector3(-1, 0, -1).normalized()
	var clamped: Vector3 = PuckCollisionRules.deflect_velocity(velocity, normal, 1.0, 1.0, -1.0, 45.0)
	var turn_deg: float = rad_to_deg(Vector3(1, 0, 0).angle_to(clamped.normalized()))
	assert_almost_eq(turn_deg, 45.0, 0.5, "turn should be clamped to the 45° cap")
	assert_almost_eq(clamped.length(), 10.0, 0.01, "clamping direction must not change speed")

func test_head_on_full_reflection_degenerates_to_passthrough() -> void:
	# Exactly antiparallel reflection (head-on, blend 1.0) has no defined rotation
	# axis for the clamp; the safe fallback is to keep the incoming direction
	# rather than pick an arbitrary side. (Real contact normals are angled, so
	# this only guards the math edge.)
	var result: Vector3 = PuckCollisionRules.deflect_velocity(
		Vector3(10, 0, 0), Vector3(-1, 0, 0), 1.0, 1.0, -1.0, 90.0)
	assert_gt(result.x, 0.0, "degenerate clamp keeps incoming direction")

func test_max_angle_180_leaves_direction_unclamped() -> void:
	var velocity := Vector3(10, 0, 0)
	var normal := Vector3(-1, 0, 0)
	var capped: Vector3 = PuckCollisionRules.deflect_velocity(velocity, normal, 1.0, 1.0, -1.0, 180.0)
	var uncapped: Vector3 = PuckCollisionRules.deflect_velocity(velocity, normal, 1.0, 1.0)
	assert_almost_eq(capped.x, uncapped.x, 0.01, "180° cap is a no-op")

func test_speed_dependent_angle_shallower_for_fast_pucks() -> void:
	# Blade normal at 45° fully reflects +X to a 90° turn. With the cap easing from
	# 80° (soft) to 20° (hard) over ref=20, a slow puck keeps a sharp redirect
	# while a fast one only glances. Args: blend, retain, retain_min, max_deg,
	# max_deg_min, ref.
	var normal := Vector3(-1, 0, -1).normalized()
	var slow: Vector3 = PuckCollisionRules.deflect_velocity(
		Vector3(5, 0, 0), normal, 1.0, 1.0, -1.0, 80.0, 20.0, 20.0)
	var fast: Vector3 = PuckCollisionRules.deflect_velocity(
		Vector3(20, 0, 0), normal, 1.0, 1.0, -1.0, 80.0, 20.0, 20.0)
	var slow_turn: float = rad_to_deg(Vector3(1, 0, 0).angle_to(slow.normalized()))
	var fast_turn: float = rad_to_deg(Vector3(1, 0, 0).angle_to(fast.normalized()))
	assert_almost_eq(slow_turn, 65.0, 0.5, "5/20 hardness=0.25 → cap lerps 80→20 to 65°")
	assert_almost_eq(fast_turn, 20.0, 0.5, "at ref speed the cap bottoms out at 20°")
	assert_lt(fast_turn, slow_turn, "fast pucks redirect less than slow ones")

func test_speed_dependent_retain_bleeds_fast_pucks() -> void:
	var normal := Vector3(-1, 0, 0)
	# ref=20, retain=0.7 at/below ref, retain_min=0.5 at/above ref.
	# Slow puck (10 m/s, half the ref) keeps more than a fast one (20 m/s).
	var slow: Vector3 = PuckCollisionRules.deflect_velocity(
		Vector3(10, 0, 0), normal, 1.0, 0.7, 0.5, 180.0, -1.0, 20.0)
	var fast: Vector3 = PuckCollisionRules.deflect_velocity(
		Vector3(20, 0, 0), normal, 1.0, 0.7, 0.5, 180.0, -1.0, 20.0)
	assert_almost_eq(slow.length(), 10.0 * 0.6, 0.05, "10/20 ratio → retain lerps to 0.6")
	assert_almost_eq(fast.length(), 20.0 * 0.5, 0.05, "at the ref speed retain bottoms out at 0.5")

func test_speed_retain_falloff_disabled_when_min_negative() -> void:
	var result: Vector3 = PuckCollisionRules.deflect_velocity(
		Vector3(30, 0, 0), Vector3(-1, 0, 0), 1.0, 0.7, -1.0, 180.0, -1.0, 20.0)
	assert_almost_eq(result.length(), 30.0 * 0.7, 0.01, "negative min keeps flat retention")

# ── apply_deflection_elevation ───────────────────────────────────────────────

func test_elevation_adds_y_component() -> void:
	var horiz := Vector3(1, 0, 0)
	var elevated: Vector3 = PuckCollisionRules.apply_deflection_elevation(horiz, 35.0)
	assert_gt(elevated.y, 0.0)
	assert_almost_eq(elevated.length(), 1.0, 0.01, "result should still be unit length")

func test_zero_elevation_no_y_component() -> void:
	var horiz := Vector3(1, 0, 0)
	var flat: Vector3 = PuckCollisionRules.apply_deflection_elevation(horiz, 0.0)
	assert_almost_eq(flat.y, 0.0, 0.01)

# ── body_block_velocity ──────────────────────────────────────────────────────

func test_body_block_reflects_and_dampens() -> void:
	var velocity := Vector3(10, 0, 0)
	var normal := Vector3(-1, 0, 0)
	var result: Vector3 = PuckCollisionRules.body_block_velocity(velocity, normal, 0.5)
	assert_lt(result.x, 0.0, "reflected X should flip")
	assert_almost_eq(result.length(), 5.0, 0.01, "dampen halves speed")

func test_body_block_falls_back_to_normal_when_reflection_zero() -> void:
	# Zero velocity → reflected is also zero → fallback to contact normal
	var velocity := Vector3.ZERO
	var normal := Vector3(0, 0, 1)
	var result: Vector3 = PuckCollisionRules.body_block_velocity(velocity, normal, 1.0)
	# result.length() is horiz_vel.length() * dampen = 0 — but direction is normal
	assert_almost_eq(result.length(), 0.0, 0.01,
		"no input energy means no output energy; fallback only sets direction")

# ── body_check_strip_velocity ────────────────────────────────────────────────

func test_body_check_strip_scales_direction() -> void:
	var dir := Vector3(1, 0, 0)
	var result: Vector3 = PuckCollisionRules.body_check_strip_velocity(dir, 5.0)
	assert_eq(result, Vector3(5, 0, 0))

# ── poke_strip_velocity ──────────────────────────────────────────────────────

# Signature: (checker_vel, carrier_vel, carrier_pos, checker_pos, blend,
# min_speed, max_speed, fallback). Exit SPEED now scales with the blended contest
# momentum, clamped to [min_speed, max_speed]; a still checker floors at min.

func test_poke_blends_checker_and_carrier_momentum() -> void:
	# Checker moving fast in +X, carrier slightly in +Z. Blended = (5,0,1),
	# length ~5.10 → in [3,9], so the exit speed is the momentum magnitude itself.
	var result: Vector3 = PuckCollisionRules.poke_strip_velocity(
		Vector3(5, 0, 0),          # checker_blade_vel
		Vector3(0, 0, 2),          # carrier_blade_vel
		Vector3.ZERO,              # carrier_pos (unused when checker vel dominates)
		Vector3.ZERO,              # checker_pos
		0.5,                       # blend → adds (0,0,1)
		3.0, 9.0,                  # min / max speed
		Vector3(1, 0, 0))          # fallback unused
	assert_almost_eq(result.length(), sqrt(26.0), 0.01, "speed = blended momentum magnitude")
	assert_gt(result.x, 0.0, "should move along checker's +X")
	assert_gt(result.z, 0.0, "should pick up some of carrier's +Z")

func test_poke_speed_scales_with_contest_momentum() -> void:
	# A harder poke (faster blade sweep) sends the puck faster — the whole point.
	var soft: Vector3 = PuckCollisionRules.poke_strip_velocity(
		Vector3(4, 0, 0), Vector3.ZERO, Vector3.ZERO, Vector3.ZERO,
		0.5, 3.0, 9.0, Vector3(1, 0, 0))
	var hard: Vector3 = PuckCollisionRules.poke_strip_velocity(
		Vector3(8, 0, 0), Vector3.ZERO, Vector3.ZERO, Vector3.ZERO,
		0.5, 3.0, 9.0, Vector3(1, 0, 0))
	assert_almost_eq(soft.length(), 4.0, 0.01, "moderate poke → its own momentum")
	assert_almost_eq(hard.length(), 8.0, 0.01, "hard poke → faster exit")
	assert_gt(hard.length(), soft.length(), "harder poke squirts the puck faster")

func test_poke_clamps_speed_to_min_and_max() -> void:
	# Weak sweep floors at min_speed; overpowered sweep caps at max_speed.
	var weak: Vector3 = PuckCollisionRules.poke_strip_velocity(
		Vector3(1, 0, 0), Vector3.ZERO, Vector3.ZERO, Vector3.ZERO,
		0.5, 3.0, 9.0, Vector3(1, 0, 0))
	var huge: Vector3 = PuckCollisionRules.poke_strip_velocity(
		Vector3(20, 0, 0), Vector3.ZERO, Vector3.ZERO, Vector3.ZERO,
		0.5, 3.0, 9.0, Vector3(1, 0, 0))
	assert_almost_eq(weak.length(), 3.0, 0.01, "weak poke clamps up to min_speed")
	assert_almost_eq(huge.length(), 9.0, 0.01, "huge sweep clamps down to max_speed")

func test_poke_uses_position_delta_at_min_speed_when_checker_still() -> void:
	# Checker blade not moving — positional strip: push away at min_speed.
	var result: Vector3 = PuckCollisionRules.poke_strip_velocity(
		Vector3.ZERO,              # checker not moving
		Vector3.ZERO,              # carrier not moving
		Vector3(3, 0, 0),          # carrier at +X
		Vector3(0, 0, 0),          # checker at origin
		0.5,
		3.0, 9.0,
		Vector3(1, 0, 0))
	assert_almost_eq(result.length(), 3.0, 0.01, "positional strip uses min_speed")
	assert_gt(result.x, 0.0, "push puck away from checker (+X)")

func test_poke_uses_fallback_when_everything_is_zero() -> void:
	# Nothing moving, same positions — fall back to provided direction at min_speed.
	var fallback := Vector3(0, 0, 1)
	var result: Vector3 = PuckCollisionRules.poke_strip_velocity(
		Vector3.ZERO, Vector3.ZERO,
		Vector3.ZERO, Vector3.ZERO,
		0.5, 3.0, 9.0, fallback)
	assert_almost_eq(result.length(), 3.0, 0.01, "fallback strip uses min_speed")
	assert_gt(result.z, 0.0, "should use fallback direction (+Z)")


# ── contested_pickup_velocity ────────────────────────────────────────────────
# Two blades on the same loose puck. Never awards possession — always squirts —
# but biased toward the stronger blade (vector sum of blade momenta); a true
# deadlock pops perpendicular. Args: (a_vel, b_vel, a_pos, b_pos, min, max,
# deadlock_speed, deadlock_threshold, perp_sign, fallback_dir).

func test_contested_biases_toward_stronger_blade() -> void:
	# A sweeps hard +X, B drifts gently +Z → net (6,0,1): puck goes mostly A's way.
	var result: Vector3 = PuckCollisionRules.contested_pickup_velocity(
		Vector3(6, 0, 0), Vector3(0, 0, 1),
		Vector3(0, 0, 1), Vector3(0, 0, -1),
		3.0, 9.0, 3.0, 0.5, 1.0, Vector3(1, 0, 0))
	assert_gt(result.x, 0.0, "goes toward the stronger blade's push (+X)")
	assert_gt(result.x, absf(result.z), "stronger blade dominates the heading")
	assert_almost_eq(result.length(), sqrt(37.0), 0.01, "speed = combined momentum magnitude")

func test_contested_speed_scales_and_clamps() -> void:
	var hard: Vector3 = PuckCollisionRules.contested_pickup_velocity(
		Vector3(10, 0, 0), Vector3(5, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1),
		3.0, 9.0, 3.0, 0.5, 1.0, Vector3(1, 0, 0))
	var moderate: Vector3 = PuckCollisionRules.contested_pickup_velocity(
		Vector3(4, 0, 0), Vector3.ZERO, Vector3(0, 0, 1), Vector3(0, 0, -1),
		3.0, 9.0, 3.0, 0.5, 1.0, Vector3(1, 0, 0))
	var weak: Vector3 = PuckCollisionRules.contested_pickup_velocity(
		Vector3(1, 0, 0), Vector3.ZERO, Vector3(0, 0, 1), Vector3(0, 0, -1),
		3.0, 9.0, 3.0, 0.5, 1.0, Vector3(1, 0, 0))
	assert_almost_eq(hard.length(), 9.0, 0.01, "big combined sweep clamps to max")
	assert_almost_eq(moderate.length(), 4.0, 0.01, "moderate contest → its own momentum")
	assert_almost_eq(weak.length(), 3.0, 0.01, "weak-but-directional clamps up to min")

func test_contested_deadlock_pops_perpendicular() -> void:
	# Blades cancel (net 0) → pop perpendicular to the blade-to-blade line (Z axis
	# here), at deadlock_speed, on the perp_sign side.
	var result: Vector3 = PuckCollisionRules.contested_pickup_velocity(
		Vector3(3, 0, 0), Vector3(-3, 0, 0),
		Vector3(0, 0, 1), Vector3(0, 0, -1),
		3.0, 9.0, 3.0, 0.5, 1.0, Vector3(1, 0, 0))
	assert_almost_eq(result.length(), 3.0, 0.01, "deadlock uses deadlock_speed")
	assert_almost_eq(result.z, 0.0, 0.01, "pops perpendicular to the blade line (no Z)")
	assert_ne(result.x, 0.0, "squirts sideways along X")

func test_contested_deadlock_perp_sign_flips_side() -> void:
	var pos: Vector3 = PuckCollisionRules.contested_pickup_velocity(
		Vector3(3, 0, 0), Vector3(-3, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1),
		3.0, 9.0, 3.0, 0.5, 1.0, Vector3(1, 0, 0))
	var neg: Vector3 = PuckCollisionRules.contested_pickup_velocity(
		Vector3(3, 0, 0), Vector3(-3, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1),
		3.0, 9.0, 3.0, 0.5, -1.0, Vector3(1, 0, 0))
	assert_almost_eq(pos.x, -neg.x, 0.01, "perp_sign flips the squirt side")

func test_contested_deadlock_coincident_blades_uses_fallback() -> void:
	# Net 0 AND blades at the same point → no blade-line, use the fallback dir.
	var result: Vector3 = PuckCollisionRules.contested_pickup_velocity(
		Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO,
		3.0, 9.0, 3.0, 0.5, 1.0, Vector3(0, 0, 1))
	assert_almost_eq(result.length(), 3.0, 0.01, "coincident deadlock still squirts at deadlock_speed")
