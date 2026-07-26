extends GutTest

# ── The aim shade must know the net exists (#552) ────────────────────────────
# Repro from a friends game, confirmed on the replay: skate at the net with
# momentum, charge a slapshot aimed OUTSIDE the post, and the goalie leaves to
# cover it — then coast in on the empty cage.
#
# `slapper_aim_shade` (0.7) is a positional commit: while reading a planted
# slapshot wind-up the goalie physically travels toward where the declared shot
# will cross his depth plane. It is deliberately strong because it powers a real
# read, and it is directional off the LOCKED aim so a fake shades him wrong —
# that part is intended. The bug was that nothing checked the declared shot was
# going in, and nothing bounded the target to the mouth.
#
# Both are geometry off numbers already in scope, so this pins them directly
# against the real read pipeline (`hold_windup` publishes the same
# `predicted_shot_velocity` field the shade consumes).

const Harness := preload("res://tests/unit/ai/real_goalie_shot_harness.gd")
const GOAL_Z: float = -GameRules.GOAL_LINE_Z
const SLAP: int = SkaterStateMachine.State.SLAPPER_CHARGE_WITH_PUCK
const WINDUP_TICKS: int = 60
const POWER_T: float = 0.9

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


# Goalie's settled lateral position after holding a slapper wind-up declared at
# `aim_x` (world x at the goal line), from dead centre in the slot.
func _shaded_x(aim_x: float) -> float:
	var shooter := Vector3(0.0, 0.0, GOAL_Z + 6.0)
	_h.hold_windup(shooter, Vector3(aim_x, 0.0, GOAL_Z), ShotMechanics.ELEVATION_FLAT,
			POWER_T, WINDUP_TICKS, SLAP)
	return _goalie.global_position.x


func test_an_off_net_windup_earns_no_shade() -> void:
	# THE BUG. Declared well outside the post — a shot that was never going in.
	# He must not travel for it; the empty net behind him is the whole cost.
	var post: float = GameRules.NET_HALF_WIDTH
	var centred: float = _shaded_x(0.0)
	var wide: float = _shaded_x(post + 1.5)
	gut.p("centred aim -> x=%+.3f, wide aim (%.2f m outside the post) -> x=%+.3f"
			% [centred, 1.5, wide])
	assert_almost_eq(wide, centred, 0.05,
			"a declared shot heading wide leaves him where he was")


func test_a_corner_windup_still_shades() -> void:
	# The guard: the read this lever exists for must survive. A genuine top-corner
	# aim still moves him, or the fix has simply deleted the mechanic.
	var post: float = GameRules.NET_HALF_WIDTH
	var centred: float = _shaded_x(0.0)
	var corner: float = _shaded_x(post - 0.15)
	gut.p("centred -> x=%+.3f, corner aim -> x=%+.3f  (shade %.3f m)"
			% [centred, corner, absf(corner - centred)])
	assert_gt(absf(corner - centred), 0.10,
			"an on-net corner declaration still shades him toward it")


func test_the_shade_never_travels_past_the_post() -> void:
	# Even on a legitimate aim just inside the post, the projection is taken at
	# the goalie's DEPTH plane and can solve wider than the mouth. He covers to
	# the post and no further.
	var post: float = GameRules.NET_HALF_WIDTH
	for aim_x: float in [post - 0.02, post - 0.10, -(post - 0.02)]:
		var x: float = _shaded_x(aim_x)
		assert_lte(absf(x), post + 0.01,
				"aim %+.2f left him at %+.3f, outside the mouth" % [aim_x, x])


func test_on_net_test_is_solved_at_the_goal_line() -> void:
	# A shot can cross the goalie's plane inside the posts and still be drifting
	# wide by the time it reaches the line — which is the crossing that decides
	# whether it is a goal. Pure-geometry check on the predicate itself.
	# The harness already ran setup(); calling it again reconnects signals.
	_puck.global_position = Vector3(0.0, 0.0, GOAL_Z + 6.0)
	var post: float = GameRules.NET_HALF_WIDTH
	# Aim at the post: on net.
	var to_post: Vector3 = Vector3(post - 0.05, 0.0, GOAL_Z) - _puck.global_position
	assert_true(_ctrl._declared_shot_is_on_net(to_post.normalized() * 30.0),
			"a shot at the post is on net")
	# Same origin, aimed a metre outside it: not.
	var to_wide: Vector3 = Vector3(post + 1.0, 0.0, GOAL_Z) - _puck.global_position
	assert_false(_ctrl._declared_shot_is_on_net(to_wide.normalized() * 30.0),
			"a shot a metre outside the post is not")
	# Pointed away from this net entirely.
	assert_false(_ctrl._declared_shot_is_on_net(Vector3(0.0, 0.0, 30.0)),
			"a shot heading up-ice is not on this net")
