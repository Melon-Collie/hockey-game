extends Node

# Mute-on-unfocus: silence the Master bus while the OS focus is on another
# window, then restore the player's intended mute state on return. Gated by
# PlayerPrefs.mute_when_unfocused (default on). Mirrors network_manager's use
# of the WM window-focus notifications.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		_apply_focus_mute(true)
	elif what == NOTIFICATION_WM_WINDOW_FOCUS_IN:
		_apply_focus_mute(false)


func _apply_focus_mute(unfocused: bool) -> void:
	var master: int = AudioServer.get_bus_index("Master")
	if master == -1:
		return
	if unfocused:
		if PlayerPrefs.mute_when_unfocused:
			AudioServer.set_bus_mute(master, true)
	else:
		# On focus return, restore whatever the player's Mute All setting was.
		AudioServer.set_bus_mute(master, PlayerPrefs.master_muted)


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
	STICK_LIFT,
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
	Sound.STICK_LIFT:       "res://Sounds/stick_lift.wav",
	Sound.PERIOD_BUZZER:    "res://Sounds/period_buzzer.wav",
	Sound.BODY_CHECK:       "res://Sounds/body_check.ogg",
	Sound.FACEOFF_WHISTLE:  "res://Sounds/faceoff_whistle.wav",
}

const _UI_POOL_SIZE: int = 4
const _SFX_2D_POOL_SIZE: int = 4
const _SFX_3D_POOL_SIZE: int = 12

# 3D world-sound falloff. Live play frames the puck closely (game cam ~15 m up),
# so the tight defaults keep events spatial without bleeding across the rink.
const _WORLD_UNIT_SIZE: float = 6.0
const _WORLD_MAX_DISTANCE: float = 40.0
# Replay viewing widens the falloff: the offline viewer's cameras (broadcast
# booth, chase, free) sit far from the action — the press-box hard cam is
# ~19–38 m from the puck, where the live defaults attenuate recorded events to
# near-silence (and far-side events hit the 40 m cutoff entirely). The wider
# curve keeps positional/stereo cues but lifts the level so the cinematic
# distance stays audible. Toggled by set_replay_audio_range, restored on exit.
const _REPLAY_UNIT_SIZE: float = 20.0
const _REPLAY_MAX_DISTANCE: float = 80.0

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
		p.max_distance = _WORLD_MAX_DISTANCE
		p.unit_size = _WORLD_UNIT_SIZE
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


func play_world(sound: Sound, position: Vector3, volume_db: float = 0.0, pitch_variance: float = 0.0, pitch_scale: float = 1.0) -> void:
	var stream: AudioStream = _streams.get(sound)
	if stream == null:
		return
	for p: AudioStreamPlayer3D in _pool_3d:
		if not p.playing:
			p.stream = stream
			p.volume_db = volume_db
			p.pitch_scale = randf_range(1.0 - pitch_variance, 1.0 + pitch_variance) * pitch_scale if pitch_variance > 0.0 else pitch_scale
			p.global_position = position
			p.play()
			return


# Widen (or restore) the 3D world-sound falloff for replay viewing. The offline
# replay viewer's cameras sit far from the action, where the live falloff
# attenuates recorded events to silence; this lifts the level while keeping
# stereo/positional cues. Call with true on replay entry, false on exit. Idempotent.
func set_replay_audio_range(enabled: bool) -> void:
	var unit_size: float = _REPLAY_UNIT_SIZE if enabled else _WORLD_UNIT_SIZE
	var max_distance: float = _REPLAY_MAX_DISTANCE if enabled else _WORLD_MAX_DISTANCE
	for p: AudioStreamPlayer3D in _pool_3d:
		p.unit_size = unit_size
		p.max_distance = max_distance


# Connects hover and click sounds to a button. Call after creating each Button node.
func wire_button(button: Button) -> void:
	button.mouse_entered.connect(func() -> void: play_ui(Sound.UI_HOVER))
	button.pressed.connect(func() -> void: play_ui(Sound.UI_CLICK))
