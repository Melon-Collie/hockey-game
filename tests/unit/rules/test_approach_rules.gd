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
