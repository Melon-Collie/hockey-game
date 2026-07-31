extends GutTest

# ── Goalie-tick micro-benchmark (report-only; NOT in the default suite) ──────
# Times GoalieController._physics_process and the eight phases it runs, so the
# goalie's per-tick budget can be ranked instead of guessed at.
#
# Why the goalie specifically: in the session profile its _physics_process
# totalled about what all TEN skaters' Skater._physics_process did — for two
# entities. And unlike anything skater-side, that cost is invariant to who is
# playing: two goalies exist in a bot lobby, a human lobby, and on a dedicated
# server alike, so there is no roster mix in which this stops mattering.
#
# Deliberately its own file rather than a section of the control benchmark. That
# one drives _process_input thousands of times with no Skater._physics_process
# to integrate or clamp between calls, which leaves a skater in a state the game
# can never produce. The goalie's per-tick view SCANS skaters in the tree, so
# sharing a scene let that degenerate state reach it — a native crash, in a
# controller that ticks 4000 times cleanly on its own. The benchmark was wrong,
# not the goalie; separate worlds keep it that way.
#
# Run explicitly:
#   bash .claude/hooks/run-gut.sh -gdir=res://benchmarks
#
# Compare RELATIVELY (phase vs phase, before vs after a change), never as an
# absolute frame cost — a debug build inflates GDScript.

const REPS: int = 3000
# Ticks run before measuring. The tick carries smoothed state (tracked threat,
# depth, body-part lerps), so a cold call measures convergence, not steady play.
const SETTLE_TICKS: int = 240

var _results: Array[Dictionary] = []
var _goalie: Goalie = null
var _puck: Puck = null
var _ctrl: GoalieController = null


func before_all() -> void:
	_goalie = load("res://Scenes/Goalie.tscn").instantiate() as Goalie
	_puck = load("res://Scenes/Puck.tscn").instantiate() as Puck
	add_child_autofree(_goalie)
	add_child_autofree(_puck)

	# A live threat from the slot — the read the goalie holds for most of a
	# shift, where tracking, depth and body-part solving all have real work.
	# Parked at the far end it would benchmark the early-outs instead.
	_puck.global_position = Vector3(1.2, 0.0, GameRules.GOAL_LINE_Z - 6.5)

	_ctrl = GoalieController.new()
	add_child_autofree(_ctrl)
	_ctrl.setup(_goalie, _puck, GameRules.GOAL_LINE_Z, true)
	for _i: int in SETTLE_TICKS:
		_ctrl._physics_process(1.0 / 120.0)


func after_all() -> void:
	if _results.is_empty():
		return
	var widest: int = 0
	for r: Dictionary in _results:
		widest = maxi(widest, (r["label"] as String).length())
	gut.p("")
	gut.p("── Goalie tick cost (µs/call, %d reps) ──" % REPS)
	for r: Dictionary in _results:
		gut.p("  %s  %8.2f" % [(r["label"] as String).rpad(widest), r["us"]])
	gut.p("")


func _bench(label: String, fn: Callable) -> void:
	fn.call()  # warm
	var t0: int = Time.get_ticks_usec()
	for _i: int in REPS:
		fn.call()
	_results.append({
		"label": label,
		"us": float(Time.get_ticks_usec() - t0) / float(REPS),
	})


# Phases are timed with the per-tick view left WARM. The real tick invalidates
# once and the first phase to read it pays the rebuild, so invalidating inside
# every phase would charge that rebuild eight times over and invent a cost that
# does not exist. The gap between the whole tick and the sum of the phases is
# therefore roughly the view rebuild — itself worth knowing.
func test_goalie_tick_costs() -> void:
	var delta: float = 1.0 / 120.0

	_bench("_physics_process (WHOLE TICK)", func() -> void:
		_ctrl._physics_process(delta))

	_bench("  tracking", func() -> void: _ctrl._update_tracking(delta))
	_bench("  shot timer", func() -> void: _ctrl._update_shot_timer(delta))
	_bench("  state", func() -> void: _ctrl._update_state(delta))
	_bench("  depth", func() -> void: _ctrl._update_depth(delta))
	_bench("  position", func() -> void: _ctrl._update_position(delta))
	_bench("  facing", func() -> void: _ctrl._update_facing(delta))
	_bench("  body parts", func() -> void: _ctrl._update_body_parts(delta))
	_bench("  poke", func() -> void: _ctrl._update_goalie_poke(delta))
	_bench("  view invalidate (flag only)", func() -> void: _ctrl._view.invalidate())

	# What one view rebuild actually costs: invalidate, then force the first
	# read. This is the term the warm-phase timings above deliberately exclude.
	_bench("  view invalidate + rebuild", func() -> void:
		_ctrl._view.invalidate()
		_ctrl._update_state(delta))

	assert_true(_results.size() > 0, "goalie benchmark produced results")
