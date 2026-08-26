extends GutTest

# ── HE SEALS ONCE, THEN GETS UP ──────────────────────────────────────────────
# The beaten-wide seal is a commitment with an end. A carrier walks the puck
# across, the seal fires, he arrives at the post — and arriving is what makes him
# not-beaten any more, so the verdict clears and he recovers to his feet.
#
# Three invariants hold that, and each one was a defect that produced a permanent
# 4 Hz coil/slide loop against a carrier who had simply stopped moving:
#
#   ARRIVAL MUST BE REACHABLE. The verdict clears on `tuck_point_travel <= 0`,
#   measured from his live position with his own reach subtracted. That reach has
#   to be the one the SEAL uses, or he arrives somewhere his own arrival test
#   still calls short and no amount of sealing can ever clear it.
#
#   THE REACH FOLLOWS THE STANCE. On his feet it is `pad_local_offset`; behind a
#   butterfly pad laid along the ice it is `_seal_cover_radius()`. One number for
#   both postures is what left a sealed goalie judged 0.34 m short.
#
#   NOTHING MAY FIGHT THE SEAL'S DEPTH. `min_challenge_depth` keeps an idle
#   butterfly from straddling the line, and already exempts COILING and SLIDING —
#   but those are the states that get him TO the seal, and BUTTERFLY is the one he
#   sits in once there. Flooring him there lifts him off a `post_seal_depth` the
#   slide spent half a second reaching, which re-opens the beat and re-commits the
#   same slide forever.
#
# The shape of the failure is worth recognising rather than the history of it: a
# stance loop at a fixed period, whose slide has NO lateral leg because the seal
# target is the x he is already standing on, means two owners are fighting over
# `_current_depth`.

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


# Set him against a carrier straight in front, then WALK the puck out to `lane`
# over a quarter of a second and stop dead.
#
# Two things about the setup matter. The lateral leg is not decoration — the
# beaten-wide ONSET needs a real lateral puck speed, so a carrier teleported into
# place arms the verdict only when the jump happens to manufacture one. And the
# puck is placed BEFORE `reset_to_crease`, which seeds `_prev_puck_position` from
# wherever the puck is at that instant; moving it afterwards hands him one tick of
# enormous phantom velocity. (The live faceoff gets this right —
# `PhaseCoordinator._enter_faceoff_prep` calls `puck.reset(dot)` first.)
#
# Counting starts once the puck is STILL. Everything after that instant is the
# goalie responding to nothing.
func _hold(lane: float, dist: float, secs: float) -> Dictionary:
	_shooter.current_shot_state = SkaterStateMachine.State.SKATING_WITH_PUCK
	_shooter.predicted_shot_velocity = Vector3.ZERO
	_shooter.global_position = Vector3(0.0, 0.0, GOAL_Z + dist)
	_shooter.velocity = Vector3.ZERO
	_puck.set_carrier(_shooter)
	_puck.global_position = _shooter.global_position
	_ctrl.reset_to_crease()
	for _i: int in 240:                       # 2 s — settled, square, on his feet
		_puck.global_position = Vector3(0.0, 0.0, GOAL_Z + dist)
		_puck.linear_velocity = Vector3.ZERO
		_ctrl._physics_process(DT)
	var pull_ticks: int = int(0.25 / DT)
	for i: int in pull_ticks:                 # the pull across, at a real pace
		var t: float = float(i + 1) / float(pull_ticks)
		_shooter.global_position = Vector3(lane * t, 0.0, GOAL_Z + dist)
		_shooter.velocity = Vector3(lane / 0.25, 0.0, 0.0)
		_puck.global_position = Vector3(lane * t, 0.0, GOAL_Z + dist)
		_puck.linear_velocity = Vector3.ZERO
		_ctrl._physics_process(DT)
	_shooter.global_position = Vector3(lane, 0.0, GOAL_Z + dist)
	_shooter.velocity = Vector3.ZERO
	var coils: int = 0
	var upright_s: float = 0.0
	var up_at: float = INF
	var prev: int = -1
	for i: int in int(secs / DT):
		_puck.global_position = Vector3(lane, 0.0, GOAL_Z + dist)
		_puck.linear_velocity = Vector3.ZERO
		_ctrl._physics_process(DT)
		var s: int = _ctrl.stance()
		if s == GoalieStateMachine.State.COILING \
				and prev != GoalieStateMachine.State.COILING:
			coils += 1
		if _ctrl._sm.is_upright():
			upright_s += DT
			up_at = minf(up_at, float(i) * DT)
		prev = s
	return {"coils": coils, "upright_s": upright_s, "up_at": up_at,
			"committed": _ctrl._beaten_wide_committed, "final": _ctrl.stance()}


# ── THE PAIR THAT MUST AGREE, as pure arithmetic ─────────────────────────────
# No scene, no ticking. Sitting exactly where the seal sends him, the travel he
# still owes is zero — so arriving clears the verdict, exactly, by construction.
func test_arriving_at_the_seal_clears_the_arrival_test() -> void:
	var pad_edge: float = _ctrl.pad_local_offset + _ctrl.butterfly_pad_half_width
	var rot: float = deg_to_rad(_ctrl.slide_max_rotation_deg)
	var seal_x: float = _ctrl.net_half_width - pad_edge * cos(rot)
	var seal_depth: float = _ctrl._slide.post_seal_depth
	var cfg := GoalieBehaviorRules.BeatenWideConfig.new()
	cfg.reach_half_width = _ctrl._seal_cover_radius()
	var travel: float = GoalieBehaviorRules.tuck_point_travel(
			Vector3(seal_x, 0.0, GOAL_Z + seal_depth), _ctrl.net_half_width,
			GOAL_Z, cfg)
	gut.p("seal spot (%.3f, %.2f) | sealed cover radius %.4f | travel owed %+.5f m"
			% [seal_x, seal_depth, cfg.reach_half_width, travel])
	assert_almost_eq(travel, 0.0, 0.001,
			"the seal spot IS the arrival point — anything else is a verdict that cannot clear")
	assert_gt(cfg.reach_half_width, _ctrl.pad_local_offset,
			"and a sealed goalie covers more than a standing one, which is why the reach follows the stance")


# ── THE BEHAVIOUR ────────────────────────────────────────────────────────────
func test_a_held_puck_gets_one_seal_and_then_he_stands_up() -> void:
	var r: Dictionary = _hold(2.0, 2.5, 8.0)
	gut.p("carrier held at x 2.0, 2.5 m out | %d seal(s), on his feet from %.2f s (%.2f s of 8)"
			% [r["coils"], r["up_at"], r["upright_s"]])
	assert_lte(r["coils"] as int, 2,
			"the seal is a commitment with an end, not a stance he re-enters at 4 Hz")
	assert_false(r["committed"] as bool, "and the verdict clears once he has arrived")
	assert_gt(r["upright_s"] as float, 5.0,
			"a puck that is not moving is played from his feet")


func test_no_lateral_offset_leaves_him_stuck_on_the_ice() -> void:
	for lane: float in [1.0, 2.0, 3.0]:
		var r: Dictionary = _hold(lane, 2.5, 8.0)
		gut.p("lane %.1f -> %d seal(s), up from %.2f s, %.2f s on his feet"
				% [lane, r["coils"], r["up_at"], r["upright_s"]])
		assert_gt(r["upright_s"] as float, 5.0,
				"lane %.1f must end on his feet" % lane)
		assert_lte(r["coils"] as int, 2, "lane %.1f must not loop" % lane)


func test_he_is_stable_centred_and_stable_far_away() -> void:
	var centred: Dictionary = _hold(0.0, 2.5, 8.0)
	gut.p("centred at 2.5 m -> %d seal(s), %.2f s on his feet"
			% [centred["coils"], centred["upright_s"]])
	assert_eq(centred["coils"], 0, "a carrier straight in front of him never seals")
	var far: Dictionary = _hold(2.0, 6.0, 8.0)
	gut.p("wide at 6.0 m -> %d seal(s), %.2f s on his feet"
			% [far["coils"], far["upright_s"]])
	assert_eq(far["coils"], 0, "nor does one outside the verdict's threat range")


# ── WHY HE GETS UP — it is the race, not a timer ─────────────────────────────
# `should_hold_seal` is a model: can he complete an answer before the puck can
# hurt him? Against a held puck 3.2 m out it says yes with room to spare
# (`answer_fraction` 1.00), which is the same thing a coach says — you play a
# puck under control from your feet, because down you cannot cut the angle, move
# laterally except by committing, or answer a deke.
#
# `lateral_race_lost` is the one input that outranks the whole race, so it has to
# be true only while he is ACTUALLY beaten. This asserts it is not, once he has
# sealed and arrived.
func test_the_race_model_is_what_puts_him_back_on_his_feet() -> void:
	_hold(2.0, 2.5, 2.0)
	var s: GoalieSaveSelection.Situation = _ctrl._build_save_situation()
	var fraction: float = GoalieSaveSelection.answer_fraction(s)
	gut.p("answer_fraction %.2f | lateral_race_lost %s | hold_seal %s | upright %s"
			% [fraction, s.lateral_race_lost,
			GoalieSaveSelection.should_hold_seal(s, _ctrl.recovery_duration),
			_ctrl._sm.is_upright()])
	assert_almost_eq(fraction, 1.0, 0.001, "a complete reaction fits")
	assert_false(s.lateral_race_lost, "he is not beaten any more — he sealed and arrived")
	assert_false(GoalieSaveSelection.should_hold_seal(s, _ctrl.recovery_duration),
			"so the race says get up")


# ── ONE BAD TICK IS NOT PERMANENT ────────────────────────────────────────────
# `_puck_velocity_est` is a raw one-tick finite difference clamped only at
# `puck.max_speed` (38 m/s), and the onset gate is 2.5 m/s — 2.1 cm of travel in a
# tick at 120 Hz. The clamp sits fifteen times above the gate, so any real
# discontinuity (a reception, a deflection, a reconcile correction) can arm the
# verdict off one frame.
#
# That is survivable ONLY because arriving clears it. A 3 cm jump — smaller than
# the puck — from a settled goalie against a parked carrier arms him, and he then
# seals, arrives, and is back on his feet.
func test_a_spurious_arm_self_corrects() -> void:
	var lane: float = 2.0
	var dist: float = 2.5
	_shooter.current_shot_state = SkaterStateMachine.State.SKATING_WITH_PUCK
	_shooter.predicted_shot_velocity = Vector3.ZERO
	_shooter.global_position = Vector3(lane, 0.0, GOAL_Z + dist)
	_shooter.velocity = Vector3.ZERO
	_puck.set_carrier(_shooter)
	_puck.global_position = _shooter.global_position
	_ctrl.reset_to_crease()
	for _i: int in 360:
		_puck.global_position = _shooter.global_position
		_puck.linear_velocity = Vector3.ZERO
		_ctrl._physics_process(DT)
	assert_false(_ctrl._beaten_wide_committed, "precondition: settled and not armed")
	assert_true(_ctrl._sm.is_upright(), "precondition: on his feet")
	_puck.global_position = _shooter.global_position + Vector3(0.03, 0.0, 0.0)
	_ctrl._physics_process(DT)
	var spike: float = absf(_ctrl._puck_velocity_est.x)
	for _i: int in 960:
		_puck.global_position = _shooter.global_position
		_puck.linear_velocity = Vector3.ZERO
		_ctrl._physics_process(DT)
	gut.p("one 3 cm jump read as %.2f m/s (gate %.2f) | 8 s later: committed %s, upright %s"
			% [spike, _ctrl.beaten_wide_min_lateral_speed,
			_ctrl._beaten_wide_committed, _ctrl._sm.is_upright()])
	assert_gt(spike, _ctrl.beaten_wide_min_lateral_speed,
			"3 cm in one tick clears the onset gate with room to spare")
	assert_false(_ctrl._beaten_wide_committed, "and it does not stick")
	assert_true(_ctrl._sm.is_upright(), "he is back on his feet")
