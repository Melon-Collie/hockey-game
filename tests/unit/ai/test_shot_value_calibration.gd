extends GutTest

# ── The shot-value calibration contract ──────────────────────────────────────
# score_shoot's value IS the make probability of firing at the best hole — so
# it must TRACK the measured goal fraction of actually firing, across shooter
# range × goalie state, against the shot-outcome instrument (shot_sim_harness:
# the goalie assembled from the live controller's own pose anatomy, reaction
# skeleton, drop and push kinematics, with the save race evaluated at his
# body's depth plane). This is the same two-sided method that calibrated
# time_to_arrive: the estimator is pinned to the measurement, so every
# consumer (the carry compete, the pass EVs, the threat surfaces) inherits
# honest magnitudes — the fix for the O-zone value-flatness Known Issue,
# where an in-tight certain goal priced 0.10 and "lose it at their doorstep"
# out-competed real plays.
#
# Banding: cells the instrument calls near-certain (≥95% goals) must read
# ≥ CERTAIN_MIN; near-dead cells (≤5%) must read ≤ DEAD_MAX; transition
# cells track within TRANSITION_TOL. Deliberately loose bands — both sides
# are models of the same live goalie, and knife-edge cells (a reach edge vs
# an aim point separated by centimetres) legitimately swing tens of percent
# on either side; the contract pins the SHAPE of the surface (where value
# saturates, where it dies, that the transition is placed right), not
# per-cell decimals.

const Sim := preload("res://tests/unit/ai/shot_sim_harness.gd")
const SAMPLES: int = 300
const SEED: int = 0x5EED

# Loose by design (see above): the knife cells — a mid-drop pad sweep vs a
# rising arc, windows about two puck-widths wide — sit at both models'
# fidelity boundary, where centimetres swing tens of percent. The contract's
# teeth are the SURFACE: dead cells stay dead, certain cells stay first-class,
# and the transition sits at the right ranges.
const CERTAIN_MIN: float = 0.55
const DEAD_MAX: float = 0.20
const TRANSITION_TOL: float = 0.55

var _goal := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)


# Frontal + moderate-angle spots. The extreme-wide band (|x| ≳ 6) is excluded
# on purpose: there the instrument's flat lateral-offset save model is the
# weaker geometry (score_shoot's body-disc tangent cone is what fixed the
# bad-angle phantom fires), so it can't serve as the reference.
func _spots() -> Array:
	var spots: Array = []
	for dist: float in [4.0, 6.0, 8.0, 10.0, 12.0, 14.0, 16.0, 18.0]:
		spots.append(Vector3(0.0, 0.0, _goal.z + dist))
	for dist: float in [6.0, 9.0, 12.0]:
		spots.append(Vector3(4.0, 0.0, _goal.z + dist))
	return spots


func _measured_goal_frac(shooter: Vector3, goalie: Vector3, unsettled: float,
		spread: float) -> float:
	var aim: Vector3 = AIActionScoring.best_shot_aim(shooter, _goal, goalie,
			GameRules.NET_HALF_WIDTH, AIActionScoring.WRISTER_SHOT_SPEED_M_S,
			unsettled, -1.0, false, spread)
	var loft: int = AIActionScoring.best_shot_loft(shooter, _goal, goalie,
			GameRules.NET_HALF_WIDTH, AIActionScoring.WRISTER_SHOT_SPEED_M_S,
			unsettled, -1.0, false, 0.0, false, spread)
	var power_t: float = AIActionScoring.best_shot_power_t(shooter, _goal, goalie,
			GameRules.NET_HALF_WIDTH, AIActionScoring.WRISTER_SHOT_SPEED_M_S,
			unsettled, -1.0, false, 0.0, false, spread)
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var goals: int = 0
	for _i: int in SAMPLES:
		var err: float = rng.randf_range(-spread, spread)
		if Sim.classify_shot(shooter, _goal, goalie, aim, loft, power_t,
				err, unsettled) == Sim.GOAL:
			goals += 1
	return float(goals) / float(SAMPLES)


func test_shot_value_tracks_measured_goal_fraction() -> void:
	var spread: float = BotSkillProfile.hard().shot_aim_error_rad
	var checked: int = 0
	for unsettled: float in [0.0, 0.25, 0.5]:
		for spot: Vector3 in _spots():
			var goalie: Vector3 = Sim.goalie_set_pos(spot, _goal)
			# Caught-moving displacement, mirroring the instrument's model.
			goalie.x = clampf(goalie.x + unsettled * Sim.CAUGHT_OFFSET_M,
					-GameRules.NET_HALF_WIDTH, GameRules.NET_HALF_WIDTH)
			var value: float = AIActionScoring.score_shoot(
					spot, _goal, goalie, GameRules.NET_HALF_WIDTH, [],
					AIActionScoring.WRISTER_SHOT_SPEED_M_S, unsettled, [],
					-1.0, false, 0.0, false, spread)
			var measured: float = _measured_goal_frac(spot, goalie, unsettled, spread)
			var label: String = "(%.0f, %.1f m out, unsettled %.2f): value %.3f vs measured %.2f" % [
					spot.x, spot.distance_to(_goal), unsettled, value, measured]
			checked += 1
			if measured >= 0.95:
				assert_gt(value, CERTAIN_MIN, "near-certain cell reads high — " + label)
			elif measured <= 0.05:
				assert_lt(value, DEAD_MAX, "near-dead cell reads low — " + label)
			else:
				assert_almost_eq(value, measured, TRANSITION_TOL,
						"transition cell tracks — " + label)
	assert_gt(checked, 30, "the grid actually ran")


func test_value_surface_is_not_flat_through_the_mid_slot() -> void:
	# The regression this whole calibration exists to prevent: a goalie who
	# has been MOVED (screened feed, cross-seam, mid-carry displacement) at
	# mid-slot range must leave a first-class chance, and an in-tight clean
	# look must read near-certain — the old ×gain currency compressed both
	# to ≈0.1 and the carry argmax degenerated to cost-minimization.
	var spread: float = BotSkillProfile.hard().shot_aim_error_rad
	var in_tight := Vector3(0.0, 0.0, _goal.z + 5.0)
	var tight_goalie: Vector3 = Sim.goalie_set_pos(in_tight, _goal)
	assert_gt(AIActionScoring.score_shoot(
			in_tight, _goal, tight_goalie, GameRules.NET_HALF_WIDTH, [],
			AIActionScoring.WRISTER_SHOT_SPEED_M_S, 0.0, [],
			-1.0, false, 0.0, false, spread), 0.9,
			"an in-tight clean look vs a standing set goalie is near-certain")
	var mid := Vector3(0.0, 0.0, _goal.z + 10.0)
	var moved_goalie: Vector3 = Sim.goalie_set_pos(mid, _goal) + Vector3(0.5, 0.0, 0.0)
	assert_gt(AIActionScoring.score_shoot(
			mid, _goal, moved_goalie, GameRules.NET_HALF_WIDTH, [],
			AIActionScoring.WRISTER_SHOT_SPEED_M_S, 0.5, [],
			-1.0, false, 0.0, false, spread), 0.5,
			"a mid-slot look at a displaced, caught-moving goalie is a real chance")
	var point := Vector3(0.0, 0.0, _goal.z + 18.0)
	var set_goalie: Vector3 = Sim.goalie_set_pos(point, _goal)
	assert_lt(AIActionScoring.score_shoot(
			point, _goal, set_goalie, GameRules.NET_HALF_WIDTH, [],
			AIActionScoring.WRISTER_SHOT_SPEED_M_S, 0.0, [],
			-1.0, false, 0.0, false, spread), 0.05,
			"a clean point shot at a set goalie stays a non-chance")


# ── Pose-fed calibration (hole-model v3) ─────────────────────────────────────
# The pose path must track the same measured surface: READY hands parked at
# the stance edges are the same goalie the instrument models, so feeding the
# replicated-pose read (instead of the declared band constants) must
# reproduce the calibration bands. GOAL is at −z here → net_dx = −local_x
# (GoalieNetworkState.hands_read's mirror): READY glove local (−0.42, 0.90),
# blocker (0.44, 0.86) — GoalieBodyConfigBuilder's stance.
const HANDS_READY_NEG_Z := Vector4(0.42, 0.90, -0.44, 0.86)


func _measured_goal_frac_posed(shooter: Vector3, goalie: Vector3,
		unsettled: float, spread: float, hands: Vector4) -> float:
	var aim: Vector3 = AIActionScoring.best_shot_aim(shooter, _goal, goalie,
			GameRules.NET_HALF_WIDTH, AIActionScoring.WRISTER_SHOT_SPEED_M_S,
			unsettled, -1.0, false, spread, 0.0, false, 0.0, hands)
	var loft: int = AIActionScoring.best_shot_loft(shooter, _goal, goalie,
			GameRules.NET_HALF_WIDTH, AIActionScoring.WRISTER_SHOT_SPEED_M_S,
			unsettled, -1.0, false, 0.0, false, spread, 0.0, hands)
	var power_t: float = AIActionScoring.best_shot_power_t(shooter, _goal, goalie,
			GameRules.NET_HALF_WIDTH, AIActionScoring.WRISTER_SHOT_SPEED_M_S,
			unsettled, -1.0, false, 0.0, false, spread, 0.0, hands)
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var goals: int = 0
	for _i: int in SAMPLES:
		var err: float = rng.randf_range(-spread, spread)
		if Sim.classify_shot(shooter, _goal, goalie, aim, loft, power_t,
				err, unsettled) == Sim.GOAL:
			goals += 1
	return float(goals) / float(SAMPLES)


func test_pose_fed_value_tracks_the_same_surface() -> void:
	var spread: float = BotSkillProfile.hard().shot_aim_error_rad
	var checked: int = 0
	for unsettled: float in [0.0, 0.5]:
		for spot: Vector3 in _spots():
			var goalie: Vector3 = Sim.goalie_set_pos(spot, _goal)
			goalie.x = clampf(goalie.x + unsettled * Sim.CAUGHT_OFFSET_M,
					-GameRules.NET_HALF_WIDTH, GameRules.NET_HALF_WIDTH)
			var value: float = AIActionScoring.score_shoot(
					spot, _goal, goalie, GameRules.NET_HALF_WIDTH, [],
					AIActionScoring.WRISTER_SHOT_SPEED_M_S, unsettled, [],
					-1.0, false, 0.0, false, spread, [], HANDS_READY_NEG_Z)
			var measured: float = _measured_goal_frac_posed(
					spot, goalie, unsettled, spread, HANDS_READY_NEG_Z)
			var label: String = "posed (%.0f, %.1f m out, unsettled %.2f): value %.3f vs measured %.2f" % [
					spot.x, spot.distance_to(_goal), unsettled, value, measured]
			checked += 1
			if measured >= 0.95:
				assert_gt(value, CERTAIN_MIN, "near-certain cell reads high — " + label)
			elif measured <= 0.05:
				assert_lt(value, DEAD_MAX, "near-dead cell reads low — " + label)
			else:
				assert_almost_eq(value, measured, TRANSITION_TOL,
						"transition cell tracks — " + label)
	assert_gt(checked, 20, "the posed grid actually ran")
