class_name CrowdAudioController
extends Node

# Drives crowd audio: a looping ambient murmur plus cheer one-shots on goals
# and period/game-end buzzers. Both stream types route through the dedicated
# "Arena" audio bus (created by SoundManager, shared with the horn/buzzer/
# whistle one-shots) so a single PlayerPrefs slider controls overall arena
# atmosphere independently of gameplay SFX.
#
# SoundManager stays one-shot-only — the looping ambient player and the small
# cheer pool both live here, mirroring how SkaterSoundController owns its own
# skate-loop AudioStreamPlayer3D.

@export var ambient_stream_path: String = "res://Sounds/crowd_ambient.wav"
@export var cheer_stream_path: String = "res://Sounds/crowd_cheer.wav"
@export var ambient_volume_db: float = -22.0
@export var cheer_volume_db: float = -7.0
@export var duck_volume_db: float = -10.0
@export var duck_recover_time: float = 4.0

const _CHEER_POOL_SIZE: int = 3
const _ARENA_BUS: StringName = &"Arena"

var _ambient_player: AudioStreamPlayer = null
var _cheer_pool: Array[AudioStreamPlayer] = []
var _cheer_stream: AudioStream = null
var _tween: Tween = null


func _ready() -> void:
	_ambient_player = AudioStreamPlayer.new()
	_ambient_player.bus = _ARENA_BUS
	_ambient_player.volume_db = ambient_volume_db
	add_child(_ambient_player)

	if ResourceLoader.exists(ambient_stream_path):
		var stream: AudioStream = load(ambient_stream_path)
		# Defensive: if the .ogg wasn't marked looping in the import dock,
		# nudge it here so the ambient doesn't go silent after one play.
		if stream is AudioStreamOggVorbis:
			(stream as AudioStreamOggVorbis).loop = true
		_ambient_player.stream = stream
		_ambient_player.finished.connect(_on_ambient_finished)
		_ambient_player.play()

	if ResourceLoader.exists(cheer_stream_path):
		_cheer_stream = load(cheer_stream_path)
	for i: int in _CHEER_POOL_SIZE:
		var p: AudioStreamPlayer = AudioStreamPlayer.new()
		p.bus = _ARENA_BUS
		add_child(p)
		_cheer_pool.append(p)

	var gm: Node = get_node_or_null("/root/GameManager")
	if gm != null:
		if gm.has_signal("goal_scored"):
			gm.goal_scored.connect(_on_goal_scored)
		if gm.has_signal("phase_changed"):
			gm.phase_changed.connect(_on_phase_changed)


# Safety net: a properly-looping AudioStream won't emit `finished`, but this
# catches the case where the import-dock loop flag wasn't set on the file.
func _on_ambient_finished() -> void:
	if _ambient_player != null and _ambient_player.stream != null:
		_ambient_player.play()


func _on_goal_scored(_scoring_team: Variant, _scorer: String, _a1: String, _a2: String) -> void:
	_cheer()


func _on_phase_changed(new_phase: int) -> void:
	if new_phase == GamePhase.Phase.END_OF_PERIOD or new_phase == GamePhase.Phase.GAME_OVER:
		_cheer()


# Public trigger for a crowd cheer + ambient duck. The replay viewer calls this
# off recorded goal events, since the live GameManager.goal_scored signal that
# normally drives _on_goal_scored doesn't fire during offline playback.
func cheer() -> void:
	_cheer()


func _cheer() -> void:
	if _cheer_stream != null:
		for p: AudioStreamPlayer in _cheer_pool:
			if not p.playing:
				p.stream = _cheer_stream
				p.volume_db = cheer_volume_db
				p.pitch_scale = randf_range(0.95, 1.05)
				p.play()
				break
	_duck_ambient()


func _duck_ambient() -> void:
	if _ambient_player == null:
		return
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(_ambient_player, "volume_db", duck_volume_db, 0.15)
	_tween.tween_property(_ambient_player, "volume_db", ambient_volume_db, duck_recover_time)
