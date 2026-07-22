extends Node

# Engine-facing constants only. Game-rule constants (faceoff timings, rink
# geometry, puck position, icing duration, faceoff positions, max players,
# ice friction) live in Scripts/domain/config/game_rules.gd as a class_name
# const class.

# ── Collision Layers ──────────────────────────────────────────────────────────
# Layer 1 (bit 0, value  1) — walls, ice, goalie bodies (pads/body/head/glove/blocker)
# Layer 2 (bit 1, value  2) — skater blade Area3Ds
# Layer 3 (bit 2, value  4) — goalie stick (skaters pass through; puck contact is analytic)
# Layer 4 (bit 3, value  8) — unused (was the puck RigidBody3D; the puck is a
#                             plain Node3D now — every puck contact is analytic)
# Layer 5 (bit 4, value 16) — skater CharacterBody3D bodies
# Layer 6 (bit 5, value 32) — perimeter boards (nothing masks it since the puck
#                             went analytic; kept isolated so nothing snags on it)
# Layer 7 (bit 6, value 64) — goal-net frame + panels (same — puck caroms are
#                             analytic, skaters clamp analytically)
const LAYER_WALLS: int          = 1
const LAYER_BLADE_AREAS: int    = 2
const LAYER_GOALIE_STICK: int   = 4
const LAYER_SKATER_BODIES: int  = 16
# Boards live on their own layer so skaters DON'T collide with the concave board
# mesh. A CharacterBody cylinder straddling the 256-segment corner mesh gets
# pinned in a vertical-only crease (two facet normals → vertical cross product)
# and freezes; skaters are kept off the boards and held inside the rink by
# GameRules.clamp_to_rink_inner instead — the same rounded-rect boundary the
# analytic puck sim caroms off. The ice and goalie bodies stay on LAYER_WALLS,
# so skaters still collide with those.
const LAYER_BOARDS: int         = 32
# The goal net (pipe frame + twine panels) lives on its own layer for the SAME
# reason as the boards: a CharacterBody cylinder shoved into the concave net
# pocket (back + side panels) wedges in a vertical-only crease and freezes — most
# reliably when the goalie bulldozes a skater backward across the goal line before
# the crease-dwell ghost fires. The puck plays the frame analytically
# (PuckGeometryCollision); skaters are held clear analytically by
# GameRules.push_out_of_net (see Skater.clamp_body_to_net).
const LAYER_NET: int            = 64

# ── Composed Masks ────────────────────────────────────────────────────────────
# Skater move_and_slide collides only with LAYER_WALLS (ice + goalie bodies);
# boards + net are held analytically (see above), and skater-vs-skater contact is
# now resolved analytically too — SkaterCollisionRules in Skater._resolve_player_
# collisions, replacing move_and_slide's rigid cylinder separation + the old
# restitution bounce (the pinball) with an inelastic disc model. Skaters keep their
# LAYER_SKATER_BODIES layer (harmless; nothing masks it now) so any future physics
# query against skater bodies still has a layer to target.
const MASK_SKATER: int = LAYER_WALLS   # goalie bodies/ice only; boards, net, and other skaters handled analytically

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
# Stage-3 remote forward-prediction (see docs/netcode-forward-prediction-plan.md).
# How far a remote skater is intent-integrated from its interpolated-past base
# toward host-present, as a fraction of interp_delay: 0.0 = legacy interpolate-in-
# the-past (render == rewind exactly, the shipped behavior); 1.0 = full ~interp_delay
# of forward prediction (remote bodies render at ~present). READ BY BOTH the client
# render (RemoteController) AND every carrier-anchored host claim rewind (hit, poke,
# stick-lift — via LagCompRewind.forward_predict_skater / forward_predict_ticks), so
# render stays == rewind at any value — all consumers MUST use the same fraction. Set to 1.0 (full ~interp_delay of forward
# prediction, remote bodies at ~present) for the experimental Steam playtest build.
# Dial toward 0.5 / 0.0 if remote skaters overshoot on hard cuts (extrapolation
# snap-back) or contested-hit feel regresses; 0.0 restores exact render == rewind.
const REMOTE_FORWARD_PREDICT_FRACTION: float = 1.0
# Rocket-League-style input decay for the forward prediction: over this many ticks
# the assumed (held) move-intent fades linearly to 0, so the far end of the
# prediction window coasts on friction instead of thrusting in a possibly-stale
# direction. This is what tames overshoot when a remote player CUTS mid-window —
# the single biggest quality lever on the skater lead. Read by BOTH the client
# render (RemoteController) and the host claim rewind (HitClaimResolver) via
# SkaterMovementRules.integrate_forward, so the decay is identical and render ==
# rewind holds. 0 = no decay (full intent every tick). ~5 fades over the near half
# of a full-lead (~9-tick) window; lower = more conservative (less overshoot, less
# catch-up), higher = more aggressive. Tune alongside REMOTE_FORWARD_PREDICT_FRACTION.
const FORWARD_PREDICT_INTENT_DECAY_TICKS: int = 5
# Phase-3/4b determinism migration (docs/netcode-determinism-migration.md):
# every client runs the SAME analytic sim the host drives the loose puck with,
# forward to its estimate of host present — real predict-and-reconcile; the
# loose puck is never interpolated except as the stale-data fallback. The
# source is the newest authoritative snapshot, or — for the shooter's own
# release, until the host's snapshots reflect it — the local release seed
# (PuckController._release_seed_*). Static geometry (boards, posts, crossbar,
# net) is fully predicted via the shared PuckAuthorityRules step; goalie
# contact is a prediction STOP (hold at the contact — the save outcome is a
# host decision, never re-derived client-side). Host claim rewinds for the
# LOOSE puck (pickup, one-timer range gate) read the claim stamp — see
# LagCompRewind.puck_view_time — so render == rewind holds at present.
# Prediction depth cap: a snapshot older than this (deep packet loss) is too
# stale to predict from — the client falls back to the legacy interpolation
# path, whose extrapolation cap + hold already handle starvation gracefully.
const PUCK_PREDICT_MAX_S: float = 0.35
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
