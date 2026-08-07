extends GutTest

# ── Beaten laterally → drop INTO the seal ────────────────────────────────────
# The move: a shooter drives straight at the net and pulls the puck
# forehand→backhand across the goalie. His body barely moves laterally — the
# PUCK is what goes around the goalie — and once it is past his standing sealing
# reach the tuck is live and standing tracking cannot cover it.
#
# What this pins is that the answer is ONE motion. A goalie who drops square and
# then re-earns the push through the idle-butterfly slide trigger (drop animation
# plus a fresh confirmation window) arrives most of half a second after the beat,
# which is not an answer. He has to push off the far leg on the way down.
#
# The counter is pinned alongside it, because it is the reason the commit is
# allowed to be irreversible: a pull that does not SUSTAIN never sells him out.

const GOAL_Z: float = -GameRules.GOAL_LINE_Z   # goalie defends the -Z net
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


# Settle the goalie against a carrier walking in dead centre, puck on the
# forehand. Leaves him squared at challenge depth with the rush live.
func _settle(from_z: float, to_z: float, ticks: int) -> void:
	_ctrl.reset_to_crease()
	_puck.set_carrier(_shooter)
	_shooter.current_shot_state = SkaterStateMachine.State.SKATING_WITH_PUCK
	for i: int in ticks:
		var t: float = float(i) / float(maxi(ticks - 1, 1))
		var z: float = lerpf(from_z, to_z, t)
		_shooter.global_position = Vector3(0.0, 0.0, z)
		_shooter.velocity = Vector3(0.0, 0.0, (to_z - from_z) / (float(ticks) * DT))
		_puck.global_position = Vector3(0.5, 0.0, z + 0.4)
		_puck.linear_velocity = Vector3.ZERO
		_ctrl._physics_process(DT)


# March the puck laterally across the goalie while the shooter keeps driving
# straight in. Returns the seconds elapsed before the goalie committed a slide,
# or INF if he never did.
func _pull_across(to_x: float, seconds: float) -> float:
	var ticks: int = int(seconds / DT)
	var from_x: float = _puck.global_position.x
	var committed_at: float = INF
	for i: int in ticks:
		var t: float = float(i + 1) / float(ticks)
		_shooter.global_position.z -= 3.0 * DT
		_shooter.velocity = Vector3(0.0, 0.0, -3.0)
		_puck.global_position = Vector3(
				lerpf(from_x, to_x, t), 0.0, _shooter.global_position.z + 0.4)
		_ctrl._physics_process(DT)
		var down: bool = _ctrl._sm.current == GoalieStateMachine.State.COILING \
				or _ctrl._sm.current == GoalieStateMachine.State.SLIDING
		if down and is_inf(committed_at):
			committed_at = float(i + 1) * DT
	return committed_at


func test_forehand_backhand_on_a_rush_pushes_into_the_seal() -> void:
	_settle(GOAL_Z + 8.0, GOAL_Z + 3.2, 180)
	# The whole move, at the pace a human plays it: the puck sweeps from the
	# forehand (+0.5) across to the backhand side (−0.9) in 0.25 s — ~5.6 m/s of
	# real lateral travel — and then keeps going to the tuck rather than coming
	# back. The shooter's body drives straight in the whole time and never
	# supplies a lateral velocity of its own, which is exactly what the old
	# body-velocity read scored as "not a drive".
	var sweep: float = _pull_across(-0.9, 0.25)
	var tuck: float = _pull_across(-1.15, 0.25)
	var committed: bool = not is_inf(sweep) or not is_inf(tuck)
	gut.p("committed %s into the move" % [
			"%.2f s" % (sweep if not is_inf(sweep) else 0.25 + tuck) if committed else "never"])
	assert_true(committed,
			"beaten to the backhand side → push off into the post seal, not a square drop")
	assert_lt(_ctrl._slide.dir, 0.0,
			"the seal goes the way the PUCK went")


func test_a_pull_that_comes_back_does_not_sell_him_out() -> void:
	_settle(GOAL_Z + 8.0, GOAL_Z + 3.2, 180)
	# Same opening move, cut short: the puck reaches the backhand side and is
	# pulled straight back inside the sealing reach before the confirmation
	# window elapses. Baiting the commit is the counter to it being irreversible.
	var out: float = _pull_across(-0.7, 0.08)
	var back: float = _pull_across(0.3, 0.08)
	assert_true(is_inf(out) and is_inf(back),
			"a transient pull is a stickhandle, not a beat — stay up and track it")
