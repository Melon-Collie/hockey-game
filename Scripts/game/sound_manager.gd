extends Node

enum Sound {
	UI_HOVER,
	UI_CLICK,
	SHOT_WRISTER,
	SHOT_SLAPPER,
	PUCK_PICKUP,
	GOAL_HORN,
	SKATE_BRAKE,
	PUCK_BOARDS,
	PUCK_GOALIE,
	PUCK_POST,
	PUCK_GOAL_BODY,
	PUCK_DEFLECTION,
	PUCK_BODY_BLOCK,
	PUCK_STRIP,
	PERIOD_BUZZER,
	BODY_CHECK,
	FACEOFF_WHISTLE,
}

const _SOUND_PATHS: Dictionary = {
	Sound.UI_HOVER:         "res://Sounds/ui_hover.wav",
	Sound.UI_CLICK:         "res://Sounds/ui_select.wav",
	Sound.SHOT_WRISTER:     "res://Sounds/shot_wrister.ogg",
	Sound.SHOT_SLAPPER:     "res://Sounds/shot_slapper.ogg",
	Sound.PUCK_PICKUP:      "res://Sounds/puck_pickup.ogg",
	Sound.GOAL_HORN:        "res://Sounds/goal_horn.ogg",
	Sound.SKATE_BRAKE:      "res://Sounds/skate_brake.wav",
	Sound.PUCK_BOARDS:      "res://Sounds/puck_boards.wav",
	Sound.PUCK_GOALIE:      "res://Sounds/puck_goalie.wav",
	Sound.PUCK_POST:        "res://Sounds/puck_post.wav",
	Sound.PUCK_GOAL_BODY:   "res://Sounds/puck_goal_body.wav",
	Sound.PUCK_DEFLECTION:  "res://Sounds/puck_deflection.wav",
	Sound.PUCK_BODY_BLOCK:  "res://Sounds/puck_body_block.ogg",
	Sound.PUCK_STRIP:       "res://Sounds/puck_strip.wav",
	Sound.PERIOD_BUZZER:    "res://Sounds/period_buzzer.wav",
	Sound.BODY_CHECK:       "res://Sounds/body_check.ogg",
	Sound.FACEOFF_WHISTLE:  "res://Sounds/faceoff_whistle.wav",
}

const _UI_POOL_SIZE: int = 4
const _SFX_2D_POOL_SIZE: int = 4
const _SFX_3D_POOL_SIZE: int = 12

var _streams: Dictionary = {}
var _pool_ui: Array[AudioStreamPlayer] = []      # UI bus — hover, click
var _pool_sfx_2d: Array[AudioStreamPlayer] = []  # SFX bus — horn, buzzer
var _pool_3d: Array[AudioStreamPlayer3D] = []    # SFX bus — all world sounds


func _ready() -> void:
	_ensure_buses()
	# PlayerPrefs._ready() runs first (autoload order), so saved volumes were
	# applied against buses that didn't exist yet. Re-apply now that SFX / UI /
	# Crowd exist so startup volumes match the slider state.
	PlayerPrefs.apply_audio()
	_load_streams()
	_build_pools()


func _ensure_buses() -> void:
	for bus_name: String in ["SFX", "UI", "Crowd"]:
		if AudioServer.get_bus_index(bus_name) == -1:
			var idx: int = AudioServer.bus_count
			AudioServer.add_bus(idx)
			AudioServer.set_bus_name(idx, bus_name)
			AudioServer.set_bus_send(idx, "Master")


func _load_streams() -> void:
	for sound: int in _SOUND_PATHS:
		var path: String = _SOUND_PATHS[sound]
		if ResourceLoader.exists(path):
			_streams[sound] = load(path)


func _build_pools() -> void:
	for i: int in _UI_POOL_SIZE:
		var p := AudioStreamPlayer.new()
		p.bus = "UI"
		add_child(p)
		_pool_ui.append(p)
	for i: int in _SFX_2D_POOL_SIZE:
		var p := AudioStreamPlayer.new()
		p.bus = "SFX"
		add_child(p)
		_pool_sfx_2d.append(p)
	for i: int in _SFX_3D_POOL_SIZE:
		var p := AudioStreamPlayer3D.new()
		p.bus = "SFX"
		p.max_distance = 40.0
		p.unit_size = 6.0
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		add_child(p)
		_pool_3d.append(p)


func play_ui(sound: Sound, volume_db: float = 0.0, pitch_variance: float = 0.0) -> void:
	var stream: AudioStream = _streams.get(sound)
	if stream == null:
		return
	for p: AudioStreamPlayer in _pool_ui:
		if not p.playing:
			p.stream = stream
			p.volume_db = volume_db
			p.pitch_scale = randf_range(1.0 - pitch_variance, 1.0 + pitch_variance) if pitch_variance > 0.0 else 1.0
			p.play()
			return


func play_sfx(sound: Sound, volume_db: float = 0.0, pitch_variance: float = 0.0) -> void:
	var stream: AudioStream = _streams.get(sound)
	if stream == null:
		return
	for p: AudioStreamPlayer in _pool_sfx_2d:
		if not p.playing:
			p.stream = stream
			p.volume_db = volume_db
			p.pitch_scale = randf_range(1.0 - pitch_variance, 1.0 + pitch_variance) if pitch_variance > 0.0 else 1.0
			p.play()
			return


func play_world(sound: Sound, position: Vector3, volume_db: float = 0.0, pitch_variance: float = 0.0) -> void:
	var stream: AudioStream = _streams.get(sound)
	if stream == null:
		return
	for p: AudioStreamPlayer3D in _pool_3d:
		if not p.playing:
			p.stream = stream
			p.volume_db = volume_db
			p.pitch_scale = randf_range(1.0 - pitch_variance, 1.0 + pitch_variance) if pitch_variance > 0.0 else 1.0
			p.global_position = position
			p.play()
			return


# Connects hover and click sounds to a button. Call after creating each Button node.
func wire_button(button: Button) -> void:
	button.mouse_entered.connect(func() -> void: play_ui(Sound.UI_HOVER))
	button.pressed.connect(func() -> void: play_ui(Sound.UI_CLICK))
