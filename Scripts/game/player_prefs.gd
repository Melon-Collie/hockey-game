extends Node

const SAVE_PATH: String = "user://preferences.cfg"
const RESOLUTIONS: Array[Vector2i] = [
	Vector2i(1280, 720),
	Vector2i(1920, 1080),
	Vector2i(2560, 1440),
]
const FPS_CAP_VALUES: Array[int] = [30, 60, 120, 144, 240, 0]

# Camera tilt. The game uses a single tilted-perspective camera; the only
# user-facing camera adjustment is a small tilt nudge around the default.
# GameCamera reads camera_tilt_deg each tick to drive pitch and the off-axis
# follow offset. Kept subtle by design — much steeper and the mouse-to-world
# projection becomes nonlinear enough to break stickhandling, so the slider is
# clamped to a tight band around the default.
const CAMERA_TILT_DEFAULT: float = 75.0
const CAMERA_TILT_MIN: float = 73.0
const CAMERA_TILT_MAX: float = 77.0

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

# Per-player attribute levels (1 = bad, 2 = medium, 3 = good). Default to
# medium across the board so a fresh install plays identically to the
# pre-attributes baseline.
var attr_speed:   int = PlayerAttributes.LEVEL_MEDIUM
var attr_agility: int = PlayerAttributes.LEVEL_MEDIUM
var attr_size:    int = PlayerAttributes.LEVEL_MEDIUM
var attr_strength:    int = PlayerAttributes.LEVEL_MEDIUM
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
# First-run onboarding: false until the player opens the player-settings popup
# for the first time. Drives the one-time "edit your player here" callout on
# the SideMenu player card.
var has_opened_player_settings: bool = false
# Confine the OS cursor to the window so fast cursor flicks (aiming the blade)
# can't slide off-screen onto a second monitor. On by default; applied via
# apply_input() at load and on settings Apply. See free_camera.gd for the one
# place that temporarily overrides mouse_mode (spectator look).
var confine_mouse: bool = true
# Custom in-game cursor. The OS white pointer blends into the ice, so we draw a
# procedural high-contrast (dark-outlined) cursor and set it via
# Input.set_custom_mouse_cursor in apply_cursor(). Only the default arrow shape
# is replaced — UI controls that request a pointing hand still get the system
# one. Tunable in Options → Input → Cursor.
const CURSOR_STYLE_DOT: int = 0
const CURSOR_STYLE_CROSSHAIR: int = 1
const CURSOR_STYLE_RING: int = 2
const CURSOR_STYLE_LABELS: Array[String] = ["Dot", "Crosshair", "Ring"]
const CURSOR_SIZE_MIN: int = 16
const CURSOR_SIZE_MAX: int = 48
var cursor_style: int = CURSOR_STYLE_DOT
var cursor_color: Color = Color(1.0, 0.45, 0.1)  # high-contrast orange on white ice
var cursor_size: int = 28
var attack_up: bool = false
# Accessibility: swap the on-ice self/team/enemy ring colors for a
# colorblind-safe palette (SkaterHUDCoordinator reads this live).
var colorblind_rings: bool = false
var camera_tilt_deg: float = CAMERA_TILT_DEFAULT  # GameCamera reads this each tick for pitch
var fov: float = 50.0  # GameCamera writes this to its Camera3D.fov each tick
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

# Tutorial completion is stored as a single Dictionary keyed by tutorial id
# ("basics", "advanced", future drill ids) so adding new tutorials never
# requires a schema change. Value is currently a bool; can grow to a small
# per-tutorial dict (timestamps, highest step reached) without migration —
# _load() defensive-casts whatever ConfigFile returns.
var tutorial_completion: Dictionary = {}

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
	cfg.set_value("player", "attr_speed",   attr_speed)
	cfg.set_value("player", "attr_agility", attr_agility)
	cfg.set_value("player", "attr_size",    attr_size)
	cfg.set_value("player", "attr_strength",    attr_strength)
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
	cfg.set_value("input", "confine_mouse", confine_mouse)
	cfg.set_value("input", "cursor_style", cursor_style)
	cfg.set_value("input", "cursor_color", cursor_color)
	cfg.set_value("input", "cursor_size", cursor_size)
	cfg.set_value("game", "attack_up", attack_up)
	cfg.set_value("game", "has_opened_player_settings", has_opened_player_settings)
	cfg.set_value("game", "colorblind_rings", colorblind_rings)
	cfg.set_value("game", "camera_tilt_deg", camera_tilt_deg)
	cfg.set_value("game", "fov", fov)
	cfg.set_value("game", "camera_distance", camera_distance)
	cfg.set_value("replay", "recording_enabled", replay_recording_enabled)
	cfg.set_value("replay", "keep_count", replay_keep_count)
	cfg.set_value("tutorials", "completion", tutorial_completion)
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

func apply_input() -> void:
	# CONFINED keeps the cursor visible (the blade is aimed by the on-screen
	# cursor) but clamps it to the window rect. When off, restore the normal
	# free-roaming visible cursor. This is also the canonical "un-capture"
	# target: free_camera calls it when leaving spectator look so it lands in
	# the configured state rather than forcing VISIBLE.
	Input.mouse_mode = Input.MOUSE_MODE_CONFINED if confine_mouse else Input.MOUSE_MODE_VISIBLE

# Renders the configured cursor to a small RGBA image and installs it as the
# default-arrow cursor. Called deferred at load and on settings Apply. Hotspot
# is the image centre so the aim point sits under the geometry centre.
func apply_cursor() -> void:
	var s: int = clampi(cursor_size, CURSOR_SIZE_MIN, CURSOR_SIZE_MAX)
	var img: Image = Image.create(s, s, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	var fill: Color = cursor_color
	var outline := Color(0.0, 0.0, 0.0, 0.9)  # dark halo for contrast on white ice
	var c: float = (s - 1) * 0.5
	var r: float = c
	match cursor_style:
		CURSOR_STYLE_DOT:
			_draw_disc(img, c, r * 0.40, r * 0.40 + maxf(1.5, s * 0.07), fill, outline)
		CURSOR_STYLE_RING:
			_draw_ring(img, c, r * 0.74, maxf(1.6, s * 0.11), fill, outline)
		CURSOR_STYLE_CROSSHAIR:
			_draw_crosshair(img, c, r, maxf(1.6, s * 0.09), r * 0.22, fill, outline)
	var tex := ImageTexture.create_from_image(img)
	Input.set_custom_mouse_cursor(tex, Input.CURSOR_ARROW, Vector2(c, c))

# Filled disc of `fill` with a `outline` halo out to outline_r.
func _draw_disc(img: Image, c: float, fill_r: float, outline_r: float, fill: Color, outline: Color) -> void:
	var s: int = img.get_width()
	for y: int in s:
		for x: int in s:
			var d: float = Vector2(x - c, y - c).length()
			if d <= fill_r:
				img.set_pixel(x, y, fill)
			elif d <= outline_r:
				img.set_pixel(x, y, outline)

# Annulus at `radius` of width `thickness`, dark-edged on both sides.
func _draw_ring(img: Image, c: float, radius: float, thickness: float, fill: Color, outline: Color) -> void:
	var s: int = img.get_width()
	var half: float = thickness * 0.5
	for y: int in s:
		for x: int in s:
			var d: float = absf(Vector2(x - c, y - c).length() - radius)
			if d <= half:
				img.set_pixel(x, y, fill)
			elif d <= half + 1.4:
				img.set_pixel(x, y, outline)

# Four-arm crosshair with a centre gap, dark-outlined.
func _draw_crosshair(img: Image, c: float, reach: float, thickness: float, gap: float, fill: Color, outline: Color) -> void:
	var s: int = img.get_width()
	var half: float = thickness * 0.5
	for y: int in s:
		for x: int in s:
			var dx: float = absf(x - c)
			var dy: float = absf(y - c)
			var on_v: bool = dx <= half and dy >= gap and dy <= reach
			var on_h: bool = dy <= half and dx >= gap and dx <= reach
			if on_v or on_h:
				img.set_pixel(x, y, fill)
				continue
			var near_v: bool = dx <= half + 1.4 and dy >= gap - 1.4 and dy <= reach + 1.4
			var near_h: bool = dy <= half + 1.4 and dx >= gap - 1.4 and dx <= reach + 1.4
			if near_v or near_h:
				img.set_pixel(x, y, outline)

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
		attr_speed   = clampi(int(cfg.get_value("player", "attr_speed",   PlayerAttributes.LEVEL_MEDIUM)),
				PlayerAttributes.LEVEL_MIN, PlayerAttributes.LEVEL_MAX)
		attr_agility = clampi(int(cfg.get_value("player", "attr_agility", PlayerAttributes.LEVEL_MEDIUM)),
				PlayerAttributes.LEVEL_MIN, PlayerAttributes.LEVEL_MAX)
		attr_size    = clampi(int(cfg.get_value("player", "attr_size",    PlayerAttributes.LEVEL_MEDIUM)),
				PlayerAttributes.LEVEL_MIN, PlayerAttributes.LEVEL_MAX)
		attr_strength    = clampi(int(cfg.get_value("player", "attr_strength",    PlayerAttributes.LEVEL_MEDIUM)),
				PlayerAttributes.LEVEL_MIN, PlayerAttributes.LEVEL_MAX)
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
		confine_mouse = cfg.get_value("input", "confine_mouse", true)
		cursor_style = clampi(int(cfg.get_value("input", "cursor_style", CURSOR_STYLE_DOT)), 0, CURSOR_STYLE_LABELS.size() - 1)
		var raw_cursor_color: Variant = cfg.get_value("input", "cursor_color", cursor_color)
		cursor_color = raw_cursor_color if raw_cursor_color is Color else cursor_color
		cursor_size = clampi(int(cfg.get_value("input", "cursor_size", cursor_size)), CURSOR_SIZE_MIN, CURSOR_SIZE_MAX)
		attack_up = cfg.get_value("game", "attack_up", false)
		has_opened_player_settings = cfg.get_value("game", "has_opened_player_settings", false)
		colorblind_rings = cfg.get_value("game", "colorblind_rings", false)
		camera_tilt_deg = clampf(cfg.get_value("game", "camera_tilt_deg", CAMERA_TILT_DEFAULT), CAMERA_TILT_MIN, CAMERA_TILT_MAX)
		fov = clampf(cfg.get_value("game", "fov", 50.0), FOV_MIN, FOV_MAX)
		camera_distance = clampf(cfg.get_value("game", "camera_distance", 1.0), CAMERA_DISTANCE_MIN, CAMERA_DISTANCE_MAX)
		replay_recording_enabled = cfg.get_value("replay", "recording_enabled", true)
		replay_keep_count = clampi(cfg.get_value("replay", "keep_count", 20), REPLAY_KEEP_MIN, REPLAY_KEEP_MAX)
		var raw_completion: Variant = cfg.get_value("tutorials", "completion", {})
		tutorial_completion = raw_completion if raw_completion is Dictionary else {}
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
	call_deferred(&"apply_input")
	call_deferred(&"apply_cursor")
	call_deferred(&"apply_video")


func get_player_attributes() -> PlayerAttributes:
	return PlayerAttributes.new(attr_speed, attr_agility, attr_size, attr_strength)


func set_player_attributes(attrs: PlayerAttributes) -> void:
	if attrs == null:
		return
	attr_speed   = attrs.speed
	attr_agility = attrs.agility
	attr_size    = attrs.size
	attr_strength = attrs.strength


func is_tutorial_complete(id: String) -> bool:
	var entry: Variant = tutorial_completion.get(id, false)
	# Value type can grow later (e.g. per-tutorial Dictionary with metadata).
	# Accept the current bool form and any Dictionary that has a "complete" key.
	if entry is Dictionary:
		return entry.get("complete", false)
	return bool(entry)


func mark_tutorial_complete(id: String) -> void:
	tutorial_completion[id] = true
	save()


func reset_tutorial(id: String) -> void:
	tutorial_completion.erase(id)
	save()


# Latches has_opened_player_settings the first time the player opens the
# player-settings popup, so the SideMenu's first-run callout shows once and
# never again. No-op (and no disk write) once already set.
func mark_player_settings_opened() -> void:
	if has_opened_player_settings:
		return
	has_opened_player_settings = true
	save()


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
