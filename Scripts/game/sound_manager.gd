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

# ONE inverse-distance falloff for every world sound, at every camera, in every
# mode — the same curve `SkaterSoundController` gives the skate loops. Two dials,
# and neither is per-camera:
#
# Unit size is where the curve is anchored, and it is anchored on the LIVE camera
# because that is the shot the game is played in: the game cam frames the puck
# from ~15 m up, so events land around -8 dB — present and clearly placed, without
# bleeding across the rink.
#
# NO distance cutoff (Godot reads 0.0 as unlimited). The rink is 60 x 26 m and the
# camera pulls back off it, so listener-to-event distances past 40 m are ordinary
# rather than exceptional — a cutoff there silenced far-side play outright instead
# of merely quieting it. Unbounded, the curve keeps falling on its own (about
# -17 dB at 40 m, -21 dB at 65 m), which is the "audible but clearly over there"
# the cutoff was destroying.
#
# The cutoff is also why this used to be three presets a camera switched between:
# with a 40 m wall in the way, the replay cams — parked 4.5-38 m out — needed
# their own wider curves to reach past it at all. Take the wall away and the
# widening has nothing left to do, and a level that changes when the direction
# stays put is its own inconsistency. Replay is quieter than it was on the old
# REPLAY_FAR preset by design: it is the distance, not a mode.
const WORLD_UNIT_SIZE: float = 6.0
const NO_DISTANCE_CUTOFF: float = 0.0

var _streams: Dictionary = {}
var _pool_ui: Array[AudioStreamPlayer] = []      # UI bus — hover, click
var _pool_sfx_2d: Array[AudioStreamPlayer] = []  # SFX bus — non-spatial gameplay cues
var _pool_3d: Array[AudioStreamPlayer3D] = []    # SFX bus — all world sounds
var _pool_crowd: Array[AudioStreamPlayer] = []   # Arena bus — horn, buzzer, whistle


func _ready() -> void:
	_ensure_buses()
	# PlayerPrefs._ready() runs first (autoload order), so saved volumes were
	# applied against buses that didn't exist yet. Re-apply now that SFX / UI /
	# Crowd exist so startup volumes match the slider state.
	PlayerPrefs.apply_audio()
	_load_streams()
	_build_pools()


func _ensure_buses() -> void:
	for bus_name: String in ["SFX", "UI", "Arena"]:
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
		p.max_distance = NO_DISTANCE_CUTOFF
		p.unit_size = WORLD_UNIT_SIZE
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		add_child(p)
		_pool_3d.append(p)
	for i: int in _CROWD_POOL_SIZE:
		var p := AudioStreamPlayer.new()
		p.bus = "Arena"
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


# Connects hover and click sounds to a button. Call after creating each Button node.
func wire_button(button: Button) -> void:
	button.mouse_entered.connect(func() -> void: play_ui(Sound.UI_HOVER))
	button.pressed.connect(func() -> void: play_ui(Sound.UI_CLICK))
