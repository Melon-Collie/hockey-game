extends GutTest

# ── CHARACTERISATION: when does he drop, and why? ────────────────────────────
# Pinned the butterfly decision before it was replaced by a model, exactly as
# test_goalie_depth_curve pinned the Buckley chart before the depth solve.
# Nothing here asserts that the behaviour is right — it reports what it IS, so
# the model could be measured against it and the differences argued one at a
# time. Both surfaces are recorded below; the model has since landed.
#
# ── THE DECISION BEFORE ──────────────────────────────────────────────────────
# GoalieController._update_state's STANDING/READY arm was a hand-ordered elif
# chain, and three of its branches produced the SAME action:
#
#   if   _should_play_rim()           -> PLAYING_PUCK
#   elif _is_puck_in_defensive_zone() -> VH / RVH
#   elif _is_carrier_at_doorstep()    -> _enter_butterfly()
#   elif _should_seal_crease_jam()    -> _enter_butterfly()
#   elif _confirmed_beaten_wide()     -> _enter_butterfly()
#   else                              -> STANDING <-> READY
#
# Whichever fired FIRST won, and the order was never chosen deliberately — the
# same latent fragility the depth chart had before it became a solve. The three
# drop branches are now one `_should_block(delta)`, which asks
# GoalieSaveSelection whether an answer still fits in the time available.
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
# LIMITATION: the "+contested" column never fired because is_crease_jam required
# a DEFENDING teammate and this fixture leaves team_id at -1, where the carrier
# branch was unreachable by design. It still reads "up" under the model, for a
# different and now-correct reason: with no teams, the extra body is an OPPONENT,
# and an opposing carrier who has declared nothing is readable no matter how much
# company he has. The column is retained so the case stays visible.
#
# ── MEASURED SURFACE (2026-07, GoalieSaveSelection driving) ──────────────────
#  dist |  idle carry | slapper windup | +contested | loose+opp
#   1.0 |          up |           DOWN |         up |      DOWN
#   1.5 |          up |           DOWN |         up |      DOWN
#   2.0 |          up |           DOWN |         up |      DOWN
#   2.6 |          up |           DOWN |         up |      DOWN
#   3.0 |          up |           DOWN |         up |      DOWN
#   4.0 |          up |           DOWN |         up |      DOWN
#   6.0 |          up |             up |         up |        up
#
#  Lateral drive, carrier 2.0 m out:  0/2/4 m/s -> up,  6/8 m/s -> DOWN
#
# The two things worth keeping, kept:
#   * idle carry is up at EVERY range, unchanged — the patience half survives.
#   * the beaten-wide boundary is still between 4 and 6 m/s, unchanged, because
#     `_confirmed_beaten_wide` moved in as an INPUT rather than being re-derived.
#
# What moved, and why. Both drop columns now cut in the same place (between 4 and
# 6 m) instead of at 2.0 m and 3.0 m respectively — which is the whole point:
# they were one rule wearing two thresholds. The new boundary is where the puck's
# flight stops covering the read: 33 m/s against a 0.13 s low-band read is ~4.3 m
# of gap, and the goalie challenges ~1.5 m out, so a carrier past ~6 m is
# answerable and one inside ~5.5 m is not. Nothing hand-picked it.
#
# loose+opp also gains the 4.0 m cell. Reported from play: he stood up early into
# traffic and gave up rebounds through the five-hole. He now stays sealed while a
# stick that is not his can reach the puck first — and, unlike the threshold pair
# it replaced, it no longer needs a DEFENDING teammate to notice the traffic.
#
# UNCHANGED by the round-2 model work (closing-speed arrival + the commit
# deadline, plan doc §9 "Shipped, round 2"). Every cell held, which is the point
# of having pinned it: both fixes target situations this grid does not contain (a
# puck moving away or across, and a threat whose clock has not run out yet).
#
# The windup column is still SLAPPER only. A wrister wind-up pins the puck too,
# so it was briefly counted as a declaration; test_goalie_disguise_read measured
# the cost and vetoed it — blocking through the slot made deception worth nothing
# (4/14 on all three arms, vs 6/14 telegraphed and 11/14 wrong-height under the
# read). The declaration is the PLANT, not the pin. See _build_save_situation.

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
