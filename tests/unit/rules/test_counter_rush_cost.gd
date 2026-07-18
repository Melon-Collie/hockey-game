extends GutTest

# AIActionScoring.counter_rush_cost — the transition-exposure term (plan §6).
# Team 0 defends +Z. The canonical scene: our defenseman weighs a deep
# O-zone carry; the loss point is in THEIR end (where turnover_cost reads
# ~0) and the question is who beats the counter-rush home.

const NET_Z: float = 26.65
const OUR_NET := Vector3(0.0, 0.0, NET_Z)
const OUR_GOALIE := Vector3(0.0, 0.0, NET_Z - 0.6)
# A loss deep in the offensive zone.
const LOSS_POINT := Vector3(6.0, 0.0, -20.0)


func _cost(teammates: Array[Vector3], self_pos: Vector3,
		opponents: Array[Vector3], self_speed: float = 8.0) -> float:
	var opp_vels: Array[Vector3] = []
	var opp_caps: Array = []
	for _i: int in opponents.size():
		opp_vels.append(Vector3.ZERO)
		opp_caps.append(null)
	return AIActionScoring.counter_rush_cost(
			LOSS_POINT, 1.0, OUR_NET, OUR_GOALIE, GameRules.NET_HALF_WIDTH,
			teammates, self_pos, self_speed, opponents, opp_vels, opp_caps)


func test_local_turnover_cost_is_small_at_the_deep_loss() -> void:
	# The premise: the existing loss-point term reads SMALL for an O-zone
	# turnover (only position_potential's forward-progress residue) —
	# that's exactly why the counter term must exist.
	var no_defenders: Array[Vector3] = []
	var local: float = AIActionScoring.turnover_cost(
			LOSS_POINT, 1.0, OUR_NET, OUR_GOALIE, GameRules.NET_HALF_WIDTH,
			no_defenders)
	assert_lt(local, 0.2, "an O-zone loss point carries little local threat")


func test_one_up_one_back_is_cheap_both_deep_is_expensive() -> void:
	# THE calibration pin (plan §6): D1 weighs the deep carry with the
	# checker right on the strip point (that IS the loss scenario the
	# probability weights). With D2 holding the point — genuinely goal-side
	# with a head start on the counter — the exposure is a fraction of the
	# both-D-pinched scene, where the partner races the rush stride for
	# stride and covers nothing.
	var opponents: Array[Vector3] = [Vector3(6.0, 0.0, -19.5)]  # the checker
	var d1_deep := Vector3(6.0, 0.0, -20.0)
	var partner_home: Array[Vector3] = [Vector3(-5.0, 0.0, -8.3)]  # at the point
	var partner_deep: Array[Vector3] = [Vector3(-6.0, 0.0, -21.0)]
	var covered: float = _cost(partner_home, d1_deep, opponents)
	var exposed: float = _cost(partner_deep, d1_deep, opponents)
	assert_gt(exposed, 0.05, "an uncovered counter must carry real cost")
	assert_lt(covered, exposed * 0.6,
			"a partner holding the point collapses the exposure")


func test_a_fast_carrier_covers_himself() -> void:
	# Same scene, no teammates back — but a burner recovers in time where a
	# plodder can't. Speed buys activation freedom, straight from the model.
	var opponents: Array[Vector3] = [Vector3(0.0, 0.0, -6.0)]
	var nobody: Array[Vector3] = []
	var slow: float = _cost(nobody, LOSS_POINT, opponents, 5.5)
	var fast: float = _cost(nobody, LOSS_POINT, opponents, 12.0)
	assert_lt(fast, slow, "the faster carrier's own recovery discounts the counter")


func test_no_opponents_no_cost() -> void:
	var nobody: Array[Vector3] = []
	var opps: Array[Vector3] = []
	assert_eq(_cost(nobody, LOSS_POINT, opps), 0.0)


func test_zero_loss_prob_is_free() -> void:
	var opponents: Array[Vector3] = [Vector3(0.0, 0.0, -12.0)]
	var nobody: Array[Vector3] = []
	var opp_vels: Array[Vector3] = [Vector3.ZERO]
	var opp_caps: Array = [null]
	assert_eq(AIActionScoring.counter_rush_cost(
			LOSS_POINT, 0.0, OUR_NET, OUR_GOALIE, GameRules.NET_HALF_WIDTH,
			nobody, LOSS_POINT, 8.0, opponents, opp_vels, opp_caps), 0.0)


func test_sooner_counter_costs_more() -> void:
	# The cost decays over the counter's development time: an opponent
	# already on the loss point (the stripping defender) builds the rush
	# sooner — and prices higher — than one who must skate across the rink
	# to collect it first.
	var nobody: Array[Vector3] = []
	var at_strip: Array[Vector3] = [Vector3(6.0, 0.0, -19.0)]
	var across_rink: Array[Vector3] = [Vector3(-11.0, 0.0, 5.0)]
	var soon_cost: float = _cost(nobody, LOSS_POINT, at_strip, 5.5)
	var late_cost: float = _cost(nobody, LOSS_POINT, across_rink, 5.5)
	assert_gt(soon_cost, late_cost)
