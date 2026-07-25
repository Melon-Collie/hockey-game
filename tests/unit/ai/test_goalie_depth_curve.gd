extends GutTest

# CHARACTERISATION of the settled depth chart — what the live goalie actually does
# against a stationary threat at range, measured rather than read off the exports.
#
# The chart's own doc-block describes the BPS zones as:
#   A Aggressive   — ~2 ft outside the crease top; challenge a clean look.
#   B Base         — heels at the crease top; "where MOST shots are faced".
# This pins whether the CONFIGURATION matches that description. It does not, and
# the assertions below record the discrepancy rather than blessing it — see
# docs/goalie-grounding-refactor-plan.md §5.7.

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


func test_the_whole_slot_sits_at_maximum_challenge_depth() -> void:
	# THE FINDING. `zone_aggressive_z = 8.0` holds FULL aggressive depth flat from
	# 2 m to 8 m — which is the entire slot, i.e. where the dangerous shots come
	# from. B (crease top, "where MOST shots are faced" per the chart's own
	# doc-block) is not reached until `zone_base_z` = 12 m, out by the top of the
	# circles. So the goalie plays A for every slot shot and B only for
	# point-adjacent ones: the configuration inverts the description.
	for d: float in [2.0, 3.0, 5.0, 8.0]:
		assert_almost_eq(_settled_radius(d), _ctrl.depth_aggressive, 0.02,
				"threat at %.0f m settles at FULL aggressive depth" % d)
	assert_gt(_ctrl.depth_aggressive, CreaseRules.STRAIGHT_DEPTH,
			"and aggressive depth is outside the crease, so he is out of his paint for the whole slot")


func test_in_tight_he_is_almost_on_the_puck() -> void:
	# Inside `zone_post_z` (2 m) the chart ramps down to the goal line, so he is not
	# "far out" in absolute terms in tight — but the GAP to the threat collapses.
	var gap_2m: float = 2.0 - _settled_radius(2.0)
	var gap_1m: float = 1.0 - _settled_radius(1.0)
	gut.p("gap at 2 m = %.2f m, at 1 m = %.2f m" % [gap_2m, gap_1m])
	assert_lt(gap_2m, 0.35, "at the top of the ramp he is within ~a foot of the puck")
	assert_lt(gap_1m, gap_2m, "and closer still further in")
