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
# There is a third arm, on a second deception axis: selling the wrong HEIGHT
# (the wind-up declares a flat shot, the release goes high), which misleads the
# LEG read — the butterfly drop — rather than the arm.
#
# Every arm is run TWICE: once with `read_lag = 0` (belief == truth, i.e. exactly
# the pre-R1 goalie) and once with R1 live. Running the control here rather than
# trusting a recorded baseline means the A/B shares every other detail of the
# instrument, and it keeps the pre-R1 defect permanently documented:
#
#   read_lag = 0     telegraphed 6/14   wrong corner 6/14   wrong height  6/14
#   read_lag = 0.10  telegraphed 6/14   wrong corner 6/14   wrong height 11/14
#
# Pre-R1 all three are identical: deception is worth exactly nothing (plan §5.1,
# "the goalie has no concept of being wrong"). Under R1 an honest shot is read
# exactly as well as before — that is the guard against "make the goalie worse"
# passing as "make disguise pay" — while selling the wrong height converts.
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
# The wind-up can also sell the wrong HEIGHT: declaring a flat shot and firing
# high misleads the leg read (butterfly drop) instead of the arm read.
const LOFT_FLAT_DECLARED: int = 0

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
#   deficit    — THE ACCEPTANCE METRIC. Reach gap minus what the arm can physically
#                cover in the time left. Continuous, zero-variance, and validated:
#                in this sweep every GOAL sits at deficit >= 0 and every save
#                below, with only two straddlers inside +/-0.13 m. Its zero
#                crossing IS the save/goal boundary, so it is not a proxy for the
#                outcome — it is the same physics at full resolution.
#   reach_gap   — the raw metres behind the deficit, reported for interpretability.
#   goals       — the coarse outcome. NOT the acceptance metric, and not because
#                of variance (this sweep has none — no scatter, no RNG, bit
#                reproducible) but because of QUANTIZATION: one goal is 7
#                percentage points, and each shot is a deterministic step
#                function, so a ~0.03 m effect flips a spot only if that spot's
#                margin happens to lie within 0.03 m of the boundary. Goals
#                become meaningful once an effect is large enough to cross zero
#                on several spots — which is exactly what R1 does, so the R1
#                assertions key on goals while the pre-R1 defect keys on deficit.
#
# Both metrics key on the NEAREST ARM (glove or blocker), not the glove alone —
# see _reach_metrics. Only the PAIRED DELTA between the two sweeps is meaningful
# anyway: the spots are identical in both, so difference-of-means is the paired
# difference.
func _sweep(disguise: bool, declared_loft: int = LOFT_HIGH) -> Dictionary:
	var goals: int = 0
	var saves: int = 0
	var shots: int = 0
	var gap_sum: float = 0.0
	var deficit_sum: float = 0.0
	for spot: Vector2 in SPOTS:
		for side: int in [-1, 1]:
			var shooter := Vector3(spot.x, 0.0, GOAL_Z + spot.y)
			var aim := Vector3(float(side) * CORNER_X, 0.0, GOAL_Z)
			var declared := aim
			if disguise:
				declared = Vector3(float(-side) * CORNER_X, 0.0, GOAL_Z)
			# `declared_loft` is the second deception axis: selling a LOW shot and
			# firing HIGH misleads the butterfly drop, not just the arm.
			_h.hold_windup(shooter, declared, declared_loft, POWER_T, WINDUP_TICKS)
			# Where the pre-lean has parked the glove vs. where the shot will cross
			# the goalie's plane — the travel the arm still owes at release.
			var m: Vector2 = _reach_metrics(shooter, aim)
			var gap: float = m.x
			gap_sum += gap
			deficit_sum += m.y
			var outcome: int = _h.fire_release(shooter, aim, LOFT_HIGH, POWER_T, 0.0)
			gut.p("  spot(%+.1f,%.1f) side=%+d  gap=%.3f deficit=%+.3f -> %s" % [
					spot.x, spot.y, side, gap, m.y,
					"GOAL" if outcome == Harness.GOAL else "save"])
			shots += 1
			if outcome == Harness.GOAL:
				goals += 1
			elif outcome == Harness.SAVE:
				saves += 1
	return {
		"goals": goals, "saves": saves, "shots": shots,
		"mean_gap": gap_sum / maxf(float(shots), 1.0),
		"mean_deficit": deficit_sum / maxf(float(shots), 1.0),
	}


# Reach metrics at the instant of release, returned as (gap, deficit):
#
#   gap     — lateral distance the glove must still cover: |glove_x now − shot_x
#             where the shot crosses the goalie's depth plane|.
#   deficit — gap MINUS what the arm can physically cover in the time left:
#             glove_react_max_speed × (flight_time − effective_arm_delay). A
#             positive deficit means the arm cannot get there; the shot beats him
#             by arm geometry.
#
# The deficit is the better instrument, and it is why raw centimetres alone
# mislead: 0.025 m of extra travel is decisive on a 0.30 s flight and irrelevant
# on a 0.90 s one. Normalising by the reach budget prices the same displacement
# correctly at every range, in the goalie's OWN physical units (the same speed cap
# and arm delay he actually runs), and it is outcome-predictive — so a continuous,
# zero-variance, 14-shot sweep can say something about goals without needing the
# goal counter's 1-in-14 resolution.
#
# `effective_arm_delay` folds in the pre-arm the way _on_puck_released does
# (arm_cut = reaction_delay − prearmed_reaction_delay), since every shot in this
# sweep carries a full windup read.
func _reach_metrics(shooter: Vector3, aim: Vector3) -> Vector2:
	var vel: Vector3 = _h.shot_velocity(shooter, aim, LOFT_HIGH, POWER_T, 0.0)
	if absf(vel.z) < 0.001:
		return Vector2.ZERO
	var t: float = (_goalie.global_position.z - shooter.z) / vel.z
	if t <= 0.0:
		return Vector2.ZERO
	var shot_x: float = shooter.x + vel.x * t
	# NEAREST ARM, not the glove alone. The goalie has two, on opposite sides, and
	# on an elevated shot either can make the save (the pads are out of it). Keying
	# on the glove alone measures glove-side-vs-blocker-side — a ~1 m swing that
	# swamps the ~0.03 m disguise effect and predicts outcomes badly, since a
	# far-from-the-glove shot is usually the blocker's easy save.
	var gap: float = minf(
			absf(_goalie.get_glove_world_position().x - shot_x),
			absf(_goalie.get_blocker_world_position().x - shot_x))
	var arm_cut: float = maxf(_ctrl.reaction_delay - _ctrl.prearmed_reaction_delay, 0.0)
	var eff_delay: float = maxf(_ctrl.arm_reaction_delay - arm_cut, 0.0)
	var budget: float = _ctrl.glove_react_max_speed * maxf(t - eff_delay, 0.0)
	return Vector2(gap, gap - budget)


func _report(label: String, d: Dictionary) -> void:
	gut.p("%-28s goals=%2d/%d  mean deficit=%+.3f m" % [
			label, d["goals"], d["shots"], d["mean_deficit"]])


func test_disguise_delta() -> void:
	# CONTROL: the identical sweep with the read lag disabled — belief == truth,
	# i.e. exactly the pre-R1 goalie. Running it here rather than trusting a
	# recorded baseline means the A/B shares every other detail of the instrument.
	_ctrl.read_lag = 0.0
	var off_tele: Dictionary = _sweep(false)
	var off_lat: Dictionary = _sweep(true)
	var off_high: Dictionary = _sweep(false, LOFT_FLAT_DECLARED)

	_ctrl.read_lag = GoalieSkillProfile.hard().read_lag_s
	var on_tele: Dictionary = _sweep(false)
	var on_lat: Dictionary = _sweep(true)
	var on_high: Dictionary = _sweep(false, LOFT_FLAT_DECLARED)

	gut.p("── read_lag = 0 (pre-R1: the goalie always knows the destination) ──")
	_report("telegraphed", off_tele)
	_report("disguised (wrong corner)", off_lat)
	_report("disguised (wrong height)", off_high)
	gut.p("── read_lag = %.2f s (R1) ──" % [_ctrl.read_lag])
	_report("telegraphed", on_tele)
	_report("disguised (wrong corner)", on_lat)
	_report("disguised (wrong height)", on_high)

	# 1. Telegraphed shots must NOT get easier. R1 only makes him wrong when he was
	#    MISLED; a stable aim means the stale sample equals the truth, so an honest
	#    shot is read exactly as well as before. This is the guard that stops
	#    "make the goalie worse" passing as "make disguise pay".
	assert_eq(on_tele["goals"], off_tele["goals"],
			"a telegraphed shot must be read exactly as well after R1 as before")
	assert_almost_eq(on_tele["mean_deficit"], off_tele["mean_deficit"], 0.01,
			"...and must leave the goalie the same reach margin at release")

	# 2. Deception must pay, on the LATERAL axis. Selling the wrong CORNER
	#    misleads the ARM read; selling the wrong HEIGHT misleads the LEG read
	#    (the butterfly drop) and is reported below but deliberately unpinned —
	#    see the note there.
	#
	#    ── UPDATE: WRONG CORNER NOW CONVERTS TOO (2026-07) ─────────────────────
#    It used to cost reach without converting, and the cause was not the arm's
#    budget: _apply_elevated_shot_reaction OVERWROTE the read belief with the
#    live puck trajectory, so the hands went to the true intercept every tick
#    while the legs used the belief. Lateral deception measured at exactly zero
#    — telegraphed, step look-off and swept look-off gave identical goals AND
#    identical save parts. Height worked only because it rides the leg drop.
#
#    Two changes fixed it: the arms now aim at the belief, and `read_lag` was
#    split from `read_converge_time` (it used to set both, so the deception
#    window could not be lengthened without also making the pre-read staler).
#    Measured across converge time, with the telegraphed CONTROL pinned at 7
#    throughout — honest shots never get easier:
#
#        converge   telegraph   wrongCorner   swept   wrongHeight
#          0.05 s        7            7         7          7
#          0.10 s        7            9         8         11
#          0.13 s        7           10         8         11
#          0.20 s        7           10         8         11
#
#    The swept arm saturates lower than the step arm, correctly: a sweep that
#    FINISHES on the true corner leaves the belief nearly right at release, so
#    it deceives less than one that never moves off the decoy.
#
#    ARM INERTIA WAS TRIED AND DOES NOTHING — recorded so it is not retried. A
#    second-order servo on the reach (acceleration cap instead of a pure speed
#    clamp, the shape SkaterController.max_blade_accel uses) was built and swept
#    from 80 down to 18 m/s²; every column was identical to the first-order
#    version at every value. The reason is the same one that makes reach SPEED
#    irrelevant here: the distances are short next to the arm's capability. The
#    reach to a corner is ~0.26 m, about 0.05 s of a 0.21 s flight, so the arm
#    arrives and PARKS. When the belief converges it starts again from rest, and
#    a servo that models momentum has no momentum to bite on. The binding
#    constraint in this whole system is the BELIEF, not the arm's kinematics.
#
#    The reach DEFICIT cannot measure R1 at all — it is sampled at the instant
	#    of release, before the read has been acted on, so it sees only the
	#    pre-lean. It was the right instrument for the PRE-R1 defect (where the
	#    pre-lean was the only channel deception reached); goals are the right one
	#    for R1, and they work here precisely because the effect is now large
	#    enough to cross the save/goal boundary on several spots.
	# 3. And deception must be worth more than honesty, under R1. LATERAL ONLY.
	assert_gt(on_lat["mean_deficit"], on_tele["mean_deficit"],
			"selling the wrong corner must at least cost him reach margin")

	# ── HEIGHT DISGUISE IS REPORTED, NOT ASSERTED (2026-07) ──────────────────
	# Selling a flat shot and firing high is a DEGENERATE mechanic and is
	# deliberately not a design goal, so the wrong-height arm above is kept as a
	# measurement and nothing keys on it. It used to assert, and what those
	# assertions actually pinned was an artifact: this sweep never re-settles
	# between shots, so the goalie is at exactly shuffle_speed with an unset
	# fraction of 0.80 at EVERY release, and the height result tracked the
	# caught-moving read latency rather than read_lag. Settle him properly and
	# the pre-existing effect was 3 goals vs 2 — inside the sweep's own stated
	# 1-in-14 quantization. Do not re-add an assertion here without first fixing
	# the instrument's set-goalie premise.
	#
	# The LATERAL arm above is the axis the design cares about, and it is the one
	# with a mechanism behind it (arms aim at the belief; see the UPDATE block).
	# It is measured through the same unsettled goalie, so its magnitude carries
	# the same caveat — hence the deficit assertion rather than a goal count.


# ── SWEPT look-off: the arm the step-disguise cannot measure ─────────────────
# `_sweep`'s disguise is a STEP — the declared aim is parked on the decoy for the
# whole wind-up and jumps to the real corner at release. That shape cannot
# distinguish a goalie reading the LIVE aim from one reading a stale sample,
# because an aim that never moves makes stale == live by construction.
#
# This is the human gesture instead: hold LMB, coil toward the decoy, then drag
# the cursor across and release. Now the two differ — a live read follows the
# cursor over and arrives re-aimed; a stale read is still parked `read_lag`
# behind it.
#
# ── MEASURED (2026-07) ───────────────────────────────────────────────────────
# Built to test a hypothesis: that the pre-lean reading the LIVE aim was eating
# the payoff for corner deception (wrong corner buys reach margin but converts no
# goals, while wrong height converts). It is not.
#
#   swept        live pre-lean     stale pre-lean (`_lagged_aim`)
#   ticks        lag .05 / .13     lag .05      lag .13
#     6          -0.1514 (both)    -0.1486      -0.1493
#    12          -0.1529 (both)    -0.1436      -0.1496
#    24          -0.1515 (both)    -0.1411      -0.1388
#    48          -0.1621 (both)    -0.1521      -0.1348
#
# Goals identical in every cell. The live column is lag-INVARIANT, which is the
# defect stated plainly: `read_lag` never reached the hands. Feeding the lean the
# stale sample connects them, and the effect grows with the lag as it should — but
# it is 1-3 cm on a ~15 cm gap and flips nothing.
#
# So the real answer to "why doesn't wrong-corner convert at 5-9 m" is the one
# already in test_disguise_delta's comment: the arm's reach budget is big enough
# to re-aim. The disguised deficit is -0.15 m — the arm covers the gap with 15 cm
# to spare, and deception buys 8. The lever is the budget, not the read.
#
# Report-only. `deficit` is the metric that matters here: the existing test notes
# it is sampled at release and therefore "sees only the pre-lean", which is
# exactly the channel under examination. Higher (less negative) = the arm owes
# more travel than it can cover = the deception bought something.
func _swept(sweep_ticks: int) -> Dictionary:
	var goals: int = 0
	var shots: int = 0
	var deficit_sum: float = 0.0
	for spot: Vector2 in SPOTS:
		for side: int in [-1, 1]:
			var shooter := Vector3(spot.x, 0.0, GOAL_Z + spot.y)
			var aim := Vector3(float(side) * CORNER_X, 0.0, GOAL_Z)
			var decoy := Vector3(float(-side) * CORNER_X, 0.0, GOAL_Z)
			_h.sweep_windup(shooter, decoy, aim, LOFT_HIGH, POWER_T,
					WINDUP_TICKS, sweep_ticks)
			deficit_sum += _reach_metrics(shooter, aim).y
			if _h.fire_release(shooter, aim, LOFT_HIGH, POWER_T, 0.0) == Harness.GOAL:
				goals += 1
			shots += 1
	return {
		"goals": goals, "shots": shots,
		"mean_deficit": deficit_sum / maxf(float(shots), 1.0),
	}


func test_report_swept_look_off() -> void:
	# Both lags: HARD's (the sharpest goalie, shortest lag) and the controller's
	# authored default, which the easier profiles sit at or above. If the stale
	# pre-lean were going to matter anywhere it would be at the LONGER lag, where
	# a live read and a stale one are furthest apart.
	for lag: float in [GoalieSkillProfile.hard().read_lag_s,
			GoalieController.new().read_lag]:
		_ctrl.read_lag = lag
		var tele: Dictionary = _sweep(false)
		var step: Dictionary = _sweep(true)
		gut.p("read_lag = %.2f s (%d ticks). Sweep = cursor dragged decoy → real corner"
				% [lag, int(round(lag * 120.0))])
		gut.p("  %-26s goals=%2d/%d  mean deficit=%+.4f m"
				% ["telegraphed", tele["goals"], tele["shots"], tele["mean_deficit"]])
		gut.p("  %-26s goals=%2d/%d  mean deficit=%+.4f m"
				% ["step look-off (existing)", step["goals"], step["shots"],
				step["mean_deficit"]])
		for ticks: int in [6, 12, 24, 48]:
			var d: Dictionary = _swept(ticks)
			gut.p("  swept %2d ticks (%.2f s)  goals=%2d/%d  deficit=%+.4f m  (vs tele %+.4f)"
					% [ticks, float(ticks) / 120.0, d["goals"], d["shots"],
					d["mean_deficit"], d["mean_deficit"] - float(tele["mean_deficit"])])
	assert_true(true, "report")


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
