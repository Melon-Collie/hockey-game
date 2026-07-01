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
# Arena venue one-shots (goal horn, period buzzer, faceoff whistle) route here
# so the Crowd slider governs all crowd/arena atmosphere as one group, separate
# from gameplay SFX. Sized for the game-over case where the goal horn and the
# period buzzer can overlap.
const _CROWD_POOL_SIZE: int = 4

# 3D world-sound falloff presets, selected via set_world_audio_range.
#
# LIVE — live play frames the puck closely (game cam ~15 m up), so the tight
#   defaults keep events spatial without bleeding across the rink.
# REPLAY_FAR — replay cameras parked far from the action: the offline viewer's
#   broadcast/chase/free cams and the goal replay's press-box hard cam sit
#   ~19–38 m from the puck, where the LIVE falloff attenuates recorded events
#   to near-silence (far-side events hit the 40 m cutoff entirely). Widen the
#   curve so the cinematic distance stays audible while keeping stereo cues.
# REPLAY_NEAR — the goal replay's behind-the-net cam (~4.5–10 m from the puck).
#   Already in the audible regime, so only a gentle lift: REPLAY_FAR's wide
#   curve would over-amplify (the close cam would be +13 dB and blow out the
#   money shot), while LIVE leaves it flat.
enum AudioRange { LIVE, REPLAY_NEAR, REPLAY_FAR }

const _WORLD_UNIT_SIZE: float = 6.0
const _WORLD_MAX_DISTANCE: float = 40.0
const _REPLAY_FAR_UNIT_SIZE: float = 20.0
const _REPLAY_FAR_MAX_DISTANCE: float = 80.0
const _REPLAY_NEAR_UNIT_SIZE: float = 10.0
const _REPLAY_NEAR_MAX_DISTANCE: float = 60.0

var _streams: Dictionary = {}
var _pool_ui: Array[AudioStreamPlayer] = []      # UI bus — hover, click
var _pool_sfx_2d: Array[AudioStreamPlayer] = []  # SFX bus — non-spatial gameplay cues
var _pool_3d: Array[AudioStreamPlayer3D] = []    # SFX bus — all world sounds
var _pool_crowd: Array[AudioStreamPlayer] = []   # Crowd bus — horn, buzzer, whistle


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
	for i: int in _CROWD_POOL_SIZE:
		var p := AudioStreamPlayer.new()
		p.bus = "Crowd"
		add_child(p)
		_pool_crowd.append(p)


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


# Non-spatial arena venue one-shots (goal horn, period buzzer, faceoff whistle)
# on the dedicated Crowd bus, so the Crowd volume slider controls all crowd/
# arena atmosphere together rather than mixing these into gameplay SFX.
func play_crowd(sound: Sound, volume_db: float = 0.0, pitch_variance: float = 0.0) -> void:
	var stream: AudioStream = _streams.get(sound)
	if stream == null:
		return
	for p: AudioStreamPlayer in _pool_crowd:
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


# Select the 3D world-sound falloff to match the active camera distance. Replay
# cameras sit far from the action, where the LIVE falloff attenuates recorded
# events to silence; the REPLAY_* presets lift the level while keeping
# stereo/positional cues. Call REPLAY_FAR/NEAR on the matching camera, LIVE to
# restore. Idempotent.
func set_world_audio_range(audio_range: AudioRange) -> void:
	var unit_size: float
	var max_distance: float
	match audio_range:
		AudioRange.REPLAY_FAR:
			unit_size = _REPLAY_FAR_UNIT_SIZE
			max_distance = _REPLAY_FAR_MAX_DISTANCE
		AudioRange.REPLAY_NEAR:
			unit_size = _REPLAY_NEAR_UNIT_SIZE
			max_distance = _REPLAY_NEAR_MAX_DISTANCE
		_:
			unit_size = _WORLD_UNIT_SIZE
			max_distance = _WORLD_MAX_DISTANCE
	for p: AudioStreamPlayer3D in _pool_3d:
		p.unit_size = unit_size
		p.max_distance = max_distance


# Connects hover and click sounds to a button. Call after creating each Button node.
func wire_button(button: Button) -> void:
	button.mouse_entered.connect(func() -> void: play_ui(Sound.UI_HOVER))
	button.pressed.connect(func() -> void: play_ui(Sound.UI_CLICK))
