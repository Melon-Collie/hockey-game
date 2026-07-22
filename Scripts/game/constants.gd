extends Node

# Engine-facing constants only. Game-rule constants (faceoff timings, rink
# geometry, puck position, icing duration, faceoff positions, max players,
# ice friction) live in Scripts/domain/config/game_rules.gd as a class_name
# const class.

# ── Collision Layers ──────────────────────────────────────────────────────────
# Layer 1 (bit 0, value  1) — walls, ice
# Layer 2 (bit 1, value  2) — skater blade Area3Ds
# Layer 3 (bit 2, value  4) — goalie stick (puck bounces off it; skaters pass through)
# Layer 4 (bit 3, value  8) — puck body (goal sensors use mask 8 to detect it)
# Layer 5 (bit 4, value 16) — skater CharacterBody3D bodies
# Layer 6 (bit 5, value 32) — perimeter boards (puck only; skaters clamp analytically)
# Layer 7 (bit 6, value 64) — goal-net frame + panels (puck only; skaters clamp analytically)
# Layer 8 (bit 7, value 128) — goalie bodies (pads/body/head/glove/blocker)
const LAYER_WALLS: int          = 1
const LAYER_BLADE_AREAS: int    = 2
const LAYER_GOALIE_STICK: int   = 4
const LAYER_PUCK: int           = 8
const LAYER_SKATER_BODIES: int  = 16
# Boards live on their own layer so the puck still bounces off the concave board
# mesh while skaters DON'T collide with it. A CharacterBody cylinder straddling
# the 256-segment corner mesh gets pinned in a vertical-only crease (two facet
# normals → vertical cross product) and freezes; skaters are kept off the boards
# and held inside the rink by GameRules.clamp_to_rink_inner instead. The ice
# stays on LAYER_WALLS, so skaters still collide with it.
const LAYER_BOARDS: int         = 32
# The goal net (pipe frame + twine panels) lives on its own layer for the SAME
# reason as the boards: a CharacterBody cylinder shoved into the concave net
# pocket (back + side panels) wedges in a vertical-only crease and freezes — most
# reliably when the goalie bulldozes a skater backward across the goal line before
# the crease-dwell ghost fires. The puck still bounces (MASK_PUCK includes it, and
# each part keeps its own pipe/twine physics material); skaters are held clear
# analytically by GameRules.push_out_of_net (see Skater.clamp_body_to_net).
const LAYER_NET: int            = 64
# Goalie bodies (pads/body/head/glove/blocker) live on their own layer, off
# LAYER_WALLS, so a ghosted skater can drop them from its mask (see
# Skater.set_ghost) while keeping the ice — a crease-dwell ghost must stop
# jostling the goalie, which is the interference the mechanic exists to remove.
# Both the puck and non-ghost skaters still collide via their composed masks.
# The goalie stick stays on its separate LAYER_GOALIE_STICK (skaters always
# pass through it, ghosted or not).
const LAYER_GOALIE_BODIES: int  = 128

# ── Composed Masks ────────────────────────────────────────────────────────────
# Puck bounces off boards + goalie bodies + the net AND the goalie stick, but the
# stick is kept off the skater mask (LAYER_GOALIE_STICK) so players skate straight
# through it instead of snagging on the hooked shaft/paddle/blade.
const MASK_PUCK: int   = LAYER_WALLS | LAYER_BOARDS | LAYER_GOALIE_STICK | LAYER_NET | LAYER_GOALIE_BODIES  # bounces off boards + ice + net + stick + goalie bodies
# Skater move_and_slide collides with the ice (LAYER_WALLS) + goalie bodies;
# boards + net are held analytically (see above), and skater-vs-skater contact is
# now resolved analytically too — SkaterCollisionRules in Skater._resolve_player_
# collisions, replacing move_and_slide's rigid cylinder separation + the old
# restitution bounce (the pinball) with an inelastic disc model. Skaters keep their
# LAYER_SKATER_BODIES layer (harmless; nothing masks it now) so any future physics
# query against skater bodies still has a layer to target.
const MASK_SKATER: int = LAYER_WALLS | LAYER_GOALIE_BODIES  # ice + goalie bodies; boards, net, and other skaters handled analytically

# ── Network (transport-level) ─────────────────────────────────────────────────
const PORT: int = 7777
# Client input batches are sent once per physics tick. Matching PHYSICS_TICK
# minimizes the batch-send wait folded into ClockSync.INPUT_LEAD_SEC (which
# derives BATCH_INTERVAL from this constant) — at 60 Hz the worst-case wait was
# a full 16.7 ms of client→host latency on every input.
const INPUT_RATE: int = 120
const STATE_RATE: int = 120
# Rate at which world-state snapshots are written to the .mreplay file, well
# below STATE_RATE: the replay viewer interpolates between snapshots (see
# ReplayPlaybackEngine), so recording every 120 Hz broadcast is ~4x redundant on
# disk. 30 Hz keeps playback smooth at roughly a quarter the file size. Only the
# steady PLAYING stream is throttled — phase-transition keyframes and the goal
# moment are always recorded (GameManager._record_world_state_to_file).
const REPLAY_FILE_RATE: int = 30
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
