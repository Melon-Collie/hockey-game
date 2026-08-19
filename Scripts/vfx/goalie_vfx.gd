class_name GoalieVFX
extends Node3D

# Snow effects for the goalie, driven KINEMATICALLY off the rendered pose
# rather than off controller state or network events. The pose is the one
# thing every machine agrees on — the host lerps it via apply_body_config,
# clients write it via apply_network_pose, and replay plays it back — so
# reading "the body dropped fast" / "the goalie is low and moving" makes the
# same snow appear everywhere with zero wire traffic, the same way
# SkaterVFX reads is_braking instead of listening for a brake event.

# Body-height thresholds are keyed to GoalieBodyConfigBuilder's resting body
# heights (standing 1.22 m, butterfly 0.40 m — goalie-local). The fire line
# sits well below any standing-family stance so a crouch can't trip it, and
# the re-arm line sits high enough that a butterfly held under traffic can't
# re-fire from pose jitter.
const DROP_FIRE_BODY_Y: float = 0.75
const DROP_REARM_BODY_Y: float = 0.95
# Committed drops move the body down at several m/s; the pose lerp easing into
# a hold moves it at centimetres/s. The gate splits those two regimes.
const DROP_MIN_FALL_SPEED: float = 1.2
const DROP_FULL_FALL_SPEED: float = 3.0   # burst size tops out here
const DROP_BURST_AMOUNT_MIN: int = 14
const DROP_BURST_AMOUNT_MAX: int = 28
const DROP_BURST_VEL_MIN: float = 1.8
const DROP_BURST_VEL_MAX: float = 4.0

# Slide spray: goalie is down (butterfly-family) and the root is translating.
# Speed floor keeps a shuffle-in-place quiet; sprays only read as a push when
# there's real travel behind them.
const SLIDE_LOW_BODY_Y: float = 0.70
const SLIDE_MIN_SPEED: float = 1.5
const SLIDE_LEAD_M: float = 0.55          # spray from the leading pad edge, not the body centre


var _pad_bursts: Array[CPUParticles3D] = []   # index 0 = left pad, 1 = right pad
var _slide_spray: CPUParticles3D = null
var _prev_root_pos: Vector3 = Vector3.ZERO
var _prev_body_y: float = 0.0
var _drop_armed: bool = true
var _frozen: bool = false


func _ready() -> void:
	for i: int in 2:
		var burst: CPUParticles3D = _make_pad_burst()
		add_child(burst)
		_pad_bursts.append(burst)
	_slide_spray = _make_slide_spray()
	add_child(_slide_spray)
	var goalie: Goalie = get_parent() as Goalie
	if goalie != null:
		_prev_root_pos = goalie.global_position
		_prev_body_y = goalie.get_body_position().y


func _process(delta: float) -> void:
	# Pose-capture freeze — silence the continuous emitter on the transition,
	# not every frame (see SkaterVFX._process for the pattern and the trap).
	if CosmeticFreeze.vfx:
		if not _frozen:
			_frozen = true
			_slide_spray.emitting = false
		return
	_frozen = false
	var goalie: Goalie = get_parent() as Goalie
	if goalie == null:
		return

	var root_pos: Vector3 = goalie.global_position
	var body_y: float = goalie.get_body_position().y

	# Reset/faceoff teleport guard: a snapped goalie must not read as a
	# lightning-fast slide or drop.
	if (root_pos - _prev_root_pos).length() > IceVFX.TELEPORT_THRESHOLD:
		_prev_root_pos = root_pos
		_prev_body_y = body_y
		_slide_spray.emitting = false
		return

	var flat_vel: Vector3 = (root_pos - _prev_root_pos) / delta
	flat_vel.y = 0.0
	_prev_root_pos = root_pos

	var fall_speed: float = (_prev_body_y - body_y) / delta
	_prev_body_y = body_y

	# Butterfly drop: both pads slam the ice — one outward chip burst per pad,
	# edge-triggered so a held butterfly fires exactly once.
	if _drop_armed and body_y < DROP_FIRE_BODY_Y and fall_speed > DROP_MIN_FALL_SPEED:
		_drop_armed = false
		_fire_pad_bursts(goalie, fall_speed)
	elif not _drop_armed and body_y > DROP_REARM_BODY_Y:
		_drop_armed = true

	# Butterfly slide: a plow of snow off the leading edge while the goalie is
	# down and travelling. Continuous, like the skater's hockey-stop fan.
	if body_y < SLIDE_LOW_BODY_Y and flat_vel.length() > SLIDE_MIN_SPEED:
		_emit_slide_spray(root_pos, flat_vel)
	else:
		_slide_spray.emitting = false


# Burst size and throw scale with how hard the body came down, so a desperate
# committed drop reads bigger than an easy set butterfly.
func _fire_pad_bursts(goalie: Goalie, fall_speed: float) -> void:
	var t: float = clampf((fall_speed - DROP_MIN_FALL_SPEED)
			/ (DROP_FULL_FALL_SPEED - DROP_MIN_FALL_SPEED), 0.0, 1.0)
	var amount: int = int(lerpf(float(DROP_BURST_AMOUNT_MIN), float(DROP_BURST_AMOUNT_MAX), t))
	var vel_max: float = lerpf(DROP_BURST_VEL_MIN, DROP_BURST_VEL_MAX, t)
	var pad_locals: Array[Vector3] = [
		goalie.get_left_pad_position(), goalie.get_right_pad_position()]
	for i: int in 2:
		var burst: CPUParticles3D = _pad_bursts[i]
		var pad_world: Vector3 = goalie.to_global(pad_locals[i])
		burst.global_position = Vector3(pad_world.x, IceVFX.ICE_Y, pad_world.z)
		burst.amount = amount
		burst.initial_velocity_min = vel_max * 0.4
		burst.initial_velocity_max = vel_max
		# Chips kick outward along the pad's own side (goalie-local ±X) plus
		# lift. direction is emitter-local — convert the world vector the same
		# way SkaterVFX does.
		var side: float = -1.0 if i == 0 else 1.0
		var world_dir: Vector3 = (goalie.global_transform.basis
				* Vector3(side, 0.0, 0.0) + Vector3(0.0, 0.6, 0.0)).normalized()
		burst.direction = burst.global_transform.basis.inverse() * world_dir
		burst.restart()


func _emit_slide_spray(root_pos: Vector3, flat_vel: Vector3) -> void:
	var travel: Vector3 = flat_vel.normalized()
	var world_dir: Vector3 = (travel + Vector3(0.0, 0.4, 0.0)).normalized()
	_slide_spray.global_position = root_pos + travel * SLIDE_LEAD_M \
			+ Vector3(0.0, IceVFX.ICE_Y, 0.0)
	_slide_spray.direction = _slide_spray.global_transform.basis.inverse() * world_dir
	_slide_spray.emitting = true


func _make_pad_burst() -> CPUParticles3D:
	var e := CPUParticles3D.new()
	e.emitting = false
	e.amount = DROP_BURST_AMOUNT_MAX
	e.lifetime = 0.35
	e.one_shot = true
	e.explosiveness = 0.95
	e.randomness = 0.4
	e.local_coords = false
	e.direction = Vector3(0.0, 1.0, 0.0)  # overwritten per drop
	e.spread = 55.0
	e.gravity = Vector3(0.0, -25.0, 0.0)
	e.scale_amount_min = 0.025
	e.scale_amount_max = 0.05
	e.mesh = IceVFX.blob(IceVFX.snow(0.85))
	return e


func _make_slide_spray() -> CPUParticles3D:
	var e := CPUParticles3D.new()
	e.emitting = false
	e.amount = 110
	e.lifetime = 0.32
	e.one_shot = false
	e.explosiveness = 0.0
	e.randomness = 0.3
	e.local_coords = false
	e.direction = Vector3(1.0, 0.0, 0.0)  # overwritten per frame
	e.spread = 55.0
	e.initial_velocity_min = 2.0
	e.initial_velocity_max = 6.0
	e.gravity = Vector3(0.0, -25.0, 0.0)
	e.scale_amount_min = 0.03
	e.scale_amount_max = 0.06
	e.mesh = IceVFX.blob(IceVFX.snow(0.85))
	return e
