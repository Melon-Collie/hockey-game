extends GutTest

# AIThreatAssignment — pure man-on-threat partition of backline defenders to
# the carrier's potential receivers. Covers:
#   - no-doubling (each defender a distinct man),
#   - value priority (high-value man gets the closer defender),
#   - odd-man rush (cover the most dangerous, concede the least),
#   - hysteresis (marginal change doesn't flip; a clear change does),
#   - degenerate (no men / no defenders),
#   - cover_anchor geometry (goal-side of the man).

const OUR_NET := Vector3(0.0, 0.0, 26.65)


func _vel_zero(peers: Array) -> Dictionary:
	var d: Dictionary = {}
	for p: int in peers:
		d[p] = Vector3.ZERO
	return d


# ── No doubling ───────────────────────────────────────────────────────────────

func test_two_defenders_two_men_distinct() -> void:
	var defenders: Array[int] = [1, 2]
	var men: Array[int] = [10, 20]
	# Defender 1 sits by man 10; defender 2 by man 20.
	var dpos: Dictionary = {1: Vector3(-5, 0, 15), 2: Vector3(5, 0, 15)}
	var mpos: Dictionary = {10: Vector3(-5, 0, 18), 20: Vector3(5, 0, 18)}
	var mval: Dictionary = {10: 0.5, 20: 0.5}
	var out: Dictionary = AIThreatAssignment.assign(
			defenders, dpos, _vel_zero(defenders), men, mpos, mval, OUR_NET, {})
	assert_eq(out.size(), 2, "both defenders assigned")
	assert_ne(out[1], out[2], "defenders take distinct men")
	assert_eq(out[1], 10, "nearer defender 1 covers man 10")
	assert_eq(out[2], 20, "nearer defender 2 covers man 20")


# ── Value priority ──────────────────────────────────────────────────────────

func test_high_value_man_gets_closer_defender() -> void:
	# Defender 1 is close to BOTH men; defender 2 is far. Man 20 is the
	# dangerous one. Maximizing value×reach puts the close defender (1) on
	# the high-value man (20) and the far defender (2) on the cheap man (10).
	var defenders: Array[int] = [1, 2]
	var men: Array[int] = [10, 20]
	var dpos: Dictionary = {1: Vector3(0, 0, 17), 2: Vector3(0, 0, 0)}
	var mpos: Dictionary = {10: Vector3(-4, 0, 19), 20: Vector3(4, 0, 19)}
	var mval: Dictionary = {10: 0.1, 20: 0.9}
	var out: Dictionary = AIThreatAssignment.assign(
			defenders, dpos, _vel_zero(defenders), men, mpos, mval, OUR_NET, {})
	assert_eq(out[1], 20, "close defender takes the dangerous man")
	assert_eq(out[2], 10, "far defender takes the cheap man")


# ── Odd-man rush: concede the least dangerous ──────────────────────────────

func test_outnumbered_covers_most_dangerous_concedes_least() -> void:
	# Two defenders, three men, all equally reachable (both defenders at the
	# same spot, men equidistant) so VALUE alone decides. The two highest-value
	# men are covered; the lowest-value man is conceded.
	var defenders: Array[int] = [1, 2]
	var men: Array[int] = [10, 20, 30]
	var dpos: Dictionary = {1: Vector3(0, 0, 20), 2: Vector3(0, 0, 20)}
	var mpos: Dictionary = {
		10: Vector3(0, 0, 16),    # lowest value
		20: Vector3(4, 0, 18),
		30: Vector3(-4, 0, 18),
	}
	var mval: Dictionary = {10: 0.1, 20: 0.6, 30: 0.9}
	var out: Dictionary = AIThreatAssignment.assign(
			defenders, dpos, _vel_zero(defenders), men, mpos, mval, OUR_NET, {})
	assert_eq(out.size(), 2, "two defenders cover two men")
	var covered: Array = out.values()
	assert_false(covered.has(10), "least dangerous man (10) is conceded")
	assert_true(covered.has(20) and covered.has(30),
			"both dangerous men covered; got %s" % str(covered))


# ── Hysteresis ────────────────────────────────────────────────────────────

func test_hysteresis_keeps_marginal_prev() -> void:
	# Symmetric geometry: 1->10/2->20 and 1->20/2->10 score nearly equally.
	# With prev = {1:20, 2:10}, a marginal fresh best must NOT flip it.
	var defenders: Array[int] = [1, 2]
	var men: Array[int] = [10, 20]
	var dpos: Dictionary = {1: Vector3(0, 0, 15), 2: Vector3(0, 0, 15)}
	var mpos: Dictionary = {10: Vector3(-3, 0, 18), 20: Vector3(3, 0, 18)}
	var mval: Dictionary = {10: 0.5, 20: 0.5}
	var prev: Dictionary = {1: 20, 2: 10}
	var out: Dictionary = AIThreatAssignment.assign(
			defenders, dpos, _vel_zero(defenders), men, mpos, mval, OUR_NET, prev)
	assert_eq(out[1], 20, "marginal change retains prev assignment")
	assert_eq(out[2], 10, "marginal change retains prev assignment")


func test_hysteresis_yields_to_clear_improvement() -> void:
	# Defender 1 right on man 10, defender 2 right on man 20 — the {1:10,2:20}
	# matching is clearly better than the stale prev {1:20,2:10}, so it flips.
	var defenders: Array[int] = [1, 2]
	var men: Array[int] = [10, 20]
	var dpos: Dictionary = {1: Vector3(-6, 0, 18), 2: Vector3(6, 0, 18)}
	var mpos: Dictionary = {10: Vector3(-6, 0, 20), 20: Vector3(6, 0, 20)}
	var mval: Dictionary = {10: 0.5, 20: 0.5}
	var prev: Dictionary = {1: 20, 2: 10}
	var out: Dictionary = AIThreatAssignment.assign(
			defenders, dpos, _vel_zero(defenders), men, mpos, mval, OUR_NET, prev)
	assert_eq(out[1], 10, "clear improvement flips to the better matching")
	assert_eq(out[2], 20, "clear improvement flips to the better matching")


# ── Degenerate ────────────────────────────────────────────────────────────

func test_empty_inputs_yield_empty() -> void:
	var none: Array[int] = []
	var men: Array[int] = [10]
	assert_eq(AIThreatAssignment.assign(
			none, {}, {}, men, {10: Vector3.ZERO}, {10: 0.5}, OUR_NET, {}).size(),
			0, "no defenders → empty")
	var defs: Array[int] = [1]
	var no_men: Array[int] = []
	assert_eq(AIThreatAssignment.assign(
			defs, {1: Vector3.ZERO}, {1: Vector3.ZERO}, no_men, {}, {}, OUR_NET, {}).size(),
			0, "no men → empty")


# ── Cover anchor geometry ──────────────────────────────────────────────────

func test_cover_anchor_is_goal_side_of_man() -> void:
	var man := Vector3(5, 0, 10)
	var anchor: Vector3 = AIThreatAssignment.cover_anchor(man, OUR_NET)
	# Anchor is COVER_DEPTH_M from the man, toward our net.
	assert_almost_eq(man.distance_to(anchor),
			AIThreatAssignment.COVER_DEPTH_M, 0.001,
			"anchor sits COVER_DEPTH_M off the man")
	assert_lt(anchor.distance_to(OUR_NET), man.distance_to(OUR_NET),
			"anchor is closer to our net than the man (goal-side)")
