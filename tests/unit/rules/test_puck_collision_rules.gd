extends GutTest

# PuckCollisionRules — pure physics math for puck interactions.

# ── can_poke_check ───────────────────────────────────────────────────────────

func test_same_team_cannot_poke() -> void:
	assert_false(PuckCollisionRules.can_poke_check(0, 0))
	assert_false(PuckCollisionRules.can_poke_check(1, 1))

func test_opponents_can_poke() -> void:
	assert_true(PuckCollisionRules.can_poke_check(0, 1))
	assert_true(PuckCollisionRules.can_poke_check(1, 0))

# ── board_rescue_velocity ────────────────────────────────────────────────────
# Analytic containment rescue for a puck the boards' trimesh let slip out.
# Args: (velocity, outward_normal_xz, restitution). outward_normal_xz points
# from the rink boundary toward the escaped position.

func test_rescue_reflects_outward_component_with_restitution() -> void:
	# +X outward escape at 10 m/s with 5 m/s along the wall: the outward
	# component reflects to −10·e, the tangential slide is untouched — the same
	# reflection Trajectory.predict applies for a modeled board bounce.
	var result: Vector3 = PuckCollisionRules.board_rescue_velocity(
			Vector3(10, 0, 5), Vector2(1, 0), 0.4)
	assert_almost_eq(result.x, -4.0, 0.001, "outward component reflects with restitution")
	assert_almost_eq(result.z, 5.0, 0.001, "tangential (rim) component is kept")

func test_rescue_leaves_inward_velocity_unchanged() -> void:
	# Engine already resolved the bounce this step (velocity points back
	# inside); only the position needed fixing — don't double-bounce.
	var v := Vector3(-3.0, 0.0, 7.0)
	assert_eq(PuckCollisionRules.board_rescue_velocity(v, Vector2(1, 0), 0.4), v)

func test_rescue_preserves_vertical_velocity() -> void:
	var result: Vector3 = PuckCollisionRules.board_rescue_velocity(
			Vector3(10, 2.5, 0), Vector2(1, 0), 0.4)
	assert_almost_eq(result.y, 2.5, 0.001, "boards are vertical — Y untouched")

func test_rescue_never_gains_speed() -> void:
	# Reflection with e ≤ 1 can only shed pace, whatever the escape angle.
	var v := Vector3(12, 1.0, 9)
	var n := Vector2(0.6, 0.8)
	var result: Vector3 = PuckCollisionRules.board_rescue_velocity(v, n, 0.4)
	assert_lt(result.length(), v.length(), "rescue bounce sheds pace like a real carom")

func test_rescue_normalizes_the_outward_normal() -> void:
	# A non-unit outward vector (caller passes raw boundary delta) must yield
	# the same reflection as the unit normal.
	var unit: Vector3 = PuckCollisionRules.board_rescue_velocity(
			Vector3(10, 0, 5), Vector2(1, 0), 0.4)
	var scaled: Vector3 = PuckCollisionRules.board_rescue_velocity(
			Vector3(10, 0, 5), Vector2(0.02, 0), 0.4)
	assert_almost_eq(unit.x, scaled.x, 0.001)
	assert_almost_eq(unit.z, scaled.z, 0.001)

func test_rescue_degenerate_normal_passes_through() -> void:
	var v := Vector3(4, 0, 4)
	assert_eq(PuckCollisionRules.board_rescue_velocity(v, Vector2.ZERO, 0.4), v)

# ── deflect_velocity ─────────────────────────────────────────────────────────
# Normal/tangential decomposition. Args: (incoming, contact_normal,
# normal_restitution, normal_restitution_min=-1, tangential_retain=1, speed_ref=0).
# contact_normal points AGAINST the incoming puck (blade face normal).

func test_perfect_restitution_square_hit_reflects_fully() -> void:
	# e=1, t=1, square hit (normal antiparallel to travel) → clean reversal, full
	# speed. This is the billiard-reflection special case of the general model.
	var result: Vector3 = PuckCollisionRules.deflect_velocity(
		Vector3(10, 0, 0), Vector3(-1, 0, 0), 1.0, -1.0, 1.0)
	assert_lt(result.x, 0.0, "square hit reverses the puck")
	assert_almost_eq(result.length(), 10.0, 0.01, "perfect restitution keeps all speed")

func test_square_hit_low_restitution_dies_bobble() -> void:
	# A square hit with low restitution (all velocity is normal, little bounces
	# back) → the puck is smothered: near-dead in front. This is the BOBBLE.
	var result: Vector3 = PuckCollisionRules.deflect_velocity(
		Vector3(10, 0, 0), Vector3(-1, 0, 0), 0.15, -1.0, 0.85)
	assert_almost_eq(result.length(), 10.0 * 0.15, 0.01,
		"a dead-square hit keeps only the restitution fraction")
	assert_lt(result.length(), 2.0, "smothered puck drops in front (bobble)")

func test_glancing_hit_keeps_pace_and_redirects() -> void:
	# A glancing blade (face nearly parallel to flight → mostly tangential) keeps
	# most of the puck's pace and bends its LINE. This is the true tip / redirect.
	# normal ≈ 15° off perpendicular-to-travel → small normal component.
	var normal := Vector3(-0.26, 0, -0.966).normalized()
	var result: Vector3 = PuckCollisionRules.deflect_velocity(
		Vector3(10, 0, 0), normal, 0.15, -1.0, 0.85)
	assert_gt(result.length(), 7.5, "a glance keeps most of its pace")
	assert_lt(result.z, 0.0, "the puck's line is redirected off the incoming axis")

func test_bobble_vs_redirect_from_one_model() -> void:
	# The three-way outcome in a single call pair, at a hard shot speed (40 m/s,
	# ref 30 → restitution bottomed out). A squared blade smothers it into a
	# bobble; a glancing blade redirects it with pace. Same speed, same tunables —
	# alignment alone splits the outcome.
	var square: Vector3 = PuckCollisionRules.deflect_velocity(
		Vector3(40, 0, 0), Vector3(-1, 0, 0), 0.6, 0.15, 0.85, 30.0)
	var glance: Vector3 = PuckCollisionRules.deflect_velocity(
		Vector3(40, 0, 0), Vector3(-0.26, 0, -0.966).normalized(), 0.6, 0.15, 0.85, 30.0)
	assert_lt(square.length(), 11.0, "squared-up hard shot bobbles (dies in front)")
	assert_gt(glance.length(), 25.0, "glancing hard shot stays a live redirect")

func test_restitution_falloff_deadens_hard_pucks_more() -> void:
	# Same square hit; a fast puck (≥ ref) rebounds a SMALLER fraction than a slow
	# one — a hard puck deadens more head-on (feeds the bobble). ref=20, e 0.6→0.15.
	var normal := Vector3(-1, 0, 0)
	var slow: Vector3 = PuckCollisionRules.deflect_velocity(
		Vector3(10, 0, 0), normal, 0.6, 0.15, 0.85, 20.0)
	var fast: Vector3 = PuckCollisionRules.deflect_velocity(
		Vector3(20, 0, 0), normal, 0.6, 0.15, 0.85, 20.0)
	assert_almost_eq(slow.length(), 10.0 * 0.375, 0.05, "10/20 hardness=0.5 → e lerps to 0.375")
	assert_almost_eq(fast.length(), 20.0 * 0.15, 0.05, "at ref speed e bottoms out at 0.15")
	assert_lt(fast.length() / 20.0, slow.length() / 10.0, "fast puck keeps a smaller fraction")

func test_restitution_falloff_disabled_when_min_negative() -> void:
	# normal_restitution_min < 0 → flat restitution regardless of speed.
	var result: Vector3 = PuckCollisionRules.deflect_velocity(
		Vector3(30, 0, 0), Vector3(-1, 0, 0), 0.7, -1.0, 0.85, 20.0)
	assert_almost_eq(result.length(), 30.0 * 0.7, 0.01, "negative min keeps flat restitution")

func test_degenerate_normal_passes_through() -> void:
	var result: Vector3 = PuckCollisionRules.deflect_velocity(
		Vector3(10, 0, 0), Vector3.ZERO, 0.6, 0.15, 0.85, 30.0)
	assert_almost_eq(result, Vector3(10, 0, 0), Vector3(0.01, 0.01, 0.01),
		"a degenerate contact normal passes the puck through unchanged")

func test_zero_velocity_yields_zero() -> void:
	var result: Vector3 = PuckCollisionRules.deflect_velocity(
		Vector3.ZERO, Vector3(-1, 0, 0), 0.6, 0.15, 0.85, 30.0)
	assert_almost_eq(result.length(), 0.0, 0.001, "no input energy, no output")

# ── deflect_loft_speed ───────────────────────────────────────────────────────

const _UP: float = 3.8
const _DOWN: float = 3.5

func _loft(level: int) -> float:
	return PuckCollisionRules.deflect_loft_speed(level, _UP, _DOWN)

# The four loft levels are DEFLECT MODES (docs/elevation-rework-plan.md v3
# §3): the level names the redirect's vertical sign outright — FLAT flat,
# LOW/MID up, HIGH down — and the blade's LIFT HEIGHT plays the matching
# plane (ice / ice / low air / high air), which is where the old geometry
# test's anti-cheese properties now live: a saucer apexes under the MID
# pivot, so an air mode still only ever meets genuinely high pucks.

func test_flat_mode_never_lofts() -> void:
	assert_almost_eq(_loft(ShotMechanics.ELEVATION_FLAT), 0.0, 0.001,
		"FLAT redirects along the ice")

func test_low_mode_tips_the_ground_puck_up() -> void:
	assert_almost_eq(_loft(ShotMechanics.ELEVATION_LOW), _UP, 0.001,
		"LOW is the money tip — ground puck up")

func test_mid_mode_tips_the_air_puck_up() -> void:
	assert_almost_eq(_loft(ShotMechanics.ELEVATION_MID), _UP, 0.001,
		"MID roofs the rising shot — air puck up")

func test_high_mode_bats_the_air_puck_down() -> void:
	assert_almost_eq(_loft(ShotMechanics.ELEVATION_HIGH), -_DOWN, 0.001,
		"HIGH is the knockdown — air puck down")

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

func test_body_check_strip_soft_hit_trickles_at_full_speed() -> void:
	# intensity 0 (barely stripped) → puck keeps the full trickle pace along the hit line.
	var dir := Vector3(1, 0, 0)
	var result: Vector3 = PuckCollisionRules.body_check_strip_velocity(dir, 3.0, 0.8, 0.0)
	assert_eq(result, Vector3(3, 0, 0))

func test_body_check_strip_hard_hit_drops_loose() -> void:
	# intensity 1 (monster hit) → puck jarred nearly dead at contact (loose_speed).
	var dir := Vector3(1, 0, 0)
	var result: Vector3 = PuckCollisionRules.body_check_strip_velocity(dir, 3.0, 0.8, 1.0)
	assert_almost_eq(result.length(), 0.8, 0.0001, "hard hit deadens the strip to loose_speed")

func test_body_check_strip_lerps_with_intensity() -> void:
	# halfway → midpoint between trickle and loose pace.
	var dir := Vector3(1, 0, 0)
	var result: Vector3 = PuckCollisionRules.body_check_strip_velocity(dir, 3.0, 0.8, 0.5)
	assert_almost_eq(result.length(), 1.9, 0.0001, "intensity 0.5 → (3.0+0.8)/2")

func test_body_check_strip_clamps_intensity() -> void:
	var dir := Vector3(1, 0, 0)
	var over: Vector3 = PuckCollisionRules.body_check_strip_velocity(dir, 3.0, 0.8, 2.0)
	assert_almost_eq(over.length(), 0.8, 0.0001, "intensity >1 clamps to loose_speed")

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
