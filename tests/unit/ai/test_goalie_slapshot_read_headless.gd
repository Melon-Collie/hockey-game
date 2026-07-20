extends GutTest

# Reproduction probe for the "Colin cheese" slot slapshot: skate into the slot,
# wind up a slapper, and it goes past the side of a frozen goalie that never
# reads the windup. Squaring, the pre-arm timing prime, and the directional
# pre-lean ALL gate on the goalie reading a SLAPPER_CHARGE_WITH_PUCK carrier
# (_is_reading_shot_threat / _reading_slapper_tell), so if that read never fires
# none of the three engage — which matches the report (no pre-lean, barely
# reacts). This drives the REAL GoalieController against a real Skater carrier
# holding the wind-up and asserts each read actually turns on.

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


# Opposing carrier winding up a slapshot from the slot, puck pinned ~1 m to the
# blade side (as Skater.enter_slapshot_pinning does), aimed at the far top corner.
func _arm_slapper_windup(shooter: Vector3, pin_offset_x: float, aim: Vector3) -> void:
	_carrier.global_position = shooter
	_carrier.velocity = Vector3.ZERO
	_carrier.current_shot_state = State.SLAPPER_CHARGE_WITH_PUCK
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
	_arm_slapper_windup(shooter, 1.0, Vector3(-0.85, 1.1, GOAL_Z))
	_tick(120)   # 1 s: settle + accumulate the pre-arm read (prearm_read_time 0.40 s)

	gut.p("carrier state=%d  puck@%.2f,%.2f  goalie@%.2f,%.2f" % [
			_carrier.current_shot_state,
			_puck.global_position.x, _puck.global_position.z,
			_goalie.global_position.x, _goalie.global_position.z])
	gut.p("reading_slapper_tell=%s  is_reading_shot_threat=%s  prelean_active=%s directional=%s  prime_linger=%.3f" % [
			_ctrl._reading_slapper_tell,
			_ctrl._is_reading_shot_threat(_carrier),
			_ctrl._pose_inputs.prelean_active,
			_ctrl._pose_inputs.prelean_directional,
			_ctrl._prime_linger_timer])

	# 1. The windup read fires at all.
	assert_true(_ctrl._is_reading_shot_threat(_carrier),
			"goalie must READ the slot slapper windup (drives squaring + pre-arm + pre-lean)")
	# 2. Squaring override engaged (squares to the pinned puck, not the chest).
	assert_true(_ctrl._reading_slapper_tell,
			"slapper-tell squaring must engage during the windup")
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
	_arm_slapper_windup(shooter, 1.0, far_corner)
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
	_arm_slapper_windup(shooter, 1.0, far_corner)
	_tick(8)   # ~0.07 s of read — far below prearm_read_time (0.40 s)

	var shot_speed: float = 32.0
	var vel: Vector3 = (far_corner - pin).normalized() * shot_speed
	vel.y = 0.0
	var gap: float = absf(_goalie.global_position.x - _shot_x_at_goalie_depth(pin, vel))
	gut.p("quick-release gap=%.2f (read_timer=%.2f)" % [gap, _ctrl._shot_read_timer])
	assert_gt(gap, _SAVE_REACH_M,
			"a quick release gets little shade — a placed corner shot still beats the goalie")
