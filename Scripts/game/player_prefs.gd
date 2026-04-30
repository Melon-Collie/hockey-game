extends Node

const SAVE_PATH: String = "user://preferences.cfg"
const RESOLUTIONS: Array[Vector2i] = [
	Vector2i(1280, 720),
	Vector2i(1920, 1080),
	Vector2i(2560, 1440),
]
const FPS_CAP_VALUES: Array[int] = [30, 60, 120, 144, 240, 0]

# Camera projection modes. Index matches OptionButton ordering in
# OptionsPanel; GameCamera reads camera_mode each tick to flip projection
# and pitch.
const CAMERA_MODE_ORTHOGRAPHIC: int = 0
const CAMERA_MODE_TOP_DOWN: int = 1   # perspective, looking straight down (the original)
const CAMERA_MODE_TILTED: int = 2     # perspective, pitched 15° forward of straight down
const CAMERA_MODE_LABELS: Array[String] = [
	"Top-Down (Orthographic)",
	"Top-Down (Perspective)",
	"Tilted (Perspective)",
]
const REBINDABLE_ACTIONS: PackedStringArray = [
	"move_up", "move_down", "move_left", "move_right", "brake",
	"shoot", "slapshot", "block", "elevation_up", "elevation_down",
]

var player_uuid: String = ""
var steam_id_linked: bool = false

var player_name: String = "Player"
var jersey_number: int = 10
var is_left_handed: bool = true
var preferred_color_id: String = ""  # team color preset id; "" → use team default at lobby join
var last_ip: String = ""
var master_volume: float = 1.0
var sfx_volume: float = 1.0
var ui_volume: float = 1.0
var master_muted: bool = false
var is_fullscreen: bool = false
var resolution_index: int = 1
var vsync_enabled: bool = true
var fps_cap_index: int = 5
var brightness: float = 1.0
var mouse_sensitivity: float = 1.0
var attack_up: bool = false
var camera_mode: int = CAMERA_MODE_TOP_DOWN
var fov: float = 75.0  # GameCamera writes this to its Camera3D.fov each tick
var camera_distance: float = 1.0  # multiplier on min/ozone/max camera heights
const FOV_MIN: float = 40.0
const FOV_MAX: float = 90.0
const CAMERA_DISTANCE_MIN: float = 0.6
const CAMERA_DISTANCE_MAX: float = 1.6
var bindings: Dictionary = {}  # action -> {type, physical_keycode or button_index}

# Replay recording. Recording fires on every peer (host + clients) for every
# multiplayer game; offline / tutorial sessions never record. ReplayFileIndex
# purges oldest replays in user://replays/ down to keep_count at writer-open
# time so the on-disk footprint stays bounded.
var replay_recording_enabled: bool = true
var replay_keep_count: int = 20
const REPLAY_KEEP_MIN: int = 1
const REPLAY_KEEP_MAX: int = 100

func _get_save_path() -> String:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--config-suffix="):
			return "user://preferences_%s.cfg" % arg.substr(16)
	return SAVE_PATH

func _ready() -> void:
	_load()
	if player_uuid.is_empty():
		player_uuid = generate_uuid()
		save()

func save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("identity", "player_uuid", player_uuid)
	cfg.set_value("identity", "steam_id_linked", steam_id_linked)
	cfg.set_value("player", "name", player_name)
	cfg.set_value("player", "jersey_number", jersey_number)
	cfg.set_value("player", "left_handed", is_left_handed)
	cfg.set_value("player", "preferred_color_id", preferred_color_id)
	cfg.set_value("player", "last_ip", last_ip)
	cfg.set_value("audio", "master_volume", master_volume)
	cfg.set_value("audio", "sfx_volume", sfx_volume)
	cfg.set_value("audio", "ui_volume", ui_volume)
	cfg.set_value("audio", "master_muted", master_muted)
	cfg.set_value("video", "fullscreen", is_fullscreen)
	cfg.set_value("video", "resolution_index", resolution_index)
	cfg.set_value("video", "vsync_enabled", vsync_enabled)
	cfg.set_value("video", "fps_cap_index", fps_cap_index)
	cfg.set_value("video", "brightness", brightness)
	cfg.set_value("input", "mouse_sensitivity", mouse_sensitivity)
	cfg.set_value("game", "attack_up", attack_up)
	cfg.set_value("game", "camera_mode", camera_mode)
	cfg.set_value("game", "fov", fov)
	cfg.set_value("game", "camera_distance", camera_distance)
	cfg.set_value("replay", "recording_enabled", replay_recording_enabled)
	cfg.set_value("replay", "keep_count", replay_keep_count)
	for action: String in REBINDABLE_ACTIONS:
		if not bindings.has(action):
			continue
		var b: Dictionary = bindings[action]
		var t: String = b.get("type", "")
		cfg.set_value("bindings", action + "_type", t)
		if t == "key":
			cfg.set_value("bindings", action + "_code", b.get("physical_keycode", 0))
		elif t == "mouse":
			cfg.set_value("bindings", action + "_code", b.get("button_index", 0))
	cfg.save(_get_save_path())

func apply_bindings() -> void:
	for action: String in bindings:
		if not InputMap.has_action(action):
			continue
		InputMap.action_erase_events(action)
		var b: Dictionary = bindings[action]
		if b.get("type") == "key":
			var ev := InputEventKey.new()
			ev.physical_keycode = b.physical_keycode as Key
			InputMap.action_add_event(action, ev)
		elif b.get("type") == "mouse":
			var ev := InputEventMouseButton.new()
			ev.button_index = b.button_index as MouseButton
			InputMap.action_add_event(action, ev)

func _read_current_input_event(action: String) -> Dictionary:
	if not InputMap.has_action(action):
		return {}
	for ev: InputEvent in InputMap.action_get_events(action):
		if ev is InputEventKey:
			return {"type": "key", "physical_keycode": int((ev as InputEventKey).physical_keycode)}
		elif ev is InputEventMouseButton:
			return {"type": "mouse", "button_index": int((ev as InputEventMouseButton).button_index)}
	return {}

func apply_audio() -> void:
	var master_bus := AudioServer.get_bus_index("Master")
	AudioServer.set_bus_volume_db(master_bus, linear_to_db(maxf(master_volume, 0.0001)))
	AudioServer.set_bus_mute(master_bus, master_muted)
	var sfx_bus := AudioServer.get_bus_index("SFX")
	if sfx_bus != -1:
		AudioServer.set_bus_volume_db(sfx_bus, linear_to_db(maxf(sfx_volume, 0.0001)))
	var ui_bus := AudioServer.get_bus_index("UI")
	if ui_bus != -1:
		AudioServer.set_bus_volume_db(ui_bus, linear_to_db(maxf(ui_volume, 0.0001)))

func apply_video() -> void:
	if is_fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_size(RESOLUTIONS[resolution_index])
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if vsync_enabled else DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = FPS_CAP_VALUES[fps_cap_index]
	var we := Engine.get_main_loop().current_scene.find_child(
		"WorldEnvironment", true, false) as WorldEnvironment
	if we != null:
		we.environment.adjustment_enabled = true
		we.environment.adjustment_brightness = brightness

func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(_get_save_path()) == OK:
		player_uuid = cfg.get_value("identity", "player_uuid", "")
		steam_id_linked = cfg.get_value("identity", "steam_id_linked", false)
		player_name = cfg.get_value("player", "name", "Player").substr(0, 10)
		jersey_number = clamp(cfg.get_value("player", "jersey_number", 10), 0, 99)
		is_left_handed = cfg.get_value("player", "left_handed", true)
		preferred_color_id = cfg.get_value("player", "preferred_color_id", "")
		last_ip = cfg.get_value("player", "last_ip", "")
		master_volume = clampf(cfg.get_value("audio", "master_volume", 1.0), 0.0, 1.0)
		sfx_volume = clampf(cfg.get_value("audio", "sfx_volume", 1.0), 0.0, 1.0)
		ui_volume = clampf(cfg.get_value("audio", "ui_volume", 1.0), 0.0, 1.0)
		master_muted = cfg.get_value("audio", "master_muted", false)
		is_fullscreen = cfg.get_value("video", "fullscreen", false)
		resolution_index = clamp(cfg.get_value("video", "resolution_index", 1), 0, RESOLUTIONS.size() - 1)
		vsync_enabled = cfg.get_value("video", "vsync_enabled", true)
		fps_cap_index = clamp(cfg.get_value("video", "fps_cap_index", 5), 0, FPS_CAP_VALUES.size() - 1)
		brightness = clampf(cfg.get_value("video", "brightness", 1.0), 0.5, 1.5)
		mouse_sensitivity = clampf(cfg.get_value("input", "mouse_sensitivity", 1.0), 0.5, 3.0)
		attack_up = cfg.get_value("game", "attack_up", false)
		camera_mode = clamp(cfg.get_value("game", "camera_mode", CAMERA_MODE_TOP_DOWN), 0, CAMERA_MODE_LABELS.size() - 1)
		fov = clampf(cfg.get_value("game", "fov", 75.0), FOV_MIN, FOV_MAX)
		camera_distance = clampf(cfg.get_value("game", "camera_distance", 1.0), CAMERA_DISTANCE_MIN, CAMERA_DISTANCE_MAX)
		replay_recording_enabled = cfg.get_value("replay", "recording_enabled", true)
		replay_keep_count = clampi(cfg.get_value("replay", "keep_count", 20), REPLAY_KEEP_MIN, REPLAY_KEEP_MAX)
		for action: String in REBINDABLE_ACTIONS:
			var t: String = cfg.get_value("bindings", action + "_type", "")
			if t == "key":
				bindings[action] = {"type": "key", "physical_keycode": cfg.get_value("bindings", action + "_code", 0)}
			elif t == "mouse":
				bindings[action] = {"type": "mouse", "button_index": cfg.get_value("bindings", action + "_code", 0)}
	# Fill in InputMap defaults for any action not in the saved config
	for action: String in REBINDABLE_ACTIONS:
		if not bindings.has(action):
			var b: Dictionary = _read_current_input_event(action)
			if not b.is_empty():
				bindings[action] = b
	apply_audio()
	apply_bindings()
	call_deferred(&"apply_video")


func generate_uuid() -> String:
	const HEX: String = "0123456789abcdef"
	var result: String = ""
	for i: int in 32:
		if i == 8 or i == 12 or i == 16 or i == 20:
			result += "-"
		if i == 12:
			result += "4"
		elif i == 16:
			result += HEX[(randi() % 4) + 8]
		else:
			result += HEX[randi() % 16]
	return result
