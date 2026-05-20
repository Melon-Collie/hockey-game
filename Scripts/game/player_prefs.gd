extends Node

const SAVE_PATH: String = "user://preferences.cfg"
const RESOLUTIONS: Array[Vector2i] = [
	Vector2i(1280, 720),
	Vector2i(1920, 1080),
	Vector2i(2560, 1440),
]
const FPS_CAP_VALUES: Array[int] = [30, 60, 120, 144, 240, 0]

# Camera style: which camera implementation runs.
#   CLASSIC  — the original midpoint-anchor camera with possession-aware zone
#              bias, goal/hit shake, and the three projection modes via
#              `camera_mode`.
#   MODERN   — the cursor-driven anchor + ozone-bias rewrite. Reads
#              `tilt_angle` instead of `camera_mode`.
# LocalController.setup() swaps the Camera3D's script based on this.
const CAMERA_STYLE_MODERN: int = 0
const CAMERA_STYLE_CLASSIC: int = 1
const CAMERA_STYLE_LABELS: Array[String] = [
	"Modern (Cursor-driven)",
	"Classic (Midpoint)",
]

# Camera projection modes (used by CLASSIC style only). Index matches
# OptionButton ordering in OptionsPanel.
const CAMERA_MODE_ORTHOGRAPHIC: int = 0
const CAMERA_MODE_TOP_DOWN: int = 1   # perspective, looking straight down (the original)
const CAMERA_MODE_TILTED: int = 2     # perspective, pitched 15° forward of straight down
const CAMERA_MODE_LABELS: Array[String] = [
	"Top-Down (Orthographic)",
	"Top-Down (Perspective)",
	"Tilted (Perspective)",
]

# Color-grade presets baked into the runtime 3D LUT alongside the gamma curve.
# Index matches OptionButton ordering in OptionsPanel.
const COLOR_GRADE_NEUTRAL: int = 0
const COLOR_GRADE_BROADCAST: int = 1  # teal-shadow / warm-mid / neutral-highlight split + mild S-curve
const COLOR_GRADE_LABELS: Array[String] = [
	"None",
	"Broadcast",
]

# Global illumination quality. SDFGI gives bouncier indirect light at a
# ~20% perf cost; off matches the cheaper baseline. Index matches the
# OptionsPanel dropdown.
const GI_MODE_OFF: int = 0
const GI_MODE_SDFGI: int = 1
const GI_MODE_LABELS: Array[String] = [
	"Off",
	"SDFGI",
]

# Spectator bowl density. Off hides the stands entirely; Low / High set the
# terrace row count on ArenaStands.
const CROWD_DENSITY_OFF: int = 0
const CROWD_DENSITY_LOW: int = 1
const CROWD_DENSITY_HIGH: int = 2
const CROWD_DENSITY_LABELS: Array[String] = [
	"Off",
	"Low",
	"High",
]
const CROWD_DENSITY_LOW_TERRACES: int = 5
const CROWD_DENSITY_HIGH_TERRACES: int = 15

# 3D render scale. Lowers the internal rendertarget resolution and upscales
# back to window size. Bilinear is cheap and blurry; FSR/FSR2 reconstruct
# sharper edges at progressively higher GPU cost. Constants match
# Viewport.Scaling3DMode so the value is passed through directly.
const SCALING_3D_BILINEAR: int = 0
const SCALING_3D_FSR: int = 1
const SCALING_3D_FSR2: int = 2
const SCALING_3D_LABELS: Array[String] = [
	"Bilinear",
	"FSR",
	"FSR2",
]
const RENDER_SCALE_MIN: float = 0.5
const RENDER_SCALE_MAX: float = 1.0
const RENDER_SCALE_STEP: float = 0.05

# Anti-aliasing mode. One dropdown that drives three viewport properties
# (msaa_3d, screen_space_aa, use_taa) — the apply step picks the right
# combination per mode. Default is MSAA 2x, matching the project.godot
# baseline.
const AA_OFF: int = 0
const AA_FXAA: int = 1
const AA_MSAA_2X: int = 2
const AA_MSAA_4X: int = 3
const AA_MSAA_8X: int = 4
const AA_TAA: int = 5
const AA_LABELS: Array[String] = [
	"Off",
	"FXAA",
	"MSAA 2x",
	"MSAA 4x",
	"MSAA 8x",
	"TAA",
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
var preferred_color_slot: int = -1  # team color preset slot index; -1 → use team default at lobby join
var last_ip: String = ""
var master_volume: float = 1.0
var sfx_volume: float = 1.0
var ui_volume: float = 1.0
var crowd_volume: float = 1.0
var master_muted: bool = false
var is_fullscreen: bool = false
var resolution_index: int = 1
var vsync_enabled: bool = true
var fps_cap_index: int = 5
var show_fps: bool = false
var gamma: float = 1.0
var color_grade_preset: int = COLOR_GRADE_BROADCAST
var gi_mode: int = GI_MODE_OFF
var crowd_density: int = CROWD_DENSITY_HIGH
var ice_scratches_enabled: bool = true
var scaling_3d_mode: int = SCALING_3D_BILINEAR
var render_scale: float = 1.0
var anti_aliasing_mode: int = AA_MSAA_2X
var mouse_sensitivity: float = 1.0
var attack_up: bool = true
var camera_style: int = CAMERA_STYLE_MODERN
var camera_mode: int = CAMERA_MODE_TOP_DOWN  # used by CLASSIC style only
var fov: float = 50.0  # GameCamera writes this to its Camera3D.fov each tick
var camera_distance: float = 1.0  # multiplier on min/ozone/max camera heights
# Tilt angle from horizontal, in degrees (MODERN style only). 90 = straight
# down, smaller = more tilted. Ignored by CLASSIC, which uses camera_mode.
var tilt_angle: float = 75.0
const FOV_MIN: float = 40.0
const FOV_MAX: float = 90.0
const CAMERA_DISTANCE_MIN: float = 0.6
const CAMERA_DISTANCE_MAX: float = 1.6
const TILT_ANGLE_MIN: float = 70.0
const TILT_ANGLE_MAX: float = 90.0
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
	cfg.set_value("player", "preferred_color_slot", preferred_color_slot)
	cfg.set_value("player", "last_ip", last_ip)
	cfg.set_value("audio", "master_volume", master_volume)
	cfg.set_value("audio", "sfx_volume", sfx_volume)
	cfg.set_value("audio", "ui_volume", ui_volume)
	cfg.set_value("audio", "crowd_volume", crowd_volume)
	cfg.set_value("audio", "master_muted", master_muted)
	cfg.set_value("video", "fullscreen", is_fullscreen)
	cfg.set_value("video", "resolution_index", resolution_index)
	cfg.set_value("video", "vsync_enabled", vsync_enabled)
	cfg.set_value("video", "fps_cap_index", fps_cap_index)
	cfg.set_value("video", "show_fps", show_fps)
	cfg.set_value("video", "gamma", gamma)
	cfg.set_value("video", "color_grade_preset", color_grade_preset)
	cfg.set_value("video", "gi_mode", gi_mode)
	cfg.set_value("video", "crowd_density", crowd_density)
	cfg.set_value("video", "ice_scratches_enabled", ice_scratches_enabled)
	cfg.set_value("video", "scaling_3d_mode", scaling_3d_mode)
	cfg.set_value("video", "render_scale", render_scale)
	cfg.set_value("video", "anti_aliasing_mode", anti_aliasing_mode)
	cfg.set_value("input", "mouse_sensitivity", mouse_sensitivity)
	cfg.set_value("game", "attack_up", attack_up)
	cfg.set_value("game", "camera_style", camera_style)
	cfg.set_value("game", "camera_mode", camera_mode)
	cfg.set_value("game", "fov", fov)
	cfg.set_value("game", "camera_distance", camera_distance)
	cfg.set_value("game", "tilt_angle", tilt_angle)
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
	var crowd_bus := AudioServer.get_bus_index("Crowd")
	if crowd_bus != -1:
		AudioServer.set_bus_volume_db(crowd_bus, linear_to_db(maxf(crowd_volume, 0.0001)))

func apply_video() -> void:
	if is_fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_size(RESOLUTIONS[resolution_index])
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if vsync_enabled else DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = FPS_CAP_VALUES[fps_cap_index]
	var root: Window = get_tree().root
	root.scaling_3d_mode = scaling_3d_mode as Viewport.Scaling3DMode
	root.scaling_3d_scale = render_scale
	_apply_anti_aliasing(root)
	var scene: Node = Engine.get_main_loop().current_scene
	if scene == null:
		return
	var we := scene.find_child("WorldEnvironment", true, false) as WorldEnvironment
	if we != null:
		we.environment.adjustment_enabled = true
		we.environment.adjustment_color_correction = _build_color_correction_lut(gamma, color_grade_preset)
		we.environment.sdfgi_enabled = (gi_mode == GI_MODE_SDFGI)
	var stands := scene.find_child("ArenaStands", true, false) as Node3D
	if stands != null:
		stands.visible = (crowd_density != CROWD_DENSITY_OFF)
		if crowd_density != CROWD_DENSITY_OFF and "num_terraces" in stands:
			var terraces: int = CROWD_DENSITY_HIGH_TERRACES \
				if crowd_density == CROWD_DENSITY_HIGH \
				else CROWD_DENSITY_LOW_TERRACES
			stands.set("num_terraces", terraces)
	var scratch := scene.find_child("IceScratchMap", true, false)
	if scratch != null and scratch.has_method("set_enabled"):
		scratch.call("set_enabled", ice_scratches_enabled)

func _apply_anti_aliasing(root: Viewport) -> void:
	# MSAA, FXAA, and TAA are mutually exclusive in the dropdown — the
	# helper sets all three viewport props per row so switching modes
	# always lands in a clean state.
	root.msaa_3d = Viewport.MSAA_DISABLED
	root.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	root.use_taa = false
	# FSR2 has its own temporal reconstruction and Godot rejects TAA on top
	# of it (renderer_viewport.cpp:210). Mirror that check here so we don't
	# emit the engine warning every Apply when the user has picked the
	# incompatible combo — FSR2's reconstruction already provides
	# TAA-equivalent sub-pixel AA.
	var fsr2_active: bool = scaling_3d_mode == SCALING_3D_FSR2
	match anti_aliasing_mode:
		AA_FXAA:
			root.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
		AA_MSAA_2X:
			root.msaa_3d = Viewport.MSAA_2X
		AA_MSAA_4X:
			root.msaa_3d = Viewport.MSAA_4X
		AA_MSAA_8X:
			root.msaa_3d = Viewport.MSAA_8X
		AA_TAA:
			if not fsr2_active:
				root.use_taa = true

# Builds a 16³ 3D LUT that applies the selected color-grade preset then the
# gamma curve (output = input^(1/gamma)). Both bake into a single texture so
# they share Environment.adjustment_color_correction — Godot only exposes one
# slot. Rebuild cost is ~4K voxels * a few ops; only runs at apply time.
func _build_color_correction_lut(g: float, preset: int) -> Texture3D:
	const N: int = 16
	var images: Array[Image] = []
	var inv_g: float = 1.0 / maxf(g, 0.01)
	for b: int in N:
		var img := Image.create(N, N, false, Image.FORMAT_RGBA8)
		var bb: float = float(b) / float(N - 1)
		for y: int in N:
			var gg: float = float(y) / float(N - 1)
			for x: int in N:
				var r: float = float(x) / float(N - 1)
				var c := Color(r, gg, bb)
				match preset:
					COLOR_GRADE_BROADCAST:
						c = _apply_grade_broadcast(c)
				c.r = pow(maxf(c.r, 0.0), inv_g)
				c.g = pow(maxf(c.g, 0.0), inv_g)
				c.b = pow(maxf(c.b, 0.0), inv_g)
				img.set_pixel(x, y, c)
		images.append(img)
	var tex := ImageTexture3D.new()
	tex.create(Image.FORMAT_RGBA8, N, N, N, false, images)
	return tex

# Modern sports-broadcast split-tone: teal cast in shadows, neutral midtones
# and highlights. Real broadcast ice samples cool-neutral at midtone+ luma —
# warmth in reference frames comes from content (team colors, crowd jerseys),
# not from the grade. Mild S-curve and slight desat finish the Rec.709 feel.
func _apply_grade_broadcast(c: Color) -> Color:
	var luma: float = c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722
	var shadow_w: float = 1.0 - smoothstep(0.0, 0.40, luma)
	# Shadow teal: pull R down, push B up. Only the shadow band picks up a
	# tint; mids and highlights are left alone so the ice stays cool-neutral.
	const SHADOW_R: float = -0.025
	const SHADOW_B: float =  0.030
	c.r = clampf(c.r + SHADOW_R * shadow_w, 0.0, 1.0)
	c.b = clampf(c.b + SHADOW_B * shadow_w, 0.0, 1.0)
	# Mild S-curve: half-blend of smoothstep keeps detail in both ends.
	c.r = lerp(c.r, smoothstep(0.0, 1.0, c.r), 0.5)
	c.g = lerp(c.g, smoothstep(0.0, 1.0, c.g), 0.5)
	c.b = lerp(c.b, smoothstep(0.0, 1.0, c.b), 0.5)
	luma = c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722
	const SAT: float = 0.96
	c.r = clampf(luma + (c.r - luma) * SAT, 0.0, 1.0)
	c.g = clampf(luma + (c.g - luma) * SAT, 0.0, 1.0)
	c.b = clampf(luma + (c.b - luma) * SAT, 0.0, 1.0)
	return c

func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(_get_save_path()) == OK:
		player_uuid = cfg.get_value("identity", "player_uuid", "")
		steam_id_linked = cfg.get_value("identity", "steam_id_linked", false)
		player_name = cfg.get_value("player", "name", "Player").substr(0, 10)
		jersey_number = clamp(cfg.get_value("player", "jersey_number", 10), 0, 99)
		is_left_handed = cfg.get_value("player", "left_handed", true)
		# Reads as int; any legacy fruit-name string under the old "preferred_color_id"
		# key is ignored — hard break, no migration. -1 falls back to the default at
		# next lobby join.
		preferred_color_slot = int(cfg.get_value("player", "preferred_color_slot", -1))
		last_ip = cfg.get_value("player", "last_ip", "")
		master_volume = clampf(cfg.get_value("audio", "master_volume", 1.0), 0.0, 1.0)
		sfx_volume = clampf(cfg.get_value("audio", "sfx_volume", 1.0), 0.0, 1.0)
		ui_volume = clampf(cfg.get_value("audio", "ui_volume", 1.0), 0.0, 1.0)
		crowd_volume = clampf(cfg.get_value("audio", "crowd_volume", 1.0), 0.0, 1.0)
		master_muted = cfg.get_value("audio", "master_muted", false)
		is_fullscreen = cfg.get_value("video", "fullscreen", false)
		resolution_index = clamp(cfg.get_value("video", "resolution_index", 1), 0, RESOLUTIONS.size() - 1)
		vsync_enabled = cfg.get_value("video", "vsync_enabled", true)
		fps_cap_index = clamp(cfg.get_value("video", "fps_cap_index", 5), 0, FPS_CAP_VALUES.size() - 1)
		show_fps = cfg.get_value("video", "show_fps", false)
		gamma = clampf(cfg.get_value("video", "gamma", 1.0), 0.5, 2.0)
		color_grade_preset = clamp(cfg.get_value("video", "color_grade_preset", COLOR_GRADE_NEUTRAL), 0, COLOR_GRADE_LABELS.size() - 1)
		gi_mode = clamp(cfg.get_value("video", "gi_mode", GI_MODE_OFF), 0, GI_MODE_LABELS.size() - 1)
		crowd_density = clamp(cfg.get_value("video", "crowd_density", CROWD_DENSITY_HIGH), 0, CROWD_DENSITY_LABELS.size() - 1)
		ice_scratches_enabled = cfg.get_value("video", "ice_scratches_enabled", true)
		scaling_3d_mode = clamp(cfg.get_value("video", "scaling_3d_mode", SCALING_3D_BILINEAR), 0, SCALING_3D_LABELS.size() - 1)
		render_scale = clampf(cfg.get_value("video", "render_scale", 1.0), RENDER_SCALE_MIN, RENDER_SCALE_MAX)
		anti_aliasing_mode = clamp(cfg.get_value("video", "anti_aliasing_mode", AA_MSAA_2X), 0, AA_LABELS.size() - 1)
		mouse_sensitivity = clampf(cfg.get_value("input", "mouse_sensitivity", 1.0), 0.5, 3.0)
		attack_up = cfg.get_value("game", "attack_up", true)
		camera_style = clamp(cfg.get_value("game", "camera_style", CAMERA_STYLE_MODERN), 0, CAMERA_STYLE_LABELS.size() - 1)
		camera_mode = clamp(cfg.get_value("game", "camera_mode", CAMERA_MODE_TOP_DOWN), 0, CAMERA_MODE_LABELS.size() - 1)
		fov = clampf(cfg.get_value("game", "fov", 50.0), FOV_MIN, FOV_MAX)
		camera_distance = clampf(cfg.get_value("game", "camera_distance", 1.0), CAMERA_DISTANCE_MIN, CAMERA_DISTANCE_MAX)
		tilt_angle = clampf(cfg.get_value("game", "tilt_angle", 75.0), TILT_ANGLE_MIN, TILT_ANGLE_MAX)
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
