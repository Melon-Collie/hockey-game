extends GutTest

# XGBaseline — the public-style (location + angle + type) xG model, and the
# head-to-head against the goalie-aware geometric model.
#
# The anchors below are the NHL aggregates the coefficients were solved to
# reproduce; they're what makes this a usable BASELINE rather than another
# hand-shaped curve. The comparison test prints both models over the same shots
# so the divergence is visible rather than argued about.

const GOAL_Z: float = -GameRules.GOAL_LINE_Z   # team 0 attacks -Z


# Distance straight out from the goal mouth, centred.
func _centred(dist: float) -> float:
	return XGBaseline.for_shot(0.0, GOAL_Z + dist, 0, ShotEvent.ShotType.SHOT)


func test_in_tight_anchor() -> void:
	assert_almost_eq(_centred(3.0), 0.40, 0.06,
			"3 m centred ≈ 0.40 (NHL in-tight aggregate)")


func test_mid_slot_anchor() -> void:
	assert_almost_eq(_centred(8.0), 0.12, 0.05,
			"8 m centred ≈ 0.12 (mid-slot)")


func test_point_shot_anchor() -> void:
	assert_almost_eq(_centred(20.0), 0.03, 0.02,
			"20 m centred ≈ 0.03 (point shot)")


func test_value_falls_with_distance() -> void:
	var prev: float = 1.0
	for d: float in [1.0, 3.0, 6.0, 10.0, 15.0, 22.0]:
		var v: float = _centred(d)
		assert_lt(v, prev, "xG falls monotonically with distance (at %.0f m)" % d)
		prev = v


func test_angle_costs_value() -> void:
	# Same distance, straight on vs a sharp angle off the post.
	var straight: float = XGBaseline.for_shot(0.0, GOAL_Z + 8.0, 0, ShotEvent.ShotType.SHOT)
	var sharp: float = XGBaseline.for_shot(8.0, GOAL_Z + 2.0, 0, ShotEvent.ShotType.SHOT)
	assert_lt(sharp, straight, "a sharp-angle look is worth less than straight on")


func test_sixty_degrees_roughly_halves() -> void:
	# 60° off-centre at ~8 m: along = 4, across = 6.93.
	var straight: float = _centred(8.0)
	var angled: float = XGBaseline.for_shot(6.93, GOAL_Z + 4.0, 0, ShotEvent.ShotType.SHOT)
	assert_almost_eq(angled / straight, 0.5, 0.22,
			"60° off-centre is roughly half value")


func test_shot_type_bumps_value() -> void:
	var plain: float = XGBaseline.for_shot(0.0, GOAL_Z + 6.0, 0, ShotEvent.ShotType.SHOT)
	var one_t: float = XGBaseline.for_shot(0.0, GOAL_Z + 6.0, 0, ShotEvent.ShotType.ONE_TIMER)
	var tip: float = XGBaseline.for_shot(0.0, GOAL_Z + 6.0, 0, ShotEvent.ShotType.TIP)
	assert_gt(one_t, plain, "a one-timer is worth more than a plain shot")
	assert_gt(tip, one_t, "a tip is worth more still")


func test_team_one_attacks_the_other_end() -> void:
	# The mirrored shot for team 1 must value identically.
	var t0: float = XGBaseline.for_shot(1.0, GOAL_Z + 6.0, 0, ShotEvent.ShotType.SHOT)
	var t1: float = XGBaseline.for_shot(1.0, -GOAL_Z - 6.0, 1, ShotEvent.ShotType.SHOT)
	assert_almost_eq(t0, t1, 0.0001, "the model is end-agnostic")


func test_bounded() -> void:
	for d: float in [0.1, 0.5, 2.0, 30.0, 55.0]:
		var v: float = _centred(d)
		assert_between(v, 0.0, 1.0, "bounded at %.1f m" % d)


# ── The comparison: same shots, both models ─────────────────────────────────

func test_print_head_to_head_vs_geometric() -> void:
	# The geometric model is evaluated against a SET, squared goalie playing his
	# depth — i.e. the honest "nobody is beaten yet" case. Where it diverges most
	# from the baseline is exactly where it conditions on a goalie already moved.
	gut.p("  dist   baseline    geometric(set goalie)")
	var speed: float = GameRules.DEFAULT_WRISTER_POWER_MAX_M_S
	var goal := Vector3(0.0, 0.0, GOAL_Z)
	var base_sum: float = 0.0
	var geo_sum: float = 0.0
	for d: float in [2.0, 3.0, 5.0, 8.0, 11.0, 15.0, 20.0]:
		var shooter := Vector3(0.0, 0.0, GOAL_Z + d)
		var goalie := Vector3(0.0, 0.0, GOAL_Z + minf(1.3, d * 0.4))
		var base: float = _centred(d)
		var geo: float = AIActionScoring.expected_goals(
				shooter, goal, goalie, GameRules.NET_HALF_WIDTH, speed)
		base_sum += base
		geo_sum += geo
		gut.p("  %5.0f m   %.3f       %.3f" % [d, base, geo])
	gut.p("  SUM        %.2f        %.2f" % [base_sum, geo_sum])
	assert_gt(base_sum, 0.0, "baseline produced values")


func test_print_head_to_head_vs_beaten_goalie() -> void:
	# THE divergence. Same shots, but the goalie is pulled off his line — the
	# state a forehand-backhand deke creates. The baseline can't see it (a shot
	# from 6 m is a shot from 6 m); the geometric model prices the wide-open net
	# as if the shot were then trivial to finish. The gap here is the missing
	# execution term: getting the goalie moving is step one, burying it is step
	# two, and only the baseline is currently pricing both.
	gut.p("  dist   baseline    geometric(beaten goalie)   ratio")
	var speed: float = GameRules.DEFAULT_WRISTER_POWER_MAX_M_S
	var goal := Vector3(0.0, 0.0, GOAL_Z)
	for d: float in [3.0, 5.0, 8.0, 11.0]:
		var shooter := Vector3(0.0, 0.0, GOAL_Z + d)
		var goalie := Vector3(0.9, 0.0, GOAL_Z + 0.6)   # slid off, mid-recovery
		var base: float = _centred(d)
		var geo: float = AIActionScoring.expected_goals(
				shooter, goal, goalie, GameRules.NET_HALF_WIDTH, speed)
		gut.p("  %5.0f m   %.3f       %.3f                   %.1fx"
				% [d, base, geo, geo / maxf(base, 0.001)])
	pass_test("printed")
