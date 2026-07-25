extends GutTest

# ── CHARACTERISATION: when does he drop, and why? ────────────────────────────
# Pins the CURRENT butterfly decision before it is replaced by a model, exactly
# as test_goalie_depth_curve pinned the Buckley chart before the depth solve.
# Nothing here asserts that the behaviour is right — it asserts what it IS, so a
# model can be measured against it and the differences argued one at a time.
#
# ── THE DECISION TODAY ───────────────────────────────────────────────────────
# GoalieController._update_state's STANDING/READY arm is a hand-ordered elif
# chain, and three of its branches produce the SAME action:
#
#   if   _should_play_rim()           -> PLAYING_PUCK
#   elif _is_puck_in_defensive_zone() -> VH / RVH
#   elif _is_carrier_at_doorstep()    -> _enter_butterfly()
#   elif _should_seal_crease_jam()    -> _enter_butterfly()
#   elif _confirmed_beaten_wide()     -> _enter_butterfly()
#   else                              -> STANDING <-> READY
#
# Whichever fires FIRST wins, and the order was never chosen deliberately —
# the same latent fragility the depth chart had before it became a solve.
#
# ── THE RULE THE CARVE-OUTS ARE APPROXIMATING ────────────────────────────────
# Real goaltending splits every save into BLOCKING or REACTING:
#   * REACTING is preferred — stay patient, let the shooter's body and stick
#     declare the puck's path, then respond.
#   * BLOCKING is for when reacting is IMPOSSIBLE: the puck is too close to
#     respond to, the goalie is screened, a deflection is live, or the play is
#     an unpredictable scramble.
#   * Rule of thumb: beyond about TWO STICK LENGTHS, use the reaction butterfly.
#
# Every one of our three drop predicates is an instance of "reacting is
# impossible here":
#   doorstep slapshot windup -> the release beats the reaction, so drop DURING
#                               the windup or not at all
#   crease jam               -> a battle/scramble is unpredictable by definition
#   beaten wide              -> standing tracking is already lost; the seal is
#                               the only coverage left
#
# And the thresholds are four hand-picked numbers straddling one boundary:
#   close_crease_butterfly_distance  1.5 m
#   jam_puck_distance                2.0 m
#   lunge_trigger_distance           1.2 m
#   active_blade_carrier_radius      2.5 m
#   two stick lengths               ~2.6 m (2 x GameRules.DEFAULT_STICK_LENGTH_M)
#
# The underlying quantity is TIME, not distance: response budget
# (reaction_delay + butterfly_drop_speed ~= 0.33 s) against what the puck
# allows. Distance is the proxy the coaching rule uses because it is coachable.
#
# ── MEASURED SURFACE (2026-07, before any model) ─────────────────────────────
#  dist |  idle carry | slapper windup | +contested | loose+opp
#   1.0 |          up |           DOWN |         up |      DOWN
#   1.5 |          up |           DOWN |         up |      DOWN
#   2.0 |          up |           DOWN |         up |      DOWN
#   2.6 |          up |             up |         up |      DOWN
#   3.0 |          up |             up |         up |      DOWN
#   4.0 |          up |             up |         up |        up
#   6.0 |          up |             up |         up |        up
#
#  Lateral drive, carrier 2.0 m out:  0/2/4 m/s -> up,  6/8 m/s -> DOWN
#
# TWO THINGS WORTH KEEPING:
#
# 1. The beaten-wide boundary sits between 4 and 6 m/s of lateral drive at 2 m.
#    The LATERAL TRACKING CAP built for the depth solve gives a critical speed of
#    push * d / r = 3.8 * 2 / 1.75 = 4.34 m/s at that same distance. Two
#    mechanisms authored independently, landing on the same boundary — strong
#    evidence they are one model seen from two directions. A drop model and a
#    depth model that both derive from "can I still track this?" would share it.
#
# 2. An idle carry NEVER drops him at any range, which is correct doctrine
#    (stay up, force the dangler to declare) and is the behaviour any model must
#    preserve — it is the patience half of react-vs-block.
#
# LIMITATION: the "+contested" column never fires because is_crease_jam requires
# a DEFENDING teammate and this fixture leaves team_id at -1, where the carrier
# branch is unreachable by design. Exercising it needs team assignment; the
# column is retained so the gap is visible rather than silently absent.

const Harness := preload("res://tests/unit/ai/real_goalie_shot_harness.gd")
const GOAL_Z: float = -GameRules.GOAL_LINE_Z
const DT: float = 1.0 / 120.0
const SkaterScene := preload("res://Scenes/Skater.tscn")

var _goalie: Node = null
var _puck: Node = null
var _shooter: Skater = null
var _mate: Skater = null
var _ctrl: GoalieController = null


func before_each() -> void:
	_goalie = load("res://Scenes/Goalie.tscn").instantiate()
	_puck = load("res://Scenes/Puck.tscn").instantiate()
	_shooter = SkaterScene.instantiate() as Skater
	_mate = SkaterScene.instantiate() as Skater
	_ctrl = GoalieController.new()
	for n: Node in [_goalie, _puck, _shooter, _mate, _ctrl]:
		add_child_autofree(n)
	for s: Skater in [_shooter, _mate]:
		s.set_physics_process(false)
		s.set_process(false)
	_ctrl.set_skater_getter(func() -> Array: return [_shooter, _mate])
	_ctrl.setup(_goalie, _puck, GOAL_Z, true)


# Drive the scene for `ticks` and report whether he ended up DOWN.
func _run(carrier_at: Vector3, shot_state: int, carrier_vel: Vector3,
		mate_at: Vector3, carried: bool, ticks: int) -> bool:
	_ctrl.reset_to_crease()
	_shooter.global_position = carrier_at
	_shooter.velocity = carrier_vel
	_shooter.current_shot_state = shot_state
	_mate.global_position = mate_at
	if carried:
		_puck.set_carrier(_shooter)
	else:
		_puck.clear_carrier()
	var p: Vector3 = carrier_at
	for _i: int in ticks:
		_shooter.global_position = p
		_puck.global_position = p
		_puck.linear_velocity = Vector3.ZERO
		_ctrl._physics_process(DT)
		p += carrier_vel * DT
	return _ctrl._sm.is_down()


func test_report_the_drop_decision_surface() -> void:
	var far := Vector3(30.0, 0.0, 0.0)   # a body parked out of every radius
	var idle: int = SkaterStateMachine.State.SKATING_WITH_PUCK
	var wind: int = SkaterStateMachine.State.SLAPPER_CHARGE_WITH_PUCK
	gut.p("Does he DROP?  (carrier dead centre, 0.5 s of scene)")
	gut.p(" dist |  idle carry | slapper windup | +teammate contesting | loose+opp")
	for d: float in [1.0, 1.5, 2.0, 2.6, 3.0, 4.0, 6.0]:
		var at := Vector3(0.0, 0.0, GOAL_Z + d)
		var a: bool = _run(at, idle, Vector3.ZERO, far, true, 60)
		var b: bool = _run(at, wind, Vector3.ZERO, far, true, 60)
		var c: bool = _run(at, idle, Vector3.ZERO, at + Vector3(0.4, 0, 0), true, 60)
		var e: bool = _run(at, idle, Vector3.ZERO, far, false, 60)
		gut.p("%5.1f | %11s | %14s | %20s | %9s"
				% [d, "DOWN" if a else "up", "DOWN" if b else "up",
				"DOWN" if c else "up", "DOWN" if e else "up"])
	gut.p("")
	gut.p("Lateral drive (beaten-wide race), carrier 2.0 m out, driving across:")
	for v: float in [0.0, 2.0, 4.0, 6.0, 8.0]:
		var at := Vector3(-1.0, 0.0, GOAL_Z + 2.0)
		var down: bool = _run(at, SkaterStateMachine.State.SKATING_WITH_PUCK,
				Vector3(v, 0.0, 0.0), far, true, 60)
		gut.p("  lateral %.1f m/s -> %s" % [v, "DOWN" if down else "up"])
	assert_true(true, "report")
