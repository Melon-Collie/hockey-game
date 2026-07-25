extends GutTest

# ── The xG contract ──────────────────────────────────────────────────────────
# expected_goals prices BOTH halves of beating a goalie:
#   xG = P(placement lands in the open window) + P(miss it) × P(goalie leaks)
# so this pins the structural properties that follow from that, plus a sanity
# band against the independent location-only model (XGBaseline).
#
# ── Why this no longer calibrates against shot_sim_harness ───────────────────
# It used to, and that was the bug. The harness's own header says to read
# RELATIVE deltas as more trustworthy than absolute rates, and tuning an
# absolute scale against it produced a model that ran ~3.6x hot in playtest
# (18.25 xG against 5 actual goals) — plus a non-monotonic curve with hard zeros
# in tight AND from the point. The harness also answers a different question: it
# measures a BOT firing with the bot's own uniform ±spread, which is
# self-consistent for the bot's decision model but is not "how likely is this
# chance to be finished by an arbitrary shooter."
#
# The real magnitude fit is against LOGGED GAME OUTCOMES (analytics plan §3.3) —
# Σ xG ≈ Σ goals, with the on-net fraction calibrating the release spread, since
# a game produces far more misses than goals. The shot_events table collects
# exactly that. Until enough games accumulate, these properties + the baseline
# band are what hold the model honest.


const SPEED: float = 33.0

# A const initializer can't reference another script's constant, so this is a var.
var GOAL := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)


func _nhw() -> float:
	return GameRules.NET_HALF_WIDTH


func _xg(shooter: Vector3, goalie: Vector3, spread: float) -> float:
	return AIActionScoring.expected_goals(shooter, GOAL, goalie, _nhw(), SPEED,
			0.0, -1.0, false, 0.0, false, 0.0, Vector4.INF, Vector4.INF, 1.0, spread)


func _settled() -> float:
	return AIActionScoring.xg_release_spread(false, 0.0)


func _awkward() -> float:  # backhand, in transition — the deke-and-shoot case
	return AIActionScoring.xg_release_spread(true, 7.0)


# ── Floor and ceiling: the false zeros are gone ──────────────────────────────

func test_hopeless_shot_floors_at_the_leak_not_zero() -> void:
	# A point shot at a square goalie: no window at all. It must still carry the
	# goalie-fallibility leak — real point shots score via screens, tips, and
	# rebounds. Returning 0.000 here is what made every 5v5 D-man shot worthless.
	var far := Vector3(0.0, 0.0, GOAL.z + 20.0)
	var squared := Vector3(0.0, 0.0, GOAL.z + 1.5)
	var xg: float = _xg(far, squared, _settled())
	assert_almost_eq(xg, AIActionScoring.XG_COVERED_LEAK, 0.02,
			"a covered shot floors at the leak, never at exactly zero")
	assert_gt(xg, 0.0, "never exactly zero")


func test_never_certain() -> void:
	var point_blank := Vector3(0.0, 0.0, GOAL.z + 1.5)
	var stranded := Vector3(_nhw() + 1.2, 0.0, GOAL.z + 0.2)
	assert_lte(_xg(point_blank, stranded, _settled()), AIActionScoring.XG_MAX,
			"even an open net is capped — you can still fan or hit iron")


func test_bounded_everywhere() -> void:
	for d: float in [1.0, 3.0, 6.0, 10.0, 16.0, 24.0]:
		for gx: float in [-1.2, 0.0, 0.9]:
			var xg: float = _xg(Vector3(0.0, 0.0, GOAL.z + d),
					Vector3(gx, 0.0, GOAL.z + 1.3), _settled())
			assert_between(xg, 0.0, AIActionScoring.XG_MAX, "bounded at d=%.0f gx=%.1f" % [d, gx])


# ── Execution: the half the old model gave away ─────────────────────────────

func test_wider_release_lowers_xg_monotonically() -> void:
	# Identical geometry, progressively harder release. This is the core fix:
	# an open net is not a goal until someone puts the puck in it.
	var shooter := Vector3(0.0, 0.0, GOAL.z + 6.0)
	var beaten := Vector3(0.9, 0.0, GOAL.z + 0.6)
	var prev: float = 1.0
	for spread: float in [0.05, 0.10, 0.18, 0.30, 0.50]:
		var xg: float = _xg(shooter, beaten, spread)
		assert_lt(xg, prev, "xG falls as the release gets wilder (σ=%.2f)" % spread)
		prev = xg


func test_deke_shot_is_worth_far_less_than_the_same_open_net_settled() -> void:
	# THE playtest case: a forehand-backhand in transition yawns the net open,
	# but the shot itself is brutal. Same window, different execution.
	var shooter := Vector3(0.0, 0.0, GOAL.z + 6.0)
	var beaten := Vector3(0.9, 0.0, GOAL.z + 0.6)
	var settled: float = _xg(shooter, beaten, _settled())
	var awkward: float = _xg(shooter, beaten, _awkward())
	assert_lt(awkward, settled * 0.7,
			"an awkward release off an open net is worth much less than a settled one")


func test_context_widens_the_release_but_skill_never_enters() -> void:
	var base: float = AIActionScoring.xg_release_spread(false, 0.0)
	assert_gt(AIActionScoring.xg_release_spread(true, 0.0), base, "a backhand is harder to place")
	assert_gt(AIActionScoring.xg_release_spread(false, 8.0), base, "shooting on the move is harder")
	assert_gt(AIActionScoring.xg_release_spread(true, 8.0), AIActionScoring.xg_release_spread(true, 0.0),
			"the two context terms compound")


# ── Geometry still drives the value ─────────────────────────────────────────

func test_more_open_net_is_worth_more() -> void:
	var shooter := Vector3(0.0, 0.0, GOAL.z + 6.0)
	var squared := Vector3(0.0, 0.0, GOAL.z + 1.5)
	var beaten := Vector3(0.9, 0.0, GOAL.z + 0.6)
	assert_gt(_xg(shooter, beaten, _settled()), _xg(shooter, squared, _settled()),
			"a beaten goalie is worth more than a square one")


# ── Sanity band against the independent location model ──────────────────────

func test_totals_are_within_a_sane_band_of_the_location_model() -> void:
	# Not equality — the two models answer different questions (ours is
	# conditional on the goalie's actual position, the baseline is marginal over
	# all goalie states, and the baseline is NHL-calibrated while Mitts is
	# arcade). But an order-of-magnitude gap means one of them is broken. Before
	# the execution term this ran ~7x on beaten-goalie shots.
	var settled: float = _settled()
	var awkward: float = _awkward()
	var geo_total: float = 0.0
	var base_total: float = 0.0
	for d: float in [3.0, 5.0, 8.0, 11.0, 15.0, 20.0]:
		var shooter := Vector3(0.0, 0.0, GOAL.z + d)
		var beaten := Vector3(0.9, 0.0, GOAL.z + 0.6)
		# Half the attempts settled, half out of a move — a plausible mix.
		geo_total += 0.5 * _xg(shooter, beaten, settled) \
				+ 0.5 * _xg(shooter, beaten, awkward)
		base_total += XGBaseline.for_shot(0.0, GOAL.z + d, 0, ShotEvent.ShotType.SHOT)
	var ratio: float = geo_total / maxf(base_total, 0.001)
	gut.p("  geometric %.2f vs baseline %.2f  (ratio %.2fx)"
			% [geo_total, base_total, ratio])
	assert_between(ratio, 0.5, 3.0,
			"the goalie-aware model stays within a sane band of the location model")
