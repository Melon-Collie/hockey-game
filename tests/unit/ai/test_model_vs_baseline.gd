extends GutTest

# ── Is the goalie-aware model worth its complexity? ──────────────────────────
# REPORT-ONLY. The comparison XGBaseline's own doc asks for and that has never
# been run: it calls itself "the BASELINE our goalie-aware model has to beat
# before its extra complexity is worth anything", but it is only ever checked
# against expected_goals — the post-game stat — never against
# open_net_danger, which is what the bots actually decide on.
#
# Three models, one measurement:
#
#   CLIMATOLOGY   the overall base rate, constant everywhere. The null model.
#                 Anything that cannot beat this is worse than knowing nothing.
#   XGBaseline    location + angle, no goalie. ~4 parameters, NHL-calibrated.
#   open_net_danger  the five-hole geometry, pose-fed, ~25 constants.
#
# The measurement is real_goalie_shot_harness: the live GoalieController and
# the real analytic save loop, firing the shot the planner ITSELF chose from
# that cell (best_shot_aim / _loft / _power_t). So every model is predicting
# the same event — "the bot shoots its best plan from here, does it go in".
#
# ── Two questions, deliberately separated ────────────────────────────────────
# CALIBRATION — is the level right? Reported as mean |model − measured rate|
#   and as Brier skill against climatology. XGBaseline is expected to lose
#   here and it is not really its fault: its own doc says it is NHL-calibrated
#   (~9-10% shooting) and Mitts is arcade, so it under-predicts by
#   construction. A single rescale would fix most of it.
# DISCRIMINATION — does it ORDER cells correctly? Reported as pairwise
#   concordance: of every pair of cells whose measured rates differ, how often
#   does the model rank them the same way. This is the property the carry beam
#   actually consumes, and no amount of rescaling changes it.
#
# A model can win one and lose the other. If the geometry only wins on
# calibration, its complexity is buying a constant we could have fitted; if it
# wins on concordance, it is buying something the location-only form cannot
# express — which is the whole question.

const Harness := preload("res://tests/unit/ai/real_goalie_shot_harness.gd")

const GOAL_Z: float = -GameRules.GOAL_LINE_Z
const NET_HW: float = GameRules.NET_HALF_WIDTH
const WRIST: float = AIActionScoring.WRISTER_SHOT_SPEED_M_S
const SAMPLES: int = 16
const SETTLE_TICKS: int = 120
const SEED: int = 0x5EED
# CAUGHT: settle him on a decoy this far to the side, then shoot from the real
# spot before he can re-square — displacement produced by moving the live
# keeper, not by nudging a synthetic position.
const DECOY_OFFSET_M: float = 4.0

var _goal := Vector3(0.0, 0.0, GOAL_Z)
var _goalie: Node = null
var _puck: Node = null
var _shooter: Skater = null
var _ctrl: GoalieController = null
var _h: RefCounted = null


func before_each() -> void:
	_goalie = load("res://Scenes/Goalie.tscn").instantiate()
	_puck = load("res://Scenes/Puck.tscn").instantiate()
	_shooter = load("res://Scenes/Skater.tscn").instantiate() as Skater
	_ctrl = GoalieController.new()
	add_child_autofree(_goalie)
	add_child_autofree(_puck)
	add_child_autofree(_shooter)
	add_child_autofree(_ctrl)
	_h = Harness.new()
	_h.setup(_goalie, _puck, _ctrl, _shooter)


# Spots as (lateral, forward-from-goal-line) so every cell is valid geometry
# rather than a distance that some laterals cannot reach.
func _spots() -> Array[Vector3]:
	var out: Array[Vector3] = []
	for x: float in [0.0, 2.0, 4.0, 7.0]:
		for fwd: float in [3.0, 5.0, 8.0, 12.0]:
			out.append(Vector3(x, 0.0, GOAL_Z + fwd))
	return out


func _settle_for(spot: Vector3, caught: bool) -> Vector3:
	_ctrl.reset_to_crease()
	var threat: Vector3 = spot
	if caught:
		threat = Vector3(spot.x + DECOY_OFFSET_M, 0.0, spot.z)
	_h.settle(threat, SETTLE_TICKS)
	return _goalie.global_position


func _env(caught: bool) -> Dictionary:
	var env: Dictionary = _h.shot_env()
	env["unsettled"] = 1.0 if caught else 0.0
	return env


# Fire the planner's OWN chosen shot `SAMPLES` times; return goals scored.
func _measure(spot: Vector3, keeper: Vector3, caught: bool, spread: float,
		env: Dictionary) -> int:
	var aim: Vector3 = AIActionScoring.best_shot_aim(
			spot, _goal, keeper, NET_HW, WRIST, env["unsettled"], env["five"],
			env["down"], spread, env["seal_x"], env["seal_tall"], 0.0,
			env["hands"], env["pads"])
	var loft: int = AIActionScoring.best_shot_loft(
			spot, _goal, keeper, NET_HW, WRIST, env["unsettled"], env["five"],
			env["down"], env["seal_x"], env["seal_tall"], spread, 0.0,
			env["hands"], env["pads"])
	var power_t: float = 1.0  # full pace, always (contact-point solve)
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var goals: int = 0
	for _i: int in SAMPLES:
		_settle_for(spot, caught)
		if _h.fire(spot, aim, loft, power_t, rng.randf_range(-spread, spread)) \
				== Harness.GOAL:
			goals += 1
	return goals


# Brier over the individual 0/1 outcomes for a cell predicted at `p`.
func _cell_brier(p: float, goals: int, n: int) -> float:
	return float(goals) * (p - 1.0) * (p - 1.0) + float(n - goals) * p * p


# Fraction of cell PAIRS ordered the same way as the measurement. Pairs whose
# measured rates tie are excluded — they carry no ordering information.
func _concordance(model: Array[float], measured: Array[float]) -> float:
	var ok: int = 0
	var total: int = 0
	for i: int in measured.size():
		for j: int in range(i + 1, measured.size()):
			if is_equal_approx(measured[i], measured[j]):
				continue
			total += 1
			var m_first: bool = measured[i] > measured[j]
			var p_first: bool = model[i] > model[j]
			if m_first == p_first:
				ok += 1
	return float(ok) / maxf(float(total), 1.0)


func test_report_goalie_aware_vs_location_only() -> void:
	var spread: float = BotSkillProfile.hard().shot_aim_error_rad
	var rate: Array[float] = []
	var geo: Array[float] = []
	var base: Array[float] = []
	var goals_at: Array[int] = []
	var labels: Array[String] = []
	var total_goals: int = 0
	var total_shots: int = 0

	gut.p("  x  fwd  state    geometric  baseline   measured   (%d samples/cell)"
			% SAMPLES)
	for caught: bool in [false, true]:
		for spot: Vector3 in _spots():
			var keeper: Vector3 = _settle_for(spot, caught)
			var env: Dictionary = _env(caught)
			var g: float = AIActionScoring.score_shoot(
					spot, _goal, keeper, NET_HW, [] as Array[Vector3], WRIST,
					env["unsettled"], [], env["five"], env["down"],
					env["seal_x"], env["seal_tall"], spread,
					[] as Array[Vector3], env["hands"], env["pads"])
			var b: float = XGBaseline.for_shot(
					spot.x, spot.z, 0, ShotEvent.ShotType.SHOT)
			var goals: int = _measure(spot, keeper, caught, spread, env)
			var r: float = float(goals) / float(SAMPLES)
			var state := "CAUGHT" if caught else "SET   "
			gut.p("%4.1f %4.1f  %s   %6.3f    %6.3f     %5.2f"
					% [spot.x, absf(spot.z - GOAL_Z), state, g, b, r])
			rate.append(r)
			geo.append(g)
			base.append(b)
			goals_at.append(goals)
			labels.append("%.0f/%.0f%s" % [spot.x, absf(spot.z - GOAL_Z),
					"C" if caught else "S"])
			total_goals += goals
			total_shots += SAMPLES

	var clim: float = float(total_goals) / float(total_shots)
	var n: int = rate.size()
	var brier_geo: float = 0.0
	var brier_base: float = 0.0
	var brier_clim: float = 0.0
	var mae_geo: float = 0.0
	var mae_base: float = 0.0
	var mae_clim: float = 0.0
	for i: int in n:
		brier_geo += _cell_brier(geo[i], goals_at[i], SAMPLES)
		brier_base += _cell_brier(base[i], goals_at[i], SAMPLES)
		brier_clim += _cell_brier(clim, goals_at[i], SAMPLES)
		mae_geo += absf(geo[i] - rate[i])
		mae_base += absf(base[i] - rate[i])
		mae_clim += absf(clim - rate[i])
	brier_geo /= float(total_shots)
	brier_base /= float(total_shots)
	brier_clim /= float(total_shots)

	gut.p("")
	gut.p("base rate over the grid: %.3f  (%d goals / %d shots, %d cells)"
			% [clim, total_goals, total_shots, n])
	gut.p("")
	gut.p("model            mean|err|   Brier    skill vs clim   concordance")
	gut.p("climatology       %6.3f    %6.4f        —             %5.1f%%"
			% [mae_clim / float(n), brier_clim, 50.0])
	gut.p("XGBaseline        %6.3f    %6.4f     %+6.1f%%          %5.1f%%"
			% [mae_base / float(n), brier_base,
				100.0 * (1.0 - brier_base / maxf(brier_clim, 1e-9)),
				100.0 * _concordance(base, rate)])
	gut.p("open_net_danger   %6.3f    %6.4f     %+6.1f%%          %5.1f%%"
			% [mae_geo / float(n), brier_geo,
				100.0 * (1.0 - brier_geo / maxf(brier_clim, 1e-9)),
				100.0 * _concordance(geo, rate)])
	gut.p("")
	gut.p("(skill > 0 beats knowing nothing. concordance is the property the")
	gut.p(" carry beam consumes: does the model order two spots the way the")
	gut.p(" goalie does. 50%% is a coin flip and is what climatology scores.)")
	assert_true(true, "report")
