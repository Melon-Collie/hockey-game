extends GutTest

# ── The goalie's STICK harness ───────────────────────────────────────────────
# Measures the live keeper's real cover along the ice, which is the surface the
# planning model was blind to. Firing flat shots and sweeping the aim outward
# gives the point where saves stop — the effective LOW-band half-width, stick
# included — and the model constants that mirror it
# (GoalieBehaviorRules.STANDING_STICK_REACH_X_M / STICK_BLADE_WIDTH_M) are
# pinned by this, exactly as HOLE_BAND_CORE[LOW] is pinned by the pad span.
#
# WHAT IT FOUND (2026-07): inside 7 m NOTHING scores at any aim point, out to
# the post, on either side — the standing keeper covers the whole low net. At
# 9 m the edge is 0.65 m from his plane, at 12 m 0.62 m. The planning model was
# using 0.36 m (the pad column alone), because the goalie's own paddle was not
# modelled at any band. Backing out the reaction push brackets the true standing
# reach at 0.59-0.64 m.
#
# Note the symmetry: both sides measure identically, because the blade-aim solve
# yaws the paddle toward the threat. This keeper's stick is NOT a stick-side-only
# asset the way a real goalie's is, so a symmetric cover term is the honest model.
#
# Report-only. Re-run this before touching either constant.

const Harness := preload("res://tests/unit/ai/real_goalie_shot_harness.gd")
const GOAL_Z: float = -GameRules.GOAL_LINE_Z

var _goalie: Node = null
var _puck: Node = null
var _shooter: Skater = null
var _ctrl: GoalieController = null
var _h: RefCounted = null
var _goal := Vector3(0.0, 0.0, -GameRules.GOAL_LINE_Z)


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


func test_measure_low_cover_edge() -> void:
	var max_a: float = GameRules.NET_HALF_WIDTH \
			- GameRules.NET_POST_RADIUS - GameRules.PUCK_COLLISION_RADIUS
	gut.p("Flat shots, zero scatter. Edge = smallest |aim_x| that SCORES.")
	gut.p("model standing core = %.3f m, butterfly core = %.3f m"
			% [AIActionScoring.LOW_CORE_STANDING_M,
			AIActionScoring.HOLE_BAND_CORE[AIActionScoring.HOLE_BAND_LOW]])
	gut.p("dist  depth | side  edge@goal  edge@keeper   parts")
	for dist: float in [3.0, 5.0, 7.0, 9.0, 12.0]:
		var spot := Vector3(0.0, 0.0, GOAL_Z + dist)
		_ctrl.reset_to_crease()
		_h.settle(spot, 120)
		var depth: float = absf(_goalie.global_position.z - GOAL_Z)
		for side: float in [-1.0, 1.0]:
			var edge: float = INF
			var parts := {}
			var a: float = 0.20
			while a <= max_a + 0.001:
				_ctrl.reset_to_crease()
				_h.settle(spot, 120)
				var aim := Vector3(side * a, 0.0, GOAL_Z)
				var o: int = _h.fire(spot, aim, ShotMechanics.ELEVATION_FLAT, 1.0, 0.0)
				if o == Harness.GOAL:
					if edge == INF:
						edge = a
				elif o == Harness.SAVE:
					var k: String = str(_h.last_part)
					parts[k] = int(parts.get(k, 0)) + 1
				a += 0.04
			var at_keeper: float = edge * (dist - depth) / dist if edge != INF else INF
			gut.p("%4.1f  %5.2f | %+3.0f   %8.2f  %10.2f   %s"
					% [dist, depth, side, edge, at_keeper, str(parts)])
	assert_true(true)
