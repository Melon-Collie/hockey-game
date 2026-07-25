extends GutTest

# CHARACTERISATION of the settled depth chart — what the live goalie actually does
# against a stationary threat at range, measured rather than read off the exports.
#
# Depth is no longer a distance curve (see GoalieDepthSolver): it is solved as
# "as far out as the races allow", bounded by a physical standoff. These pin the
# two ends of that solve — the in-close standoff and the unconstrained ceiling —
# and that the result stays monotonic. See plan doc §5.7.

const Harness := preload("res://tests/unit/ai/real_goalie_shot_harness.gd")
const GOAL_Z: float = -GameRules.GOAL_LINE_Z
const SETTLE_TICKS: int = 240   # 2 s — well past the depth rate cap's travel time

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


func _settled_radius(threat_dist: float) -> float:
	_ctrl.reset_to_crease()
	_h.settle(Vector3(0.0, 0.0, GOAL_Z + threat_dist), SETTLE_TICKS)
	return _ctrl._current_depth


func test_depth_curve_against_a_stationary_threat() -> void:
	gut.p("crease top = %.2f m   depth_aggressive = %.2f   depth_base = %.2f" % [
			CreaseRules.STRAIGHT_DEPTH, _ctrl.depth_aggressive, _ctrl.depth_base])
	gut.p(" threat   radius    gap to threat")
	for d: float in [1.0, 1.5, 2.0, 3.0, 5.0, 8.0, 10.0, 12.0]:
		var r: float = _settled_radius(d)
		gut.p("%6.1f   %6.2f   %+6.2f" % [d, r, d - r])
	# A reporting test, but it should still fail loudly if the chart stops being
	# monotonic — depth must never increase as the threat gets closer.
	assert_true(_settled_radius(1.0) < _settled_radius(3.0),
			"depth must not grow as the threat closes")


func test_unconstrained_threat_is_challenged_to_the_ceiling() -> void:
	# A stationary threat with no receiver and no rush is a clean 1v0: nothing
	# binds the re-square race, so challenging hard is the correct read and the
	# solve goes to the ceiling.
	for d: float in [3.0, 5.0, 8.0]:
		assert_almost_eq(_settled_radius(d), _ctrl.depth_aggressive, 0.02,
				"unconstrained threat at %.0f m is challenged to the ceiling" % d)


func test_the_standoff_keeps_him_off_the_puck_in_tight() -> void:
	# THE FIX. The old chart ramped toward aggressive depth at `zone_post_z`, which
	# left the goalie 0.07 m from a threat at 1 m and 0.25 m at 2 m — standing on
	# the puck. The standoff makes the gap a constant consequence of him having a
	# body instead of a hand-authored ramp.
	for d: float in [1.0, 1.5, 2.0]:
		var gap: float = d - _settled_radius(d)
		gut.p("threat %.1f m -> gap %.2f m" % [d, gap])
		assert_almost_eq(gap, _ctrl.challenge_standoff, 0.03,
				"in tight the gap is the standoff, not whatever the curve happened to give")
