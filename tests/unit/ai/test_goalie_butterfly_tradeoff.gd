extends GutTest

# ── DOES THE BUTTERFLY COST HIM ANYTHING? ────────────────────────────────────
# In real goaltending the butterfly is a TRADE: it seals the ice and concedes
# the top of the net. Every block-vs-react decision rests on that trade — the
# whole reason to stay on your feet is that going down gives something up.
#
# This measures whether the trade exists in our game. It does not, in tight,
# and that single fact explains a run of results that otherwise look like a
# broken test.
#
# ── WHAT IT MEASURED (2026-07) ───────────────────────────────────────────────
# 1. A goalie forced DOWN saves MORE than one left upright, at every height
#    reachable from 7 m:
#
#      HIGH loft, 75 mph, aim x -0.80..+0.80    UPRIGHT 4 goals -> DOWN 1 goal
#      FLAT loft, 75 mph, same sweep            UPRIGHT 1 goal  -> DOWN 0 goals
#
#    (down at release in 21/21 cells, so this is not the drop being arrested).
#    The upright goals are the extreme corners; the splayed butterfly covers
#    them laterally, and nothing above it is reachable to punish the seal.
#
# 2. Because a HIGH shot cannot arrive high from in tight. Arrival height at the
#    net, HIGH loft (crossbar inner edge ~1.17 m):
#
#       dist   65 mph   75 mph   85 mph
#        3.0     0.43     0.38     0.34
#        5.0     0.66     0.59     0.53
#        7.0     0.84     0.76     0.69
#       12.0     1.09     1.04     0.98
#       16.0     1.07     1.10     1.09
#
#    Loft is a fixed vertical LAUNCH SPEED, not a solved arc (by design — it is
#    what stops a hard shot sailing over the net), so in tight the puck simply
#    has not climbed yet. A max-power shot from 3 m arrives at 0.38 m.
#
# 3. The roofing counter exists, but it costs PACE, and it has a minimum range.
#    Arrival height vs power, HIGH loft:
#
#       dist   25mph   35mph   45mph   55mph   65mph   75mph
#        2.0    0.73    0.53    0.42    0.35    0.30    0.26
#        3.0    0.95    0.74    0.60    0.50    0.43    0.38
#        5.0    1.10    1.01    0.87    0.75    0.66    0.59
#        7.0    0.88    1.10    1.04    0.94    0.84    0.76
#
#    Bar height is reachable from ~4 m out on a soft release and not at all
#    inside ~3 m at any power — which matches the documented design intent
#    (CLAUDE.md: min bar-height roofing distance ~3.7 m on a balanced blade).
#
# ── WHY THIS MATTERS ─────────────────────────────────────────────────────────
# Three separate experiments made the goalie pre-commit and all three measured
# the same way: more saves AND deception stopping paying (see
# test_goalie_disguise_read, and §9 of docs/goalie-grounding-refactor-plan.md).
# That reads like a broken instrument. It is not.
#
# All three commits happened IN TIGHT, which is exactly the zone where the
# butterfly gives up nothing: there is only one plane to shoot at, so there is
# nothing for a height fake to choose between. Deception needs two live options.
#
# A contributing gap: GoalieBodyConfigBuilder._apply_elevated_shot_reaction runs
# IDENTICALLY in STANDING, READY, BUTTERFLY, COILING and SLIDING. The resting
# glove drops (0.90 m upright -> 0.44 m down) so the reach has further to travel
# under `glove_react_max_speed`, but the reach TARGET and the speed cap are the
# same. A down goalie in this model has the same upper-net envelope as a standing
# one; only the trip is longer, and the measurement above says that cost is
# smaller than the lateral coverage the splay buys.
#
# Report-only. Nothing here is a decision — it is the evidence for one.

const Harness := preload("res://tests/unit/ai/real_goalie_shot_harness.gd")
const GOAL_Z: float = -GameRules.GOAL_LINE_Z
const MPH: float = 0.44704
const SETTLE_TICKS: int = 90
const DROP_TICKS: int = 40

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
	for n: Node in [_goalie, _puck, _shooter, _ctrl]:
		add_child_autofree(n)
	_h = Harness.new()
	_h.setup(_goalie, _puck, _ctrl, _shooter)


# Arrival height at the net plane for a shot fired from `d` metres at `mph`.
func _arrival_y(d: float, mph: float, loft: int) -> float:
	var spot := Vector3(0.0, 0.0, GOAL_Z + d)
	var v: Vector3 = _h.shot_velocity_at(spot, Vector3(0.0, 0.0, GOAL_Z),
			loft, mph * MPH, 0.0)
	if absf(v.z) < 0.001:
		return 0.0
	var t: float = d / absf(v.z)
	return v.y * t - 0.5 * 9.8 * t * t


# Sweep the mouth from a settled keeper, optionally forcing him down first.
func _sweep(force_down: bool, loft: int) -> String:
	var spot := Vector3(0.0, 0.0, GOAL_Z + 7.0)
	var row: String = ""
	var goals: int = 0
	var still_down: int = 0
	var cells: int = 0
	var a: float = -0.80
	while a <= 0.801:
		_ctrl.reset_to_crease()
		_h.settle(spot, SETTLE_TICKS)
		if force_down:
			_ctrl._enter_butterfly()
			for _i: int in DROP_TICKS:
				_ctrl._physics_process(1.0 / 120.0)
			if _ctrl._sm.is_down():
				still_down += 1
		cells += 1
		var o: int = _h.fire_at(spot, Vector3(a, 0.0, GOAL_Z), loft, 75.0 * MPH, 0.0)
		if o == Harness.GOAL:
			row += "G"
			goals += 1
		elif o == Harness.SAVE:
			row += "s"
		else:
			row += "x"
		a += 0.08
	var held: String = ""
	if force_down:
		held = "  (down at release %d/%d)" % [still_down, cells]
	return "%s  %d goals%s" % [row, goals, held]


func test_report_whether_going_down_gives_anything_up() -> void:
	gut.p("Arrival height at the net, HIGH loft (crossbar inner ~1.17 m):")
	gut.p("  dist   65 mph   75 mph   85 mph")
	for d: float in [3.0, 5.0, 7.0, 9.0, 12.0, 16.0, 20.0]:
		var line: String = "%6.1f" % d
		for mph: float in [65.0, 75.0, 85.0]:
			line += "   %6.2f" % _arrival_y(d, mph, ShotMechanics.ELEVATION_HIGH)
		gut.p(line)
	gut.p("")
	gut.p("Arrival height vs POWER in tight (HIGH loft) — the roofing counter:")
	gut.p("  dist   25mph   35mph   45mph   55mph   65mph   75mph")
	for d: float in [2.0, 3.0, 5.0, 7.0]:
		var line: String = "%6.1f" % d
		for mph: float in [25.0, 35.0, 45.0, 55.0, 65.0, 75.0]:
			line += "  %6.2f" % _arrival_y(d, mph, ShotMechanics.ELEVATION_HIGH)
		gut.p(line)
	gut.p("")
	gut.p("Forced BUTTERFLY vs UPRIGHT, 7 m, 75 mph, aim x -0.80..+0.80:")
	for loft: int in [ShotMechanics.ELEVATION_HIGH, ShotMechanics.ELEVATION_FLAT]:
		var nm: String = "HIGH" if loft == ShotMechanics.ELEVATION_HIGH else "FLAT"
		gut.p("  %s UPRIGHT  |%s" % [nm, _sweep(false, loft)])
		gut.p("  %s BUTTERFLY|%s" % [nm, _sweep(true, loft)])
	assert_true(true, "report")
