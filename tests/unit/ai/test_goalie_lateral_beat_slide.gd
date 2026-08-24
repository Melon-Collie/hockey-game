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
	# THE SEAL'S SIDE, read off where the slide ENDS. Not `_slide.dir`, which is
	# only the residual TRAVEL — `commit_slide` takes it as
	# `sign(target_x - current_x)`, so it agrees with the seal's side only while
	# he commits from inside the seal spot. Standing wider than the seal (which a
	# shallower retreat does: measured, he sits at -0.183 rather than -0.117 and
	# reaches the SAME -0.154 seal) makes the last few centimetres travel back the
	# other way, and reading that as "sealed the wrong post" is a proxy failing,
	# not a behaviour change.
	assert_lt(_ctrl._slide.end_x, 0.0,
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


# THE SHOT DOES NOT UN-BEAT HIM. The beat is a coverage fact, and the moment the
# beaten player releases is the moment the goalie has least time to lose — yet the
# seal used to be unreachable exactly there, twice over: `_seal_beaten_wide_post`
# rode the block's `not _reaction.reacting` gate, and the verdict itself required
# a hostile CARRIER, so releasing the puck erased it outright. Measured before:
# beaten wide and then a release sealed NEVER, against 0.33 s with no shot.
#
# The release is timed into the confirmation window — after the beat arms, before
# it confirms — because that is the gap. Release later and he has already sealed;
# release earlier and he was not beaten yet.
func test_a_release_inside_the_confirmation_window_still_seals() -> void:
	_settle(GOAL_Z + 8.0, GOAL_Z + 3.2, 180)
	var from_x: float = _puck.global_position.x
	var ticks: int = int(0.30 / DT)
	var released: bool = false
	var committed: bool = false
	for i: int in ticks + 60:
		_shooter.global_position.z -= 3.0 * DT
		_shooter.velocity = Vector3(0.0, 0.0, -3.0)
		if released:
			_puck.global_position += _puck.linear_velocity * DT
		else:
			var t: float = clampf(float(i + 1) / float(ticks), 0.0, 1.0)
			_puck.global_position = Vector3(
					lerpf(from_x, -1.15, t), 0.0, _shooter.global_position.z + 0.4)
		_ctrl._physics_process(DT)
		# Fire as soon as the beat has ARMED but not yet confirmed.
		if not released and _ctrl._beaten_wide_armed and not _ctrl._beaten_wide_committed:
			released = true
			_shooter.current_shot_state = SkaterStateMachine.State.FOLLOW_THROUGH
			_puck.clear_carrier()
			# Deliberately unhurried, so the puck is still in front of him while
			# the window runs out — the seal has to be able to fire mid-read.
			var v := Vector3(-1.0, 0.0, -7.0)
			_puck.apply_release_velocity(v)
			_puck.puck_released.emit()
			_puck.linear_velocity = v
			assert_true(_ctrl._reaction.reacting, "precondition: he is reading the shot")
		var st: int = _ctrl._sm.current
		if st == GoalieStateMachine.State.COILING \
				or st == GoalieStateMachine.State.SLIDING:
			committed = true
			break
	assert_true(released, "precondition: the beat armed and a shot was taken inside the window")
	assert_true(committed,
			"a shot in flight does not give him back the lateral race — seal anyway")
	# Read the seal's side off where the slide ENDS, for the reason spelled out
	# on the sibling assertion above: `_slide.dir` is residual TRAVEL, not a post
	# identity, and it disagrees with the seal's side whenever he commits from
	# WIDER than the seal spot. Measured here, he stands at -0.163 and seals the
	# same -0.154 post, so the last 9 mm travel back toward centre and `dir`
	# reads +1 against a puck that went the other way.
	assert_lt(_ctrl._slide.end_x, 0.0, "the seal goes the way the PUCK went")
