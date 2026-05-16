extends Node

# Engine-facing constants only. Game-rule constants (faceoff timings, rink
# geometry, puck position, icing duration, faceoff positions, max players,
# ice friction) live in Scripts/domain/config/game_rules.gd as a class_name
# const class.

# ── Collision Layers ──────────────────────────────────────────────────────────
# Layer 1 (bit 0, value  1) — walls, ice, goalie bodies
# Layer 2 (bit 1, value  2) — skater blade Area3Ds
# Layer 4 (bit 3, value  8) — puck body (goal sensors use mask 8 to detect it)
# Layer 5 (bit 4, value 16) — skater CharacterBody3D bodies
const LAYER_WALLS: int          = 1
const LAYER_BLADE_AREAS: int    = 2
const LAYER_PUCK: int           = 8
const LAYER_SKATER_BODIES: int  = 16

# ── Composed Masks ────────────────────────────────────────────────────────────
const MASK_PUCK: int   = LAYER_WALLS                         # bounces off boards + goalie bodies
const MASK_SKATER: int = LAYER_WALLS | LAYER_SKATER_BODIES   # blocked by boards + other skaters

# ── Network (transport-level) ─────────────────────────────────────────────────
const PORT: int = 7777
const INPUT_RATE: int = 60
const STATE_RATE: int = 60
# Client-side render delay when interpolating buffered snapshots. Shared default
# for RemoteController / PuckController / GoalieController; each controller
# still exposes it as @export so individual actors can be tuned independently.
const NETWORK_INTERPOLATION_DELAY: float = 0.075

# ── Physics ───────────────────────────────────────────────────────────────────
const PHYSICS_TICK: int = 240

# ── Scenes ────────────────────────────────────────────────────────────────────
const SCENE_BOOT: String          = "res://Scenes/Boot.tscn"
const SCENE_HOCKEY: String        = "res://Scenes/Hockey.tscn"
const SCENE_LOBBY: String         = "res://Scenes/Lobby.tscn"
const SCENE_REPLAY_VIEWER: String = "res://Scenes/ReplayViewer.tscn"
