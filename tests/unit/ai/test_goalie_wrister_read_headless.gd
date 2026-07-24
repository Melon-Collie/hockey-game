extends GutTest

# Wrister wind-up read: the new coil-and-release wrister FREEZES the puck at the
# shot origin while the torso coils — a legible "committing to a shot" tell. The
# goalie reads it like the slapper (square to the frozen origin, pre-arm, pre-lean),
# but with ONE difference: the wrister's aim is origin→cursor at RELEASE, never
# locked at press, so the aim-shade is LAGGED (`_wrister_shade_x` low-passes the
# projected crossing). A telegraphed, held aim gets read; a disguised late flick
# outruns the lag. This drives the REAL GoalieController against a real Skater
# holding the wind-up and asserts both halves: the read engages, and the lag makes
# it beatable by disguise.

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


# Opposing carrier holding a wrister coil from the slot. The freeze holds the blade
# (and pinned puck) near the carry pose — model it with a small blade-side offset.
# `aim` is where the origin→cursor shot currently points; the goalie reads the coil
# through the published predicted velocity.
func _arm_wrister_windup(shooter: Vector3, pin_offset_x: float, aim: Vector3) -> void:
	_carrier.global_position = shooter
	_carrier.velocity = Vector3.ZERO
	_carrier.current_shot_state = State.WRISTER_AIM
	var pin := shooter + Vector3(pin_offset_x, 0.0, 0.0)
	pin.y = _puck.ice_height
	_puck.global_position = pin
	_puck.set_carrier(_carrier)
	_set_live_aim(pin, aim)
	_ctrl.set_skater_getter(func() -> Array: return [_carrier])
	_ctrl.setup(_goalie, _puck, GOAL_Z, true)


# Re-point the live (unlocked) wrister aim: the shot fires origin→cursor, so the
# published predicted velocity swings toward wherever the cursor currently sits.
func _set_live_aim(origin: Vector3, aim: Vector3) -> void:
	var dir: Vector3 = (aim - origin).normalized()
	_carrier.predicted_shot_velocity = dir * 30.0


func _tick(n: int) -> void:
	for _i: int in n:
		_ctrl._physics_process(DT)


func _shot_x_at_goalie_depth(pin: Vector3, vel: Vector3) -> float:
	var g_z: float = _goalie.global_position.z
	var t: float = (g_z - pin.z) / vel.z
	return pin.x + vel.x * t


func test_goalie_reads_the_wrister_windup_in_the_slot() -> void:
	# Slot shooter 7 m out, dead centre; puck frozen ~0.3 m to the blade side; aimed
	# high glove. Same read the slapper gets — square, pre-arm, pre-lean all engage.
	var shooter := Vector3(0.0, 0.0, GOAL_Z + 7.0)
	_arm_wrister_windup(shooter, 0.3, Vector3(-0.85, 1.1, GOAL_Z))
	_tick(120)   # 1 s: settle + accumulate the pre-arm read (prearm_read_time 0.40 s)

	gut.p("reading_wrister_tell=%s  is_reading_shot_threat=%s  prelean_directional=%s  prime_linger=%.3f" % [
			_ctrl._reading_wrister_tell,
			_ctrl._is_reading_shot_threat(_carrier),
			_ctrl._pose_inputs.prelean_directional,
			_ctrl._prime_linger_timer])

	# 1. The wind-up read fires (the wrister freeze is a shot tell, like the slapper).
	assert_true(_ctrl._is_reading_shot_threat(_carrier),
			"goalie must READ the slot wrister coil (drives squaring + pre-arm + pre-lean)")
	# 2. Square-to-origin engaged (squares to the frozen puck, not the chest).
	assert_true(_ctrl._reading_wrister_tell,
			"wrister-tell squaring must engage during the coil")
	# 3. Directional pre-lean populated toward the aimed corner.
	assert_true(_ctrl._pose_inputs.prelean_directional,
			"directional pre-lean must engage (glove pre-positions toward the aimed corner)")
	# 4. Pre-arm timing prime accumulated after >0.40 s of continuous reading.
	assert_gt(_ctrl._prime_linger_timer, 0.0,
			"pre-arm read must prime the faster reaction after reading the coil")


func test_telegraphed_wrister_is_read_but_disguise_beats_the_lag() -> void:
	# The heart of the design. Two coils with the SAME final aim (far corner) but
	# different histories:
	#   Telegraphed — held on the far corner the whole coil. The lagged shade catches
	#     up, so the goalie cheats his angle over toward it.
	#   Disguised — held CENTRE almost the whole coil, then flicked to the far corner
	#     for the last two ticks and "released". The lag hasn't caught up, so the
	#     goalie is still square — the disguise beat the read.
	# Equal total read time (shade_t is identical); only `_wrister_shade_x` differs.
	var shooter := Vector3(0.0, 0.0, GOAL_Z + 7.0)
	var pin := shooter + Vector3(0.3, 0.0, 0.0)
	var far_corner := Vector3(-0.80, _puck.ice_height, GOAL_Z)
	var centre := Vector3(0.0, _puck.ice_height, GOAL_Z)

	# Telegraphed: far corner the whole way.
	_arm_wrister_windup(shooter, 0.3, far_corner)
	_tick(150)
	var goalie_x_telegraphed: float = _goalie.global_position.x
	var shade_x_telegraphed: float = _ctrl._wrister_shade_x

	# Disguised: fresh goalie, hold centre, then flick far for the last 2 ticks.
	before_each()
	_arm_wrister_windup(shooter, 0.3, centre)
	_tick(148)
	_set_live_aim(pin, far_corner)   # late flick to the same corner
	_tick(2)
	var goalie_x_disguised: float = _goalie.global_position.x
	var shade_x_disguised: float = _ctrl._wrister_shade_x

	gut.p("telegraphed: goalie_x=%.2f shade_x=%.2f | disguised: goalie_x=%.2f shade_x=%.2f" % [
			goalie_x_telegraphed, shade_x_telegraphed, goalie_x_disguised, shade_x_disguised])

	# The lagged shade converged toward the far corner only when the aim was HELD there.
	assert_lt(shade_x_telegraphed, -0.30,
			"held far-corner aim: the lag catches up, shade tracks the crossing")
	assert_gt(shade_x_disguised, -0.15,
			"late flick: the lag has NOT caught up, shade still near centre")
	# So the telegraphed shooter is read (goalie shaded over) while the disguised one
	# beats it (goalie still square) — even though the actual shot is identical.
	assert_lt(goalie_x_telegraphed, -0.10,
			"telegraphed coil: goalie shades toward the read corner")
	assert_gt(goalie_x_disguised, goalie_x_telegraphed + 0.15,
			"disguised late flick beats the lag — goalie left far more square than the read case")
