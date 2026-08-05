extends GutTest

# TopHandIK — 1-bone inverse kinematics for the stick's top hand. Given a
# desired blade target in upper-body-local XZ space, the solver returns
# (hand, blade) respecting fixed stick length and an asymmetric ROM.
#
# Two regimes:
#   FAR   (target ≥ stick_horiz_at_rest): hand stays at hand_rest_y, displaces
#         in XZ toward target up to ROM; blade sits stick_horiz_at_rest from
#         clamped hand along the aim line.
#   CLOSE (target < stick_horiz_at_rest): hand XZ stays at shoulder, hand Y
#         rises so the stick tilts vertical and blade lands on target.
#         Clamped by hand_y_max; overshoots along aim line when clamped.

# Baselines chosen to match current game defaults.
const STICK_LENGTH: float = 1.50
const BLADE_Y: float = -0.95
const HAND_REST_Y: float = 0.0
const HAND_Y_MAX: float = 0.30
const SHOULDER_OFFSET: float = 0.22
# Derived horizontal stick projection at rest: sqrt(1.50² − 0.95²) ≈ 1.1608.
const STICK_HORIZ_AT_REST: float = 1.16081
# Derived horizontal stick projection at hand_y_max: sqrt(1.50² − 1.25²).
const STICK_HORIZ_AT_MAX: float = 0.82916

# ROM
const FORE_ANGLE: float = PI / 4.0        # 45°
const BACK_ANGLE: float = 2.0 * PI / 3.0  # 120°
const FORE_REACH: float = 0.20
const BACK_REACH: float = 0.70

func _cfg() -> TopHandIK.Config:
	var cfg := TopHandIK.Config.new()
	cfg.stick_length = STICK_LENGTH
	cfg.blade_y = BLADE_Y
	cfg.hand_rest_y = HAND_REST_Y
	cfg.hand_y_max = HAND_Y_MAX
	cfg.rom_forehand_angle_max = FORE_ANGLE
	cfg.rom_backhand_angle_max = BACK_ANGLE
	cfg.rom_forehand_reach_max = FORE_REACH
	cfg.rom_backhand_reach_max = BACK_REACH
	return cfg

# A left-handed skater has blade on −X and shoulder (top hand) on +X.
func _lefty_shoulder() -> Vector3:
	return Vector3(SHOULDER_OFFSET, 0.0, 0.0)

# A right-handed skater has blade on +X and shoulder (top hand) on −X.
func _righty_shoulder() -> Vector3:
	return Vector3(-SHOULDER_OFFSET, 0.0, 0.0)

# ── Invariant: 3D stick length is constant ───────────────────────────────

func test_stick_length_3d_is_constant_for_all_targets() -> void:
	# Whatever the solver returns, |blade − hand| in 3D must equal stick_length
	# (the rigid rod invariant). Horizontal projection varies with hand Y; full
	# 3D length does not.
	var shoulder: Vector3 = _lefty_shoulder()
	for deg: int in range(-180, 180, 15):
		for dist: float in [0.0, 0.2, 0.8, 1.16, 1.5, 2.5, 5.0]:
			var angle: float = deg_to_rad(deg)
			var target := Vector2(sin(angle) * dist, -cos(angle) * dist)
			var result: TopHandIK.Result = TopHandIK.solve(shoulder, target, -1.0, _cfg())
			var length_3d: float = result.hand.distance_to(result.blade)
			assert_almost_eq(
				length_3d, STICK_LENGTH, 0.001,
				"stick length violated at deg=%d dist=%.2f" % [deg, dist])

# ── Blade Y is always locked; hand Y never exceeds ceiling ───────────────

func test_blade_y_locked_and_hand_y_within_bounds() -> void:
	var shoulder: Vector3 = _lefty_shoulder()
	for target: Vector2 in [
			Vector2(0.0, 0.0),         # at shoulder (close, hand_y clamps)
			Vector2(0.5, -0.5),        # intermediate
			Vector2(-1.5, -1.5),       # far forehand
			Vector2(1.5, -1.2),        # far backhand
		]:
		var result: TopHandIK.Result = TopHandIK.solve(shoulder, target, -1.0, _cfg())
		assert_almost_eq(result.blade.y, BLADE_Y, 0.0001, "blade Y locked")
		assert_true(
				result.hand.y >= HAND_REST_Y - 0.0001 and result.hand.y <= HAND_Y_MAX + 0.0001,
				"hand Y in [%.3f, %.3f] for target %s — got %.3f" % [HAND_REST_Y, HAND_Y_MAX, target, result.hand.y])

# ── FAR regime: target past stick range ──────────────────────────────────

func test_far_target_on_stick_sphere_hits_target_exactly() -> void:
	# Target exactly at stick_horiz_at_rest from shoulder, dead ahead.
	# Boundary between FAR and CLOSE regimes — should resolve via FAR branch
	# (or CLOSE with hand_y at rest); either way blade lands on target.
	var shoulder: Vector3 = _lefty_shoulder()
	var target := Vector2(shoulder.x, shoulder.z - STICK_HORIZ_AT_REST)
	var result: TopHandIK.Result = TopHandIK.solve(shoulder, target, -1.0, _cfg())
	assert_almost_eq(result.blade.x, target.x, 0.001, "blade X == target X")
	assert_almost_eq(result.blade.z, target.y, 0.001, "blade Z == target Z")
	assert_almost_eq(result.hand.y, HAND_REST_Y, 0.001, "hand at rest Y at boundary")

func test_far_target_slightly_past_stick_reachable_by_small_hand_extension() -> void:
	# Backhand side, just past stick_horiz_at_rest but within backhand ROM.
	var shoulder: Vector3 = _lefty_shoulder()
	var target := Vector2(shoulder.x + STICK_HORIZ_AT_REST + 0.15, shoulder.z - 0.2)
	var result: TopHandIK.Result = TopHandIK.solve(shoulder, target, -1.0, _cfg())
	assert_almost_eq(result.blade.x, target.x, 0.001, "reachable backhand: blade on target X")
	assert_almost_eq(result.blade.z, target.y, 0.001, "reachable backhand: blade on target Z")
	assert_almost_eq(result.hand.y, HAND_REST_Y, 0.001, "hand at rest Y in FAR regime")

func test_far_forehand_target_past_rom_clamps_hand_short() -> void:
	var shoulder: Vector3 = _lefty_shoulder()
	var target := Vector2(shoulder.x - 4.0, shoulder.z - 0.1)
	var result: TopHandIK.Result = TopHandIK.solve(shoulder, target, -1.0, _cfg())

	var hand_disp := Vector2(
			result.hand.x - shoulder.x, result.hand.z - shoulder.z).length()
	assert_almost_eq(
			hand_disp, FORE_REACH, 0.001,
			"hand clamped to rom_forehand_reach_max on forehand side")

	var blade_xz := Vector2(result.blade.x, result.blade.z)
	assert_gt(
			blade_xz.distance_to(target), 0.1,
			"blade falls short of unreachable forehand target")

func test_far_backhand_hand_extends_to_backhand_reach_max() -> void:
	var shoulder: Vector3 = _lefty_shoulder()
	var target := Vector2(shoulder.x + 5.0, shoulder.z - 0.1)
	var result: TopHandIK.Result = TopHandIK.solve(shoulder, target, -1.0, _cfg())
	var hand_disp := Vector2(
			result.hand.x - shoulder.x, result.hand.z - shoulder.z).length()
	assert_almost_eq(
			hand_disp, BACK_REACH, 0.001,
			"hand clamped to rom_backhand_reach_max on backhand side")

func test_far_backhand_target_reaches_farther_than_forehand() -> void:
	var shoulder: Vector3 = _lefty_shoulder()
	var d: float = STICK_HORIZ_AT_REST + 0.50

	var fore_target := Vector2(shoulder.x - d, shoulder.z)
	var fore_result: TopHandIK.Result = TopHandIK.solve(shoulder, fore_target, -1.0, _cfg())
	var fore_blade := Vector2(fore_result.blade.x, fore_result.blade.z)
	var fore_reach_achieved: float = shoulder.distance_to(
			Vector3(fore_blade.x, shoulder.y, fore_blade.y))

	var back_target := Vector2(shoulder.x + d, shoulder.z)
	var back_result: TopHandIK.Result = TopHandIK.solve(shoulder, back_target, -1.0, _cfg())
	var back_blade := Vector2(back_result.blade.x, back_result.blade.z)
	var back_reach_achieved: float = shoulder.distance_to(
			Vector3(back_blade.x, shoulder.y, back_blade.y))

	assert_gt(
			back_reach_achieved, fore_reach_achieved + 0.1,
			"backhand blade reaches meaningfully farther than forehand at same target distance")

# ── CLOSE regime: target inside stick reach ──────────────────────────────

func test_close_target_hits_blade_exactly_via_hand_rise() -> void:
	# Target well inside stick_horiz_at_rest. Hand should rise to make the
	# horizontal stick projection match r exactly; blade lands on target.
	var shoulder: Vector3 = _lefty_shoulder()
	# Pick a distance where hand_y doesn't clamp: need ideal_hand_y ≤ hand_y_max.
	# ideal_hand_y = blade_y + sqrt(stick² − r²). We want r such that
	# sqrt(1.5² − r²) ≤ blade_y + hand_y_max + 0.95 = 1.25 → r ≥ sqrt(1.5² − 1.25²)
	# ≈ 0.829. Pick r = 0.9, which is < stick_horiz_at_rest (1.16).
	var target := Vector2(shoulder.x, shoulder.z - 0.9)
	var result: TopHandIK.Result = TopHandIK.solve(shoulder, target, -1.0, _cfg())
	assert_almost_eq(result.blade.x, target.x, 0.001, "blade X lands on target")
	assert_almost_eq(result.blade.z, target.y, 0.001, "blade Z lands on target")
	assert_gt(result.hand.y, HAND_REST_Y + 0.0001, "hand rose above rest")
	assert_lt(result.hand.y, HAND_Y_MAX - 0.0001, "hand not clamped at max")

func test_close_target_stays_at_shoulder_xz() -> void:
	# CLOSE regime: hand XZ stays at shoulder; only Y rises.
	var shoulder: Vector3 = _lefty_shoulder()
	var target := Vector2(shoulder.x + 0.3, shoulder.z - 0.5)  # ~0.58 from shoulder
	var result: TopHandIK.Result = TopHandIK.solve(shoulder, target, -1.0, _cfg())
	assert_almost_eq(result.hand.x, shoulder.x, 0.001, "hand X at shoulder in CLOSE regime")
	assert_almost_eq(result.hand.z, shoulder.z, 0.001, "hand Z at shoulder in CLOSE regime")

func test_close_target_at_shoulder_clamps_hand_and_overshoots_along_aim() -> void:
	# Target at (or right on top of) the shoulder: the solver would want the
	# hand to rise all the way to blade_y + stick_length = 0.55 m so the stick
	# is vertical. But hand_y_max = 0.30 clamps it; stick_horiz can't go below
	# STICK_HORIZ_AT_MAX ≈ 0.829. So the blade can't come in closer than that
	# to the shoulder. With aim_dir falling back to (0, −1), blade lands at
	# shoulder + (0, -1) × STICK_HORIZ_AT_MAX.
	var shoulder: Vector3 = _lefty_shoulder()
	var target := Vector2(shoulder.x, shoulder.z)
	var result: TopHandIK.Result = TopHandIK.solve(shoulder, target, -1.0, _cfg())
	assert_almost_eq(result.hand.y, HAND_Y_MAX, 0.001, "hand clamped at hand_y_max")
	assert_almost_eq(result.blade.x, shoulder.x, 0.001, "blade on forward axis")
	assert_almost_eq(result.blade.z, shoulder.z - STICK_HORIZ_AT_MAX, 0.001, "blade at min horizontal reach along forward")

func test_close_to_far_continuity_at_stick_horiz_at_rest() -> void:
	# At the exact boundary r == stick_horiz_at_rest, the two regimes should
	# agree: hand at hand_rest_y, blade on target. Tested by sampling both
	# just below and just above the boundary and checking continuity of hand Y.
	var shoulder: Vector3 = _lefty_shoulder()
	var forward := Vector2(0.0, -1.0)

	var just_below_target := shoulder_xz_from(shoulder) + forward * (STICK_HORIZ_AT_REST - 0.0005)
	var just_above_target := shoulder_xz_from(shoulder) + forward * (STICK_HORIZ_AT_REST + 0.0005)

	var below: TopHandIK.Result = TopHandIK.solve(shoulder, just_below_target, -1.0, _cfg())
	var above: TopHandIK.Result = TopHandIK.solve(shoulder, just_above_target, -1.0, _cfg())

	# Hand Y should be nearly identical across the boundary — the CLOSE branch's
	# ideal_hand_y converges to hand_rest_y as r → stick_horiz_at_rest.
	assert_almost_eq(
			below.hand.y, above.hand.y, 0.002,
			"hand Y continuous across FAR/CLOSE boundary")
	# Also: blade should be the same in both regimes at this r.
	assert_almost_eq(
			below.blade.x, above.blade.x, 0.002,
			"blade X continuous across FAR/CLOSE boundary")
	assert_almost_eq(
			below.blade.z, above.blade.z, 0.002,
			"blade Z continuous across FAR/CLOSE boundary")

func shoulder_xz_from(shoulder: Vector3) -> Vector2:
	return Vector2(shoulder.x, shoulder.z)

# ── project_blade matches solve().blade ───────────────────────────────────

func test_project_blade_matches_solve_blade_everywhere() -> void:
	# project_blade is the closed-form ROM clamp that solve() builds the hand on
	# top of. They must agree on the blade position across both regimes and both
	# handedness signs, or the speed-cap target (which uses project_blade) would
	# drift from the pose solve (which uses solve()).
	for shoulder: Vector3 in [_lefty_shoulder(), _righty_shoulder()]:
		var sign: float = -1.0 if shoulder.x > 0.0 else 1.0
		for deg: int in range(-180, 180, 15):
			for dist: float in [0.0, 0.2, 0.8, 1.16, 1.5, 2.5, 5.0]:
				var angle: float = deg_to_rad(deg)
				var target := Vector2(sin(angle) * dist, -cos(angle) * dist)
				var projected: Vector3 = TopHandIK.project_blade(shoulder, target, sign, _cfg())
				var solved: TopHandIK.Result = TopHandIK.solve(shoulder, target, sign, _cfg())
				assert_almost_eq(
						projected.x, solved.blade.x, 0.0001,
						"blade X agree at deg=%d dist=%.2f sign=%.0f" % [deg, dist, sign])
				assert_almost_eq(
						projected.y, solved.blade.y, 0.0001,
						"blade Y agree at deg=%d dist=%.2f sign=%.0f" % [deg, dist, sign])
				assert_almost_eq(
						projected.z, solved.blade.z, 0.0001,
						"blade Z agree at deg=%d dist=%.2f sign=%.0f" % [deg, dist, sign])

# ── Handedness mirror ─────────────────────────────────────────────────────

func test_righty_mirrors_lefty_in_x() -> void:
	var lefty_shoulder: Vector3 = _lefty_shoulder()
	var righty_shoulder: Vector3 = _righty_shoulder()
	var lefty_target := Vector2(-1.5, -1.2)
	var righty_target := Vector2(1.5, -1.2)

	var lefty: TopHandIK.Result = TopHandIK.solve(lefty_shoulder, lefty_target, -1.0, _cfg())
	var righty: TopHandIK.Result = TopHandIK.solve(righty_shoulder, righty_target, 1.0, _cfg())

	assert_almost_eq(lefty.hand.x, -righty.hand.x, 0.001, "hand X mirrors")
	assert_almost_eq(lefty.hand.y, righty.hand.y, 0.001, "hand Y matches")
	assert_almost_eq(lefty.hand.z, righty.hand.z, 0.001, "hand Z matches")
	assert_almost_eq(lefty.blade.x, -righty.blade.x, 0.001, "blade X mirrors")
	assert_almost_eq(lefty.blade.z, righty.blade.z, 0.001, "blade Z matches")


# ── CLOSE-regime angular ROM (the behind-the-back fix) ───────────────────

func test_close_regime_cannot_reach_behind() -> void:
	# The bug this pins: the FAR regime always clamped direction to the
	# angular ROM, but a slowly-swept cursor entering the CLOSE regime could
	# walk the blade to ANY angle — including directly behind the body. The
	# CLOSE aim now respects the same asymmetric limits.
	var shoulder := _lefty_shoulder()
	# Target close in and directly BEHIND the shoulder (+Z is behind).
	var behind := Vector2(shoulder.x + 0.05, shoulder.z + 0.6)
	var blade: Vector3 = TopHandIK.project_blade(shoulder, behind, -1.0, _cfg())
	var dir := Vector2(blade.x - shoulder.x, blade.z - shoulder.z).normalized()
	# Forehand-signed angle for a lefty (blade_side_sign −1).
	var angle_fh: float = atan2(dir.x, -dir.y) * -1.0
	assert_between(angle_fh, -BACK_ANGLE - 0.001, FORE_ANGLE + 0.001,
			"CLOSE blade direction stays inside the angular ROM")


func test_close_regime_in_rom_aim_unchanged() -> void:
	# A close target inside the ROM keeps its exact aim direction — the clamp
	# only engages past the limits.
	var shoulder := _lefty_shoulder()
	var target := Vector2(shoulder.x - 0.3, shoulder.z - 0.4)  # front, blade side
	var blade: Vector3 = TopHandIK.project_blade(shoulder, target, -1.0, _cfg())
	var aim := (target - Vector2(shoulder.x, shoulder.z)).normalized()
	var got := Vector2(blade.x - shoulder.x, blade.z - shoulder.z).normalized()
	assert_almost_eq(got.x, aim.x, 0.0001, "in-ROM close aim x preserved")
	assert_almost_eq(got.y, aim.y, 0.0001, "in-ROM close aim z preserved")


func test_close_and_far_agree_at_the_boundary_behind() -> void:
	# Continuity for an out-of-ROM aim: a behind-ish target just inside vs just
	# outside the rest radius lands the blade in the same clamped direction.
	var shoulder := _lefty_shoulder()
	var shoulder_xz := Vector2(shoulder.x, shoulder.z)
	var aim := Vector2(0.2, 1.0).normalized()  # well past the backhand limit
	var close_target: Vector2 = shoulder_xz + aim * (STICK_HORIZ_AT_REST - 0.01)
	var far_target: Vector2 = shoulder_xz + aim * (STICK_HORIZ_AT_REST + 0.01)
	var close_blade: Vector3 = TopHandIK.project_blade(shoulder, close_target, -1.0, _cfg())
	var far_blade: Vector3 = TopHandIK.project_blade(shoulder, far_target, -1.0, _cfg())
	var close_dir := Vector2(close_blade.x - shoulder.x, close_blade.z - shoulder.z).normalized()
	var far_dir := Vector2(far_blade.x - shoulder.x, far_blade.z - shoulder.z).normalized()
	assert_almost_eq(close_dir.x, far_dir.x, 0.01, "clamped direction continuous across regimes")
	assert_almost_eq(close_dir.y, far_dir.y, 0.01)


# ── Inner boundary: hand_y_max × stick length (the phone-booth seesaw) ────

func test_inner_boundary_grows_with_stick_length() -> void:
	# The blade's minimum distance from the shoulder is sqrt(S² − drop_max²):
	# a longer stick has a bigger no-go circle in tight. Pin monotonic growth,
	# and the near-vertical sensitivity that makes the stick-length gear lean
	# a real in-tight tradeoff: when S barely exceeds the max hand drop, a few
	# cm of stick add a LOT of inner circle.
	var shoulder := _lefty_shoulder()
	var at_shoulder := Vector2(shoulder.x, shoulder.z - 0.01)
	var inner: Array[float] = []
	for stick: float in [1.44, 1.50, 1.56]:
		var cfg := _cfg()
		cfg.stick_length = stick
		var blade: Vector3 = TopHandIK.project_blade(shoulder, at_shoulder, -1.0, cfg)
		inner.append(Vector2(blade.x - shoulder.x, blade.z - shoulder.z).length())
	assert_lt(inner[0], inner[1], "short stick works tighter than standard")
	assert_lt(inner[1], inner[2], "standard works tighter than long")
	# Near the vertical limit (S ≈ max drop 1.25) the growth is steep.
	var near := _cfg()
	near.stick_length = 1.26
	var near_blade: Vector3 = TopHandIK.project_blade(shoulder, at_shoulder, -1.0, near)
	var near_inner: float = Vector2(near_blade.x - shoulder.x, near_blade.z - shoulder.z).length()
	var near2 := _cfg()
	near2.stick_length = 1.31
	var near2_blade: Vector3 = TopHandIK.project_blade(shoulder, at_shoulder, -1.0, near2)
	var near2_inner: float = Vector2(near2_blade.x - shoulder.x, near2_blade.z - shoulder.z).length()
	assert_gt(near2_inner, near_inner * 2.0,
			"5 cm of stick more than doubles the inner circle near the vertical limit")

# ── Obstacle reach cap (max_blade_reach) ─────────────────────────────────
# The boards intersect the ROM envelope: a blade cannot be farther from the
# shoulder than the wall along the aim line. The cap lands on the DESIRED
# distance before the regime split, so a wall-limited reach flows into the
# CLOSE branch and chokes up instead of being dragged back out of FAR.

func test_reach_cap_pulls_blade_to_the_limit() -> void:
	var shoulder: Vector3 = _lefty_shoulder()
	var cfg := _cfg()
	cfg.max_blade_reach = 0.90
	# Straight ahead, well past both the cap and stick_horiz_at_rest.
	var target := Vector2(shoulder.x, shoulder.z - 3.0)
	var blade: Vector3 = TopHandIK.project_blade(shoulder, target, -1.0, cfg)
	var d: float = Vector2(blade.x - shoulder.x, blade.z - shoulder.z).length()
	assert_almost_eq(d, 0.90, 0.001, "blade stops at the obstacle, not at ROM")

func test_reach_cap_preserves_aim_direction() -> void:
	var shoulder: Vector3 = _lefty_shoulder()
	var cfg := _cfg()
	cfg.max_blade_reach = 0.80
	# Swept inside the angular ROM (lefty: forehand at negative deg, capped at
	# 45°; backhand at positive, capped at 120°). Past those the aim is clamped
	# to the boundary ray by design, which is the FAR regime's behavior, not the
	# reach cap's — test_reach_cap_pulls_blade_to_the_limit covers distance.
	for deg: int in range(-40, 91, 10):
		var rad: float = deg_to_rad(float(deg))
		var aim := Vector2(sin(rad), -cos(rad))
		var target := Vector2(shoulder.x, shoulder.z) + aim * 3.0
		var blade: Vector3 = TopHandIK.project_blade(shoulder, target, -1.0, cfg)
		var got := Vector2(blade.x - shoulder.x, blade.z - shoulder.z)
		# Inside the angular ROM the capped blade stays on the same ray.
		assert_almost_eq(got.normalized().angle_to(aim), 0.0, 0.001,
				"capped blade holds the aim line at %d°" % deg)

func test_reach_cap_chokes_up_rather_than_shortening_the_stick() -> void:
	var shoulder: Vector3 = _lefty_shoulder()
	var cfg := _cfg()
	cfg.max_blade_reach = 0.70  # inside stick_horiz_at_rest → CLOSE regime
	var target := Vector2(shoulder.x, shoulder.z - 3.0)
	var res: TopHandIK.Result = TopHandIK.solve(shoulder, target, -1.0, cfg)
	assert_gt(res.hand.y, HAND_REST_Y, "hand rises — the stick tilts toward vertical")
	assert_almost_eq((res.blade - res.hand).length(), STICK_LENGTH, 0.001,
			"rigid stick survives the cap")

func test_reach_cap_is_inert_when_slacker_than_rom() -> void:
	var shoulder: Vector3 = _lefty_shoulder()
	var capped := _cfg()
	capped.max_blade_reach = 50.0
	var target := Vector2(shoulder.x - 1.0, shoulder.z - 1.5)
	var with_cap: Vector3 = TopHandIK.project_blade(shoulder, target, -1.0, capped)
	var without: Vector3 = TopHandIK.project_blade(shoulder, target, -1.0, _cfg())
	assert_almost_eq(with_cap.x, without.x, 0.0001, "far cap changes nothing (x)")
	assert_almost_eq(with_cap.z, without.z, 0.0001, "far cap changes nothing (z)")

# ── hand_for_clamped_blade ───────────────────────────────────────────────
# Arm reconstruction for a blade an obstacle clamp has already placed. The
# blade is authoritative, the arm stays inside ROM, and stick length yields.

func test_hand_reconstruction_inverts_solve_exactly() -> void:
	# For any blade solve() itself placed, the reconstruction must return the
	# same hand — otherwise the pose pops the instant a clamp starts biting.
	var cfg := _cfg()
	for sign_i: float in [-1.0, 1.0]:
		var shoulder: Vector3 = _lefty_shoulder() if sign_i < 0.0 else _righty_shoulder()
		for deg: int in range(-180, 180, 15):
			for dist: float in [0.1, 0.5, 1.0, 1.16, 1.4, 2.0, 4.0]:
				var rad: float = deg_to_rad(float(deg))
				var target := Vector2(shoulder.x, shoulder.z) \
						+ Vector2(sin(rad), -cos(rad)) * dist
				var res: TopHandIK.Result = TopHandIK.solve(shoulder, target, sign_i, cfg)
				var hand: Vector3 = TopHandIK.hand_for_clamped_blade(
						shoulder, Vector2(res.blade.x, res.blade.z), res.blade.y, sign_i, cfg)
				assert_almost_eq(hand.x, res.hand.x, 0.0005,
						"hand.x at %d° / %.2f m" % [deg, dist])
				assert_almost_eq(hand.y, res.hand.y, 0.0005,
						"hand.y at %d° / %.2f m" % [deg, dist])
				assert_almost_eq(hand.z, res.hand.z, 0.0005,
						"hand.z at %d° / %.2f m" % [deg, dist])

func test_hand_never_leaves_arm_reach_for_any_clamped_blade() -> void:
	# The failure this replaces: a clamp offset translated the hand rigidly, so
	# it could land anywhere — including behind the shoulder, which folded the
	# elbow through the torso. Reconstruction bounds it by ROM reach always.
	var cfg := _cfg()
	var shoulder: Vector3 = _lefty_shoulder()
	for deg: int in range(-180, 180, 10):
		for dist: float in [0.0, 0.05, 0.3, 0.9, 1.16, 1.5, 2.0, 3.0, 6.0]:
			var rad: float = deg_to_rad(float(deg))
			var blade_xz := Vector2(shoulder.x, shoulder.z) \
					+ Vector2(sin(rad), -cos(rad)) * dist
			var hand: Vector3 = TopHandIK.hand_for_clamped_blade(
					shoulder, blade_xz, BLADE_Y, -1.0, cfg)
			var reach: float = Vector2(hand.x - shoulder.x, hand.z - shoulder.z).length()
			assert_lte(reach, BACK_REACH + 0.0005,
					"hand within arm reach at %d° / %.2f m (got %.3f)" % [deg, dist, reach])

func test_clamped_blade_pulled_behind_keeps_hand_in_front_of_shoulder() -> void:
	# A carrier jammed on the boards: the blade gets clamped back to just in
	# front of the body. The hand must come in over the shoulder and rise (choke
	# up), never slide behind it.
	var cfg := _cfg()
	var shoulder: Vector3 = _lefty_shoulder()
	var blade_xz := Vector2(shoulder.x, shoulder.z - 0.35)  # deep inside stick reach
	var hand: Vector3 = TopHandIK.hand_for_clamped_blade(
			shoulder, blade_xz, BLADE_Y, -1.0, cfg)
	assert_almost_eq(hand.x, shoulder.x, 0.0005, "hand stacks over the shoulder")
	assert_almost_eq(hand.z, shoulder.z, 0.0005, "hand does not slide behind")
	assert_gt(hand.y, HAND_REST_Y, "hand rises — the choke-up")
	assert_lte(hand.y, HAND_Y_MAX + 0.0005, "choke-up bounded by hand_y_max")

func test_stick_length_yields_not_arm_length_when_blade_is_pinned() -> void:
	# The priority ladder: blade stays put, arm stays in ROM, stick gives.
	var cfg := _cfg()
	var shoulder: Vector3 = _lefty_shoulder()
	var blade_xz := Vector2(shoulder.x - 0.20, shoulder.z - 0.30)
	var hand: Vector3 = TopHandIK.hand_for_clamped_blade(
			shoulder, blade_xz, BLADE_Y, -1.0, cfg)
	var rendered: float = (Vector3(blade_xz.x, BLADE_Y, blade_xz.y) - hand).length()
	assert_lte(rendered, STICK_LENGTH + 0.0005,
			"rendered shaft never exceeds the real stick — it chokes up, not stretches")

# ── enforce_rigid_stick ───────────────────────────────────────────────────
# The correction the AUTHORED poses run through (shot finishes, wind-up, block).
# Those place hand and blade from tunables rather than solving one against the
# other, so nothing in the placement keeps them a stick apart — the slapper
# finish drew 2.00 m of a 1.30 m stick — and any obstacle clamp then adds its
# whole correction on top. Order: the hand slides down the shaft as far as the
# arm allows, and only what is left comes off the blade.

func _rigid(shoulder: Vector3, hand: Vector3, blade: Vector3,
		sign_i: float = -1.0) -> TopHandIK.Result:
	var out := TopHandIK.Result.new()
	TopHandIK.enforce_rigid_stick(shoulder, hand, blade, sign_i, _cfg(), out)
	return out


func test_a_pose_within_a_stick_length_is_left_alone() -> void:
	# Inert on everything authored honestly — including a shaft reading SHORT,
	# which is the legitimate choke-up and must not be pushed back out.
	var shoulder: Vector3 = _lefty_shoulder()
	var hand := Vector3(shoulder.x, HAND_REST_Y, shoulder.z)
	for dist: float in [0.4, 0.9, STICK_HORIZ_AT_REST]:
		var blade := Vector3(shoulder.x, BLADE_Y, shoulder.z - dist)
		var res: TopHandIK.Result = _rigid(shoulder, hand, blade)
		assert_eq(res.hand, hand, "hand untouched at %.2f m" % dist)
		assert_eq(res.blade, blade, "blade untouched at %.2f m" % dist)


func test_an_over_long_pose_comes_back_to_exactly_one_stick() -> void:
	var shoulder: Vector3 = _lefty_shoulder()
	var hand := Vector3(shoulder.x, HAND_REST_Y, shoulder.z - 0.30)
	for over: float in [0.05, 0.3, 0.7, 2.0]:
		var blade: Vector3 = _blade_at_span(hand, STICK_LENGTH + over)
		var res: TopHandIK.Result = _rigid(shoulder, hand, blade)
		assert_almost_eq(res.hand.distance_to(res.blade), STICK_LENGTH, 0.0005,
				"rigid at %.2f m over" % over)


# A blade straight in front of `hand` at exactly `span` from it in 3D, sitting at
# BLADE_Y. The drop is most of a metre, so laying the span out along z alone (the
# obvious way to write these) makes it something else entirely.
func _blade_at_span(hand: Vector3, span: float) -> Vector3:
	var drop: float = hand.y - BLADE_Y
	return Vector3(hand.x, BLADE_Y, hand.z - sqrt(maxf(span * span - drop * drop, 0.0)))


func test_the_hand_pays_first_and_the_blade_only_for_the_rest() -> void:
	# A small overrun the arm can absorb: the blade must not move at all, because
	# the blade is where the pose (or a clamp) wanted it.
	var shoulder: Vector3 = _lefty_shoulder()
	var hand := Vector3(shoulder.x, HAND_REST_Y, shoulder.z)
	var blade: Vector3 = _blade_at_span(hand, STICK_LENGTH + 0.05)
	var res: TopHandIK.Result = _rigid(shoulder, hand, blade)
	assert_eq(res.blade, blade, "the arm covered it, so the blade stayed")
	assert_almost_eq(res.hand.distance_to(hand), 0.05, 0.0005,
			"the hand slid the whole overrun down the shaft")


func test_the_hand_never_slides_past_the_arm() -> void:
	# The reach the finish poses were quietly buying: past ROM the arm stops and
	# the blade gives up the rest of the reach instead.
	var shoulder: Vector3 = _lefty_shoulder()
	var hand := Vector3(shoulder.x, HAND_REST_Y, shoulder.z)
	var blade := Vector3(shoulder.x, BLADE_Y, shoulder.z - (STICK_LENGTH + 1.5))
	var res: TopHandIK.Result = _rigid(shoulder, hand, blade)
	var reach: float = Vector2(res.hand.x - shoulder.x, res.hand.z - shoulder.z).length()
	assert_lte(reach, BACK_REACH + 0.0005, "hand stopped at the arm's own limit")
	assert_gt(blade.distance_to(res.blade), 0.5, "so the finish fell short instead")
	assert_almost_eq(res.hand.distance_to(res.blade), STICK_LENGTH, 0.0005,
			"and the stick is still exactly a stick")


func test_the_blade_falls_short_along_the_shaft_it_was_on() -> void:
	# Direction is preserved — a finish that cannot reach all the way still
	# points where it was swinging.
	var shoulder: Vector3 = _lefty_shoulder()
	var hand := Vector3(shoulder.x, HAND_REST_Y, shoulder.z)
	var blade := Vector3(shoulder.x + 1.4, BLADE_Y, shoulder.z - 1.4)
	var res: TopHandIK.Result = _rigid(shoulder, hand, blade)
	var was: Vector3 = (blade - hand).normalized()
	var now: Vector3 = (res.blade - res.hand).normalized()
	assert_almost_eq(was.dot(now), 1.0, 0.0005, "still on the same line")


func test_a_raised_hand_keeps_its_height() -> void:
	# Why the finishes use this rather than the reconstruction: their hand is
	# deliberately high and carried, and hand_for_clamped_blade would put it back
	# at rest height — dropping the arm mid-follow-through.
	var shoulder: Vector3 = _lefty_shoulder()
	var hand := Vector3(shoulder.x, HAND_Y_MAX, shoulder.z - 0.20)
	var blade := Vector3(shoulder.x, BLADE_Y + 0.5, shoulder.z - 2.2)
	var res: TopHandIK.Result = _rigid(shoulder, hand, blade)
	assert_gt(res.hand.y, HAND_REST_Y + 0.1, "the finish's raised hand survives")
	assert_lte(res.hand.y, HAND_Y_MAX + 0.0005, "and stays under the ceiling")
	assert_almost_eq(res.hand.distance_to(res.blade), STICK_LENGTH, 0.0005, "rigid")
