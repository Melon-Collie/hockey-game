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


func _speed_caps(v: float) -> AISkaterCaps:
	var c := AISkaterCaps.new()
	c.max_speed = v
	return c


func test_faster_defender_takes_the_more_dangerous_man() -> void:
	# Two defenders at the same spot; two men equidistant from it (so distance
	# doesn't decide), one far more dangerous. Speed decides: the FAST defender's
	# higher reach multiplies the bigger threat value, so it's assigned the
	# dangerous man and the slow one takes the cheap man.
	var defenders: Array[int] = [1, 2]
	var men: Array[int] = [10, 20]
	var dpos: Dictionary = {1: Vector3(0, 0, 10), 2: Vector3(0, 0, 10)}
	var mpos: Dictionary = {10: Vector3(-6, 0, 15), 20: Vector3(6, 0, 15)}  # equidistant
	var mval: Dictionary = {10: 0.1, 20: 0.9}                               # 20 dangerous
	var caps: Dictionary = {1: _speed_caps(14.0), 2: _speed_caps(6.0)}
	var out: Dictionary = AIThreatAssignment.assign(
			defenders, dpos, _vel_zero(defenders), men, mpos, mval, OUR_NET, {}, caps)
	assert_eq(out[1], 20, "the faster defender covers the more dangerous man")
	assert_eq(out[2], 10, "the slower defender takes the cheap man")


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


# ── Net-front (house) override ─────────────────────────────────────────────

func test_house_override_covers_a_man_pure_matching_would_concede() -> void:
	# Odd-man: 2 defenders, 3 men. Man 10 is a lethal backdoor (high finish
	# danger) but a LOW pass value (contested feed lane). Men 20/30 are higher
	# pass value. Pure value×reach concedes the backdoor; the override pins it.
	var defenders: Array[int] = [1, 2]
	var men: Array[int] = [10, 20, 30]
	var dpos: Dictionary = {1: Vector3(0, 0, 20), 2: Vector3(0, 0, 20)}
	var mpos: Dictionary = {
		10: Vector3(0, 0, 25),    # backdoor, right on the net
		20: Vector3(5, 0, 18),
		30: Vector3(-5, 0, 18),
	}
	var mval: Dictionary = {10: 0.2, 20: 0.8, 30: 0.7}

	# Baseline (no danger supplied): backdoor 10 is conceded.
	var base: Dictionary = AIThreatAssignment.assign(
			defenders, dpos, _vel_zero(defenders), men, mpos, mval, OUR_NET, {})
	assert_false(base.values().has(10),
			"without the override, the low-value backdoor is conceded")

	# With finish danger on 10 above the bar: it's covered regardless.
	var mdanger: Dictionary = {10: 0.9, 20: 0.1, 30: 0.1}
	var out: Dictionary = AIThreatAssignment.assign(
			defenders, dpos, _vel_zero(defenders), men, mpos, mval, OUR_NET, {}, {}, mdanger)
	assert_true(out.values().has(10),
			"the net-front override covers the lethal backdoor man")
	assert_true(out.values().has(20),
			"the remaining defender still takes the higher-value perimeter man (20)")
	assert_false(out.values().has(30),
			"the lower-value perimeter man (30) is the one conceded now")


func test_house_override_off_below_the_danger_bar() -> void:
	# Same geometry, but no man clears NET_FRONT_DANGER_BAR → the override is a
	# no-op and the result matches pure value×reach matching.
	var defenders: Array[int] = [1, 2]
	var men: Array[int] = [10, 20]
	var dpos: Dictionary = {1: Vector3(0, 0, 17), 2: Vector3(0, 0, 0)}
	var mpos: Dictionary = {10: Vector3(-4, 0, 19), 20: Vector3(4, 0, 19)}
	var mval: Dictionary = {10: 0.1, 20: 0.9}
	var low_danger: Dictionary = {10: 0.2, 20: 0.3}   # both under 0.45
	var out: Dictionary = AIThreatAssignment.assign(
			defenders, dpos, _vel_zero(defenders), men, mpos, mval, OUR_NET, {}, {}, low_danger)
	assert_eq(out[1], 20, "below the bar, the close defender still takes the high-value man")
	assert_eq(out[2], 10, "below the bar, the far defender takes the cheap man")


func test_house_marker_is_sticky_across_ticks() -> void:
	# House man 10 (lethal). Defender 1 is closer to his anchor than 2, so a
	# FRESH pin picks 1. But if 2 covered him last tick, the pin stays on 2 —
	# no thrash over which body owns the net-front.
	var defenders: Array[int] = [1, 2]
	var men: Array[int] = [10, 20]
	var dpos: Dictionary = {1: Vector3(0, 0, 24), 2: Vector3(0, 0, 8)}
	var mpos: Dictionary = {10: Vector3(0, 0, 25), 20: Vector3(6, 0, 16)}
	var mval: Dictionary = {10: 0.3, 20: 0.5}
	var mdanger: Dictionary = {10: 0.9, 20: 0.1}

	# Fresh (no prev): the closer defender (1) is pinned to the house man.
	var fresh: Dictionary = AIThreatAssignment.assign(
			defenders, dpos, _vel_zero(defenders), men, mpos, mval, OUR_NET, {}, {}, mdanger)
	assert_eq(fresh[1], 10, "fresh pin picks the defender who reaches the net-front soonest")

	# Incumbent 2 held the house last tick → it keeps him despite 1 being closer.
	var prev: Dictionary = {2: 10, 1: 20}
	var sticky: Dictionary = AIThreatAssignment.assign(
			defenders, dpos, _vel_zero(defenders), men, mpos, mval, OUR_NET, prev, {}, mdanger)
	assert_eq(sticky[2], 10, "the incumbent keeps the net-front man (sticky)")
	assert_eq(sticky[1], 20, "the other defender takes the remaining man")


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


func test_cover_anchor_stays_in_front_of_the_goal_line() -> void:
	# A man AT/BEHIND the goal line (corner lurker, wraparound walker) must
	# not station his marker behind the line with him — the anchor is held a
	# buffer in front (front him at the post; the goalie's RVH owns the wrap).
	var man := Vector3(3.0, 0.0, 27.5)   # behind the +Z goal line
	var anchor: Vector3 = AIThreatAssignment.cover_anchor(man, OUR_NET)
	assert_lt(anchor.z, GameRules.GOAL_LINE_Z - 0.99,
			"anchor clamps a buffer in front of the goal line; got z=%f"
			% anchor.z)
