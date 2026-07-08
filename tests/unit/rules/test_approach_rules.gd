extends GutTest

# ApproachRules — deterministic eased skate-in path used by the faceoff / intro
# approach (position + facing as pure functions of start, target, progress t).

const START: Vector3 = Vector3(11.5, 1.0, 4.4)
const TARGET: Vector3 = Vector3(0.0, 1.0, 1.5)

# ── path_position ────────────────────────────────────────────────────────────

func test_position_at_zero_is_start() -> void:
	assert_eq(ApproachRules.path_position(START, TARGET, 0.0), START)

func test_position_at_one_is_target() -> void:
	assert_eq(ApproachRules.path_position(START, TARGET, 1.0), TARGET)

func test_position_clamps_below_zero_to_start() -> void:
	assert_eq(ApproachRules.path_position(START, TARGET, -0.5), START)

func test_position_clamps_above_one_to_target() -> void:
	assert_eq(ApproachRules.path_position(START, TARGET, 1.5), TARGET)

func test_position_midpoint_is_geometric_midpoint() -> void:
	# smoothstep(0.5) == 0.5, so t=0.5 lands exactly halfway.
	var mid: Vector3 = ApproachRules.path_position(START, TARGET, 0.5)
	assert_almost_eq(mid, START.lerp(TARGET, 0.5), Vector3(0.001, 0.001, 0.001))

func test_position_eases_in_slower_than_linear() -> void:
	# Ease-in: early progress covers less ground than a linear lerp would.
	var eased: Vector3 = ApproachRules.path_position(START, TARGET, 0.2)
	var linear: Vector3 = START.lerp(TARGET, 0.2)
	assert_lt(eased.distance_to(START), linear.distance_to(START))

func test_position_is_monotonic_toward_target() -> void:
	var prev: float = START.distance_to(TARGET)
	for i: int in range(1, 11):
		var d: float = ApproachRules.path_position(START, TARGET, i / 10.0).distance_to(TARGET)
		assert_true(d <= prev + 0.0001, "distance to target must not increase at step %d" % i)
		prev = d

# ── path_position: momentum (Hermite launch) ─────────────────────────────────

func test_zero_velocity_matches_smoothstep() -> void:
	# Default v0 = 0 must reduce exactly to the plain smoothstep ease.
	for i: int in range(0, 11):
		var t: float = i / 10.0
		var hermite: Vector3 = ApproachRules.path_position(START, TARGET, t, Vector3.ZERO, 2.0)
		var smooth: Vector3 = START.lerp(TARGET, smoothstep(0.0, 1.0, t))
		assert_almost_eq(hermite, smooth, Vector3(0.001, 0.001, 0.001))

func test_momentum_endpoints_are_still_exact() -> void:
	var v0 := Vector3(5.0, 0.0, 0.0)
	assert_almost_eq(ApproachRules.path_position(START, TARGET, 0.0, v0, 2.0), START,
			Vector3(0.001, 0.001, 0.001))
	assert_almost_eq(ApproachRules.path_position(START, TARGET, 1.0, v0, 2.0), TARGET,
			Vector3(0.001, 0.001, 0.001))

func test_momentum_launches_along_initial_velocity() -> void:
	# Start at origin, dot 10 m away in -Z, but moving +X at the whistle: the
	# early path should travel mostly along +X (carried momentum), not straight
	# at the dot — that's the anti-snap.
	var s := Vector3(0.0, 1.0, 0.0)
	var e := Vector3(0.0, 1.0, -10.0)
	var v0 := Vector3(5.0, 0.0, 0.0)
	var p: Vector3 = ApproachRules.path_position(s, e, 0.06, v0, 2.0)
	assert_gt(absf(p.x), absf(p.z), "early travel follows the launch velocity, not the chord")

func test_momentum_tangent_is_clamped_to_chord_no_overshoot() -> void:
	# A huge v0 straight at the dot must not overshoot past it (arrival stays at
	# rest); distance to the dot is monotonically non-increasing.
	var s := Vector3(0.0, 1.0, 0.0)
	var e := Vector3(0.0, 1.0, -5.0)
	var v0 := Vector3(0.0, 0.0, -50.0)  # 50 m/s straight in
	var prev: float = s.distance_to(e)
	for i: int in range(1, 11):
		var d: float = ApproachRules.path_position(s, e, i / 10.0, v0, 2.0).distance_to(e)
		assert_true(d <= prev + 0.0001, "no overshoot past the dot at step %d" % i)
		prev = d

# ── facing_along ─────────────────────────────────────────────────────────────

func test_facing_along_early_holds_travel_dir() -> void:
	var travel := Vector2(1.0, 0.0)
	assert_almost_eq(ApproachRules.facing_along(travel, 0.1, Vector2(0.0, -1.0)),
			travel, Vector2(0.001, 0.001))

func test_facing_along_end_is_settle() -> void:
	var settle := Vector2(0.0, -1.0)
	assert_almost_eq(ApproachRules.facing_along(Vector2(1.0, 0.0), 1.0, settle), settle,
			Vector2(0.001, 0.001))

func test_facing_along_stationary_returns_settle() -> void:
	var settle := Vector2(0.0, 1.0)
	assert_eq(ApproachRules.facing_along(Vector2.ZERO, 0.3, settle), settle)

# ── path_facing ──────────────────────────────────────────────────────────────

func test_facing_early_points_along_travel() -> void:
	var travel: Vector2 = Vector2(TARGET.x - START.x, TARGET.z - START.z).normalized()
	var facing: Vector2 = ApproachRules.path_facing(START, TARGET, 0.1, Vector2(0.0, -1.0))
	assert_almost_eq(facing, travel, Vector2(0.001, 0.001))

func test_facing_at_end_is_settle_facing() -> void:
	var settle: Vector2 = Vector2(0.0, -1.0)
	assert_almost_eq(ApproachRules.path_facing(START, TARGET, 1.0, settle), settle,
			Vector2(0.001, 0.001))

func test_facing_is_normalized_through_the_settle_blend() -> void:
	var settle: Vector2 = Vector2(0.0, -1.0)
	for i: int in range(0, 11):
		var f: Vector2 = ApproachRules.path_facing(START, TARGET, i / 10.0, settle)
		assert_almost_eq(f.length(), 1.0, 0.001)

func test_facing_stationary_path_returns_settle() -> void:
	# start == target: no travel direction, hold the squared-up dot facing.
	var settle: Vector2 = Vector2(0.0, 1.0)
	assert_eq(ApproachRules.path_facing(TARGET, TARGET, 0.3, settle), settle)

func test_facing_opposite_travel_and_settle_snaps_to_settle() -> void:
	# travel_dir == +Z, settle == -Z: the blend passes through ~zero; the rule
	# must return a usable (settle) vector, never a zero facing.
	var s: Vector3 = Vector3(0.0, 1.0, -4.0)
	var e: Vector3 = Vector3(0.0, 1.0, 0.0)   # travel = +Z
	var settle: Vector2 = Vector2(0.0, -1.0)  # opposite
	var f: Vector2 = ApproachRules.path_facing(s, e, 0.86, settle)  # near the crossover
	assert_almost_eq(f.length(), 1.0, 0.001)
