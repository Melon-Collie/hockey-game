extends Node

# Engine-facing constants only. Game-rule constants (faceoff timings, rink
# geometry, puck position, icing duration, faceoff positions, max players,
# ice friction) live in Scripts/domain/config/game_rules.gd as a class_name
# const class.

# ── Collision Layers ──────────────────────────────────────────────────────────
# Layer 1 (bit 0, value  1) — walls, ice, goalie bodies (pads/body/head/glove/blocker)
# Layer 2 (bit 1, value  2) — skater blade Area3Ds
# Layer 3 (bit 2, value  4) — goalie stick (puck bounces off it; skaters pass through)
# Layer 4 (bit 3, value  8) — puck body (goal sensors use mask 8 to detect it)
# Layer 5 (bit 4, value 16) — skater CharacterBody3D bodies
const LAYER_WALLS: int          = 1
const LAYER_BLADE_AREAS: int    = 2
const LAYER_GOALIE_STICK: int   = 4
const LAYER_PUCK: int           = 8
const LAYER_SKATER_BODIES: int  = 16

# ── Composed Masks ────────────────────────────────────────────────────────────
# Puck bounces off boards + goalie bodies AND the goalie stick, but the stick is
# kept off LAYER_WALLS so skaters (whose mask omits LAYER_GOALIE_STICK) skate
# straight through it instead of snagging on the hooked shaft/paddle/blade.
const MASK_PUCK: int   = LAYER_WALLS | LAYER_GOALIE_STICK    # bounces off boards + goalie bodies + stick
const MASK_SKATER: int = LAYER_WALLS | LAYER_SKATER_BODIES   # blocked by boards + goalie bodies + other skaters

# ── Network (transport-level) ─────────────────────────────────────────────────
const PORT: int = 7777
const INPUT_RATE: int = 60
const STATE_RATE: int = 120
# Client-side render delay when interpolating buffered snapshots. Shared default
# for RemoteController / PuckController / GoalieController; each controller
# still exposes it as @export so individual actors can be tuned independently.
const NETWORK_INTERPOLATION_DELAY: float = 0.075
# Wire encoding for session-relative timestamps: u32 in 0.1 ms units
# (seconds × this scale). Replaces f32 seconds, whose ULP degraded with host
# uptime — ~1 ms error at 2.3 h (visible interpolation jitter), ~2 ms at
# 4.6 h (per-tick input stamps quantize equal and get dropped as duplicates).
# u32 @ 0.1 ms gives constant precision over a ~119-hour range. Encode with
# roundi so round-trips through the grid are exact; bump
# BuildInfo.PROTOCOL_VERSION and ReplayFileWriter.FORMAT_VERSION if this
# representation ever changes again.
const TIME_WIRE_SCALE: float = 10000.0

# ── Physics ───────────────────────────────────────────────────────────────────
# Single source of truth for the GDScript-side tick rate: every tick-derived
# timing constant (clock-sync input lead, AI charge/cooldown windows, telemetry
# windows) preloads this file and divides PHYSICS_TICK, so they all track it.
# The ENGINE steps at project.godot's physics/common/physics_ticks_per_second,
# which is a SEPARATE knob — to change the tick rate, edit BOTH. `_ready()` below
# push_errors at boot if they drift (a mismatch silently dilates the sim).
const PHYSICS_TICK: int = 120

# ── Scenes ────────────────────────────────────────────────────────────────────
const SCENE_BOOT: String          = "res://Scenes/Boot.tscn"
const SCENE_HOCKEY: String        = "res://Scenes/Hockey.tscn"
const SCENE_LOBBY: String         = "res://Scenes/Lobby.tscn"
const SCENE_REPLAY_VIEWER: String = "res://Scenes/ReplayViewer.tscn"


func _ready() -> void:
	# Guard the two-knob coupling: the engine steps at project.godot's rate while
	# all GDScript timing derives from PHYSICS_TICK. If they disagree the sim
	# silently dilates against the wall clock that clock-sync and broadcast
	# cadence depend on — catch it loudly at boot instead of in the field.
	var engine_tick: int = int(ProjectSettings.get_setting(
			"physics/common/physics_ticks_per_second", PHYSICS_TICK))
	if engine_tick != PHYSICS_TICK:
		push_error(("Constants.PHYSICS_TICK (%d) != project.godot " +
				"physics_ticks_per_second (%d) — update both to change the tick rate.") %
				[PHYSICS_TICK, engine_tick])
