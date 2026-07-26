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
# THE HEADLINE: the butterfly covers the SAME VERTICAL ENVELOPE as standing. A
# goalie flat on the ice gloves a puck arriving 5 cm under the crossbar, with
# essentially the same hand distribution as an upright one:
#
#   16 m @ 75 mph, puck arrives y = 1.10 m (crossbar inner ~1.17), aim sweep
#     UPRIGHT     0 goals   GLOVE 11  BLOCK 10
#     BUTTERFLY   0 goals   GLOVE 11  BLOCK  9  stick 1   (down at release 21/21)
#
#   5 m @ 25 mph — the soft in-tight roof, y = 1.10 m
#     UPRIGHT     0 goals   GLOVE 10  BLOCK 10  chest 1
#     BUTTERFLY   0 goals   GLOVE 11  BLOCK 10
#
# That is a code fact, not an emergent one. GoalieBodyConfigBuilder._reach_glove
# and _reach_blocker end with
#
#     c.glove_pos = Vector3(glove_x, target_y, glove_z)
#
# where `target_y = clampf(intercept_y, react_hand_y_min, react_hand_y_max)` —
# 0.50 to 1.55 m, with NO arm-length constraint and NO shoulder anchor. The hand
# is placed in goalie-ROOT-local space and the root does not drop when he does,
# so y = 1.55 is reachable from the butterfly exactly as it is from the feet.
# `_apply_elevated_shot_reaction` is called identically from STANDING, READY,
# BUTTERFLY, COILING and SLIDING.
#
# The ONLY cost of being down is that the resting glove sits lower (0.90 m
# upright, 0.44 m in the butterfly, per _set_butterfly_pose), so the reach has
# 0.46 m further to travel under `glove_react_max_speed`. At any range with time
# to spare that costs nothing at all.
#
# SECOND, COMPOUNDING FACT: in tight there is nothing above him to shoot at
# anyway. Being down therefore also gains lateral coverage for free —
#
#   HIGH loft, 75 mph, 7 m, aim x -0.80..+0.80    UPRIGHT 4 goals -> DOWN 1 goal
#   FLAT loft, 75 mph, same sweep                 UPRIGHT 1 goal  -> DOWN 0 goals
#
#   arrival height at the net, HIGH loft (crossbar inner ~1.17 m):
#      dist   65 mph   75 mph   85 mph
#       3.0     0.43     0.38     0.34
#       5.0     0.66     0.59     0.53
#       7.0     0.84     0.76     0.69
#      12.0     1.09     1.04     0.98
#      16.0     1.07     1.10     1.09
#
# Loft is a fixed vertical LAUNCH SPEED, not a solved arc (by design — it is what
# stops a hard shot sailing over the net), so in tight the puck has not climbed
# yet. The roofing counter costs pace and has a floor: bar height is reachable
# from ~4 m on a soft release and not at all inside ~3 m at any power, matching
# the documented intent (CLAUDE.md: ~3.7 m on a balanced blade).
#
#   arrival height vs power, HIGH loft:
#      dist   25mph   35mph   45mph   55mph   65mph   75mph
#       2.0    0.73    0.53    0.42    0.35    0.30    0.26
#       3.0    0.95    0.74    0.60    0.50    0.43    0.38
#       5.0    1.10    1.01    0.87    0.75    0.66    0.59
#       7.0    0.88    1.10    1.04    0.94    0.84    0.76
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
# But the envelope is the deeper cause, and it bites at MEDIUM range too, where
# elevation IS achievable — which is exactly where a height fake ought to pay.
# A seal that concedes nothing above it cannot be punished for sealing, so
# committing is never a trade and deception has no lever anywhere.
#
# ── FIXED (2026-07): the reach ceiling is now chest-anchored ─────────────────
# `_reachable_hand_y` caps the hand at `body_pos.y + arm_reach_above_chest`,
# where the chest anchor is whatever the pose in play already authored (READY
# 1.06, STANDING 1.22, BUTTERFLY 0.40). 1.06 + 0.49 = 1.55 — the old flat
# ceiling — so upright reach is unchanged BY CONSTRUCTION and only the down
# postures give anything up.
#
# WHAT THE FIX ACTUALLY MOVED — exactly two cells, both BUTTERFLY, both with the
# puck arriving high. Everything else in this instrument is identical:
#
#   cell (butterfly)                   before   after
#   16 m @ 75 mph, arrives 1.10 m         0       6
#    5 m @ 25 mph, arrives 1.10 m         1       3
#    9 m @ 65 mph, arrives 0.98 m         0       0
#    7 m HIGH,     arrives 0.76 m         1       1
#    7 m FLAT                             0       0
#   every UPRIGHT cell                    —   unchanged
#
# ⚠️ Read that as a BEFORE/AFTER table and the UPRIGHT-vs-BUTTERFLY rows below as
# a WITHIN-BUILD contrast. They are different comparisons and conflating them is
# an easy mistake to make (it was made once already). In particular the butterfly
# being better LOW is not something this fix created — it was always true, it is
# the lateral splay, and the fix does not touch it. The fix removed the seal's
# HIGH-side advantage and nothing else.
#
#   UPRIGHT vs BUTTERFLY, after the fix:
#     16 m @ 75 mph, arrives 1.10 m    UPRIGHT 0 goals   BUTTERFLY 6 goals
#      5 m @ 25 mph, arrives 1.10 m    UPRIGHT 0 goals   BUTTERFLY 3 goals
#      9 m @ 65 mph, arrives 0.98 m    UPRIGHT 1 goal    BUTTERFLY 0 goals
#      7 m HIGH, arrives 0.76 m        UPRIGHT 4 goals   BUTTERFLY 1 goal
#      7 m FLAT                        UPRIGHT 1 goal    BUTTERFLY 0 goals
#
# So the butterfly is better low and worse high — seal the ice, concede the top —
# and only the second half of that is new. The soft in-tight roof (5 m @ 25 mph)
# is the counter a real shooter has against a goalie who drops early, and it went
# from a single edge cell to a real window.
#
# Everything that shoots at a SETTLED UPRIGHT keeper is bit-identical:
# exhaustive 16/288 and 0/288, five-hole windows, and the disguise arms
# (7 / 10 / 11). The change reaches only a down goalie playing the top.
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
var _parts: Dictionary = {}
const PART_NAME: Dictionary = {
	GoalieSaveRules.SavePart.PAD: "pad",
	GoalieSaveRules.SavePart.GLOVE: "GLOVE",
	GoalieSaveRules.SavePart.BLOCKER: "BLOCK",
	GoalieSaveRules.SavePart.CHEST: "chest",
	GoalieSaveRules.SavePart.STICK: "stick",
}


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
func _sweep(force_down: bool, loft: int, dist: float = 7.0,
		mph: float = 75.0) -> String:
	var spot := Vector3(0.0, 0.0, GOAL_Z + dist)
	var row: String = ""
	var goals: int = 0
	var still_down: int = 0
	var cells: int = 0
	_parts = {}
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
		var o: int = _h.fire_at(spot, Vector3(a, 0.0, GOAL_Z), loft, mph * MPH, 0.0)
		if o == Harness.GOAL:
			row += "G"
			goals += 1
		elif o == Harness.SAVE:
			row += "s"
			var k: String = PART_NAME.get(_h.last_part, "?")
			_parts[k] = int(_parts.get(k, 0)) + 1
		else:
			row += "x"
		a += 0.08
	var held: String = ""
	if force_down:
		held = "  (down at release %d/%d)" % [still_down, cells]
	return "%s  %d goals%s  %s" % [row, goals, held, str(_parts)]


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
	gut.p("")
	gut.p("THE CASE THAT SHOULD PUNISH THE SEAL — medium range, puck arriving high:")
	for cell: Vector2 in [Vector2(9.0, 65.0), Vector2(12.0, 65.0),
			Vector2(16.0, 75.0), Vector2(5.0, 25.0)]:
		var d: float = cell.x
		var mph: float = cell.y
		gut.p("  %.0f m @ %.0f mph  (arrives y=%.2f m)"
				% [d, mph, _arrival_y(d, mph, ShotMechanics.ELEVATION_HIGH)])
		gut.p("     UPRIGHT  |%s"
				% _sweep(false, ShotMechanics.ELEVATION_HIGH, d, mph))
		gut.p("     BUTTERFLY|%s"
				% _sweep(true, ShotMechanics.ELEVATION_HIGH, d, mph))
	assert_true(true, "report")
