extends GutTest

# ── The xG calibration contract ──────────────────────────────────────────────
# expected_goals (the analytics stat) must TRACK the measured goal fraction of a
# reference shooter across the shot grid — the same shot-outcome instrument
# (shot_sim_harness) that calibrated open_net_danger. Unlike the bot's decision
# value, xG separates the geometry (best_open_angle at a sharp-hand spread) from a
# saturating calibration head (XG_ANGLE_HALF / XG_MAX); this pins that head so xG
# is a real probability, not a hand-set curve.
#
# Reference shooter: MEASURE_SPREAD — a moderately-accurate release (not the razor
# 0.01 the bot's own calibration uses), so the measured goal fraction is graded
# (a looser shooter misses tight windows) and xG has a gradient to track rather
# than a near-binary surface. Banding is loose by the same logic as the shot-value
# contract: both sides model the same goalie and knife-edge cells swing tens of
# percent; the teeth are the SHAPE — certain looks read high, dead looks read low,
# the transition tracks and sits at the right ranges.

const Sim := preload("res://tests/unit/ai/shot_sim_harness.gd")
const SAMPLES: int = 300
const SEED: int = 0x5EED
# The reference shooter whose finishing xG models. Documented feel choice.
const MEASURE_SPREAD: float = 0.04

# Loose bands (see header). Certain cells sit at/under the XG_MAX cap; dead cells
# near zero; transition tracks within tolerance.
const CERTAIN_MIN: float = 0.45
const DEAD_MAX: float = 0.25
const TRANSITION_TOL: float = 0.40

var _goal := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)


func _spots() -> Array:
	var spots: Array = []
	for dist: float in [4.0, 6.0, 8.0, 10.0, 12.0, 14.0, 16.0]:
		spots.append(Vector3(0.0, 0.0, _goal.z + dist))
	for dist: float in [6.0, 9.0, 12.0]:
		spots.append(Vector3(4.0, 0.0, _goal.z + dist))
	return spots


func _measured_goal_frac(shooter: Vector3, goalie: Vector3, unsettled: float) -> float:
	var aim: Vector3 = AIActionScoring.best_shot_aim(shooter, _goal, goalie,
			GameRules.NET_HALF_WIDTH, AIActionScoring.WRISTER_SHOT_SPEED_M_S,
			unsettled, -1.0, false, MEASURE_SPREAD)
	var loft: int = AIActionScoring.best_shot_loft(shooter, _goal, goalie,
			GameRules.NET_HALF_WIDTH, AIActionScoring.WRISTER_SHOT_SPEED_M_S,
			unsettled, -1.0, false, 0.0, false, MEASURE_SPREAD)
	var power_t: float = AIActionScoring.best_shot_power_t(shooter, _goal, goalie,
			GameRules.NET_HALF_WIDTH, AIActionScoring.WRISTER_SHOT_SPEED_M_S,
			unsettled, -1.0, false, 0.0, false, MEASURE_SPREAD)
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var goals: int = 0
	for _i: int in SAMPLES:
		var err: float = rng.randf_range(-MEASURE_SPREAD, MEASURE_SPREAD)
		if Sim.classify_shot(shooter, _goal, goalie, aim, loft, power_t,
				err, unsettled) == Sim.GOAL:
			goals += 1
	return float(goals) / float(SAMPLES)


func test_xg_tracks_measured_goal_fraction() -> void:
	var checked: int = 0
	for unsettled: float in [0.0, 0.25, 0.5]:
		for spot: Vector3 in _spots():
			var goalie: Vector3 = Sim.goalie_set_pos(spot, _goal)
			goalie.x = clampf(goalie.x + unsettled * Sim.CAUGHT_OFFSET_M,
					-GameRules.NET_HALF_WIDTH, GameRules.NET_HALF_WIDTH)
			var xg: float = AIActionScoring.expected_goals(
					spot, _goal, goalie, GameRules.NET_HALF_WIDTH,
					AIActionScoring.WRISTER_SHOT_SPEED_M_S, unsettled)
			var measured: float = _measured_goal_frac(spot, goalie, unsettled)
			var label: String = "(%.0f, %.1f m out, uns %.2f): xG %.3f vs measured %.2f" % [
					spot.x, spot.distance_to(_goal), unsettled, xg, measured]
			gut.p(label)
			checked += 1
			if measured >= 0.85:
				assert_gt(xg, CERTAIN_MIN, "near-certain cell reads high — " + label)
			elif measured <= 0.08:
				assert_lt(xg, DEAD_MAX, "near-dead cell reads low — " + label)
			else:
				assert_almost_eq(xg, measured, TRANSITION_TOL,
						"transition cell tracks — " + label)
	assert_gt(checked, 25, "the grid actually ran")
