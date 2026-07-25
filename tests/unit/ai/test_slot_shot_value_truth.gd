extends GutTest

# ── score_shoot vs the REAL goalie, through the slot (measure-then-match) ─────
# test_shot_value_calibration pins score_shoot against shot_sim_harness — a
# lateral-reach BAND model. That leaves two blind spots, and the slot sits in
# both:
#   * its grid starts at 4.0 m, so the in-tight ranges are unmeasured;
#   * both sides are models of the goalie, so a shared error is invisible.
#
# This measures the same quantity against the goalie the puck actually hits:
# the live GoalieController posed by its own anatomy, with the real analytic
# save collision. The bot plans the shot (best_shot_aim / _loft / _power_t) at
# the keeper's REAL settled position, fires it, and we count goals. If
# score_shoot is the make probability it claims to be, the two columns match.
#
# ── WHAT IT MEASURED (2026-07, first run) ────────────────────────────────────
# score_shoot over-estimates by up to +1.00 through the entire slot. Measured
# 0/24 goals in EVERY cell inside 7 m against a set keeper, where the model
# reads 0.83–1.00. Nothing missed the net (S24, no WIDE/POST) — they are all
# saves. Two mechanisms, both visible in the columns:
#
#   1. The planner picks a FLAT along-the-ice shot in every cell (loft=0,
#      aim.y=0), and the live goalie eats 100% of them with his STICK (24/24
#      in tight) and PADS. The forced-HIGH column of
#      test_real_goalie_shot_outcomes shows HIGH beating the same keeper
#      75% at 8 m and 68.8% at 11 m — so the band CHOICE is inverted, not
#      just the magnitude.
#
#   2. The goalie's cover model has NO STICK TERM. HOLE_BAND_CORE is pads
#      (LOW) + glove/blocker (HIGH); every `stick` in action_scoring.gd is
#      LANE_DEFENDER_REACH_M, a SKATER's blade in a passing lane. The paddle
#      lying on the ice — the surface actually making these saves — is not a
#      thing the planner can see. That is a missing perception, not a
#      mis-tuned constant, and it is why the flat corner reads open.
#
# Also note the 9–16 m cells agree at 0.00 for the WRONG reason: the model
# finds no hole at all and falls back to aiming dead centre, so the agreement
# is a coincidence rather than calibration. And one inversion — off-angle
# 9.7 m reads 0.00 but measures 0.33, a real chance the model is blind to.
#
# ── METHODOLOGY CORRECTION (2026-07, and it changed the answer) ───────────────
# The runs above scored through score_shoot's DEFAULTS — no post seal, no
# replicated pose, no measured five-hole. Gameplay does not: carrier.gd builds
# _shot_env_* off the live GoalieNetworkState and feeds all of it. So the first
# measurements compared a degraded model against the full live keeper, i.e. they
# measured a code path the bots never execute. Both instruments now score
# through Harness.shot_env(), which mirrors what carrier.gd assembles.
#
# Feeding the real read moves the result, and NOT in the flattering direction:
#
#   cell          loft  model  measured  saves
#   3.5 / 4.3 m     0    1.00    0.00    PAD x24
#   3.5 / 5.3 m     0    1.00    0.00    PAD x24
#   5.0 m           2    1.00    0.17    STICK x18
#   7.0 m           0    0.85    0.00    PAD x24
#
# The first two cells scored 24/24 GOALS on the default path, shooting HIGH.
# With the pose fed they pick FLAT and the pad eats all 24. So the pose-fed HIGH
# cover is OVER-STATED: READY hands parked at (0.42, 0.90) / (-0.44, 0.86) make
# the model read the top corners as guarded, the flat corner wins the hole
# compete by default, and the flat corner is exactly what this keeper is best at
# stopping. The band choice inverts for the second time, from the opposite cause.
#
# That is the live target. Note it is NOT the same defect as the stick (the
# in-tight cells stay 0.00/0.00 either way — that fix holds on both paths).

# Report-only ON PURPOSE. Every cell is currently wrong, so there is nothing
# here worth freezing; asserting the present surface would cement the bug.
# This is the measuring stick for the fix, not a guard on it.

const Harness := preload("res://tests/unit/ai/real_goalie_shot_harness.gd")

const SAMPLES: int = 24
const SETTLE_TICKS: int = 120
const SEED: int = 0x5EED

var _goal := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)
var _goalie: Node = null
var _puck: Node = null
var _shooter: Skater = null
var _ctrl: GoalieController = null
var _h: RefCounted = null
var _last_counts: Dictionary = {}
var _last_pick: String = ""
var _last_parts: Dictionary = {}
const _PART_NAME: Dictionary = {
	GoalieSaveRules.SavePart.PAD: "PAD",
	GoalieSaveRules.SavePart.GLOVE: "GLOVE",
	GoalieSaveRules.SavePart.BLOCKER: "BLOCK",
	GoalieSaveRules.SavePart.CHEST: "CHEST",
	GoalieSaveRules.SavePart.STICK: "STICK",
}


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


# The keeper's REAL settled position for a carrier at `spot`. reset_to_crease
# first so every cell starts from the same state — without it he carries pose,
# depth and reaction from the previous cell and the grid stops being reproducible.
func _settled_keeper(spot: Vector3) -> Vector3:
	_ctrl.reset_to_crease()
	_h.settle(spot, SETTLE_TICKS)
	return _goalie.global_position


# Measured goal fraction of the bot's OWN planned shot from `spot`, fired at the
# real goalie. Each sample re-settles from a clean crease so trials are
# independent; the scatter draw is the bot's release error.
func _measured(spot: Vector3, keeper: Vector3, spread: float) -> float:
	var speed: float = AIActionScoring.WRISTER_SHOT_SPEED_M_S
	var env: Dictionary = _h.shot_env()
	var aim: Vector3 = AIActionScoring.best_shot_aim(
			spot, _goal, keeper, GameRules.NET_HALF_WIDTH, speed,
			0.0, env["five"], env["down"], spread,
			env["seal_x"], env["seal_tall"], 0.0, env["hands"], env["pads"])
	var loft: int = AIActionScoring.best_shot_loft(
			spot, _goal, keeper, GameRules.NET_HALF_WIDTH, speed,
			0.0, env["five"], env["down"], env["seal_x"], env["seal_tall"],
			spread, 0.0, env["hands"], env["pads"])
	var power_t: float = AIActionScoring.best_shot_power_t(
			spot, _goal, keeper, GameRules.NET_HALF_WIDTH, speed,
			0.0, env["five"], env["down"], env["seal_x"], env["seal_tall"],
			spread, 0.0, env["hands"], env["pads"])
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	_last_counts = {Harness.GOAL: 0, Harness.SAVE: 0, Harness.POST: 0, Harness.WIDE: 0}
	_last_pick = "aim(%.2f,%.2f) loft=%d pt=%.2f" % [aim.x, aim.y, loft, power_t]
	_last_parts = {}
	for _i: int in SAMPLES:
		_ctrl.reset_to_crease()
		_h.settle(spot, SETTLE_TICKS)
		var err: float = rng.randf_range(-spread, spread)
		var o: int = _h.fire(spot, aim, loft, power_t, err)
		_last_counts[o] = int(_last_counts.get(o, 0)) + 1
		if o == Harness.SAVE:
			var k: String = _PART_NAME.get(_h.last_part, "?")
			_last_parts[k] = int(_last_parts.get(k, 0)) + 1
	return float(_last_counts[Harness.GOAL]) / float(SAMPLES)


func _model(spot: Vector3, keeper: Vector3, spread: float) -> float:
	var env: Dictionary = _h.shot_env()
	return AIActionScoring.score_shoot(
			spot, _goal, keeper, GameRules.NET_HALF_WIDTH, [],
			AIActionScoring.WRISTER_SHOT_SPEED_M_S, 0.0, [],
			env["five"], env["down"], env["seal_x"], env["seal_tall"],
			spread, [], env["hands"], env["pads"])


func _spots() -> Array[Vector3]:
	var out: Array[Vector3] = []
	for d: float in [1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 7.0, 9.0, 12.0, 16.0]:
		out.append(Vector3(0.0, 0.0, _goal.z + d))
	for d: float in [2.5, 4.0, 6.0, 9.0]:
		out.append(Vector3(3.5, 0.0, _goal.z + d))
	return out


func test_report_slot_shot_value_vs_real_goalie() -> void:
	var spread: float = BotSkillProfile.hard().shot_aim_error_rad
	gut.p("   x   dist  keeper_depth   model   measured    delta   (%d samples, set goalie)"
			% SAMPLES)
	var worst_over: float = 0.0
	var worst_spot := ""
	for spot: Vector3 in _spots():
		var keeper: Vector3 = _settled_keeper(spot)
		var depth: float = absf(keeper.z - _goal.z)
		var model: float = _model(spot, keeper, spread)
		var measured: float = _measured(spot, keeper, spread)
		var delta: float = model - measured
		if delta > worst_over:
			worst_over = delta
			worst_spot = "x=%.1f, %.1f m" % [spot.x, spot.distance_to(_goal)]
		gut.p("%4.1f  %5.1f      %5.2f      %5.2f    %5.2f    %+6.2f   | G%d S%d P%d W%d  %s"
				% [spot.x, spot.distance_to(_goal), depth, model, measured, delta,
				_last_counts[Harness.GOAL], _last_counts[Harness.SAVE],
				_last_counts[Harness.POST], _last_counts[Harness.WIDE],
				_last_pick + "  saves:" + str(_last_parts)])
	gut.p("worst OVER-estimate: %+.2f at %s" % [worst_over, worst_spot])
	assert_true(true, "report")
