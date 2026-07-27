extends GutTest

# Reproduction probe for the "Colin cheese" slot slapshot: skate into the slot,
# wind up a slapper, and it goes past the side of a frozen goalie that never
# reads the windup. Squaring, the pre-arm timing prime, and the directional
# pre-lean ALL gate on the goalie reading the wind-up
# (_is_reading_shot_threat / _reading_pinned_windup), so if that read never fires
# none of the three engage — which matches the report (no pre-lean, barely
# reacts). This drives the REAL GoalieController against a real Skater carrier
# holding the wind-up and asserts each read actually turns on.
#
# Also covers the WRISTER wind-up, which under the coil-and-release model pins the
# puck body-local exactly as the slapper does — so it must earn the same PINNED
# reads (squaring to the pinned puck, no double-counted lead) while NOT earning the
# PLANTED-only positional aim shade, since a wrister shooter keeps full locomotion
# and can skate the shot origin out from under a shade.

const State = SkaterStateMachine.State
const GOAL_Z: float = -GameRules.GOAL_LINE_Z   # goalie defends the -Z net
const DT: float = 1.0 / 120.0

var _goalie: Goalie = null
var _puck: Puck = null
var _carrier: Skater = null
var _ctrl: GoalieController = null


func before_each() -> void:
	_goalie = load("res://Scenes/Goalie.tscn").instantiate() as Goalie
	_puck = load("res://Scenes/Puck.tscn").instantiate() as Puck
	_carrier = load("res://Scenes/Skater.tscn").instantiate() as Skater
	add_child_autofree(_goalie)
	add_child_autofree(_puck)
	add_child_autofree(_carrier)
	_carrier.set_physics_process(false)
	_carrier.set_process(false)
	_ctrl = GoalieController.new()
	add_child_autofree(_ctrl)


# Opposing carrier winding up a shot from the slot, puck pinned to the blade side
# (as Skater.enter_slapshot_pinning does for the slapper, and as the body-local
# blade freeze does for the wrister), aimed at the far top corner.
func _arm_windup(shooter: Vector3, pin_offset_x: float, aim: Vector3,
		shot_state: int = State.SLAPPER_CHARGE_WITH_PUCK) -> void:
	_carrier.global_position = shooter
	_carrier.velocity = Vector3.ZERO
	_carrier.current_shot_state = shot_state
	var pin := shooter + Vector3(pin_offset_x, 0.0, 0.0)
	pin.y = _puck.ice_height
	_puck.global_position = pin
	_puck.set_carrier(_carrier)
	# Direction the shot would fire — the goalie's directional pre-lean reads this.
	var dir: Vector3 = (aim - pin).normalized()
	_carrier.predicted_shot_velocity = dir * 30.0
	_ctrl.set_skater_getter(func() -> Array: return [_carrier])
	_ctrl.setup(_goalie, _puck, GOAL_Z, true)


func _tick(n: int) -> void:
	for _i: int in n:
		_ctrl._physics_process(DT)


func test_goalie_reads_the_slapper_windup_in_the_slot() -> void:
	# Slot shooter 7 m out, dead centre; puck pinned 1 m to the side; aimed high glove.
	var shooter := Vector3(0.0, 0.0, GOAL_Z + 7.0)
	_arm_windup(shooter, 1.0, Vector3(-0.85, 1.1, GOAL_Z))
	_tick(120)   # 1 s: settle + accumulate the pre-arm read (prearm_read_time 0.40 s)

	gut.p("carrier state=%d  puck@%.2f,%.2f  goalie@%.2f,%.2f" % [
			_carrier.current_shot_state,
			_puck.global_position.x, _puck.global_position.z,
			_goalie.global_position.x, _goalie.global_position.z])
	gut.p("reading_pinned_windup=%s  is_reading_shot_threat=%s  prelean_active=%s directional=%s  prime_linger=%.3f" % [
			_ctrl._reading_pinned_windup,
			_ctrl._is_reading_shot_threat(_carrier),
			_ctrl._pose_inputs.prelean_active,
			_ctrl._pose_inputs.prelean_directional,
			_ctrl._prime_linger_timer])

	# 1. The windup read fires at all.
	assert_true(_ctrl._is_reading_shot_threat(_carrier),
			"goalie must READ the slot slapper windup (drives squaring + pre-arm + pre-lean)")
	# 2. Squaring override engaged (squares to the pinned puck, not the chest).
	assert_true(_ctrl._reading_pinned_windup,
			"pinned-windup squaring must engage during the windup")
	# 3. Directional pre-lean populated toward the aimed corner.
	assert_true(_ctrl._pose_inputs.prelean_directional,
			"directional pre-lean must engage (glove pre-positions toward the aimed corner)")
	# 4. Pre-arm timing prime accumulated after >0.40 s of continuous reading.
	assert_gt(_ctrl._prime_linger_timer, 0.0,
			"pre-arm read must prime the faster reaction after reading the windup")


# The honest "does he cover it" metric: the shot passes the goalie's DEPTH plane
# at some x; a set goalie saves it if that x is within his lateral reach (butterfly
# pad half-spread + a little). Goalie holds his set position on a direct shot (he
# doesn't chase), so coverage is decided by where the wind-up read left him.
const _SAVE_REACH_M: float = 0.55   # butterfly pad half-coverage, low shot

func _shot_x_at_goalie_depth(pin: Vector3, vel: Vector3) -> float:
	var g_z: float = _goalie.global_position.z
	var t: float = (g_z - pin.z) / vel.z
	return pin.x + vel.x * t

func test_shade_lets_the_goalie_cover_the_against_grain_corner() -> void:
	# The cheese: slot slapper, puck pinned to the blade side, ripped to the FAR
	# (against-the-grain) corner. Squaring to the pinned puck alone left the goalie
	# a metre short. With the aim shade he reads the locked wind-up and cheats his
	# angle over, so the shot line falls inside his reach at his depth plane.
	var shooter := Vector3(0.0, 0.0, GOAL_Z + 7.0)
	var pin := shooter + Vector3(1.0, 0.0, 0.0)
	var far_corner := Vector3(-0.80, _puck.ice_height, GOAL_Z)
	_arm_windup(shooter, 1.0, far_corner)
	_tick(150)   # full wind-up read → shade ramps in

	var shot_speed: float = 32.0
	var vel: Vector3 = (far_corner - pin).normalized() * shot_speed
	vel.y = 0.0
	var shot_x: float = _shot_x_at_goalie_depth(pin, vel)
	var goalie_x: float = _goalie.global_position.x
	var gap: float = absf(goalie_x - shot_x)
	gut.p("shaded goalie_x=%.2f  shot_x@depth=%.2f  gap=%.2f  reach=%.2f  read_timer=%.2f" % [
			goalie_x, shot_x, gap, _SAVE_REACH_M, _ctrl._shot_read_timer])

	assert_lt(goalie_x, 0.10,
			"goalie must shade toward the aimed (far) corner, not hold the puck-squared angle")
	assert_lt(gap, _SAVE_REACH_M,
			"the shot line must fall inside the goalie's reach at his depth — a save, not a cheese")


func test_quick_release_still_beats_the_shade() -> void:
	# The skill window survives: a snap release with almost no wind-up read gets
	# little shade, so a well-placed corner shot still beats the goalie.
	var shooter := Vector3(0.0, 0.0, GOAL_Z + 7.0)
	var pin := shooter + Vector3(1.0, 0.0, 0.0)
	var far_corner := Vector3(-0.80, _puck.ice_height, GOAL_Z)
	_arm_windup(shooter, 1.0, far_corner)
	_tick(8)   # ~0.07 s of read — far below prearm_read_time (0.40 s)

	var shot_speed: float = 32.0
	var vel: Vector3 = (far_corner - pin).normalized() * shot_speed
	vel.y = 0.0
	var gap: float = absf(_goalie.global_position.x - _shot_x_at_goalie_depth(pin, vel))
	gut.p("quick-release gap=%.2f (read_timer=%.2f)" % [gap, _ctrl._shot_read_timer])
	assert_gt(gap, _SAVE_REACH_M,
			"a quick release gets little shade — a placed corner shot still beats the goalie")


# ── Wrister wind-up: same PIN, different MOBILITY ────────────────────────────
# The coil-and-release wrister freezes the blade at its body-local pose, so the
# puck rides the carrier rigidly — the same pin the slapper has. What it does NOT
# share is the plant: the slapper suppresses locomotion and drags velocity to
# zero, the wrister suppresses nothing. So the wrister must earn the pinned reads
# and not the planted one.

func test_wrister_windup_earns_the_pinned_read_but_not_the_planted_one() -> void:
	var shooter := Vector3(0.0, 0.0, GOAL_Z + 7.0)
	_arm_windup(shooter, 0.5, Vector3(-0.85, 1.1, GOAL_Z), State.WRISTER_AIM)
	_tick(120)

	assert_true(_ctrl._is_reading_shot_threat(_carrier),
			"the wrister coil is a visible wind-up — the goalie must read it")
	assert_true(_ctrl._reading_pinned_windup,
			"a wrister wind-up pins the puck body-local, so pinned-windup squaring must engage")
	assert_false(_ctrl._reading_planted_windup,
			"a wrister shooter is NOT planted — the positional shade must stay off")
	# The TEMPORAL credit is direction-agnostic, so it is not withheld from a
	# mobile shooter: relocating doesn't invalidate being ready to move.
	assert_gt(_ctrl._prime_linger_timer, 0.0,
			"reading a wrister wind-up must still prime the faster reaction")


# Advance carrier + puck together at `vel` so the controller's position-derived
# `_puck_velocity_est` converges on the carrier's own velocity — which is exactly
# what a body-rigid pin produces in the live game.
func _tick_carrying(vel: Vector3, n: int) -> void:
	_carrier.velocity = vel
	for _i: int in n:
		_carrier.global_position += vel * DT
		_puck.global_position += vel * DT
		_ctrl._physics_process(DT)


func test_wrister_windup_does_not_double_count_the_carrier_velocity() -> void:
	# THE BUG THIS FIXES: during a wind-up the puck's velocity IS the carrier's
	# (rigid pin), so adding a puck lead on top of the carrier lead counts the same
	# body motion twice — over-committing the goalie ahead of the puck and opening
	# the against-the-grain side. In tight that was up to ~1.67x the intended lead.
	#
	# 3.5 m out keeps chest_t well below 1 (so an un-suppressed puck lead would
	# really contribute) and 2.0 m/s stays under beaten_wide_min_lateral_speed, so
	# the goalie holds his feet and the threat math is what's under test.
	var shooter := Vector3(0.0, 0.0, GOAL_Z + 3.5)
	_arm_windup(shooter, 0.4, Vector3(-0.85, 0.3, GOAL_Z), State.WRISTER_AIM)
	var vel := Vector3(2.0, 0.0, 0.0)
	_tick_carrying(vel, 40)

	assert_true(_ctrl._reading_pinned_windup, "precondition: the pinned read is engaged")
	# Sanity: the pin really is rigid, so the estimate tracks the carrier.
	assert_almost_eq(_ctrl._puck_velocity_est.x, vel.x, 0.15,
			"precondition: a body-rigid pin makes the puck estimate equal carrier velocity")

	# With w == 0 the blended threat IS the puck, so the residual is purely lead.
	var threat: Vector3 = _ctrl._compute_threat_position()
	var lead_x: float = threat.x - _puck.global_position.x
	var carrier_only: float = vel.x * _ctrl.carrier_velocity_lead_time
	var double_counted: float = carrier_only \
			+ vel.x * _ctrl.puck_velocity_lead_time * (1.0 - _ctrl._chest_t)
	gut.p("lead_x=%.4f  carrier_only=%.4f  double_counted=%.4f  chest_t=%.2f" % [
			lead_x, carrier_only, double_counted, _ctrl._chest_t])

	assert_almost_eq(lead_x, carrier_only, 0.01,
			"a pinned wind-up must lead by the CARRIER velocity alone")
	assert_lt(lead_x, double_counted - 0.02,
			"the puck lead must be suppressed — adding it double-counts the same body motion")


func test_ordinary_carry_keeps_the_puck_lead() -> void:
	# The guard on the fix: outside a wind-up the blade genuinely dangles
	# independently of the body, which is the motion the puck lead exists to catch.
	# It must NOT be suppressed there.
	var shooter := Vector3(0.0, 0.0, GOAL_Z + 3.5)
	_arm_windup(shooter, 0.4, Vector3(-0.85, 0.3, GOAL_Z), State.SKATING_WITH_PUCK)
	_tick_carrying(Vector3(2.0, 0.0, 0.0), 40)

	assert_false(_ctrl._reading_pinned_windup,
			"ordinary carry is not a wind-up — the pinned override must stay off")
	# Threat is chest-blended here, so measure the lead against the blend, not the
	# puck: the point is only that the puck term still contributes.
	var chest_t: float = _ctrl._chest_t
	assert_gt(1.0 - chest_t, 0.0, "precondition: in tight enough for the puck lead to apply")
