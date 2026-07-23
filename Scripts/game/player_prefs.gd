extends Node

const SAVE_PATH: String = "user://preferences.cfg"

# Window mode. Godot's WINDOW_MODE_FULLSCREEN is a borderless "fullscreen
# window" (native res, instant alt-tab) — NOT a true mode switch;
# EXCLUSIVE_FULLSCREEN is the real exclusive mode (lowest latency, slower
# alt-tab). Windowed clears the project.godot borderless baseline so the player
# gets a movable, titled window at the chosen Resolution. Borderless Fullscreen
# is the default — it fills any monitor (ultrawide / 4K included) at native res
# on first launch instead of stranding a fixed-size window. Index matches the
# OptionsPanel dropdown.
const WINDOW_MODE_WINDOWED: int = 0
const WINDOW_MODE_BORDERLESS: int = 1
const WINDOW_MODE_EXCLUSIVE: int = 2
const WINDOW_MODE_LABELS: Array[String] = [
	"Windowed",
	"Borderless Fullscreen",
	"Exclusive Fullscreen",
]

# Windowed-mode resolution candidates. The dropdown is filtered at build time to
# those that fit the active monitor (get_available_resolutions), and the
# monitor's native size is always folded in — so ultrawide / 4K players see
# their real resolution instead of a hardcoded 16:9 ladder. Covers 16:9, 16:10,
# 21:9 ultrawide, and 32:9 super-ultrawide.
const RESOLUTION_CANDIDATES: Array[Vector2i] = [
	Vector2i(1280, 720),
	Vector2i(1600, 900),
	Vector2i(1920, 1080),
	Vector2i(1920, 1200),
	Vector2i(2560, 1080),   # 21:9 ultrawide
	Vector2i(2560, 1440),
	Vector2i(2560, 1600),
	Vector2i(3440, 1440),   # 21:9 ultrawide
	Vector2i(3840, 1600),   # 21:9 ultrawide
	Vector2i(3840, 2160),   # 4K
	Vector2i(5120, 1440),   # 32:9 super-ultrawide
]
const RESOLUTION_DEFAULT: Vector2i = Vector2i(1920, 1080)

# VSync mode. Disabled tears but is lowest-latency; Enabled is double-buffered
# v-sync; Adaptive tears only when the frame rate drops below refresh (kills
# the hard judder of vsync stutter); Mailbox is low-latency triple-buffering
# (no tearing, not capped to refresh). Index matches the OptionsPanel dropdown
# AND the DisplayServer.VSyncMode enum order, so the value passes through
# directly.
const VSYNC_DISABLED: int = 0
const VSYNC_ENABLED: int = 1
const VSYNC_ADAPTIVE: int = 2
const VSYNC_MAILBOX: int = 3
const VSYNC_LABELS: Array[String] = [
	"Disabled",
	"Enabled",
	"Adaptive",
	"Mailbox",
]
const FPS_CAP_VALUES: Array[int] = [30, 60, 120, 144, 240, 0]

# Camera tilt. The game uses a single tilted-perspective camera; the only
# user-facing camera adjustment is a small tilt nudge around the default.
# GameCamera reads camera_tilt_deg each tick to drive pitch and the off-axis
# follow offset. Kept subtle by design — much shallower and the mouse-to-world
# projection becomes nonlinear enough to break stickhandling, so the slider is
# clamped to a tight band around the default. The low end trades a little of
# that projection linearity for forward view: at 70° the camera sits further
# behind the play and shows noticeably more of the attacking zone.
const CAMERA_TILT_DEFAULT: float = 75.0
const CAMERA_TILT_MIN: float = 70.0
const CAMERA_TILT_MAX: float = 77.0

# Camera framing mode. DYNAMIC is the broadcast-style cam that frames the
# midpoint of player + puck and biases toward the attacking zone. LOCKED pins
# the center on the player and only zooms out to keep an in-play puck in frame
# (used as the puckless fallback too). GameCamera reads camera_mode live each
# tick. Index matches the OptionsPanel dropdown.
const CAMERA_MODE_DYNAMIC: int = 0
const CAMERA_MODE_LOCKED: int = 1
const CAMERA_MODE_LABELS: Array[String] = [
	"Dynamic",
	"Locked",
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

# Shadow quality. The arena ceiling carries 8 downward SpotLight3Ds
# (SpotLight3D / SpotLight3D2..8 in RinkArena.tscn), and every shadow-casting
# light renders a full shadow map each frame — the arena's dominant shadow
# cost. This picks how many of them cast shadows, trading softer/denser
# overlapping shadows for fewer per-frame shadow passes. High = all 8 (the
# shipped look); Medium = 4; Low = 2. The kept lights are spatially interleaved
# so a reduced count still shadows the whole sheet — see SHADOW_LIGHTS_*.
const SHADOW_QUALITY_LOW: int = 0
const SHADOW_QUALITY_MEDIUM: int = 1
const SHADOW_QUALITY_HIGH: int = 2
const SHADOW_QUALITY_LABELS: Array[String] = [
	"Low",
	"Medium",
	"High",
]
# Which of the 8 name-sorted ceiling spotlights keep shadows at Medium / Low.
# Indices are into the SpotLight3D..SpotLight3D8 rig sorted by name; idx 0..3 are
# the x=-6 row (z = -22/-7/7/22), idx 4..7 the x=6 row. The sets interleave both
# sides and the rink length so the reduced count still lights the whole ice.
# High keeps them all, so it needs no set. Tweak in-editor to taste.
const SHADOW_LIGHTS_MEDIUM: PackedInt32Array = [0, 2, 5, 7]
const SHADOW_LIGHTS_LOW: PackedInt32Array = [1, 6]

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
# Upper-deck rows behind the concourse walkway (ArenaStands.upper_terraces).
# LOW skips the second deck entirely — it roughly doubles the spectator
# instance count — leaving the shell wall to close in behind the small bowl.
const CROWD_DENSITY_LOW_UPPER_TERRACES: int = 0
const CROWD_DENSITY_HIGH_UPPER_TERRACES: int = 10

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
	"move_up", "move_down", "move_left", "move_right", "sprint", "brake",
	"shoot", "quick_pass", "slapshot", "hit", "block", "elevation_up", "elevation_down",
	"stick_lift", "smart_ping", "toggle_ui",
]

var player_name: String = "Player"
var jersey_number: int = 10
var is_left_handed: bool = true
var preferred_color_slot: int = -1  # team color preset slot index; -1 → use team default at lobby join

# Per-player build (attributes v4, body + gear): a free HEIGHT in inches
# (5'8"..6'7"), a free WEIGHT in lbs (clamped to the height's BMI band), and
# four gear slots (0/1/2, 1 = balanced). Every axis is lateral — validation is
# coercion, not rejection. Default is the neutral build (6'1"/201, balanced)
# so a fresh install plays identically to the shipped baseline.
var attr_height:  int = PlayerAttributes.HEIGHT_MEDIUM
var attr_weight:  int = int(PlayerAttributes.NEUTRAL_WEIGHT_LBS)
var attr_profile: int = PlayerAttributes.GEAR_BALANCED
var attr_curve:   int = PlayerAttributes.GEAR_BALANCED
var attr_flex:    int = PlayerAttributes.GEAR_BALANCED
var attr_length:  int = PlayerAttributes.GEAR_BALANCED

# Named attribute-build presets. The player keeps up to MAX_PRESETS builds and
# switches which one is ACTIVE; the flat attr_* fields above always mirror the
# active preset, so everything that reads get_player_attributes() (the online
# join handshake, the free-play live apply) is unaffected by the presets layer —
# it always sees the active build. Each entry is {"name": String,
# "attrs": PlayerAttributes}. A save without a stored presets array (fresh
# install or a pre-presets save) is migrated to a single "Default" preset
# carrying the flat build, in _finalize_presets().
const MAX_PRESETS: int = 4
const PRESET_NAME_MAX_LEN: int = 16
const DEFAULT_PRESET_NAME: String = "Default"
var attr_presets: Array[Dictionary] = []
var attr_active_preset: int = 0
var master_volume: float = 0.5
var sfx_volume: float = 1.0
var ui_volume: float = 1.0
var arena_volume: float = 1.0
var master_muted: bool = false
# Silence the game while another window has OS focus (alt-tabbed away). On by
# default; streamers / second-monitor players can turn it off. SoundManager
# mutes the Master bus on focus-out and restores master_muted on focus-in.
var mute_when_unfocused: bool = true
var window_mode: int = WINDOW_MODE_BORDERLESS
var resolution: Vector2i = RESOLUTION_DEFAULT
var display_monitor: int = -1  # -1 = follow the window (automatic); else target screen index
# The monitor the window was last seen on, persisted so Automatic mode
# (display_monitor < 0) re-opens on the same screen next launch instead of
# wherever the OS drops it. Updated by the screen-change watcher below; an
# explicit display_monitor pick still wins at launch (we don't silently
# overwrite a deliberate Options selection).
var last_window_screen: int = -1
var vsync_mode: int = VSYNC_ENABLED
var fps_cap_index: int = 5
var show_fps: bool = false
var gamma: float = 1.0
var color_grade_preset: int = COLOR_GRADE_BROADCAST
var gi_mode: int = GI_MODE_OFF
var shadow_quality: int = SHADOW_QUALITY_HIGH
var crowd_density: int = CROWD_DENSITY_HIGH
var ice_scratches_enabled: bool = true
var puck_shadow_enabled: bool = true
var scaling_3d_mode: int = SCALING_3D_BILINEAR
var render_scale: float = 1.0
var anti_aliasing_mode: int = AA_MSAA_2X
# Shot Power Sensitivity: scales the raw cursor speed the wrister power model
# reads (SkaterController._wrister_sweep_speed), so a player calibrates how hard
# they must flick for a full-power shot to their own mouse DPI/sensitivity.
# Higher = shots reach full power with a gentler flick. Local-only (applied by
# LocalController); does not affect bots or the aim direction.
var shot_power_sensitivity: float = 1.0
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
# Top-down rink minimap in the HUD corner (Options → Camera). On by default; the
# widget itself reads this live each frame (see Minimap._draw).
var minimap_enabled: bool = true
# On-ice self/team/enemy ring colors, relationship-relative to the local player.
# Fully user-pickable (Options → Game → Ring Colors) so players can dial in a
# colorblind-safe palette or any scheme they like. SkaterHUDCoordinator reads
# these live. Defaults are MenuStyle's canonical green/blue/red.
var ring_color_self: Color = MenuStyle.HUD_RING_SELF
var ring_color_team: Color = MenuStyle.HUD_RING_TEAM
var ring_color_enemy: Color = MenuStyle.HUD_RING_ENEMY
# Overhead self-beacon — the floating marker above your own skater that helps you
# not lose which skater is yours. SkaterHUDCoordinator reads this live.
#   ALWAYS   — always shown over your skater.
#   SMART    — shown only in scrums and while ghosted (default).
#   DISABLED — never shown.
const BEACON_MODE_ALWAYS: int = 0
const BEACON_MODE_SMART: int = 1
const BEACON_MODE_DISABLED: int = 2
const BEACON_MODE_LABELS: Array[String] = ["Always On", "Smart", "Disabled"]
var self_beacon_mode: int = BEACON_MODE_SMART

# Bot difficulty. Index matches BotSkillProfile.Difficulty and the OptionButton
# ordering wherever the menu exposes it.
const BOT_DIFFICULTY_LABELS: Array[String] = [
	"Easy",
	"Normal",
	"Hard",
]
# Goalie difficulty. Index matches GoalieSkillProfile.Difficulty and the
# OptionButton ordering wherever the menu exposes it (Easy → Normal → Hard).
const GOALIE_DIFFICULTY_LABELS: Array[String] = [
	"Easy",
	"Normal",
	"Hard",
]
# Accessibility: photosensitivity / motion options. screen_flash gates the
# full-screen goal flash and hit vignette (FlashOverlay); screen_shake gates
# camera trauma shake (GameCamera.shake). Both default on.
var screen_flash: bool = true
var screen_shake: bool = true
var camera_tilt_deg: float = CAMERA_TILT_DEFAULT  # GameCamera reads this each tick for pitch
var fov: float = 50.0  # GameCamera writes this to its Camera3D.fov each tick
var camera_distance: float = 1.0  # multiplier on min/ozone/max camera heights
var camera_mode: int = CAMERA_MODE_DYNAMIC  # GameCamera reads this each tick (see CAMERA_MODE_*)
var bot_difficulty: int = BotSkillProfile.Difficulty.NORMAL  # see BotSkillProfile
# Goalie difficulty for HOSTED / lobby matches (set in the lobby settings panel).
var goalie_difficulty: int = GoalieSkillProfile.Difficulty.NORMAL  # see GoalieSkillProfile
# Goalie difficulty for FREE PLAY — a separate knob from the hosted one, since
# free play is the personal sandbox / effective main menu (set in the options
# panel). Defaults to Easy so a newcomer's first puck-drop is the forgiving
# goalie; they opt up from there. GameManager branches on is_free_play_mode.
var freeplay_goalie_difficulty: int = GoalieSkillProfile.Difficulty.EASY
const FOV_MIN: float = 40.0
const FOV_MAX: float = 90.0
const CAMERA_DISTANCE_MIN: float = 0.6
const CAMERA_DISTANCE_MAX: float = 1.6
# HUD scale. A uniform scale on the gameplay HUD CanvasLayer, applied about the
# viewport center — so values below 1.0 both shrink the overlay AND pull its
# edge-anchored elements inward (a safe-area inset for ultrawide / 32:9, where
# corner widgets otherwise sit uncomfortably far apart). HUD reads it live in
# _process. Menus render on their own CanvasLayers and are unaffected.
var hud_scale: float = 1.0
const HUD_SCALE_MIN: float = 0.80
const HUD_SCALE_MAX: float = 1.20
var bindings: Dictionary = {}  # action -> {type, physical_keycode or button_index}
# Project-default key bindings, captured once at load before any saved override
# is applied — the canonical source for Options' "Reset to Defaults".
var default_bindings: Dictionary = {}

# Telemetry / privacy. When false, no career-stats rows are uploaded at game
# over (GameManager skips CareerStatsReporter). Both the Career screen and the
# replay browser are driven entirely by that uploaded backend data, so opting
# out leaves them empty — the Career menu is greyed out in the side menu and
# replays can't be browsed. Default on. Toggle + notice live in
# Options → Game → Data Sharing.
var share_gameplay_stats: bool = true

# UI language. Empty string means "follow the OS language" (resolved to a
# shipped locale, else English); a non-empty code ("en", "es") forces that
# language. Applied through LocaleManager into Godot's TranslationServer, which
# every UI tr() reads. Shipped languages + resolution live in LocaleManager;
# the string catalogue is locale/translations.csv.
var locale: String = ""

# Replay recording. Recording fires on every peer (host + clients) for every
# multiplayer game; offline / tutorial sessions never record. ReplayFileIndex
# purges oldest replays in user://replays/ down to keep_count at writer-open
# time so the on-disk footprint stays bounded.
var replay_recording_enabled: bool = true
var replay_keep_count: int = 20
const REPLAY_KEEP_MIN: int = 1
const REPLAY_KEEP_MAX: int = 100

# Tutorial completion is stored as a single Dictionary keyed by tutorial id
# ("movement", "shooting", future drill ids) so adding new tutorials never
# requires a schema change. Value is currently a bool; can grow to a small
# per-tutorial dict (timestamps, highest step reached) without migration —
# _load() defensive-casts whatever ConfigFile returns.
# TUTORIAL_COURSE_VERSION gates a completion wipe on load: bump it whenever the
# course is restructured enough that everyone should replay it (v2 = the
# six-part Movement→Rules course).
const TUTORIAL_COURSE_VERSION: int = 2
var tutorial_completion: Dictionary = {}

func _get_save_path() -> String:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--config-suffix="):
			return "user://preferences_%s.cfg" % arg.substr(16)
	return SAVE_PATH

func _ready() -> void:
	_load()
	# Steam Cloud reconcile is deferred: PlayerPrefs is autoload #1 and
	# SteamManager #7, so Steam isn't initialised yet during the _load() above.
	# A deferred call runs after every autoload's (synchronous) _ready, by which
	# point Cloud availability is known. See _sync_from_cloud.
	_sync_from_cloud.call_deferred()


func save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("player", "name", player_name)
	cfg.set_value("player", "jersey_number", jersey_number)
	cfg.set_value("player", "left_handed", is_left_handed)
	cfg.set_value("player", "preferred_color_slot", preferred_color_slot)
	cfg.set_value("player", "attr_height",  attr_height)
	cfg.set_value("player", "attr_weight",  attr_weight)
	cfg.set_value("player", "attr_profile", attr_profile)
	cfg.set_value("player", "attr_curve",   attr_curve)
	cfg.set_value("player", "attr_flex",    attr_flex)
	cfg.set_value("player", "attr_length",  attr_length)
	# Marks the values above as already on the v4 body+gear model so _load()
	# doesn't re-run the tier / six-attribute migrations on them.
	cfg.set_value("player", "attr_scale_version", 5)
	# Presets are stored in the same version-5 native format. The flat attr_* keys
	# above remain the active build's mirror for backward compat.
	var stored_presets: Array = []
	for p: Dictionary in attr_presets:
		var a: PlayerAttributes = p["attrs"]
		var stored: Dictionary = a.to_dict()
		stored["name"] = p["name"]
		stored_presets.append(stored)
	cfg.set_value("player", "attr_presets", stored_presets)
	cfg.set_value("player", "attr_active_preset", attr_active_preset)
	cfg.set_value("audio", "master_volume", master_volume)
	cfg.set_value("audio", "sfx_volume", sfx_volume)
	cfg.set_value("audio", "ui_volume", ui_volume)
	cfg.set_value("audio", "arena_volume", arena_volume)
	cfg.set_value("audio", "master_muted", master_muted)
	cfg.set_value("audio", "mute_when_unfocused", mute_when_unfocused)
	cfg.set_value("video", "window_mode", window_mode)
	cfg.set_value("video", "resolution", resolution)
	cfg.set_value("video", "display_monitor", display_monitor)
	cfg.set_value("video", "last_window_screen", last_window_screen)
	cfg.set_value("video", "vsync_mode", vsync_mode)
	cfg.set_value("video", "fps_cap_index", fps_cap_index)
	cfg.set_value("video", "show_fps", show_fps)
	cfg.set_value("video", "gamma", gamma)
	cfg.set_value("video", "color_grade_preset", color_grade_preset)
	cfg.set_value("video", "gi_mode", gi_mode)
	cfg.set_value("video", "shadow_quality", shadow_quality)
	cfg.set_value("video", "crowd_density", crowd_density)
	cfg.set_value("video", "ice_scratches_enabled", ice_scratches_enabled)
	cfg.set_value("video", "puck_shadow_enabled", puck_shadow_enabled)
	cfg.set_value("video", "scaling_3d_mode", scaling_3d_mode)
	cfg.set_value("video", "render_scale", render_scale)
	cfg.set_value("video", "anti_aliasing_mode", anti_aliasing_mode)
	cfg.set_value("input", "shot_power_sensitivity", shot_power_sensitivity)
	cfg.set_value("input", "confine_mouse", confine_mouse)
	cfg.set_value("input", "cursor_style", cursor_style)
	cfg.set_value("input", "cursor_color", cursor_color)
	cfg.set_value("input", "cursor_size", cursor_size)
	cfg.set_value("game", "attack_up", attack_up)
	cfg.set_value("game", "minimap_enabled", minimap_enabled)
	cfg.set_value("game", "has_opened_player_settings", has_opened_player_settings)
	cfg.set_value("game", "ring_color_self", ring_color_self)
	cfg.set_value("game", "ring_color_team", ring_color_team)
	cfg.set_value("game", "ring_color_enemy", ring_color_enemy)
	cfg.set_value("game", "self_beacon_mode", self_beacon_mode)
	cfg.set_value("game", "screen_flash", screen_flash)
	cfg.set_value("game", "screen_shake", screen_shake)
	cfg.set_value("game", "camera_tilt_deg", camera_tilt_deg)
	cfg.set_value("game", "fov", fov)
	cfg.set_value("game", "camera_distance", camera_distance)
	cfg.set_value("game", "camera_mode", camera_mode)
	cfg.set_value("game", "bot_difficulty", bot_difficulty)
	# Marks bot_difficulty as already on the 3-tier (Easy/Normal/Hard) scale so
	# _load() doesn't re-run the 2-tier → 3-tier remap on a re-saved file.
	cfg.set_value("game", "bot_difficulty_scale_version", 1)
	cfg.set_value("game", "goalie_difficulty", goalie_difficulty)
	cfg.set_value("game", "freeplay_goalie_difficulty", freeplay_goalie_difficulty)
	# Marks goalie_difficulty as already on the 3-tier (Easy/Normal/Hard) scale so
	# _load() doesn't re-run the 2-tier → 3-tier remap on a re-saved file.
	cfg.set_value("game", "goalie_difficulty_scale_version", 1)
	cfg.set_value("game", "hud_scale", hud_scale)
	cfg.set_value("game", "share_gameplay_stats", share_gameplay_stats)
	cfg.set_value("game", "locale", locale)
	cfg.set_value("replay", "recording_enabled", replay_recording_enabled)
	cfg.set_value("replay", "keep_count", replay_keep_count)
	cfg.set_value("tutorials", "completion", tutorial_completion)
	cfg.set_value("tutorials", "course_version", TUTORIAL_COURSE_VERSION)
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
	# Marks the Hit/Block control-scheme swap applied (see _load's migration), so
	# a returning config is remapped exactly once and never re-forces Block off a
	# key the player has since chosen for it.
	cfg.set_value("bindings", "scheme_version", 1)
	cfg.save(_get_save_path())
	_push_to_cloud()


# ── Steam Cloud sync ─────────────────────────────────────────────────────────
# The prefs file is mirrored into Steam Cloud so settings follow the player to
# any machine. Steam's own client sync resolves the remote copy into its local
# cache before the game launches, so cloud_read returns the already-reconciled
# bytes; we bridge that namespace to our user:// file. The cloud name mirrors the
# local basename so --config-suffix dev instances stay separate in Cloud too.
func _cloud_save_name() -> String:
	return _get_save_path().get_file()


# Push the on-disk prefs file up to Cloud. No-op when Cloud is unavailable.
func _push_to_cloud() -> void:
	if not SteamManager.is_cloud_available():
		return
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(_get_save_path())
	if bytes.is_empty():
		return
	SteamManager.cloud_write(_cloud_save_name(), bytes)


# Reconcile the local prefs file against Steam Cloud at boot. Cloud is the
# cross-machine source of truth: when a cloud copy exists and differs we adopt
# it (newer-write-wins on a genuine conflict) and re-load; when none exists we
# seed Cloud from the local file. Deferred from _ready (see there).
func _sync_from_cloud() -> void:
	if not SteamManager.is_cloud_available():
		return
	# Subscribe once to Dynamic Cloud Sync: on Deck suspend→resume Steam pulls a
	# newer copy into the local cache mid-session, and re-running this reconcile
	# adopts it. Connected here rather than in _ready because SteamManager is a
	# later autoload and isn't constructed yet during _ready.
	if not SteamManager.cloud_files_changed.is_connected(_sync_from_cloud):
		SteamManager.cloud_files_changed.connect(_sync_from_cloud)
	var cloud_name: String = _cloud_save_name()
	var local_path: String = _get_save_path()
	var has_local: bool = FileAccess.file_exists(local_path)
	if not SteamManager.cloud_file_exists(cloud_name):
		if has_local:
			_push_to_cloud()  # first run with Cloud on — seed it
		return
	var cloud_bytes: PackedByteArray = SteamManager.cloud_read(cloud_name)
	if cloud_bytes.is_empty():
		return
	if has_local:
		var local_bytes: PackedByteArray = FileAccess.get_file_as_bytes(local_path)
		if cloud_bytes == local_bytes:
			return  # already in sync — nothing to do
		# Conflict: a copy was changed on another machine (cloud) and/or offline
		# here (local). Keep whichever store was written most recently, and push
		# a newer local back up so the other machine converges next launch.
		if FileAccess.get_modified_time(local_path) > SteamManager.cloud_file_timestamp(cloud_name):
			_push_to_cloud()
			return
	# Adopt the cloud copy: write it to the local file and re-load from it.
	var f := FileAccess.open(local_path, FileAccess.WRITE)
	if f == null:
		return
	f.store_buffer(cloud_bytes)
	f = null
	_load()

func apply_locale() -> void:
	LocaleManager.apply(locale)


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


# Short display string for an action's current primary binding, read from the
# live InputMap (which apply_bindings keeps in sync with the player's rebinds).
# Used by tutorial copy — instructions always name the player's real keys, not
# the project defaults.
func action_display(action: String) -> String:
	var b: Dictionary = _read_current_input_event(action)
	if b.get("type") == "key":
		return OS.get_keycode_string(int(b.physical_keycode) as Key)
	if b.get("type") == "mouse":
		match int(b.button_index):
			MOUSE_BUTTON_LEFT: return "LMB"
			MOUSE_BUTTON_RIGHT: return "RMB"
			MOUSE_BUTTON_MIDDLE: return "MMB"
			MOUSE_BUTTON_WHEEL_UP: return "Scroll Up"
			MOUSE_BUTTON_WHEEL_DOWN: return "Scroll Down"
			_: return "Mouse %d" % int(b.button_index)
	return "?"

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
	var arena_bus := AudioServer.get_bus_index("Arena")
	if arena_bus != -1:
		AudioServer.set_bus_volume_db(arena_bus, linear_to_db(maxf(arena_volume, 0.0001)))

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

# Windowed resolutions valid for a monitor: every candidate that fits inside
# the screen, plus the monitor's native size, de-duplicated and sorted ascending
# by pixel count. Rebuilt each time Options opens (and per monitor pick) so the
# offered list always matches the screen the window will actually use. Never
# empty — falls back to the default on a degenerate/headless display query.
# `screen` defaults to the target monitor; pass an index to preview another.
func get_available_resolutions(screen: int = -1) -> Array[Vector2i]:
	if screen < 0 or screen >= DisplayServer.get_screen_count():
		screen = _target_screen()
	var native: Vector2i = DisplayServer.screen_get_size(screen)
	var out: Array[Vector2i] = []
	for r: Vector2i in RESOLUTION_CANDIDATES:
		if r.x <= native.x and r.y <= native.y and not out.has(r):
			out.append(r)
	if native.x > 0 and native.y > 0 and not out.has(native):
		out.append(native)
	if out.is_empty():
		out.append(RESOLUTION_DEFAULT)
	out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.x * a.y < b.x * b.y)
	return out


# The monitor fullscreen / windowed-centering should target: the explicit
# override when it points at a real screen; otherwise (Automatic) the monitor
# the window was last remembered on; otherwise the screen the window lives on.
func _target_screen() -> int:
	if display_monitor >= 0 and display_monitor < DisplayServer.get_screen_count():
		return display_monitor
	if last_window_screen >= 0 and last_window_screen < DisplayServer.get_screen_count():
		return last_window_screen
	return DisplayServer.window_get_current_screen()


func apply_video() -> void:
	_apply_window_mode()
	DisplayServer.window_set_vsync_mode(vsync_mode as DisplayServer.VSyncMode)
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
	_apply_shadow_quality(scene)
	var stands := scene.find_child("ArenaStands", true, false) as Node3D
	if stands != null:
		stands.visible = (crowd_density != CROWD_DENSITY_OFF)
		if crowd_density != CROWD_DENSITY_OFF and stands.has_method("set_crowd_rows"):
			if crowd_density == CROWD_DENSITY_HIGH:
				stands.call("set_crowd_rows",
						CROWD_DENSITY_HIGH_TERRACES, CROWD_DENSITY_HIGH_UPPER_TERRACES)
			else:
				stands.call("set_crowd_rows",
						CROWD_DENSITY_LOW_TERRACES, CROWD_DENSITY_LOW_UPPER_TERRACES)
	var scratch := scene.find_child("IceScratchMap", true, false)
	if scratch != null and scratch.has_method("set_enabled"):
		scratch.call("set_enabled", ice_scratches_enabled)

# Enables shadow casting on a subset of the arena's ceiling spotlights per the
# shadow_quality level. The lights are matched by name ("SpotLight3D*", which
# excludes the DasherSpotLights) and sorted by name so the SHADOW_LIGHTS_* index
# sets are stable. High keeps every light casting (the shipped look); Medium/Low
# disable the rest, cutting per-frame shadow-map passes. Degrades gracefully if
# the rig's light count ever changes (out-of-range keep indices just no-op).
func _apply_shadow_quality(scene: Node) -> void:
	var lights: Array[Node] = scene.find_children("SpotLight3D*", "SpotLight3D", true, false)
	if lights.is_empty():
		return
	lights.sort_custom(func(a: Node, b: Node) -> bool: return String(a.name) < String(b.name))
	if shadow_quality == SHADOW_QUALITY_HIGH:
		for node: Node in lights:
			(node as SpotLight3D).shadow_enabled = true
		return
	var keep: PackedInt32Array = SHADOW_LIGHTS_MEDIUM \
		if shadow_quality == SHADOW_QUALITY_MEDIUM else SHADOW_LIGHTS_LOW
	for i: int in lights.size():
		(lights[i] as SpotLight3D).shadow_enabled = keep.has(i)

# Routes window_mode + display_monitor + resolution into DisplayServer. The
# monitor is selected first so a fullscreen mode lands on the right screen.
func _apply_window_mode() -> void:
	var screen: int = _target_screen()
	if DisplayServer.window_get_current_screen() != screen:
		DisplayServer.window_set_current_screen(screen)
	match window_mode:
		WINDOW_MODE_BORDERLESS:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		WINDOW_MODE_EXCLUSIVE:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
		_:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			# project.godot ships window/size/borderless=true; clear it in true
			# windowed mode so the player gets a movable, titled window. Then
			# size it (clamped to the monitor) and center it on that screen.
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
			var size: Vector2i = _fit_resolution(resolution, screen)
			DisplayServer.window_set_size(size)
			var screen_pos: Vector2i = DisplayServer.screen_get_position(screen)
			var screen_size: Vector2i = DisplayServer.screen_get_size(screen)
			DisplayServer.window_set_position(screen_pos + (screen_size - size) / 2)
	# Re-baseline the screen-change watcher: a deliberate apply just placed the
	# window, so this screen is the new "no move yet" reference and the watcher
	# shouldn't treat it as an OS-driven monitor change.
	_last_seen_screen = DisplayServer.window_get_current_screen()


# --- Multi-monitor follow ----------------------------------------------------
# Godot emits no signal when the OS moves the window to another monitor
# (Win+Shift+Arrow, drag, a different-resolution second screen, etc.), and a
# Borderless/Exclusive Fullscreen window keeps the *old* monitor's pixel size
# after such a move — so on a rig with mismatched-resolution monitors it renders
# at the wrong size on the new screen. We poll the window's current screen at a
# low rate; on a change we re-fit the fullscreen window to the new monitor and
# remember it so the next launch opens there (Automatic monitor mode).
const _SCREEN_POLL_INTERVAL: float = 0.25
var _screen_poll_accum: float = 0.0
var _last_seen_screen: int = -1


func _process(delta: float) -> void:
	_screen_poll_accum += delta
	if _screen_poll_accum < _SCREEN_POLL_INTERVAL:
		return
	_screen_poll_accum = 0.0
	var cur: int = DisplayServer.window_get_current_screen()
	if cur == _last_seen_screen:
		return
	_last_seen_screen = cur
	_on_window_screen_changed(cur)


func _on_window_screen_changed(screen: int) -> void:
	# Remember the monitor so Automatic mode re-opens here next launch. (An
	# explicit Options "Monitor" pick still governs launch via _target_screen;
	# we don't silently rewrite display_monitor here.)
	if last_window_screen != screen:
		last_window_screen = screen
		save()
	# Windowed mode is left as-is (respect OS half-screen snapping / manual
	# drags); only the fullscreen modes need re-fitting to the new monitor's
	# native resolution.
	if window_mode == WINDOW_MODE_WINDOWED:
		return
	_refit_fullscreen_to_screen(screen)


# Force a Borderless/Exclusive Fullscreen window to recompute its size against
# the monitor the OS just moved it onto. Re-setting the same fullscreen mode is
# a no-op in Godot, so we bounce through Windowed to make it re-fit.
func _refit_fullscreen_to_screen(screen: int) -> void:
	var mode: DisplayServer.WindowMode = (
		DisplayServer.WINDOW_MODE_FULLSCREEN
		if window_mode == WINDOW_MODE_BORDERLESS
		else DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_current_screen(screen)
	DisplayServer.window_set_mode(mode)


# Clamp a windowed resolution to the monitor so a size saved on a larger display
# can't open a window taller/wider than the current screen.
func _fit_resolution(size: Vector2i, screen: int) -> Vector2i:
	var native: Vector2i = DisplayServer.screen_get_size(screen)
	if native.x <= 0 or native.y <= 0:
		return size
	return Vector2i(mini(size.x, native.x), mini(size.y, native.y))


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
	# InputMap still holds the untouched project defaults on the FIRST load
	# (apply_bindings hasn't run yet), so snapshot them for Reset to Defaults
	# before any saved override is read in below. Guarded to first-call-only: a
	# Steam Cloud adopt re-runs _load() after apply_bindings has rewritten the
	# InputMap, and re-snapshotting then would capture the saved binds as
	# "defaults".
	if default_bindings.is_empty():
		for action: String in REBINDABLE_ACTIONS:
			var d: Dictionary = _read_current_input_event(action)
			if not d.is_empty():
				default_bindings[action] = d
	var cfg := ConfigFile.new()
	if cfg.load(_get_save_path()) == OK:
		player_name = cfg.get_value("player", "name", "Player").substr(0, 10)
		jersey_number = clamp(cfg.get_value("player", "jersey_number", 10), 0, 99)
		is_left_handed = cfg.get_value("player", "left_handed", true)
		# Reads as int; any legacy fruit-name string under the old "preferred_color_id"
		# key is ignored — hard break, no migration. -1 falls back to the default at
		# next lobby join.
		preferred_color_slot = int(cfg.get_value("player", "preferred_color_slot", -1))
		var attr_ver: int = int(cfg.get_value("player", "attr_scale_version", 1))
		if attr_ver >= 5:
			# Native v4 body+gear model. Funnel through set_player_attributes so
			# every axis coerces (weight into the height's band, gear into 0..2).
			set_player_attributes(PlayerAttributes.new(
					int(cfg.get_value("player", "attr_height", PlayerAttributes.HEIGHT_MEDIUM)),
					int(cfg.get_value("player", "attr_weight", 0)),
					int(cfg.get_value("player", "attr_profile", PlayerAttributes.GEAR_BALANCED)),
					int(cfg.get_value("player", "attr_curve",   PlayerAttributes.GEAR_BALANCED)),
					int(cfg.get_value("player", "attr_flex",    PlayerAttributes.GEAR_BALANCED)),
					int(cfg.get_value("player", "attr_length",  PlayerAttributes.GEAR_BALANCED))))
		elif attr_ver == 4:
			# v4-era save: height + three tiers. Deterministic map onto body+gear
			# (PlayerAttributes.migrate_tiers — Checking→frame, Skating→profile, …).
			set_player_attributes(PlayerAttributes.migrate_tiers(
					int(cfg.get_value("player", "attr_height", PlayerAttributes.HEIGHT_MEDIUM)),
					int(cfg.get_value("player", "attr_skating",  2)),
					int(cfg.get_value("player", "attr_skill",    2)),
					int(cfg.get_value("player", "attr_checking", 2))))
		else:
			# Any pre-v4 save is on the legacy six-attribute scale (or an even older
			# 1..3 / four-attribute one). Rebuild a v3 six-attribute build via the old
			# migration chain, then map it to the body+gear model with migrate_legacy.
			var sp: int
			var ag: int
			var ha: int
			var sz: int
			var ph: int
			var sh: int
			if attr_ver >= 3:
				sp = _clamp_1to5(int(cfg.get_value("player", "attr_speed",    3)))
				ag = _clamp_1to5(int(cfg.get_value("player", "attr_agility",  3)))
				ha = _clamp_1to5(int(cfg.get_value("player", "attr_hands",    3)))
				sz = _clamp_1to5(int(cfg.get_value("player", "attr_size",     3)))
				ph = _clamp_1to5(int(cfg.get_value("player", "attr_physical", 3)))
				sh = _clamp_1to5(int(cfg.get_value("player", "attr_shot",     3)))
			else:
				# v1 (1..3) / v2 (1..5, Skill-renamed) four-attribute saves: rebuild the
				# Speed/Agility/Size/Skill intermediate, seeding Hands/Physical at medium
				# and using Skill for Shot, matching the old four→six split.
				var sk: int
				if attr_ver >= 2:
					sp = _clamp_1to5(int(cfg.get_value("player", "attr_speed",   3)))
					ag = _clamp_1to5(int(cfg.get_value("player", "attr_agility", 3)))
					sz = _clamp_1to5(int(cfg.get_value("player", "attr_size",    3)))
					sk = _clamp_1to5(int(cfg.get_value("player", "attr_skill",   3)))
				else:
					sp = _migrate_legacy_level(int(cfg.get_value("player", "attr_speed",    2)))
					ag = _migrate_legacy_level(int(cfg.get_value("player", "attr_agility",  2)))
					sz = _migrate_legacy_level(int(cfg.get_value("player", "attr_size",     2)))
					sk = _migrate_legacy_level(int(cfg.get_value("player", "attr_strength", 2)))
				ha = 3
				ph = 3
				sh = sk
			set_player_attributes(PlayerAttributes.migrate_legacy(sp, ag, ha, sz, ph, sh))
		# One choke point: whichever branch ran above, the flat build re-coerces
		# through the constructor (weight into the height's band, gear into range)
		# before anything reads it. Runs BEFORE the presets load so a pre-presets
		# save seeds its Default preset from the already-repaired build.
		_enforce_attr_legal()
		# Load the preset list (validated + clamped). If the save predates presets
		# the array is empty here; _finalize_presets() seeds a Default from the flat
		# build below. When presets ARE present they are authoritative for the
		# active build, so _finalize_presets() re-syncs the flat fields from them.
		attr_presets = _parse_stored_presets(cfg.get_value("player", "attr_presets", []))
		attr_active_preset = int(cfg.get_value("player", "attr_active_preset", 0))
		master_volume = clampf(cfg.get_value("audio", "master_volume", 0.5), 0.0, 1.0)
		sfx_volume = clampf(cfg.get_value("audio", "sfx_volume", 1.0), 0.0, 1.0)
		ui_volume = clampf(cfg.get_value("audio", "ui_volume", 1.0), 0.0, 1.0)
		# Renamed from "crowd_volume"; fall back to the old key so existing saves keep their level.
		arena_volume = clampf(cfg.get_value("audio", "arena_volume", cfg.get_value("audio", "crowd_volume", 1.0)), 0.0, 1.0)
		master_muted = cfg.get_value("audio", "master_muted", false)
		mute_when_unfocused = cfg.get_value("audio", "mute_when_unfocused", true)
		window_mode = clampi(int(cfg.get_value("video", "window_mode", WINDOW_MODE_BORDERLESS)), 0, WINDOW_MODE_LABELS.size() - 1)
		var raw_resolution: Variant = cfg.get_value("video", "resolution", RESOLUTION_DEFAULT)
		resolution = raw_resolution if raw_resolution is Vector2i else RESOLUTION_DEFAULT
		display_monitor = int(cfg.get_value("video", "display_monitor", -1))
		last_window_screen = int(cfg.get_value("video", "last_window_screen", -1))
		vsync_mode = clampi(int(cfg.get_value("video", "vsync_mode", VSYNC_ENABLED)), 0, VSYNC_LABELS.size() - 1)
		fps_cap_index = clamp(cfg.get_value("video", "fps_cap_index", 5), 0, FPS_CAP_VALUES.size() - 1)
		show_fps = cfg.get_value("video", "show_fps", false)
		gamma = clampf(cfg.get_value("video", "gamma", 1.0), 0.5, 2.0)
		color_grade_preset = clamp(cfg.get_value("video", "color_grade_preset", COLOR_GRADE_NEUTRAL), 0, COLOR_GRADE_LABELS.size() - 1)
		gi_mode = clamp(cfg.get_value("video", "gi_mode", GI_MODE_OFF), 0, GI_MODE_LABELS.size() - 1)
		shadow_quality = clamp(cfg.get_value("video", "shadow_quality", SHADOW_QUALITY_HIGH), 0, SHADOW_QUALITY_LABELS.size() - 1)
		crowd_density = clamp(cfg.get_value("video", "crowd_density", CROWD_DENSITY_HIGH), 0, CROWD_DENSITY_LABELS.size() - 1)
		ice_scratches_enabled = cfg.get_value("video", "ice_scratches_enabled", true)
		puck_shadow_enabled = cfg.get_value("video", "puck_shadow_enabled", true)
		scaling_3d_mode = clamp(cfg.get_value("video", "scaling_3d_mode", SCALING_3D_BILINEAR), 0, SCALING_3D_LABELS.size() - 1)
		render_scale = clampf(cfg.get_value("video", "render_scale", 1.0), RENDER_SCALE_MIN, RENDER_SCALE_MAX)
		anti_aliasing_mode = clamp(cfg.get_value("video", "anti_aliasing_mode", AA_MSAA_2X), 0, AA_LABELS.size() - 1)
		shot_power_sensitivity = clampf(cfg.get_value("input", "shot_power_sensitivity", 1.0), 0.25, 4.0)
		confine_mouse = cfg.get_value("input", "confine_mouse", true)
		cursor_style = clampi(int(cfg.get_value("input", "cursor_style", CURSOR_STYLE_DOT)), 0, CURSOR_STYLE_LABELS.size() - 1)
		var raw_cursor_color: Variant = cfg.get_value("input", "cursor_color", cursor_color)
		cursor_color = raw_cursor_color if raw_cursor_color is Color else cursor_color
		cursor_size = clampi(int(cfg.get_value("input", "cursor_size", cursor_size)), CURSOR_SIZE_MIN, CURSOR_SIZE_MAX)
		attack_up = cfg.get_value("game", "attack_up", false)
		minimap_enabled = cfg.get_value("game", "minimap_enabled", true)
		has_opened_player_settings = cfg.get_value("game", "has_opened_player_settings", false)
		var raw_ring_self: Variant = cfg.get_value("game", "ring_color_self", ring_color_self)
		ring_color_self = raw_ring_self if raw_ring_self is Color else ring_color_self
		var raw_ring_team: Variant = cfg.get_value("game", "ring_color_team", ring_color_team)
		ring_color_team = raw_ring_team if raw_ring_team is Color else ring_color_team
		var raw_ring_enemy: Variant = cfg.get_value("game", "ring_color_enemy", ring_color_enemy)
		ring_color_enemy = raw_ring_enemy if raw_ring_enemy is Color else ring_color_enemy
		self_beacon_mode = clampi(int(cfg.get_value("game", "self_beacon_mode", BEACON_MODE_SMART)), 0, BEACON_MODE_LABELS.size() - 1)
		screen_flash = cfg.get_value("game", "screen_flash", true)
		screen_shake = cfg.get_value("game", "screen_shake", true)
		camera_tilt_deg = clampf(cfg.get_value("game", "camera_tilt_deg", CAMERA_TILT_DEFAULT), CAMERA_TILT_MIN, CAMERA_TILT_MAX)
		fov = clampf(cfg.get_value("game", "fov", 50.0), FOV_MIN, FOV_MAX)
		camera_distance = clampf(cfg.get_value("game", "camera_distance", 1.0), CAMERA_DISTANCE_MIN, CAMERA_DISTANCE_MAX)
		camera_mode = clampi(int(cfg.get_value("game", "camera_mode", CAMERA_MODE_DYNAMIC)), 0, CAMERA_MODE_LABELS.size() - 1)
		bot_difficulty = int(cfg.get_value("game", "bot_difficulty", BotSkillProfile.Difficulty.NORMAL))
		# Easy was inserted at index 0, shifting the old 2-tier values up one
		# (old 0=Normal → new 1=Normal, old 1=Hard → new 2=Hard). Remap once, but
		# only a value actually persisted under the old scale (has the key, no
		# version marker) — mirrors the goalie_difficulty remap above so a config
		# predating bot_difficulty keeps the new default instead of bumping to Hard.
		if cfg.has_section_key("game", "bot_difficulty") \
				and int(cfg.get_value("game", "bot_difficulty_scale_version", 0)) < 1:
			bot_difficulty += 1
		bot_difficulty = clampi(bot_difficulty, 0, BOT_DIFFICULTY_LABELS.size() - 1)
		goalie_difficulty = int(cfg.get_value("game", "goalie_difficulty", GoalieSkillProfile.Difficulty.NORMAL))
		# Easy was inserted at index 0, shifting the old 2-tier values up one
		# (old 0=Normal → new 1=Normal, old 1=Hard → new 2=Hard). Remap once, but
		# only a value that was actually persisted under the old scale (has the key,
		# no version marker) — a config predating goalie_difficulty keeps the new
		# default rather than being spuriously bumped to Hard.
		if cfg.has_section_key("game", "goalie_difficulty") \
				and int(cfg.get_value("game", "goalie_difficulty_scale_version", 0)) < 1:
			goalie_difficulty += 1
		goalie_difficulty = clampi(goalie_difficulty, 0, GOALIE_DIFFICULTY_LABELS.size() - 1)
		freeplay_goalie_difficulty = clampi(int(cfg.get_value("game", "freeplay_goalie_difficulty", GoalieSkillProfile.Difficulty.EASY)), 0, GOALIE_DIFFICULTY_LABELS.size() - 1)
		hud_scale = clampf(cfg.get_value("game", "hud_scale", 1.0), HUD_SCALE_MIN, HUD_SCALE_MAX)
		share_gameplay_stats = cfg.get_value("game", "share_gameplay_stats", true)
		var raw_locale: Variant = cfg.get_value("game", "locale", "")
		locale = raw_locale if raw_locale is String else ""
		replay_recording_enabled = cfg.get_value("replay", "recording_enabled", true)
		replay_keep_count = clampi(cfg.get_value("replay", "keep_count", 20), REPLAY_KEEP_MIN, REPLAY_KEEP_MAX)
		var raw_completion: Variant = cfg.get_value("tutorials", "completion", {})
		tutorial_completion = raw_completion if raw_completion is Dictionary else {}
		# Course-version gate: when the tutorial course is restructured (new
		# parts, new mechanics taught), bump TUTORIAL_COURSE_VERSION to wipe
		# saved completion so every player is routed back through the new
		# course on next boot (see boot.gd's first-incomplete routing).
		if int(cfg.get_value("tutorials", "course_version", 1)) < TUTORIAL_COURSE_VERSION:
			tutorial_completion = {}
		for action: String in REBINDABLE_ACTIONS:
			var t: String = cfg.get_value("bindings", action + "_type", "")
			if t == "key":
				bindings[action] = {"type": "key", "physical_keycode": cfg.get_value("bindings", action + "_code", 0)}
			elif t == "mouse":
				bindings[action] = {"type": "mouse", "button_index": cfg.get_value("bindings", action + "_code", 0)}
		# Action rename (quick_shot → quick_pass): the quick-pass action was renamed
		# off "quick_shot" so it stops reading as a shot. A config predating the
		# rename stored the bind under the old key — adopt it so a player's custom
		# quick-pass key survives the rename instead of resetting to the E default.
		# (The old key is left in the file; it's simply never read again.)
		if not bindings.has("quick_pass"):
			var old_qp_type: String = cfg.get_value("bindings", "quick_shot_type", "")
			if old_qp_type == "key":
				bindings["quick_pass"] = {"type": "key", "physical_keycode": cfg.get_value("bindings", "quick_shot_code", 0)}
			elif old_qp_type == "mouse":
				bindings["quick_pass"] = {"type": "mouse", "button_index": cfg.get_value("bindings", "quick_shot_code", 0)}
		# Control-scheme swap (scheme_version 1): Hit takes Ctrl, Block moves to C.
		# Block was moved off Ctrl to free it for the new Hit button. A config
		# predating the swap that still has Block on its old Ctrl default is
		# remapped to C so the new layout takes effect; a player who deliberately
		# rebound Block elsewhere is left alone. Hit is new — erased here so the
		# default-fill below seeds it from the fresh project default (Ctrl). Runs
		# once, gated like the difficulty-scale remaps above.
		if int(cfg.get_value("bindings", "scheme_version", 0)) < 1:
			var old_block: Dictionary = bindings.get("block", {})
			if old_block.get("type") == "key" \
					and int(old_block.get("physical_keycode", 0)) == KEY_CTRL:
				bindings["block"] = {"type": "key", "physical_keycode": KEY_C}
			bindings.erase("hit")
	# Fill in InputMap defaults for any action not in the saved config
	for action: String in REBINDABLE_ACTIONS:
		if not bindings.has(action):
			var b: Dictionary = _read_current_input_event(action)
			if not b.is_empty():
				bindings[action] = b
	# Runs whether or not a config file loaded (fresh installs skip the OK block
	# above entirely), so there is always at least one preset and the flat build
	# matches the active one.
	_finalize_presets()
	apply_locale()
	apply_audio()
	apply_bindings()
	call_deferred(&"apply_input")
	call_deferred(&"apply_cursor")
	call_deferred(&"apply_video")


func get_player_attributes() -> PlayerAttributes:
	# Mirror the host-side joiner validation (NetworkManager.request_join): the
	# constructor coerces every axis (weight into the height's band, gear into
	# range), so a hand-edited or corrupt flat build lands on the nearest legal
	# body instead of leaking out-of-band values into the sim.
	return PlayerAttributes.new(attr_height, attr_weight,
			attr_profile, attr_curve, attr_flex, attr_length)


func set_player_attributes(attrs: PlayerAttributes) -> void:
	if attrs == null:
		return
	attr_height  = attrs.height
	attr_weight  = attrs.weight
	attr_profile = attrs.profile
	attr_curve   = attrs.curve
	attr_flex    = attrs.flex
	attr_length  = attrs.length
	# The active preset IS the flat build — editing the live build (free-play
	# picker Apply) edits the active preset. Guarded for the pre-_finalize window.
	if attr_active_preset >= 0 and attr_active_preset < attr_presets.size():
		attr_presets[attr_active_preset]["attrs"] = _copy_attrs(attrs)


# ── Presets API ──────────────────────────────────────────────────────────────
# Mutators update in-memory state only; callers persist with save() afterward,
# exactly like set_player_attributes (see the free-play picker Apply path). This
# keeps the presets layer disk-side-effect-free and unit-testable.

# The live preset list. Callers read entry["name"] / entry["attrs"]; they must
# not mutate entries in place — use the mutators below.
func get_presets() -> Array[Dictionary]:
	return attr_presets


func get_active_preset_index() -> int:
	return attr_active_preset


# Switch which preset is active. Copies its build into the flat fields so
# get_player_attributes() (and thus the join handshake / free-play apply) sees it.
func set_active_preset(index: int) -> void:
	if index < 0 or index >= attr_presets.size() or index == attr_active_preset:
		return
	attr_active_preset = index
	_sync_flat_from_active()


# Overwrite the build (and optionally the name) of an existing preset. If it is
# the active preset the flat mirror is refreshed too.
func save_preset(index: int, attrs: PlayerAttributes, preset_name: String = "") -> void:
	if attrs == null or index < 0 or index >= attr_presets.size():
		return
	attr_presets[index]["attrs"] = _copy_attrs(attrs)
	if preset_name != "":
		attr_presets[index]["name"] = _sanitize_preset_name(preset_name)
	if index == attr_active_preset:
		_sync_flat_from_active()


# Append a new preset (up to MAX_PRESETS). Defaults to a copy of the current
# active build. Returns the new index, or -1 if the cap is reached.
func add_preset(attrs: PlayerAttributes = null, preset_name: String = "") -> int:
	if attr_presets.size() >= MAX_PRESETS:
		return -1
	var a: PlayerAttributes = attrs if attrs != null else get_player_attributes()
	var nm: String = preset_name if preset_name != "" else _default_preset_name()
	attr_presets.append(_make_preset(nm, a))
	return attr_presets.size() - 1


# Remove a preset. The last surviving preset can't be deleted. Keeps the active
# index pointing at a valid build and re-syncs the flat mirror if it moved.
func delete_preset(index: int) -> void:
	if attr_presets.size() <= 1 or index < 0 or index >= attr_presets.size():
		return
	attr_presets.remove_at(index)
	if attr_active_preset >= attr_presets.size():
		attr_active_preset = attr_presets.size() - 1
	elif attr_active_preset > index:
		attr_active_preset -= 1
	_sync_flat_from_active()


# Bulk-replace the whole preset list and active index in one shot — the commit
# path for the picker panel, which edits a working copy and pushes it back on
# Apply. Each entry is {"name": String, "levels": Array[int]} in the order
# [height, skating, skill, checking]. Ignores entries that don't carry four
# levels and never leaves the list empty (a no-op if nothing usable is
# supplied). Callers persist with save() afterward.
func set_all_presets(entries: Array, active: int) -> void:
	var out: Array[Dictionary] = []
	for entry: Variant in entries:
		if not (entry is Dictionary):
			continue
		var lv: Array = (entry as Dictionary).get("levels", [])
		if lv.size() < 2:
			continue
		# Canonical levels order: [height, weight, profile, curve, flex, length].
		# Missing gear entries (a short array) default to balanced.
		var attrs := PlayerAttributes.from_levels(
				int(lv[0]), int(lv[1]),
				int(lv[2]) if lv.size() > 2 else PlayerAttributes.GEAR_BALANCED,
				int(lv[3]) if lv.size() > 3 else PlayerAttributes.GEAR_BALANCED,
				int(lv[4]) if lv.size() > 4 else PlayerAttributes.GEAR_BALANCED,
				int(lv[5]) if lv.size() > 5 else PlayerAttributes.GEAR_BALANCED)
		out.append(_make_preset(String((entry as Dictionary).get("name", DEFAULT_PRESET_NAME)), attrs))
		if out.size() >= MAX_PRESETS:
			break
	if out.is_empty():
		return
	attr_presets = out
	attr_active_preset = clampi(active, 0, out.size() - 1)
	_sync_flat_from_active()


func _clamp_1to5(v: int) -> int:
	return clampi(v, 1, 5)


# Guarantees at least one preset exists and the flat build matches the active
# one. When presets loaded from disk they are authoritative (flat ← active);
# when none were stored (fresh / pre-presets save) seeds a Default from the flat
# build (a no-op re-sync afterward).
func _finalize_presets() -> void:
	if attr_presets.is_empty():
		attr_presets = [_make_preset(DEFAULT_PRESET_NAME, get_player_attributes())]
		attr_active_preset = 0
	attr_active_preset = clampi(attr_active_preset, 0, attr_presets.size() - 1)
	_sync_flat_from_active()


func _sync_flat_from_active() -> void:
	if attr_active_preset < 0 or attr_active_preset >= attr_presets.size():
		return
	var a: PlayerAttributes = attr_presets[attr_active_preset]["attrs"]
	attr_height  = a.height
	attr_weight  = a.weight
	attr_profile = a.profile
	attr_curve   = a.curve
	attr_flex    = a.flex
	attr_length  = a.length


func _make_preset(preset_name: String, attrs: PlayerAttributes) -> Dictionary:
	return {"name": _sanitize_preset_name(preset_name), "attrs": _copy_attrs(attrs)}


# Independent copy so a preset never shares a PlayerAttributes instance with a
# caller (which could mutate it out from under us).
func _copy_attrs(attrs: PlayerAttributes) -> PlayerAttributes:
	return PlayerAttributes.from_levels(attrs.height, attrs.weight,
			attrs.profile, attrs.curve, attrs.flex, attrs.length)


func _default_preset_name() -> String:
	return "Build %d" % (attr_presets.size() + 1)


func _sanitize_preset_name(preset_name: String) -> String:
	var n: String = preset_name.strip_edges()
	if n.is_empty():
		n = DEFAULT_PRESET_NAME
	return n.substr(0, PRESET_NAME_MAX_LEN)


# Rebuilds the runtime preset list from the stored array-of-dicts, capping at
# MAX_PRESETS. Native entries (height/skating/skill/checking) are read directly;
# a legacy six-attribute preset dict is migrated via PlayerAttributes.from_dict.
# An illegal build resets to all-average. Tolerates malformed entries (skips
# non-dicts) so a corrupt save degrades to fewer presets rather than crashing.
func _parse_stored_presets(raw: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not (raw is Array):
		return out
	for entry: Variant in (raw as Array):
		if not (entry is Dictionary):
			continue
		var d: Dictionary = entry
		# from_dict migrates tier-era and six-attribute preset dicts and the
		# constructor coerces every axis, so no legality pass is needed.
		var attrs := PlayerAttributes.from_dict(d)
		out.append(_make_preset(String(d.get("name", DEFAULT_PRESET_NAME)), attrs))
		if out.size() >= MAX_PRESETS:
			break
	return out


# Remaps a legacy 1..3 attribute level onto the 1..5 scale (medium 2 → 3). Used
# only by the pre-v2 prefs migration to reconstruct the six-attribute
# intermediate that migrate_legacy then maps to the height/tier model.
func _migrate_legacy_level(old: int) -> int:
	return _clamp_1to5(2 * clampi(old, 1, 3) - 1)


# Re-coerce the loaded/migrated flat build through the constructor (weight into
# the height's BMI band, gear into 0..2). A hand-edited / corrupt cfg could
# carry out-of-band values, which unchecked would let an offline or HOSTING
# player field them (the joiner gate in NetworkManager only coerces REMOTE
# peers). Funnel through set_player_attributes so the active preset mirror
# stays in sync.
func _enforce_attr_legal() -> void:
	set_player_attributes(get_player_attributes())


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
