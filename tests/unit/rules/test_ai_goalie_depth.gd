extends GutTest

# AIActionScoring.planned_goalie_depth — the planning keeper's radial depth.
#
# The planner used to hold the keeper at whatever depth he occupied when the
# read was taken. Because shot coverage is a tangent cone off his body, a
# frozen-out keeper appears to GROW as the shooter closes: a release from the
# doorstep against a keeper pinned at challenge depth reads as a fully covered
# net, so the whole in-zone gradient pointed away from the goal and the carrier
# bailed out (the "addicted to backpassing" report). These pin the retreat that
# was missing, and the retreat-only discipline that keeps it from re-pricing
# every settled look.

const GOAL := Vector3(0, 0, -GameRules.GOAL_LINE_Z)


func _keeper_at(depth: float) -> Vector3:
	return Vector3(0.0, 0.0, GOAL.z + depth)


func _puck_out(dist: float) -> Vector3:
	return Vector3(0.0, 0.0, GOAL.z + dist)


func before_each() -> void:
	AIActionScoring.set_goalie_profile(GoalieSkillProfile.hard())


# ── Retreat-only ────────────────────────────────────────────────────────────

func test_a_settled_read_leaves_the_keeper_exactly_where_he_is() -> void:
	# His live depth is replicated truth and is set by a lot the planner cannot
	# see (post seals, backdoor caps, recoveries). Nothing about a static puck
	# may move him, in either direction.
	for depth: float in [0.1, 0.6, 1.2, 1.75]:
		var d: float = AIActionScoring.planned_goalie_depth(
				_keeper_at(depth), GOAL, _puck_out(6.6), 0.3, 0.0)
		assert_almost_eq(d, depth, 0.0001,
				"a static read never moves the keeper's depth")


func test_the_planner_never_challenges_the_keeper_further_out() -> void:
	# A keeper sitting deep in his crease with the puck at chart-challenge range
	# must not be pushed out to the chart station — that would invent an
	# aggressive challenge the real keeper may already have declined.
	var d: float = AIActionScoring.planned_goalie_depth(
			_keeper_at(0.2), GOAL, _puck_out(6.0), 1.0, 8.0)
	assert_almost_eq(d, 0.2, 0.0001, "retreat-only: depth is never pushed out")


# ── The rush backflow ───────────────────────────────────────────────────────

func test_a_closing_carrier_backs_the_keeper_in() -> void:
	# Challenge depth, carrier driving to 3 m: the backflow curve wants him near
	# crease-bottom by then, and a second is plenty to get there.
	var d: float = AIActionScoring.planned_goalie_depth(
			_keeper_at(1.75), GOAL, _puck_out(3.0), 1.0, 6.0)
	assert_lt(d, 1.0, "a closing rush backs the keeper off his challenge")
	assert_gt(d, 0.0, "…but not through his own goal line")


func test_the_backflow_is_monotone_in_how_far_the_rush_has_come() -> void:
	var prev: float = INF
	for dist: float in [7.0, 5.0, 4.0, 3.0, 2.0]:
		var d: float = AIActionScoring.planned_goalie_depth(
				_keeper_at(1.75), GOAL, _puck_out(dist), 1.0, 6.0)
		assert_lt(d, prev, "deeper drive → deeper keeper (dist %.1f)" % dist)
		prev = d


func test_a_stalled_carrier_does_not_move_him() -> void:
	# Below the live keeper's rush_min_closing_speed he keeps the challenge and
	# makes the attacker come to him — a walk-in is not a rush.
	var d: float = AIActionScoring.planned_goalie_depth(
			_keeper_at(1.75), GOAL, _puck_out(3.0), 1.0, 0.5)
	assert_almost_eq(d, 1.75, 0.0001, "a stalled attacker earns no backflow")


func test_the_retreat_is_rate_bounded() -> void:
	# He skates the retreat; an instantaneous read cannot teleport him in.
	var d: float = AIActionScoring.planned_goalie_depth(
			_keeper_at(1.75), GOAL, _puck_out(2.0), 0.02, 6.0)
	assert_gt(d, 1.5, "a 20 ms window buys almost no depth change")


# ── What it buys the shooter ────────────────────────────────────────────────

func test_the_doorstep_drive_stops_reading_as_a_covered_net() -> void:
	# The bug, end to end. A keeper frozen out at challenge depth stands a
	# quarter-metre off a 2 m release and his tangent cone swallows the whole
	# net — the most dangerous ice on the rink scoring zero, which is what made
	# every drive lose to a back pass. With the retreat he is where a real
	# keeper would be and the corners are honestly open.
	var release: Vector3 = _puck_out(2.0)
	var opps: Array[Vector3] = []
	var frozen: float = AIActionScoring.score_shoot(
			release, GOAL, _keeper_at(1.75), GameRules.NET_HALF_WIDTH, opps,
			AIActionScoring.WRISTER_SHOT_SPEED_M_S)
	var retreated: float = AIActionScoring.score_shoot(
			release, GOAL,
			_keeper_at(AIActionScoring.planned_goalie_depth(
					_keeper_at(1.75), GOAL, release, 0.9, 6.0)),
			GameRules.NET_HALF_WIDTH, opps,
			AIActionScoring.WRISTER_SHOT_SPEED_M_S)
	assert_almost_eq(frozen, 0.0, 0.001,
			"the frozen keeper walls the doorstep completely")
	assert_gt(retreated, 0.3,
			"the retreating keeper concedes a real chance; got %f" % retreated)
