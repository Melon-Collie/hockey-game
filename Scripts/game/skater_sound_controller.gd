class_name SkaterSoundController
extends Node

# Tunable thresholds
const _SKATE_START_SPEED: float = 0.5      # m/s XZ to start loop
const _SKATE_MAX_SPEED: float = 10.0       # m/s XZ for full volume
const _SKATE_MIN_VOL_DB: float = -24.0
const _SKATE_MAX_VOL_DB: float = 0.0
const _SKATE_MIN_PITCH: float = 0.85
const _SKATE_MAX_PITCH: float = 1.15

const _BRAKE_MIN_SPEED: float = 1.5        # must be moving this fast for brake sound

var _skater: Skater = null
var _skate_player: AudioStreamPlayer3D = null
var _brake_player: AudioStreamPlayer3D = null


func setup(skater: Skater) -> void:
	_skater = skater
	_skate_player = _make_loop_player("res://Sounds/skate_loop.ogg")
	_brake_player = _make_oneshot_player("res://Sounds/skate_brake.wav")


func _make_loop_player(path: String) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.bus = "Master"
	p.max_distance = 35.0
	p.unit_size = 5.0
	p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	if ResourceLoader.exists(path):
		p.stream = load(path)
	add_child(p)
	return p


func _make_oneshot_player(path: String) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.bus = "Master"
	p.max_distance = 35.0
	p.unit_size = 5.0
	p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	if ResourceLoader.exists(path):
		p.stream = load(path)
	add_child(p)
	return p


func _physics_process(_delta: float) -> void:
	if _skater == null:
		return

	var vel: Vector3 = _skater.velocity
	var speed: float = Vector2(vel.x, vel.z).length()

	_update_skate_loop(speed)
	_update_brake(speed)


func _update_skate_loop(speed: float) -> void:
	if _skate_player.stream == null:
		return
	if speed > _SKATE_START_SPEED:
		var t: float = clampf(
			(speed - _SKATE_START_SPEED) / (_SKATE_MAX_SPEED - _SKATE_START_SPEED), 0.0, 1.0)
		_skate_player.volume_db = lerpf(_SKATE_MIN_VOL_DB, _SKATE_MAX_VOL_DB, t)
		_skate_player.pitch_scale = lerpf(_SKATE_MIN_PITCH, _SKATE_MAX_PITCH, t)
		if not _skate_player.playing:
			_skate_player.play()
	else:
		if _skate_player.playing:
			_skate_player.stop()


func _update_brake(speed: float) -> void:
	if _brake_player.stream == null or _brake_player.playing:
		return
	if _skater.is_braking and speed >= _BRAKE_MIN_SPEED:
		_brake_player.global_position = _skater.global_position
		_brake_player.play()
