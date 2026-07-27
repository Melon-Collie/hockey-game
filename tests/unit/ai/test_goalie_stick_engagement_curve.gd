extends GutTest

# ── CHARACTERISATION: how hard does the stick play the puck? ─────────────────
# Pins the CURRENT stick-engagement decision before it is replaced by a model,
# the same way test_goalie_depth_curve pinned the Buckley chart and
# test_goalie_drop_decision_curve pinned the butterfly. Nothing here asserts the
# behaviour is right — it reports what it IS.
#
# ── THE DECISION TODAY ───────────────────────────────────────────────────────
# FOUR independent predicates, each with its own hand-picked distance, all
# answering one question ("how aggressively does the blade play this puck?"):
#
#   _is_blade_intent_active()    carrier < 2.5 m, or loose < 1.5 m + a shooter
#   _is_standing_sweep_active()  upright, puck < 2.0 m, shooter near, carrier
#                                slow (<= 3.0 m/s) or loose
#   _is_paddle_sweep_active()    down, puck < 1.5 m, shooter near
#   _should_lunge()              puck < 1.2 m, slot side, shooter near
#
#   active_blade_carrier_radius     2.5 m
#   standing_sweep_trigger_distance 2.0 m
#   paddle_sweep_trigger_distance   1.5 m
#   lunge_trigger_distance          1.2 m
#
# Four numbers on one ladder — the same signature the butterfly had before it
# became a race (2.5 / 2.0 / 1.5 / 1.2 there too, which is not a coincidence:
# both ladders were authored against "about two stick lengths").
#
# ── WHAT THE LADDER ACTUALLY IS ──────────────────────────────────────────────
# The three actions differ by HOW MUCH OF HIMSELF HE COMMITS, not by distance:
#
#   mild intent   wrist yaw only (ACTIVE_YAW_CAP_DEG 25). Costs nothing.
#   sweep         arm extends laterally, hand drops. The blocker pad leaves its
#                 post. Recoverable.
#   lunge         the whole assembly jabs forward 0.35 m. Fully unset while
#                 extended — _movement_read_delay already prices a committed
#                 lunge as the gamble it is.
#
# So the grounded rule is plausibly "use the LEAST commitment that reaches",
# with each action's reach falling out of geometry GoalieStickRules already
# owns (blade offset, yaw cap, extension), and the lunge carrying an extra gate
# because a miss concedes. That is the hypothesis this instrument exists to
# measure against — not a conclusion.

# ── WHAT IT MEASURED (2026-07) ───────────────────────────────────────────────
#  dist  goalie blade | UPRIGHT, carrier still  | carrier 5 m/s     | loose puck
#   0.8   0.08  0.24 | mild stand   .   LUNGE  | mild  .  .  LUNGE | mild . paddle LUNGE
#   1.0   0.69  0.20 | mild stand   .   LUNGE  | mild  .  .  LUNGE | mild . paddle LUNGE
#   1.2   0.74  0.19 | mild stand   .   LUNGE  | mild  .  .  LUNGE | mild . paddle LUNGE
#   1.5   0.83  0.15 | mild stand   .   LUNGE  | mild  .  .  LUNGE | mild . paddle  .
#   1.8   1.08  0.35 | mild stand   .   LUNGE  | mild  .  .  LUNGE |  .   .   .     .
#   2.0   1.28  0.57 | mild stand   .     .    | mild  .  .    .   |  .   .   .     .
#   2.5   1.78  1.04 | mild stand   .     .    | mild  .  .    .   |  .   .   .     .
#   3.0   2.28  1.55 | mild   .     .     .    | mild  .  .    .   |  .   .   .     .
#
# THREE THINGS FALL OUT.
#
# 1. THE LADDER IS INVERTED IN PRACTICE. `goalie_poke_radius` is 0.25 m, and the
#    BLADE is already 0.15-0.24 m from the puck in every row where the lunge
#    fires. He is spending the most expensive action he has — fully unset while
#    extended, priced as a gamble in _movement_read_delay — in exactly the
#    situations where the cheapest one is already touching the puck. The lunge
#    should be what he reaches for when the blade CANNOT get there, and it is
#    firing when it demonstrably can.
#
# 2. NONE OF THE FOUR CONSTANTS IS THE BOUNDARY A SHOOTER FEELS. They measure
#    goalie-to-puck while the goalie is challenging out, so the effective
#    carrier-distance boundary is roughly double the constant and moves with his
#    depth. The lunge's 1.2 m fires out to a 1.8 m carrier; the standing sweep's
#    2.0 m fires past 2.5 m. Same defect the butterfly ladder had.
#
# 3. THE PREDICATES ARE NOT EXCLUSIVE. mild + stand + LUNGE are simultaneously
#    live in most upright rows, and precedence is resolved somewhere else
#    entirely (the pose builder). Nobody chose that order — the same latent
#    fragility the depth chart and the drop chain both had.
#
# The "loose puck" columns are not upright, and that is correct: a loose puck
# with an opponent on it is a BLOCK (GoalieSaveSelection), so he has already
# dropped and the paddle sweep is the down-state action. They agree with the
# forced-butterfly rows below, which is the consistency check.

# ── AFTER the lunge model (2026-07) ──────────────────────────────────────────
#  dist  goalie blade | UPRIGHT, carrier still  | carrier 5 m/s     | loose puck
#   0.8   0.08  0.27 | mild stand   .   LUNGE  | mild  .  .  LUNGE | mild . paddle LUNGE
#   1.0   0.69  0.20 | mild stand   .     .    | mild  .  .  LUNGE | mild . paddle  .
#   1.2   0.74  0.19 | mild stand   .     .    | mild  .  .  LUNGE | mild . paddle  .
#   1.5   0.83  0.20 | mild stand   .     .    | mild  .  .  LUNGE | mild . paddle LUNGE
#   1.8   1.08  0.27 | mild stand   .   LUNGE  | mild  .  .  LUNGE |  .   .   .     .
#   2.0   1.28  0.57 | mild stand   .   LUNGE  | mild  .  .    .   |  .   .   .     .
#   2.5   1.78  1.04 | mild stand   .     .    | mild  .  .    .   |  .   .   .     .
#   3.0   2.28  1.55 | mild   .     .     .    | mild  .  .    .   |  .   .   .     .
#
# The lunge now tracks the BLADE gap against the poke radius (0.25) and the jab's
# own extension (0.35), so it fires in exactly one band: 0.25 < gap <= 0.60.
#   * 1.0-1.5 m: blade at 0.19-0.20, INSIDE poke range — no jab. He does not need
#     one; the per-tick poke check is already stripping from there. This is the
#     defect the characterisation found, gone.
#   * 1.8-2.0 m: blade at 0.27-0.57, just out of reach — jab. What it is for.
#   * 2.5 m+:    blade at 1.04+, out of reach even extended — no jab. Flailing at
#     a puck he was never going to touch is pure cost.
#
# NOT MONOTONIC in carrier distance, deliberately. The blade gap is not monotonic
# either — it moves with his challenge depth and pose — and "can my stick reach
# you" is the honest question, not "how far away are you". A shooter feels the
# blade, which is why the trigger is measured there.
#
# The two sweeps are UNCHANGED and that is on purpose. They are COVERAGE (extend
# the paddle, widen the low silhouette) rather than a strike, so "does it reach
# the puck" is the wrong test for them; they are still worth doing when they do
# not touch it. Only the lunge is a gamble that pays nothing unless it connects.

const Harness := preload("res://tests/unit/ai/real_goalie_shot_harness.gd")
const GOAL_Z: float = -GameRules.GOAL_LINE_Z
const DT: float = 1.0 / 120.0
const SkaterScene := preload("res://Scenes/Skater.tscn")

var _goalie: Node = null
var _puck: Node = null
var _shooter: Skater = null
var _ctrl: GoalieController = null
# Filled by the last _engagement() call — the distances the predicates actually
# see, which are NOT the carrier distance the rows are keyed on.
var last_gap: float = 0.0
var last_blade_gap: float = 0.0
var last_down: bool = false


func before_each() -> void:
	_goalie = load("res://Scenes/Goalie.tscn").instantiate()
	_puck = load("res://Scenes/Puck.tscn").instantiate()
	_shooter = SkaterScene.instantiate() as Skater
	_ctrl = GoalieController.new()
	for n: Node in [_goalie, _puck, _shooter, _ctrl]:
		add_child_autofree(n)
	_shooter.set_physics_process(false)
	_shooter.set_process(false)
	_ctrl.set_skater_getter(func() -> Array: return [_shooter])
	_ctrl.setup(_goalie, _puck, GOAL_Z, true)


# Settle the scene with the puck `d` metres out and report which stick actions
# are live. `carried` puts it on an opposing carrier's blade; `speed` is that
# carrier's velocity; `down` forces the butterfly first.
func _engagement(d: float, carried: bool, speed: float, down: bool) -> String:
	_ctrl.reset_to_crease()
	var at := Vector3(0.0, 0.0, GOAL_Z + d)
	_shooter.global_position = at
	_shooter.velocity = Vector3(speed, 0.0, 0.0)
	_shooter.current_shot_state = SkaterStateMachine.State.SKATING_WITH_PUCK
	if carried:
		_puck.set_carrier(_shooter)
	else:
		_puck.clear_carrier()
	if down:
		_ctrl._enter_butterfly()
	for _i: int in 40:
		_shooter.global_position = at
		_puck.global_position = at
		_puck.linear_velocity = Vector3.ZERO
		_ctrl._physics_process(DT)
	last_gap = _goalie.global_position.distance_to(_puck.global_position)
	last_blade_gap = _goalie.get_blade_world_position().distance_to(_puck.global_position)
	last_down = _ctrl._sm.is_down()
	var out: String = ""
	out += "mild " if _ctrl._is_blade_intent_active() else "  .  "
	out += "stand " if _ctrl._is_standing_sweep_active() else "   .  "
	out += "paddle " if _ctrl._is_paddle_sweep_active() else "    .  "
	out += "LUNGE" if _ctrl._should_lunge() else "  .  "
	return out


func test_report_the_stick_engagement_surface() -> void:
	gut.p("Which stick actions are live?  (settled 0.33 s, puck dead centre)")
	gut.p("⚠️ `dist` is CARRIER distance from the goal line. The predicates all")
	gut.p("   measure GOALIE-to-puck, and he challenges out — so `goalie` below is")
	gut.p("   what they actually see, and it is roughly half the row label. None of")
	gut.p("   the four constants is the boundary a shooter experiences.")
	gut.p(" dist  goalie blade | UPRIGHT, carrier still  | UPRIGHT, carrier 5 m/s  | loose puck")
	for d: float in [0.8, 1.0, 1.2, 1.5, 1.8, 2.0, 2.5, 3.0]:
		var a: String = _engagement(d, true, 0.0, false)
		var g: float = last_gap
		var bg: float = last_blade_gap
		gut.p("%5.1f  %5.2f %5.2f | %-23s | %-23s | %s"
				% [d, g, bg, a, _engagement(d, true, 5.0, false),
				_engagement(d, false, 0.0, false)])
	gut.p("")
	gut.p(" dist | BUTTERFLY, carrier still | BUTTERFLY, loose puck")
	for d: float in [0.8, 1.0, 1.2, 1.5, 1.8, 2.0, 2.5]:
		gut.p("%5.1f | %-24s | %s"
				% [d, _engagement(d, true, 0.0, true),
				_engagement(d, false, 0.0, true)])
	gut.p("")
	gut.p("NOTE the \"loose puck\" columns are not upright — a loose puck with an")
	gut.p("opponent on it is a BLOCK (GoalieSaveSelection), so he has already")
	gut.p("dropped and the paddle sweep is the down-state action. The forced-down")
	gut.p("rows above and the loose columns therefore agree, which is correct.")
	gut.p("")
	gut.p("Derived stick geometry (GoalieStickRules):")
	gut.p("  standing lateral reach   %.3f m   (blade centre at the yaw cap + half-width)"
			% GoalieStickRules.standing_lateral_reach())
	gut.p("  blade width              %.3f m" % GoalieStickRules.BLADE_WIDTH_M)
	gut.p("  active yaw cap           %.0f deg" % GoalieStickRules.ACTIVE_YAW_CAP_DEG)
	var gc: GoalieController = autofree(GoalieController.new())
	gut.p("  lunge extension          %.2f m forward, %.2f s window, %.2f s cooldown"
			% [gc.lunge_extension, gc.lunge_duration, gc.lunge_cooldown])
	gut.p("  poke radius              %.2f m" % gc.goalie_poke_radius)
	assert_true(true, "report")
