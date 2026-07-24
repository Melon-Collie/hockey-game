extends GutTest

# ── DISGUISE INSTRUMENT (plan doc §5, Tranche B / Step 0b) ───────────────────
# Measures the thing the goalie audit says is missing: does it matter WHERE THE
# SHOOTER LOOKED before releasing?
#
# Two arms, identical in every other respect — same shooter spot, same release
# aim, same power, same loft, same windup duration, no scatter:
#
#   TELEGRAPHED — the windup declares the corner the shot actually goes to.
#   DISGUISED   — the windup declares the OPPOSITE corner, and the release swings
#                 late to the real one. The against-the-grain wrister.
#
# The goalie reads the declared aim all through the windup: it feeds the
# directional pre-lean, the pinned-windup squaring, and the quiet-eye pre-arm
# timer. Then he reads the ACTUAL release velocity — exactly, on the release
# frame — via _on_puck_released.
#
# CURRENT EXPECTED RESULT: the two arms score the SAME. The goalie's read of
# where the puck is going is exact and re-projected every tick, so a late swing
# costs him nothing (plan §5.1: "the goalie has no concept of being wrong"). The
# test asserts that equality — it is DOCUMENTING A DEFECT, not blessing it.
#
# WHEN R1 LANDS (read lag — plan §5.2), flip `EXPECT_DISGUISE_PAYS` to true. The
# disguised arm must then score strictly more, and the telegraphed arm must NOT
# get easier (a stable aim still reads perfectly — bad shots stay saved). That
# pair of conditions is the whole acceptance criterion for R1.
#
# Fully deterministic: no scatter draws, no RNG. Per the goalie's no-RNG
# invariant (plan §5.3), the disguise effect must be a pure function of what the
# shooter did with their aim, so a fixed sweep is the correct instrument.

const Harness := preload("res://tests/unit/ai/real_goalie_shot_harness.gd")

const GOAL_Z: float = -GameRules.GOAL_LINE_Z
# 0.5 s of windup — comfortably past prearm_read_time (0.40 s), so the goalie
# banks the full quiet-eye prime and the pre-lean is fully committed. This is the
# best case for the read, which is what makes a late swing the sharp test.
const WINDUP_TICKS: int = 60
const POWER_T: float = 0.85
# HIGH loft, aimed at the top corners. This matters: the directional pre-lean —
# the ONLY channel through which the declared aim currently reaches the goalie —
# moves the GLOVE and BLOCKER. A flat low corner is a PAD save, so disguise
# provably cannot matter there. Elevated corners are where the arm read decides
# the save, and they are also the shot the design most wants beatable in tight.
const LOFT_HIGH: int = 2

# Flip when R1 (read lag) lands. See the header.
const EXPECT_DISGUISE_PAYS: bool = false

var _h: RefCounted = null
var _goalie: Node = null
var _puck: Node = null
var _shooter: Skater = null
var _ctrl: GoalieController = null


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


# Shot spots: range × lateral offset. Kept inside the scoring area where a
# corner pick is a real option and the goalie is genuinely challenging.
const SPOTS: Array[Vector2] = [
	Vector2(0.0, 5.0), Vector2(0.0, 7.0), Vector2(0.0, 9.0),
	Vector2(2.5, 5.0), Vector2(2.5, 7.0),
	Vector2(-2.5, 5.0), Vector2(-2.5, 7.0),
]
# Corner pairs (x at the net plane). A shot to one, a windup declaring the other:
# the classic against-the-grain look-off.
const CORNER_X: float = 0.72   # inside the post, a real corner but not a miss


# Run the full sweep for one arm. `disguise` picks whether the declared windup aim
# is the opposite corner from the release.
#
# Two metrics, because the coarse one alone is untrustworthy here (the real-goalie
# instrument's outcomes are near-binary per scenario, so a 14-shot goal count
# swings on one incidental flip):
#
#   reach_gap  — CONTINUOUS, the primary signal. At the moment of release, how far
#                the glove has to travel laterally to meet the shot line. This is
#                exactly what the pre-lean is for and exactly what disguise should
#                inflate, so it detects a read effect long before it shows up as a
#                goal.
#   goals      — the coarse outcome, reported for context.
#
# CAVEAT on reach_gap: its ABSOLUTE value is dominated by glove-side vs
# blocker-side (the glove sits off-centre, so one corner is ~0.05 m away and the
# other ~1.0 m). Only the PAIRED DELTA between the two arms is meaningful — the
# spots are identical in both, so difference-of-means is the paired difference.
func _sweep(disguise: bool) -> Dictionary:
	var goals: int = 0
	var saves: int = 0
	var shots: int = 0
	var gap_sum: float = 0.0
	for spot: Vector2 in SPOTS:
		for side: int in [-1, 1]:
			var shooter := Vector3(spot.x, 0.0, GOAL_Z + spot.y)
			var aim := Vector3(float(side) * CORNER_X, 0.0, GOAL_Z)
			var declared := aim
			if disguise:
				declared = Vector3(float(-side) * CORNER_X, 0.0, GOAL_Z)
			_h.hold_windup(shooter, declared, LOFT_HIGH, POWER_T, WINDUP_TICKS)
			# Where the pre-lean has parked the glove vs. where the shot will cross
			# the goalie's plane — the travel the arm still owes at release.
			var gap: float = _reach_gap(shooter, aim)
			gap_sum += gap
			var outcome: int = _h.fire_release(shooter, aim, LOFT_HIGH, POWER_T, 0.0)
			gut.p("  spot(%+.1f,%.1f) side=%+d  reach_gap=%.3f -> %s" % [
					spot.x, spot.y, side, gap,
					"GOAL" if outcome == Harness.GOAL else "save"])
			shots += 1
			if outcome == Harness.GOAL:
				goals += 1
			elif outcome == Harness.SAVE:
				saves += 1
	return {
		"goals": goals, "saves": saves, "shots": shots,
		"mean_gap": gap_sum / maxf(float(shots), 1.0),
	}


# Lateral distance the glove must still cover at the instant of release: |glove_x
# now − shot_x where the shot crosses the goalie's depth plane|.
func _reach_gap(shooter: Vector3, aim: Vector3) -> float:
	var vel: Vector3 = _h.shot_velocity(shooter, aim, LOFT_HIGH, POWER_T, 0.0)
	if absf(vel.z) < 0.001:
		return 0.0
	var t: float = (_goalie.global_position.z - shooter.z) / vel.z
	if t <= 0.0:
		return 0.0
	var shot_x: float = shooter.x + vel.x * t
	return absf(_goalie.get_glove_world_position().x - shot_x)


func test_disguise_delta() -> void:
	var telegraphed: Dictionary = _sweep(false)
	var disguised: Dictionary = _sweep(true)

	var tele_goals: int = telegraphed["goals"]
	var dis_goals: int = disguised["goals"]
	var shots: int = telegraphed["shots"]
	gut.p("TELEGRAPHED  goals=%d/%d  saves=%d" % [
			tele_goals, shots, telegraphed["saves"]])
	gut.p("DISGUISED    goals=%d/%d  saves=%d" % [
			dis_goals, disguised["shots"], disguised["saves"]])
	gut.p("DISGUISE DELTA = %+d goals" % [dis_goals - tele_goals])

	var gap_delta: float = disguised["mean_gap"] - telegraphed["mean_gap"]
	gut.p("MEAN REACH GAP  telegraphed=%.3f m  disguised=%.3f m  (delta %+.3f m)" % [
			telegraphed["mean_gap"], disguised["mean_gap"], gap_delta])
	# The headline number. Extra glove travel converts to time at the arm's speed
	# cap, which is what a read advantage is actually worth.
	gut.p("=> selling the wrong corner for %.2f s of windup buys %.1f ms of arm travel" % [
			WINDUP_TICKS / 120.0, 1000.0 * gap_delta / _ctrl.glove_react_max_speed])

	assert_eq(disguised["shots"], shots, "both arms must fire the same shot count")

	# The continuous signal: a disguised release must leave the glove further from
	# the shot than a telegraphed one. This holds TODAY (the directional pre-lean
	# is the one channel disguise already reaches) and must only widen under R1.
	assert_gt(disguised["mean_gap"], telegraphed["mean_gap"],
			"a disguised release must leave the glove further from the shot line than a telegraphed one")

	if EXPECT_DISGUISE_PAYS:
		# Post-R1 acceptance: selling the wrong corner must actually beat him...
		assert_gt(dis_goals, tele_goals,
				"a late swing against the grain must beat the goalie more often than a telegraphed shot")
		# ...and it must NOT come from the goalie getting worse at honest shots.
		# R1 only makes him wrong when he was MISLED; a stable aim still reads
		# perfectly, so bad (telegraphed) shots stay saved.
		assert_true(tele_goals <= _BASELINE_TELEGRAPHED_GOALS,
				"R1 must not make TELEGRAPHED shots easier — only disguised ones (%d vs baseline %d)" % [
						tele_goals, _BASELINE_TELEGRAPHED_GOALS])
	else:
		# Current behaviour, documenting the defect (plan §5.1). Disguise buys a
		# pre-lean's worth of glove displacement and NOTHING ELSE: the goalie's
		# positional read and his timing are both exact, so selling the wrong
		# corner does not convert into goals. The reach gap moves; the scoreboard
		# does not. That gap-without-goals signature IS the defect.
		assert_true(dis_goals <= tele_goals + 1,
				("TODAY: disguise moves the glove but not the scoreboard " +
				"(telegraphed %d goals, disguised %d of %d). The goalie's read of the " +
				"shot is exact — see docs/goalie-grounding-refactor-plan.md §5.1. " +
				"Flip EXPECT_DISGUISE_PAYS when R1 lands.") % [tele_goals, dis_goals, shots])


# Recorded when the assertion above is flipped — the telegraphed arm's goal count
# under the current (perfect-read) model, so R1 can be checked for not having
# quietly made honest shots easier too.
const _BASELINE_TELEGRAPHED_GOALS: int = 3


# The pre-arm is what makes the disguise test sharp: the goalie must actually be
# fixating on the declared aim, or "disguise" would be measuring nothing. Pins the
# read pipeline the instrument depends on.
func test_windup_is_actually_read() -> void:
	var shooter := Vector3(0.0, 0.0, GOAL_Z + 7.0)
	var declared := Vector3(CORNER_X, 1.0, GOAL_Z)
	_h.hold_windup(shooter, declared, LOFT_HIGH, POWER_T, WINDUP_TICKS)

	assert_true(_ctrl._is_reading_shot_threat(_shooter),
			"the goalie must be reading the wrister windup")
	assert_true(_ctrl._reading_pinned_windup,
			"a wrister windup pins the puck — pinned squaring must be engaged")
	assert_gt(_ctrl._prime_linger_timer, 0.0,
			"%.2f s of windup must bank the quiet-eye pre-arm" % [WINDUP_TICKS / 120.0])
	assert_true(_ctrl._pose_inputs.prelean_directional,
			"the goalie must be pre-leaning toward the DECLARED aim (what disguise exploits)")
