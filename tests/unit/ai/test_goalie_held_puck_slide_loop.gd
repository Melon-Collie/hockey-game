extends GutTest

# ── A HELD PUCK PUTS HIM IN A PERMANENT SLIDE LOOP ──────────────────────────
# Reported from play: stand still with the puck near the goalie and he coils and
# slides forever. Reproduced: pull the puck across at a real pace, stop dead, and
# he never gets up again.
#
# Measured with the carrier stopped at x 2.0, 2.5 m out, over the 8 s AFTER the
# puck goes still: 31 entries into COILING, zero time on his feet, and a limit
# cycle of period 0.242 s repeating identical to three decimals. The boundary is
# around 2 m of lateral offset — at 1 m he settles — and outside
# `beaten_wide_max_threat_distance` he settles at any offset.
#
# ══ THE CYCLE ══════════════════════════════════════════════════════════════
#   BUTTERFLY at x +0.154, depth 0.100   (where the seal just put him)
#   idle butterfly pulls depth back out toward butterfly_radius 0.400
#   the seal re-commits: end_x +0.154 — the same x he is already standing on
#   COILING → SLIDING drags him back to post_seal_depth 0.100
#   repeat, forever
#
# The lateral leg is ZERO. Nothing about the slide is lateral: the only thing
# driving the re-commit is that idle BUTTERFLY and the post seal want different
# values of `_current_depth`, so with the verdict latched he oscillates between
# their two targets at 4 Hz.
#
# ══ WHY THE VERDICT NEVER CLEARS — the root cause is arithmetic ════════════
# `beaten_wide_holds` is deliberately clock-free: a puck that settles wide has
# not un-beaten him. But its arrival term, `tuck_point_travel > 0`, measures the
# distance from his live position to the post LESS `reach_half_width`, and
# `reach_half_width` is `pad_local_offset` (0.42) — his STANDING reach.
#
# The seal he is sent to is `_post_edge_seal_x`, which puts him at 0.154 because
# a BUTTERFLY pad reaches 0.84 m. So he seals with 0.84 of reach and is judged on
# 0.42 of it, and from the seal spot the arrival test still reads +0.34 m to go.
# He cannot satisfy it from the only place the seal ever sends him:
#
#   0.915 (post) − 0.154 (seal spot) − 0.42 (standing reach) = +0.341
#
# So "beaten" is permanent once it fires, by construction, for any wide carrier.
#
# ══ AGAINST THE COACHING ═══════════════════════════════════════════════════
# Three separate things are wrong, and each is wrong on its own terms:
#
#   A SEALED GOALIE IS NOT A BEATEN GOALIE. The verdict asks "can I cover the
#   tuck point from here". Having arrived at the seal is precisely the state in
#   which the answer is yes, so arrival has to be able to clear it.
#
#   YOU DO NOT MOVE FOR A PUCK THAT IS NOT MOVING. A carrier holding it wide is
#   the patient situation — square, set, wait. Repeated pushes off the post are
#   the textbook way to take yourself out of a position you were already in.
#
#   TWO STATES MUST NOT OWN ONE QUANTITY. Idle BUTTERFLY wants
#   `butterfly_radius` 0.40 and the seal wants `post_seal_depth` 0.10; whichever
#   ticks last wins. That is the contested-field failure the collaborator rules
#   in Scripts/controllers/CLAUDE.md describe, inside one class.
#
# Everything here is pinned as CHARACTERISATION of the defect. When it is fixed
# these assertions fail, and the correct response is to invert them — a settled
# goalie against a held puck enters COILING zero times.

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
# over a quarter of a second and stop dead. The lateral leg is not decoration:
# the beaten-wide ONSET needs a real lateral puck speed, so teleporting a carrier
# into place and holding it only fires the verdict when the jump happens to
# manufacture one — which made an earlier version of this file report the loop at
# lane 2.0 and miss it at lane 1.0, for reasons that were about the test.
#
# Counting starts once the puck is STILL. Everything after that instant is the
# goalie reacting to nothing.
func _hold(lane: float, dist: float, secs: float) -> Dictionary:
	_ctrl.reset_to_crease()
	_shooter.current_shot_state = SkaterStateMachine.State.SKATING_WITH_PUCK
	_shooter.predicted_shot_velocity = Vector3.ZERO
	_shooter.global_position = Vector3(0.0, 0.0, GOAL_Z + dist)
	_shooter.velocity = Vector3.ZERO
	_puck.set_carrier(_shooter)
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
	var first_s: float = INF
	var prev: int = -1
	for i: int in int(secs / DT):
		_puck.global_position = Vector3(lane, 0.0, GOAL_Z + dist)
		_puck.linear_velocity = Vector3.ZERO
		_ctrl._physics_process(DT)
		var s: int = _ctrl.stance()
		if s == GoalieStateMachine.State.COILING \
				and prev != GoalieStateMachine.State.COILING:
			coils += 1
			first_s = minf(first_s, float(i) * DT)
		if _ctrl._sm.is_upright():
			upright_s += DT
		prev = s
	return {"coils": coils, "upright_s": upright_s, "first_s": first_s,
			"final": _ctrl.stance()}


# ── THE ROOT CAUSE, as pure arithmetic ───────────────────────────────────────
# No scene, no ticking: the seal spot and the arrival test simply disagree about
# how far the goalie reaches, and the gap is what makes the verdict permanent.
func test_the_seal_spot_can_never_satisfy_the_arrival_test() -> void:
	var pad_edge: float = _ctrl.pad_local_offset + _ctrl.butterfly_pad_half_width
	var seal_x: float = _ctrl.net_half_width \
			- pad_edge * cos(deg_to_rad(_ctrl.slide_max_rotation_deg))
	var cfg := GoalieBehaviorRules.BeatenWideConfig.new()
	cfg.reach_half_width = _ctrl.pad_local_offset
	# Sitting exactly in the seal, right on the goal line — the most-arrived he
	# can possibly be.
	var travel: float = GoalieBehaviorRules.tuck_point_travel(
			Vector3(seal_x, 0.0, GOAL_Z), _ctrl.net_half_width, GOAL_Z, cfg)
	gut.p("seal spot x %.3f (butterfly pad reach %.2f) | arrival test uses standing reach %.2f | travel still %+.3f m"
			% [seal_x, pad_edge, cfg.reach_half_width, travel])
	assert_gt(travel, 0.0,
			"he is judged 'still beaten' while sitting in the seal — the two use different reach numbers")


# ── THE BUG ITSELF ───────────────────────────────────────────────────────────
func test_a_held_puck_leaves_him_coiling_forever() -> void:
	var r: Dictionary = _hold(2.0, 2.5, 8.0)
	gut.p("carrier held at x 2.0, 2.5 m out for 8 s -> %d coil entries, %.2f s on his feet"
			% [r["coils"], r["upright_s"]])
	assert_gt(r["coils"] as int, 20,
			"CHARACTERISATION OF A DEFECT: a held puck re-commits the seal at ~4 Hz forever")
	assert_lt(r["upright_s"] as float, 1.0,
			"and he never gets back up")


# WHERE THE BOUNDARY IS. Not every wide carrier — he settles at 1 m of offset and
# loops from about 2 m out. Worth pinning as a number rather than a direction,
# because the onset needs the puck genuinely past his standing sealing reach and
# the arrival test then needs real travel left to the post; a fix that moves
# either one moves this boundary, and that is the thing to look at.
func test_the_loop_starts_around_two_metres_of_offset() -> void:
	var loops: Dictionary = {}
	for lane: float in [1.0, 2.0, 3.0]:
		var r: Dictionary = _hold(lane, 2.5, 8.0)
		loops[lane] = r["coils"]
		gut.p("lane %.1f -> first coil at %.2f s, %d entries"
				% [lane, r["first_s"], r["coils"]])
	assert_eq(loops[1.0], 0, "a metre of offset still settles")
	assert_gt(loops[2.0] as int, 20, "two metres does not")
	assert_gt(loops[3.0] as int, 20, "nor does three")


# ── THE CONTROL ──────────────────────────────────────────────────────────────
# Dead centre he is completely stable, and so is a carrier outside the verdict's
# threat range. So this is the beaten-wide path specifically, not "he cannot
# stand still".
func test_he_is_stable_centred_and_stable_far_away() -> void:
	var centred: Dictionary = _hold(0.0, 2.5, 8.0)
	gut.p("centred at 2.5 m -> %d coil entries, %.2f s on his feet"
			% [centred["coils"], centred["upright_s"]])
	assert_eq(centred["coils"], 0, "a carrier straight in front of him is stable")
	var far: Dictionary = _hold(2.0, 6.0, 8.0)
	gut.p("wide at 6.0 m -> %d coil entries, %.2f s on his feet"
			% [far["coils"], far["upright_s"]])
	assert_eq(far["coils"], 0, "and so is one outside the verdict's threat range")
