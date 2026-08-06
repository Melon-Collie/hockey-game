extends GutTest

# The rung picker reads POSTURE, not a fixed seam.
#
# The two-band model floored every elevated look at the standing pad seam
# (0.86 m), so against a keeper who was already down the whole 0.28–0.86 m
# band — over the flat pads, under or over his sealed hands — was invisible and
# the bot played FLAT. These pin that the floor now follows his actual pad top,
# and that nothing about the STANDING read moved.

const LEAGUE: Vector3 = AIActionScoring.DEFAULT_LOFT_TANS   # M92: 5.5 / 8.2 / 11 deg
const SEAM: float = GameRules.DEFAULT_GOALIE_PAD_TOP_SEAM_M
const FULL_PACE: float = 33.0


func _arrival(dist: float, tan_a: float) -> float:
	return dist * tan_a \
			- 9.8 * dist * dist * (1.0 + tan_a * tan_a) / (2.0 * FULL_PACE * FULL_PACE)


func _rung(dist: float, down: bool) -> int:
	return AIActionScoring._best_high_rung(dist, FULL_PACE, LEAGUE, -1.0, down)


func test_standing_keeper_read_is_unchanged() -> void:
	# The floor against an upright keeper IS the old constant, because that is
	# where his pad column ends. Every distance where a rung used to be legal
	# still resolves to one arriving above the seam.
	assert_almost_eq(GoalieAnatomy.pad_span(false).y, SEAM, 0.001,
			"standing pad top is the seam the old model hardcoded")
	for dist: float in [6.0, 8.0, 10.0, 12.0]:
		var level: int = _rung(dist, false)
		if level == ShotMechanics.ELEVATION_FLAT:
			continue
		var arrive: float = _arrival(dist, LEAGUE[level - ShotMechanics.ELEVATION_LOW])
		assert_gt(arrive, SEAM,
				"a rung chosen against a standing keeper still clears the seam")


func test_down_keeper_opens_the_over_pad_and_armpit_rungs() -> void:
	# The change. From the slot against a DOWN keeper the bot now has a rung
	# whose arc lands in the band his collapsed pads no longer defend.
	var dist: float = 6.0
	var level: int = _rung(dist, true)
	assert_ne(level, ShotMechanics.ELEVATION_FLAT,
			"a downed keeper leaves an elevated rung on from the slot")
	var arrive: float = _arrival(dist, LEAGUE[level - ShotMechanics.ELEVATION_LOW])
	assert_gt(arrive, GoalieAnatomy.pad_span(true).y,
			"the chosen rung clears his flat pads")
	assert_lt(arrive, AIActionScoring.HIGH_BAND_CEILING_M, "and stays under the bar")


func test_posture_changes_the_answer_in_tight() -> void:
	# In tight the league ladder cannot reach the standing seam at all, so the
	# old model played FLAT there no matter what the keeper did. Dropping him
	# has to change the read — that is the whole point of resolving height.
	var dist: float = 4.0
	assert_eq(_rung(dist, false), ShotMechanics.ELEVATION_FLAT,
			"nothing reaches the seam from 4 m, so a standing keeper closes it")
	assert_ne(_rung(dist, true), ShotMechanics.ELEVATION_FLAT,
			"but the same look against a downed keeper is an elevated shot")


func test_the_pick_is_the_least_covered_height() -> void:
	# Shape picks the rung: among the legal ones the bot takes the height where
	# the least of the keeper is in the way, not simply the highest arrival.
	var dist: float = 6.0
	var chosen: int = _rung(dist, true)
	var chosen_cover: float = GoalieAnatomy.structural_cover_half_width_at(
			_arrival(dist, LEAGUE[chosen - ShotMechanics.ELEVATION_LOW]), true)
	for i: int in 3:
		var arrive: float = _arrival(dist, LEAGUE[i])
		if arrive <= GoalieAnatomy.pad_span(true).y \
				or arrive > AIActionScoring.HIGH_BAND_CEILING_M:
			continue
		assert_lte(chosen_cover,
				GoalieAnatomy.structural_cover_half_width_at(arrive, true),
				"no legal rung is less covered than the one picked")


func test_a_sealed_low_hand_cannot_defend_the_armpit() -> void:
	# The race half. A keeper down with both hands at butterfly height has to
	# LIFT to meet a puck at the armpit, and over a slot-range flight he cannot
	# — so the cover there is structure only, far less than the splayed pads
	# he is credited with along the ice.
	var armpit: float = 0.70
	var hands := Vector4(-0.42, 0.44, 0.46, 0.49)   # butterfly glove / blocker
	var t_read: float = 0.18                        # ~6 m of flight
	var cover: float = AIActionScoring._cover_at_height(
			armpit, t_read, true, 1, hands, Vector4.INF)
	var ice: float = AIActionScoring._cover_at_height(
			0.0, t_read, true, 1, hands, Vector4.INF)
	assert_lt(cover, ice, "the armpit is barer than the ice he is sealing")
