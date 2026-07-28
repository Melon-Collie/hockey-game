extends GutTest

# AIShotValue — the decision layer's single value seam. These pin the
# PROPERTIES the model must have for a utility argmax to be able to steer on
# it, not the numbers it currently produces: the numbers are knowingly an
# approximation until the goalie is retuned, but a surface that is
# non-monotone, unbounded, or indifferent to displacement is broken whatever
# the goalie does.

const GOAL_Z: float = -GameRules.GOAL_LINE_Z
var GOAL := Vector3(0.0, 0.0, GOAL_Z)


func _spot(x: float, fwd: float) -> Vector3:
	return Vector3(x, 0.0, GOAL_Z + fwd)


func _v(x: float, fwd: float, disp: float = 0.0) -> float:
	return AIShotValue.for_release(_spot(x, fwd), GOAL, disp)


# ── The structural claim: this IS the public model plus one feature ──────────
func test_zero_displacement_is_exactly_the_public_baseline() -> void:
	for x: float in [0.0, 3.0, 6.0]:
		for fwd: float in [2.0, 5.0, 10.0, 18.0]:
			var spot: Vector3 = _spot(x, fwd)
			assert_almost_eq(
					AIShotValue.for_release(spot, GOAL, 0.0),
					XGBaseline.for_shot(spot.x, spot.z, 0, ShotEvent.ShotType.SHOT),
					0.000001,
					"at zero displacement the model must BE XGBaseline (%.0f, %.0f)"
							% [x, fwd])


func test_shot_type_bumps_pass_through() -> void:
	var spot: Vector3 = _spot(0.0, 6.0)
	assert_gt(AIShotValue.for_release(spot, GOAL, 0.0,
					ShotEvent.ShotType.ONE_TIMER),
			AIShotValue.for_release(spot, GOAL, 0.0, ShotEvent.ShotType.SHOT),
			"a one-timer carries the baseline's bump through the seam")


# ── Monotonicity: the properties an argmax needs ─────────────────────────────
func test_closer_is_better_at_every_angle() -> void:
	for x: float in [0.0, 2.0, 5.0]:
		var prev: float = INF
		for fwd: float in [2.0, 4.0, 6.0, 9.0, 13.0, 18.0]:
			var v: float = _v(x, fwd)
			assert_lt(v, prev, "value must fall with range (x=%.0f, %.0f m)"
					% [x, fwd])
			prev = v


func test_straighter_is_better_at_every_range() -> void:
	for fwd: float in [3.0, 6.0, 12.0]:
		var prev: float = INF
		for x: float in [0.0, 2.0, 4.0, 7.0]:
			var v: float = _v(x, fwd)
			assert_lt(v, prev, "value must fall with angle (%.0f m, x=%.0f)"
					% [fwd, x])
			prev = v


func test_displacing_the_keeper_always_helps() -> void:
	for x: float in [0.0, 3.0]:
		for fwd: float in [4.0, 8.0, 14.0]:
			var prev: float = -INF
			for disp: float in [0.0, 0.2, 0.5, 0.9]:
				var v: float = _v(x, fwd, disp)
				assert_gt(v, prev,
						"displacement must raise value (x=%.0f, %.0f m, d=%.1f)"
								% [x, fwd, disp])
				prev = v


# The specific thing the old currency could not express, and the reason this
# feature exists at all: there must be REAL headroom above a set keeper, or
# moving him buys nothing and the argmax falls through to tie-breakers.
func test_a_moved_keeper_beats_a_set_one_by_a_wide_margin() -> void:
	var set_v: float = _v(0.0, 6.0, 0.0)
	var moved: float = _v(0.0, 6.0, 0.85)
	assert_gt(moved, set_v * 2.0,
			"beating him to one side must be worth multiples of a set look (%.3f vs %.3f)"
					% [moved, set_v])


func test_displacement_saturates_rather_than_running_away() -> void:
	var at_post: float = _v(0.0, 6.0, AIShotValue.MAX_USEFUL_DISPLACEMENT_M)
	var absurd: float = _v(0.0, 6.0, 25.0)
	assert_almost_eq(absurd, at_post, 0.000001,
			"displacement past the post buys nothing more — the mouth is finite")


# ── Bounds and guards ────────────────────────────────────────────────────────
func test_bounded_everywhere() -> void:
	for x: float in [0.0, 4.0, 9.0, 20.0]:
		for fwd: float in [0.3, 1.0, 5.0, 15.0, 40.0]:
			for disp: float in [0.0, 0.9]:
				var v: float = _v(x, fwd, disp)
				assert_between(v, 0.0, 1.0,
						"bounded at (%.0f, %.1f, d=%.1f)" % [x, fwd, disp])


func test_no_shot_from_on_or_behind_the_goal_line() -> void:
	assert_eq(AIShotValue.for_release(_spot(0.0, 0.0), GOAL, 0.9), 0.0,
			"on the goal line there is no shot")
	assert_eq(AIShotValue.for_release(_spot(1.0, -2.0), GOAL, 0.9), 0.0,
			"behind the net there is no shot, however displaced he is")


func test_works_for_the_other_net() -> void:
	var far_goal := Vector3(0.0, 0.0, GameRules.GOAL_LINE_Z)
	var a: float = AIShotValue.for_release(
			Vector3(0.0, 0.0, GameRules.GOAL_LINE_Z - 6.0), far_goal, 0.4)
	var b: float = _v(0.0, 6.0, 0.4)
	assert_almost_eq(a, b, 0.000001, "the model is net-symmetric")


# ── The displacement measurement itself ──────────────────────────────────────
func test_a_set_keeper_on_the_shot_line_has_no_deficit() -> void:
	var release: Vector3 = _spot(0.0, 7.0)
	var keeper := Vector3(0.0, 0.0, GOAL_Z + 1.5)
	assert_almost_eq(AIShotValue.displacement_deficit_m(
			keeper, GOAL, release, 0.4), 0.0, 0.001,
			"already square on a straight-on shot — nothing to make up")


func test_more_time_lets_him_close_the_deficit() -> void:
	var release: Vector3 = _spot(-4.0, 5.0)
	var keeper := Vector3(0.7, 0.0, GOAL_Z + 1.5)
	var snap: float = AIShotValue.displacement_deficit_m(
			keeper, GOAL, release, 0.15)
	var slow: float = AIShotValue.displacement_deficit_m(
			keeper, GOAL, release, 1.2)
	assert_gt(snap, slow,
			"a quick release leaves more deficit than a slow one (%.3f vs %.3f)"
					% [snap, slow])
	assert_almost_eq(slow, 0.0, 0.001,
			"given a second-plus he re-squares completely")


func test_deficit_never_negative() -> void:
	var release: Vector3 = _spot(0.0, 9.0)
	var keeper := Vector3(0.0, 0.0, GOAL_Z + 1.5)
	assert_eq(AIShotValue.displacement_deficit_m(keeper, GOAL, release, 3.0),
			0.0, "a keeper with all the time in the world is set, not negative")
