extends GutTest

# ── THE DEPTH SOLVE RUNS IN TWO OF FOURTEEN STATES ───────────────────────────
# `_update_depth` composes the whole ladder — challenge ceiling, physical
# standoff, lateral tracking cap, backdoor re-square cap, rush backflow — through
# `GoalieDepthSolver`, and early-returns before any of it for RVH, VH, BUTTERFLY,
# COILING, SLIDING, COVERING, PLAYING_PUCK and both CATCHING states. RECOVERING
# gets a plain fade to `depth_defensive`. So the solve runs in STANDING and READY
# and nowhere else.
#
# What that is worth is a question of DWELL, not of the branch, and the branch on
# its own overstates it. Measured here:
#
#   an idle butterfly freezes the depth COMPLETELY — 0.000 m of movement while the
#   carrier walks 2 m → 8 m → 2 m, against 0.351 m for the same walk on his feet;
#
#   but the DWELL decides whether that matters, and it splits hard on
#   `recovery_proximity_threshold` (2.4 m):
#
#     carrier 2.5 m and out   froze at 1.749 m, held 0.34 s, then recovered
#     carrier 1.8 m           froze at 1.200 m, held 5.00 s — never recovered
#     carrier 1.2 m           froze at 0.600 m, held 5.00 s — never recovered
#
# So the freeze is harmless at range and unbounded in tight, because
# `_is_threat_pressing`'s proximity clause pins him there. A carrier who stops
# inside 2.4 m gets a goalie frozen at whatever depth he happened to drop at, for
# as long as he cares to stand there — 1.2 m out, in the 1.8 m case.
#
# That is the measured version of "he butterflies too far from the net": not that
# the drop picks a bad depth, but that nothing revisits it afterwards.
#
# COILING and SLIDING are excluded throughout: the slide captured its own
# endpoints and owning depth is its job, so counting those ticks reports a
# committed slide as though the butterfly had re-solved.

const GOAL_Z: float = -GameRules.GOAL_LINE_Z
const DT: float = 1.0 / 120.0
const SkaterScene := preload("res://Scenes/Skater.tscn")

var _goalie: Node = null
var _puck: Node = null
var _shooter: Skater = null
var _ctrl: GoalieController = null


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


func _place(dist: float) -> void:
	_shooter.global_position = Vector3(0.0, 0.0, GOAL_Z + dist)
	_shooter.velocity = Vector3.ZERO
	_puck.global_position = _shooter.global_position
	_puck.linear_velocity = Vector3.ZERO


func _settle(dist: float) -> void:
	_shooter.current_shot_state = SkaterStateMachine.State.SKATING_WITH_PUCK
	_shooter.predicted_shot_velocity = Vector3.ZERO
	_place(dist)
	_puck.set_carrier(_shooter)
	_ctrl.reset_to_crease()
	for _i: int in 240:
		_place(dist)
		_ctrl._physics_process(DT)


# Walk the carrier out and back over 5 s, sampling his challenge radius only on
# ticks in the stance under test. Returns the span it covered and the dwell.
func _sweep(from_d: float, to_d: float, down: bool) -> Dictionary:
	_settle(from_d)
	if down:
		_ctrl._sm.transition_to(GoalieStateMachine.State.BUTTERFLY)
	var lo: float = INF
	var hi: float = -INF
	var dwell: float = 0.0
	var ticks: int = 300
	for i: int in ticks * 2:
		var t: float = float(i) / float(ticks)
		_place(lerpf(from_d, to_d, t) if t <= 1.0 else lerpf(to_d, from_d, t - 1.0))
		_ctrl._physics_process(DT)
		var counts: bool = (_ctrl.stance() == GoalieStateMachine.State.BUTTERFLY) \
				if down else _ctrl._sm.is_upright()
		if counts:
			dwell += DT
			lo = minf(lo, _ctrl.challenge_radius())
			hi = maxf(hi, _ctrl.challenge_radius())
	return {"lo": lo, "hi": hi, "span": hi - lo, "dwell": dwell}


# ── THE CONTROL ──────────────────────────────────────────────────────────────
func test_upright_depth_follows_the_threat() -> void:
	var r: Dictionary = _sweep(2.0, 8.0, false)
	gut.p("UPRIGHT | %.2f s | radius %.3f..%.3f, span %.3f m"
			% [r["dwell"], r["lo"], r["hi"], r["span"]])
	assert_gt(r["span"] as float, 0.30,
			"a standing goalie re-solves his depth as the threat moves")


# ── THE FREEZE ───────────────────────────────────────────────────────────────
func test_idle_butterfly_freezes_the_depth_completely() -> void:
	var r: Dictionary = _sweep(2.0, 8.0, true)
	gut.p("IDLE BUTTERFLY | %.2f s | radius %.3f..%.3f, span %.3f m"
			% [r["dwell"], r["lo"], r["hi"], r["span"]])
	assert_gt(r["dwell"] as float, 0.1,
			"precondition: he held the stance long enough to measure")
	assert_lt(r["span"] as float, 0.02,
			"an idle butterfly does not re-solve depth at all — it holds the entry value")


# ── AND HOW LONG IT LASTS, which is what decides whether it matters ──────────
func test_the_freeze_window_and_the_depth_it_freezes_at() -> void:
	var in_tight: float = 0.0
	var at_range: float = 0.0
	for dist: float in [1.2, 1.8, 2.5, 4.0, 6.0]:
		_settle(dist)
		var standing: float = _ctrl.challenge_radius()
		_ctrl._sm.transition_to(GoalieStateMachine.State.BUTTERFLY)
		var dwell: float = 0.0
		var frozen_at: float = _ctrl.challenge_radius()
		var still_down: bool = true
		for _i: int in 600:
			_place(dist)
			_ctrl._physics_process(DT)
			if _ctrl.stance() != GoalieStateMachine.State.BUTTERFLY:
				still_down = false
				break
			dwell += DT
			frozen_at = _ctrl.challenge_radius()
		gut.p("carrier %.1f m | standing %.3f -> froze at %.3f | held %.2f s (%s)"
				% [dist, standing, frozen_at, dwell,
				"never recovered" if still_down else "then recovered"])
		if dist < _ctrl.recovery_proximity_threshold:
			in_tight = maxf(in_tight, dwell)
		else:
			at_range = maxf(at_range, dwell)
	gut.p("longest freeze: %.2f s inside the %.2f m proximity stay, %.2f s outside it"
			% [in_tight, _ctrl.recovery_proximity_threshold, at_range])
	assert_gt(in_tight, 4.0 * at_range,
			"CHARACTERISATION: the proximity stay is what turns a short freeze into an unbounded one")
