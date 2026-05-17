extends Node

# Drives crowd audio: a looping ambient murmur plus cheer one-shots on goals
# and period/game-end buzzers. SoundManager itself stays one-shot-only — the
# looping ambient player lives here so the manager's pool semantics aren't
# disturbed.
#
# Add this node under Hockey.tscn root. It auto-wires to the GameManager
# autoload's `goal_scored` and `phase_changed` signals in _ready().

@export var ambient_stream_path: String = "res://Sounds/crowd_ambient.ogg"
@export var ambient_volume_db: float = -14.0
@export var cheer_volume_db: float = 0.0
@export var duck_volume_db: float = -4.0
@export var duck_recover_time: float = 4.0

var _ambient_player: AudioStreamPlayer = null
var _tween: Tween = null


func _ready() -> void:
	_ambient_player = AudioStreamPlayer.new()
	_ambient_player.bus = "SFX"
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


func _cheer() -> void:
	var sm: Node = get_node_or_null("/root/SoundManager")
	if sm != null:
		sm.play_sfx(sm.Sound.CROWD_CHEER, cheer_volume_db, 0.05)
	_duck_ambient()


func _duck_ambient() -> void:
	if _ambient_player == null:
		return
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(_ambient_player, "volume_db", duck_volume_db, 0.15)
	_tween.tween_property(_ambient_player, "volume_db", ambient_volume_db, duck_recover_time)
